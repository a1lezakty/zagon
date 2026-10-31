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

    public init(store: Store, linker: TaskLinker, jira: JiraClient?, jiraSetupError: String? = nil, idleGap: Double = 20 * 60,
                base: TaskTime.Base = .sessions) {
        self.store = store; self.linker = linker; self.jira = jira; self.jiraSetupError = jiraSetupError
        self.idleGap = idleGap; self.base = base
    }

    /// Links the day's sessions (branch, title, messages, commits), reads the day from Jira and rebuilds the plan.
    /// `JiraCache` is read again first when older than an hour.
    /// Without `strict` a Jira failure comes back as `jiraError` and the plan is made without Jira.
    public func plan(_ day: String, strict: Bool = false) throws -> (plan: DayPlan, jiraError: String?) {
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
        var p = try Worklog(store: store).plan(day: day, idleGap: idleGap, base: base, jira: jiraDay, linker: linker)
        p.notes += settled
        return (p, jiraError)
    }

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
    public func write(_ rows: [WorklogRow], day: String, now: Timestamp = Time.now()) throws -> WriteResult {
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
            do { id = try jira.addWorklog(issue: key, started: row.start, seconds: row.seconds, comment: row.text) }
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
        return r
    }
}
