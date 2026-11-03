public struct ExportImportError: Error, CustomStringConvertible {
    public let description: String
}

/// Reference client of `zagon export`: applies its lines to another store (e.g. the Mac app's copy of a server).
/// Imported rows of `usage_hour`, `tool_use` and `activity` belong to one `source_file` row per source
/// (`export:<source>`), so local ingest never touches them and a session or a day is replaced as a whole without
/// affecting local data. Your-time intervals become `activity` rows with `kind = 'user'` and `session_id = ''`
/// (`user_activity` is rebuilt by local ingest). Unknown line types and keys are ignored.
public final class ExportImport {
    public let store: Store
    let file: Int64
    let source: String
    /// `seq` of the last header line: pass it as the next `--since`.
    public private(set) var seq = 0

    public init(store: Store, source: String) throws {
        self.store = store
        self.source = source
        let path = "export:" + source
        try store.db.run("INSERT OR IGNORE INTO source_file(path, tool) VALUES(?, 'export')", [.text(path)])
        file = try store.db.one("SELECT id FROM source_file WHERE path = ?", [.text(path)]) { $0.int64(0) } ?? 0
    }

    /// Applies one export (all its lines) in one transaction.
    public func apply(_ lines: [String]) throws {
        try store.db.transaction { for l in lines where !l.isEmpty { try apply(line: l) } }
    }

