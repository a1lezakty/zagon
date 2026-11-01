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
    /// The current reading per (tool, window) (`Store.latestLimits`), with its pace.
    public func limits(now: Timestamp) throws -> [LimitReading] {
        var out: [LimitReading] = []
        for s in try Store.latestLimits(db) {
            var r = LimitReading(tool: s.tool, window: s.window, usedPct: s.usedPct, resetsAt: s.resetsAt,
                                 windowMinutes: s.windowMinutes, ts: s.ts)
            if now - s.ts <= 900, let (pct, ts) = try Store.paceBase(db, s, from: s.ts - 3600, to: s.ts - 900), s.ts > ts {
                r.pctPerHour = (s.usedPct - pct) / ((s.ts - ts) / 3600)
            }
            out.append(r)
        }
        return out
    }
}

/// Where a current limit reading came from (`Query.limitSources`).
public struct LimitSource: Sendable, Equatable {
    public var tool: ToolKind
    public var window: String
    /// "" = this store's own readings, else the ssh alias they were imported under (`ExportImport`).
    public var source: String
    /// `[limits] account` of that source; nil = not set.
    public var account: String?
    /// More than one source read this tool's limits within 8 days: the rings may mix two accounts, so say whose they are.
    public var several: Bool
    public init(tool: ToolKind, window: String, source: String, account: String? = nil, several: Bool) {
        self.tool = tool; self.window = window; self.source = source; self.account = account; self.several = several
    }
}

extension Query {
    /// For each current reading (`Store.latestLimits`) with a known source: the source whose own newest reading of that
    /// window (`meta` `limit_src:<tool>:<window>:<source>`) is that reading, else is of its window period (`resets_at`
    /// within 2 minutes: one account's period; two accounts resetting within 2 minutes cannot be told apart), the newest
    /// of those. `account` from `meta` `limit_account:<alias>`, for this store's own readings `localAccount` (its
    /// `[limits] account`). `several`: more than one source has a reading of the tool within 8 days (the longest window,
    /// the week, and a day); a source quiet for longer has no current window left to mix up. A source is a label of its
    /// own (the alias is part of it), so more than one source = more than one label. Readings from before 0.1.5 carry no
    /// source and are left out.
    public func limitSources(now: Timestamp, localAccount: String? = nil) throws -> [LimitSource] {
        var newest: [(key: String, ts: Timestamp)] = [], accounts: [String: String] = [:]
        try db.query("SELECT key, value FROM meta WHERE key LIKE 'limit\\_src:%' ESCAPE '\\'") {
            newest.append(($0.text(0) ?? "", $0.real(1)))
        }
        try db.query("SELECT substr(key, 15), value FROM meta WHERE key LIKE 'limit\\_account:%' ESCAPE '\\'") {
            accounts[$0.text(0) ?? ""] = $0.text(1)
        }
        var out: [LimitSource] = [], recent: [ToolKind: Set<String>] = [:]
        for c in try Store.latestLimits(db) {
            let prefix = "limit_src:\(c.tool.rawValue):\(c.window):"
            var best: (source: String, ts: Timestamp, exact: Bool)?
            for (key, ts) in newest where key.hasPrefix(prefix) {
                let source = String(key.dropFirst(prefix.count)), exact = ts == c.ts
                if now - ts <= 8 * 86400 { recent[c.tool, default: []].insert(source) }
                if let b = best, b.exact || !exact && b.ts >= ts { continue }
                if !exact {
                    guard let r = c.resetsAt, let rs = try db.one("""
                        SELECT resets_at FROM limit_snapshot WHERE tool = ? AND window = ? AND ts = ?
                        """, [.text(c.tool.rawValue), .text(c.window), .real(ts)], { $0.optReal(0) }) ?? nil,
                          abs(rs - r) < 120 else { continue }
                }
                best = (source, ts, exact)
            }
            if let b = best {
                out.append(LimitSource(tool: c.tool, window: c.window, source: b.source,
                                       account: b.source.isEmpty ? localAccount : accounts[b.source], several: false))
            }
        }
        for i in out.indices { out[i].several = (recent[out[i].tool]?.count ?? 0) > 1 }
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
    /// The current reading per (tool, window): of its newest window period (`resets_at` within 2 minutes of the latest:
    /// Codex readings with only `resets_in_seconds` drift by seconds), the highest percent, the newest of equals.
    /// Not simply the newest row: `ts` is when a reading was written, not when it was measured. A Claude Code status
    /// line left open re-sends its last reading every minute with a fresh time (on a busy server one in five rows is
    /// below the current usage), and a Codex rollout may still report a period that has already reset. Usage only grows
    /// within a period, so its highest reading is the latest. A reading without `resets_at` counts as a period of its
    /// own ending at its `ts`: it wins only when newer than the end of every known period.
    /// ponytail: one account assumed. Readings carry no account, so two accounts (e.g. one per machine) mix: the one
    /// whose window resets last is shown (`Query.limitSources` says from where); split by an account id once the status
    /// line or Codex reports one, or by a source column in `limit_snapshot` (schema v8).
    static func latestLimits(_ db: SQLite) throws -> [LimitSnapshot] {
        var out: [LimitSnapshot] = []
        try db.query("""
            WITH s AS (SELECT tool, window, used_pct, resets_at, window_minutes, ts,
                              coalesce(resets_at, ts) AS period FROM limit_snapshot),
                 p AS (SELECT tool, window, max(period) AS period FROM s GROUP BY tool, window)
            SELECT tool, window, used_pct, resets_at, window_minutes, ts FROM (
              SELECT s.*, row_number() OVER (PARTITION BY s.tool, s.window ORDER BY s.used_pct DESC, s.ts DESC) AS n
              FROM s JOIN p ON s.tool = p.tool AND s.window = p.window AND s.period >= p.period - 120)
            WHERE n = 1 ORDER BY tool, window
            """) { r in
            guard let tool = ToolKind(rawValue: r.text(0) ?? "") else { return }
            out.append(LimitSnapshot(tool: tool, window: r.text(1) ?? "", usedPct: r.real(2), resetsAt: r.optReal(3),
                                     windowMinutes: r.optInt(4), ts: r.real(5)))
        }
        return out
    }

    /// Where a pace up to reading `s` starts: the earliest reading of its window period between `from` and `to`, with
    /// the usage at that moment, the highest percent of the period so far (that reading itself may be an older one
    /// re-sent, see `latestLimits`). The period starts `window_minutes` before its reset; without either, at `from`.
    static func paceBase(_ db: SQLite, _ s: LimitSnapshot, from: Timestamp, to: Timestamp) throws -> (pct: Double, ts: Timestamp)? {
        try db.one("""
            WITH w AS (SELECT used_pct, ts FROM limit_snapshot
                       WHERE tool = ?1 AND window = ?2 AND abs(coalesce(resets_at, 0) - coalesce(?3, 0)) < 120
                         AND ts >= coalesce(?3 - ?6 * 60, ?4))
            SELECT (SELECT max(used_pct) FROM w WHERE ts <= f.ts), f.ts
            FROM (SELECT min(ts) AS ts FROM w WHERE ts >= ?4 AND ts <= ?5) f WHERE f.ts IS NOT NULL
            """, [.text(s.tool.rawValue), .text(s.window), .of(s.resetsAt), .real(from), .real(to), .of(s.windowMinutes)]) {
            ($0.real(0), $0.real(1))
        }
    }
}

/// One limit's usage as its readings come in, oldest first. Usage only grows within a window period (`resets_at` within
/// 2 minutes), so a lower reading is an older one re-sent and the period's highest so far stands (see
/// `Store.latestLimits`); a reading of a period before the current one is a late report and is skipped. A reading without
/// `resets_at` belongs to the current period while that has not reset, else it opens a new one.
struct LimitUsage {
    let tool: String, window: String
    /// The usage now and its period's reset; nil before any reading.
    private(set) var pct: Double?, resets: Timestamp?

