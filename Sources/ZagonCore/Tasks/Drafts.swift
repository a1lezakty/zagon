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
    /// The project's issue type for a task (`Task` where the project has one).
    public var type: String?
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

    /// Drafts of the last `showDays` days are shown; older ones are dropped when drafts are next stored.
    static let showDays = 14
    /// How long a create in Jira that ended unclear blocks another try of the same draft (it may still be under way).
    static let createWait: Double = 300

    /// Adds drafts for the day (inside the caller's transaction): a draft of that day with the same title (case aside;
    /// titles come with their spaces squeezed) takes the stretches instead of a second one; ids continue one counter
    /// (`suggest:new-seq`).
    func addDrafts(_ items: [(segs: [Segment], title: String, description: String, done: String, confidence: Double)], day: String,
                   now: Timestamp) throws {
        guard !items.isEmpty else { return }
        let oldest = Time.addDays(Time.dayString(now), -Self.showDays) ?? ""
        var all = try storedDrafts().filter { ($0["day"]?.string ?? "") >= oldest }, n = Int(try meta("suggest:new-seq")?.double ?? 0)
        for x in items {
            let segs = x.segs.map { JValue.object([.init("s", .string($0.session)), .init("a", .number("\($0.start)")), .init("b", .number("\($0.end)"))]) }
            if let i = all.firstIndex(where: { $0["day"]?.string == day && $0["t"]?.string?.lowercased() == x.title.lowercased() }),
               case .object(let m) = all[i] {
                all[i] = .object(m.map { $0.key == "segs" ? .init("segs", .array(($0.value.array ?? []) + segs)) : $0 })
                continue
            }
            n += 1
            all.append(.object([
                .init("id", .string("N\(n)")), .init("day", .string(day)), .init("t", .string(x.title)), .init("d", .string(x.description)),
                .init("w", .string(x.done)), .init("c", .number("\(x.confidence)")), .init("at", .number("\(now)")), .init("segs", .array(segs)),
            ]))
        }
        try setMeta(Self.draftsKey, .array(all))
        try setMeta("suggest:new-seq", .number("\(n)"))
    }

    /// Drops drafts (`day` nil: those with `ids`).
    func dropDrafts(day: String? = nil, ids: Set<String> = []) throws {
        try store.db.transaction {
            let keep = try storedDrafts().filter { v in
                guard let d = Self.draft(v) else { return false }
                return !(ids.contains(d.id) || d.day == day)
            }
            try setMeta(Self.draftsKey, .array(keep))
        }
    }

    /// Open drafts (of `day`, or all of the last `showDays` days, newest day first), their stretches as they are now:
    /// a stretch any link covers since is left out, a draft with none left is not shown.
    public func drafts(_ day: String? = nil, now: Timestamp = Time.now()) throws -> [NewTaskDraft] {
        let map = try Tasks(store: store).linkMap(), oldest = Time.addDays(Time.dayString(now), -Self.showDays) ?? ""
        var out: [NewTaskDraft] = []
        for v in try storedDrafts() {
            guard var d = Self.draft(v), day.map({ d.day == $0 }) ?? (d.day >= oldest) else { continue }
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

    /// Stretches of the day's stored drafts, per session: work a new task is suggested for already.
    func draftPeriods(_ day: String) throws -> [String: [Interval]] {
        var out: [String: [Interval]] = [:]
        for d in try storedDrafts().compactMap(Self.draft) where d.day == day {
            for s in d.stretches { out[s.sessionId, default: []].append(Interval(s.start, s.end)) }
        }
        return out
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

    /// Accept: a task with the draft's title and description (yours to change; an empty description stays empty) is
    /// made here, its stretches are linked to it by hand and the draft's text becomes the day's "what was done".
    /// `jiraKey`: the issue made for it in Jira (`createInJira`), which then is its key (a task that has that key
    /// already takes the work); that task is kept whatever happened to the suggestion meanwhile.
    public func acceptNew(_ id: String, title: String? = nil, description: String? = nil, jiraKey: String? = nil) throws -> String {
        let id = id.uppercased(), claimKey = "jira:create:" + id
        // Jira made the issue for it already (an earlier create that did not finish here): it goes under that key.
        let claim = try meta(claimKey), jiraKey = jiraKey ?? claim?["key"]?.string
        let title = title ?? claim?["titles"]?.array?.last?.string
        let (open, taken) = try openDraft(id), tasks = Tasks(store: store)
        func keepJiraTask(_ key: String, _ why: String) throws -> String {
            try store.db.transaction {
                if try tasks.find(key) == nil {
                    try tasks.add(title: Self.given(title) ?? key, key: key, description: description, status: .inProgress)
                }
                try store.db.run("DELETE FROM meta WHERE key = ?", [.text(claimKey)])
            }
            return "\(id): \(key) is a task here; \(why), so no work was linked to it"
        }
        guard let d = open else {
            if let jiraKey {
                return try keepJiraTask(jiraKey, taken.isEmpty ? "the suggestion was answered meanwhile"
                                                               : "its time is linked to \(taken.joined(separator: ", ")) now")
            }
            return taken.isEmpty ? "\(id): no such suggested task"
                : "\(id) not accepted: that time is linked to \(taken.joined(separator: ", ")) now; suggestion dropped"
        }
        let made: TaskItem? = try store.db.transaction {
            // Answered by another run meanwhile (the app, MCP, the bot): not a second task for the same work.
            guard try storedDrafts().compactMap(Self.draft).contains(where: { $0.id == d.id }) else { return nil }
            let t = try jiraKey.flatMap { try tasks.find($0) }
                ?? tasks.add(title: Self.given(title) ?? d.title, key: jiraKey, description: description ?? d.description, status: .inProgress)
            for s in d.stretches {
                try store.db.run("INSERT OR REPLACE INTO task_session(task_id, session_id, how, start, \"end\") VALUES(?, ?, 'manual', ?, ?)",
                                 [.int(Int64(t.id)), .text(s.sessionId), .real(s.start), .real(s.end)])
            }
            if !d.done.isEmpty, try tasks.done(t.id).first(where: { $0.day == d.day }) == nil {
                try tasks.setDone(t.id, day: d.day, text: d.done, source: "auto")
            }
            try dropDrafts(ids: [d.id])
            try store.db.run("DELETE FROM meta WHERE key = ?", [.text(claimKey)])
            return t
        }
        guard let t = made else {
            return try jiraKey.map { try keepJiraTask($0, "the suggestion was answered meanwhile") } ?? "\(id): already answered"
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

    /// Projects you may create issues in, read once per day (`meta` `jira:projects`).
    func projects(_ jira: JiraClient, now: Timestamp = Time.now()) throws -> [JiraProject] {
        let today = Time.dayString(now)
        if let v = try meta("jira:projects"), v["at"]?.string == today {
            return (v["list"]?.array ?? []).compactMap { x in x["k"]?.string.map { JiraProject(key: $0, name: x["n"]?.string ?? "") } }
        }
        let p = try jira.projects()
        try setMeta("jira:projects", .object([.init("at", .string(today)), .init("list", .array(p.map {
            .object([.init("k", .string($0.key)), .init("n", .string($0.name))])
        }))]))
        return p
    }

    /// Projects you may create Jira issues in, and the one to suggest.
    public func jiraProjects() throws -> (default: String?, projects: [JiraProject]) {
        guard let jira else { throw TaskError("Jira is not connected ([jira] in config.toml)") }
        let p = try projects(jira), d = try defaultProject()
        return (p.contains { $0.key == d } ? d : nil, p)
    }

    /// The issue type a new task gets in Jira project `project`, by its name there (`Task`, maybe translated).
    public func jiraTaskType(_ project: String) throws -> String {
        guard let jira else { throw TaskError("Jira is not connected ([jira] in config.toml)") }
        return try jira.taskType(project.uppercased()).name
    }

    /// What `createInJira` would do; Jira is only read (its projects, the issue type).
    public func jiraPlan(_ id: String, project: String? = nil, title: String? = nil, description: String? = nil) throws -> JiraCreatePlan {
        guard let jira else { throw TaskError("Jira is not connected ([jira] in config.toml)") }
        let (open, taken) = try openDraft(id)
        guard let d = open else {
            throw TaskError(taken.isEmpty ? "\(id): no such suggested task" : "\(id): that time is linked to \(taken.joined(separator: ", ")) now")
        }
        let projects = try projects(jira)
        let fallback = try defaultProject(), want = Self.given(project)?.uppercased() ?? fallback
        let proj = projects.contains { $0.key == want } ? want : nil
        return JiraCreatePlan(draft: d, project: proj, type: try proj.map { try jira.taskType($0).name }, projects: projects,
                              title: Self.given(title) ?? d.title, description: description ?? d.description)
    }

    /// An earlier create of the draft in Jira is not settled yet: `createInJira` then takes the issue it made (no
    /// second one is made without a new plan), even when the draft itself is gone.
    public func jiraClaim(_ id: String) throws -> Bool { try meta("jira:create:" + id.uppercased()) != nil }

    /// The key Jira gave an earlier create of the draft that is not accepted here yet.
    public func jiraClaimKey(_ id: String) throws -> String? { try meta("jira:create:" + id.uppercased())?["key"]?.string }

    /// Creates the draft's task in Jira (a Task in `project`, assigned to you) and accepts it under the new key. Only
    /// on the user's explicit confirmation (CLI `--yes` or y, MCP `confirm: true` with the preview's token, the app's
    /// Create button). Every try is remembered in `jira:create:N…` (when, titles, projects; the key once Jira gave
    /// it) until the draft is accepted: an issue made by an earlier try is taken (by its key, else by a search of your
    /// issues of those projects made since the first try (at least 15 days back) with one of those titles) instead of making a second one, and
    /// while a try that ended unclear is younger than `createWait` (it may still be under way) no other one starts.
    /// `takeOnly`: only take an issue an earlier try made, never make one (when the plan could not be shown).
    public func createInJira(_ id: String, project: String, title: String? = nil, description: String? = nil,
                             takeOnly: Bool = false, now: Timestamp = Time.now()) throws -> String {
        guard let jira else { throw TaskError("Jira is not connected ([jira] in config.toml)") }
        let started = Time.now(), id = id.uppercased(), claimKey = "jira:create:" + id, claim = try meta(claimKey)
        // `title`: the single title a claim of an earlier version kept.
        let titles = ((claim?["titles"]?.array ?? []) + [claim?["title"]].compactMap { $0 }).compactMap(\.string)
        let tried = (claim?["projects"]?.array ?? []).compactMap(\.string)
        func accept(_ key: String) throws -> String {
            try setMeta("jira:last-project", .string(String(key.prefix { $0 != "-" })))
            return try acceptNew(id, title: Self.given(title) ?? titles.last, description: description, jiraKey: key) + " · created in Jira"
        }
        if let key = claim?["key"]?.string { return try accept(key) }
        if let claim {
            let want = Set(titles + [Self.given(title)].compactMap { $0 })
            // Back to the first try (the claim lives as long as the draft, and longer when the draft is gone).
            let days = max(Self.showDays + 1, Int((now - (claim["first"]?.double ?? claim["at"]?.double ?? now)) / 86400) + 2)
            for p in Array(Set(tried + [project.uppercased()].filter { !$0.isEmpty })).sorted() {
                let found = try jira.search("creator = currentUser() AND project = \"\(p)\" AND created >= -\(days)d ORDER BY created DESC", limit: 100)
                if let k = found.first(where: { want.contains($0.summary) })?.key { return try accept(k) }
            }
            let at = claim["at"]?.double ?? 0
            if now - at < Self.createWait {
                throw TaskError("a create of \(id) in Jira started at \(Txt.clock(at)) and has not ended clearly: check Jira; if the "
                                + "issue is not there, try again after \(Txt.clock(at + Self.createWait))")
            }
        }
        guard !takeOnly else { throw TaskError("\(id): no issue an earlier try made was found in Jira; nothing was created") }
        let p = try jiraPlan(id, project: project, title: title, description: description)
        guard let proj = p.project else { throw TaskError("no Jira project \(project) you may create issues in") }
        // Reads first: their failures did not reach the create.
        let type = try jira.taskType(proj)
        _ = try jira.accountId()
        try store.db.transaction {
            guard try meta(claimKey) == claim else { throw TaskError("a create of \(id) in Jira is under way elsewhere: check Jira") }
            // Accepted by another run meanwhile (its claim is gone with it).
            guard try storedDrafts().compactMap(Self.draft).contains(where: { $0.id == id }) else { throw TaskError("\(id): already answered") }
            // The time of the POST, not of the call: the reads before it may have taken a while.
            let at = now + (Time.now() - started)
            try setMeta(claimKey, .object([.init("at", .number("\(at)")), .init("first", .number("\(claim?["first"]?.double ?? at)")),
                                           .init("titles", .array((titles + [p.title]).map(JValue.string))),
                                           .init("projects", .array((tried + [proj]).map(JValue.string)))]))
        }
        let key: String
        do { key = try jira.createIssue(project: proj, summary: p.title, description: p.description, type: type.id) }
        catch let e as JiraError where !e.mayHaveArrived {
            // Not made: the claim is as before this try.
            if let claim { try setMeta(claimKey, claim) } else { try store.db.run("DELETE FROM meta WHERE key = ?", [.text(claimKey)]) }
            if case .http(400, let body) = e {
                throw TaskError("Jira refused the issue (HTTP 400: \(body)). The project may need fields Zagon does not fill: make it "
                                + "in Jira by hand, then `zagon task add --key <KEY> <title>` and link the work")
            }
            throw e
        } catch {
            throw TaskError("Jira may have made the issue but did not say so (\(error)); nothing changed here. Check Jira: trying "
                            + "again takes that issue if it is there")
        }
        if case .object(let m)? = try meta(claimKey) { try setMeta(claimKey, .object(m + [.init("key", .string(key))])) }
        return try accept(key)
    }
}
