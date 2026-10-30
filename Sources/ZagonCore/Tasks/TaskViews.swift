#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// What `task list` / `task show` / `log plan` show, as data (JSON, Mac app) and as short text (CLI, MCP).
public struct TaskListLine: Codable, Sendable {
    /// `id` 0: one of your open Jira issues that is no task here yet (`--all` only).
    public var task: TaskItem
    public var sessions: Int
    /// Worked time (on the chosen base) and session time over the last 7 days.
    public var weekSec: Double
    public var weekSessionSec: Double
    /// In the main list: worked on in the last 7 days (time, a link reaching into them, your Jira worklogs, TODO /
    /// notes / what was done of those days, an open TODO), or an own task that is not done since before then. False:
    /// in Jira, no work here then. nil (a zagon before 0.1.1) = true.
    public var worked: Bool?
    /// The issue's Jira status as last read (`JiraCache`).
    public var jiraStatus: String?
}

public struct TaskCard: Codable, Sendable {
    public var task: TaskItem
    /// Over the whole history of the task's sessions.
    public var time: TaskTimeLine
    public var todos: [TaskTodo]
    public var notes: [TaskNote]
    public var done: [TaskDone]
    public var sessions: [TaskLink]
    public var jira: JiraIssue?
    /// That Jira status as a status here (`[jira] review_statuses`).
    public var jiraStatusHere: TaskStatus?
    /// Your worklogs on the Jira issue, all time.
    public var jiraLoggedSec: Double?
    /// Jira is configured but failed (or the issue was not found: then `jira` is nil and this says so).
    public var jiraError: String?
}

extension Tasks {
    /// The task list: tasks worked on in the last 7 days first (most time first); `all` adds the rest, also your open
    /// Jira issues that are no task here (`JiraCache`, as last read).
    public func overview(status: TaskStatus? = nil, all: Bool = false, limit: Int = 100, base: TaskTime.Base = .sessions,
                         idleGap: Double = 20 * 60, now: Timestamp = Time.now()) throws -> [TaskListLine] {
        let today = Time.dayString(now)
        let from = Time.dayBounds(Time.addDays(today, -6) ?? today)?.start ?? now - 7 * 86400
        let time = try TaskTime.compute(store, from: from, to: now, idleGap: idleGap, base: base)
        let cache = JiraCache.load(store)
        var busy = Set<Int>()
        try db.query("""
            SELECT ts.task_id FROM task_session ts JOIN session s ON s.id = ts.session_id
            WHERE ts.how NOT IN ('unlinked', 'suggested') AND s.last_at >= ?1 AND ts."end" > ?1
            UNION SELECT task_id FROM task_todo WHERE created >= ?1 OR done = 0 UNION SELECT task_id FROM task_note WHERE created >= ?1
            UNION SELECT task_id FROM task_done WHERE day >= ?2
            """, [.real(from), .text(Time.dayString(from))]) { busy.insert($0.int(0)) }
        var lines = try list().map { t in
            let sec = time.lines[t.id]?.userSec ?? 0, sessionSec = time.lines[t.id]?.sessionSec ?? 0
            let worked = sec > 0 || sessionSec > 0 || busy.contains(t.id) || t.jiraKey.map(cache.logged.contains) == true
                || (t.jiraKey == nil && !(t.status == .done && t.updated < from))
            return TaskListLine(task: t, sessions: try links(t.id).filter { $0.how != LinkHow.unlinked.rawValue }.count,
                                weekSec: sec, weekSessionSec: sessionSec, worked: worked, jiraStatus: t.jiraKey.flatMap { cache.issues[$0]?.status })
        }
        if all {
            let here = Set(lines.flatMap { [$0.task.key, $0.task.jiraKey].compactMap { $0 } })
            for k in cache.mine.sorted() where !here.contains(k) {
                guard let i = cache.issues[k], i.statusCategory != "done" else { continue }
                let t = TaskItem(id: 0, key: k, title: i.summary, status: TaskStatus(jira: i, review: cache.review), jiraKey: k, created: 0, updated: 0)
                lines.append(TaskListLine(task: t, sessions: 0, weekSec: 0, weekSessionSec: 0, worked: false, jiraStatus: i.status))
            }
        }
        let shown = lines.filter { (all || $0.worked == true) && (status == nil || $0.task.status == status) }
        // Stable: `list()` is newest change first.
        let worked = shown.filter { $0.worked == true }.enumerated().sorted { ($0.element.weekSec, -$0.offset) > ($1.element.weekSec, -$1.offset) }
        return Array((worked.map(\.element) + shown.filter { $0.worked != true }).prefix(limit))
    }

