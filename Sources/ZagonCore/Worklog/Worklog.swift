/// The day's worklog plan stored in `worklog_plan` (state planned | logged | skipped), built from your time per task.
public struct WorklogRow: Codable, Sendable {
    public var id: Int
    public var day: String
    public var taskId: Int?
    public var taskKey: String?
    public var jiraKey: String?
    public var start: Timestamp
    public var end: Timestamp
    public var seconds: Int
    public var text: String
    public var state: String
    public var jiraWorklogId: String?
    // Since 0.1.5 (optional: a plan from 0.1.4 has none). Filled for planned rows.
    /// summary | manual | titles
    public var textSource: String?
    /// The longest planned row of its task that day: it carries the task's day summary.
    public var daySummary: Bool?
    public var summary: String?
    /// summary | manual
    public var summarySource: String?
    public var sessions: [RowSession]?
}

/// A session behind a plan row: its time on the row's task inside the row (the day for the summary row), how it is
/// linked to the task (the strongest link) and its role: `leader` typed into other sessions' terminals that day,
/// `worker` got the task from a brief or was typed into by a leader, else `single`.
public struct RowSession: Codable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var role: String
    public var how: String
    public var seconds: Int
}

public struct ExcludedTime: Codable, Sendable, Equatable {
    public var kind: String, name: String
    public var seconds: Int
}

public struct ProjectTime: Codable, Sendable, Equatable {
    public var project: String
    public var seconds: Int
}

public struct PlanTaskLine: Codable, Sendable {
    public var taskId: Int?
    public var key: String?
    public var title: String?
    public var userSec: Double
    public var sessionSec: Double
    /// Your worklogs on this task's Jira issue that day.
    public var jiraSec: Double
}

/// Worklogs already in Jira for the day (yours, any issue) and what Jira says about the tasks' issues.
public struct JiraDay: Sendable {
    public var worklogs: [JiraWorklog]
    /// Jira key -> issue; a key mapped to nil was looked up and not found.
    public var issues: [String: JiraIssue?]
    /// `[jira] review_statuses`: how a Jira status reads here.
    public var review = JiraConfig.defaultReview
    public init(worklogs: [JiraWorklog], issues: [String: JiraIssue?], review: [String] = JiraConfig.defaultReview) {
        self.worklogs = worklogs; self.issues = issues; self.review = review
    }
}

public struct DayPlan: Codable, Sendable {
    public var day: String
    public var userSec: Double
    public var sessionSec: Double
    /// Your worklogs in Jira that day (nil: Jira not connected).
    public var jiraSec: Double?
    public var rows: [WorklogRow]
    public var tasks: [PlanTaskLine]
    /// Your time in sessions linked to no task, and keys seen in those sessions' branches or titles.
    public var unassignedSec: Double
    public var unknownKeys: [String]
    /// Seconds per task key that found no free time.
    public var unplaced: [String: Int]
    /// Differences against Jira and other things to look at.
    public var notes: [String]
    /// What `log commit` would write (`commitDigest(_:)` of `rows`): `log commit --expect` writes only if it is the same.
    public var commitDigest = ""
    // Since 0.1.5 (optional: a plan from 0.1.4 has none).
    /// The zone the day is cut in (`[worklog] tz`, else the database's).
    public var tz: String?
    /// When the day's texts were last built (nil: never).
    public var summaryBuiltAt: Double?
    /// Sessions of the rows with work in the day after `summaryBuiltAt` (all of them when never built).
    public var sessionsAfterSummary: Int?
    /// `[worklog] exclude` items and their time (in no row, no task line, not in `unassignedSec`).
    public var excluded: [ExcludedTime]?
    /// `unassignedSec` by the sessions' project ("—": time no session covered or a session without a project).
    public var unassigned: [ProjectTime]?

