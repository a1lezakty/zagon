/// Own task registry over the `task*` tables (works without Jira).
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    /// `review`: in review, testing or ready to release.
    case planned, inProgress = "in_progress", review, done
    /// Older rows may carry the schema default `open`.
    init(stored: String?) { self = TaskStatus(rawValue: stored ?? "") ?? .planned }
    public init(jiraCategory c: String) { self = c == "done" ? .done : c == "indeterminate" ? .inProgress : .planned }
    /// A Jira status as a status here: a name with a part from `review` (any case) is `review` unless Jira counts it
    /// done; the rest by the status category (`new` | `indeterminate` | `done`).
    public init(jira i: JiraIssue, review: [String] = JiraConfig.defaultReview) {
        let name = i.status.lowercased()
        if i.statusCategory != "done", review.contains(where: { !$0.isEmpty && name.contains($0.lowercased()) }) { self = .review }
        else { self.init(jiraCategory: i.statusCategory) }
    }
}

public struct TaskItem: Codable, Sendable, Equatable {
    public var id: Int
    /// Own `ZAG-N` or an external key such as `PROJ-123`.
    public var key: String
    public var title: String
    public var description: String?
    public var status: TaskStatus
    public var jiraKey: String?
    public var created: Timestamp
    public var updated: Timestamp

    public init(id: Int, key: String, title: String, description: String? = nil, status: TaskStatus, jiraKey: String? = nil, created: Timestamp,
                updated: Timestamp) {
        self.id = id; self.key = key; self.title = title; self.description = description; self.status = status
        self.jiraKey = jiraKey; self.created = created; self.updated = updated
    }

    // JSON: `status` keeps to the three values a zagon before 0.1.1 reads (`review` goes as `in_progress`), `stage`
    // carries `review`; an unknown status reads as `planned`.
    enum CodingKeys: String, CodingKey { case id, key, title, description, status, stage, jiraKey, created, updated }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id); key = try c.decode(String.self, forKey: .key)
        title = try c.decode(String.self, forKey: .title); description = try c.decodeIfPresent(String.self, forKey: .description)
        status = TaskStatus(stored: try c.decodeIfPresent(String.self, forKey: .stage) ?? c.decodeIfPresent(String.self, forKey: .status))
        jiraKey = try c.decodeIfPresent(String.self, forKey: .jiraKey)
        created = try c.decode(Timestamp.self, forKey: .created); updated = try c.decode(Timestamp.self, forKey: .updated)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(key, forKey: .key); try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(status == .review ? TaskStatus.inProgress : status, forKey: .status)
        if status == .review { try c.encode(status, forKey: .stage) }
        try c.encodeIfPresent(jiraKey, forKey: .jiraKey); try c.encode(created, forKey: .created); try c.encode(updated, forKey: .updated)
    }
}

public struct TaskTodo: Codable, Sendable { public var id: Int; public var text: String; public var done: Bool; public var created: Timestamp }
public struct TaskNote: Codable, Sendable { public var id: Int; public var text: String; public var created: Timestamp }
/// "What was done" on a day; `source` = `auto` (from summaries) | `manual`.
public struct TaskDone: Codable, Sendable { public var day: String; public var text: String; public var source: String }
public struct TaskLink: Codable, Sendable {
    public var sessionId: String
    public var how: String
    public var title: String?
    public var lastAt: Timestamp?
    /// Linked periods of the session; 0 = the whole session.
    public var periods: Int = 0
}

/// How a session got linked. `unlinked` is a manual "not this task" for the whole session that keeps automatic
/// linking from adding it back; `worktree` = the branch checked out in the folder an interval was worked in.
public enum LinkHow: String, Sendable, CaseIterable {
    /// `suggested`: proposed by meaning (`TaskSuggester`), counts nowhere until accepted (then `manual`); `brief`: the
    /// key of a brief a typed message points to, reaching as a typed key. New cases go last (`nudge` is by position).
    case manual, commit, message, branch, worktree, title, unlinked, suggested, brief
    /// Where several links cover one moment the strongest win: by hand, then a commit or a typed key of that time,
    /// then a branch or the session title.
    public var rank: Int {
        switch self { case .manual: 4; case .commit, .message, .brief: 3; case .branch, .worktree, .title: 2; case .unlinked, .suggested: 0 }
    }
    /// The key of `task_session` has no `how`: a period link is stored a fraction of a millisecond early, each kind by
    /// its own amount (times are on a millisecond grid), so one kind never merges into or replaces another;
    /// `linkMap` gives the exact start back. ponytail: `how` in the key (a schema change) would make this unneeded.
    static let maxNudge = 0.001
    var nudge: Double { Double(LinkHow.allCases.firstIndex(of: self)!) * 0.0001 }
}

