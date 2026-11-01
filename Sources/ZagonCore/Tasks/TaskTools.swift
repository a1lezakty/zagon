#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `TaskService` for `zagon mcp`: task_list / task_get / task_create / task_update, worklog_plan, worklog_commit.
public final class TaskTools: TaskService {
    /// Built for every call, so a fixed config or a rotated token is picked up without restarting the server.
    let makeWorklog: () throws -> DayWorklog
    let makeSuggester: (() throws -> TaskSuggester)?
    let refresh: (() throws -> Void)?
    let log: (String) -> Void
    let now: () -> Timestamp
    let store: Store
    var tasks: Tasks { Tasks(store: store) }

    /// What a planned Jira row looked like when this server showed it; worklog_commit writes only rows that are
    /// still exactly like this (row ids can be reused by SQLite, a key or a text can change meanwhile).
    struct Shown: Hashable { var id: Int, task: Int?, start: Timestamp, end: Timestamp, jiraKey: String?, text: String, summary: String? }
    /// Day -> rows shown by the last worklog_plan (or by a refused commit, which returns the new plan to show).
    var shown: [String: [Int: Shown]] = [:]

    /// `refresh` (an incremental scan) runs before each answer; its failure is logged and the answer uses the database.
    public init(store: Store, worklog: @escaping () throws -> DayWorklog, suggester: (() throws -> TaskSuggester)? = nil,
                refresh: (() throws -> Void)? = nil, now: @escaping () -> Timestamp = Time.now, log: @escaping (String) -> Void = { _ in }) {
        self.store = store; makeWorklog = worklog; makeSuggester = suggester; self.refresh = refresh; self.now = now; self.log = log
    }

    func suggester() throws -> TaskSuggester {
        guard let makeSuggester else { throw MCPToolError("suggestions are not set up in this server") }
        return try makeSuggester()
    }

    public func suggestions(day: String, again: Bool) throws -> String {
        scan()
        let r = try mapErrors { try suggester().suggest(day, again: again, now: now()) }
        return SuggestText.run(r, day: day, answer: "ask the user, then task_suggestions_answer with confirm: true; a new task (N…) "
                               + "can be made in Jira instead with task_create_in_jira (preview first)")
    }

    public func answerSuggestions(accept: [String], reject: [String]) throws -> String {
        let s = try suggester()
        // No outer transaction: accept refreshes the day's links (git) and must not hold the write lock meanwhile.
        return try mapErrors {
            try s.accept(accept.compactMap(Int.init)) + accept.filter { Int($0) == nil }.map { try s.acceptNew($0) }
                + s.reject(reject.compactMap(Int.init)) + reject.filter { Int($0) == nil }.map { try s.rejectNew($0) }
        }.joined(separator: "\n")
    }

    public func createInJira(id: String, project: String?, title: String?, description: String?, confirm: Bool, token: String?) throws -> String {
        let s = try suggester()
        return try mapErrors {
            // An earlier try that Jira answered: its issue is taken, nothing new is made.
            if try s.jiraClaimKey(id) != nil {
                return try s.createInJira(id, project: project ?? "", title: title, description: description, takeOnly: true)
            }
            let p: JiraCreatePlan
            do { p = try s.jiraPlan(id, project: project, title: title, description: description) } catch {
                // An earlier try may have made the issue: that one is taken; none is made without the plan shown.
                guard try s.jiraClaim(id) else { throw error }
                return try s.createInJira(id, project: project ?? "", title: title, description: description, takeOnly: true)
            }
            guard let proj = p.project else {
                throw MCPToolError((project.map { "No Jira project \($0) you may create issues in. " } ?? "Choose a project. ")
                                   + "Projects: " + p.projects.map { "\($0.key) (\($0.name))" }.joined(separator: ", ") + ". Nothing was created.")
            }
            // The token ties the confirmation to the values shown: no create without a preview of exactly these.
            let want = String(UInt64(bitPattern: fnv1a64([id.uppercased(), proj, p.title, p.description].joined(separator: "\u{1}"))), radix: 36)
            let preview = "Would create in Jira: a \(p.type ?? "Task") in \(proj), assigned to the user\ntitle: \(p.title)\ndescription:\n"
                + "\(p.description)\nthen \(Txt.dur(p.draft.workedSec)) of work is linked to it.\nProjects: "
                + p.projects.map(\.key).joined(separator: ", ") + "\ntoken: \(want)\nNothing was created. Show this to the user; only "
                + "after they explicitly say to create it, call again with these values, confirm: true and token \(want)."
            guard confirm, token == want else {
                if confirm { throw MCPToolError("The token is not the one of these values; nothing was created. " + preview) }
                return preview
            }
            return try s.createInJira(id, project: proj, title: p.title, description: p.description)
        }
    }

    func scan() { if let refresh { do { try refresh() } catch { log("mcp: scan failed: \(error)") } } }

