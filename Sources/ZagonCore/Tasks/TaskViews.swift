#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// What `task list` / `task show` / `log plan` show, as data (JSON, Mac app) and as short text (CLI, MCP).
public struct TaskListLine: Codable, Sendable {
    public var task: TaskItem
    public var sessions: Int
    /// Worked time (on the chosen base) and session time over the last 7 days.
    public var weekSec: Double
    public var weekSessionSec: Double
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
    /// Your worklogs on the Jira issue, all time.
    public var jiraLoggedSec: Double?
    /// Jira is configured but failed (or the issue was not found: then `jira` is nil and this says so).
    public var jiraError: String?
}

extension Tasks {
    public func overview(status: TaskStatus? = nil, limit: Int = 100, base: TaskTime.Base = .sessions, idleGap: Double = 20 * 60,
                         now: Timestamp = Time.now()) throws -> [TaskListLine] {
        let today = Time.dayString(now)
        let from = Time.dayBounds(Time.addDays(today, -6) ?? today)?.start ?? now - 7 * 86400
        let time = try TaskTime.compute(store, from: from, to: now, idleGap: idleGap, base: base)
        return try list(status: status).prefix(limit).map { t in
            TaskListLine(task: t, sessions: try links(t.id).filter { $0.how != LinkHow.unlinked.rawValue }.count,
                         weekSec: time.lines[t.id]?.userSec ?? 0, weekSessionSec: time.lines[t.id]?.sessionSec ?? 0)
        }
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

    public static func list(_ lines: [TaskListLine], base: TaskTime.Base = .sessions) -> String {
        guard !lines.isEmpty else { return "No tasks." }
        return lines.map { l in
            "\(pad(l.task.key, 10)) \(pad(l.task.status.rawValue, 11)) \(label(base)) 7d \(pad(Txt.dur(l.weekSec), 7)) "
                + "\(l.sessions) sessions  \(Txt.oneLine(l.task.title, 70))"
        }.joined(separator: "\n")
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
                out.append("jira: \(k) \"\(i.status)\"" + (t.status.jiraCategory == i.statusCategory ? "" : " (here \(t.status.rawValue))")
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
        var out = [head + " · \(r.items.count) suggestions"]
        if let n = r.note { out.append("note: \(n)") }
        if !r.items.isEmpty {
            out.append(items(r.items))
            out.append("Not counted until accepted: \(answer)")
        }
        return out.joined(separator: "\n")
    }
}
