/// `claude agents --json` (Claude Code 2.1.145+): a second source of live statuses next to hooks, polled by the daemon
/// (`Daemon.startClaudeAgents`). It sees what hooks miss (a hook not installed, a lost event, a background session).
public enum ClaudeAgents {
    public struct Entry: Equatable, Sendable {
        public var sessionId: String
        public var cwd: String?
        /// `busy` / `waiting` / `idle`; nil when the process has exited.
        public var status: String?
        public var waitingFor: String?
        /// Background sessions: `working` / `blocked` / `done` / `failed` / `stopped`.
        public var state: String?
        public init(sessionId: String, cwd: String? = nil, status: String? = nil, waitingFor: String? = nil, state: String? = nil) {
            self.sessionId = sessionId; self.cwd = cwd; self.status = status; self.waitingFor = waitingFor; self.state = state
        }
    }

    /// The entries that carry a `sessionId`; nil when the output is not a JSON array (an older Claude Code).
    public static func parse(_ bytes: [UInt8]) -> [Entry]? {
        guard let list = JValue.parse(bytes)?.array else { return nil }
        return list.compactMap { v in
            v["sessionId"]?.string.map {
                Entry(sessionId: $0, cwd: v["cwd"]?.string, status: v["status"]?.string, waitingFor: v["waitingFor"]?.string,
                      state: v["state"]?.string)
            }
        }
    }

    /// Our status for an entry; nil = says nothing new (keep what hooks set).
    public static func status(_ e: Entry) -> String? {
        switch e.status {
        case "busy": return "working"
        case "waiting":
            let blocked: Set = ["permission prompt", "sandbox request", "worker request", "input needed"]
            return e.waitingFor.map(blocked.contains) == true ? "waiting_permission" : "waiting_input"
        // A background session idle between steps it drives itself (a loop, a wait on CI) is not waiting for you.
        case "idle": return e.state == "working" ? nil : e.state == "blocked" ? "waiting_permission" : "waiting_input"
        case nil:
            switch e.state {
            case "done": return "waiting_input"
            case "blocked": return "waiting_permission"
            case "failed", "stopped": return "ended"
            default: return nil
            }
        default: return nil
        }
    }

    /// A hook this many seconds older than the call may still be on its way to the database (spool debounce, a
    /// retried batch): the call's statuses are dated so far back, so such a hook (exact time) still wins.
    public static let lag: Double = 5

    /// Applies the statuses of a call started at `at` through `SpoolIngest.setStatus`: newer ones win, an unchanged
    /// one keeps its `status_at`. Only sessions already in the database; a session missing from the list is left
    /// alone (another config dir, a container, a start race), and an exited process does not reopen an ended one.
    /// Returns how many statuses changed.
    @discardableResult
    public static func apply(_ entries: [Entry], store: Store, at: Timestamp) throws -> Int {
        var n = 0
        for e in entries {
            guard let st = status(e) else { continue }
            let id = "claude:" + e.sessionId
            guard let prev = try store.db.one("SELECT status FROM session WHERE id = ?", [.text(id)], { $0.text(0) ?? "" })
            else { continue }
            if e.status == nil, prev == "ended" { continue }
            if try SpoolIngest.setStatus(store: store, id: id, tool: .claude, status: st, at: at - lag, cwd: e.cwd) { n += 1 }
        }
        return n
    }

    /// Whether a call is worth it: a Claude session of `host` not ended and seen in the last `window` seconds.
    public static func active(store: Store, host: String, now: Timestamp, window: Double = 1800) throws -> Bool {
        try store.db.one("""
            SELECT 1 FROM session WHERE tool = 'claude' AND coalesce(host, ?1) = ?1 AND coalesce(status, '') != 'ended'
              AND max(coalesce(last_at, 0), coalesce(status_at, 0)) >= ?2 LIMIT 1
            """, [.text(host), .real(now - window)]) { $0.int(0) } != nil
    }
}
