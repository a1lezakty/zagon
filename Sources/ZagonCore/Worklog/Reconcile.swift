#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Sessions against your Jira worklogs over a range of local days, per task and day: `zagon log reconcile`, MCP
/// `worklog_reconcile` and the Mac app read this. Jira is only read.
public struct Reconcile: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// A Jira task's work in sessions, no worklog.
        case onlySessions = "only_sessions"
        /// A worklog, no work in Zagon.
        case onlyJira = "only_jira"
        /// Both, apart by more than the tolerance (on some day, for a task over the range).
        case mismatch
        case match
        /// A task with no Jira key: stays in Zagon.
        case zagonOnly = "zagon_only"
        /// Work linked to no task (a row per project and branch).
        case noTask = "no_task"
    }

    public struct SessionRef: Codable, Sendable {
        public var id: String
        public var title: String?
        public var project: String?
        public var host: String?
        public var tool: String?
        public var branch: String?
        /// The session's working time that day (all of it, also when it is split between tasks).
        public var sec = 0
    }

    public struct Log: Codable, Sendable {
        public var id: String
        public var start: Timestamp
        public var end: Timestamp
        public var sec: Int
        public var comment: String?
    }

    /// A task, a Jira issue that is no task here (`key` nil, `jiraKey` set) or work with no task in one project and
    /// branch (`key` and `jiraKey` nil, `project`, `branch`), over the range or on one day. `sessions`, `worklogs` and
    /// `done` are filled on day rows only.
    public struct Row: Codable, Sendable {
        public var taskId: Int?
        public var key: String?
        public var jiraKey: String?
        public var title: String?
        public var project: String?
        public var branch: String?
        public var sessionSec: Int
        public var jiraSec: Int
        public var status: Status
        /// The day's "what was done" for the task.
        public var done: String?
        public var sessions: [SessionRef] = []
        public var worklogs: [Log] = []
    }

    public struct Day: Codable, Sendable {
        public var day: String
        /// Before `coverageFrom`: not reconciled, no rows, `jiraSec` only.
        public var beforeCoverage = false
        public var sessionSec = 0
        public var jiraSec = 0
        public var unloggedSec = 0
        public var jiraOnlySec = 0
        public var rows: [Row] = []
    }

    /// Sums over the reconciled day rows: `sessionSec - jiraSec == unloggedSec - jiraOnlySec`.
    public struct Totals: Codable, Sendable {
        public var sessionSec = 0
        public var jiraSec = 0
        /// Session time beyond the worklogs of the same task and day (all of it where there are none, tasks with no
        /// Jira key and work with no task included).
        public var unloggedSec = 0
        /// Worklog time beyond the sessions of the same task and day (all of it where there were none).
        public var jiraOnlySec = 0
        public var zagonOnlySec = 0
        public var noTaskSec = 0
        /// Your worklogs on days before `coverageFrom` (not reconciled, not in `jiraSec`).
        public var jiraBeforeCoverageSec = 0
    }

    public var from: String
    /// The last day counted: `toRequested`, or today when that is later.
    public var to: String
    public var toRequested: String
    /// First day Zagon has whole session history for (nil: no sessions at all); earlier days are not reconciled.
    public var coverageFrom: String?
    /// `sessions` | `user`: what counts as worked time (as in `log plan`).
    public var base: String
    public var toleranceMin: Int
    /// `connected` | `not_connected` | `failed` (`jiraError` says why; the sessions are there all the same).
    public var jira: String
    public var jiraError: String?
    public var totals = Totals()
    /// Per task over the range, most time first.
    public var tasks: [Row] = []
    /// Days with work or worklogs, in order.
    public var days: [Day] = []

    public static let defaultToleranceMin = 15
    /// Longest range, in days.
    public static let maxDays = 400

    /// A Jira task's status on one day.
    public static func status(session s: Int, jira j: Int, toleranceSec: Int) -> Status {
        if j == 0 { return .onlySessions }
        if s == 0 { return .onlyJira }
        return abs(s - j) > toleranceSec ? .mismatch : .match
    }

    /// Claude Code deletes transcripts older than its `cleanupPeriodDays` (30 by default), so its history is whole
    /// only from the earliest end of a Claude session Zagon has; Codex keeps everything (then its first session).
    /// ponytail: that first day itself may miss sessions deleted before Zagon read them (nothing here tells it apart).
    static func coverageFrom(_ db: SQLite) throws -> String? {
        let t = try db.one("""
            SELECT coalesce((SELECT min(last_at) FROM session WHERE tool = 'claude' AND last_at IS NOT NULL),
                            (SELECT min(coalesce(started_at, last_at)) FROM session))
            """) { $0.optReal(0) } ?? nil
        return t.map(Time.dayString)
    }
}

