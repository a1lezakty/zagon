/// Read-side queries behind `today`, `day`, `week`, `sessions` (CLI, later MCP and the Mac app).
public struct TokenTotals: Codable, Sendable, Equatable {
    /// `cacheWrite` is all cache writes; `cacheWrite1h` the part kept for an hour (priced higher).
    public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cacheWrite1h = 0, requests = 0
    public var total: Int { input + output + cacheRead + cacheWrite }
    public init() {}
    enum CodingKeys: String, CodingKey { case input, output, cacheRead, cacheWrite, cacheWrite1h = "cache_write_1h", requests, total }
    enum Converted: String, CodingKey { case cacheWrite1h }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(input, forKey: .input); try c.encode(output, forKey: .output)
        try c.encode(cacheRead, forKey: .cacheRead); try c.encode(cacheWrite, forKey: .cacheWrite)
        try c.encode(cacheWrite1h, forKey: .cacheWrite1h)
        try c.encode(requests, forKey: .requests); try c.encode(total, forKey: .total)
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        input = try c.decode(Int.self, forKey: .input); output = try c.decode(Int.self, forKey: .output)
        cacheRead = try c.decode(Int.self, forKey: .cacheRead); cacheWrite = try c.decode(Int.self, forKey: .cacheWrite)
        // `cache_write_1h` as written, or `cacheWrite1h` through a decoder that converts from snake case
        cacheWrite1h = try c.decodeIfPresent(Int.self, forKey: .cacheWrite1h)
            ?? d.container(keyedBy: Converted.self).decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0
        requests = try c.decode(Int.self, forKey: .requests)
    }
    /// Six columns from `i`: input, output, cache_read, cache_write, cache_write_1h, requests.
    mutating func add(_ r: Row, from i: Int32) {
        input += r.int(i); output += r.int(i + 1); cacheRead += r.int(i + 2); cacheWrite += r.int(i + 3)
        cacheWrite1h += r.int(i + 4); requests += r.int(i + 5)
    }
    mutating func add(_ o: TokenTotals) {
        input += o.input; output += o.output; cacheRead += o.cacheRead; cacheWrite += o.cacheWrite
        cacheWrite1h += o.cacheWrite1h; requests += o.requests
    }
}

/// `cost` everywhere: USD at API list prices (`Pricing`), for comparison; a subscription is billed differently.
/// `unpriced` next to it: tokens of models with no known price, left out of `cost` (shown as "$ ?").
public struct ModelLine: Codable, Sendable {
    public var model: String; public var tokens: TokenTotals; public var cost = 0.0; public var unpriced = 0
}
public struct ProjectLine: Codable, Sendable {
    public var tool: String, project: String
    public var tokens: TokenTotals
    public var sessionSec: Double
    public var toolCalls: Int
    public var cost = 0.0, unpriced = 0
}
public struct NameCount: Codable, Sendable { public var name: String; public var count: Int }

public struct SessionLine: Codable, Sendable {
    public var id: String
    public var tool: String
    public var title: String?
    public var project: String?
    public var gitBranch: String?
    public var model: String?
    public var status: String?
    /// The tool waiting for approval in `waiting_permission`.
    public var statusDetail: String?
    public var startedAt: Timestamp?
    public var lastAt: Timestamp?
    public var userMsgs: Int
    /// nil = the source did not say.
    public var archived: Bool?
    /// Tokens and working time inside the report range (whole history for `sessions`).
    public var tokens: TokenTotals
    public var workingSec: Double
    public var cost = 0.0, unpriced = 0
}

public struct DayReport: Codable, Sendable {
    public var day: String
    public var tokens = TokenTotals()
    public var cost = 0.0, unpriced = 0
    public var toolCalls = 0
    /// Sum over sessions of each session's merged working time.
    public var sessionSec = 0.0
    /// Your time: union of activity around your actions across all sessions.
    public var userSec = 0.0
    public var models: [ModelLine] = []
    public var projects: [ProjectLine] = []
    public var tools: [NameCount] = []
    /// Total tokens per local hour 0...23.
    public var hours: [Int] = Array(repeating: 0, count: 24)
    public var sessions: [SessionLine] = []
}

