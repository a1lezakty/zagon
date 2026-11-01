import CSys
import CZstd
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public struct ArchiveError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// zstd copies of transcripts, kept after Claude Code (`cleanupPeriodDays`) or Codex drop the originals:
/// `<dir>/<tool>/<yyyy-mm>/<native id>.jsonl.zst` for the session file and `<native id>/<path under the session
/// dir>.zst` for Claude sub-agents. The copy of each tracked file (`source_file.id`, stable across moves) is fixed
/// once in `meta` (`archive:file:<id>`); a second file that would get a taken name (a session continued in another
/// project dir) gets `-<id>` added. One zstd frame per file with its size in the header and a checksum. A file is (re)written
/// whole once its session has been quiet for `idle` seconds and the original differs from the copy (size or a newer
/// mtime); a gone original never touches its copy. Writes go to `<name>.tmp`, then rename.
/// An organization's retention (`retention`) bounds the Claude copies: see `tick`.
public struct Archive {
    public let store: Store
    /// `~/.zagon/archive`
    public var dir: String
    /// zstd level (3: best speed/size on transcript-like data, see docs/dev/contracts.md).
    public var level: Int32 = 3
    public var idle: Double = 3600
    /// Tests: runs after the new copy is complete and before it replaces the old one.
    var beforeRename: (() throws -> Void)?
    /// Where `tick` reads the retention from (`Archive.retention`); tests point them at temp files.
    var managedDir = Archive.managedSettingsDir, remoteSettings = Archive.remoteSettingsFile

    public init(store: Store, dir: String) { self.store = store; self.dir = dir }

    public struct Stats: Sendable, Equatable {
        /// Sessions with a copy of their main file.
        public var sessions = 0
        public var files = 0
        /// Files written by this pass (`tick` only).
        public var written = 0
        public var rawBytes = 0, packedBytes = 0
        /// Copies whose original is gone (`stats` only).
        public var orphans = 0
        /// Copies removed by this pass for the retention (`tick` only).
        public var removed = 0
    }

    /// `seen`: the mtime Ingest last saw (`source_file.mtime`), for a gone original.
    struct File { var id: Int64; var path: String; var agent: String; var size: Int; var mtime: Double?; var seen: Double? }

    // MARK: pass

    /// One pass over the transcripts Ingest knows (`source_file`): copies what is quiet and new or changed.
    /// With a retention of N days (`Archive.retention`), a Claude file last written more than N days ago (its mtime,
    /// else the one Ingest last saw, else the session's `last_at`; Claude Code deletes by mtime) is not copied, and its
    /// copy is removed with its `meta` key and `session.archive_path`. 0 keeps no Claude copies. Codex copies are not
    /// bound by it.
    @discardableResult
    public func tick(now: Double = Sys.now()) throws -> Stats {
        var sessions: [String: (tool: String, started: Double?, lastAt: Double?, archivePath: String?, files: [File])] = [:]
        try store.db.query("""
            SELECT f.session_id, f.tool, f.path, f.agent, s.started_at, s.last_at, s.archive_path, f.id, f.mtime
            FROM source_file f LEFT JOIN session s ON s.id = f.session_id WHERE f.session_id IS NOT NULL ORDER BY f.id
            """) { r in
            guard let sid = r.text(0), let path = r.text(2) else { return }
            var st = stat()
            let exists = stat(path, &st) == 0
            let f = File(id: r.int64(7), path: path, agent: r.text(3) ?? "", size: exists ? Int(st.st_size) : -1,
                         mtime: exists ? Archive.mtime(st) : nil, seen: r.optReal(8))
            sessions[sid, default: (r.text(1) ?? "", r.optReal(4), r.optReal(5), r.text(6), [])].files.append(f)
        }
        let cutoff = Archive.retention(managedDir: managedDir, remoteSettings: remoteSettings).days.map { now - Double($0) * 86400 }
        var out = Stats()
        for (sid, s) in sessions.sorted(by: { $0.key < $1.key }) {
            var files = s.files
            if let cutoff, s.tool == "claude" {
                let old = Set(files.filter { ($0.mtime ?? $0.seen ?? s.lastAt ?? .infinity) < cutoff }.map(\.id))
                for f in files where old.contains(f.id) { if try drop(f, sessionId: sid) { out.removed += 1 } }
                files.removeAll { old.contains($0.id) }
            }
            let live = files.filter { $0.mtime != nil }
            guard !live.isEmpty, live.allSatisfy({ now - $0.mtime! >= idle }), (s.lastAt ?? 0) <= now - idle else { continue }
            let base = s.archivePath.map { String($0.dropLast(".jsonl.zst".count)) } ?? defaultBase(sid, tool: s.tool,
                at: s.started ?? live.compactMap(\.mtime).min()!)
            var main: String?
            for f in live {
                let target = try copyPath(f, sessionId: sid, base: base)
                if target == base + ".jsonl.zst" { main = target }
                guard Archive.stale(copy: target, size: f.size, mtime: f.mtime!) else { continue }
                let (raw, packed) = try compress(f.path, size: f.size, to: target)
                out.written += 1; out.rawBytes += raw; out.packedBytes += packed
            }
            if let main, main != s.archivePath {
                try store.db.run("UPDATE session SET archive_path = ? WHERE id = ?", [.text(main), .text(sid)])
            }
        }
        return out
    }