    /// FNV-1a 64 (hex) of `jira_key|start|end|seconds|text` lines (start, end: whole epoch seconds; text: what the
    /// worklog gets, `Worklog.comment`) of the planned rows with a Jira key in order of start, then a
    /// `comment|jira_key|summary` line per day summary that goes as an issue comment (`commentKeys`).
    public static func commitDigest(_ rows: [WorklogRow], withSummary: Bool = false, commentKeys: Set<String> = []) -> String {
        let planned = rows.filter { $0.state == "planned" && $0.jiraKey != nil }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let lines = planned.map {
            "\($0.jiraKey!)|\(Int64($0.start))|\(Int64($0.end))|\($0.seconds)|\(Worklog.comment($0, withSummary: withSummary, commentKeys: commentKeys))"
        }
            + Worklog.issueComments(planned, commentKeys: commentKeys).map { "comment|\($0.key)|\($0.text)" }
        return String(UInt64(bitPattern: fnv1a64(lines.joined(separator: "\n"))), radix: 16)
    }
}

public struct Worklog {
    public let store: Store
    var db: SQLite { store.db }
    public init(store: Store) { self.store = store }

    public func rows(day: String) throws -> [WorklogRow] {
        var out: [WorklogRow] = []
        try db.query("""
            SELECT w.id, w.day, w.task_id, t.key, t.jira_key, w.start, w."end", w.seconds, coalesce(w.text, ''), w.state, w.jira_worklog_id
            FROM worklog_plan w LEFT JOIN task t ON t.id = w.task_id WHERE w.day = ? ORDER BY w.start
            """, [.text(day)]) { r in
            out.append(WorklogRow(id: r.int(0), day: r.text(1) ?? "", taskId: r.optInt(2), taskKey: r.text(3), jiraKey: r.text(4),
                                  start: r.real(5), end: r.real(6), seconds: r.int(7), text: r.text(8) ?? "",
                                  state: r.text(9) ?? "planned", jiraWorklogId: r.text(10)))
        }
        return out
    }

    public func mark(_ id: Int, state: String, jiraWorklogId: String? = nil) throws {
        try db.run("UPDATE worklog_plan SET state = ?, jira_worklog_id = coalesce(?, jira_worklog_id) WHERE id = ?",
                   [.text(state), .of(jiraWorklogId), .int(Int64(id))])
    }

    /// Marks a planned row skipped; nil if there is no planned row with this id.
    public func skip(_ id: Int) throws -> WorklogRow? {
        guard let day = try db.one("SELECT day FROM worklog_plan WHERE id = ? AND state = 'planned'", [.int(Int64(id))], { $0.text(0) }),
              let day else { return nil }
        // Only while planned: a commit may have claimed it (`writing`) meanwhile.
        guard try db.run("UPDATE worklog_plan SET state = 'skipped' WHERE id = ? AND state = 'planned'", [.int(Int64(id))]) == 1 else { return nil }
        return try rows(day: day).first { $0.id == id }
    }

