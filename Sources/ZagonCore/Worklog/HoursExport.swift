#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A line of `zagon log export`: a planned row, or a worklog in Jira.
public struct HoursLine: Codable, Sendable, Equatable {
    public var day: String
    public var start: Timestamp
    public var seconds: Int
    public var jiraKey: String?
    /// The task here; nil for a worklog on an issue that is no task here.
    public var taskKey: String?
    public var title: String?
    public var text: String
    /// planned: in the plan, not in Jira yet | logged: in Jira | writing: a write that did not finish (Jira not read)
    public var state: String
}

extension DayWorklog {
    /// Hours for invoices over a range of days (cut in the caller's zone): each day's plan, made again as `log plan`
    /// makes it (no AI), and your worklogs in Jira, those Zagon wrote and those written by hand. When Jira is set up
    /// but cannot be read, the plans stay as they were and Zagon's own logged rows stand for Jira (`jiraError` says why).
    public func hours(from: String, to requested: String, today: String = Time.dayString(Time.now())) throws
        -> (lines: [HoursLine], jiraError: String?) {
        guard Time.parseDay(from) != nil, Time.parseDay(requested) != nil else { throw TaskError("dates must be YYYY-MM-DD") }
        let to = min(requested, today)
        guard from <= to else { throw TaskError("from \(from) is after \(to)") }
        var days = [from]
        while let next = Time.addDays(days.last!, 1), next <= to {
            guard days.count < Reconcile.maxDays else { throw TaskError("at most \(Reconcile.maxDays) days at a time") }
            days.append(next)
        }
        let (start, end) = (Time.dayBounds(from)!.start, Time.dayBounds(to)!.end)

        _ = JiraCache.current(store, jira)  // your Jira issues found in the work become tasks
        try linker.linkSessions(store)
        try linker.linkDay(store, from: start, to: end)
        let wl = Worklog(store: store), exclude = try wl.exclusions(config)
        var jiraError = jiraSetupError, logs: [JiraWorklog]?, summary: [String: String] = [:]
        if jiraError == nil, let jira {
            // Issues the lagging worklog search may not show yet: Zagon's own worklogs and the tasks worked in the range.
            var also = Set<String>()
            try store.db.query("""
                SELECT t.jira_key FROM worklog_plan w JOIN task t ON t.id = w.task_id
                WHERE w.state IN ('logged', 'writing') AND t.jira_key IS NOT NULL AND w.day >= ?1 AND w.day <= ?2
                UNION SELECT t.jira_key FROM task t JOIN task_session ts ON ts.task_id = t.id
                WHERE t.jira_key IS NOT NULL AND ts.how NOT IN ('unlinked', 'suggested') AND ts.start < ?4 AND ts."end" > ?3
                """, [.text(from), .text(to), .real(start), .real(end)]) { if let k = $0.text(0) { also.insert(k) } }
            // One search for the range, not one per day.
            do { (logs, summary) = try Self.worklogs(jira, from: start, to: end, also: also) } catch { jiraError = "\(error)" }
        }

        // A plan made again without the Jira it is set up with would lay rows over worklogs it did not see.
        var rows: [WorklogRow] = []
        for day in days {
            if jiraError == nil {
                let jd = logs.map { JiraDay(worklogs: $0, issues: [:], review: jira?.config.reviewStatuses ?? JiraConfig.defaultReview) }
                rows += try wl.plan(day: day, idleGap: idleGap, base: base, jira: jd, linker: linker, config: config).rows
            } else { rows += try wl.filled(day: day, config: config, exclude: exclude) }
        }

        var byId: [Int: TaskItem] = [:], byJira: [String: TaskItem] = [:]
        for t in try Tasks(store: store).list() { byId[t.id] = t; if let k = t.jiraKey { byJira[k] = t } }
        var out: [HoursLine] = []
        // With Jira read, what is in Jira comes from Jira (also Zagon's own worklogs, as they are there now).
        for r in rows where r.state == "planned" || (logs == nil && (r.state == "logged" || r.state == "writing")) {
            out.append(HoursLine(day: r.day, start: r.start, seconds: r.seconds, jiraKey: r.jiraKey, taskKey: r.taskKey,
                                 title: r.taskId.flatMap { byId[$0]?.title }, text: r.text, state: r.state))
        }
        // As in `log reconcile`: worklogs on an excluded task are left out.
        let skip = Set(exclude.items.flatMap(\.tasks))
        for w in logs ?? [] where !(byJira[w.issueKey].map { skip.contains($0.id) } ?? false) {
            let t = byJira[w.issueKey]
            out.append(HoursLine(day: Time.dayString(w.started), start: w.started, seconds: w.seconds, jiraKey: w.issueKey, taskKey: t?.key,
                                 title: summary[w.issueKey] ?? t?.title, text: w.comment ?? "", state: "logged"))
        }
        return (out.sorted { ($0.start, $0.jiraKey ?? $0.taskKey ?? "") < ($1.start, $1.jiraKey ?? $1.taskKey ?? "") }, jiraError)
    }
}

/// `zagon log export` formats; times in the zone the caller cuts days in.
public enum HoursText {
    static func p2(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    /// `09:05`, with `seconds` `09:05:00`, local.
    static func clock(_ ts: Timestamp, seconds: Bool = false) -> String {
        var t = time_t(ts.rounded(.down)), v = tm()
        localtime_r(&t, &v)
        return p2(Int(v.tm_hour)) + ":" + p2(Int(v.tm_min)) + (seconds ? ":" + p2(Int(v.tm_sec)) : "")
    }

    /// `1:30:00`
    static func duration(_ s: Int) -> String { "\(s / 3600):" + p2(s % 3600 / 60) + ":" + p2(s % 60) }

    /// Decimal hours, two places: `1.50`.
    static func hours(_ s: Int) -> String {
        let c = (s * 100 + 1800) / 3600
        return "\(c / 100)." + p2(c % 100)
    }

    /// `date,start,end,hours,task,title,text,state`: a line per row; `task` is the Jira key, else the task's key.
    public static func csv(_ lines: [HoursLine]) -> String {
        var out = ["date,start,end,hours,task,title,text,state"]
        for l in lines {
            out.append([l.day, clock(l.start), clock(l.start + Double(l.seconds)), hours(l.seconds), l.jiraKey ?? l.taskKey ?? "",
                        l.title ?? "", l.text, l.state].map(ReconcileText.csvField).joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Toggl Track's CSV import (https://support.toggl.com/toggl-track-csv-import-guide): Email, Start Date
    /// (YYYY-MM-DD), Start Time and Duration (HH:MM:SS) are required; Description is the key and the text (else the
    /// title) on one line, Project the Jira project.
    public static func toggl(_ lines: [HoursLine], email: String) -> String {
        var out = ["Email,Start Date,Start Time,Duration,Description,Project"]
        for l in lines {
            let what = l.text.isEmpty ? l.title ?? "" : l.text
            let description = Txt.oneLine([l.jiraKey ?? l.taskKey ?? "", what].filter { !$0.isEmpty }.joined(separator: " "), .max)
            let project = l.jiraKey.map { String($0.prefix { $0 != "-" }) } ?? ""
            out.append([email, l.day, clock(l.start, seconds: true), duration(l.seconds), description, project]
                .map(ReconcileText.csvField).joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