    /// Where the copy of a tracked file goes; decided once per file.
    func copyPath(_ f: File, sessionId sid: String, base: String) throws -> String {
        let key = "archive:file:\(f.id)"
        if let p = try store.db.one("SELECT value FROM meta WHERE key = ?", [.text(key)], { $0.text(0) }) ?? nil { return p }
        let native = sid.split(separator: ":", maxSplits: 1).last.map(String.init) ?? sid
        let parts = f.path.split(separator: "/").map(String.init)
        var want = base + ".jsonl.zst"
        if !f.agent.isEmpty {
            // sub-agent: keep its path below the session dir (<project>/<session>/subagents/…)
            let rest = parts.lastIndex(of: native).map { parts[($0 + 1)...] } ?? parts.suffix(1)
            want = base + "/" + rest.joined(separator: "/") + ".zst"
        }
        let taken = try store.db.one("SELECT 1 FROM meta WHERE key LIKE 'archive:file:%' AND value = ?", [.text(want)]) { _ in true } ?? false
        if taken { want = String(want.dropLast(".jsonl.zst".count)) + "-\(f.id).jsonl.zst" }
        try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text(key), .text(want)])
        return want
    }

    /// Removes the copy of a tracked file, then its pointers (`meta`, `session.archive_path`): a crash in between
    /// leaves a pointer to a missing copy, which readers skip and the next pass drops. Empty folders it leaves go too.
    func drop(_ f: File, sessionId sid: String) throws -> Bool {
        let key = "archive:file:\(f.id)"
        guard let p = try store.db.one("SELECT value FROM meta WHERE key = ?", [.text(key)], { $0.text(0) }) ?? nil else { return false }
        let removed = unlink(p) == 0
        var d = Sys.dirname(p)
        while d.hasPrefix(dir + "/"), rmdir(d) == 0 { d = Sys.dirname(d) }
        try store.db.transaction {
            try store.db.run("UPDATE session SET archive_path = NULL WHERE id = ? AND archive_path = ?", [.text(sid), .text(p)])
            try store.db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
        return removed
    }

    func defaultBase(_ sid: String, tool: String, at t: Double) -> String {
        let native = sid.split(separator: ":", maxSplits: 1).last.map(String.init) ?? sid
        var s = time_t(t), v = tm()
        localtime_r(&s, &v)
        let month = "\(v.tm_year + 1900)-" + (v.tm_mon < 9 ? "0" : "") + "\(v.tm_mon + 1)"
        return "\(dir)/\(tool.isEmpty ? "other" : tool)/\(month)/\(native)"
    }

    static func mtime(_ st: stat) -> Double {
        #if canImport(Darwin)
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        #else
        return Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9
        #endif
    }

    /// The copy is missing, holds another size, or is older than the original.
    static func stale(copy: String, size: Int, mtime: Double) -> Bool {
        var st = stat()
        guard stat(copy, &st) == 0, let n = contentSize(copy) else { return true }
        return n != size || mtime > Archive.mtime(st)
    }

    /// Original size from the frame header.
    public static func contentSize(_ path: String) -> Int? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var h = [UInt8](repeating: 0, count: 18)
        let n = h.withUnsafeMutableBytes { read(fd, $0.baseAddress, 18) }
        guard n > 0 else { return nil }
        let v = ZSTD_getFrameContentSize(h, n)
        return v == ZSTD_CONTENTSIZE_UNKNOWN || v == ZSTD_CONTENTSIZE_ERROR ? nil : Int(v)
    }

    // MARK: zstd

    /// Compresses the first `size` bytes of `src` into `dst` (atomically); returns (raw, packed) bytes.
    func compress(_ src: String, size: Int, to dst: String) throws -> (Int, Int) {
        guard Sys.mkdirs(Sys.dirname(dst)) else { throw ArchiveError("cannot create \(Sys.dirname(dst))") }
        let inFD = open(src, O_RDONLY | O_CLOEXEC)
        guard inFD >= 0 else { throw ArchiveError("cannot open \(src)") }
        defer { close(inFD) }
        let tmp = dst + ".tmp"
        let outFD = Sys.createExclusive(tmp)
        guard outFD >= 0 else { throw ArchiveError("cannot write \(tmp)") }
        var ok = false
        defer { if !ok { close(outFD); unlink(tmp) } }
        guard let cctx = ZSTD_createCCtx() else { throw ArchiveError("zstd: no memory") }
        defer { ZSTD_freeCCtx(cctx) }
        ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, level)
        ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, 1)
        ZSTD_CCtx_setPledgedSrcSize(cctx, UInt64(size))
        var inBuf = [UInt8](repeating: 0, count: ZSTD_CStreamInSize())
        var outBuf = [UInt8](repeating: 0, count: ZSTD_CStreamOutSize())
        var left = size, packed = 0
        while true {
            let n = left == 0 ? 0 : inBuf.withUnsafeMutableBytes { read(inFD, $0.baseAddress, min(left, $0.count)) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0, n > 0 || left == 0 else { throw ArchiveError("\(src) got shorter while archiving") }
            left -= n
            let last = left == 0
            try inBuf.withUnsafeBytes { ib in
                var input = ZSTD_inBuffer(src: ib.baseAddress, size: n, pos: 0)
                while true {
                    let (rem, written): (Int, Int) = outBuf.withUnsafeMutableBytes { ob in
                        var output = ZSTD_outBuffer(dst: ob.baseAddress, size: ob.count, pos: 0)
                        let r = ZSTD_compressStream2(cctx, &output, &input, last ? ZSTD_e_end : ZSTD_e_continue)
                        return (ZSTD_isError(r) != 0 ? -1 : r, output.pos)
                    }
                    guard rem >= 0 else { throw ArchiveError("zstd: compression failed on \(src)") }
                    guard Sys.writeAll(fd: outFD, Array(outBuf[0..<written])) else { throw ArchiveError("cannot write \(tmp)") }
                    packed += written
                    if last ? rem == 0 : input.pos == input.size { break }
                }
            }
            if last { break }
        }
        guard fsync(outFD) == 0 else { throw ArchiveError("cannot write \(tmp)") }
        z_drop_cache(outFD); z_drop_cache(inFD)  // written / read once: keep them out of the page cache
        close(outFD)
        ok = true
        do { try beforeRename?() } catch { unlink(tmp); throw error }
        guard rename(tmp, dst) == 0 else { unlink(tmp); throw ArchiveError("cannot replace \(dst)") }
        return (size, packed)
    }

    /// Streams the original bytes of a copy to `body`; throws on a damaged or cut copy.
    public static func decompress(_ path: String, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveError("cannot open \(path)") }
        defer { close(fd) }
        guard let dctx = ZSTD_createDCtx() else { throw ArchiveError("zstd: no memory") }
        defer { ZSTD_freeDCtx(dctx) }
        var inBuf = [UInt8](repeating: 0, count: ZSTD_DStreamInSize())
        var outBuf = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var pending = 1  // 0 = the last frame is complete
        while true {
            let n = inBuf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw ArchiveError("cannot read \(path)") }
            if n == 0 { break }
            try inBuf.withUnsafeBytes { ib in
                var input = ZSTD_inBuffer(src: ib.baseAddress, size: n, pos: 0)
                while input.pos < input.size {
                    var produced = 0
                    let r: Int = outBuf.withUnsafeMutableBytes { ob in
                        var output = ZSTD_outBuffer(dst: ob.baseAddress, size: ob.count, pos: 0)
                        let r = ZSTD_decompressStream(dctx, &output, &input)
                        produced = output.pos
                        return ZSTD_isError(r) != 0 ? -1 : r
                    }
                    guard r >= 0 else { throw ArchiveError("\(path) is damaged") }
                    if produced > 0 { try outBuf.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[0..<produced])) } }
                    pending = r
                }
            }
        }
        guard pending == 0 else { throw ArchiveError("\(path) is cut short") }
    }

    // MARK: reading

    /// Session id from `claude:<id>`, `<id>` or a unique id prefix.
    public func resolve(_ s: String) throws -> String? {
        var ids: [String] = []
        try store.db.query("SELECT id FROM session WHERE id = ?1 OR id LIKE ?2 ESCAPE '\\' ORDER BY id LIMIT 2",
                           [.text(s), .text("%:" + s.replacingOccurrences("%", "\\%").replacingOccurrences("_", "\\_") + "%")]) {
            if let id = $0.text(0) { ids.append(id) }
        }
        return ids.first == s || ids.count == 1 ? ids.first : nil
    }

    /// The session's main transcript: the original while it is complete, else the archived copy (for handoff and
    /// search after Claude Code or Codex dropped the file). Nil when neither exists.
    public func transcript(_ sessionId: String) throws -> [UInt8]? {
        let row = try store.db.one("""
            SELECT f.path, s.archive_path FROM session s LEFT JOIN source_file f ON f.session_id = s.id AND f.agent = ''
            WHERE s.id = ?
            """, [.text(sessionId)]) { ($0.text(0), $0.text(1)) }
        guard let (path, copy) = row else { return nil }
        if let path, let b = Sys.readFile(path), copy.flatMap(Archive.contentSize).map({ b.count >= $0 }) ?? true { return b }
        guard let copy, Sys.exists(copy) else { return nil }
        var out: [UInt8] = []
        try Archive.decompress(copy) { out.append(contentsOf: $0) }
        return out
    }

    /// Totals over every copy under `dir`.
    public func stats() throws -> Stats {
        var s = Stats()
        var originals = Set<String>()
        try store.db.query("SELECT path FROM source_file") { if let p = $0.text(0), Sys.exists(p) { originals.insert(p) } }
        var mains: [String: String] = [:]  // copy -> original
        try store.db.query("""
            SELECT s.archive_path, f.path FROM session s LEFT JOIN source_file f ON f.session_id = s.id AND f.agent = ''
            WHERE s.archive_path IS NOT NULL
            """) { if let a = $0.text(0) { mains[a] = $0.text(1) ?? "" } }
        Archive.walk(dir) { path in
            guard path.hasSuffix(".jsonl.zst") else { return }
            s.files += 1
            s.packedBytes += Sys.fileSize(path) ?? 0
            s.rawBytes += Archive.contentSize(path) ?? 0
            if let orig = mains[path] { s.sessions += 1; if !originals.contains(orig) { s.orphans += 1 } }
        }
        return s
    }

    static func walk(_ dir: String, _ body: (String) -> Void) {
        for name in Sys.listDir(dir) {
            let p = dir + "/" + name
            if Sys.isDir(p) { walk(p, body) } else { body(p) }
        }
    }
}

