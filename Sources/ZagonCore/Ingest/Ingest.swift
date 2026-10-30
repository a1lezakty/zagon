import CSys
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
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

public struct IngestOptions: Sendable {
    /// User time: actions closer than this are one stretch of work.
    public var idleGap: Double = 20 * 60
    /// Session time: agent silence longer than this ends a working interval.
    public var sessionGap: Double = 30 * 60
    /// How long request ids stay in the dedup ledger.
    public var dedupDays: Double = 40
    /// Feed typed messages and titles into the contentless search index.
    public var indexPrompts = true
    /// Task keys looked for in typed messages (`task_key`); nil = off. `[tasks] key_pattern` in config.toml.
    public var keyPattern: String? = IngestOptions.defaultKeyPattern
    public static let defaultKeyPattern = #"[A-Z][A-Z0-9]+-\d+"#
    /// nil = the database's own host (`Store.host`); set only to import another machine's data.
    public var host: String?
    /// Apply parsed records to the database after this many bytes (bounds memory on huge files).
    public var applyBytes = 16 << 20
    /// A full scan commits after this many bytes of new data (several files per transaction: far less WAL traffic).
    public var batchBytes = 64 << 20
    public init() {}
}

public struct IngestStats: Sendable, Codable {
    public var filesSeen = 0, filesRead = 0, bytes = 0, lines = 0, badLines = 0, resets = 0, moves = 0, usageRecords = 0
    /// Files recounted from their archive copy (the original is gone; schema v5 recount).
    public var fromArchive = 0
    public var seconds = 0.0, parseSeconds = 0.0, applySeconds = 0.0, deriveSeconds = 0.0
}

/// Tails line-oriented logs into the Store. Per file: offset + inode + size + tail bytes; a partial last line waits
/// for its newline; a truncated or replaced file has its whole contribution retracted and is recounted from 0.
/// Each file is processed inside one BEGIN IMMEDIATE transaction (a scan groups several files into one), so a crash
/// or a concurrent process never double counts.
public final class Ingest {
    public let store: Store
    public let sources: [SourceSpec]
    public let options: IngestOptions
    /// Host written into sessions and `day_agg`: `options.host` or the database's own.
    public let host: String
    let keys: Regex<AnyRegexOutput>?
    public private(set) var stats = IngestStats()
    var db: SQLite { store.db }

    // Pending derived work, done once in finish().
    var touchedHours = Set<Int>()
    var touchedSessions = Set<String>()
    var userActionsChanged = false

    public init(store: Store, sources: [SourceSpec], options: IngestOptions = IngestOptions()) {
        self.store = store; self.sources = sources; self.options = options
        host = options.host ?? store.host
        keys = options.keyPattern.flatMap { try? Regex($0) }  // an invalid pattern turns key extraction off
    }

    /// One pass over all sources (sorted by path, so a fresh scan is deterministic), then derived tables.
    @discardableResult
    public func scan() throws -> IngestStats {
        let t0 = Time.monotonic()
        stats = IngestStats()
        try checkTimezone()
        let files = sources.flatMap { src in Ingest.walk(src.root).filter(src.accepts).sorted().map { (src, $0) } }
        var i = 0
        while i < files.count {
            try db.transaction {
                let start = stats.bytes
                while i < files.count, stats.bytes - start < options.batchBytes {
                    let (src, rel) = files[i]
                    stats.filesSeen += 1
                    try ingest(path: src.root + "/" + rel, relative: rel, source: src)
                    i += 1
                }
            }
        }
        try recountGone()
        try finish()
        stats.seconds = Time.monotonic() - t0
        return stats
    }

