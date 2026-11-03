public struct StoreError: Error, CustomStringConvertible {
    public let description: String
}

/// The Zagon database (`~/.zagon/zagon.db`). Parsers do not write here directly: `Ingest` feeds `ParseOutput`
/// through the store. Hooks / status line / external importers use the small public API below.
public final class Store {
    public let db: SQLite
    public static let schemaVersion = Schema.migrations.count
    /// The machine this database belongs to (`meta.host`): fixed at the first open, so a Mac renaming itself with the
    /// network (`X.local` → `X-2.local`) does not split its totals into two hosts.
    public private(set) var host = ""

    public init(path: String) throws {
        db = try SQLite(path: path)
        // A newer zagon migrated this database (e.g. before `mv zagon.prev zagon`): writing to it with an older schema
        // would corrupt it, so refuse before any write.
        let v = try db.one("PRAGMA user_version") { $0.int(0) } ?? 0
        guard v <= Store.schemaVersion else {
            throw StoreError(description: "\(path): the database is newer than this zagon (schema v\(v) > "
                             + "v\(Store.schemaVersion)): update zagon or put the newer version back")
        }
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try migrate()
        host = try pinHost()
    }

    /// `meta.host`; set once: the host most sessions already carry (a database from before pinning), else gethostname.
    func pinHost() throws -> String {
        if let h = try db.one("SELECT value FROM meta WHERE key='host'", [], { $0.text(0) }) ?? nil { return h }
        let used = try db.one("SELECT host FROM session WHERE host IS NOT NULL GROUP BY host ORDER BY count(*) DESC LIMIT 1") {
            $0.text(0)
        } ?? nil
        try db.run("INSERT OR IGNORE INTO meta(key, value) VALUES('host', ?)", [.text(used ?? Ingest.hostName())])
        return try db.one("SELECT value FROM meta WHERE key='host'") { $0.text(0) ?? "" } ?? ""
    }

    func migrate() throws {
        let current = try db.one("PRAGMA user_version") { $0.int(0) } ?? 0
        guard current < Schema.migrations.count else { return }
        try db.transaction {
            // Re-check under the write lock: another process may have migrated meanwhile.
            let v = try db.one("PRAGMA user_version") { $0.int(0) } ?? 0
            for (i, sql) in Schema.migrations.enumerated() where i >= v {
                try db.exec(sql)
                try db.exec("PRAGMA user_version=\(i + 1)")
            }
        }
    }

    public var userVersion: Int { (try? db.one("PRAGMA user_version") { $0.int(0) }) ?? 0 }

    // MARK: change counter (for `export --since <seq>`)

    /// Increments and returns the global change counter. Call inside a transaction.
    public func nextSeq() throws -> Int {
        try db.run("INSERT INTO meta(key, value) VALUES('seq', 1) ON CONFLICT(key) DO UPDATE SET value = value + 1")
        return try db.one("SELECT value FROM meta WHERE key='seq'") { $0.int(0) } ?? 0
    }

    // MARK: public write API

    /// Creates the session if needed and fills in known fields. A title replaces the stored one only if its rank
    /// is at least the stored rank.
    public func mergeSession(_ m: SessionMeta, host: String? = nil) throws {
        let seq = try nextSeq()
        try db.run("""
            INSERT INTO session(id, tool, host, project, cwd, git_branch, title, title_rank, model, archived, account, seq)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, CASE WHEN ?7 IS NULL THEN 0 ELSE ?8 END, ?9, ?11, ?12, ?10)
            ON CONFLICT(id) DO UPDATE SET
              host = coalesce(session.host, excluded.host),
              project = coalesce(excluded.project, session.project),
              cwd = coalesce(excluded.cwd, session.cwd),
              git_branch = coalesce(excluded.git_branch, session.git_branch),
              title = CASE WHEN excluded.title IS NOT NULL AND ?8 >= session.title_rank THEN excluded.title ELSE session.title END,
              title_rank = CASE WHEN excluded.title IS NOT NULL AND ?8 >= session.title_rank THEN ?8 ELSE session.title_rank END,
              model = coalesce(excluded.model, session.model),
              archived = coalesce(excluded.archived, session.archived),
              account = coalesce(excluded.account, session.account),
              seq = excluded.seq
            """, [.text(m.id), .text(m.tool.rawValue), .of(host), .of(m.project), .of(m.cwd), .of(m.gitBranch),
                  .of(m.title), .int(Int64(m.titleRank)), .of(m.model), .int(Int64(seq)),
                  .of(m.archived.map { $0 ? 1 : 0 }), .of(m.account)])
    }

