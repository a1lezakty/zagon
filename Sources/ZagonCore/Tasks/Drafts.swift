/// A new task the AI suggested for work no task fits (`TaskSuggester`). It counts nowhere until accepted; accepted, it
/// becomes a task here (own key) or, on an explicit command, a new Jira issue, and its stretches are linked to it by hand.
public struct NewTaskDraft: Codable, Sendable, Equatable {
    /// `N<number>`: what `task accept|reject` take.
    public var id: String
    public var day: String
    public var title: String
    /// What it was and what was done: the task's description.
    public var description: String
    /// The day's worklog text ("what was done").
    public var done: String
    public var confidence: Double
    /// The stretches of work it is for that no link covers now.
    public var stretches: [DraftStretch]
    /// Working time of those stretches.
    public var workedSec: Double = 0
}

public struct DraftStretch: Codable, Sendable, Equatable {
    public var sessionId: String
    public var start: Timestamp, end: Timestamp
    public var sessionTitle: String?, project: String?
}

/// What creating in Jira will do: shown before the user confirms.
public struct JiraCreatePlan: Codable, Sendable {
    public var draft: NewTaskDraft
    /// The project it goes to (`--project`, else the last one used, else the one most of your issues are in).
    public var project: String?
    public var projects: [JiraProject]
    public var title: String, description: String
}

extension TaskSuggester {
    static let draftsKey = "suggest:new"

    func storedDrafts() throws -> [JValue] { try meta(Self.draftsKey)?.array ?? [] }

    static func draft(_ v: JValue) -> NewTaskDraft? {
        guard let id = v["id"]?.string, let day = v["day"]?.string, let t = v["t"]?.string else { return nil }
        let st = (v["segs"]?.array ?? []).compactMap { x -> DraftStretch? in
            guard let s = x["s"]?.string, let a = x["a"]?.double, let b = x["b"]?.double else { return nil }
            return DraftStretch(sessionId: s, start: a, end: b)
        }
        return NewTaskDraft(id: id, day: day, title: t, description: v["d"]?.string ?? "", done: v["w"]?.string ?? "",
                            confidence: v["c"]?.double ?? 0, stretches: st)
    }

    /// Adds drafts for the day (inside the caller's transaction); ids continue one counter (`suggest:new-seq`).
    func addDrafts(_ items: [(segs: [Segment], title: String, description: String, done: String, confidence: Double)], day: String,
                   now: Timestamp) throws {
        guard !items.isEmpty else { return }
        var all = try storedDrafts(), n = Int(try meta("suggest:new-seq")?.double ?? 0)
        for x in items {
            n += 1
            all.append(.object([
                .init("id", .string("N\(n)")), .init("day", .string(day)), .init("t", .string(x.title)), .init("d", .string(x.description)),
                .init("w", .string(x.done)), .init("c", .number("\(x.confidence)")), .init("at", .number("\(now)")),
                .init("segs", .array(x.segs.map { .object([.init("s", .string($0.session)), .init("a", .number("\($0.start)")),
                                                           .init("b", .number("\($0.end)"))]) })),
            ]))
        }
        try setMeta(Self.draftsKey, .array(all))
        try setMeta("suggest:new-seq", .number("\(n)"))
    }

    /// Drops drafts (`day` nil: those with `ids`).
    func dropDrafts(day: String? = nil, ids: Set<String> = []) throws {
        let keep = try storedDrafts().filter { v in
            guard let d = Self.draft(v) else { return false }
            return !(ids.contains(d.id) || d.day == day)
        }
        try setMeta(Self.draftsKey, .array(keep))
    }

