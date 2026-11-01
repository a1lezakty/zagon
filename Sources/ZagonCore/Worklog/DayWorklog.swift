/// Plan and write one day's worklogs with linking and (optional) Jira. Shared by `zagon log`, MCP and the bot.
public struct DayWorklog {
    public let store: Store
    public var linker: TaskLinker
    public var jira: JiraClient?
    /// Why Jira is not available although configured (unreadable token file, bad url); nil = fine or not configured.
    public var jiraSetupError: String?
    public var idleGap: Double
    public var base: TaskTime.Base
    /// `[worklog] reconcile_tolerance_min`: a task's day where sessions and worklogs differ by more is a mismatch.
    public var reconcileToleranceMin = Reconcile.defaultToleranceMin
    /// `[worklog]`: zone, projects, day summary, exclusions. The caller cuts days in `config.tz` (`Settings.inZone`).
    public var config = WorklogConfig()
    /// Builds the rows' texts with an AI (nil: no engine set up here; the plan keeps the texts it has).
    public var texts: WorklogTextBuilder?

    public init(store: Store, linker: TaskLinker, jira: JiraClient?, jiraSetupError: String? = nil, idleGap: Double = 20 * 60,
                base: TaskTime.Base = .sessions) {
        self.store = store; self.linker = linker; self.jira = jira; self.jiraSetupError = jiraSetupError
        self.idleGap = idleGap; self.base = base
    }

    /// Links the day's sessions (branch, title, messages, commits), reads the day from Jira and rebuilds the plan.
    /// `JiraCache` is read again first when older than an hour.
    /// Without `strict` a Jira failure comes back as `jiraError` and the plan is made without Jira.
    /// With `refresh` the day's texts are built again (one AI call) when they never were or a session worked after.
    public func plan(_ day: String, strict: Bool = false, refresh: Bool = false, now: Timestamp = Time.now()) throws -> (plan: DayPlan, jiraError: String?) {
        guard let (from, to) = Time.dayBounds(day) else { throw TaskError("bad day \(day)") }
        _ = JiraCache.current(store, jira)  // your Jira issues found in the day's work become tasks
        try linker.linkSessions(store)
        try linker.linkDay(store, from: from, to: to)
        var jiraDay: JiraDay?, jiraError = jiraSetupError
        if jiraSetupError != nil, strict { throw TaskError("Jira: \(jiraSetupError!)") }
        do { jiraDay = try fetchJira(from: from, to: to) } catch {
            if strict { throw error }
            jiraError = "\(error)"
        }
        // Rows an earlier write left `writing` are settled first, so their time counts as it is in Jira.
        var settled: [String] = []
        if jira != nil {
            do { settled = try settle(day) } catch { if strict { throw error }; jiraError = jiraError ?? "\(error)" }
        }
        let wl = Worklog(store: store)
        var p = try wl.plan(day: day, idleGap: idleGap, base: base, jira: jiraDay, linker: linker, config: config)
        p.notes += settled
        if refresh, p.summaryBuiltAt == nil || (p.sessionsAfterSummary ?? 0) > 0 {
            if try buildTexts(day, p, now: now) {
                p.rows = try wl.filled(day: day, config: config, exclude: try wl.exclusions(config))
                p.summaryBuiltAt = try WorklogTexts(store: store).builtAt(day)
                p.sessionsAfterSummary = 0
                p.commitDigest = DayPlan.commitDigest(p.rows)
            } else { p.notes.append("texts not rebuilt: " + (texts == nil ? "no AI engine" : texts!.engine.failure.reason ?? "the engine gave no texts")) }
        }
        return (p, jiraError)
    }