    /// Days are cut in the zone of this process. When it differs from the one the day rows were built in (or that
    /// is unknown), every day of this host is rebuilt by the next `finish()`.
    func checkTimezone(_ id: String = Settings.timezoneID()) throws {
        let stored = try db.one("SELECT value FROM meta WHERE key='tz'") { $0.text(0) } ?? nil
        guard stored != id else { return }
        try db.transaction {
            // Days this host has are rebuilt in the new zone, not deleted: one left empty keeps a zero totals row
            // (DayAggregator), so `export` tells clients to drop it.
            try db.query("SELECT DISTINCT day FROM day_agg WHERE host=?", [.text(host)]) { r in
                if let d = r.text(0), let (s, _) = Time.dayBounds(d) { touchedHours.insert(Time.hour(s)) }
            }
            for sql in ["SELECT DISTINCT hour FROM usage_hour", "SELECT DISTINCT hour FROM tool_use", "SELECT start FROM activity",
                        "SELECT \"end\" FROM activity", "SELECT ts FROM user_action"] {
                try db.query(sql) { touchedHours.insert(Time.hour($0.real(0))) }
            }
            try db.run("INSERT INTO meta(key, value) VALUES('tz', ?1) ON CONFLICT(key) DO UPDATE SET value = ?1", [.text(id)])
        }
    }

    // MARK: one file

    struct FileRow {
        var id: Int64 = 0
        var inode = 0, size = 0, offset = 0
        var mtime: Double?
        var tail: [UInt8] = []
        var parserState: String?
        var activityState: String?
        var sessionId: String?
        var agent = ""
        var badLines = 0
        var resets = 0
        /// Count the file again from byte 0 (schema v5: fills the request directory and the 1-hour cache split).
        var recount = false
    }

    public func ingest(path: String, relative: String, source: SourceSpec) throws {
        var sb = stat()
        guard stat(path, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFREG else { return }
        let ino = Int(sb.st_ino), size = Int(sb.st_size)
        #if canImport(Darwin)
        let mtime = Double(sb.st_mtimespec.tv_sec) + Double(sb.st_mtimespec.tv_nsec) / 1e9
        #else
        let mtime = Double(sb.st_mtim.tv_sec) + Double(sb.st_mtim.tv_nsec) / 1e9
        #endif
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }

        try db.transaction {
            var f: FileRow
            var known = try loadFile(path)
            if known == nil, let m = try movedFile(tool: source.tool, inode: ino, size: size, fd: fd) {
                // Renamed or moved between roots of this tool (Codex sessions/ -> archived_sessions/): the same file,
                // so only the path changes; its contribution stays and tailing continues from the stored offset.
                try db.run("UPDATE source_file SET path=? WHERE id=?", [.text(path), .int(m.id)])
                stats.moves += 1
                known = m
            }
            if let row = known {
                f = row
                let replaced = f.inode != ino || size < f.offset || !tailMatches(fd, f)
                if replaced || f.recount {
                    try restart(&f)
                    if replaced { f.resets += 1; stats.resets += 1 }
                } else if size == f.offset {
                    return
                }
            } else {
                try db.run("INSERT INTO source_file(path, tool) VALUES(?, ?)", [.text(path), .text(source.tool.rawValue)])
                f = FileRow(id: db.lastInsertRowID)
            }
            f.inode = ino; f.size = size; f.mtime = mtime
            try read(fd: fd, file: &f, path: path, relative: relative, source: source)
            // A file quiet for an hour is read once (full pass, catch-up): drop it from the page cache.
            if mtime < Time.now() - 3600 { z_drop_cache(fd) }
            try save(f)
        }
    }

    func save(_ f: FileRow) throws {
        try db.run("""
            UPDATE source_file SET inode=?, size=?, offset=?, mtime=?, tail=?, parser_state=?, activity_state=?,
              session_id=?, agent=?, bad_lines=?, resets=?, recount=0 WHERE id=?
            """, [.int(Int64(f.inode)), .int(Int64(f.size)), .int(Int64(f.offset)), .of(f.mtime), .blob(f.tail),
                  .of(f.parserState), .of(f.activityState), .of(f.sessionId), .text(f.agent),
                  .int(Int64(f.badLines)), .int(Int64(f.resets)), .int(f.id)])
    }

    /// Takes back everything the file contributed; it is read again from byte 0.
    func restart(_ f: inout FileRow) throws {
        try retract(f.id)
        f.offset = 0; f.tail = []; f.parserState = nil; f.activityState = nil; f.sessionId = nil; f.agent = ""
        f.badLines = 0
    }