    /// Open drafts (of `day`, or all, newest day first), their stretches as they are now: a stretch any link covers
    /// since is left out, a draft with none left is not shown.
    public func drafts(_ day: String? = nil) throws -> [NewTaskDraft] {
        let map = try Tasks(store: store).linkMap()
        var out: [NewTaskDraft] = []
        for v in try storedDrafts() {
            guard var d = Self.draft(v), day == nil || d.day == day else { continue }
            d.stretches = d.stretches.filter { Self.covered(map, $0.sessionId, $0.start, $0.end).isEmpty }
            guard !d.stretches.isEmpty else { continue }
            for i in d.stretches.indices {
                try store.db.query("SELECT title, project FROM session WHERE id = ?", [.text(d.stretches[i].sessionId)]) {
                    d.stretches[i].sessionTitle = $0.text(0); d.stretches[i].project = $0.text(1)
                }
                d.workedSec += try TaskLinker.working(store.db, d.stretches[i].sessionId)
                    .reduce(0) { $0 + max(0, min($1.end, d.stretches[i].end) - max($1.start, d.stretches[i].start)) }
            }
            out.append(d)
        }
        return out.sorted { ($0.day, $0.workedSec) > ($1.day, $1.workedSec) }
    }

    /// The draft as it is now after the day's links are refreshed; nil when it is not open (accepted, rejected, or
    /// all its time got a link since: then it is dropped and `taken` names those tasks).
    func openDraft(_ id: String) throws -> (draft: NewTaskDraft?, taken: [String]) {
        guard let raw = try storedDrafts().compactMap(Self.draft).first(where: { $0.id == id.uppercased() }) else { return (nil, []) }
        if let (from, to) = Time.dayBounds(raw.day) { try linker.linkSessions(store); try linker.linkDay(store, from: from, to: to) }
        if let d = try drafts(raw.day).first(where: { $0.id == raw.id }) { return (d, []) }
        let map = try Tasks(store: store).linkMap()
        let ids = Set(raw.stretches.flatMap { Self.covered(map, $0.sessionId, $0.start, $0.end) })
        try dropDrafts(ids: [raw.id])
        return (nil, try ids.sorted().map { try Tasks(store: store).get($0)?.key ?? "#\($0)" })
    }

    /// Accept: a task with the draft's title and description (yours to change) is made here, its stretches are
    /// linked to it by hand and the draft's text becomes the day's "what was done". `jiraKey`: the issue just made
    /// for it in Jira (`createInJira`), which then is its key.
    public func acceptNew(_ id: String, title: String? = nil, description: String? = nil, jiraKey: String? = nil) throws -> String {
        let (open, taken) = try openDraft(id), tasks = Tasks(store: store)
        guard let d = open else {
            // The issue is in Jira already: keep it as a task even when its time went to another task meanwhile.
            if let jiraKey, let title = Self.given(title) {
                try tasks.add(title: title, key: jiraKey, description: Self.given(description), status: .inProgress)
                return "\(id): \(jiraKey) is a task here, but its time is linked to \(taken.joined(separator: ", ")) now"
            }
            return taken.isEmpty ? "\(id): no such suggested task"
                : "\(id) not accepted: that time is linked to \(taken.joined(separator: ", ")) now; suggestion dropped"
        }
        let t = try store.db.transaction {
            let t = try tasks.add(title: Self.given(title) ?? d.title, key: jiraKey, description: Self.given(description) ?? d.description,
                                  status: .inProgress)
            for s in d.stretches {
                try store.db.run("INSERT OR REPLACE INTO task_session(task_id, session_id, how, start, \"end\") VALUES(?, ?, 'manual', ?, ?)",
                                 [.int(Int64(t.id)), .text(s.sessionId), .real(s.start), .real(s.end)])
            }
            if !d.done.isEmpty { try tasks.setDone(t.id, day: d.day, text: d.done, source: "auto") }
            try dropDrafts(ids: [d.id])
            return t
        }
        return "\(d.id) accepted: \(t.key) \(Txt.oneLine(t.title, 70)) · \(Txt.dur(d.workedSec))"
    }