// MARK: retention

extension Archive {
    /// The folder of Claude Code's file-based managed settings (`managed-settings.json`, `managed-settings.d/*.json`).
    #if os(macOS)
    public static let managedSettingsDir = "/Library/Application Support/ClaudeCode"
    #else
    public static let managedSettingsDir = "/etc/claude-code"
    #endif
    /// Claude Code's copy of the organization's server-managed settings.
    public static var remoteSettingsFile: String {
        (Sys.env("CLAUDE_CONFIG_DIR") ?? (Sys.env("HOME") ?? "") + "/.claude") + "/remote-settings.json"
    }

    /// How long the archive may keep Claude Code transcripts: the `cleanupPeriodDays` an organization set in Claude
    /// Code's managed settings, and the file it came from (`source`); `(nil, nil)` = none set, copies are kept for
    /// good. Server-managed settings (`remoteSettings`) win over the files; among the files `managed-settings.json` is
    /// read first, then `managed-settings.d/*.json` (not dot files) in name order, a later file overriding an earlier
    /// one. A value that is not a whole number >= 0 is ignored (Claude Code rejects it too). `days == 0`: Claude Code
    /// now rejects 0 (it used to turn transcripts off); the archive takes it as "keep nothing". The user's own
    /// `~/.claude/settings.json` does not count: keeping beyond it is what the archive is for. Not read: macOS
    /// configuration profiles (MDM) and the Windows registry.
    public static func retention(managedDir: String = managedSettingsDir,
                                 remoteSettings: String = remoteSettingsFile) -> (days: Int?, source: String?) {
        func days(_ path: String) -> Int? {
            guard !Sys.isDir(path), let b = Sys.readFile(path), let d = JValue.parse(b)?["cleanupPeriodDays"]?.double,
                  d >= 0, d < 1e6, d == d.rounded(.down) else { return nil }
            return Int(d)
        }
        if let d = days(remoteSettings) { return (d, remoteSettings) }
        let dropIns = managedDir + "/managed-settings.d"
        let files = [managedDir + "/managed-settings.json"]
            + Sys.listDir(dropIns).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { dropIns + "/" + $0 }
        var out: (days: Int?, source: String?) = (nil, nil)
        for f in files { if let d = days(f) { out = (d, f) } }
        return out
    }
}

extension String {
    func replacingOccurrences(_ a: String, _ b: String) -> String {
        split(separator: Character(a), omittingEmptySubsequences: false).joined(separator: b)
    }
}