/// Link periods of all sessions, to ask which tasks a session worked on at a moment.
public struct LinkMap: Sendable {
    struct Period: Sendable { var task: Int, rank: Int, start: Timestamp, end: Timestamp }
    var bySession: [String: [Period]] = [:]

    /// The strongest links of the session covering `t`, split equally; empty = no task.
    public func tasks(_ session: String, at t: Timestamp) -> [(task: Int, weight: Double)] {
        let covering = (bySession[session] ?? []).filter { $0.start <= t && t < $0.end }
        guard let top = covering.map(\.rank).max() else { return [] }
        let ids = Set(covering.filter { $0.rank == top }.map(\.task)).sorted()
        return ids.map { ($0, 1.0 / Double(ids.count)) }
    }

    /// Where the session's links start or end (sorted), to cut its time there.
    public func edges(_ session: String) -> [Timestamp] {
        Array(Set((bySession[session] ?? []).flatMap { [$0.start, $0.end] })).sorted()
    }
}

public struct TaskError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public struct Tasks {
    public let store: Store
    var db: SQLite { store.db }
    public static let ownPrefix = "ZAG"

    public init(store: Store) { self.store = store }

    /// Creates a task. Without `key` it gets the next own `ZAG-N`; an explicit external key is also its Jira key
    /// unless `jiraKey` says otherwise.
    @discardableResult
    public func add(title: String, key: String? = nil, jiraKey: String? = nil, description: String? = nil,
                    status: TaskStatus = .planned, at now: Timestamp = Time.now()) throws -> TaskItem {
        // Blank values (as models and scripts often send) mean "not given".
        func given(_ s: String?) -> String? { s.flatMap { $0.trimmed(" \t\n\r").isEmpty ? nil : $0.trimmed(" \t\n\r") } }
        let description = given(description)
        return try db.transaction {
            let k = try given(key)?.uppercased() ?? nextOwnKey()
            if try find(k) != nil { throw TaskError("task \(k) already exists") }
            let jira = given(jiraKey)?.uppercased() ?? (k.hasPrefix(Tasks.ownPrefix + "-") ? nil : k)
            if let jira, let other = try owner(of: jira) { throw TaskError("Jira issue \(jira) already belongs to task \(other.key)") }
            try db.run("""
                INSERT INTO task(key, title, description, status, jira_key, created, updated) VALUES(?, ?, ?, ?, ?, ?, ?)
                """, [.text(k), .text(title), .of(description), .text(status.rawValue), .of(jira), .real(now), .real(now)])
            return TaskItem(id: Int(db.lastInsertRowID), key: k, title: title, description: description, status: status,
                            jiraKey: jira, created: now, updated: now)
        }
    }

    func nextOwnKey() throws -> String {
        var n = 0
        try db.query("SELECT key FROM task WHERE key LIKE ?", [.text(Tasks.ownPrefix + "-%")]) {
            n = max(n, Int(($0.text(0) ?? "").dropFirst(Tasks.ownPrefix.count + 1)) ?? 0)
        }
        return "\(Tasks.ownPrefix)-\(n + 1)"
    }

    static let columns = "id, key, title, description, status, jira_key, created, updated"
    static func item(_ r: Row) -> TaskItem {
        TaskItem(id: r.int(0), key: r.text(1) ?? "", title: r.text(2) ?? "", description: r.text(3),
                 status: TaskStatus(stored: r.text(4)), jiraKey: r.text(5), created: r.real(6), updated: r.real(7))
    }

    /// By id (`12`), key or Jira key (case-insensitive).
    public func find(_ ref: String) throws -> TaskItem? {
        if let id = Int(ref) { return try get(id) }
        return try db.one("SELECT \(Tasks.columns) FROM task WHERE upper(key) = ?1 OR upper(jira_key) = ?1 ORDER BY upper(key) = ?1 DESC",
                          [.text(ref.uppercased())], Tasks.item)
    }

