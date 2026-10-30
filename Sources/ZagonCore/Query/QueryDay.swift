/// Tokens and their API price for one name (project, model, sub-agent, host).
public struct UsageLine: Sendable, Equatable {
    public var name: String
    public var tokens: Int
    public var cost: Double
}

public struct LaneInterval: Sendable, Equatable {
    public var start: Timestamp
    public var end: Timestamp
    public var waiting: Bool
}

/// One session's intervals inside a day (working merged over sub-agents, then waiting from hooks).
public struct SessionLane: Sendable, Equatable {
    public var id: String
    public var title: String?
    public var project: String?
    public var host: String?
    public var intervals: [LaneInterval]
}

public struct StoredSummary: Sendable, Equatable {
    public var engine: String
    public var text: String
    public var created: Timestamp
}

public struct DayDetail: Sendable {
    public var day: String
    public var tokens = TokenTotals()
    public var cost = 0.0
    public var sessionSec = 0.0
    public var userSec = 0.0
    public var lanes: [SessionLane] = []
    /// Most tokens first; an empty name = no project / the main thread.
    public var byProject: [UsageLine] = []
    public var byModel: [UsageLine] = []
    public var byAgent: [UsageLine] = []
    public var byHost: [UsageLine] = []
    /// Tool calls by tool name, most first.
    public var byTool: [NameCount] = []
    /// Stretches when a 5-hour window stood at 100 %.
    public var limitHits: [Interval] = []
    /// First and last weekly-limit reading of the day.
    public var weekPctStart: Double?
    public var weekPctEnd: Double?
    public var summary: StoredSummary?
}

public struct ProjectDay: Sendable, Equatable {
    public var project: String
    public var sessionSec: Double
    public var tokens: Int
    public var cost: Double
}

public struct PeriodTotals: Sendable, Equatable {
    public var sessionSec = 0.0, userSec = 0.0, tokens = 0, cost = 0.0
    public init() {}
}

public struct WeekDetail: Sendable {
    public var days: [String]
    /// Per day, per project (merged over tools).
    public var projects: [[ProjectDay]]
    public var totals: PeriodTotals
    public var previous: PeriodTotals
    /// Previous week's session seconds per project.
    public var previousSec: [String: Double]
    /// Last weekly-limit reading of each day; nil = none that day.
    public var limitByDay: [Double?]
}

/// Day string -> its [start, end) as the caller cuts days; `Time.dayBounds` is this machine's time zone.
public typealias DayBounds = (String) -> (Timestamp, Timestamp)?

/// What one stretch of time holds, read from usage_hour, tool_use, activity and your time instead of `day_agg` (which
/// follows the zone of each machine that scanned), so the caller's zone cuts the days. Usage is kept by UTC hour: an
/// hour belongs to the stretch it starts in, so with an offset that is not whole hours the edges are rounded to it.
struct Span {
    var tokens = TokenTotals(), cost = 0.0, sessionSec = 0.0, userSec = 0.0
    var project: [String: UsageLine] = [:], model: [String: UsageLine] = [:], agent: [String: UsageLine] = [:]
    var host: [String: UsageLine] = [:]
    var tools: [String: Int] = [:]
    /// Session seconds per project, merged over tools.
    var projectSec: [String: Double] = [:]
}

extension Query {
    /// The longest a stretch of work or of your time is assumed to run unbroken: the time scans start this much before
    /// a range (the index is on `start`; without a lower bound every query would walk the whole history).
    // ponytail: a stretch over 2 days unbroken would be cut at that edge; an index on "end" if one ever is.
    static let longestStretch = 2 * 86400