    /// The plan's rows by task, as the text builder takes them (planned rows with a task).
    func textInputs(_ p: DayPlan) throws -> [WorklogTextBuilder.TaskInput] {
        let tasks = Tasks(store: store)
        var out: [WorklogTextBuilder.TaskInput] = []
        for r in p.rows where r.state == "planned" {
            guard let t = r.taskId else { continue }
            let row = WorklogTextBuilder.RowInput(id: r.id, task: t, start: r.start, end: r.end, sessions: r.sessions ?? [])
            if let i = out.firstIndex(where: { $0.id == t }) { out[i].rows.append(row); continue }
            let item = try tasks.get(t)
            out.append(.init(id: t, key: r.jiraKey ?? r.taskKey ?? "#\(t)", title: item?.title ?? "", rows: [row]))
        }
        return out
    }

    /// Builds the day's texts (one AI call); false when there is no engine, nothing to write about or it failed.
    @discardableResult
    public func buildTexts(_ day: String, _ p: DayPlan, now: Timestamp = Time.now()) throws -> Bool {
        guard let texts else { return false }
        let inputs = try textInputs(p)
        guard !inputs.isEmpty else { return false }
        return try texts.build(day: day, tasks: inputs, summaries: config.daySummary, now: now) != nil
    }

    /// One planned row's text again (`summary`: its task's day summary) with one AI call; `shorten` shortens the text it
    /// has. A rebuilt text replaces one set by hand; a shortened one keeps its source. Returns the row as planned now.
    public func rebuildText(row id: Int, day: String, summary: Bool, shorten: Bool) throws -> WorklogRow {
        guard let texts else { throw TaskError("no AI engine for texts ([summary] engine in config.toml)") }
        let wl = Worklog(store: store)
        let rows = try wl.filled(day: day, config: config, exclude: try wl.exclusions(config))
        guard let r = rows.first(where: { $0.id == id }), r.state == "planned", let t = r.taskId else { throw TaskError("no planned row #\(id) on \(day)") }
        if summary, r.daySummary != true { throw TaskError("row #\(id) does not carry its task's day summary") }
        let plan = DayPlan(day: day, userSec: 0, sessionSec: 0, jiraSec: nil, rows: rows, tasks: [], unassignedSec: 0, unknownKeys: [],
                           unplaced: [:], notes: [])
        guard let task = try textInputs(plan).first(where: { $0.id == t }), let row = task.rows.first(where: { $0.id == id }) else {
            throw TaskError("no planned row #\(id) on \(day)")
        }
        let current = shorten ? (summary ? r.summary : r.text) : nil
        if shorten, (current ?? "").isEmpty { throw TaskError("row #\(id) has no text to shorten") }
        guard let text = try texts.rebuild(day: day, task: task, row: row, summary: summary, shorten: current) else {
            throw TaskError("no text: " + (texts.engine.failure.reason ?? "the engine gave nothing usable"))
        }
        let kept = WorklogTexts(store: store)
        let manual = shorten && (summary ? r.summarySource : r.textSource) == "manual"
        if summary {
            if manual { try kept.setManualSummary(day: day, task: t, text: text) }
            else { try kept.setManualSummary(day: day, task: t, text: nil); try kept.put(WorklogTexts.sumKey("auto", day, t), text) }
        } else if manual { try kept.setManual(day: day, task: t, start: r.start, text: text) }
        else {
            try kept.put(WorklogTexts.rowKey("manual", day, t, r.start), nil)
            try kept.put(WorklogTexts.rowKey("auto", day, t, r.start), text)
        }
        return try wl.filled(day: day, config: config, exclude: try wl.exclusions(config)).first { $0.id == id }!
    }

    /// Sets a planned row's text (or with `summary` its task's day summary) by hand; nil or "" goes back to the built one.
    public func setText(row id: Int, day: String, summary: Bool, text: String?) throws -> WorklogRow {
        let wl = Worklog(store: store)
        let rows = try wl.filled(day: day, config: config, exclude: try wl.exclusions(config))
        guard let r = rows.first(where: { $0.id == id }), r.state == "planned", let t = r.taskId else { throw TaskError("no planned row #\(id) on \(day)") }
        if summary {
            guard r.daySummary == true else { throw TaskError("row #\(id) does not carry its task's day summary") }
            try WorklogTexts(store: store).setManualSummary(day: day, task: t, text: text)
        } else { try WorklogTexts(store: store).setManual(day: day, task: t, start: r.start, text: text) }
        return try wl.filled(day: day, config: config, exclude: try wl.exclusions(config)).first { $0.id == id }!
    }