    /// A task (other than `except`) whose key or Jira key is `key`.
    public func owner(of key: String, except: Int? = nil) throws -> TaskItem? {
        try db.one("SELECT \(Tasks.columns) FROM task WHERE (upper(key) = ?1 OR upper(jira_key) = ?1) AND id <> ?2 LIMIT 1",
                   [.text(key.uppercased()), .int(Int64(except ?? -1))], Tasks.item)
    }

    public func get(_ id: Int) throws -> TaskItem? {
        try db.one("SELECT \(Tasks.columns) FROM task WHERE id = ?", [.int(Int64(id))], Tasks.item)
    }

    public func list(status: TaskStatus? = nil) throws -> [TaskItem] {
        var out: [TaskItem] = []
        try db.query("SELECT \(Tasks.columns) FROM task ORDER BY updated DESC") { out.append(Tasks.item($0)) }
        return status.map { s in out.filter { $0.status == s } } ?? out
    }

    public func update(_ t: TaskItem, at now: Timestamp = Time.now()) throws {
        try db.run("UPDATE task SET key=?, title=?, description=?, status=?, jira_key=?, updated=? WHERE id=?",
                   [.text(t.key), .text(t.title), .of(t.description), .text(t.status.rawValue), .of(t.jiraKey), .real(now),
                    .int(Int64(t.id))])
    }

    public func setStatus(_ task: Int, _ s: TaskStatus, at now: Timestamp = Time.now()) throws {
        try db.run("UPDATE task SET status=?, updated=? WHERE id=?", [.text(s.rawValue), .real(now), .int(Int64(task))])
    }

    func touch(_ task: Int, _ now: Timestamp) throws {
        try db.run("UPDATE task SET updated=? WHERE id=?", [.real(now), .int(Int64(task))])
    }

    // MARK: TODO, notes, what was done

    @discardableResult
    public func addTodo(_ task: Int, _ text: String, at now: Timestamp = Time.now()) throws -> Int {
        try db.run("INSERT INTO task_todo(task_id, text, created) VALUES(?, ?, ?)", [.int(Int64(task)), .text(text), .real(now)])
        let id = Int(db.lastInsertRowID)
        try touch(task, now)
        return id
    }

    /// Marks the `n`-th TODO (1-based, in creation order) done or not.
    public func checkTodo(_ task: Int, number n: Int, done: Bool = true) throws {
        let todos = try self.todos(task)
        guard n >= 1 && n <= todos.count else { throw TaskError("no TODO #\(n)") }
        try db.run("UPDATE task_todo SET done=? WHERE id=?", [.int(done ? 1 : 0), .int(Int64(todos[n - 1].id))])
        try touch(task, Time.now())
    }

    public func todos(_ task: Int) throws -> [TaskTodo] {
        var out: [TaskTodo] = []
        try db.query("SELECT id, text, done, created FROM task_todo WHERE task_id=? ORDER BY id", [.int(Int64(task))]) {
            out.append(TaskTodo(id: $0.int(0), text: $0.text(1) ?? "", done: $0.int(2) != 0, created: $0.real(3)))
        }
        return out
    }

    @discardableResult
    public func addNote(_ task: Int, _ text: String, at now: Timestamp = Time.now()) throws -> Int {
        try db.run("INSERT INTO task_note(task_id, text, created) VALUES(?, ?, ?)", [.int(Int64(task)), .text(text), .real(now)])
        let id = Int(db.lastInsertRowID)
        try touch(task, now)
        return id
    }

    public func notes(_ task: Int) throws -> [TaskNote] {
        var out: [TaskNote] = []
        try db.query("SELECT id, text, created FROM task_note WHERE task_id=? ORDER BY id", [.int(Int64(task))]) {
            out.append(TaskNote(id: $0.int(0), text: $0.text(1) ?? "", created: $0.real(2)))
        }
        return out
    }

    /// Sets "what was done" for a day; one text per (day, source).
    public func setDone(_ task: Int, day: String, text: String, source: String = "manual") throws {
        try db.run("INSERT OR REPLACE INTO task_done(task_id, day, text, source) VALUES(?, ?, ?, ?)",
                   [.int(Int64(task)), .text(day), .text(text), .text(source)])
        try touch(task, Time.now())
    }

