public struct SessionHit: Sendable, Equatable {
    public var id: String
    public var tool: String
    public var title: String?
    public var project: String?
    public var cwd: String?
    public var host: String?
    public var model: String?
    public var startedAt: Timestamp?
    public var lastAt: Timestamp?
    /// The id without the `<tool>:` prefix.
    public var nativeId: String { id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id }
}

/// One session's own numbers for a task card (its working time over its life, its tokens).
public struct SessionWork: Sendable, Equatable {
    public var id: String
    public var tool: String
    public var title: String?
    public var project: String?
    public var host: String?
    public var model: String?
    public var startedAt: Timestamp?
    public var lastAt: Timestamp?
    public var workingSec: Double
    public var tokens: Int
}

/// Your work stretches of a day (`user_activity`) and the sessions' working time.
public struct WorkDay: Sendable, Equatable {
    public var day: String
    public var work: [Interval]
    public var sessionSec: Double
}

extension Query {
    /// Sessions whose typed messages (full-text index) or title / project contain every word, newest first.
    public func search(_ text: String, limit: Int = 20) throws -> [SessionHit] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return [] }
        var ids: [String] = []
        // Words of separators only are empty FTS phrases (a syntax error): they match titles only.
        let indexed = words.filter { $0.contains { $0.isLetter || $0.isNumber } }
        if !indexed.isEmpty {
            let match = indexed.map { "\"" + $0.replacing("\"", with: "\"\"") + "\"*" }.joined(separator: " ")
            try db.query("""
                SELECT d.session_id, max(d.ts) FROM fts JOIN fts_doc d ON d.rowid = fts.rowid WHERE fts MATCH ?
                GROUP BY d.session_id ORDER BY 2 DESC LIMIT ?
                """, [.text(match), .int(Int64(limit))]) { if let id = $0.text(0) { ids.append(id) } }
        }
        let like = words.map { _ in "(coalesce(title, '') || ' ' || coalesce(project, '')) LIKE ? ESCAPE '\\'" }
            .joined(separator: " AND ")
        let args = words.map { SQLValue.text("%" + $0.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_") + "%") }
        try db.query("SELECT id FROM session WHERE \(like) ORDER BY last_at DESC LIMIT ?", args + [.int(Int64(limit))]) {
            if let id = $0.text(0), !ids.contains(id) { ids.append(id) }
        }
        return try ids.prefix(limit).compactMap { id in
            try db.one("""
                SELECT tool, title, \(Projects.sessionSQL("session")), cwd, host, model, started_at, last_at FROM session WHERE id = ?
                """, [.text(id)]) {
                SessionHit(id: id, tool: $0.text(0) ?? "", title: $0.text(1), project: $0.text(2), cwd: $0.text(3),
                           host: $0.text(4), model: $0.text(5), startedAt: $0.optReal(6), lastAt: $0.optReal(7))
            }
        }
    }

    public func sessionWork(_ id: String) throws -> SessionWork? {
        var working: [Interval] = []
        try db.query("SELECT start, \"end\" FROM activity WHERE session_id = ? AND kind = 'working'", [.text(id)]) {
            working.append(Interval($0.real(0), $0.real(1)))
        }
        let tokens = try db.one("""
            SELECT coalesce(sum(input + output + cache_read + cache_write), 0) FROM usage_hour WHERE session_id = ?
            """, [.text(id)]) { $0.int(0) } ?? 0
        return try db.one("""
            SELECT tool, title, \(Projects.sessionSQL("session")), host, model, started_at, last_at FROM session WHERE id = ?
            """, [.text(id)]) {
            SessionWork(id: id, tool: $0.text(0) ?? "", title: $0.text(1), project: $0.text(2), host: $0.text(3), model: $0.text(4),
                        startedAt: $0.optReal(5), lastAt: $0.optReal(6),
                        workingSec: Intervals.merge(working).reduce(0) { $0 + $1.length }, tokens: tokens)
        }
    }

    public func workDay(_ day: String, bounds: DayBounds = Time.dayBounds) throws -> WorkDay {
        var w = WorkDay(day: day, work: [], sessionSec: 0)
        guard let (s, e) = bounds(day) else { return w }
        try db.query("SELECT start, \"end\" FROM user_activity WHERE start < ? AND \"end\" > ? ORDER BY start", [.real(e), .real(s)]) {
            w.work.append(Interval(max(s, $0.real(0)), min(e, $0.real(1))))
        }
        w.sessionSec = try spans([(s, e)])[0].sessionSec
        return w
    }
}