    /// Files still due for the v5 recount after a pass whose original is gone (Claude Code / Codex dropped it): counted
    /// again from the archive copy when it holds at least what was counted, else their rows stay as they are. A file
    /// that exists but was not walked (another root this time) waits for a pass that sees it.
    func recountGone() throws {
        var due: [(id: Int64, path: String)] = []
        try db.query("SELECT id, path FROM source_file WHERE recount = 1") { if let p = $0.text(1) { due.append(($0.int64(0), p)) } }
        for d in due where !Sys.exists(d.path) {
            try db.transaction {
                guard var f = try loadFile(d.path) else { return }
                defer { _ = try? db.run("UPDATE source_file SET recount = 0 WHERE id = ?", [.int(f.id)]) }
                guard let src = sources.first(where: { d.path.hasPrefix($0.root + "/") }),
                      case let rel = String(d.path.dropFirst(src.root.count + 1)), src.accepts(rel),
                      let copy = try db.one("SELECT value FROM meta WHERE key = ?", [.text("archive:file:\(f.id)")], { $0.text(0) }) ?? nil,
                      let n = Archive.contentSize(copy), n >= f.offset else { return }
                // Unpacked next to the database (the copy's protection, not /tmp), read like the original, dropped.
                let tmp = (try db.one("SELECT file FROM pragma_database_list WHERE name = 'main'") { $0.text(0) } ?? nil)
                    .flatMap { $0.isEmpty ? nil : $0 } .map { $0 + ".recount" } ?? copy + ".recount"
                let out = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
                guard out >= 0 else { return }
                defer { unlink(tmp) }
                do {
                    try Archive.decompress(copy) { b in
                        guard Sys.writeAll(fd: out, Array(b)) else { throw ArchiveError("cannot write \(tmp)") }
                    }
                    close(out)
                } catch { close(out); return }
                let fd = open(tmp, O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { return }
                defer { close(fd) }
                try restart(&f)
                f.size = n
                try read(fd: fd, file: &f, path: d.path, relative: rel, source: src)
                stats.fromArchive += 1
                try save(f)
            }
        }
    }

    func loadFile(_ path: String) throws -> FileRow? {
        try db.one("""
            SELECT id, inode, size, offset, mtime, tail, parser_state, activity_state, session_id, agent, bad_lines, resets,
                   recount
            FROM source_file WHERE path=?
            """, [.text(path)]) { r in
            FileRow(id: r.int64(0), inode: r.int(1), size: r.int(2), offset: r.int(3), mtime: r.optReal(4), tail: r.blob(5),
                    parserState: r.text(6), activityState: r.text(7), sessionId: r.text(8), agent: r.text(9) ?? "",
                    badLines: r.int(10), resets: r.int(11), recount: r.int(12) != 0)
        }
    }

    /// A known file of `tool` with this inode whose old path is gone, not longer than the file and with the same
    /// bytes before its offset. A path that still has this inode is a hard link, not a move.
    func movedFile(tool: ToolKind, inode: Int, size: Int, fd: Int32) throws -> FileRow? {
        var paths: [String] = []
        try db.query("SELECT path FROM source_file WHERE tool=? AND inode=?", [.text(tool.rawValue), .int(Int64(inode))]) {
            if let p = $0.text(0) { paths.append(p) }
        }
        for old in paths {
            var sb = stat()
            if stat(old, &sb) == 0, Int(sb.st_ino) == inode { continue }
            if let row = try loadFile(old), size >= row.offset, tailMatches(fd, row) { return row }
        }
        return nil
    }

    static let tailLength = 64

    /// The bytes just before the stored offset are unchanged (detects a file rewritten in place to a larger size).
    func tailMatches(_ fd: Int32, _ f: FileRow) -> Bool {
        guard f.offset > 0 else { return true }
        let k = min(f.offset, Ingest.tailLength)
        var b = [UInt8](repeating: 0, count: k)
        let n = b.withUnsafeMutableBytes { pread(fd, $0.baseAddress, k, off_t(f.offset - k)) }
        return n == k && b == f.tail
    }

    func read(fd: Int32, file f: inout FileRow, path: String, relative: String, source: SourceSpec) throws {
        var parser = source.makeParser(path, relative, f.parserState)
        var turns = f.activityState.flatMap { try? JSONDecoder().decode(TurnBuilder.self, from: Data($0.utf8)) } ?? TurnBuilder()
        var out = ParseOutput()
        lseek(fd, off_t(f.offset), SEEK_SET)
        stats.filesRead += 1
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var filled = 0, sinceApply = 0
        while true {
            if filled == buf.count { buf.append(contentsOf: repeatElement(0, count: buf.count)) } // a line longer than buf
            let r = buf.withUnsafeMutableBytes { Glibc_read(fd, $0.baseAddress! + filled, $0.count - filled) }
            if r <= 0 { break }
            filled += r
            var start = 0
            let tp = Time.monotonic()
            defer { stats.parseSeconds += Time.monotonic() - tp }
            buf.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                while start < filled, let nl = memchr(base + start, 0x0A, filled - start) {
                    let len = (base + start).distance(to: UnsafeRawPointer(nl))
                    if len > 0 {
                        stats.lines += 1
                        parser.parse(line: UnsafeRawBufferPointer(start: base + start, count: len), into: &out)
                    }
                    start += len + 1
                }
            }
            if start > 0 {
                // Keep the tail bytes ending at the new offset (only complete lines are consumed).
                let k = Ingest.tailLength
                f.tail = start >= k ? Array(buf[(start - k)..<start]) : Array((f.tail + buf[0..<start]).suffix(k))
                f.offset += start; sinceApply += start; stats.bytes += start
                buf.withUnsafeMutableBytes { _ = memmove($0.baseAddress!, $0.baseAddress! + start, filled - start) }
                filled -= start
            }
            if sinceApply >= options.applyBytes {
                try apply(&out, file: &f, turns: &turns)
                sinceApply = 0
            }
        }
        try apply(&out, file: &f, turns: &turns)
        f.parserState = parser.saveState()
        f.activityState = turns.open.isEmpty ? nil : (try? JSONEncoder().encode(turns)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: apply parsed records

    struct UsageKey: Hashable { var session: String; var agent: String; var hour: Int; var model: String; var cwd: String }
    struct Counts { var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cacheWrite1h = 0, requests = 0
        mutating func add(_ u: UsageRecord, _ sign: Int) {
            input += sign * u.input; output += sign * u.output; cacheRead += sign * u.cacheRead
            cacheWrite += sign * u.cacheWrite; cacheWrite1h += sign * u.cacheWrite1h; requests += sign
        }
    }
    struct ToolKey: Hashable { var session: String; var hour: Int; var name: String }
    /// What the ledger counted for one request id.
    struct LedgerEntry { var file: Int64; var hour: Int; var model: String; var u: UsageRecord }

    func apply(_ out: inout ParseOutput, file f: inout FileRow, turns: inout TurnBuilder) throws {
        let t0 = Time.monotonic()
        defer { out = ParseOutput(); stats.applySeconds += Time.monotonic() - t0 }
        f.badLines += out.badLines
        stats.badLines += out.badLines
        stats.usageRecords += out.usage.count
        guard !out.isEmpty else { return }
        if f.sessionId == nil {
            f.sessionId = out.usage.first?.sessionId ?? out.events.first?.sessionId ?? out.userMessages.first?.sessionId
                ?? out.meta.first?.id
        }
        if f.agent.isEmpty, let a = out.usage.first?.agent { f.agent = a }
        let fileSession = f.sessionId ?? "?"

        // Sessions referenced by this batch exist (tool from the id prefix `<tool>:`).
        var sessions = Set<String>()
        for m in out.meta { sessions.insert(m.id) }
        for u in out.usage { sessions.insert(u.messageId == nil ? u.sessionId : fileSession) }
        for e in out.events { sessions.insert(e.sessionId) }
        for m in out.userMessages { sessions.insert(m.sessionId) }
        for s in sessions {
            let tool = s.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "claude"
            try db.run("INSERT OR IGNORE INTO session(id, tool, host, seq) VALUES(?, ?, ?, 0)",
                       [.text(s), .text(tool), .text(host)])
        }
        touchedSessions.formUnion(sessions)
        for m in out.meta { try store.mergeSession(m, host: host) }
        // Readings, not contributions: keyed by (tool, window, ts), so a recount writes the same rows again.
        for l in out.limits { try store.addLimitSnapshot(l) }

        // Usage with the request-id ledger.
        var deltas: [UsageKey: Counts] = [:]
        var ledger: [Int64: LedgerEntry?] = [:]
        var dirty = Set<Int64>()
        func lookup(_ h: Int64) throws -> LedgerEntry? {
            if let e = ledger[h] { return e }
            let e = try db.one("""
                SELECT file_id, hour, model, input, output, cache_read, cache_write, cache_write_1h, cwd FROM msg WHERE id=?
                """, [.int(h)]) { r in
                LedgerEntry(file: r.int64(0), hour: r.int(1), model: r.text(2) ?? "",
                            u: UsageRecord(sessionId: "", ts: 0, model: r.text(2) ?? "", input: r.int(3), output: r.int(4),
                                           cacheRead: r.int(5), cacheWrite: r.int(6), cacheWrite1h: r.int(7), cwd: r.text(8)))
            }
            ledger[h] = .some(e)
            return e
        }
        for u in out.usage {
            let hour = Time.hour(u.ts)
            touchedHours.insert(hour)
            guard let id = u.messageId else {
                deltas[UsageKey(session: u.sessionId, agent: u.agent, hour: hour, model: u.model, cwd: u.cwd ?? ""),
                       default: Counts()].add(u, 1)
                continue
            }
            let h = fnv1a64(id)
            let key = UsageKey(session: fileSession, agent: f.agent, hour: hour, model: u.model, cwd: u.cwd ?? "")
            if let e = try lookup(h) {
                guard e.file == f.id else { continue } // the same request copied into another file
                // Last record wins: take back what was counted, count the new values.
                deltas[UsageKey(session: fileSession, agent: f.agent, hour: e.hour, model: e.model, cwd: e.u.cwd ?? ""),
                       default: Counts()].add(e.u, -1)
                touchedHours.insert(e.hour)
            }
            deltas[key, default: Counts()].add(u, 1)
            ledger[h] = .some(LedgerEntry(file: f.id, hour: hour, model: u.model, u: u))
            dirty.insert(h)
        }
        for h in dirty {
            guard let e = ledger[h] ?? nil else { continue }
            try db.run("""
                INSERT OR REPLACE INTO msg(id, file_id, hour, model, input, output, cache_read, cache_write, cache_write_1h, cwd)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """, [.int(h), .int(e.file), .int(Int64(e.hour)), .text(e.model), .int(Int64(e.u.input)),
                      .int(Int64(e.u.output)), .int(Int64(e.u.cacheRead)), .int(Int64(e.u.cacheWrite)),
                      .int(Int64(e.u.cacheWrite1h)), .of(e.u.cwd)])
        }
        for (k, c) in deltas {
            try db.run("""
                INSERT INTO usage_hour(file_id, session_id, agent, hour, model, cwd, input, output, cache_read, cache_write,
                  cache_write_1h, requests)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO UPDATE SET input=input+excluded.input,
                  output=output+excluded.output, cache_read=cache_read+excluded.cache_read,
                  cache_write=cache_write+excluded.cache_write, cache_write_1h=cache_write_1h+excluded.cache_write_1h,
                  requests=requests+excluded.requests
                """, [.int(f.id), .text(k.session), .text(k.agent), .int(Int64(k.hour)), .text(k.model), .text(k.cwd),
                      .int(Int64(c.input)), .int(Int64(c.output)), .int(Int64(c.cacheRead)), .int(Int64(c.cacheWrite)),
                      .int(Int64(c.cacheWrite1h)), .int(Int64(c.requests))])
        }
        if deltas.values.contains(where: { $0.requests < 0 }) {
            try db.run("DELETE FROM usage_hour WHERE file_id=? AND requests<=0", [.int(f.id)])
        }

        // Tool calls, deduplicated by call id (rewritten records repeat their blocks).
        var tools: [ToolKey: Int] = [:]
        for t in out.tools {
            let hour = Time.hour(t.ts)
            if let cid = t.callId {
                let h = fnv1a64("call:" + cid)
                if ledger[h] != nil { continue }
                if try db.one("SELECT 1 FROM msg WHERE id=?", [.int(h)], { _ in true }) == true { continue }
                ledger[h] = .some(nil)
                try db.run("INSERT INTO msg(id, file_id, hour, model, input, output, cache_read, cache_write) VALUES(?,?,?,'',0,0,0,0)",
                           [.int(h), .int(f.id), .int(Int64(hour))])
            }
            tools[ToolKey(session: t.sessionId, hour: hour, name: t.name), default: 0] += 1
        }
        for (k, n) in tools {
            try db.run("""
                INSERT INTO tool_use(file_id, session_id, hour, name, n) VALUES(?,?,?,?,?)
                ON CONFLICT DO UPDATE SET n=n+excluded.n
                """, [.int(f.id), .text(k.session), .int(Int64(k.hour)), .text(k.name), .int(Int64(n))])
        }

        // Typing into a terminal: decides later whether a message in another session was the human's.
        for r in out.relays {
            for target in r.targets {
                try db.run("INSERT INTO relay(file_id, session_id, ts, target) VALUES(?,?,?,?)",
                           [.int(f.id), .text(r.sessionId), .real(r.ts), .text(target)])
            }
            touchedHours.insert(Time.hour(r.ts))
            userActionsChanged = true
        }

        // Working intervals and user actions, in time order.
        var points: [(ts: Timestamp, session: String, user: Bool, text: String?, cwd: String?, channel: Bool)] = []
        points.reserveCapacity(out.events.count + out.userMessages.count)
        for e in out.events { points.append((e.ts, e.sessionId, false, nil, e.cwd, false)) }
        for m in out.userMessages { points.append((m.ts, m.sessionId, true, m.text, m.cwd, m.channel)) }
        points.sort { $0.ts < $1.ts }
        var t = TurnBuilder.Output()
        for p in points {
            if p.user {
                let before = t.actions.count
                turns.user(p.session, p.ts, cwd: p.cwd, kind: p.channel ? "channel" : "msg", idleGap: options.idleGap,
                           into: &t)
                // Only messages taken as actions: copies of history in a resumed or forked file are skipped.
                guard t.actions.count > before, let text = p.text, !text.isEmpty else { continue }
                if options.indexPrompts { try indexText(text, file: f.id, session: p.session, ts: p.ts, kind: "msg") }
                for k in taskKeys(text) {
                    try db.run("INSERT OR IGNORE INTO task_key(file_id, session_id, key, at) VALUES(?,?,?,?)",
                               [.int(f.id), .text(p.session), .text(k), .real(p.ts)])
                }
            } else {
                turns.agent(p.session, p.ts, cwd: p.cwd, sessionGap: options.sessionGap, into: &t)
            }
        }
        for c in t.closed { try putWorking(file: f.id, session: c.session, c.interval, cwd: c.cwd) }
        for (s, iv) in turns.open { try putWorking(file: f.id, session: s, iv, cwd: turns.cwd(of: s)) }
        for a in t.actions {
            try db.run("INSERT INTO user_action(file_id, session_id, ts, kind) VALUES(?,?,?,?)",
                       [.int(f.id), .text(a.session), .real(a.ts), .text(a.kind)])
            touchedHours.insert(Time.hour(a.ts))
            userActionsChanged = true
        }
    }

    /// Writes an interval keyed by (file, session, start); rewriting it is idempotent (an open interval grows).
    func putWorking(file: Int64, session: String, _ iv: Interval, cwd: String?) throws {
        try db.run("DELETE FROM activity WHERE file_id=? AND session_id=? AND start=? AND kind='working'",
                   [.int(file), .text(session), .real(iv.start)])
        try db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind, cwd) VALUES(?,?,?,?,'working',?)",
                   [.int(file), .text(session), .real(iv.start), .real(iv.end), .of(cwd)])
        var h = Time.hour(iv.start)
        while h <= Time.hour(iv.end) { touchedHours.insert(h); h += 86400 }
        touchedHours.insert(Time.hour(iv.end))
    }

