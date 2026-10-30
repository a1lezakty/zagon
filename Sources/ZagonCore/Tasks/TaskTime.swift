/// Time, tokens and limit share per task over a range. `nil` task = sessions linked to no task.
public struct TaskTimeLine: Codable, Sendable {
    public var taskId: Int?
    /// Worked time on the chosen base (your time by default), parallel tasks split by the activity of their sessions.
    public var userSec = 0.0
    /// Working time of the task's sessions (each session merged on its own; parallel sessions add up).
    public var sessionSec = 0.0
    public var tokens = TokenTotals()
    /// Estimated share of the weekly limit (percent points) by tool: Claude `seven_day`, Codex `secondary`.
    public var weekPct: [String: Double] = [:]
    public var firstActive: Timestamp?
    public var sessions: [String] = []
    public init(taskId: Int?) { self.taskId = taskId }
}

/// One stretch of your time and how it splits between tasks.
public struct UserSlice: Sendable {
    public var interval: Interval
    public var shares: [Int?: Double]
    /// When each task was first active inside the stretch.
    public var first: [Int?: Timestamp]
}

public struct TaskTimeReport: Sendable {
    public var lines: [Int?: TaskTimeLine]
    public var slices: [UserSlice]
    public var userSec: Double { slices.reduce(0) { $0 + $1.interval.length } }
}

public enum TaskTime {
    static let weekWindow = ["claude": "seven_day", "codex": "secondary"]

    /// What counts as worked time: the wall-clock union of all sessions' working intervals (default: people log the
    /// time their agents worked) or only your time (`user_activity`, around your own actions).
    public enum Base: String, Sendable, CaseIterable { case user, sessions }

    /// Your time in [from, to) is cut at the edges of every session's activity cover (working intervals plus the
    /// gaps between its own user actions up to `idleGap`) and where its task links start or end. Each piece goes to the
    /// tasks the sessions active in it were linked to at that moment, one share per linked session (split equally
    /// between that session's tasks); sessions with no link at that moment take nothing from them (one slot, one task,
    /// as people log it) and count as "no task" only when no linked session is active. Pieces where no session was
    /// active go to the tasks in proportion to the rest of the same stretch.
    public static func compute(_ store: Store, from: Timestamp, to: Timestamp, idleGap: Double = 20 * 60,
                                base: Base = .sessions) throws -> TaskTimeReport {
        let db = store.db
        let links = try Tasks(store: store).linkMap()
        func tasks(_ s: String, at t: Timestamp) -> [(task: Int?, weight: Double)] {
            let x = links.tasks(s, at: t)
            return x.isEmpty ? [(nil, 1)] : x.map { ($0.task, $0.weight) }
        }
        /// Seconds of a session's intervals per task, cut where its links start or end.
        func byTask(_ s: String, _ ivs: [Interval]) -> [Int?: Double] {
            var out: [Int?: Double] = [:]
            let edges = links.edges(s)
            for iv in ivs where iv.end > iv.start {
                let cuts = [iv.start] + edges.filter { $0 > iv.start && $0 < iv.end } + [iv.end]
                for i in 0..<(cuts.count - 1) {
                    for (t, x) in tasks(s, at: (cuts[i] + cuts[i + 1]) / 2) { out[t, default: 0] += (cuts[i + 1] - cuts[i]) * x }
                }
            }
            return out
        }

        var users: [Interval] = []
        try db.query("SELECT start, \"end\" FROM user_activity WHERE start < ? AND \"end\" > ? ORDER BY start",
                     [.real(to), .real(from)]) { users.append(Interval(max(from, $0.real(0)), min(to, $0.real(1)))) }

        let working = try SessionTime.working(db, from: from, to: to)
        if base == .sessions {
            users = Intervals.merge(working.values.flatMap(\.intervals)).compactMap { iv -> Interval? in
                let x = Interval(max(from, iv.start), min(to, iv.end)); return x.end > x.start ? x : nil
            }
        }
        var actions: [String: [Timestamp]] = [:]
        try db.query("SELECT session_id, ts FROM user_action WHERE ts >= ? AND ts < ?",
                     [.real(from - idleGap), .real(to + idleGap)]) { actions[$0.text(0) ?? "", default: []].append($0.real(1)) }
        var cover: [String: [Interval]] = [:]
        for sid in Set(working.keys).union(actions.keys) {
            let c = Intervals.merge((working[sid]?.intervals ?? []) + Intervals.chain(actions[sid] ?? [], gap: idleGap))
                .compactMap { iv -> Interval? in
                    let x = Interval(max(from, iv.start), min(to, iv.end)); return x.end > x.start ? x : nil
                }
            if !c.isEmpty { cover[sid] = c }
        }

        var lines: [Int?: TaskTimeLine] = [:]
        func line(_ t: Int?) -> TaskTimeLine { lines[t] ?? TaskTimeLine(taskId: t) }

        var slices: [UserSlice] = []
        for u in users where u.end > u.start {
            let active = cover.filter { $0.value.contains { $0.start < u.end && $0.end > u.start } }
            var cuts = [u.start, u.end]
            for (sid, ivs) in active {
                for iv in ivs { cuts += [iv.start, iv.end].filter { $0 > u.start && $0 < u.end } }
                cuts += links.edges(sid).filter { $0 > u.start && $0 < u.end }
            }
            cuts = Array(Set(cuts)).sorted()
            var covered: [Int?: Double] = [:], first: [Int?: Timestamp] = [:], uncovered = 0.0
            for i in 0..<(cuts.count - 1) {
                let a = cuts[i], b = cuts[i + 1], mid = (a + b) / 2
                var w: [Int?: Double] = [:]
                for (sid, ivs) in active where ivs.contains(where: { $0.start <= mid && mid < $0.end }) {
                    for (t, x) in tasks(sid, at: mid) { w[t, default: 0] += x }
                }
                if w.keys.contains(where: { $0 != nil }) { w[nil] = nil }
                let total = w.values.reduce(0, +)
                guard total > 0 else { uncovered += b - a; continue }
                for (t, x) in w {
                    covered[t, default: 0] += (b - a) * x / total
                    first[t] = min(first[t] ?? a, a)
                }
            }
            let sum = covered.values.reduce(0, +)
            var shares: [Int?: Double] = [:]
            if sum > 0 { for (t, c) in covered { shares[t] = c + uncovered * c / sum } }
            else { shares[nil] = u.length; first[nil] = u.start }
            for (t, s) in shares {
                var l = line(t); l.userSec += s; l.firstActive = min(l.firstActive ?? first[t]!, first[t]!); lines[t] = l
            }
            slices.append(UserSlice(interval: u, shares: shares, first: first))
        }

        // Session time per task: the session's working time cut by its links. Tokens: per hour, in proportion to the
        // session's working time per task in that hour (the link at mid-hour if it did not work then).
        var merged: [String: [Interval]] = [:]
        for (sid, e) in working {
            merged[sid] = Intervals.merge(e.intervals).compactMap { iv -> Interval? in
                let x = Interval(max(from, iv.start), min(to, iv.end)); return x.end > x.start ? x : nil
            }
        }
        var tool: [String: String] = [:]
        for (sid, e) in working { tool[sid] = e.tool }
        for (sid, ivs) in merged {
            for (t, sec) in byTask(sid, ivs) {
                var l = line(t)
                l.sessionSec += sec
                if !l.sessions.contains(sid) { l.sessions.append(sid) }
                if l.firstActive == nil, let s = ivs.first?.start { l.firstActive = s }
                lines[t] = l
            }
        }
        var toolWeight: [String: Double] = [:], taskToolWeight: [Int?: [String: Double]] = [:]
        try db.query("""
            SELECT u.session_id, u.hour, sum(u.input), sum(u.output), sum(u.cache_read), sum(u.cache_write),
                   sum(u.cache_write_1h), sum(u.requests), coalesce(s.tool, '') FROM usage_hour u
            LEFT JOIN session s ON s.id = u.session_id
            WHERE u.hour >= ? AND u.hour < ? GROUP BY u.session_id, u.hour
            """, [.real(from), .real(to)]) { r in
            let sid = r.text(0) ?? "", hour = r.real(1), tl = tool[sid] ?? r.text(8) ?? ""
            var tk = TokenTotals(); tk.add(r, from: 2)
            let inHour = (merged[sid] ?? []).compactMap { iv -> Interval? in
                let x = Interval(max(hour, iv.start), min(hour + 3600, iv.end)); return x.end > x.start ? x : nil
            }
            var split = byTask(sid, inHour)
            let total = split.values.reduce(0, +)
            if total > 0 { for k in split.keys { split[k]! /= total } }
            else { split = Dictionary(tasks(sid, at: hour + 1800).map { ($0.task, $0.weight) }, uniquingKeysWith: +) }
            toolWeight[tl, default: 0] += limitWeight(tk)
            for (t, x) in split {
                var l = line(t)
                l.tokens.add(scaled(tk, x))
                if !l.sessions.contains(sid) { l.sessions.append(sid) }
                lines[t] = l
                taskToolWeight[t, default: [:]][tl, default: 0] += limitWeight(tk) * x
            }
        }
        for (tl, window) in weekWindow {
            let delta = try limitGrowth(db, tool: tl, window: window, from: from, to: to)
            guard delta > 0, let all = toolWeight[tl], all > 0 else { continue }
            for (t, w) in taskToolWeight { if let x = w[tl], x > 0 { lines[t]?.weekPct[tl] = delta * x / all } }
        }
        return TaskTimeReport(lines: lines, slices: slices)
    }

