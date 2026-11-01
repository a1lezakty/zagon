/// What Zagon keeps of Jira between calls (`meta` key `jira:issues`): your issues (assigned to you: open, or updated in
/// the last 30 days), the Jira issues of the registry's tasks, and the issues with your worklogs of the last 7 days.
/// Jira is a reference here, not the task list: a key found in work (branch, title, typed message, commit) that is one
/// of these issues becomes a task (`TaskLinker`), the task list takes Jira statuses from it and shows the open ones
/// without work here apart. Refreshed by `task import` and, at most once an hour, by the task commands; Jira is only read.
public struct JiraCache: Sendable, Equatable {
    public var at: Timestamp = 0
    public var issues: [String: JiraIssue] = [:]
    /// Assigned to you (the other issues are registry tasks looked up by key).
    public var mine: Set<String> = []
    /// With your worklogs in the last 7 days.
    public var logged: Set<String> = []
    /// Keys of the projects you can browse: a key of another project (`BRIEF-2`) is no task (`TaskLinker`).
    public var projects: Set<String> = []
    /// `[jira] review_statuses` of the last read: how a task made from an issue here gets its status.
    public var review = JiraConfig.defaultReview
    public init() {}

    static let metaKey = "jira:issues"
    /// How long a read is used before the task commands read Jira again; a failed read is retried after `retry`.
    public static let ttl: Double = 3600, retry: Double = 600
    public static let mineJQL = "assignee = currentUser() AND (statusCategory != Done OR updated >= -30d) ORDER BY updated DESC"

    public static func load(_ store: Store) -> JiraCache { stored(store).cache }

    /// `legacy`: a read from before the project list (0.1.4).
    static func stored(_ store: Store) -> (cache: JiraCache, tried: Timestamp, legacy: Bool) {
        guard let raw = try? store.db.one("SELECT value FROM meta WHERE key = ?", [.text(metaKey)], { $0.text(0) }), let text = raw,
              let v = JValue.parse(text) else { return (JiraCache(), 0, false) }
        var c = JiraCache()
        c.at = v["at"]?.double ?? 0
        if case .object(let m)? = v["issues"] {
            for x in m {
                c.issues[x.key] = JiraIssue(key: x.key, summary: x.value["s"]?.string ?? "", status: x.value["st"]?.string ?? "",
                                            statusCategory: x.value["c"]?.string ?? "")
            }
        }
        c.mine = Set(v["mine"]?.array?.compactMap(\.string) ?? [])
        c.logged = Set(v["logged"]?.array?.compactMap(\.string) ?? [])
        c.projects = Set(v["projects"]?.array?.compactMap(\.string) ?? [])
        if let r = v["review"]?.array?.compactMap(\.string) { c.review = r }
        return (c, v["tried"]?.double ?? c.at, v["projects"] == nil && c.at > 0)
    }

    func save(_ store: Store, tried: Timestamp) throws {
        let v = JValue.object([
            .init("at", .number("\(at)")), .init("tried", .number("\(tried)")),
            .init("issues", .object(issues.values.sorted { $0.key < $1.key }.map {
                .init($0.key, .object([.init("s", .string($0.summary)), .init("st", .string($0.status)), .init("c", .string($0.statusCategory))]))
            })),
            .init("mine", .array(mine.sorted().map(JValue.string))), .init("logged", .array(logged.sorted().map(JValue.string))),
            .init("projects", .array(projects.sorted().map(JValue.string))),
            .init("review", .array(review.map(JValue.string))),
        ])
        try store.db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2",
                         [.text(Self.metaKey), .text(v.compact)])
    }

    /// Reads Jira and keeps the result. A task whose Jira status changed since the last read takes it as its status
    /// here (`TaskStatus(jira:)`); read for the first time, only if its status is `planned` (the default) or what its
    /// status category gives (as an import set it). A status set here by hand stays until Jira's changes.
    @discardableResult
    public static func refresh(_ store: Store, _ jira: JiraClient, jql: String = mineJQL, now: Timestamp = Time.now()) throws -> JiraCache {
        let old = stored(store).cache, tasks = Tasks(store: store)
        var c = JiraCache()
        c.at = now; c.review = jira.config.reviewStatuses
        for i in try jira.search(jql) { c.issues[i.key] = i; c.mine.insert(i.key) }
        let rest = try tasks.list().compactMap(\.jiraKey).filter { c.issues[$0] == nil }
        for i in stride(from: 0, to: rest.count, by: 100) {
            let chunk = rest[i..<min(i + 100, rest.count)]
            // Jira skips keys it does not show; should it refuse the query, those tasks keep their last read.
            do { for x in try jira.search("key in (\(chunk.joined(separator: ", ")))") { c.issues[x.key] = x } }
            catch { for k in chunk { c.issues[k] = old.issues[k] } }
        }
        // Your worklogs only: the search also finds issues where you logged long ago and someone else this week.
        c.logged = Set(try jira.myWorklogs(from: now - 7 * 86400, to: now).map(\.issueKey))
        // Projects change rarely: a failed read keeps the last one.
        c.projects = (try? Set(jira.projects(action: nil).map(\.key))) ?? old.projects
        try store.db.transaction {
            for t in try tasks.list() {
                guard let k = t.jiraKey, let i = c.issues[k], old.issues[k]?.status != i.status else { continue }
                if old.issues[k] == nil, t.status != .planned, t.status != TaskStatus(jiraCategory: i.statusCategory) { continue }
                let s = TaskStatus(jira: i, review: c.review)
                if s != t.status { try tasks.setStatus(t.id, s, at: now) }
            }
            try c.save(store, tried: now)
        }
        return c
    }

    /// The cache, read again from Jira first when older than `ttl` (and no read failed in the last `retry`); a failure
    /// is logged and the last read is used.
    public static func current(_ store: Store, _ jira: JiraClient?, now: Timestamp = Time.now(),
                               log: (String) -> Void = { _ in }) -> JiraCache {
        let (c, tried, legacy) = stored(store)
        // A read from before the project list (0.1.4) is read again now: until then every key counts.
        let failedLately = tried > c.at && now - tried < retry
        guard let jira, now - c.at >= ttl || legacy, !failedLately else { return c }
        do { return try refresh(store, jira, now: now) } catch {
            log("jira: \(error)")
            // Only the time of the try: a read another process saved meanwhile stays.
            _ = try? store.db.run("UPDATE meta SET value = json_set(value, '$.tried', ?) WHERE key = ?", [.real(now), .text(metaKey)])
            if tried == 0 && c.at == 0 { try? c.save(store, tried: now) }
            return c
        }
    }
}