    /// Rebuilds the planned rows of `day` (logged and skipped rows stay and count as taken). Run the linker first.
    @discardableResult
    public func plan(day: String, idleGap: Double = 20 * 60, base: TaskTime.Base = .sessions, jira: JiraDay? = nil,
                     linker: TaskLinker? = nil, config: WorklogConfig = WorklogConfig()) throws -> DayPlan {
        guard let (from, to) = Time.dayBounds(day) else { throw TaskError("bad day \(day)") }
        let exclude = try exclusions(config)
        let report = try TaskTime.compute(store, from: from, to: to, idleGap: idleGap, base: base, exclude: exclude)
        let tasks = Tasks(store: store)
        var byId: [Int: TaskItem] = [:]
        for t in try tasks.list() { byId[t.id] = t }

        // What is in Jira counts as it is in Jira (also Zagon's own worklogs, even if moved there); logged rows whose
        // worklog Jira does not show (Jira not connected, or deleted there) and skipped rows count as local rows.
        let jiraLogs = jira?.worklogs ?? []
        let inJira = Set(jiraLogs.map(\.id))
        let local = try rows(day: day).filter { $0.state != "planned" && !($0.jiraWorklogId.map(inJira.contains) ?? false) }
        var already: [Int: Double] = [:]
        for r in local { if let t = r.taskId { already[t, default: 0] += Double(r.seconds) } }
        var jiraByKey: [String: Double] = [:]
        for w in jiraLogs where w.started >= from && w.started < to { jiraByKey[w.issueKey, default: 0] += Double(w.seconds) }
        for (id, t) in byId { if let k = t.jiraKey, let s = jiraByKey[k] { already[id, default: 0] += s } }
        let busy = local.map { Interval($0.start, $0.end) } + jiraLogs.map(\.interval)

        let stretches = report.slices.map { s in
            (interval: s.interval, shares: s.shares.compactMap { t, sec in
                t.map { WorklogPlanner.Share(task: $0, seconds: sec, first: s.first[$0] ?? s.interval.start) }
            })
        }
        let out = WorklogPlanner.plan(day: Interval(from, to), stretches: stretches, already: already, busy: busy)

        // A row that is planned again unchanged keeps its id (a plan shown earlier can still name it); new rows are
        // inserted before stale ones are deleted, so a deleted id is not handed to a different row right away.
        try db.transaction {
            var old: [Int: WorklogPlanner.Entry] = [:]
            try db.query("SELECT id, task_id, start, \"end\" FROM worklog_plan WHERE day = ? AND state = 'planned'", [.text(day)]) {
                old[$0.int(0)] = WorklogPlanner.Entry(task: $0.optInt(1) ?? -1, start: $0.real(2), end: $0.real(3))
            }
            for e in out.entries {
                if let id = old.first(where: { $0.value == e })?.key { old[id] = nil; continue }
                try db.run("INSERT INTO worklog_plan(day, task_id, start, \"end\", seconds, text, state) VALUES(?, ?, ?, ?, ?, '', 'planned')",
                           [.text(day), .int(Int64(e.task)), .real(e.start), .real(e.end), .int(Int64(e.seconds))])
            }
            for id in old.keys { try db.run("DELETE FROM worklog_plan WHERE id = ?", [.int(Int64(id))]) }
        }

        var lines: [PlanTaskLine] = []
        for (t, l) in report.lines where t != nil {
            let item = byId[t!]
            lines.append(PlanTaskLine(taskId: t, key: item?.key, title: item?.title, userSec: l.userSec, sessionSec: l.sessionSec,
                                      jiraSec: item?.jiraKey.flatMap { jiraByKey[$0] } ?? 0))
        }
        lines.sort { $0.userSec > $1.userSec }

        var notes: [String] = []
        if let jira {
            for l in lines where l.userSec >= WorklogPlanner.step {
                guard let item = l.taskId.flatMap({ byId[$0] }) else { continue }
                guard let k = item.jiraKey else { notes.append("\(item.key) is not in Jira: stays in Zagon"); continue }
                switch jira.issues[k] {
                case .some(.none): notes.append("\(item.key): issue \(k) not found in Jira")
                case .some(.some(let i)):
                    if item.status != TaskStatus(jira: i, review: jira.review) {
                        notes.append("\(item.key): status here \(item.status.rawValue), in Jira \"\(i.status)\"")
                    }
                case .none: break
                }
                if l.jiraSec == 0 { notes.append("\(item.key): work today, nothing logged in Jira yet") }
            }
        }
        let jiraSec = jira.map { j in j.worklogs.reduce(0.0) { $0 + max(0, min(to, $1.interval.end) - max(from, $1.interval.start)) } }
        if let j = jiraSec, j >= report.userSec, report.userSec > 0, !out.entries.isEmpty {
            func hm(_ s: Double) -> String { let m = Int(s / 60); return "\(m / 60)h \(m % 60 < 10 ? "0" : "")\(m % 60)m" }
            notes.append("Jira already has \(hm(j)) for the day, more than the \(hm(report.userSec)) worked: check before logging")
        }
        let unknown = try (linker ?? TaskLinker()).unknownKeys(store, from: from, to: to)
        var unplaced: [String: Int] = [:]
        for (t, s) in out.unplaced { unplaced[byId[t]?.key ?? "#\(t)"] = s }
        if !unplaced.isEmpty { notes.append("no free time left for " + unplaced.keys.sorted().joined(separator: ", ")) }
        var p = DayPlan(day: day, userSec: report.userSec,
                        sessionSec: report.lines.values.reduce(0) { $0 + $1.sessionSec },
                        jiraSec: jiraSec,
                        rows: try filled(day: day, config: config, exclude: exclude), tasks: lines,
                        unassignedSec: report.lines[nil]?.userSec ?? 0,
                        unknownKeys: unknown.keys.sorted(), unplaced: unplaced, notes: notes)
        p.tz = Settings.zoneName()
        let texts = WorklogTexts(store: store)
        p.summaryBuiltAt = try texts.builtAt(day)
        let mine = Set(p.rows.flatMap { $0.sessions?.map(\.id) ?? [] })
        p.sessionsAfterSummary = try sessions(from: max(from, p.summaryBuiltAt ?? from), to: to, exclude: exclude).intersection(mine).count
        p.excluded = config.exclude.enumerated().map { i, x in ExcludedTime(kind: x.kind, name: x.name, seconds: Int((report.excluded[i] ?? 0).rounded())) }
        var byProject: [String: Double] = [:]
        for (sid, sec) in report.noTask {
            let project = sid.isEmpty ? nil : try db.one("SELECT project FROM session WHERE id = ?", [.text(sid)]) { $0.text(0) } ?? nil
            byProject[project.flatMap { $0.isEmpty ? nil : $0 } ?? "—", default: 0] += sec
        }
        p.unassigned = byProject.map { ProjectTime(project: $0.key, seconds: Int($0.value.rounded())) }.filter { $0.seconds > 0 }
            .sorted { ($0.seconds, $1.project) > ($1.seconds, $0.project) }
        p.commitDigest = DayPlan.commitDigest(p.rows)
        return p
    }

