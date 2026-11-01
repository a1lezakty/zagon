#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Cursor's agent: sessions and time, no tokens and no limits (Cursor keeps those on its servers, and Zagon reads no
/// credentials). Two sources:
/// - hooks: `spool/<day>.cursor.ndjson`, the lines `zagon hook` writes for Cursor's calls (`HookSpool.cursorLine`):
///   exact turns, from when the hooks first fired (`ZagonPaths.cursorHooks`);
/// - transcripts: `~/.cursor/projects/<project>/agent-transcripts/<id>/<id>.jsonl`, for the time before that. They hold
///   no times; only typed messages with a `<timestamp>` tag (minutes) are placed, and a turn lasts until the next one
///   (or the file's last write), so this time is approximate.
public enum CursorSource {
    public static func specs(paths: ZagonPaths = ZagonPaths(), root: String? = nil) -> [SourceSpec] {
        let marker = paths.cursorHooks, home = paths.home
        return [
            SourceSpec(tool: .cursor, root: paths.spool, accepts: isHookFile) { _, _, _ in CursorHookParser() },
            SourceSpec(tool: .cursor, root: root ?? home + "/.cursor/projects", accepts: isTranscript) { path, rel, state in
                CursorTranscriptParser(path: path, relativePath: rel, state: state, hooksSince: hooksSince(marker), home: home)
            },
        ]
    }

    @Sendable static func isHookFile(_ rel: String) -> Bool { !rel.contains("/") && rel.hasSuffix(".cursor.ndjson") }

    /// `<project>/agent-transcripts/<id>/<id>.jsonl`; sub-agent logs (`<id>/subagents/`) and the old flat `.txt` are left out.
    @Sendable static func isTranscript(_ rel: String) -> Bool {
        let p = rel.split(separator: "/")
        return p.count == 4 && p[1] == "agent-transcripts" && p[3] == p[2] + ".jsonl"
    }

    /// When Cursor's hooks first fired (`HookSpool.handleHook` writes it once); nil = never.
    static func hooksSince(_ marker: String) -> Double? {
        Sys.readFile(marker).flatMap { Double(String(decoding: $0, as: UTF8.self).split(separator: "\n").first ?? "") }
    }
}

/// Cursor's lines of the hook spool: a typed prompt starts a turn, tool calls and the end of the answer extend it.
struct CursorHookParser: LineParser {
    /// Session, directory and model last reported (one `SessionMeta` per change, not per line).
    var reported: [String?] = []

    mutating func parse(line: UnsafeRawBufferPointer, into out: inout ParseOutput) {
        guard let v = JValue.parse(Array(line)), v["tool"]?.string == "cursor" else { return }
        guard v["kind"]?.string == "hook", let sid = v["session_id"]?.string, !sid.isEmpty, let ts = v["ts"]?.double,
              let event = v["event"]?.string else { out.badLines += 1; return }
        let id = "cursor:" + sid, cwd = v["cwd"]?.string, model = v["model"]?.string
        if reported != [id, cwd, model] {
            out.meta.append(SessionMeta(id: id, tool: .cursor, project: cwd.map(ClaudeParser.project), cwd: cwd, model: model))
            reported = [id, cwd, model]
        }
        switch event {
        // No text: only the prompt's task keys (`HookSpool.cursorLine`), for task links.
        case "UserPromptSubmit": out.userMessages.append(UserMessage(sessionId: id, ts: ts, text: v["keys"]?.string, cwd: cwd))
        case "PostToolUse", "Stop", "SubagentStop", "PreCompact": out.events.append(ActivityEvent(sessionId: id, ts: ts, cwd: cwd))
        default: break
        }
    }

    func saveState() -> String? { nil }
}

