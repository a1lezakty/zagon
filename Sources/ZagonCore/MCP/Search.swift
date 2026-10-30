/// Session search over the contentless FTS index of typed messages (`fts` + `fts_doc`) and over session titles.
/// ponytail: lives with MCP until the CLI `search` needs it; move next to `Reports` then.
public struct SearchHit: Sendable, Equatable {
    public var sessionId: String
    /// Typed messages that match.
    public var messages: Int
    public var inTitle: Bool
    /// Time of the latest matching message.
    public var lastMatch: Timestamp?
}

extension Reports {
    /// Every word must match (prefix match in messages, substring in titles, case-insensitive); newest first.
    public func search(_ text: String, from: Timestamp? = nil, to: Timestamp? = nil) throws -> [SearchHit] {
        let words = text.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }
        guard !words.isEmpty else { throw MCPToolError("text needs at least one word") }
        let s = from ?? -Double.greatestFiniteMagnitude, e = to ?? Double.greatestFiniteMagnitude
        var hits: [String: SearchHit] = [:]
        // Each word quoted (no FTS syntax from the user), `*` for a prefix match; space = AND.
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        try db.query("""
            SELECT session_id, count(*), max(ts) FROM fts_doc
            WHERE rowid IN (SELECT rowid FROM fts WHERE fts MATCH ?) AND coalesce(ts, 0) >= ? AND coalesce(ts, 0) < ?
            GROUP BY session_id
            """, [.text(match), .real(s), .real(e)]) { r in
            let id = r.text(0) ?? ""
            hits[id] = SearchHit(sessionId: id, messages: r.int(1), inTitle: false, lastMatch: r.optReal(2))
        }
        // ponytail: titles filtered in Swift (SQLite lower() is ASCII only); fine for thousands of sessions.
        try db.query("SELECT id, title, started_at, last_at FROM session WHERE title IS NOT NULL") { r in
            guard let id = r.text(0), let title = r.text(1)?.lowercased(), words.allSatisfy({ title.contains($0) }) else { return }
            let first = r.optReal(2) ?? r.optReal(3) ?? 0, last = r.optReal(3) ?? first
            guard last >= s, first < e else { return }
            hits[id, default: SearchHit(sessionId: id, messages: 0, inTitle: true, lastMatch: nil)].inTitle = true
        }
        var lastAt: [String: Timestamp] = [:]
        for id in hits.keys {
            lastAt[id] = try db.one("SELECT last_at FROM session WHERE id=?", [.text(id)]) { $0.optReal(0) } ?? nil
        }
        return hits.values.sorted {
            ($0.lastMatch ?? lastAt[$0.sessionId] ?? 0, $0.sessionId) > ($1.lastMatch ?? lastAt[$1.sessionId] ?? 0, $1.sessionId)
        }
    }
}