    /// `[worklog] exclude` as sessions (a project's, or one by id with or without its `claude:` / `codex:` prefix) and
    /// tasks (key, Jira key or `#id`); an item that names nothing known excludes nothing.
    public func exclusions(_ c: WorklogConfig) throws -> TaskTime.Exclude {
        var items: [(sessions: Set<String>, tasks: Set<Int>)] = []
        for x in c.exclude {
            var ss = Set<String>(), ts = Set<Int>()
            switch x.kind {
            case "project":
                try db.query("SELECT id FROM session WHERE lower(project) = lower(?)", [.text(x.name)]) { if let i = $0.text(0) { ss.insert(i) } }
            case "session":
                try db.query("SELECT id FROM session WHERE id IN (?1, 'claude:' || ?1, 'codex:' || ?1)", [.text(x.name)]) { if let i = $0.text(0) { ss.insert(i) } }
            default:
                let ref = x.name.hasPrefix("#") ? String(x.name.dropFirst()) : x.name
                if let t = try Tasks(store: store).find(ref) { ts.insert(t.id) }
            }
            items.append((ss, ts))
        }
        return TaskTime.Exclude(items)
    }

    /// Sessions with working time in [from, to), excluded ones left out.
    func sessions(from: Timestamp, to: Timestamp, exclude: TaskTime.Exclude) throws -> Set<String> {
        var out = Set<String>()
        try db.query("SELECT DISTINCT session_id FROM activity WHERE kind = 'working' AND \"end\" > ? AND start < ?", [.real(from), .real(to)]) {
            if let s = $0.text(0) { out.insert(s) }
        }
        return out.subtracting(exclude.items.flatMap(\.sessions))
    }

    /// What the row's worklog gets: its text and, only `withSummary`, on its task's summary row the day summary
    /// unless that goes as an issue comment (`commentKeys`: Jira or task keys). Nothing goes to Jira unasked.
    public static func comment(_ r: WorklogRow, withSummary: Bool = false, commentKeys: Set<String> = []) -> String {
        guard withSummary, r.daySummary == true, let s = r.summary, !s.isEmpty, !asComment(r, commentKeys) else { return r.text }
        return r.text.isEmpty ? s : r.text + "\n\n" + s
    }

