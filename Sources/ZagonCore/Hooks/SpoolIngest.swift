/// Applies new spool lines (hooks, status line) to the Store. Called by the daemon; safe to call often.
/// Read offsets live in `meta` (`spool:<file name>`), committed with the writes of the same chunk.
public enum SpoolIngest {
    /// Live status for a hook event; nil = the event does not change the status.
    public static func status(tool: String, event: String, notificationType: String?, source: String?) -> String? {
        switch (tool, event) {
        case (_, "UserPromptSubmit"), (_, "PostToolUse"): return "working"
        case (_, "PermissionRequest"): return "waiting_permission"
        case (_, "Stop"): return "waiting_input"
        case ("codex", "Interrupt"): return "waiting_input"
        case (_, "SessionEnd"): return "ended"
        // A compact restart happens mid-turn; any other start leaves the session waiting for a prompt.
        case (_, "SessionStart"): return source == "compact" ? nil : "waiting_input"
        case ("claude", "Notification"):
            switch notificationType {
            case "idle_prompt": return "waiting_input"
            case "permission_prompt": return "waiting_permission"
            default: return nil
            }
        default: return nil
        }
    }

    static let windowMinutes = ["five_hour": 300, "seven_day": 10080]
    /// An unchanged limit reading is stored again only after this many seconds (keeps "last seen" fresh).
    static let limitRefresh: Double = 60

    public struct Result: Equatable, Sendable {
        public var lines = 0, statuses = 0, limits = 0, bad = 0, expired = 0
    }

    /// Reads every spool file from its saved offset (complete lines only), then deletes files older than
    /// `retainDays` (UTC day in the name) and offsets of files that are gone.
    @discardableResult
    public static func run(store: Store, spoolDir: String, retainDays: Int = 7, now: Double = Sys.now()) throws -> Result {
        var res = Result()
        let names = Sys.listDir(spoolDir)
        let files = names.filter { $0.hasSuffix(".ndjson") }
        let oldest = Sys.utcDay(now - Double(retainDays) * 86400)
        // Last status-line readings of sessions (StatusLine.shouldSpool) go with the spool files of their age.
        for name in names where name.hasPrefix(".limits-") {
            if let m = Sys.mtime(spoolDir + "/" + name), m < now - Double(retainDays) * 86400 { Sys.remove(spoolDir + "/" + name) }
        }
        // Cursor's lines are its only record of time (CursorSource): kept as long as the dedup ledger, beyond Claude
        // Code's 30-day cleanup, so a rebuilt database counts them again.
        let oldestCursor = Sys.utcDay(now - Double(max(retainDays, 40)) * 86400)
        for name in files {
            if String(name.prefix(10)) < (name.hasSuffix(".cursor.ndjson") ? oldestCursor : oldest) {
                Sys.remove(spoolDir + "/" + name)
                try store.db.run("DELETE FROM meta WHERE key = ?", [.text("spool:" + name)])
                res.expired += 1
                continue
            }
            try ingest(file: spoolDir + "/" + name, key: "spool:" + name, store: store, into: &res)
        }
        let live = Set(files.map { "spool:" + $0 })
        var stale: [String] = []
        try store.db.query("SELECT key FROM meta WHERE key LIKE 'spool:%'") { r in
            if let k = r.text(0), !live.contains(k) { stale.append(k) }
        }
        for k in stale { try store.db.run("DELETE FROM meta WHERE key = ?", [.text(k)]) }
        return res
    }

    static func ingest(file: String, key: String, store: Store, into res: inout Result) throws {
        let saved = try store.db.one("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.int(0) } ?? 0
        let size = Sys.fileSize(file) ?? 0
        let offset = saved <= size ? saved : 0  // shrunk = replaced: start over
        guard size > offset, let data = Sys.readFile(file, from: offset),
              let lastNL = data.lastIndex(of: 0x0A) else { return }
        try store.db.transaction {
            var start = 0
            while start <= lastNL {
                let end = data[start...lastNL].firstIndex(of: 0x0A) ?? lastNL
                if end > start { try apply(Array(data[start..<end]), store: store, into: &res) }
                start = end + 1
            }
            try store.db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2",
                             [.text(key), .int(Int64(offset + lastNL + 1))])
        }
    }

    static func apply(_ line: [UInt8], store: Store, into res: inout Result) throws {
        res.lines += 1
        guard let v = JValue.parse(line), let ts = v["ts"]?.double, let tool = v["tool"]?.string.flatMap(ToolKind.init)
        else { res.bad += 1; return }
        switch v["kind"]?.string {
        case "hook":
            guard let sid = v["session_id"]?.string, let event = v["event"]?.string else { res.bad += 1; return }
            guard let st = status(tool: tool.rawValue, event: event, notificationType: v["notification_type"]?.string,
                                  source: v["source"]?.string) else { return }
            if try setStatus(store: store, id: "\(tool.rawValue):\(sid)", tool: tool, status: st, at: ts,
                             cwd: v["cwd"]?.string, detail: st == "waiting_permission" ? v["tool_name"]?.string : nil) {
                res.statuses += 1
            }
        case "limits":
            for (window, minutes) in windowMinutes.sorted(by: { $0.key < $1.key }) {
                guard let pct = v[window + "_pct"]?.double else { continue }
                let resets = v[window + "_resets_at"]?.double
                let last = try store.db.one("""
                    SELECT used_pct, resets_at, ts FROM limit_snapshot WHERE tool = ? AND window = ? ORDER BY ts DESC LIMIT 1
                    """, [.text(tool.rawValue), .text(window)]) { ($0.real(0), $0.optReal(1), $0.real(2)) }
                if let last, last.0 == pct, last.1 == resets, ts - last.2 < limitRefresh, ts >= last.2 { continue }
                try store.addLimitSnapshot(LimitSnapshot(tool: tool, window: window, usedPct: pct, resetsAt: resets,
                                                         windowMinutes: minutes, ts: ts))
                res.limits += 1
            }
        default: res.bad += 1
        }
    }

    /// Sets the status unless an equal or newer one is stored. Leaving a `waiting_*` status records the
    /// `waiting` interval from when it started. Returns whether anything changed.
    static func setStatus(store: Store, id: String, tool: ToolKind, status: String, at: Timestamp, cwd: String?,
                          detail: String? = nil) throws -> Bool {
        let row = try store.db.one("SELECT status, status_at FROM session WHERE id = ?", [.text(id)]) { ($0.text(0), $0.optReal(1)) }
        if row == nil, let cwd { try store.mergeSession(SessionMeta(id: id, tool: tool, cwd: cwd)) }
        let (prev, prevAt) = row ?? (nil, nil)
        if let prevAt, at < prevAt { return false }
        if prev == status { return false }  // keep status_at = when this state began
        if let prev, let prevAt, prev.hasPrefix("waiting") {
            try store.addActivity(sessionId: id, start: prevAt, end: at, kind: "waiting", cwd: cwd)
        }
        try store.setStatus(sessionId: id, tool: tool, status: status, at: at, detail: detail)
        return true
    }
}
