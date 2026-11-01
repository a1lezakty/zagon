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
public struct Archive {
    public let store: Store
    /// `~/.zagon/archive`
    public var dir: String
    /// zstd level (3: best speed/size on transcript-like data, see docs/dev/contracts.md).
    public var level: Int32 = 3
    public var idle: Double = 3600
    /// Tests: runs after the new copy is complete and before it replaces the old one.
    var beforeRename: (() throws -> Void)?

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
    }

    struct File { var id: Int64; var path: String; var agent: String; var size: Int; var mtime: Double? }

    // MARK: pass

    /// One pass over the transcripts Ingest knows (`source_file`): copies what is quiet and new or changed.
    @discardableResult
    public func tick(now: Double = Sys.now()) throws -> Stats {
        var sessions: [String: (tool: String, started: Double?, lastAt: Double?, archivePath: String?, files: [File])] = [:]
        try store.db.query("""
            SELECT f.session_id, f.tool, f.path, f.agent, s.started_at, s.last_at, s.archive_path, f.id
            FROM source_file f LEFT JOIN session s ON s.id = f.session_id WHERE f.session_id IS NOT NULL ORDER BY f.id
            """) { r in
            guard let sid = r.text(0), let path = r.text(2) else { return }
            var st = stat()
            let exists = stat(path, &st) == 0
            let f = File(id: r.int64(7), path: path, agent: r.text(3) ?? "", size: exists ? Int(st.st_size) : -1,
                         mtime: exists ? Archive.mtime(st) : nil)
            sessions[sid, default: (r.text(1) ?? "", r.optReal(4), r.optReal(5), r.text(6), [])].files.append(f)
        }
        var out = Stats()
        for (sid, s) in sessions.sorted(by: { $0.key < $1.key }) {
            let live = s.files.filter { $0.mtime != nil }
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
        if let path, let b = Archive.readLog(path), copy.flatMap(Archive.contentSize).map({ b.count >= $0 }) ?? true { return b }
        guard let copy, Sys.exists(copy) else { return nil }
        var out: [UInt8] = []
        try Archive.decompress(copy) { out.append(contentsOf: $0) }
        return out
    }

    /// A log's bytes, at most about `limit`; one compressed in place (a Codex `<name>.zst`, also when asked for `<name>`,
    /// as `source_file` keeps it) unpacked.
    public static func readLog(_ path: String, limit: Int = .max) -> [UInt8]? {
        let zst = path.hasSuffix(".zst") ? path : !Sys.exists(path) && Sys.exists(path + ".zst") ? path + ".zst" : nil
        guard let zst else { return Sys.readFile(path) }
        struct Enough: Error {}
        var out: [UInt8] = []
        do {
            try decompress(zst) { out.append(contentsOf: $0); if out.count >= limit { throw Enough() } }
        } catch is Enough {
        } catch { return nil }
        return out
    }

    /// Totals over every copy under `dir`.
    public func stats() throws -> Stats {
        var s = Stats()
        var originals = Set<String>()
        try store.db.query("SELECT path FROM source_file") {
            if let p = $0.text(0), Sys.exists(p) || Sys.exists(p + ".zst") { originals.insert(p) }
        }
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

extension String {
    func replacingOccurrences(_ a: String, _ b: String) -> String {
        split(separator: Character(a), omittingEmptySubsequences: false).joined(separator: b)
    }
}