public struct WeekReport: Codable, Sendable {
    public struct DayLine: Codable, Sendable {
        public var day: String; public var tokens: TokenTotals; public var sessionSec: Double; public var userSec: Double
        public var cost = 0.0, unpriced = 0
    }
    public var from: String, to: String
    public var days: [DayLine]
    public var tokens: TokenTotals
    public var cost = 0.0, unpriced = 0
    public var sessionSec: Double, userSec: Double
    public var previous: TokenTotals
    public var previousCost = 0.0
    public var previousSessionSec: Double, previousUserSec: Double
    public var projects: [ProjectLine]
}

public struct Reports {
    public let db: SQLite
    public init(store: Store) { db = store.db }

    public func day(_ day: String, withSessions: Bool = true) throws -> DayReport {
        var r = DayReport(day: day)
        try db.query("""
            SELECT tool, project, model, input, output, cache_read, cache_write, cache_write_1h, requests, tool_calls, session_sec,
                   user_sec
            FROM day_agg WHERE day=?
            """, [.text(day)]) { row in
            let tool = row.text(0) ?? "", project = row.text(1) ?? "", model = row.text(2) ?? ""
            if tool.isEmpty && project.isEmpty && model.isEmpty {
                r.tokens.add(row, from: 3); r.toolCalls += row.int(9); r.sessionSec += row.real(10); r.userSec += row.real(11)
                return
            }
            var t = TokenTotals(); t.add(row, from: 3)
            let cost = Pricing.cost(model: model, t), unpriced = Pricing.unpriced(model: model, t)
            r.cost += cost; r.unpriced += unpriced
            if let i = r.projects.firstIndex(where: { $0.tool == tool && $0.project == project }) {
                r.projects[i].tokens.add(t); r.projects[i].sessionSec += row.real(10); r.projects[i].toolCalls += row.int(9)
                r.projects[i].cost += cost; r.projects[i].unpriced += unpriced
            } else {
                r.projects.append(ProjectLine(tool: tool, project: project, tokens: t, sessionSec: row.real(10),
                                              toolCalls: row.int(9), cost: cost, unpriced: unpriced))
            }
            if !model.isEmpty {
                if let i = r.models.firstIndex(where: { $0.model == model }) {
                    r.models[i].tokens.add(t); r.models[i].cost += cost; r.models[i].unpriced += unpriced
                } else { r.models.append(ModelLine(model: model, tokens: t, cost: cost, unpriced: unpriced)) }
            }
        }
        r.models.sort { $0.tokens.total > $1.tokens.total }
        r.projects.sort { ($0.tokens.total, $0.sessionSec) > ($1.tokens.total, $1.sessionSec) }
        guard let (s, e) = Time.dayBounds(day) else { return r }
        try db.query("SELECT name, sum(n) FROM tool_use WHERE hour >= ? AND hour < ? GROUP BY name ORDER BY 2 DESC",
                     [.real(s), .real(e)]) { r.tools.append(NameCount(name: $0.text(0) ?? "?", count: $0.int(1))) }
        try db.query("""
            SELECT hour, sum(input + output + cache_read + cache_write) FROM usage_hour WHERE hour >= ? AND hour < ? GROUP BY hour
            """, [.real(s), .real(e)]) { row in
            let i = Int((row.real(0) - s) / 3600)
            if i >= 0 && i < 24 { r.hours[i] += row.int(1) }   // 23/25-hour DST days fold into the edges
        }
        if withSessions { r.sessions = try sessions(from: s, to: e) }
        return r
    }