    /// After a scan, Jira read again when the last read is older than an hour (`JiraCache`), links refreshed.
    func fresh() throws -> DayWorklog {
        scan()
        let w = try makeWorklog()
        _ = JiraCache.current(store, w.jira, now: now(), log: log)
        try w.linker.linkSessions(store)
        return w
    }

    /// A task to change; one of the user's Jira issues (as last read) becomes a task here.
    func find(_ ref: String) throws -> TaskItem {
        guard let t = try tasks.findOrAdopt(ref) else { throw MCPToolError("No task \(ref). task_list shows the keys.") }
        return t
    }

    func check(_ s: String?) throws -> TaskStatus? {
        guard let s else { return nil }
        guard let v = TaskStatus(rawValue: s) else { throw MCPToolError("status must be planned, in_progress, review or done") }
        return v
    }

    /// Models send "" for fields they do not mean to set.
    static func given(_ s: String?) -> String? { s.flatMap { $0.trimmed(" \t\n\r").isEmpty ? nil : $0 } }

    public func list(status: String?, all: Bool, limit: Int) throws -> String {
        let w = try fresh()
        let lines = try tasks.overview(status: try check(status), all: true, limit: .max, base: w.base, idleGap: w.idleGap, now: now())
        let drafts = (try? makeSuggester?().drafts(now: now()).count) ?? 0
        return TaskText.list(lines, base: w.base, all: all, limit: limit, more: "task_list with all: true",
                             drafts: (drafts, "task_suggestions"))
    }

    public func get(_ ref: String) throws -> String {
        let w = try fresh()
        guard let t = try tasks.find(ref) ?? tasks.jiraOnly(ref) else { throw MCPToolError("No task \(ref). task_list shows the keys.") }
        let c = try tasks.card(t, base: w.base, idleGap: w.idleGap, jira: w.jira, now: now())
        return TaskText.card(c, base: w.base, jiraConnected: w.jira != nil)
    }

    public func create(_ f: TaskFields) throws -> String {
        guard let title = Self.given(f.title) else { throw MCPToolError("title is required") }
        let status = try check(f.status) ?? .planned
        let (t, extra) = try mapErrors {
            try store.db.transaction {
                let t = try tasks.add(title: title, key: Self.given(f.key), jiraKey: Self.given(f.jiraKey),
                                      description: Self.given(f.description), status: status, at: now())
                return (t, try apply(t, f, skipBasics: true))
            }
        }
        try makeWorklog().linker.linkSessions(store)
        let links = try tasks.links(t.id).count
        return "Created \(t.key): \(t.title)" + (t.jiraKey.map { " (Jira \($0))" } ?? "") + extra
            + (links > 0 ? "; linked \(links) sessions" : "")
    }

    public func update(_ ref: String, _ f: TaskFields) throws -> String {
        let t = try find(ref)
        let changes = try mapErrors { try store.db.transaction { try apply(t, f, skipBasics: false) } }
        return changes.isEmpty ? "\(t.key): nothing to change" : "\(t.key) updated" + changes
    }