    /// One of your Jira issues that is no task here (as last read), as a task with id 0: to show, not to edit.
    public func jiraOnly(_ ref: String) -> TaskItem? {
        let cache = JiraCache.load(store), k = ref.uppercased()
        guard cache.mine.contains(k), let i = cache.issues[k] else { return nil }
        return TaskItem(id: 0, key: k, title: i.summary, status: TaskStatus(jira: i, review: cache.review), jiraKey: k, created: 0, updated: 0)
    }

    /// A task to change: the task, or one of your Jira issues (as last read) made a task (at `at`).
    public func findOrAdopt(_ ref: String, at: Timestamp = Time.now()) throws -> TaskItem? {
        if let t = try find(ref) { return t }
        guard let j = jiraOnly(ref) else { return nil }
        return try add(title: j.title.isEmpty ? j.key : j.title, key: j.key, status: j.status, at: at)
    }

    /// Everything about one task; Jira (if given) adds its status and your logged time, its failure is reported in
    /// `jiraError` instead of thrown.
    public func card(_ t: TaskItem, base: TaskTime.Base = .sessions, idleGap: Double = 20 * 60, jira: JiraClient? = nil,
                     now: Timestamp = Time.now()) throws -> TaskCard {
        let links = try self.links(t.id).filter { $0.how != LinkHow.unlinked.rawValue }
        var from = now
        try db.query("""
            SELECT min(coalesce(s.started_at, s.last_at)) FROM task_session ts JOIN session s ON s.id = ts.session_id
            WHERE ts.task_id = ? AND ts.how NOT IN ('unlinked', 'suggested')
            """, [.int(Int64(t.id))]) { r in if let v = r.optReal(0) { from = min(from, v) } }
        let line = try TaskTime.compute(store, from: from, to: now, idleGap: idleGap, base: base).lines[t.id] ?? TaskTimeLine(taskId: t.id)
        var c = TaskCard(task: t, time: line, todos: try todos(t.id), notes: try notes(t.id), done: try done(t.id), sessions: links)
        if let k = t.jiraKey, let jira {
            do {
                let me = try jira.accountId()
                c.jira = try jira.issue(k)
                c.jiraStatusHere = c.jira.map { TaskStatus(jira: $0, review: jira.config.reviewStatuses) }
                if c.jira == nil { c.jiraError = "issue \(k) not found in Jira" }
                else { c.jiraLoggedSec = Double(try jira.worklogs(issue: k, startedAfter: 0).filter { $0.accountId == me }.reduce(0) { $0 + $1.seconds }) }
            } catch { c.jiraError = "\(error)" }
        }
        return c
    }
}