    var db: SQLite { store.db }

    /// A row's claim older than this has no write in flight (curl gives up after 60 s).
    static let claimTimeout: Double = 5 * 60

    /// Rows left `writing` whose answer never came (a lost reply, a crash, a failed local update): the issue's own
    /// worklog list (read directly, unlike the search index, which lags) says whether Jira has one with the same
    /// start and length; then the row is logged with it. Without one and with a claim older than `claimTimeout` it is
    /// planned again; a newer claim may still be in flight and stays. An issue Jira no longer shows (404) has no such
    /// worklog; another failure leaves that row for the next time. Returns a line per settled (or unchecked) row.
    @discardableResult
    public func settle(_ day: String, now: Timestamp = Time.now()) throws -> [String] {
        guard let jira, let (from, _) = Time.dayBounds(day) else { return [] }
        let wl = Worklog(store: store)
        let open = try wl.rows(day: day).filter { $0.state == "writing" && $0.jiraKey != nil }
        guard !open.isEmpty else { return [] }
        let me = try jira.accountId()
        var mine: [String: [JiraWorklog]] = [:], out: [String] = []
        for row in open {
            let key = row.jiraKey!, span = "#\(row.id) \(key) \(Txt.clock(row.start))–\(Txt.clock(row.end))"
            do {
                if mine[key] == nil { mine[key] = try issueWorklogs(key, from: from, me: me) }
                if let w = mine[key]!.first(where: { Self.same($0, row) }) {
                    try wl.mark(row.id, state: "logged", jiraWorklogId: w.id)
                    try dropClaim(row.id)
                    out.append("\(span) is in Jira: marked logged")
                    continue
                }
                // Planned again only if the claim read is still the claim (another writer may have claimed it since).
                let claim = try claimedAt(row.id)
                guard now - (claim ?? 0) > Self.claimTimeout else { continue }
                let done = try store.db.transaction { () throws -> Bool in
                    guard try claimedAt(row.id) == claim,
                          try store.db.run("UPDATE worklog_plan SET state = 'planned' WHERE id = ? AND state = 'writing'", [.int(Int64(row.id))]) == 1
                    else { return false }
                    try dropClaim(row.id)
                    return true
                }
                if done { out.append("\(span) did not reach Jira: planned again") }
            } catch { out.append("\(span) not checked (\(error)): still writing") }
        }
        return out
    }

    /// Your worklogs on the issue, read directly; an issue Jira does not show (404) has none.
    func issueWorklogs(_ key: String, from: Timestamp, me: String) throws -> [JiraWorklog] {
        guard let jira else { return [] }
        do { return try jira.worklogs(issue: key, startedAfter: from - 86400).filter { $0.accountId == me } }
        catch JiraError.http(404, _) { return [] }
    }

    /// The Jira worklog this row would write: same start (to the second) and length.
    static func same(_ w: JiraWorklog, _ row: WorklogRow) -> Bool {
        Int64(w.started.rounded()) == Int64(row.start.rounded()) && w.seconds == row.seconds
    }

    func claimedAt(_ id: Int) throws -> Timestamp? {
        try store.db.one("SELECT value FROM meta WHERE key = ?", [.text("worklog:claim:\(id)")]) { $0.optReal(0) } ?? nil
    }

    func dropClaim(_ id: Int) throws { try store.db.run("DELETE FROM meta WHERE key = ?", [.text("worklog:claim:\(id)")]) }