    func mapErrors<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as TaskError { throw MCPToolError(e.description) }
        catch let e as JiraError { throw MCPToolError("\(e)") }
    }

    /// Applies the fields inside the caller's transaction (all or nothing); returns what changed as "; …" pieces.
    func apply(_ t0: TaskItem, _ f: TaskFields, skipBasics: Bool) throws -> String {
        var t = t0, out: [String] = []
        if !skipBasics {
            if let v = Self.given(f.title), v != t.title { t.title = v; out.append("title") }
            if let v = f.description, v != (t.description ?? "") { t.description = Self.given(v); out.append("description") }
            if let s = try check(f.status), s != t.status { t.status = s; out.append("status \(s.rawValue)") }
            if let raw = f.jiraKey {
                let k = Self.given(raw)?.uppercased()
                if k != t.jiraKey {
                    if let k, let other = try tasks.owner(of: k, except: t.id) {
                        throw MCPToolError("Jira issue \(k) already belongs to task \(other.key)")
                    }
                    t.jiraKey = k; out.append(k.map { "Jira key \($0)" } ?? "Jira key removed")
                }
            }
            if !out.isEmpty { try tasks.update(t, at: now()) }
        }
        if let n = Self.given(f.note) { try tasks.addNote(t.id, n, at: now()); out.append("note added") }
        if let x = Self.given(f.todo) { try tasks.addTodo(t.id, x, at: now()); out.append("TODO added") }
        if let n = f.todoDone { try tasks.checkTodo(t.id, number: n); out.append("TODO #\(n) done") }
        if let d = Self.given(f.done) { try tasks.setDone(t.id, day: Time.dayString(now()), text: d); out.append("what was done today set") }
        return out.isEmpty ? "" : "; " + out.joined(separator: ", ")
    }

    /// The plan's rows to write to Jira (with their texts and summaries) as shown.
    func jiraRows(_ p: DayPlan) -> [Int: Shown] {
        var out: [Int: Shown] = [:]
        for r in p.rows where r.state == "planned" && r.jiraKey != nil {
            out[r.id] = Shown(id: r.id, task: r.taskId, start: r.start, end: r.end, jiraKey: r.jiraKey, text: r.text,
                              summary: r.daySummary == true ? r.summary : nil)
        }
        return out
    }

    func planText(_ p: DayPlan, _ w: DayWorklog, _ err: String? = nil) throws -> String {
        shown[p.day] = jiraRows(p)
        return TaskText.plan(p, base: w.base, jiraError: err)
    }

    public func worklogPlan(day: String) throws -> String { try worklogPlan(day: day, refresh: false, json: false) }

    /// Days are cut in `[worklog] tz` after the scan (`Settings.inZone`: the MCP server answers one call at a time).
    public func worklogPlan(day: String?, refresh: Bool, json: Bool) throws -> String {
        scan()
        let w = try makeWorklog()
        return try Settings.inZone(w.config.tz) {
            let (p, err) = try w.plan(day ?? Time.dayString(now()), refresh: refresh)
            let text = try planText(p, w, err)
            if json {
                let e = JSONEncoder()
                e.keyEncodingStrategy = .convertToSnakeCase
                e.outputFormatting = [.sortedKeys]
                return String(decoding: try e.encode(p), as: UTF8.self)
            }
            return text + "\nNothing was written. To log, the user must ask; then worklog_commit with confirm: true (and ids to pick rows)."
        }
    }

    public func worklogConfig() throws -> String {
        let w = try makeWorklog()
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(WorklogSettings(w.config, jiraProjects: JiraCache.load(store).projects.sorted())), as: UTF8.self)
    }

    public func worklogReconcile(from: String, to: String?, format: String) throws -> String {
        scan()
        let w = try makeWorklog()
        let r = try Settings.inZone(w.config.tz) {
            let today = Time.dayString(now())
            return try mapErrors { try w.reconcile(from: from, to: to ?? today, today: today) }
        }
        switch format {
        case "json": return try ReconcileText.json(r)
        case "csv": return ReconcileText.csv(r)
        case "text": return ReconcileText.text(r)
        default: return ReconcileText.markdown(r)
        }
    }

    /// Writes only what this server's last worklog_plan of the day showed: the day is planned again against fresh
    /// data, and if the rows to write differ in anything (task, time, Jira issue, text) nothing is written and the new
    /// plan comes back instead.
    public func worklogCommit(day: String, ids: [Int]?) throws -> String { try worklogCommit(day: day, ids: ids, withSummary: false, summaryComment: []) }

    public func worklogCommit(day: String, ids: [Int]?, withSummary: Bool, summaryComment: [String]) throws -> String {
        let w = try makeWorklog()
        guard w.jira != nil else {
            throw MCPToolError("Jira is not connected" + (w.jiraSetupError.map { " (\($0))" } ?? " ([jira] in config.toml)")
                               + "; nothing was written.")
        }
        guard let before = shown[day] else {
            throw MCPToolError("Call worklog_plan for \(day) first and show it to the user; nothing was written.")
        }
        scan()
        return try Settings.inZone(w.config.tz) {
            try commit(w, day: day, ids: ids, before: before, withSummary: withSummary, comments: Set(summaryComment.map { $0.uppercased() }))
        }
    }

    func commit(_ w: DayWorklog, day: String, ids: [Int]?, before: [Int: Shown], withSummary: Bool, comments: Set<String>) throws -> String {
        let p: DayPlan
        do { p = try w.plan(day, strict: true).plan }
        catch let e as JiraError { throw MCPToolError("Jira failed, nothing was written: \(e)") }
        catch { throw MCPToolError("Could not plan \(day), nothing was written: \(error)") }
        let current = jiraRows(p)
        let wanted = ids.map(Set.init) ?? Set(before.keys)
        let changed = ids == nil ? Set(before.values) != Set(current.values)
                                 : wanted.contains { before[$0] == nil || before[$0] != current[$0] }
        if changed {
            let text = try planText(p, w)
            throw MCPToolError((ids == nil ? "The plan of \(day) changed since it was shown"
                                           : "Rows \(wanted.sorted().map { "#\($0)" }.joined(separator: ", ")) are not exactly as shown")
                               + "; nothing was written. Show this plan to the user:\n" + text)
        }
        let pick = p.rows.filter { wanted.contains($0.id) && current[$0.id] != nil }
        guard !pick.isEmpty else { return "Nothing to write to Jira for \(day)." }
        let r = try w.write(pick, day: day, withSummary: withSummary, commentKeys: comments)
        for row in pick { shown[day]?[row.id] = nil }
        return (r.lines + ["\(r.logged) worklogs written to Jira" + (r.failed > 0 ? ", \(r.failed) not written" : "")] + r.commentLines
                + (r.commentLines.isEmpty ? [] : ["\(r.commented) day summaries written as comments" + (r.commentsFailed > 0 ? ", \(r.commentsFailed) not written" : "")]))
            .joined(separator: "\n")
    }
}
