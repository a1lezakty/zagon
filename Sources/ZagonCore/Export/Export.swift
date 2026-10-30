#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `zagon export --since <seq>`: NDJSON of the totals changed after `seq`, for the Mac app over SSH.
/// Lines (keys in snake_case):
/// - `{"type":"export","schema","since","seq","version"}` first; pass `seq` as the next `--since`;
/// - `{"type":"session",…}` per session changed after `since` (all `session` columns), each followed by
///   `{"type":"activity","session_id","kind","start","end"}` lines: the session's complete working / waiting
///   intervals (merged per kind), which replace what the client had for that session;
/// - `{"type":"day","day","host","seq","start","end","rows":[…],"usage":[…],"tools":[…],"user":[…]}` per local day
///   with a change: the complete `day_agg` rows of that day and host, the `usage_hour` and `tool_use` rows of the day
///   (summed over files) and your-time intervals clipped to the day; together they replace what the client had for
///   that day (rows that vanished are gone). `ExportImport` is the reference client;
/// - `{"type":"limit",…}` the latest reading per (tool, window), every time (a handful of rows).
public enum Export {
    struct Header: Encodable { var type = "export"; var schema: Int; var since: Int; var seq: Int; var version: String? }
    struct SessionLine: Encodable {
        var type = "session"
        var id: String, tool: String, host: String?, project: String?, cwd: String?, gitBranch: String?, title: String?
        var model: String?, startedAt: Double?, lastAt: Double?, status: String?, statusAt: Double?, statusDetail: String?
        var userMsgs: Int
        var archived: Bool?, seq: Int
        /// The session that typed its last typed message (v6); nil = the human.
        var driver: String?
    }
    struct DayRow: Encodable {
        var tool: String, project: String, model: String
        var input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int, requests: Int, toolCalls: Int
        var sessionSec: Double, userSec: Double
        enum CodingKeys: String, CodingKey {
            case tool, project, model, input, output, cacheRead, cacheWrite, cacheWrite1h = "cache_write_1h", requests, toolCalls
            case sessionSec, userSec
        }
    }
    /// `cwd` nil: a `usage` row (summed over directories, the shape clients before v5 import); set: a `usage_cwd` row.
    struct UsageRow: Encodable {
        var sessionId: String, agent: String, hour: Int, model: String, cwd: String?
        var input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int, requests: Int, toolCalls: Int
        enum CodingKeys: String, CodingKey {
            case sessionId, agent, hour, model, cwd, input, output, cacheRead, cacheWrite, cacheWrite1h = "cache_write_1h"
            case requests, toolCalls
        }
    }
    struct ToolRow: Encodable { var sessionId: String, hour: Int, name: String, n: Int }
    struct Span: Encodable { var start: Double, end: Double }
    struct DayLine: Encodable {
        var type = "day"; var day: String; var host: String; var seq: Int; var start: Double; var end: Double
        var rows: [DayRow]; var usage: [UsageRow]; var usageCwd: [UsageRow]; var tools: [ToolRow]; var user: [Span]
    }
    struct DirLine: Encodable { var type = "dir"; var host: String, cwd: String, project: String, home: Bool, seq: Int }
    struct ActivityLine: Encodable {
        var type = "activity"; var sessionId: String, kind: String, start: Double, end: Double, cwd: String?
    }
    struct LimitLine: Encodable {
        var type = "limit"
        var tool: String, window: String, usedPct: Double, resetsAt: Double?, windowMinutes: Int?, ts: Double
    }