public enum TaskText {
    static func label(_ base: TaskTime.Base) -> String { base == .user ? "you" : "worked" }
    static func pad(_ s: String, _ w: Int) -> String { s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count) }

    /// `lines` as `overview(all: true)` gives them: without `all` only the worked ones, and how many more there are.
    public static func list(_ lines: [TaskListLine], base: TaskTime.Base = .sessions, all: Bool = false, limit: Int = .max,
                            more: String = "task list --all") -> String {
        func line(_ l: TaskListLine) -> String {
            "\(pad(l.task.key, 10)) \(pad(l.task.status.rawValue, 11)) \(label(base)) 7d \(pad(Txt.dur(l.weekSec), 7)) "
                + "\(l.sessions) sessions  \(Txt.oneLine(l.task.title, 70))" + (l.jiraStatus.map { "  · Jira \"\($0)\"" } ?? "")
                + (l.task.id == 0 ? "  (not a task here yet)" : "")
        }
        let worked = lines.filter { $0.worked != false }, rest = lines.filter { $0.worked == false }
        let open = rest.filter { $0.task.status != .done }.count
        var out = worked.isEmpty ? ["No tasks worked on in the last 7 days."] : worked.prefix(limit).map(line)
        if all, !rest.isEmpty { out += ["In Jira, no work here in the last 7 days:"] + rest.prefix(limit).map(line) }
        else if !all, open > 0 { out.append("+ \(open) more open in Jira with no work here in the last 7 days: \(more)") }
        return out.joined(separator: "\n")
    }

    public static func card(_ c: TaskCard, base: TaskTime.Base = .sessions, jiraConnected: Bool = false) -> String {
        let t = c.task
        var out = ["\(t.key)  \(t.status.rawValue)  \(t.title)"]
        if let d = t.description, !d.isEmpty { out.append("  \(d)") }
        out.append("time: \(label(base)) \(Txt.dur(c.time.userSec)) · sessions \(Txt.dur(c.time.sessionSec)) · "
                   + "\(Txt.tokens(c.time.tokens.total)) tokens"
                   + c.time.weekPct.sorted { $0.key < $1.key }.map { " · \($0.key) week \(Txt.pct($0.value))" }.joined())
        if let k = t.jiraKey {
            if let i = c.jira {
                out.append("jira: \(k) \"\(i.status)\"" + (c.jiraStatusHere.map { $0 == t.status } ?? true ? "" : " (here \(t.status.rawValue))")
                           + (c.jiraLoggedSec.map { " · you logged \(Txt.dur($0)) of \(Txt.dur(c.time.userSec)) worked" } ?? ""))
            } else if let e = c.jiraError { out.append("jira: \(k): \(e)") }
            else { out.append("jira: \(k)" + (jiraConnected ? "" : " (Jira not connected)")) }
        } else { out.append("jira: not in Jira, stays in Zagon") }
        if !c.todos.isEmpty {
            out.append("todo:")
            for (i, x) in c.todos.enumerated() { out.append("  \(i + 1). [\(x.done ? "x" : " ")] \(x.text)") }
        }
        if !c.done.isEmpty {
            out.append("done:")
            for d in c.done.prefix(14) { out.append("  \(d.day)  \(Txt.oneLine(d.text, 200))" + (d.source == "auto" ? "  (auto)" : "")) }
        }
        if !c.notes.isEmpty { out.append("notes:"); for n in c.notes { out.append("  \(Time.dayString(n.created))  \(n.text)") } }
        if !c.sessions.isEmpty {
            out.append("sessions:")
            for l in c.sessions.prefix(20) {
                out.append("  \(l.sessionId)  \(l.how)  \(l.lastAt.map(Time.dayString) ?? "")  \(Txt.oneLine(l.title ?? "", 60))")
            }
        }
        return out.joined(separator: "\n")
    }

    public static func rows(_ rows: [WorklogRow]) -> String {
        rows.map { r in
            "#\(pad("\(r.id)", 5)) \(pad(r.taskKey ?? "-", 10)) \(Txt.clock(r.start))–\(Txt.clock(r.end)) \(pad(Txt.dur(Double(r.seconds)), 7)) "
                + "\(pad(r.state, 8)) \(Txt.oneLine(r.text, 260))" + (r.jiraKey == nil ? "  (Zagon only)" : "")
        }.joined(separator: "\n")
    }

    public static func plan(_ p: DayPlan, base: TaskTime.Base = .sessions, jiraError: String? = nil) -> String {
        let toJira = p.rows.filter { $0.state == "planned" && $0.jiraKey != nil }.reduce(0) { $0 + $1.seconds }
        var out = ["\(p.day): \(label(base)) \(Txt.dur(p.userSec)) · sessions \(Txt.dur(p.sessionSec))"
                   + (p.jiraSec.map { " · in Jira \(Txt.dur($0))" } ?? " · Jira not connected")
                   + " · to log to Jira \(Txt.dur(Double(toJira)))"]
        if let e = jiraError { out.append("Jira failed, planned without it: \(e)") }
        out.append(p.rows.isEmpty ? "nothing to log" : rows(p.rows))
        if !p.tasks.isEmpty {
            out.append("tasks:")
            for t in p.tasks {
                out.append("  \(pad(t.key ?? "-", 10)) \(label(base)) \(pad(Txt.dur(t.userSec), 7)) sessions \(pad(Txt.dur(t.sessionSec), 7))"
                           + (p.jiraSec == nil ? "" : " Jira \(pad(Txt.dur(t.jiraSec), 7))") + " \(Txt.oneLine(t.title ?? "", 60))")
            }
        }
        if p.unassignedSec > 0 {
            out.append("no task: \(Txt.dur(p.unassignedSec))"
                       + (p.unknownKeys.isEmpty ? "" : " · keys seen: \(p.unknownKeys.joined(separator: ", ")) (add them as tasks to link)"))
        }
        for n in p.notes { out.append("note: \(n)") }
        return out.joined(separator: "\n")
    }
}