    /// The stored background tasks of a session (`Background`); empty for an unknown one.
    func background(_ id: String) throws -> Background.State {
        try db.one("SELECT bg_tasks, bg_until, bg_since FROM session WHERE id = ?", [.text(id)]) {
            Background.State(tasks: $0.text(0), until: $0.optReal(1), since: $0.optReal(2))
        } ?? Background.State()
    }

    func setBackground(_ id: String, _ s: Background.State) throws {
        try db.run("UPDATE session SET bg_tasks = ?, bg_until = ?, bg_since = ?, seq = ? WHERE id = ?",
                   [.of(s.tasks), .of(s.until), .of(s.since), .int(Int64(try nextSeq())), .text(id)])
    }

    /// Live status from hooks: `working` | `waiting_permission` | `waiting_input` | `ended` (free text, short).
    /// `detail` says what it is about (the tool name for `waiting_permission`); nil clears it. A session new here is
    /// this machine's (`host`): hooks run where the session runs.
    public func setStatus(sessionId: String, tool: ToolKind, status: String, at: Timestamp, detail: String? = nil) throws {
        let seq = try nextSeq()
        try db.run("""
            INSERT INTO session(id, tool, host, status, status_at, status_detail, seq) VALUES(?1, ?2, ?7, ?3, ?4, ?6, ?5)
            ON CONFLICT(id) DO UPDATE SET status = excluded.status, status_at = excluded.status_at,
              status_detail = excluded.status_detail, seq = excluded.seq
            WHERE session.status_at IS NULL OR excluded.status_at >= session.status_at
            """, [.text(sessionId), .text(tool.rawValue), .text(status), .real(at), .int(Int64(seq)), .of(detail), .text(host)])
    }

    /// `source`: "" = this store's own reading, else the alias it was imported under (`ExportImport`). The newest `ts` of
    /// each source is kept in `meta` (`limit_src:<Store.limitKey>:<source>`) for `Query.limitSources`.
    public func addLimitSnapshot(_ s: LimitSnapshot, source: String = "") throws {
        try db.run("""
            INSERT OR REPLACE INTO limit_snapshot(tool, window, used_pct, resets_at, window_minutes, ts, account)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """, [.text(s.tool.rawValue), .text(s.window), .real(s.usedPct), .of(s.resetsAt), .of(s.windowMinutes), .real(s.ts),
                  .text(s.account)])
        try db.run("""
            INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2 WHERE ?2 > meta.value
            """, [.text("limit_src:\(Store.limitKey(s)):\(source)"), .real(s.ts)])
    }

    /// `<tool>:<window>` of a reading, `<tool>:<account>/<window>` for an account other than the default one (the keys
    /// of the default account stay as they were before accounts).
    public static func limitKey(_ s: LimitSnapshot) -> String {
        s.account == Accounts.defaultName ? "\(s.tool.rawValue):\(s.window)" : "\(s.tool.rawValue):\(s.account)/\(s.window)"
    }

    /// The current reading per (tool, window), see `Store.latestLimits(_:)`.
    public func latestLimits() throws -> [LimitSnapshot] { try Store.latestLimits(db) }

    /// An interval known from hooks (not from transcripts), e.g. `waiting` for permission.
    public func addActivity(sessionId: String, start: Timestamp, end: Timestamp, kind: String, cwd: String? = nil) throws {
        guard end > start else { return }
        try db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind, cwd) VALUES(NULL, ?, ?, ?, ?, ?)",
                   [.text(sessionId), .real(start), .real(end), .text(kind), .of(cwd)])
    }
}