    /// Reject: the draft is dropped; its stretches stay asked, so they are not suggested again (`--again` asks anew).
    public func rejectNew(_ id: String) throws -> String {
        guard try storedDrafts().compactMap(Self.draft).contains(where: { $0.id == id.uppercased() }) else { return "\(id): no such suggested task" }
        try dropDrafts(ids: [id.uppercased()])
        return "\(id.uppercased()) rejected"
    }

    static func given(_ s: String?) -> String? { s.flatMap { $0.trimmed(" \t\n\r").isEmpty ? nil : $0.trimmed(" \t\n\r") } }

    // MARK: Jira

    /// The project to suggest: the last one an issue was made in here, else the one most of your Jira issues are in.
    func defaultProject() throws -> String? {
        if let p = try meta("jira:last-project")?.string { return p }
        let counts = Dictionary(grouping: JiraCache.load(store).mine.compactMap { $0.split(separator: "-").first.map(String.init) }, by: { $0 })
        return counts.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
    }

    /// Projects you may create Jira issues in, and the one to suggest.
    public func jiraProjects() throws -> (default: String?, projects: [JiraProject]) {
        guard let jira else { throw TaskError("Jira is not connected ([jira] in config.toml)") }
        let p = try jira.projects(), d = try defaultProject()
        return (p.contains { $0.key == d } ? d : nil, p)
    }

    /// What `createInJira` would do; Jira is only read (its projects).
    public func jiraPlan(_ id: String, project: String? = nil, title: String? = nil, description: String? = nil) throws -> JiraCreatePlan {
        guard let jira else { throw TaskError("Jira is not connected ([jira] in config.toml)") }
        let (open, taken) = try openDraft(id)
        guard let d = open else {
            throw TaskError(taken.isEmpty ? "\(id): no such suggested task" : "\(id): that time is linked to \(taken.joined(separator: ", ")) now")
        }
        let projects = try jira.projects()
        let fallback = try defaultProject(), want = Self.given(project)?.uppercased() ?? fallback
        return JiraCreatePlan(draft: d, project: projects.contains { $0.key == want } ? want : nil, projects: projects,
                              title: Self.given(title) ?? d.title, description: Self.given(description) ?? d.description)
    }

    /// Creates the draft's task in Jira (a Task in `project`, assigned to you) and accepts it under the new key. Only
    /// on the user's explicit confirmation (CLI `--yes` or y, MCP `confirm: true`, the app's Create button). A create
    /// that failed after it may have reached Jira is remembered: the next try first looks for an issue you made with
    /// that title in the project in the last two days and takes it instead of making a second one.
    public func createInJira(_ id: String, project: String, title: String? = nil, description: String? = nil,
                             now: Timestamp = Time.now()) throws -> String {
        guard let jira else { throw TaskError("Jira is not connected ([jira] in config.toml)") }
        let p = try jiraPlan(id, project: project, title: title, description: description)
        guard let proj = p.project else { throw TaskError("no Jira project \(project) you may create issues in") }
        let claimKey = "jira:create:" + p.draft.id
        var key: String?
        if try meta(claimKey) != nil {
            key = try jira.search("creator = currentUser() AND project = \"\(proj)\" AND created >= -2d ORDER BY created DESC", limit: 100)
                .first { $0.summary == p.title }?.key
        }
        if key == nil {
            try setMeta(claimKey, .object([.init("at", .number("\(now)")), .init("title", .string(p.title))]))
            do { key = try jira.createIssue(project: proj, summary: p.title, description: p.description) }
            catch let e as JiraError where !e.mayHaveArrived {
                try store.db.run("DELETE FROM meta WHERE key = ?", [.text(claimKey)])
                throw e
            } catch {
                throw TaskError("Jira may have made the issue but did not say so (\(error)); nothing changed here. Run it again: "
                                + "it looks for that issue first")
            }
        }
        try setMeta("jira:last-project", .string(proj))
        try store.db.run("DELETE FROM meta WHERE key = ?", [.text(claimKey)])
        return try acceptNew(p.draft.id, title: p.title, description: p.description, jiraKey: key!) + " · created in Jira"
    }
}