extension DayWorklog {
    /// Your time per task and day (`TaskTime`, as `log plan` counts it; links refreshed first) against your worklogs
    /// started in the range, matched by Jira key and local day. Days after `today` are not counted, days before
    /// `Reconcile.coverageFrom` are not reconciled. Jira: the `worklogAuthor` search (paged) with each issue's worklogs
    /// (`JiraClient.myWorklogs(search:)`); the issues of tasks worked in the range and of worklogs Zagon wrote that it
    /// did not find are read directly, as the search index lags a new worklog by minutes. A Jira failure leaves the
    /// sessions part.
    public func reconcile(from: String, to requested: String, today: String = Time.dayString(Time.now())) throws -> Reconcile {
        // Days are compared as strings: `2026-10-1` becomes `2026-10-01`; a date that does not exist (02-31) is refused.
        func norm(_ s: String) throws -> String {
            guard let p = Time.parseDay(s), let d = Time.addDays(s, 0), Time.parseDay(d)?.2 == p.2 else { throw TaskError("\(s): dates must be YYYY-MM-DD") }
            return d
        }
        let (from, requested, today) = (try norm(from), try norm(requested), try norm(today))
        let to = min(requested, today)
        guard from <= to else { throw TaskError(from > today ? "from \(from) is after today" : "from \(from) is after to \(to)") }
        var days = [from]
        while let next = Time.addDays(days.last!, 1), next <= to {
            guard days.count < Reconcile.maxDays else { throw TaskError("at most \(Reconcile.maxDays) days at a time") }
            days.append(next)
        }
        let (start, end) = (Time.dayBounds(from)!.start, Time.dayBounds(to)!.end)
        _ = JiraCache.current(store, jira)
        try linker.linkSessions(store)
        try linker.linkDay(store, from: start, to: end)
        let db = store.db
        let coverage = try Reconcile.coverageFrom(db)

        var byId: [Int: TaskItem] = [:], byJira: [String: TaskItem] = [:]
        for t in try Tasks(store: store).list() { byId[t.id] = t; if let k = t.jiraKey { byJira[k] = t } }
        var info: [String: Reconcile.SessionRef] = [:]
        try db.query("""
            SELECT id, title, project, host, tool, git_branch FROM session WHERE last_at >= ? AND coalesce(started_at, last_at) < ?
            """, [.real(start), .real(end)]) { r in
            let id = r.text(0) ?? ""
            info[id] = Reconcile.SessionRef(id: id, title: r.text(1), project: r.text(2), host: r.text(3), tool: r.text(4), branch: r.text(5))
        }
        var working: [String: [Interval]] = [:]
        try db.query("SELECT session_id, start, \"end\" FROM activity WHERE kind = 'working' AND start < ? AND \"end\" > ?",
                     [.real(end), .real(start)]) { working[$0.text(0) ?? "", default: []].append(Interval($0.real(1), $0.real(2))) }
        for (k, v) in working { working[k] = Intervals.merge(v) }
        var done: [String: String] = [:]   // "<task id> <day>"
        try db.query("SELECT task_id, day, text FROM task_done WHERE day >= ? AND day <= ? ORDER BY source = 'manual'",
                     [.text(from), .text(to)]) { if let t = $0.text(2), !t.isEmpty { done["\($0.int(0)) \($0.text(1) ?? "")"] = t } }

        struct Cell { var task: Int?, jiraKey: String?, project: String?, branch: String?, sec = 0.0, sessions: [String] = [], logs: [JiraWorklog] = [] }
        // "t<task id>", "j<Jira key>" (an issue that is no task here) or "-<project>|<branch>" (no task).
        var cells: [String: [String: Cell]] = [:]
        var sessionSec: [String: [String: Int]] = [:]   // day -> session -> working seconds
        let exclude = try Worklog(store: store).exclusions(config)
        let skip = Set(exclude.items.flatMap(\.sessions))
        for day in days where coverage.map({ day >= $0 }) ?? false {
            let (a, b) = Time.dayBounds(day)!
            for (sid, ivs) in working where !skip.contains(sid) {
                let s = Int(Intervals.covered(ivs, from: a, to: b).rounded())
                if s > 0 { sessionSec[day, default: [:]][sid] = s }
            }
            for (t, l) in try TaskTime.compute(store, from: a, to: b, idleGap: idleGap, base: base, exclude: exclude).lines where l.userSec > 0 {
                if let t {
                    var c = cells[day]?["t\(t)"] ?? Cell(task: t, jiraKey: byId[t]?.jiraKey)
                    c.sec += l.userSec
                    c.sessions += l.sessions.filter { !c.sessions.contains($0) }
                    cells[day, default: [:]]["t\(t)"] = c
                    continue
                }
                // ponytail: no-task time split by each session's whole working time that day, not only its unlinked part.
                let w = l.sessions.map { Double(sessionSec[day]?[$0] ?? 0) }, sum = w.reduce(0, +)
                for (i, sid) in l.sessions.enumerated() {
                    let s = info[sid], id = "-\(s?.project ?? "")|\(s?.branch ?? "")"
                    var c = cells[day]?[id] ?? Cell(project: s?.project, branch: s?.branch)
                    c.sec += sum > 0 ? l.userSec * w[i] / sum : l.userSec / Double(l.sessions.count)
                    c.sessions.append(sid)
                    cells[day, default: [:]][id] = c
                }
                if l.sessions.isEmpty { cells[day, default: [:]]["-|", default: Cell()].sec += l.userSec }
            }
        }

        var issueTitle: [String: String] = [:], beforeCoverage: [String: Int] = [:]
        var r = Reconcile(from: from, to: to, toRequested: requested, coverageFrom: coverage, base: base.rawValue,
                          toleranceMin: reconcileToleranceMin, jira: "not_connected")
        if let e = jiraSetupError { r.jira = "failed"; r.jiraError = e }
        else if let jira {
            var also = Set(cells.values.flatMap(\.values).compactMap(\.jiraKey))
            try db.query("""
                SELECT DISTINCT t.jira_key FROM worklog_plan w JOIN task t ON t.id = w.task_id
                WHERE w.state IN ('logged', 'writing') AND t.jira_key IS NOT NULL AND w.day >= ? AND w.day <= ?
                """, [.text(from), .text(to)]) { if let k = $0.text(0) { also.insert(k) } }
            do {
                let (logs, summary) = try Self.worklogs(jira, from: start, to: end, also: also)
                r.jira = "connected"
                issueTitle = summary
                for w in logs {
                    let day = Time.dayString(w.started)
                    guard coverage.map({ day >= $0 }) ?? false else { beforeCoverage[day, default: 0] += w.seconds; continue }
                    let task = byJira[w.issueKey], id = task.map { "t\($0.id)" } ?? "j\(w.issueKey)"
                    var c = cells[day]?[id] ?? Cell(task: task?.id, jiraKey: w.issueKey)
                    c.logs.append(w)
                    cells[day, default: [:]][id] = c
                }
            } catch { r.jira = "failed"; r.jiraError = "\(error)" }
        }

        let tol = reconcileToleranceMin * 60
        func row(_ c: Cell, sec: Int, jiraSec: Int, status: Reconcile.Status) -> Reconcile.Row {
            let t = c.task.flatMap { byId[$0] }
            return Reconcile.Row(taskId: c.task, key: t?.key, jiraKey: c.jiraKey, title: t?.title ?? c.jiraKey.flatMap { issueTitle[$0] },
                                 project: c.project, branch: c.branch, sessionSec: sec, jiraSec: jiraSec, status: status)
        }
        func kind(_ c: Cell) -> Reconcile.Status? { c.task == nil && c.jiraKey == nil ? .noTask : c.jiraKey == nil ? .zagonOnly : nil }
        func order(_ a: Reconcile.Row, _ b: Reconcile.Row) -> Bool {
            (max(a.sessionSec, a.jiraSec), ReconcileText.name(b)) > (max(b.sessionSec, b.jiraSec), ReconcileText.name(a))
        }
        var period: [String: (cell: Cell, sec: Int, jira: Int, allMatch: Bool)] = [:]
        for day in Set(cells.keys).union(beforeCoverage.keys).sorted() {
            var d = Reconcile.Day(day: day)
            if let j = beforeCoverage[day] {
                d.beforeCoverage = true; d.jiraSec = j
                r.totals.jiraBeforeCoverageSec += j
                r.days.append(d)
                continue
            }
            for (id, c) in cells[day]! {
                let s = Int(c.sec.rounded()), j = c.logs.reduce(0) { $0 + $1.seconds }
                // Under a minute of work with no worklog is a sliver at a link's edge, not something to log.
                guard j > 0 || s >= 60 else { continue }
                let st = kind(c) ?? Reconcile.status(session: s, jira: j, toleranceSec: tol)
                var x = row(c, sec: s, jiraSec: j, status: st)
                x.done = c.task.flatMap { done["\($0) \(day)"] }
                x.sessions = c.sessions.map { sid in
                    var s = info[sid] ?? Reconcile.SessionRef(id: sid); s.sec = sessionSec[day]?[sid] ?? 0; return s
                }
                x.worklogs = c.logs.map { Reconcile.Log(id: $0.id, start: $0.started, end: $0.interval.end, sec: $0.seconds, comment: $0.comment) }
                d.rows.append(x)
                let p = period[id] ?? (c, 0, 0, true)
                period[id] = (p.cell, p.sec + s, p.jira + j, p.allMatch && st == .match)
                d.sessionSec += s; d.jiraSec += j
                d.unloggedSec += max(0, s - j); d.jiraOnlySec += max(0, j - s)
                if st == .noTask { r.totals.noTaskSec += s }
                if st == .zagonOnly { r.totals.zagonOnlySec += s }
            }
            guard !d.rows.isEmpty else { continue }
            d.rows.sort(by: order)
            r.totals.sessionSec += d.sessionSec; r.totals.jiraSec += d.jiraSec
            r.totals.unloggedSec += d.unloggedSec; r.totals.jiraOnlySec += d.jiraOnlySec
            r.days.append(d)
        }
        // A task matches only when every one of its days does.
        r.tasks = period.values.map { p in
            row(p.cell, sec: p.sec, jiraSec: p.jira, status: kind(p.cell)
                ?? (p.jira == 0 ? .onlySessions : p.sec == 0 ? .onlyJira : p.allMatch ? .match : .mismatch))
        }.sorted(by: order)
        return r
    }