/// One conversation of Cursor's agent. A line is `{"role": "user" | "assistant", "message": {"content": [...]}}` with
/// no time, id or model; a typed message is the text in `<user_query>`, preceded by `<timestamp>Friday, Apr 24, 2026,
/// 7:43 PM (UTC+5)</timestamp>` in newer versions. Each stamped message starts a turn that lasts until the next stamped
/// one, the last one until the file's modification time, at most `cap`; a gap over `gap` gives the turn no length.
/// Messages from when the hooks already ran (`hooksSince`) are counted by the hooks instead.
/// ponytail: the format is not documented (it already moved from `.txt` to JSONL); unknown shapes are skipped.
struct CursorTranscriptParser: LineParser {
    struct State: Codable { var last: Double?; var titled = false }
    var st: State
    let sessionId: String, cwd: String?, project: String
    let since: Double?, mtime: Double?
    /// The stamped message whose end at `mtime` this pass has given (answer lines carry no time).
    var endFor: Double?

    /// ponytail: 10 min ≈ the 75th percentile of the gaps between stamped messages in real transcripts (median 5): the
    /// rest of a longer gap is mostly the user reading. Fixed; the parser does not see `session_gap` (30 min default).
    static let cap: Double = 600, gap: Double = 1800

    init(path: String, relativePath rel: String, state: String?, hooksSince: Double?, home: String) {
        st = state.flatMap { try? JSONDecoder().decode(State.self, from: Data($0.utf8)) } ?? State()
        let p = rel.split(separator: "/").map(String.init)
        sessionId = "cursor:" + (p.count > 2 ? p[2] : rel)
        (cwd, project) = Self.folder(ofSlug: p.first ?? "", home: home)
        since = hooksSince; mtime = Sys.mtime(path)
    }

    func saveState() -> String? { (try? JSONEncoder().encode(st)).map { String(decoding: $0, as: UTF8.self) } }

    static let role = Array(#"{"role":""#.utf8), user = Array(#"{"role":"user""#.utf8)

    mutating func parse(line: UnsafeRawBufferPointer, into out: inout ParseOutput) {
        defer { end(&out) }
        if line.starts(with: Self.role), !line.starts(with: Self.user) { return }  // the agent's lines: nothing to take
        guard let v = JValue.parse(Array(line)) else { out.badLines += 1; return }
        guard v["role"]?.string == "user", let content = v["message"]?["content"] else { return }
        let text = (content.array ?? [content]).compactMap { $0.string ?? $0["text"]?.string }.joined(separator: "\n")
        // The last `<user_query>` (attached files come before it), and the stamp just before it.
        guard let query = Self.lastTag("user_query", in: text[...]) else { return }  // not typed: context Cursor added
        if !st.titled {
            st.titled = true
            let title = query.text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingSpaces }.first { !$0.isEmpty }
            out.meta.append(SessionMeta(id: sessionId, tool: .cursor, project: project, cwd: cwd,
                                        title: title.map { String($0.prefix(80)) }))
        }
        guard let ts = Self.lastTag("timestamp", in: text[..<query.at]).flatMap({ Self.stamp($0.text) }),
              ts < (since ?? .infinity) - 60 else { return }
        if let last = st.last { turnEnd(last, ts - 1, &out) }
        out.userMessages.append(UserMessage(sessionId: sessionId, ts: ts, text: query.text, cwd: cwd))
        st.last = ts
    }

    /// The turn begun at `last` still went on at `at`: capped, none after a long gap or once the hooks count.
    func turnEnd(_ last: Double, _ at: Double, _ out: inout ParseOutput) {
        guard at > last, at - last <= Self.gap, at < since ?? .infinity else { return }
        out.events.append(ActivityEvent(sessionId: sessionId, ts: min(at, last + Self.cap), cwd: cwd))
    }

    /// The latest stamped message's turn went on until the file's last write (also when only answer lines came).
    mutating func end(_ out: inout ParseOutput) {
        guard let last = st.last, endFor != last, let m = mtime else { return }
        endFor = last
        turnEnd(last, m, &out)
    }