    /// Whether the task's day summary is in Jira: a comment written (`wlcomment:<day>:<key>` = `id:…`; one still
    /// `writing:` is offered again, `writeComments` then looks in Jira first), or the worklog that carries it
    /// (`wlsummary:<day>:<key>` = `worklog:<row id>`) is logged or may be (writing).
    static func summaryWritten(_ db: SQLite, day: String, key: String) throws -> Bool {
        if let v = try db.one("SELECT value FROM meta WHERE key = ?", [.text("wlcomment:\(day):\(key)")], { $0.text(0) }) ?? nil, v.hasPrefix("id:") { return true }
        guard let v = try db.one("SELECT value FROM meta WHERE key = ?", [.text("wlsummary:\(day):\(key)")], { $0.text(0) }) ?? nil,
              let row = Int64(v.dropFirst("worklog:".count)) else { return false }
        let state = try db.one("SELECT state FROM worklog_plan WHERE id = ?", [.int(row)], { $0.text(0) }) ?? nil
        return state == "logged" || state == "writing"
    }

    static func asComment(_ r: WorklogRow, _ keys: Set<String>) -> Bool {
        [r.jiraKey, r.taskKey].contains { $0.map { keys.contains($0.uppercased()) } ?? false }
    }

    /// Day summaries that go as an issue comment: one per Jira key, from its planned summary row.
    public static func issueComments(_ rows: [WorklogRow], commentKeys: Set<String>) -> [(key: String, task: Int?, text: String)] {
        rows.filter { $0.state == "planned" && $0.jiraKey != nil && $0.daySummary == true && !($0.summary ?? "").isEmpty && asComment($0, commentKeys) }
            .map { ($0.jiraKey!, $0.taskId, $0.summary!) }
    }

    /// The day's rows with their texts: each planned row's text (`WorklogTexts.rowText`, written to the row when it
    /// changed), its sessions and, on the longest planned row of each task (with `daySummary`), the task's summary.
    public func filled(day: String, config: WorklogConfig, exclude: TaskTime.Exclude = TaskTime.Exclude()) throws -> [WorklogRow] {
        guard let (from, to) = Time.dayBounds(day) else { throw TaskError("bad day \(day)") }
        var rs = try rows(day: day)
        let texts = WorklogTexts(store: store)
        var longest: [Int: Int] = [:]  // task -> index of its longest planned row
        for (i, r) in rs.enumerated() where r.state == "planned" {
            guard let t = r.taskId else { continue }
            if let j = longest[t], rs[j].seconds >= r.seconds { continue }
            longest[t] = i
        }
        let sessions = try rowSessions(rs, longest: Set(longest.values), from: from, to: to, exclude: exclude)
        var siblings: [Int: [Interval]] = [:]
        for r in rs where r.state == "planned" { if let t = r.taskId { siblings[t, default: []].append(Interval(r.start, r.end)) } }
        for i in rs.indices {
            guard let t = rs[i].taskId else { continue }
            guard rs[i].state == "planned" else { rs[i].daySummary = false; continue }
            let (text, source) = try texts.rowText(day: day, task: t, start: rs[i].start, end: rs[i].end, siblings: siblings[t] ?? []) {
                try titles(task: t, from: from, to: to, fallback: try Tasks(store: store).get(t)?.title ?? "")
            }
            if text != rs[i].text {
                try db.run("UPDATE worklog_plan SET text = ? WHERE id = ? AND state = 'planned'", [.text(text), .int(Int64(rs[i].id))])
                rs[i].text = text
            }
            rs[i].textSource = source
            rs[i].sessions = sessions[rs[i].id] ?? []
            // Once a day summary of the task is in Jira (a worklog or a comment), it is not offered again.
            let written = try Worklog.summaryWritten(db, day: day, key: rs[i].jiraKey ?? rs[i].taskKey ?? "#\(t)")
            rs[i].daySummary = config.daySummary && longest[t] == i && !written
            if rs[i].daySummary == true, let s = try texts.summary(day: day, task: t) { (rs[i].summary, rs[i].summarySource) = (s.text, s.source) }
        }
        return rs
    }