    /// Sessions with tokens or working time in [from, to), most tokens first (archived ones included: history).
    /// Without a range: the live list, by last activity, archived sessions left out.
    public func sessions(from: Timestamp? = nil, to: Timestamp? = nil, limit: Int = 50) throws -> [SessionLine] {
        let s = from ?? -Double.greatestFiniteMagnitude, e = to ?? Double.greatestFiniteMagnitude
        var tokens: [String: TokenTotals] = [:], cost: [String: Double] = [:], unpriced: [String: Int] = [:]
        try db.query("""
            SELECT session_id, sum(input), sum(output), sum(cache_read), sum(cache_write), sum(cache_write_1h), sum(requests),
                   model
            FROM usage_hour WHERE hour >= ? AND hour < ? GROUP BY session_id, model
            """, [.real(s), .real(e)]) {
            let id = $0.text(0) ?? ""
            var t = TokenTotals(); t.add($0, from: 1)
            tokens[id, default: TokenTotals()].add(t)
            cost[id, default: 0] += Pricing.cost(model: $0.text(7) ?? "", t)
            unpriced[id, default: 0] += Pricing.unpriced(model: $0.text(7) ?? "", t)
        }
        var working: [String: Double] = [:]
        for (sid, entry) in try SessionTime.working(db, from: s, to: e) {
            working[sid] = Intervals.covered(entry.intervals, from: s, to: e)
        }
        var ids = Set(tokens.keys).union(working.filter { $0.value > 0 }.keys)
        if from == nil {
            ids = []
            try db.query("""
                SELECT id FROM session WHERE last_at IS NOT NULL AND coalesce(archived, 0) = 0 ORDER BY last_at DESC LIMIT ?
                """, [.int(Int64(limit))]) {
                if let id = $0.text(0) { ids.insert(id) }
            }
        }
        var out: [SessionLine] = []
        for id in ids {
            try db.query("""
                SELECT id, tool, title, project, git_branch, model, status, started_at, last_at, user_msgs, archived,
                       status_detail FROM session WHERE id=?
                """, [.text(id)]) { r in
                out.append(SessionLine(id: id, tool: r.text(1) ?? "", title: r.text(2), project: r.text(3), gitBranch: r.text(4),
                                       model: r.text(5), status: r.text(6), statusDetail: r.text(11),
                                       startedAt: r.optReal(7), lastAt: r.optReal(8),
                                       userMsgs: r.int(9), archived: r.optInt(10).map { $0 != 0 },
                                       tokens: tokens[id] ?? TokenTotals(), workingSec: working[id] ?? 0,
                                       cost: cost[id] ?? 0, unpriced: unpriced[id] ?? 0))
            }
        }
        if from == nil { out.sort { ($0.lastAt ?? 0) > ($1.lastAt ?? 0) } }
        else { out.sort { ($0.tokens.total, $0.workingSec) > ($1.tokens.total, $1.workingSec) } }
        return Array(out.prefix(limit))
    }

    /// Seven local days ending at `end` (inclusive), compared with the seven days before.
    public func week(ending end: String) throws -> WeekReport {
        let start = Time.addDays(end, -6) ?? end
        var days: [WeekReport.DayLine] = []
        var projects: [ProjectLine] = []
        var tokens = TokenTotals(), ss = 0.0, us = 0.0, cost = 0.0, unpriced = 0
        for k in 0..<7 {
            let d = Time.addDays(start, k) ?? start
            let r = try self.day(d, withSessions: false)
            days.append(.init(day: d, tokens: r.tokens, sessionSec: r.sessionSec, userSec: r.userSec, cost: r.cost,
                              unpriced: r.unpriced))
            tokens.add(r.tokens); ss += r.sessionSec; us += r.userSec; cost += r.cost; unpriced += r.unpriced
            for p in r.projects {
                if let i = projects.firstIndex(where: { $0.tool == p.tool && $0.project == p.project }) {
                    projects[i].tokens.add(p.tokens); projects[i].sessionSec += p.sessionSec; projects[i].toolCalls += p.toolCalls
                    projects[i].cost += p.cost; projects[i].unpriced += p.unpriced
                } else { projects.append(p) }
            }
        }
        var prev = TokenTotals(), pss = 0.0, pus = 0.0, pcost = 0.0
        for k in 1...7 {
            let r = try self.day(Time.addDays(start, -k) ?? start, withSessions: false)
            prev.add(r.tokens); pss += r.sessionSec; pus += r.userSec; pcost += r.cost
        }
        projects.sort { ($0.tokens.total, $0.sessionSec) > ($1.tokens.total, $1.sessionSec) }
        return WeekReport(from: start, to: end, days: days, tokens: tokens, cost: cost, unpriced: unpriced, sessionSec: ss, userSec: us,
                          previous: prev, previousCost: pcost, previousSessionSec: pss, previousUserSec: pus, projects: projects)
    }
}