    /// The usage just before `t`: the highest reading of the newest period seen before it.
    /// ponytail: scans the window's whole history before `t`; bound it once `limit_snapshot` holds years.
    init(_ db: SQLite, tool: String, window: String, before t: Timestamp) throws {
        self.tool = tool; self.window = window
        if let (p, r) = try db.one("""
            SELECT max(used_pct), resets_at FROM limit_snapshot WHERE tool = ?1 AND window = ?2 AND ts < ?3
              AND coalesce(resets_at, ts) >= (SELECT max(coalesce(resets_at, ts)) FROM limit_snapshot
                                              WHERE tool = ?1 AND window = ?2 AND ts < ?3) - 120
            """, [.text(tool), .text(window), .real(t)], { ($0.optReal(0), $0.optReal(1)) }), let p {
            pct = p; resets = r
        }
    }

    /// Folds one reading taken at `ts` in: nil = skipped, true = it opened a new period after a known one.
    mutating func add(_ v: Double, resets r: Timestamp?, at ts: Timestamp) -> Bool? {
        guard let p = pct else { pct = v; resets = r; return false }
        switch (r, resets) {
        case let (r?, cur?):
            if r < cur - 120 { return nil }
            if r > cur + 120 { pct = v; resets = r; return true }
            pct = max(p, v)
        case let (nil, cur?) where ts < cur + 120: pct = max(p, v)
        case (nil, _?): pct = v; resets = nil; return true  // taken after the period's end: a new one began
        default: pct = v; resets = r
        }
        return false
    }

    /// Folds in the readings of [from, to), oldest first; `each(ts, usage before, after, new period)` for each one taken.
    mutating func read(_ db: SQLite, from: Timestamp, to: Timestamp,
                       _ each: (Timestamp, Double?, LimitUsage, Bool) -> Void) throws {
        try db.query("""
            SELECT ts, used_pct, resets_at FROM limit_snapshot WHERE tool = ? AND window = ? AND ts >= ? AND ts < ? ORDER BY ts
            """, [.text(tool), .text(window), .real(from), .real(to)]) { r in
            let before = pct
            if let new = add(r.real(1), resets: r.optReal(2), at: r.real(0)) { each(r.real(0), before, self, new) }
        }
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
    /// for that session, not for you. Its title or project ("" = neither); nil = the human (`UserTime.driverSQL`).
    public var drivenBy: String?
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
                   \(UserTime.driverSQL("session", now: now))
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
                                       cwd: r.text(4), host: r.text(5), model: r.text(6), state: state, drivenBy: r.text(11),
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