    /// Your worklogs started in [from, to) and the summaries of the issues the search found; the issues in `also` it
    /// did not find are read one by one (one Jira does not show, 404, is skipped).
    static func worklogs(_ jira: JiraClient, from: Timestamp, to: Timestamp, also: Set<String>) throws
        -> (logs: [JiraWorklog], summary: [String: String]) {
        let me = try jira.accountId()
        // worklogDate is in the profile's time zone: ask a day wider, then keep what started in the range.
        let jql = "worklogAuthor = currentUser() AND worklogDate >= \"\(JiraClient.utcDay(from - 86400))\" AND worklogDate <= \"\(JiraClient.utcDay(to + 86400))\""
        var (out, summary) = try jira.myWorklogs(search: jql, from: from, to: to)
        for k in also.subtracting(summary.keys).sorted() {
            do { out += try jira.worklogs(issue: k, startedAfter: from - 86400).filter { $0.accountId == me && $0.started >= from && $0.started < to } }
            catch JiraError.http(404, _) { continue }
        }
        // A moved issue's old key (kept by a task) reads the same worklogs again under that key: count each once.
        var seen = Set<String>()
        return (out.filter { seen.insert($0.id).inserted }.sorted { $0.started < $1.started }, summary)
    }
}

/// Text, Markdown, CSV and JSON of a `Reconcile`, shared by the CLI, MCP and the Mac app.
public enum ReconcileText {
    /// `12:05` (hours:minutes).
    static func hm(_ s: Int) -> String {
        let m = (abs(s) + 30) / 60
        return "\(m / 60):\(m % 60 < 10 ? "0" : "")\(m % 60)"
    }