    /// Distinct task keys in a typed message, upper-cased; a match glued to a letter or digit before it is not a key.
    func taskKeys(_ text: String) -> [String] {
        guard let keys else { return [] }
        var out: [String] = []
        for m in text.matches(of: keys) {
            if m.range.lowerBound > text.startIndex {
                let c = text[text.index(before: m.range.lowerBound)]
                if c.isLetter || c.isNumber { continue }
            }
            let k = text[m.range].uppercased()
            if !out.contains(k) { out.append(k) }
        }
        return out
    }

    func indexText(_ text: String, file: Int64?, session: String, ts: Timestamp?, kind: String) throws {
        try db.run("INSERT INTO fts_doc(file_id, session_id, ts, kind) VALUES(?,?,?,?)",
                   [file.map { .int($0) } ?? .null, .text(session), .of(ts), .text(kind)])
        try db.run("INSERT INTO fts(rowid, body) VALUES(?, ?)", [.int(db.lastInsertRowID), .text(text)])
    }

    /// Removes everything a file contributed (it was truncated or replaced; it is recounted from byte 0).
    func retract(_ file: Int64) throws {
        let id: [SQLValue] = [.int(file)]
        for sql in ["SELECT DISTINCT hour FROM usage_hour WHERE file_id=?", "SELECT DISTINCT hour FROM tool_use WHERE file_id=?",
                    "SELECT start FROM activity WHERE file_id=?", "SELECT \"end\" FROM activity WHERE file_id=?",
                    "SELECT ts FROM user_action WHERE file_id=?"] {
            try db.query(sql, id) { r in touchedHours.insert(Time.hour(r.real(0))) }
        }
        for t in ["usage_hour", "tool_use", "activity", "user_action"] {
            try db.query("SELECT DISTINCT session_id FROM \(t) WHERE file_id=?", id) { r in
                if let s = r.text(0) { touchedSessions.insert(s) }
            }
        }
        var docs: [Int64] = []
        try db.query("SELECT rowid FROM fts_doc WHERE file_id=?", id) { docs.append($0.int64(0)) }
        for d in docs { try db.run("DELETE FROM fts WHERE rowid=?", [.int(d)]) }
        for t in ["usage_hour", "tool_use", "msg", "activity", "user_action", "fts_doc", "task_key", "relay"] {
            try db.run("DELETE FROM \(t) WHERE file_id=?", id)
        }
        userActionsChanged = true
    }

