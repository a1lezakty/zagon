/// Read-only queries behind the Mac app screens (and later MCP): limits with pace, live sessions, day / week /
/// month detail, search, tasks, worklog plan. Never writes. Times are UTC epoch seconds, days are local `YYYY-MM-DD`.
public struct Query {
    public let db: SQLite
    public let reports: Reports

    public init(store: Store) {
        db = store.db
        reports = Reports(store: store)
    }
}

// MARK: - limits

public struct LimitReading: Sendable, Equatable {
    public var tool: ToolKind
    /// Claude `five_hour` / `seven_day`, Codex `primary` / `secondary`.
    public var window: String
    public var usedPct: Double
    public var resetsAt: Timestamp?
    public var windowMinutes: Int?
    public var ts: Timestamp
    /// Growth in percent per hour over the 15–60 minutes before the reading, same window; nil without an earlier
    /// reading or when the latest reading is over 15 minutes old (nothing is running, so the rate is stale).
    public var pctPerHour: Double?
}

extension Query {
    /// Latest reading per (tool, window), with its pace.
    public func limits(now: Timestamp) throws -> [LimitReading] {
        var out: [LimitReading] = []
        for s in try Store.latestLimits(db) {
            var r = LimitReading(tool: s.tool, window: s.window, usedPct: s.usedPct, resetsAt: s.resetsAt,
                                 windowMinutes: s.windowMinutes, ts: s.ts)
            // The earliest reading of the same window 15–60 minutes back. Codex readings with only `resets_in_seconds`
            // get a reset time that drifts by seconds between readings, hence the 2-minute tolerance.
            if now - s.ts <= 900, let (pct, ts) = try db.one("""
                SELECT used_pct, ts FROM limit_snapshot WHERE tool = ?1 AND window = ?2 AND ts >= ?3 AND ts <= ?4
                  AND abs(coalesce(resets_at, 0) - coalesce(?5, 0)) < 120 ORDER BY ts LIMIT 1
                """, [.text(s.tool.rawValue), .text(s.window), .real(s.ts - 3600), .real(s.ts - 900), .of(s.resetsAt)],
                { ($0.real(0), $0.real(1)) }), s.ts > ts {
                r.pctPerHour = (s.usedPct - pct) / ((s.ts - ts) / 3600)
            }
            out.append(r)
        }
        return out
    }
}

extension Query {
    /// Readings of one window since `since`, oldest first: (ts, used percent).
    public func limitHistory(tool: ToolKind, window: String, since: Timestamp) throws -> [(ts: Timestamp, pct: Double)] {
        var out: [(ts: Timestamp, pct: Double)] = []
        try db.query("SELECT ts, used_pct FROM limit_snapshot WHERE tool = ? AND window = ? AND ts >= ? ORDER BY ts",
                     [.text(tool.rawValue), .text(window), .real(since)]) { out.append(($0.real(0), $0.real(1))) }
        return out
    }
}

extension Store {
    /// `latestLimits()` on a bare connection (Query holds the connection, not the Store).
    static func latestLimits(_ db: SQLite) throws -> [LimitSnapshot] {
        var out: [LimitSnapshot] = []
        try db.query("""
            SELECT tool, window, used_pct, resets_at, window_minutes, max(ts) FROM limit_snapshot GROUP BY tool, window
            ORDER BY tool, window
            """) { r in
            guard let tool = ToolKind(rawValue: r.text(0) ?? "") else { return }
            out.append(LimitSnapshot(tool: tool, window: r.text(1) ?? "", usedPct: r.real(2), resetsAt: r.optReal(3),
                                     windowMinutes: r.optInt(4), ts: r.real(5)))
        }
        return out
    }
}

// MARK: - live sessions

public enum LiveState: String, Sendable, Equatable {
    case working, waitingPermission, waitingInput, idle
}

public struct LiveSessionInfo: Sendable, Equatable {
    public var id: String
    public var tool: String
    public var title: String?
    public var project: String?
    public var cwd: String?
    public var host: String?
    public var model: String?
    public var state: LiveState
    /// Another session typed its last typed message (a worker driven over `tmux send-keys`): waiting for input, it waits
    /// for that session, not for you. Its title, "" = untitled; nil = the human typed it.
    public var driver: String?
    /// When the current state began.
    public var since: Timestamp
    public var lastAt: Timestamp?
    /// The id without the `<tool>:` prefix (what `claude --resume` / `codex resume` take).
    public var nativeId: String { id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id }
}

extension Query {
    /// Waiting (for input or a permission) longer than this counts as idle; a `working` status older than this with no
    /// transcript activity is a missed hook (idle too).
    public static let idleAfter: Double = 30 * 60

    /// Sessions seen in the last `window` seconds that have not ended, by state rule:
    /// hooks' status when known, else transcript activity (working when active within 5 minutes). A waiting status
    /// that the transcript moved past was overtaken: Esc on a permission prompt fires no hook, nor does a missed
    /// `UserPromptSubmit`.
    public func liveSessions(now: Timestamp, window: Double = 6 * 3600) throws -> [LiveSessionInfo] {
        var out: [LiveSessionInfo] = []
        try db.query("""
            SELECT id, tool, title, \(Projects.sessionSQL("session")), cwd, host, model, status, status_at, last_at,
                   (SELECT max(start) FROM activity a WHERE a.session_id = session.id AND a.kind = 'working'),
                   \(UserTime.driverSQL("session"))
            FROM session
            WHERE max(coalesce(last_at, 0), coalesce(status_at, 0)) >= ?1 AND coalesce(archived, 0) = 0
              AND coalesce(status, '') <> 'ended'
            """, [.real(now - window)]) { r in
            let status = r.text(7), statusAt = r.optReal(8), lastAt = r.optReal(9)
            let seen = max(lastAt ?? 0, statusAt ?? 0)
            let overtaken = (lastAt ?? 0) > (statusAt ?? 0) + 5
            var state = LiveState.idle, since = seen
            switch (status, statusAt) {
            case ("waiting_permission"?, let at?) where !overtaken:
                state = now - at <= Self.idleAfter ? .waitingPermission : .idle; since = at
            case ("waiting_input"?, let at?) where !overtaken:
                state = now - at <= Self.idleAfter ? .waitingInput : .idle; since = at
            case ("working"?, let at?) where now - seen <= Self.idleAfter:
                state = .working; since = at
            case _ where now - (lastAt ?? 0) <= 5 * 60:
                state = .working; since = r.optReal(10) ?? lastAt ?? now
            default:
                break
            }
            out.append(LiveSessionInfo(id: r.text(0) ?? "", tool: r.text(1) ?? "", title: r.text(2), project: r.text(3),
                                       cwd: r.text(4), host: r.text(5), model: r.text(6), state: state, driver: r.text(11),
                                       since: since, lastAt: lastAt))
        }
        return out.sorted { $0.since < $1.since }
    }

    public func hosts() throws -> [String] {
        var out: [String] = []
        try db.query("SELECT DISTINCT host FROM session WHERE host IS NOT NULL ORDER BY host") { r in
            if let h = r.text(0) { out.append(h) }
        }
        return out
    }
}