    func fetchJira(from: Timestamp, to: Timestamp) throws -> JiraDay? {
        guard let jira else { return nil }
        _ = try jira.accountId()  // a bad token fails here, not as "issue not found" below
        var keys = Set<String>()
        try store.db.query("""
            SELECT DISTINCT t.jira_key FROM task t JOIN task_session ts ON ts.task_id = t.id JOIN session s ON s.id = ts.session_id
            WHERE t.jira_key IS NOT NULL AND ts.how NOT IN ('unlinked', 'suggested') AND s.last_at >= ?1 AND coalesce(s.started_at, s.last_at) < ?2
              AND ts.start + \(LinkHow.maxNudge) < ?2 AND ts."end" > ?1
            """, [.real(from), .real(to)]) { if let k = $0.text(0) { keys.insert(k) } }
        var issues: [String: JiraIssue?] = [:]
        for k in keys { issues[k] = .some(try jira.issue(k)) }
        return JiraDay(worklogs: try jira.myWorklogs(from: from, to: to), issues: issues, review: jira.config.reviewStatuses)
    }

    public struct WriteResult: Sendable {
        public var lines: [String] = []
        public var logged = 0, failed = 0
    }

    /// Writes planned rows that have a Jira key — call it only on an explicit command. Rows left `writing` are
    /// settled first; then each row is checked against the issue's own worklog list (direct, not the lagging search):
    /// the same worklog there means it was written before (logged, no second POST), an overlap means it is not
    /// written. A refused or unsent POST puts the row back to planned; a POST that may have reached Jira (timeout,
    /// lost reply, 5xx) or a failed local update leaves it `writing` for the next settle. One failed row does not stop
    /// the others.
    /// `now` is for settling only; a claim records the moment it is made.
    /// A row's worklog gets `Worklog.comment`: its text, on its task's summary row also the day summary, unless the
    /// task is in `commentKeys`: then the summary goes as one comment on the issue (`writeComments`).
    public func write(_ rows: [WorklogRow], day: String, commentKeys: Set<String> = [], now: Timestamp = Time.now()) throws -> WriteResult {
        guard let jira else { throw TaskError("Jira is not connected" + (jiraSetupError.map { ": \($0)" } ?? " ([jira] in config.toml)")) }
        guard let (from, to) = Time.dayBounds(day) else { throw TaskError("bad day \(day)") }
        var r = WriteResult()
        r.lines = try settle(day, now: now)
        let me = try jira.accountId()
        var taken = try jira.myWorklogs(from: from, to: to).map(\.interval)
        var mine: [String: [JiraWorklog]] = [:]
        let wl = Worklog(store: store)
        for row in rows where row.state == "planned" {
            guard let key = row.jiraKey else { continue }
            let span = "#\(row.id) \(key) \(Txt.clock(row.start))–\(Txt.clock(row.end))"
            let iv = Interval(row.start, row.end)
            // Never POST without having read the issue: a failed read or mark fails this row only.
            do {
                if mine[key] == nil { mine[key] = try jira.worklogs(issue: key, startedAfter: from - 86400).filter { $0.accountId == me } }
                if let w = mine[key]!.first(where: { Self.same($0, row) }) {
                    try wl.mark(row.id, state: "logged", jiraWorklogId: w.id)
                    r.lines.append("already in Jira \(span): marked logged"); r.logged += 1
                    continue
                }
            } catch {
                r.lines.append("not logged \(span): \(error)"); r.failed += 1
                continue
            }
            if (taken + mine[key]!.map(\.interval)).contains(where: { $0.start < iv.end && $0.end > iv.start }) {
                r.lines.append("not logged \(span): overlaps a worklog now in Jira"); r.failed += 1
                continue
            }
            // Claim the row first: a second writer (CLI, MCP, bot at once) finds it taken; a re-plan meanwhile keeps it.
            let claimed = try store.db.transaction { () throws -> Bool in
                guard try store.db.run("UPDATE worklog_plan SET state = 'writing' WHERE id = ? AND state = 'planned'", [.int(Int64(row.id))]) == 1
                else { return false }
                try store.db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2",
                                 [.text("worklog:claim:\(row.id)"), .real(Time.now())])
                return true
            }
            guard claimed else {
                r.lines.append("not logged \(span): already being written or logged"); r.failed += 1
                continue
            }
            let id: String
            do { id = try jira.addWorklog(issue: key, started: row.start, seconds: row.seconds, comment: Worklog.comment(row, commentKeys: commentKeys)) }
            catch let e as JiraError where !e.mayHaveArrived {
                try? wl.mark(row.id, state: "planned"); try? dropClaim(row.id)
                r.lines.append("not logged \(span): \(e)"); r.failed += 1
                continue
            } catch {
                // Also an answer that does not decode after a 2xx: the worklog may well exist.
                taken.append(iv); r.failed += 1
                r.lines.append("not sure \(span) reached Jira (\(error)): left writing, the next plan or commit checks Jira first")
                continue
            }
            taken.append(iv); r.logged += 1
            do {
                try wl.mark(row.id, state: "logged", jiraWorklogId: id)
                try dropClaim(row.id)
                r.lines.append("logged \(span) \(Txt.dur(Double(row.seconds)))")
            } catch {
                r.lines.append("logged \(span) in Jira, but not marked here (\(error)): the next plan or commit marks it")
            }
        }
        let c = try writeComments(Worklog.issueComments(rows, commentKeys: commentKeys), day: day)
        r.lines += c.lines; r.logged += c.logged; r.failed += c.failed
        return r
    }

    /// Writes each day summary as one comment on its issue, once per issue and day: a comment of yours that starts with
    /// the day's header (`WorklogTexts.commentHeader`) means it is there (lost reply, another writer); meta
    /// `wlcomment:<day>:<key>` holds `writing:<time>` while a POST is out and `id:<id>` after. A claim older than
    /// `claimTimeout` with no such comment in Jira is taken over.
    func writeComments(_ cs: [(key: String, task: Int?, text: String)], day: String) throws -> WriteResult {
        var r = WriteResult()
        guard let jira, !cs.isEmpty else { return r }
        let w = texts.map { $0.engine.config.lang.words() } ?? NotifyLang.auto.words()
        for c in cs {
            let mark = "wlcomment:\(day):\(c.key)", what = "day summary on \(c.key)"
            do {
                if let v = try db.one("SELECT value FROM meta WHERE key = ?", [.text(mark)], { $0.text(0) }) ?? nil, v.hasPrefix("id:") {
                    r.lines.append("\(what) already commented"); continue
                }
                if let had = try jira.myComments(issue: c.key).first(where: { WorklogTexts.isCommentOf($0.body, day: day) }) {
                    try db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2", [.text(mark), .text("id:" + had.id)])
                    r.lines.append("\(what) is in Jira: marked"); r.logged += 1; continue
                }
            } catch { r.lines.append("\(what) not written: \(error)"); r.failed += 1; continue }
            let claimed = try db.transaction { () throws -> Bool in
                if let v = try db.one("SELECT value FROM meta WHERE key = ?", [.text(mark)], { $0.text(0) }) ?? nil {
                    guard v.hasPrefix("writing:"), let at = Double(v.dropFirst(8)), Time.now() - at > Self.claimTimeout else { return false }
                }
                try db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2", [.text(mark), .text("writing:\(Time.now())")])
                return true
            }
            guard claimed else { r.lines.append("\(what) not written: already being written"); r.failed += 1; continue }
            do {
                let id = try jira.addComment(issue: c.key, body: WorklogTexts.commentHeader(day, w) + "\n\n" + c.text)
                try? db.run("UPDATE meta SET value = ? WHERE key = ?", [.text("id:" + id), .text(mark)])
                r.lines.append("commented \(what)"); r.logged += 1
            } catch let e as JiraError where !e.mayHaveArrived {
                try? db.run("DELETE FROM meta WHERE key = ?", [.text(mark)])
                r.lines.append("\(what) not written: \(e)"); r.failed += 1
            } catch {
                r.lines.append("not sure \(what) reached Jira (\(error)): the next commit checks Jira first"); r.failed += 1
            }
        }
        return r
    }
}