    static func diff(_ s: Int) -> String { (abs(s) < 30 ? "" : s > 0 ? "+" : "-") + hm(s) }

    static func minutes(_ s: Int) -> String { "\(s < 0 ? -((-s + 30) / 60) : (s + 30) / 60)" }

    static func name(_ r: Reconcile.Row) -> String { r.key ?? r.jiraKey ?? "(no task)" }

    /// The title, or the project and branch of work with no task.
    static func label(_ r: Reconcile.Row) -> String {
        r.title ?? [r.project, r.branch.map { "branch \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    static func notes(_ r: Reconcile) -> [String] {
        var out: [String] = []
        if r.to != r.toRequested { out.append("\(r.toRequested) has not come yet: counted to \(r.to)") }
        if let c = r.coverageFrom, c > r.from {
            out.append("reconciled from \(c): no whole session history before it"
                       + (r.totals.jiraBeforeCoverageSec > 0 ? "; Jira has \(hm(r.totals.jiraBeforeCoverageSec)) there" : ""))
        } else if r.coverageFrom == nil {
            out.append("no sessions yet: nothing to reconcile"
                       + (r.totals.jiraBeforeCoverageSec > 0 ? "; Jira has \(hm(r.totals.jiraBeforeCoverageSec)) in the range" : ""))
        }
        switch r.jira {
        case "connected": break
        case "failed": out.append("Jira failed, sessions only: \(r.jiraError ?? "")")
        default: out.append("Jira not connected: sessions only")
        }
        return out
    }

    static func head(_ r: Reconcile) -> String {
        "\(r.from) – \(r.to): \(TaskText.label(TaskTime.Base(rawValue: r.base) ?? .sessions)) \(hm(r.totals.sessionSec))"
            + (r.jira == "connected" ? " · in Jira \(hm(r.totals.jiraSec)) · not logged \(hm(r.totals.unloggedSec))"
                + " · in Jira beyond sessions \(hm(r.totals.jiraOnlySec))" : "")
            + " · no Jira key \(hm(r.totals.zagonOnlySec)) · no task \(hm(r.totals.noTaskSec))"
    }

    static func legend(_ r: Reconcile) -> String {
        "only_sessions: work, no worklog · only_jira: worklog, no work in Zagon · mismatch: apart by more than "
            + "\(r.toleranceMin) min on a day · zagon_only: task with no Jira key · no_task: work linked to no task"
    }

    public static func text(_ r: Reconcile) -> String {
        var out = [head(r)] + notes(r).map { "note: " + $0 }
        func line(_ x: Reconcile.Row) -> String {
            "\(TaskText.pad(name(x), 10)) \(TaskText.pad(x.status.rawValue, 13)) sessions \(TaskText.pad(hm(x.sessionSec), 7)) "
                + "Jira \(TaskText.pad(hm(x.jiraSec), 7)) \(TaskText.pad(diff(x.sessionSec - x.jiraSec), 8)) \(Txt.oneLine(label(x), 60))"
        }
        guard !r.tasks.isEmpty else { return (out + ["no work and no worklogs"]).joined(separator: "\n") }
        out.append("tasks (\(legend(r))):")
        for x in r.tasks { out.append("  " + line(x)) }
        out.append("days:")
        for d in r.days where !d.beforeCoverage { for x in d.rows { out.append("  \(d.day)  " + line(x)) } }
        return out.joined(separator: "\n")
    }

    /// One line, `|` escaped, for a table cell or a list item.
    static func cell(_ s: String, _ max: Int = 120) -> String { Txt.oneLine(s, max).replacing("|", with: "\\|") }

    public static func markdown(_ r: Reconcile) -> String {
        var out = ["# Worklogs against sessions: \(r.from) – \(r.to)", ""] + notes(r).map { "> " + cell($0, 300) }
        out += ["", "## Totals", "", "| | Hours |", "|---|--:|",
                "| Worked (\(TaskText.label(TaskTime.Base(rawValue: r.base) ?? .sessions))) | \(hm(r.totals.sessionSec)) |"]
        if r.jira == "connected" {
            out += ["| In Jira | \(hm(r.totals.jiraSec)) |", "| Not logged | \(hm(r.totals.unloggedSec)) |",
                    "| In Jira beyond sessions | \(hm(r.totals.jiraOnlySec)) |"]
            if r.totals.jiraBeforeCoverageSec > 0 {
                out.append("| In Jira \(r.coverageFrom.map { "before \($0)" } ?? "with no sessions") (not reconciled) | \(hm(r.totals.jiraBeforeCoverageSec)) |")
            }
        }
        out += ["| Tasks with no Jira key | \(hm(r.totals.zagonOnlySec)) |", "| No task | \(hm(r.totals.noTaskSec)) |", "",
                legend(r) + " · match.", "", "## Tasks", ""]
        guard !r.tasks.isEmpty else { return (out + ["No work and no worklogs."]).joined(separator: "\n") }
        out += ["| Task | Jira | Title | Sessions | Jira | Diff | Status |", "|---|---|---|--:|--:|--:|---|"]
        for x in r.tasks {
            out.append("| \(x.key ?? (x.jiraKey == nil ? "(no task)" : "")) | \(x.jiraKey ?? "") | \(cell(label(x), 80)) | \(hm(x.sessionSec)) "
                       + "| \(hm(x.jiraSec)) | \(diff(x.sessionSec - x.jiraSec)) | \(x.status.rawValue) |")
        }
        out.append("| **Total** | | | **\(hm(r.totals.sessionSec))** | **\(hm(r.totals.jiraSec))** | **\(diff(r.totals.sessionSec - r.totals.jiraSec))** | |")
        out += ["", "## By day"]
        for d in r.days where !d.beforeCoverage {
            out += ["", "### \(d.day) · sessions \(hm(d.sessionSec)) · Jira \(hm(d.jiraSec))", ""]
            for x in d.rows {
                out.append("- **\(name(x))** \(cell(label(x), 80)) — \(x.status.rawValue) · sessions \(hm(x.sessionSec)) · Jira \(hm(x.jiraSec))")
                for s in x.sessions {
                    out.append("  - session \(hm(s.sec)): " + cell([s.title ?? s.id, s.project, s.host, s.tool, s.branch].compactMap { $0 }
                        .joined(separator: " · ")))
                }
                if let t = x.done { out.append("  - done: " + cell(t, 300)) }
                for w in x.worklogs {
                    out.append("  - worklog \(Txt.clock(w.start))–\(Txt.clock(w.end)) \(hm(w.sec))"
                               + (w.comment.map { $0.isEmpty ? "" : ": " + cell($0, 200) } ?? ""))
                }
            }
        }
        return out.joined(separator: "\n")
    }

    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + s.replacing("\"", with: "\"\"") + "\"" : s
    }

    /// A line per task and day; minutes as numbers.
    public static func csv(_ r: Reconcile) -> String {
        var out = ["day,key,jira_key,title,status,sessions_min,jira_min,diff_min,sessions,worklogs"]
        for d in r.days where !d.beforeCoverage {
            for x in d.rows {
                let sessions = x.sessions.map { $0.title ?? $0.id }.joined(separator: "; ")
                let logs = x.worklogs.map { "\(Txt.clock($0.start))–\(Txt.clock($0.end))" + ($0.comment.map { $0.isEmpty ? "" : " " + $0 } ?? "") }
                    .joined(separator: "; ")
                out.append([d.day, x.key ?? "", x.jiraKey ?? "", label(x), x.status.rawValue, minutes(x.sessionSec), minutes(x.jiraSec),
                            minutes(x.sessionSec - x.jiraSec), sessions, logs].map(csvField).joined(separator: ","))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The JSON `zagon log reconcile --json` prints (snake_case keys).
    public static func json(_ r: Reconcile) throws -> String {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(r), as: UTF8.self)
    }
}
