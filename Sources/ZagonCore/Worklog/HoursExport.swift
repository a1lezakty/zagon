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
    /// planned: in the plan, not in Jira yet | logged: in Jira | writing: a write not settled yet that Jira does not show
    public var state: String
}

extension DayWorklog {
    /// Hours for invoices over a range of days (cut in the caller's zone): each day's plan, made again as `log plan`
    /// makes it (no AI), and your worklogs in Jira, those Zagon wrote and those written by hand. When Jira is set up
    /// but cannot be read, the plans stay as they were and Zagon's own logged rows stand for Jira (`jiraError` says why).
    public func hours(from: String, to requested: String, today: String = Time.dayString(Time.now())) throws
        -> (lines: [HoursLine], jiraError: String?) {
        let (from, requested, today) = (try Self.normDay(from), try Self.normDay(requested), try Self.normDay(today))
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
            // Issues the lagging worklog search may not show yet: Zagon's own worklogs and the tasks worked in the range
            // (sessions that ran in it, as `fetchJira`: a manual link spans the whole session).
            var also = Set<String>()
            try store.db.query("""
                SELECT t.jira_key FROM worklog_plan w JOIN task t ON t.id = w.task_id
                WHERE w.state IN ('logged', 'writing') AND t.jira_key IS NOT NULL AND w.day >= ?1 AND w.day <= ?2
                UNION SELECT t.jira_key FROM task t JOIN task_session ts ON ts.task_id = t.id JOIN session s ON s.id = ts.session_id
                WHERE t.jira_key IS NOT NULL AND ts.how NOT IN ('unlinked', 'suggested') AND s.last_at >= ?3
                  AND coalesce(s.started_at, s.last_at) < ?4 AND ts.start + \(LinkHow.maxNudge) < ?4 AND ts."end" > ?3
                """, [.text(from), .text(to), .real(start), .real(end)]) { if let k = $0.text(0) { also.insert(k) } }
            do {
                // Writes an earlier commit left `writing` are settled first, as `log plan` does: one that never reached
                // Jira is planned again instead of being lost between the plan and Jira.
                for day in days { _ = try settle(day) }
                // One search for the range, not one per day.
                (logs, summary) = try Self.worklogs(jira, from: start, to: end, also: also)
            } catch { jiraError = "\(error)" }
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
        // With Jira read, what is in Jira comes from Jira (also Zagon's own worklogs, as they are there now); a write
        // still unsettled (in flight, or not checked) stays as `writing` unless a worklog of its issue covers it.
        func inJira(_ r: WorklogRow) -> Bool {
            logs?.contains { $0.issueKey == r.jiraKey && $0.started < r.end && $0.started + Double($0.seconds) > r.start } ?? false
        }
        for r in rows where r.state == "planned" || (r.state == "writing" && !inJira(r)) || (logs == nil && r.state == "logged") {
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

    /// `09:05:00` local (zones are whole minutes: the seconds are the timestamp's).
    static func clockSec(_ ts: Timestamp) -> String { Txt.clock(ts) + ":" + p2((Int(ts.rounded(.down)) % 60 + 60) % 60) }

    /// A text cell a spreadsheet would run as a formula (`=`, `+`, `-`, `@`, tab, CR first) gets a leading `'`.
    static func safe(_ s: String) -> String { s.unicodeScalars.first.map { "=+-@\t\r".unicodeScalars.contains($0) } == true ? "'" + s : s }

    /// `1:30:00`
    static func duration(_ s: Int) -> String { "\(s / 3600):" + p2(s % 3600 / 60) + ":" + p2(s % 60) }

    /// Decimal hours, two places: `1.50`.
    static func hours(_ s: Int) -> String {
        let c = (s * 100 + 1800) / 3600
        return "\(c / 100)." + p2(c % 100)
    }

    /// `date,start,end,hours,task,title,text,state`: a line per row; `task` is the Jira key, else the task's key. Titles
    /// (any Jira project member sets them) and texts never start a formula when the file is opened in a spreadsheet.
    public static func csv(_ lines: [HoursLine]) -> String {
        var out = ["date,start,end,hours,task,title,text,state"]
        for l in lines {
            out.append([l.day, Txt.clock(l.start), Txt.clock(l.start + Double(l.seconds)), hours(l.seconds), l.jiraKey ?? l.taskKey ?? "",
                        safe(l.title ?? ""), safe(l.text), l.state].map(ReconcileText.csvField).joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Toggl Track's CSV import (https://support.toggl.com/toggl-track-csv-import-guide): Email, Start Date
    /// (YYYY-MM-DD), Start Time and Duration (HH:MM:SS; the guide's own example writes 1 hour as `1:00:00`) are
    /// required; Description is the key and the text (else the title) on one line, Project the Jira project. Toggl
    /// reads the times in the importing profile's zone.
    public static func toggl(_ lines: [HoursLine], email: String) -> String {
        var out = ["Email,Start Date,Start Time,Duration,Description,Project"]
        for l in lines {
            let what = l.text.isEmpty ? l.title ?? "" : l.text
            let description = Txt.oneLine([l.jiraKey ?? l.taskKey ?? "", what].filter { !$0.isEmpty }.joined(separator: " "), .max)
            let project = l.jiraKey.map { String($0.prefix { $0 != "-" }) } ?? ""
            out.append([email, l.day, clockSec(l.start), duration(l.seconds), description, project]
                .map(ReconcileText.csvField).joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