    /// The text inside the last `<name>…</name>` of `s`, trimmed, and where its opening tag starts.
    static func lastTag(_ name: String, in s: Substring) -> (text: String, at: String.Index)? {
        guard let a = s.ranges(of: "<\(name)>").last, let b = s[a.upperBound...].firstRange(of: "</\(name)>") else { return nil }
        var inner = s[a.upperBound..<b.lowerBound].drop(while: \.isWhitespace)
        while inner.last?.isWhitespace == true { inner = inner.dropLast() }
        return (String(inner), a.lowerBound)
    }

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `Friday, Apr 24, 2026, 7:43 PM (UTC+5)` (also `UTC-3:30`, `GMT`, 24-hour without AM/PM) → epoch seconds.
    static func stamp(_ s: String) -> Timestamp? {
        let f = s.split(separator: ",").map { $0.trimmingSpaces }
        guard f.count == 4 else { return nil }
        let md = f[1].split(separator: " "), rest = f[3].split(separator: " ")
        guard md.count == 2, let mi = months.firstIndex(of: String(md[0].prefix(3))), let d = Int(md[1]), let y = Int(f[2]),
              let hm = rest.first?.split(separator: ":"), hm.count == 2, var h = Int(hm[0]), let m = Int(hm[1]),
              (1970...2200).contains(y), (1...31).contains(d), (0...23).contains(h), (0...59).contains(m) else { return nil }
        var zone = rest.dropFirst()
        if let ap = zone.first, ap == "AM" || ap == "PM" {
            guard (1...12).contains(h) else { return nil }
            h = h % 12 + (ap == "PM" ? 12 : 0)
            zone = zone.dropFirst()
        }
        // `(UTC)`, `(UTC+5)`, `(UTC-03:30)`
        let z = zone.joined().filter { $0 != "(" && $0 != ")" }
        guard z.hasPrefix("UTC") || z.hasPrefix("GMT") else { return nil }
        var offset = 0
        let o = z.dropFirst(3)
        if let sign = o.first {
            guard sign == "+" || sign == "-" else { return nil }
            let p = o.dropFirst().split(separator: ":")
            let om = p.count == 2 ? Int(p[1]) : 0
            guard let oh = p.first.flatMap({ Int($0) }), let om, p.count <= 2, (0...14).contains(oh), (0...59).contains(om)
            else { return nil }
            offset = (oh * 3600 + om * 60) * (sign == "-" ? -1 : 1)
        }
        return Double(Time.daysFromCivil(y, mi + 1, d) * 86400 + h * 3600 + m * 60 - offset)
    }

    /// The folder a project slug names: Cursor writes `/Users/me/my-app` as `Users-me-my-app` (also spaces and dots
    /// as `-`), so each level is matched against the folder's entries; nil when it is gone or not a folder, and never
    /// looked into a folder macOS guards with a consent prompt (`Projects.guarded`; links are not followed, they may lead
    /// into one). `name`: the
    /// project, the folder's name, else the part of the slug no folder matched (`my-cool-app` under `~/Documents`).
    static func folder(ofSlug slug: String, home: String) -> (path: String?, name: String) {
        func key(_ name: String) -> String { String(name.map { $0.isLetter || $0.isNumber ? $0 : "-" }) }
        let homes = Projects.homes(home)
        var dir = "", rest = Substring(slug)
        while !rest.isEmpty {
            if Projects.guarded(dir, homes: homes) { break }
            let entries = Sys.listDir(dir.isEmpty ? "/" : dir).filter { e in
                let k = key(e)
                return !k.isEmpty && (rest == k || rest.hasPrefix(k + "-"))
            }
            var st = stat()
            guard let e = entries.max(by: { $0.count < $1.count }), lstat(dir + "/" + e, &st) == 0,
                  st.st_mode & S_IFMT != S_IFLNK else { break }
            dir += "/" + e
            rest = rest.dropFirst(e.count).drop { $0 == "-" }
        }
        if rest.isEmpty, !dir.isEmpty, Sys.isDir(dir) { return (dir, ClaudeParser.project(dir)) }
        return (nil, rest.isEmpty ? Sys.basename(dir) : String(rest))
    }
}