    /// Per planned row: the sessions linked to its task with their time inside the row (the day for summary rows, and
    /// for rows laid where none of them worked), at least a minute each, most first.
    func rowSessions(_ rs: [WorklogRow], longest: Set<Int>, from: Timestamp, to: Timestamp, exclude: TaskTime.Exclude) throws -> [Int: [RowSession]] {
        let tasks = Set(rs.compactMap(\.taskId))
        guard !tasks.isEmpty else { return [:] }
        let skip = Set(exclude.items.flatMap(\.sessions))
        var links: [Int: [String: [(how: String, iv: Interval)]]] = [:]
        try db.query("""
            SELECT task_id, session_id, how, start, "end" FROM task_session
            WHERE how NOT IN ('unlinked', 'suggested') AND start < ?2 AND "end" > ?1
            """, [.real(from), .real(to)]) { r in
            let t = r.int(0), sid = r.text(1) ?? ""
            guard tasks.contains(t), !skip.contains(sid) else { return }
            links[t, default: [:]][sid, default: []].append((r.text(2) ?? "", Interval(max(from, r.real(3)), min(to, r.real(4)))))
        }
        var working: [String: [Interval]] = [:], title: [String: String] = [:]
        for sid in Set(links.values.flatMap(\.keys)) {
            working[sid] = try TaskLinker.working(db, sid).compactMap { iv in
                let x = Interval(max(from, iv.start), min(to, iv.end)); return x.end > x.start ? x : nil
            }
            if let t = try db.one("SELECT title FROM session WHERE id = ?", [.text(sid)], { $0.text(0) }) ?? nil { title[sid] = t }
        }
        var leaders = Set<String>(), targets = Set<String>()
        try db.query("SELECT session_id, target FROM relay WHERE ts >= ? AND ts < ?", [.real(from), .real(to)]) { r in
            if let s = r.text(0) { leaders.insert(s) }
            if let t = r.text(1), !t.isEmpty { targets.insert(t.lowercased()) }
        }
        func seconds(_ sid: String, _ periods: [Interval], _ w: Interval) -> Double {
            let mine = Intervals.merge(periods.compactMap { p in
                let x = Interval(max(w.start, p.start), min(w.end, p.end)); return x.end > x.start ? x : nil
            })
            var s = 0.0
            for a in working[sid] ?? [] { for b in mine { s += max(0, min(a.end, b.end) - max(a.start, b.start)) } }
            return s
        }
        var out: [Int: [RowSession]] = [:]
        for (i, r) in rs.enumerated() where r.state == "planned" {
            guard let t = r.taskId, let byS = links[t] else { continue }
            func list(_ w: Interval) -> [RowSession] {
                byS.compactMap { sid, ps -> RowSession? in
                    let sec = seconds(sid, ps.map(\.iv), w)
                    guard sec >= 60 else { return nil }
                    let how = ps.filter { $0.iv.start < w.end && $0.iv.end > w.start }.map(\.how)
                        .max { (LinkHow(rawValue: $0)?.rank ?? 0) < (LinkHow(rawValue: $1)?.rank ?? 0) } ?? ps[0].how
                    let role = leaders.contains(sid) ? "leader"
                        : how == "brief" || title[sid].map({ targets.contains($0.lowercased()) }) == true ? "worker" : "single"
                    return RowSession(id: sid, title: title[sid], role: role, how: how, seconds: Int(sec.rounded()))
                }.sorted { ($0.seconds, $1.id) > ($1.seconds, $0.id) }
            }
            let own = longest.contains(i) ? [] : list(Interval(r.start, r.end))
            out[r.id] = own.isEmpty ? list(Interval(from, to)) : own
        }
        return out
    }

    /// The titles of the task's sessions that day, else `fallback` (the task's title).
    func titles(task: Int, from: Timestamp, to: Timestamp, fallback: String) throws -> String {
        var titles: [String] = []
        try db.query("""
            SELECT DISTINCT s.title FROM task_session ts JOIN session s ON s.id = ts.session_id
            WHERE ts.task_id = ?1 AND ts.how NOT IN ('unlinked', 'suggested') AND s.title IS NOT NULL AND s.last_at >= ?2
              AND coalesce(s.started_at, s.last_at) < ?3 AND ts.start + \(LinkHow.maxNudge) < ?3 AND ts."end" > ?2
            ORDER BY s.started_at
            """, [.int(Int64(task)), .real(from), .real(to)]) { if let t = $0.text(0), !titles.contains(t) { titles.append(t) } }
        let joined = titles.joined(separator: "; ")
        return joined.isEmpty ? fallback : String(joined.prefix(250))
    }
}