    /// Newest day first; on one day the manual text comes before the auto one.
    public func done(_ task: Int) throws -> [TaskDone] {
        var out: [TaskDone] = []
        try db.query("SELECT day, text, source FROM task_done WHERE task_id=? ORDER BY day DESC, source = 'manual' DESC",
                     [.int(Int64(task))]) { out.append(TaskDone(day: $0.text(0) ?? "", text: $0.text(1) ?? "", source: $0.text(2) ?? "")) }
        return out
    }

    // MARK: sessions

    /// The whole session, as a link period.
    public static let wholeSession = (start: 0.0, end: 1e18)

    /// A manual link (or `unlinked`) covers the whole session; `unlinked` also drops the task's other links to the
    /// session and keeps automatic ones out. An automatic link covers [start, end) and only extends one of its kind.
    public func link(_ task: Int, session: String, how: LinkHow, start: Timestamp = Tasks.wholeSession.start,
                     end: Timestamp = Tasks.wholeSession.end) throws {
        if how == .manual || how == .unlinked {
            if how == .unlinked { try db.run("DELETE FROM task_session WHERE task_id = ? AND session_id = ?", [.int(Int64(task)), .text(session)]) }
            try db.run("INSERT OR REPLACE INTO task_session(task_id, session_id, how, start, \"end\") VALUES(?, ?, ?, ?, ?)",
                       [.int(Int64(task)), .text(session), .text(how.rawValue), .real(Tasks.wholeSession.start), .real(Tasks.wholeSession.end)])
            return
        }
        let start = start == Tasks.wholeSession.start ? start : start - how.nudge
        guard end > start else { return }
        try db.run("""
            INSERT INTO task_session(task_id, session_id, how, start, "end")
            SELECT ?1, ?2, ?3, ?4, ?5 WHERE NOT EXISTS (SELECT 1 FROM task_session WHERE task_id = ?1 AND session_id = ?2 AND how = 'unlinked')
            ON CONFLICT(task_id, session_id, start) DO UPDATE SET "end" = max(task_session."end", excluded."end")
            WHERE task_session.how = excluded.how
            """, [.int(Int64(task)), .text(session), .text(how.rawValue), .real(start), .real(end)])
    }

    /// One line per linked session: the strongest way it is linked (`unlinked` if it was unlinked by hand) and how many
    /// periods (0 = linked as a whole).
    public func links(_ task: Int) throws -> [TaskLink] {
        var out: [TaskLink] = []
        try db.query("""
            SELECT ts.session_id, ts.how, ts.start, s.title, s.last_at FROM task_session ts LEFT JOIN session s ON s.id = ts.session_id
            WHERE ts.task_id = ? AND ts.how <> 'suggested' ORDER BY s.last_at DESC, ts.session_id
            """, [.int(Int64(task))]) { r in
            let sid = r.text(0) ?? "", how = LinkHow(rawValue: r.text(1) ?? "") ?? .title, whole = r.real(2) == Tasks.wholeSession.start
            if let i = out.indices.last, out[i].sessionId == sid {
                let cur = LinkHow(rawValue: out[i].how) ?? .title
                if cur != .unlinked && (how == .unlinked || how.rank > cur.rank) { out[i].how = how.rawValue }
                if !whole { out[i].periods += 1 }
            } else {
                out.append(TaskLink(sessionId: sid, how: how.rawValue, title: r.text(3), lastAt: r.optReal(4), periods: whole ? 0 : 1))
            }
        }
        return out
    }

    /// All link periods; a task unlinked from a session by hand gets no time there.
    public func linkMap() throws -> LinkMap {
        var m = LinkMap(), unlinked = Set<String>()
        try db.query("SELECT session_id, task_id, how, start, \"end\" FROM task_session") { r in
            guard let sid = r.text(0), let how = LinkHow(rawValue: r.text(2) ?? "") else { return }
            if how == .unlinked { unlinked.insert("\(r.int(1)) \(sid)"); return }
            if how == .suggested { return }
            let start = r.real(3) == Tasks.wholeSession.start ? r.real(3) : r.real(3) + how.nudge
            m.bySession[sid, default: []].append(.init(task: r.int(1), rank: how.rank, start: start, end: r.real(4)))
        }
        for (sid, ps) in m.bySession { m.bySession[sid] = ps.filter { !unlinked.contains("\($0.task) \(sid)") } }
        return m
    }
}