extension Txt {
    /// `HH:MM` local.
    static func clock(_ ts: Timestamp) -> String {
        var t = time_t(min(max(ts, -1e11), 1e11).rounded(.down)), v = tm()
        localtime_r(&t, &v)
        return (v.tm_hour < 10 ? "0" : "") + "\(v.tm_hour):" + (v.tm_min < 10 ? "0" : "") + "\(v.tm_min)"
    }
}

public enum SuggestText {
    /// Suggested new tasks: id, time, title, the worklog text.
    public static func drafts(_ d: [NewTaskDraft]) -> String {
        d.map { x in
            "#\(TaskText.pad(x.id, 5)) new        \(TaskText.pad(Txt.dur(x.workedSec), 7)) \(x.day)  \(Txt.oneLine(x.title, 70))"
                + (x.done.isEmpty ? "" : "\n       \(Txt.oneLine(x.done, 200))")
        }.joined(separator: "\n")
    }

    public static func items(_ items: [Suggestion]) -> String {
        items.map { s in
            "#\(TaskText.pad("\(s.id)", 5)) \(TaskText.pad(s.key, 10)) \(TaskText.pad(Txt.dur(s.workedSec), 7)) "
                + "\(Txt.clock(s.start))–\(Txt.clock(s.end))  \(Int((s.confidence * 100).rounded()))%  "
                + "\(Txt.oneLine(s.sessionTitle ?? s.project ?? s.sessionId, 50))" + (s.reason.isEmpty ? "" : "  — \(s.reason)")
        }.joined(separator: "\n")
    }

    public static func run(_ r: TaskSuggester.Run, day: String,
                           answer: String = "zagon task accept <id…> · zagon task reject <id…>") -> String {
        var head = "\(day): \(r.segments) stretches without a task"
        if r.made {
            head += ", \(r.asked) asked · \(r.engine)"
            if r.engine != "none" {
                head += " \(Int(r.seconds.rounded())) s" + (r.costUSD.map { " · $\(Double(Int(($0 * 10000).rounded())) / 10000)" } ?? "")
                    + (r.inputTokens.map { " · \(Txt.tokens($0)) in" } ?? "") + (r.outputTokens.map { " / \(Txt.tokens($0)) out" } ?? "")
            }
        } else { head += " · suggested earlier by \(r.engine) (--again asks again)" }
        var out = [head + " · \(r.items.count) suggestions" + (r.drafts.isEmpty ? "" : ", \(r.drafts.count) new tasks")]
        if let n = r.note { out.append("note: \(n)") }
        if !r.items.isEmpty { out.append(items(r.items)) }
        if !r.drafts.isEmpty { out.append(drafts(r.drafts)) }
        if !r.items.isEmpty || !r.drafts.isEmpty { out.append("Not counted until accepted: \(answer)") }
        return out.joined(separator: "\n")
    }
}