    /// ponytail: tokens weighted roughly by price (output 5x, cache reads 0.1x), one model; per-model prices if needed.
    static func limitWeight(_ t: TokenTotals) -> Double {
        Double(t.input + t.cacheWrite) + 5 * Double(t.output) + 0.1 * Double(t.cacheRead)
    }

    static func scaled(_ t: TokenTotals, _ x: Double) -> TokenTotals {
        guard x != 1 else { return t }
        var o = TokenTotals()
        o.input = Int((Double(t.input) * x).rounded()); o.output = Int((Double(t.output) * x).rounded())
        o.cacheRead = Int((Double(t.cacheRead) * x).rounded()); o.cacheWrite = Int((Double(t.cacheWrite) * x).rounded())
        o.cacheWrite1h = Int((Double(t.cacheWrite1h) * x).rounded())
        o.requests = Int((Double(t.requests) * x).rounded())
        return o
    }

    /// Sum of the increases of a limit's used percent inside [from, to) (drops at a reset are not subtracted).
    static func limitGrowth(_ db: SQLite, tool: String, window: String, from: Timestamp, to: Timestamp) throws -> Double {
        var prev = try db.one("SELECT used_pct FROM limit_snapshot WHERE tool=? AND window=? AND ts < ? ORDER BY ts DESC LIMIT 1",
                              [.text(tool), .text(window), .real(from)]) { $0.real(0) }
        var sum = 0.0
        try db.query("SELECT used_pct FROM limit_snapshot WHERE tool=? AND window=? AND ts >= ? AND ts < ? ORDER BY ts",
                     [.text(tool), .text(window), .real(from), .real(to)]) { r in
            let v = r.real(0)
            if let p = prev, v > p { sum += v - p }
            prev = v
        }
        return sum
    }
}