    /// `detail: false` stops after the totals and cost (the menu bar needs only those).
    public func day(_ day: String, detail: Bool = true, bounds: DayBounds = Time.dayBounds) throws -> DayDetail {
        var d = DayDetail(day: day)
        guard let (s, e) = bounds(day) else { return d }
        let x = try spans([(s, e)])[0]
        d.tokens = x.tokens; d.cost = x.cost; d.sessionSec = x.sessionSec; d.userSec = x.userSec
        d.byTool = x.tools.map { NameCount(name: $0.key, count: $0.value) }.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        guard detail else { return d }
        func ranked(_ x: [String: UsageLine]) -> [UsageLine] { x.values.sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) } }
        d.byProject = ranked(x.project); d.byModel = ranked(x.model); d.byHost = ranked(x.host); d.byAgent = ranked(x.agent)

        d.lanes = try lanes(from: s, to: e)
        d.limitHits = try limitHits(from: s, to: e)
        try db.query("""
            SELECT used_pct FROM limit_snapshot WHERE window = 'seven_day' AND tool = 'claude' AND ts >= ? AND ts < ? ORDER BY ts
            """, [.real(s), .real(e)]) { row in
            if d.weekPctStart == nil { d.weekPctStart = row.real(0) }
            d.weekPctEnd = row.real(0)
        }
        d.summary = try db.one("SELECT engine, text, created FROM summary WHERE day = ? ORDER BY created DESC LIMIT 1",
                               [.text(day)]) { StoredSummary(engine: $0.text(0) ?? "", text: $0.text(1) ?? "", created: $0.real(2)) }
        return d
    }

    /// One `Span` per range (ranges must not overlap; an empty one stays empty). Session time is the union per session
    /// summed over sessions (what `day_agg` holds); your time is one union over all machines (`day_agg` keeps it per
    /// host, so its sum counts an hour on two machines twice).
    func spans(_ ranges: [(Timestamp, Timestamp)]) throws -> [Span] {
        var out = ranges.map { _ in Span() }
        let real = ranges.filter { $0.1 > $0.0 }
        guard let lo = real.map(\.0).min(), let hi = real.map(\.1).max() else { return out }
        func index(_ t: Timestamp) -> Int? { ranges.firstIndex { t >= $0.0 && t < $0.1 } }
        let dirs = try Projects.load(db)
        func covered(_ merged: [Interval], _ r: (Timestamp, Timestamp)) -> Double {
            merged.reduce(0) { $0 + max(0, min($1.end, r.1) - max($1.start, r.0)) }
        }
        // Tokens count for the project of the directory each request was made in (the session's when not known).
        try db.query("""
            SELECT u.hour, u.cwd, coalesce(s.project,''), coalesce(s.host,''), u.agent, u.model, sum(u.input), sum(u.output),
                   sum(u.cache_read), sum(u.cache_write), sum(u.cache_write_1h), sum(u.requests), s.cwd
            FROM usage_hour u LEFT JOIN session s ON s.id = u.session_id WHERE u.hour >= ? AND u.hour < ?
            GROUP BY 1, 2, 3, 4, 5, 6, 13
            """, [.real(lo), .real(hi)]) { r in
            guard let i = index(r.real(0)) else { return }
            let m = r.text(5) ?? "", t = r.int(6) + r.int(7) + r.int(8) + r.int(9)
            let c = Pricing.cost(model: m, input: r.int(6), output: r.int(7), cacheRead: r.int(8), cacheWrite: r.int(9),
                                 cacheWrite1h: r.int(10))
            out[i].tokens.input += r.int(6); out[i].tokens.output += r.int(7); out[i].tokens.cacheRead += r.int(8)
            out[i].tokens.cacheWrite += r.int(9); out[i].tokens.cacheWrite1h += r.int(10); out[i].tokens.requests += r.int(11)
            out[i].cost += c
            Self.add(&out[i].project, Projects.of(r.text(1), session: r.text(2) ?? "", started: r.text(12), host: r.text(3),
                                                  dirs: dirs), t, c)
            Self.add(&out[i].host, r.text(3) ?? "", t, c)
            Self.add(&out[i].agent, r.text(4) ?? "", t, c); Self.add(&out[i].model, m, t, c)
        }
        try db.query("SELECT hour, name, sum(n) FROM tool_use WHERE hour >= ? AND hour < ? GROUP BY 1, 2", [.real(lo), .real(hi)]) { r in
            if let i = index(r.real(0)) { out[i].tools[r.text(1) ?? "?", default: 0] += r.int(2) }
        }
        // Session time: union per session; per project (the directory of each interval), union per session and project.
        var working: [String: (all: [Interval], projects: [String: [Interval]])] = [:]
        try db.query("""
            SELECT a.session_id, coalesce(s.project,''), a.start, a."end", a.cwd, s.cwd, s.host FROM activity a
            LEFT JOIN session s ON s.id = a.session_id
            WHERE a.kind = 'working' AND a.start < ?1 AND a.start > ?2 - \(Self.longestStretch) AND a."end" > ?2
            """, [.real(hi), .real(lo)]) { r in
            let sid = r.text(0) ?? "", iv = Interval(r.real(2), r.real(3))
            working[sid, default: ([], [:])].all.append(iv)
            working[sid]!.projects[Projects.of(r.text(4), session: r.text(1) ?? "", started: r.text(5), host: r.text(6),
                                               dirs: dirs), default: []].append(iv)
        }
        for e in working.values {
            let merged = Intervals.merge(e.all)
            let byProject = e.projects.mapValues(Intervals.merge)
            for i in ranges.indices {
                let sec = covered(merged, ranges[i])
                guard sec > 0 else { continue }
                out[i].sessionSec += sec
                for (p, ivs) in byProject {
                    let x = covered(ivs, ranges[i])
                    if x > 0 { out[i].projectSec[p, default: 0] += x }
                }
            }
        }
        // Your time on this Mac and on each server (`activity` kind 'user' under its export file) as one union: an
        // hour worked on two machines at once is one hour of yours.
        var user: [Interval] = []
        try db.query("""
            SELECT start, "end" FROM user_activity WHERE start < ?1 AND start > ?2 - \(Self.longestStretch) AND "end" > ?2
            UNION ALL SELECT start, "end" FROM activity
            WHERE kind = 'user' AND start < ?1 AND start > ?2 - \(Self.longestStretch) AND "end" > ?2
            """, [.real(hi), .real(lo)]) { user.append(Interval($0.real(0), $0.real(1))) }
        let merged = Intervals.merge(user)
        for i in ranges.indices { out[i].userSec = covered(merged, ranges[i]) }
        return out
    }

    static func add(_ x: inout [String: UsageLine], _ key: String, _ tokens: Int, _ cost: Double) {
        x[key, default: UsageLine(name: key, tokens: 0, cost: 0)].tokens += tokens
        x[key]!.cost += cost
    }

    /// Sessions with intervals in [from, to), clipped, in order of their first interval.
    func lanes(from s: Timestamp, to e: Timestamp) throws -> [SessionLane] {
        var working: [String: [Interval]] = [:], waiting: [String: [Interval]] = [:]
        var meta: [String: (title: String?, project: String?, host: String?)] = [:]
        try db.query("""
            SELECT a.session_id, a.start, a."end", a.kind, s.title, s.project, s.host FROM activity a
            LEFT JOIN session s ON s.id = a.session_id
            WHERE a.start < ?1 AND a.start > ?2 - \(Self.longestStretch) AND a."end" > ?2 AND a.kind IN ('working', 'waiting')
            """, [.real(e), .real(s)]) { row in
            let iv = Interval(max(s, row.real(1)), min(e, row.real(2)))
            guard iv.end > iv.start, let id = row.text(0) else { return }
            if row.text(3) == "waiting" { waiting[id, default: []].append(iv) } else { working[id, default: []].append(iv) }
            meta[id] = (row.text(4), row.text(5), row.text(6))
        }
        var out: [SessionLane] = []
        for id in Set(working.keys).union(waiting.keys) {
            let ivs = Intervals.merge(working[id] ?? []).map { LaneInterval(start: $0.start, end: $0.end, waiting: false) }
                + Intervals.merge(waiting[id] ?? []).map { LaneInterval(start: $0.start, end: $0.end, waiting: true) }
            var lane = SessionLane(id: id, intervals: ivs)
            (lane.title, lane.project, lane.host) = meta[id] ?? (nil, nil, nil)
            out.append(lane)
        }
        func first(_ l: SessionLane) -> Timestamp { l.intervals.map(\.start).min() ?? 0 }
        return out.sorted { (first($0), $0.id) < (first($1), $1.id) }
    }

    /// 5-hour readings at 100 % chained into stretches; a stretch ends at the next lower reading or the reset.
    /// A stretch carried over from the day before starts at midnight.
    func limitHits(from s: Timestamp, to e: Timestamp) throws -> [Interval] {
        var out: [Interval] = []
        var open: (start: Timestamp, resets: Timestamp?)?
        if let (pct, resets) = try db.one("""
            SELECT used_pct, resets_at FROM limit_snapshot WHERE window = 'five_hour' AND tool = 'claude' AND ts < ?
            ORDER BY ts DESC LIMIT 1
            """, [.real(s)], { ($0.real(0), $0.optReal(1)) }), pct >= 99.5, let r = resets, r > s {
            open = (s, r)
        }
        func close(_ at: Timestamp) {
            guard let o = open else { return }
            out.append(Interval(o.start, min(at, o.resets ?? at, e)))
            open = nil
        }
        try db.query("""
            SELECT used_pct, resets_at, ts FROM limit_snapshot WHERE window = 'five_hour' AND tool = 'claude' AND ts >= ? AND ts < ?
            ORDER BY ts
            """, [.real(s), .real(e)]) { row in
            let full = row.real(0) >= 99.5, ts = row.real(2)
            if full, open == nil { open = (ts, row.optReal(1)) } else if !full { close(ts) }
        }
        close(e)
        return out
    }

    /// Seven days from `start` and the seven before.
    public func week(from start: String, bounds: DayBounds = Time.dayBounds) throws -> WeekDetail {
        let days = (0..<7).map { Time.addDays(start, $0) ?? start }, before = (1...7).map { Time.addDays(start, -$0) ?? start }
        let ranges = (days + before).map { bounds($0) ?? (0, 0) }
        let x = try spans(ranges)
        func totals(_ xs: ArraySlice<Span>) -> PeriodTotals {
            var t = PeriodTotals()
            for s in xs { t.sessionSec += s.sessionSec; t.userSec += s.userSec; t.tokens += s.tokens.total; t.cost += s.cost }
            return t
        }
        // Projects of each day merged over tools: session time and the tokens of their sessions.
        let projects = x.prefix(7).map { s in
            Set(s.projectSec.keys).union(s.project.keys).map { p in
                ProjectDay(project: p, sessionSec: s.projectSec[p] ?? 0, tokens: s.project[p]?.tokens ?? 0, cost: s.project[p]?.cost ?? 0)
            }.sorted { ($0.sessionSec, $1.project) > ($1.sessionSec, $0.project) }
        }
        var previousSec: [String: Double] = [:]
        for s in x.suffix(7) { for (p, sec) in s.projectSec { previousSec[p, default: 0] += sec } }
        var limit: [Double?] = []
        for (s, e) in ranges.prefix(7) {
            limit.append(e > s ? try db.one("""
                SELECT used_pct FROM limit_snapshot WHERE window = 'seven_day' AND tool = 'claude' AND ts >= ? AND ts < ?
                ORDER BY ts DESC LIMIT 1
                """, [.real(s), .real(e)]) { $0.real(0) } : nil)
        }
        return WeekDetail(days: days, projects: projects, totals: totals(x.prefix(7)), previous: totals(x.suffix(7)),
                          previousSec: previousSec, limitByDay: limit)
    }

    /// Session hours of each day from `first` for `count` days.
    public func hours(from first: String, count: Int, bounds: DayBounds = Time.dayBounds) throws -> [Double] {
        try spans((0..<count).map { bounds(Time.addDays(first, $0) ?? first) ?? (0, 0) }).map { $0.sessionSec / 3600 }
    }
}