    /// Writes the lines through `write`; reads one consistent snapshot of the database. `version`: the CLI's
    /// (`zagon --version`), for the header.
    public static func run(store: Store, since: Int, version: String? = nil, write: (String) -> Void) throws {
        let db = store.db
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        func out<T: Encodable>(_ v: T) throws { write(String(decoding: try e.encode(v), as: UTF8.self)) }

        try db.exec("BEGIN")  // deferred: a read snapshot, writers are not blocked
        defer { try? db.exec("COMMIT") }
        let seq = try db.one("SELECT value FROM meta WHERE key='seq'") { $0.int(0) } ?? 0
        try out(Header(schema: Store.schemaVersion, since: since, seq: seq, version: version))

        var sessions: [SessionLine] = []
        try db.query("""
            SELECT id, tool, host, project, cwd, git_branch, title, model, started_at, last_at, status, status_at, user_msgs,
                   archived, seq, status_detail, driver FROM session WHERE seq > ? ORDER BY seq
            """, [.int(Int64(since))]) { r in
            sessions.append(SessionLine(id: r.text(0) ?? "", tool: r.text(1) ?? "", host: r.text(2), project: r.text(3),
                                        cwd: r.text(4), gitBranch: r.text(5), title: r.text(6), model: r.text(7),
                                        startedAt: r.optReal(8), lastAt: r.optReal(9), status: r.text(10),
                                        statusAt: r.optReal(11), statusDetail: r.text(15), userMsgs: r.int(12),
                                        archived: r.optInt(13).map { $0 != 0 },
                                        seq: r.int(14), driver: r.text(16)))
        }
        for s in sessions {
            try out(s)
            struct KindDir: Hashable, Comparable {
                var kind: String, cwd: String?
                static func < (a: Self, b: Self) -> Bool { (a.kind, a.cwd ?? "") < (b.kind, b.cwd ?? "") }
            }
            var byKind: [KindDir: [Interval]] = [:]
            try db.query("""
                SELECT kind, start, "end", cwd FROM activity WHERE session_id = ? AND kind IN ('working', 'waiting')
                """, [.text(s.id)]) {
                byKind[KindDir(kind: $0.text(0) ?? "", cwd: $0.text(3)), default: []].append(Interval($0.real(1), $0.real(2)))
            }
            for (k, xs) in byKind.sorted(by: { $0.key < $1.key }) {
                for iv in Intervals.merge(xs) {
                    try out(ActivityLine(sessionId: s.id, kind: k.kind, start: iv.start, end: iv.end, cwd: k.cwd))
                }
            }
        }

        var dirs: [DirLine] = []
        try db.query("SELECT host, cwd, project, home, seq FROM dir_project WHERE seq > ? ORDER BY seq", [.int(Int64(since))]) {
            dirs.append(DirLine(host: $0.text(0) ?? "", cwd: $0.text(1) ?? "", project: $0.text(2) ?? "", home: $0.int(3) != 0,
                                seq: $0.int(4)))
        }
        for d in dirs { try out(d) }

        var days: [(String, String, Int)] = []
        try db.query("SELECT day, host, max(seq) FROM day_agg GROUP BY day, host HAVING max(seq) > ? ORDER BY day, host",
                     [.int(Int64(since))]) { days.append(($0.text(0) ?? "", $0.text(1) ?? "", $0.int(2))) }
        for (day, host, dseq) in days {
            var rows: [DayRow] = []
            try db.query("""
                SELECT tool, project, model, input, output, cache_read, cache_write, cache_write_1h, requests, tool_calls,
                       session_sec, user_sec
                FROM day_agg WHERE day = ? AND host = ? ORDER BY tool, project, model
                """, [.text(day), .text(host)]) { r in
                rows.append(DayRow(tool: r.text(0) ?? "", project: r.text(1) ?? "", model: r.text(2) ?? "", input: r.int(3),
                                   output: r.int(4), cacheRead: r.int(5), cacheWrite: r.int(6), cacheWrite1h: r.int(7),
                                   requests: r.int(8), toolCalls: r.int(9), sessionSec: r.real(10), userSec: r.real(11)))
            }
            guard let (start, end) = Time.dayBounds(day) else { continue }
            var usage: [UsageRow] = [], usageCwd: [UsageRow] = [], tools: [ToolRow] = [], user: [Span] = []
            try db.query("""
                SELECT session_id, agent, hour, model, cwd, sum(input), sum(output), sum(cache_read), sum(cache_write),
                       sum(cache_write_1h), sum(requests), sum(tool_calls)
                FROM usage_hour WHERE hour >= ? AND hour < ? GROUP BY 1, 2, 3, 4, 5 ORDER BY 1, 2, 3, 4, 5
                """, [.real(start), .real(end)]) { r in
                var u = UsageRow(sessionId: r.text(0) ?? "", agent: r.text(1) ?? "", hour: r.int(2), model: r.text(3) ?? "",
                                 cwd: r.text(4) ?? "", input: r.int(5), output: r.int(6), cacheRead: r.int(7),
                                 cacheWrite: r.int(8), cacheWrite1h: r.int(9), requests: r.int(10), toolCalls: r.int(11))
                usageCwd.append(u)
                u.cwd = nil
                if let l = usage.last, (l.sessionId, l.agent, l.hour, l.model) == (u.sessionId, u.agent, u.hour, u.model) {
                    usage[usage.count - 1].input += u.input; usage[usage.count - 1].output += u.output
                    usage[usage.count - 1].cacheRead += u.cacheRead; usage[usage.count - 1].cacheWrite += u.cacheWrite
                    usage[usage.count - 1].cacheWrite1h += u.cacheWrite1h; usage[usage.count - 1].requests += u.requests
                    usage[usage.count - 1].toolCalls += u.toolCalls
                } else { usage.append(u) }
            }
            try db.query("""
                SELECT session_id, hour, name, sum(n) FROM tool_use WHERE hour >= ? AND hour < ? GROUP BY 1, 2, 3 ORDER BY 1, 2, 3
                """, [.real(start), .real(end)]) { tools.append(ToolRow(sessionId: $0.text(0) ?? "", hour: $0.int(1), name: $0.text(2) ?? "", n: $0.int(3))) }
            try db.query("SELECT start, \"end\" FROM user_activity WHERE start < ? AND \"end\" > ? ORDER BY start",
                         [.real(end), .real(start)]) { user.append(Span(start: max(start, $0.real(0)), end: min(end, $0.real(1)))) }
            try out(DayLine(day: day, host: host, seq: dseq, start: start, end: end, rows: rows, usage: usage,
                            usageCwd: usageCwd, tools: tools, user: user))
        }

        for l in try store.latestLimits() {
            try out(LimitLine(tool: l.tool.rawValue, window: l.window, usedPct: l.usedPct, resetsAt: l.resetsAt,
                              windowMinutes: l.windowMinutes, ts: l.ts))
        }
    }
}
