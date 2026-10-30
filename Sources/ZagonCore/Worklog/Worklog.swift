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

    /// FNV-1a 64 (hex) of `jira_key|start|end|seconds|text` lines (start, end: whole epoch seconds) of the planned
    /// rows with a Jira key, in order of start.
    public static func commitDigest(_ rows: [WorklogRow]) -> String {
        let lines = rows.filter { $0.state == "planned" && $0.jiraKey != nil }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            .map { "\($0.jiraKey!)|\(Int64($0.start))|\(Int64($0.end))|\($0.seconds)|\($0.text)" }
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
        try mark(id, state: "skipped")
        return try rows(day: day).first { $0.id == id }
    }

    /// Rebuilds the planned rows of `day` (logged and skipped rows stay and count as taken). Run the linker first.
    @discardableResult
    public func plan(day: String, idleGap: Double = 20 * 60, base: TaskTime.Base = .sessions, jira: JiraDay? = nil,
                     linker: TaskLinker? = nil) throws -> DayPlan {
        guard let (from, to) = Time.dayBounds(day) else { throw TaskError("bad day \(day)") }
        let report = try TaskTime.compute(store, from: from, to: to, idleGap: idleGap, base: base)
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
                let text = try text(task: e.task, day: day, from: from, to: to, fallback: byId[e.task]?.title ?? "")
                if let id = old.first(where: { $0.value == e })?.key {
                    old[id] = nil
                    try db.run("UPDATE worklog_plan SET text = ? WHERE id = ?", [.text(text), .int(Int64(id))])
                } else {
                    try db.run("INSERT INTO worklog_plan(day, task_id, start, \"end\", seconds, text, state) VALUES(?, ?, ?, ?, ?, ?, 'planned')",
                               [.text(day), .int(Int64(e.task)), .real(e.start), .real(e.end), .int(Int64(e.seconds)), .text(text)])
                }
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
                        rows: try rows(day: day), tasks: lines, unassignedSec: report.lines[nil]?.userSec ?? 0,
                        unknownKeys: unknown.keys.sorted(), unplaced: unplaced, notes: notes)
        p.commitDigest = DayPlan.commitDigest(p.rows)
        return p
    }

    /// The day's "what was done" for the task (manual over auto), else the titles of its sessions that day.
    func text(task: Int, day: String, from: Timestamp, to: Timestamp, fallback: String) throws -> String {
        if let t = try db.one("SELECT text FROM task_done WHERE task_id = ? AND day = ? ORDER BY source = 'manual' DESC",
                              [.int(Int64(task)), .text(day)], { $0.text(0) }), let t, !t.isEmpty { return t }
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
