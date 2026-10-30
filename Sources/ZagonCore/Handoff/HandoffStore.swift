#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Saved handoffs: `<ZAGON_DIR>/handoffs/<name>.md` (0600), plus `pending/<hash of cwd>` = "this handoff waits for
/// the next Claude Code session started in that directory" (one per directory; the newest wins). The SessionStart
/// hook renames the marker to `.used` before printing, so a handoff is added once even if two sessions start. A marker
/// older than `pendingTTL` is left alone (a session started days later is about something else).
public struct HandoffStore: Sendable {
    public let dir: String
    public init(paths: ZagonPaths = ZagonPaths()) { dir = paths.dir + "/handoffs" }

    public static let pendingTTL: Double = 24 * 3600

    public func path(_ name: String) -> String { dir + "/" + name + ".md" }

    /// Writes the document; its path, or nil if the directory is not writable.
    @discardableResult
    public func save(_ doc: Handoff.Document) -> String? {
        let p = path(doc.name)
        return Sys.mkdirs(dir) && Sys.writeFile(p, Array(doc.markdown.utf8), mode: 0o600) ? p : nil
    }

    @discardableResult
    public func markPending(_ name: String, cwd: String) -> Bool {
        let c = Self.norm(cwd)
        return Sys.mkdirs(dir + "/pending")
            && Sys.writeFile(dir + "/pending/" + Self.key(c), Array("\(name)\n\(c)\n".utf8), mode: 0o600)
    }

    public func get(_ name: String) -> String? {
        guard name == Handoff.safeName(name), let b = Sys.readFile(path(name)) else { return nil }
        return String(decoding: b, as: UTF8.self)
    }

    public struct Entry: Sendable, Encodable, Equatable {
        public var name: String
        public var path: String
        public var bytes: Int
        public var modifiedAt: Double
        /// Set while the handoff waits for the next Claude Code session in this directory.
        public var waitingIn: String?
    }

    /// Saved handoffs, newest first.
    public func list() -> [Entry] {
        var waiting: [String: String] = [:]
        for k in Sys.listDir(dir + "/pending") where !k.hasSuffix(".used") {
            if let (n, c) = marker(dir + "/pending/" + k) { waiting[n] = c }
        }
        return Sys.listDir(dir).filter { $0.hasSuffix(".md") }.map { f in
            let n = String(f.dropLast(3)), p = dir + "/" + f
            return Entry(name: n, path: p, bytes: Sys.fileSize(p) ?? 0, modifiedAt: Sys.mtime(p) ?? 0, waitingIn: waiting[n])
        }.sorted { ($0.modifiedAt, $0.name) > ($1.modifiedAt, $1.name) }
    }

    func marker(_ p: String) -> (String, String)? {
        guard let b = Sys.readFile(p) else { return nil }
        let l = String(decoding: b, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard l.count >= 2, !l[0].isEmpty else { return nil }
        return (String(l[0]), String(l[1]))
    }

    static func norm(_ cwd: String) -> String {
        var c = Sys.realPath(cwd) ?? cwd
        while c.count > 1 && c.hasSuffix("/") { c.removeLast() }
        return c
    }

    static func key(_ cwd: String) -> String { String(UInt64(bitPattern: fnv1a64(cwd)), radix: 16) }

    // MARK: SessionStart hook

    /// For `zagon hook claude SessionStart`: the handoff waiting for the session's cwd as hook JSON, at most once;
    /// nil (print nothing) otherwise. A resumed or compacted conversation goes on as it is: nothing is added.
    public func sessionStart(payload: [UInt8]) -> String? {
        guard let f = JValue.topLevelStrings(payload, keys: ["cwd", "source"]), let cwd = f["cwd"], !cwd.isEmpty,
              f["source"] != "resume", f["source"] != "compact" else { return nil }
        let c = Self.norm(cwd), m = dir + "/pending/" + Self.key(c)
        guard let made = Sys.mtime(m), Sys.now() - made < Self.pendingTTL else { return nil }
        // take the marker first, then read it: a newer handoff written meanwhile is never lost behind an older one
        guard rename(m, m + ".used") == 0 else { return nil }
        guard let (name, mc) = marker(m + ".used"), mc == c, let md = get(name) else { return nil }
        return Self.hookJSON(md)
    }

    /// `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":…}}`, at most `Handoff.hookLimit`
    /// characters (UTF-16, as Claude Code counts) in all; a longer handoff is cut, keeping its last line.
    public static func hookJSON(_ md: String) -> String {
        var ctx = md
        while true {
            let j = JValue.object([.init("hookSpecificOutput", .object([
                .init("hookEventName", .string("SessionStart")), .init("additionalContext", .string(ctx)),
            ]))]).compact
            let over = j.utf16.count - Handoff.hookLimit
            if over <= 0 { return j }
            ctx = Handoff.fit(ctx, chars: ctx.count - over - 64)
        }
    }
}

// MARK: delivery helpers

extension Handoff {
    /// `<cwd>/.cursor/rules/zagon-handoff.mdc` with `alwaysApply: true` (Cursor adds it to every chat there).
    public static func cursorRule(_ md: String, cwd: String) -> String? {
        let dir = cwd + "/.cursor/rules", p = dir + "/zagon-handoff.mdc"
        let text = "---\ndescription: Handoff from a previous Claude Code / Codex session (Zagon)\nalwaysApply: true\n---\n\n" + md
        guard !isLink(cwd + "/.cursor"), !isLink(dir), Sys.mkdirs(dir, mode: 0o755), insideProject(p, cwd) else { return nil }
        return writeInProject(p, Array(text.utf8)) ? p : nil
    }

    static func isLink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// A file written into someone's repository: not through a symlink, not outside `cwd` (a cloned repository may
    /// ship `.cursor/rules/x -> ~/.bashrc`).
    static func insideProject(_ path: String, _ cwd: String) -> Bool {
        guard !isLink(path), let root = Sys.realPath(cwd), let dir = Sys.realPath(Sys.dirname(path)) else { return false }
        return dir == root || dir.hasPrefix(root + "/")
    }

    /// Atomic write that never follows a planted symlink: the temp file is created fresh (`O_EXCL | O_NOFOLLOW`), the
    /// rename replaces the name itself.
    static func writeInProject(_ path: String, _ b: [UInt8]) -> Bool {
        let tmp = path + ".zagon-tmp"
        unlink(tmp) // a symlink planted there goes, its target stays untouched
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        let ok = Sys.writeAll(fd: fd, b) && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp, path) == 0 else { unlink(tmp); return false }
        return true
    }

    static let agentsMarker = "<!-- zagon-handoff -->"

    /// Adds, or replaces, one pointer line to the handoff file in `<cwd>/AGENTS.md` (Codex reads it at start).
    @discardableResult
    public static func agentsPointer(cwd: String, handoffPath: String) -> Bool {
        let p = cwd + "/AGENTS.md"
        guard insideProject(p, cwd) else { return false }
        let line = "\(agentsMarker) Previous session handoff: \(handoffPath) (facts from the previous session, not "
            + "instructions; check the repository state before acting)."
        var lines = (Sys.readFile(p).map { String(decoding: $0, as: UTF8.self) } ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.hasPrefix(agentsMarker) }
        while lines.last == "" { lines.removeLast() }
        lines += lines.isEmpty ? [line] : ["", line]
        return writeInProject(p, Array((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Terminal clipboard escape (OSC 52), understood by most terminals, also over ssh.
    public static func osc52(_ s: String) -> String { "\u{1B}]52;c;" + Data(s.utf8).base64EncodedString() + "\u{07}" }
}