    // MARK: derived tables

    /// Ledger pruning, session rollups, user time and day aggregates for everything touched since the last call.
    public func finish() throws {
        let t0 = Time.monotonic()
        defer { stats.deriveSeconds += Time.monotonic() - t0 }
        try db.transaction {
            try db.run("DELETE FROM msg WHERE hour < ?", [.real(Time.now() - options.dedupDays * 86400)])
            if !touchedSessions.isEmpty {
                let seq = try store.nextSeq()
                for s in touchedSessions {
                    try db.run("""
                        UPDATE session SET
                          started_at = (SELECT min(t) FROM (SELECT min(start) t FROM activity WHERE session_id=?1 AND file_id IS NOT NULL
                                        UNION ALL SELECT min(ts) FROM user_action WHERE session_id=?1)),
                          last_at = (SELECT max(t) FROM (SELECT max("end") t FROM activity WHERE session_id=?1 AND file_id IS NOT NULL
                                     UNION ALL SELECT max(ts) FROM user_action WHERE session_id=?1)),
                          seq = ?2
                        WHERE id=?1
                        """, [.text(s), .int(Int64(seq))])
                    // Listed by the directory it started in, not the last one it visited.
                    if let c = try db.one("""
                        SELECT cwd FROM activity WHERE session_id = ? AND cwd IS NOT NULL AND file_id IS NOT NULL ORDER BY start LIMIT 1
                        """, [.text(s)], { $0.text(0) }) ?? nil {
                        try db.run("UPDATE session SET cwd = ?, project = ? WHERE id = ?",
                                   [.text(c), .text(ClaudeParser.project(c)), .text(s)])
                    }
                }
            }
            if userActionsChanged {
                let human = try UserTime.humanActions(db, host: host)
                try db.run("DELETE FROM user_activity")
                for iv in Intervals.chain(human.points, gap: options.idleGap) {
                    try db.run("INSERT INTO user_activity(start, \"end\") VALUES(?, ?)", [.real(iv.start), .real(iv.end)])
                }
                var stored: [String: Int] = [:]
                try db.query("SELECT id, user_msgs FROM session WHERE coalesce(host, ?1) = ?1", [.text(host)]) {
                    stored[$0.text(0) ?? ""] = $0.int(1)
                }
                let changed = stored.filter { human.messages[$0.key, default: 0] != $0.value }
                if !changed.isEmpty {
                    let seq = try store.nextSeq()
                    for (id, _) in changed {
                        try db.run("UPDATE session SET user_msgs = ?, seq = ? WHERE id = ?",
                                   [.int(Int64(human.messages[id, default: 0])), .int(Int64(seq)), .text(id)])
                    }
                }
            }
            var days = Set<String>()
            for h in touchedHours {
                days.insert(Time.dayString(Double(h)))
                days.insert(Time.dayString(Double(h + 3599)))
            }
            if userActionsChanged {
                // A user stretch may cross midnight: refresh neighbours too.
                for d in days { if let p = Time.addDays(d, -1) { days.insert(p) }; if let n = Time.addDays(d, 1) { days.insert(n) } }
            }
            if !days.isEmpty {
                let seq = try store.nextSeq()
                for d in days.sorted() { try DayAggregator(db: db, host: host).rebuild(day: d, seq: seq) }
            }
        }
        touchedHours.removeAll(); touchedSessions.removeAll(); userActionsChanged = false
    }

