/// Rebuilds `day_agg` rows of one local day and host from usage_hour, tool_use, activity and user_activity of the
/// sessions of that host (rows imported from other machines carry their own host in `session.host`).
struct DayAggregator {
    let db: SQLite
    let host: String

    struct Key: Hashable { var tool: String; var project: String; var model: String }
    struct Row { var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, requests = 0, toolCalls = 0
                 var sessionSec = 0.0, userSec = 0.0 }

    func rebuild(day: String, seq: Int) throws {
        guard let (s, e) = Time.dayBounds(day) else { return }
        var rows: [Key: Row] = [:]
        try db.query("""
            SELECT coalesce(s.tool,''), coalesce(s.project,''), u.model, sum(u.input), sum(u.output), sum(u.cache_read),
                   sum(u.cache_write), sum(u.requests)
            FROM usage_hour u LEFT JOIN session s ON s.id = u.session_id
            WHERE u.hour >= ?1 AND u.hour < ?2 AND coalesce(s.host, ?3) = ?3 GROUP BY 1, 2, 3
            """, [.real(s), .real(e), .text(host)]) { r in
            rows[Key(tool: r.text(0) ?? "", project: r.text(1) ?? "", model: r.text(2) ?? "?"), default: Row()] = Row(
                input: r.int(3), output: r.int(4), cacheRead: r.int(5), cacheWrite: r.int(6), requests: r.int(7))
        }
        var total = Row()
        try db.query("""
            SELECT coalesce(s.tool,''), coalesce(s.project,''), sum(t.n) FROM tool_use t LEFT JOIN session s ON s.id = t.session_id
            WHERE t.hour >= ?1 AND t.hour < ?2 AND coalesce(s.host, ?3) = ?3 GROUP BY 1, 2
            """, [.real(s), .real(e), .text(host)]) { r in
            rows[Key(tool: r.text(0) ?? "", project: r.text(1) ?? "", model: ""), default: Row()].toolCalls += r.int(2)
            total.toolCalls += r.int(2)
        }
        // Session time: union per session (parallel sub-agents are not double counted), summed per project.
        for (sid, ivs) in try SessionTime.working(db, from: s, to: e, host: host) {
            let sec = Intervals.covered(ivs.intervals, from: s, to: e)
            guard sec > 0 else { continue }
            _ = sid
            rows[Key(tool: ivs.tool, project: ivs.project, model: ""), default: Row()].sessionSec += sec
            total.sessionSec += sec
        }
        var user: [Interval] = []
        try db.query("SELECT start, \"end\" FROM user_activity WHERE start < ? AND \"end\" > ?", [.real(e), .real(s)]) {
            user.append(Interval($0.real(0), $0.real(1)))
        }
        total.userSec = Intervals.covered(user, from: s, to: e)
        for v in rows.values {
            total.input += v.input; total.output += v.output; total.cacheRead += v.cacheRead
            total.cacheWrite += v.cacheWrite; total.requests += v.requests
        }
        let had = try db.run("DELETE FROM day_agg WHERE day=? AND host=?", [.text(day), .text(host)]) > 0
        let empty = total.requests == 0 && total.sessionSec == 0 && total.userSec == 0 && total.toolCalls == 0
        // A day that had rows keeps a (zero) totals row, so `export` tells clients the day is now empty.
        if !empty || had { rows[Key(tool: "", project: "", model: "")] = total }
        for (k, v) in rows {
            try db.run("""
                INSERT INTO day_agg(day, host, tool, project, model, input, output, cache_read, cache_write, requests,
                  tool_calls, session_sec, user_sec, seq) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(day), .text(host), .text(k.tool), .text(k.project), .text(k.model), .int(Int64(v.input)),
                      .int(Int64(v.output)), .int(Int64(v.cacheRead)), .int(Int64(v.cacheWrite)), .int(Int64(v.requests)),
                      .int(Int64(v.toolCalls)), .real(v.sessionSec), .real(v.userSec), .int(Int64(seq))])
        }
    }
}

enum SessionTime {
    struct Entry { var tool: String; var project: String; var intervals: [Interval] }

    /// Working intervals overlapping [from, to), grouped by session; with `host`, only sessions of that host.
    static func working(_ db: SQLite, from: Timestamp, to: Timestamp, host: String? = nil) throws -> [String: Entry] {
        var out: [String: Entry] = [:]
        try db.query("""
            SELECT a.session_id, coalesce(s.tool,''), coalesce(s.project,''), a.start, a."end"
            FROM activity a LEFT JOIN session s ON s.id = a.session_id
            WHERE a.kind = 'working' AND a.start < ?1 AND a."end" > ?2 AND (?3 IS NULL OR coalesce(s.host, ?3) = ?3)
            """, [.real(to), .real(from), .of(host)]) { r in
            let sid = r.text(0) ?? ""
            out[sid, default: Entry(tool: r.text(1) ?? "", project: r.text(2) ?? "", intervals: [])]
                .intervals.append(Interval(r.real(3), r.real(4)))
        }
        return out
    }
}