    func apply(line: String) throws {
        guard let v = JValue.parse(line) else { throw ExportImportError(description: "not JSON: \(line.prefix(80))") }
        let db = store.db
        func s(_ k: String) -> SQLValue { .of(v[k]?.string) }
        func d(_ k: String) -> SQLValue { .of(v[k]?.double) }
        func i(_ k: String, _ o: JValue? = nil) -> Int64 { Int64((o ?? v)[k]?.double ?? 0) }
        switch v["type"]?.string {
        case "export":
            seq = Int(i("seq"))
        case "session":
            guard let id = v["id"]?.string else { return }
            let archived: SQLValue = v["archived"].map { $0 == .bool(true) ? .int(1) : $0 == .bool(false) ? .int(0) : .null } ?? .null
            try db.run("""
                INSERT INTO session(id, tool, host, project, cwd, git_branch, title, model, started_at, last_at, status, status_at,
                                    status_detail, user_msgs, archived, seq, driver, account, bg_tasks, bg_until)
                VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
                ON CONFLICT(id) DO UPDATE SET tool = ?2, host = ?3, project = ?4, cwd = ?5, git_branch = ?6, title = ?7,
                  model = ?8, started_at = ?9, last_at = ?10, status = ?11, status_at = ?12, status_detail = ?13,
                  user_msgs = ?14, archived = ?15, seq = ?16, driver = ?17, account = ?18, bg_tasks = ?19, bg_until = ?20
                """, [.text(id), s("tool"), s("host"), s("project"), s("cwd"), s("git_branch"), s("title"), s("model"),
                      d("started_at"), d("last_at"), s("status"), d("status_at"), s("status_detail"), .int(i("user_msgs")),
                      archived, .int(i("seq")), s("driver"), s("account"), s("bg_tasks"), d("bg_until")])
            // Its activity lines follow: they are the complete set.
            try db.run("DELETE FROM activity WHERE file_id = ? AND session_id = ?", [.int(file), .text(id)])
        case "activity":
            try db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind, cwd) VALUES(?, ?, ?, ?, ?, ?)",
                       [.int(file), s("session_id"), d("start"), d("end"), s("kind"), s("cwd")])
        case "day":
            guard let day = v["day"]?.string, let host = v["host"]?.string, let start = v["start"]?.double,
                  let end = v["end"]?.double else { return }
            try db.run("DELETE FROM day_agg WHERE day = ? AND host = ?", [.text(day), .text(host)])
            for t in ["usage_hour", "tool_use"] {
                try db.run("DELETE FROM \(t) WHERE file_id = ? AND hour >= ? AND hour < ?", [.int(file), .real(start), .real(end)])
            }
            try db.run("DELETE FROM activity WHERE file_id = ? AND kind = 'user' AND start >= ? AND start < ?",
                       [.int(file), .real(start), .real(end)])
            for r in v["rows"]?.array ?? [] {
                try db.run("""
                    INSERT INTO day_agg(day, host, tool, project, model, input, output, cache_read, cache_write, cache_write_1h,
                      requests, tool_calls, session_sec, user_sec, seq) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(day), .text(host), .text(r["tool"]?.string ?? ""), .text(r["project"]?.string ?? ""),
                          .text(r["model"]?.string ?? ""), .int(i("input", r)), .int(i("output", r)), .int(i("cache_read", r)),
                          .int(i("cache_write", r)), .int(i("cache_write_1h", r)), .int(i("requests", r)), .int(i("tool_calls", r)),
                          .real(r["session_sec"]?.double ?? 0), .real(r["user_sec"]?.double ?? 0), .int(i("seq"))])
            }
            // `usage_cwd` (v5) is `usage` split by directory: take it when the server sent it.
            for r in v["usage_cwd"]?.array ?? v["usage"]?.array ?? [] {
                try db.run("""
                    INSERT INTO usage_hour(file_id, session_id, agent, hour, model, cwd, input, output, cache_read, cache_write,
                      cache_write_1h, requests, tool_calls) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.int(file), .text(r["session_id"]?.string ?? ""), .text(r["agent"]?.string ?? ""), .int(i("hour", r)),
                          .text(r["model"]?.string ?? ""), .text(r["cwd"]?.string ?? ""), .int(i("input", r)),
                          .int(i("output", r)), .int(i("cache_read", r)), .int(i("cache_write", r)),
                          .int(i("cache_write_1h", r)), .int(i("requests", r)), .int(i("tool_calls", r))])
            }
            for r in v["tools"]?.array ?? [] {
                try db.run("INSERT INTO tool_use(file_id, session_id, hour, name, n) VALUES(?,?,?,?,?)",
                           [.int(file), .text(r["session_id"]?.string ?? ""), .int(i("hour", r)), .text(r["name"]?.string ?? ""),
                            .int(i("n", r))])
            }
            for r in v["user"]?.array ?? [] {
                try db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(?, '', ?, ?, 'user')",
                           [.int(file), .of(r["start"]?.double), .of(r["end"]?.double)])
            }
        case "dir":
            guard let host = v["host"]?.string, let cwd = v["cwd"]?.string, let project = v["project"]?.string else { return }
            try db.run("INSERT OR REPLACE INTO dir_project(host, cwd, project, home, seq) VALUES(?, ?, ?, ?, 0)",
                       [.text(host), .text(cwd), .text(project), .int(v["home"] == .bool(true) ? 1 : 0)])
        case "summary":
            guard let day = v["day"]?.string, let engine = v["engine"]?.string, let text = v["text"]?.string,
                  let created = v["created"]?.double else { return }
            // ponytail: one row per (day, engine) on this store: two servers' summaries of a day replace each other
            // (the newer stays); a host in the key of `summary` (a schema change) if that bites.
            let n = try db.run("""
                INSERT INTO summary(day, engine, text, created) VALUES(?1, ?2, ?3, ?4)
                ON CONFLICT(day, engine) DO UPDATE SET text = ?3, created = ?4 WHERE ?4 >= created
                """, [.text(day), .text(engine), .text(text), .real(created)])
            // This store's reason for a summary without AI is not the other host's.
            if engine == "none", n > 0 { try db.run("DELETE FROM meta WHERE key = ?", [.text("summary_why:" + day)]) }
        case "limit", "account_limit":
            guard let tool = v["tool"]?.string.flatMap(ToolKind.init), let w = v["window"]?.string,
                  let pct = v["used_pct"]?.double, let ts = v["ts"]?.double else { return }
            let id = v["account_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            try store.addLimitSnapshot(LimitSnapshot(tool: tool, window: w, usedPct: pct, resetsAt: v["resets_at"]?.double,
                                                     windowMinutes: v["window_minutes"]?.double.map { Int($0) }, ts: ts,
                                                     account: id ?? Accounts.defaultName),
                                       source: source)
            // The server's `[limits] account` (0.1.5; a line without it, also from an older server, = none), from the
            // default account's lines; another account's label is its own name (`account_id`).
            guard v["type"]?.string == "limit" else { return }
            if let a = v["account"]?.string, !a.isEmpty {
                try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text("limit_account:" + source), .text(a)])
            } else {
                try db.run("DELETE FROM meta WHERE key = ?", [.text("limit_account:" + source)])
            }
        default: break
        }
    }
}