    // MARK: helpers

    /// Relative paths of regular files under `root` (recursive; symlinked directories are not followed).
    public static func walk(_ root: String) -> [String] {
        var out: [String] = []
        func rec(_ dir: String, _ prefix: String) {
            guard let d = opendir(dir) else { return }
            defer { closedir(d) }
            while let e = readdir(d) {
                let name = withUnsafePointer(to: &e.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let full = dir + "/" + name, rel = prefix.isEmpty ? name : prefix + "/" + name
                var type = e.pointee.d_type
                if type == UInt8(DT_UNKNOWN) {
                    var sb = stat()
                    if lstat(full, &sb) == 0 {
                        type = (sb.st_mode & S_IFMT) == S_IFDIR ? UInt8(DT_DIR) : (sb.st_mode & S_IFMT) == S_IFREG ? UInt8(DT_REG) : 0
                    }
                }
                if type == UInt8(DT_DIR) { rec(full, rel) } else if type == UInt8(DT_REG) { out.append(rel) }
            }
        }
        rec(root, "")
        return out
    }

    public static func hostName() -> String {
        #if canImport(SystemConfiguration)
        // A Mac's gethostname follows the network (DHCP, VPN: "X.local", "X.lan", "X-2"); its local host name and its
        // computer name do not.
        for name in [SCDynamicStoreCopyLocalHostName(nil), SCDynamicStoreCopyComputerName(nil, nil)] {
            if let cf = name, let s = cfUTF8(cf), !s.isEmpty { return s }
        }
        #endif
        var b = [CChar](repeating: 0, count: 256)
        return gethostname(&b, b.count) == 0 ? String(decoding: b.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "localhost"
    }
}

#if canImport(SystemConfiguration)
/// A CFString as a Swift string without Foundation.
func cfUTF8(_ s: CFString) -> String? {
    let size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), CFStringBuiltInEncodings.UTF8.rawValue) + 1
    var b = [CChar](repeating: 0, count: Int(size))
    guard CFStringGetCString(s, &b, size, CFStringBuiltInEncodings.UTF8.rawValue) else { return nil }
    return String(decoding: b.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
#endif

/// `read(2)` under a name that does not clash with methods called `read`.
@inline(__always)
func Glibc_read(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.read(fd, p, n)
    #elseif canImport(Musl)
    return Musl.read(fd, p, n)
    #else
    return Darwin.read(fd, p, n)
    #endif
}
