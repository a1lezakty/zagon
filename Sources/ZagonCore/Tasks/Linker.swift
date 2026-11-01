/// Links sessions to tasks by keys (`PROJ-123`), each for the time the key is about: a session title for the whole
/// session; a branch, a commit or a typed key only for the session's working intervals (sub-agents included) next to
/// it, found by the folder each interval was worked in. A key that is not a task yet but one of your Jira issues
/// (`JiraCache.mine`) becomes a task here as its work is linked; keys of other unknown tasks come back from
/// `unknownKeys` so the plan can suggest adding them.
public struct TaskLinker {
    public static let defaultPattern = #"[A-Z][A-Z0-9]+-\d+"#
    /// A commit's keys take its repository's working time since the previous commit, at most this far back.
    public static let commitReach: Double = 2 * 3600
    /// ...and after the day's last commit in the repository, this much more.
    public static let afterCommit: Double = 30 * 60
    let patterns: [Regex<AnyRegexOutput>]
    /// A pause longer than this ends the reach of a typed key (as for your time).
    public var idleGap: Double
    /// Jira projects keys may belong to besides those read from Jira (`JiraCache.projects`), e.g. `[worklog] projects`.
    public var projects: Set<String> = []

    /// `[tasks] key_pattern` and `[worklog] projects` of config.toml: every linker of a process links alike.
    public static func load(configText t: String) throws -> TaskLinker {
        var l = try TaskLinker(patterns: [TOMLLite.string(in: t, section: "tasks", key: "key_pattern") ?? defaultPattern])
        l.projects = Set(WorklogConfig.load(configText: t).projects)
        return l
    }

    public init(patterns: [String] = [TaskLinker.defaultPattern], idleGap: Double = 20 * 60) throws {
        self.patterns = try patterns.map { try Regex($0) }
        self.idleGap = idleGap
    }

    /// Distinct keys in `s`, in order of appearance; a match glued to a letter or digit before it (`fooPROJ-1`) is not a key.
    public func keys(in s: String) -> [String] {
        var out: [String] = []
        for p in patterns {
            for m in s.matches(of: p) {
                if m.range.lowerBound > s.startIndex, s[s.index(before: m.range.lowerBound)].isLetter || s[s.index(before: m.range.lowerBound)].isNumber { continue }
                // Keys are stored upper-case: a case-insensitive pattern (`(?i)…`) still finds `proj-123` branches.
                let k = s[m.range].uppercased()
                if !out.contains(k) { out.append(k) }
            }
        }
        return out
    }

    /// Projects a key may belong to (the text before its last `-`): Jira's (`JiraCache.projects`), `projects` and
    /// those of the registry's tasks; nil (every match counts) when neither Jira's nor `projects` are known (no Jira).
    /// Keeps `BRIEF-2`, `EN-150` and the like out.
    func knownProjects(jira: Set<String>, registry: [String: [Int]]) -> Set<String>? {
        guard !jira.isEmpty || !projects.isEmpty else { return nil }
        return jira.union(projects.map { $0.uppercased() }).union(registry.keys.compactMap(Self.project))
    }
    static func project(_ key: String) -> String? { key.lastIndex(of: "-").map { String(key[..<$0]) } }
    static func allowed(_ key: String, _ projects: Set<String>?) -> Bool {
        guard let projects, let p = project(key) else { return true }
        return projects.contains(p)
    }

    /// Task ids by key and Jira key.
    func index(_ store: Store) throws -> [String: [Int]] {
        var ix: [String: [Int]] = [:]
        try store.db.query("SELECT id, key, jira_key FROM task") { r in
            for k in Set([r.text(1), r.text(2)].compactMap { $0 }) { ix[k, default: []].append(r.int(0)) }
        }
        return ix
    }

    /// Task ids by key; a key that is one of your Jira issues and no task yet becomes a task when work asks for it.
    final class Known {
        var ids: [String: [Int]]
        let cache: JiraCache, tasks: Tasks, projects: Set<String>?
        init(_ store: Store, _ linker: TaskLinker) throws {
            ids = try linker.index(store); cache = JiraCache.load(store); tasks = Tasks(store: store)
            projects = linker.knownProjects(jira: cache.projects, registry: ids)
        }
        var isEmpty: Bool { ids.isEmpty && cache.mine.isEmpty }
        func callAsFunction(_ k: String) throws -> [Int]? {
            // Your issues (`JiraCache`) always count: the project list is cut at 1000.
            guard TaskLinker.allowed(k, projects) || cache.issues[k] != nil else { return nil }
            if let v = ids[k] { return v }
            guard cache.mine.contains(k), let i = cache.issues[k] else { return nil }
            let t = try tasks.add(title: i.summary.isEmpty ? k : i.summary, key: k, status: TaskStatus(jira: i, review: cache.review))
            ids[k] = [t.id]
            return [t.id]
        }
    }

    /// Working intervals of a session (all its files), merged; with `cwd`, only those worked in that folder
    /// (an interval of unknown folder counts as the session's folder).
    static func working(_ db: SQLite, _ session: String, cwd: String?? = nil) throws -> [Interval] {
        var out: [Interval] = []
        try db.query("""
            SELECT a.start, a."end", coalesce(a.cwd, s.cwd) FROM activity a LEFT JOIN session s ON s.id = a.session_id
            WHERE a.session_id = ? AND a.kind = 'working'
            """, [.text(session)]) { r in
            if case .some(let want) = cwd, r.text(2) != want { return }
            out.append(Interval(r.real(0), r.real(1)))
        }
        return Intervals.merge(out)
    }

    /// Links that need no git, rebuilt from scratch: session titles (whole session); the branch the agent recorded
    /// (the intervals in the session's folder); keys typed in messages and in the titles of briefs they point to (from
    /// the message on while the session keeps working without a pause longer than `idleGap`, until a message with other
    /// keys; a brief's as `brief`). Returns links written.
    @discardableResult
    public func linkSessions(_ store: Store) throws -> Int {
        let db = store.db, tasks = Tasks(store: store), ix = try Known(store, self)
        var n = 0
        try db.transaction {
            // Whole-session commit links are what the v3 migration left; new ones always have a period.
            try db.run("DELETE FROM task_session WHERE how IN ('title', 'branch', 'message', 'brief') OR (how IN ('commit', 'worktree') AND start = 0)")
            guard !ix.isEmpty else { return }
            var rows: [(id: String, branch: String?, title: String?, cwd: String?)] = []
            try db.query("SELECT id, git_branch, title, cwd FROM session") { rows.append(($0.text(0) ?? "", $0.text(1), $0.text(2), $0.text(3))) }
            for s in rows {
                for k in s.title.map(keys) ?? [] { for t in try ix(k) ?? [] { try tasks.link(t, session: s.id, how: .title); n += 1 } }
                let bk = try (s.branch.map(keys) ?? []).filter { try ix($0) != nil }
                if !bk.isEmpty {
                    for iv in try Self.working(db, s.id, cwd: .some(s.cwd)) {
                        for k in bk { for t in try ix(k)! { try tasks.link(t, session: s.id, how: .branch, start: iv.start, end: iv.end); n += 1 } }
                    }
                }
            }
            // Typed keys: session -> (time, keys) in time order; keys of a brief the message points to are in `brief`.
            var typed: [String: [(at: Timestamp, keys: Set<String>)]] = [:], brief = Set<String>()
            try db.query("SELECT session_id, at, key, how FROM task_key ORDER BY session_id, at") { r in
                let sid = r.text(0) ?? "", at = r.real(1), k = r.text(2) ?? ""
                if r.text(3) == LinkHow.brief.rawValue { brief.insert("\(sid) \(at) \(k)") }
                if var list = typed[sid], let last = list.last, last.at == at {
                    list[list.count - 1].keys.insert(k); typed[sid] = list
                } else { typed[sid, default: []].append((at, [k])) }
            }
            for (sid, msgs) in typed {
                let known = try msgs.map { (at: $0.at, keys: try $0.keys.filter { try ix($0) != nil }) }
                guard known.contains(where: { !$0.keys.isEmpty }) else { continue }
                let ivs = try Self.working(db, sid)
                var end = -Double.infinity
                for (i, m) in known.enumerated() where !m.keys.isEmpty {
                    // A later message naming the same keys within the period continues it; one with other keys ends it.
                    if i > 0, known[i - 1].keys == m.keys, m.at <= end { continue }
                    let stop = known[(i + 1)...].first { $0.keys != m.keys }?.at ?? 1e18
                    end = reach(from: m.at, until: stop, ivs)
                    for k in m.keys {
                        let how: LinkHow = brief.contains("\(sid) \(m.at) \(k)") ? .brief : .message
                        for t in try ix(k)! { try tasks.link(t, session: sid, how: how, start: m.at, end: end); n += 1 }
                    }
                }
            }
        }
        return n
    }

    /// End of a typed key's reach: through the working intervals after `start` while no pause is longer than
    /// `idleGap`, never past `stop`; at least the following minute (a key typed and then nothing worked).
    func reach(from start: Timestamp, until stop: Timestamp, _ ivs: [Interval]) -> Timestamp {
        var cur = start
        for iv in ivs where iv.end > start {
            if iv.start >= stop || iv.start - cur > idleGap { break }
            cur = max(cur, min(iv.end, stop))
        }
        return max(cur, min(start + 60, stop))
    }

    /// Git links of [from, to), rebuilt for the day, per folder an interval was worked in: the branch checked out
    /// there at the time (`worktree`, from the folder's checkouts), and your commits (author = the repo's `user.email`; worktrees of one repository are one
    /// group): a commit's keys take the group's intervals since the previous commit, at most `commitReach` back, and
    /// the last commit's keys also `afterCommit` after it. Work in a folder above the repository that is not a
    /// repository itself (`~`, a projects folder) counts too: agents there commit with `git -C` or full paths without
    /// moving into the repository. Other folders that are not git repositories are skipped.
    @discardableResult
    public func linkDay(_ store: Store, from: Timestamp, to: Timestamp, git: String = "git") throws -> Int {
        let db = store.db, tasks = Tasks(store: store), ix = try Known(store, self)
        var byCwd: [String: [(session: String, iv: Interval)]] = [:]
        try db.query("""
            SELECT a.session_id, coalesce(a.cwd, s.cwd), a.start, a."end" FROM activity a LEFT JOIN session s ON s.id = a.session_id
            WHERE a.kind = 'working' AND a.start < ? AND a."end" > ? AND coalesce(a.cwd, s.cwd) IS NOT NULL
            """, [.real(to), .real(from)]) { r in
            byCwd[r.text(1) ?? "", default: []].append((r.text(0) ?? "", Interval(max(from, r.real(2)), min(to, r.real(3)))))
        }
        var repos: [String: (cwd: String, tops: Set<String>, items: [(session: String, iv: Interval)])] = [:]
        var worktree: [String: [(session: String, iv: Interval)]] = [:]  // key -> intervals worked on a branch with it
        var plain: [String] = []
        if !ix.isEmpty {
            for (cwd, items) in byCwd where !cwd.isEmpty {
                guard let info = gitInfo(cwd, git: git) else { plain.append(cwd); continue }
                repos[info.common, default: (cwd, [], [])].items += items
                repos[info.common]!.tops.insert(info.top)
                let cos = checkouts(cwd, git: git)
                for it in items {
                    let cuts = [it.iv.start] + cos.map(\.ts).filter { $0 > it.iv.start && $0 < it.iv.end } + [it.iv.end]
                    for (a, b) in zip(cuts, cuts.dropFirst()) {
                        let branch = cos.last { $0.ts <= a }?.to ?? cos.first?.from ?? info.branch
                        for k in try (branch.map(keys) ?? []).filter({ try ix($0) != nil }) { worktree[k, default: []].append((it.session, Interval(a, b))) }
                    }
                }
            }
            // Repositories below such folders, also those nobody moved into.
            for p in plain where p != "/" {
                for dir in reposBelow(p) {
                    guard let info = gitInfo(dir, git: git) else { continue }
                    repos[info.common, default: (dir, [], [])].tops.insert(info.top)
                }
            }
            // git gives real paths (macOS: /var → /private/var; a symlinked projects folder).
            let real = Dictionary(plain.map { ($0, Sys.realPath($0) ?? $0) }, uniquingKeysWith: { a, _ in a })
            for (k, r) in repos {
                for p in plain {
                    let rp = real[p]!
                    guard r.tops.contains(where: { $0.hasPrefix(rp.hasSuffix("/") ? rp : rp + "/") }) else { continue }
                    repos[k]!.items += byCwd[p] ?? []
                }
            }
        }
        var n = 0
        try db.transaction {
            // Starts in [from, to), stored a little early (`LinkHow.nudge`).
            try db.run("DELETE FROM task_session WHERE how IN ('commit', 'worktree') AND start >= ? AND start < ?",
                       [.real(from - LinkHow.maxNudge), .real(to - LinkHow.maxNudge)])
            for (k, items) in worktree {
                for (sid, iv) in Self.mergedBySession(items) {
                    for t in try ix(k)! { try tasks.link(t, session: sid, how: .worktree, start: iv.start, end: iv.end); n += 1 }
                }
            }
            for repo in repos.values {
                let cs = commits(repo.cwd, from: from, to: to, git: git)
                guard try cs.contains(where: { try keys(in: $0.subject).contains { try ix($0) != nil } }) else { continue }
                var windows: [(lo: Timestamp, hi: Timestamp, keys: [String])] = []
                for (i, c) in cs.enumerated() {
                    windows.append((max(i > 0 ? cs[i - 1].ts : from, c.ts - Self.commitReach), c.ts, keys(in: c.subject)))
                }
                if let last = cs.last { windows.append((last.ts, last.ts + Self.afterCommit, keys(in: last.subject))) }
                let items = Self.mergedBySession(repo.items)
                for w in windows {
                    let ks = try w.keys.filter { try ix($0) != nil }
                    guard !ks.isEmpty, w.hi > w.lo else { continue }
                    for (sid, iv) in items {
                        let a = max(iv.start, w.lo), b = min(iv.end, w.hi)
                        guard b > a else { continue }
                        for k in ks { for t in try ix(k)! { try tasks.link(t, session: sid, how: .commit, start: a, end: b); n += 1 } }
                    }
                }
            }
        }
        return n
    }

    static func mergedBySession(_ items: [(session: String, iv: Interval)]) -> [(session: String, iv: Interval)] {
        Dictionary(grouping: items, by: \.session).flatMap { sid, xs in Intervals.merge(xs.map(\.iv)).map { (sid, $0) } }
    }

    /// The repository's shared git dir (one for all its worktrees), the worktree's top folder and the branch checked
    /// out in `cwd`.
    func gitInfo(_ cwd: String, git: String) -> (common: String, top: String, branch: String?)? {
        guard let r = Exec.run([git, "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel",
                                "--abbrev-ref", "HEAD"], quiet: true), r.status == 0 else { return nil }
        let lines = String(decoding: r.out, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        return (lines[0], lines[1], lines.count > 2 && lines[2] != "HEAD" ? lines[2] : nil)
    }

    /// Branch switches in the folder (its HEAD reflog), oldest first.
    func checkouts(_ cwd: String, git: String) -> [(ts: Timestamp, from: String, to: String)] {
        guard let r = Exec.run([git, "-C", cwd, "reflog", "--date=unix", "--format=%gd%x09%gs", "HEAD"], quiet: true), r.status == 0 else { return [] }
        // HEAD@{1793239200}<TAB>checkout: moving from main to PROJ-1-x
        return String(decoding: r.out, as: UTF8.self).split(separator: "\n").reversed().compactMap { line in
            guard let o = line.firstIndex(of: "{"), let c = line.firstIndex(of: "}"), o < c,
                  let ts = Double(line[line.index(after: o)..<c]), let tab = line.firstIndex(of: "\t") else { return nil }
            let w = line[line.index(after: tab)...].split(separator: " ")
            guard w.count == 6, w[0] == "checkout:", w[1] == "moving", w[2] == "from", w[4] == "to" else { return nil }
            return (ts, String(w[3]), String(w[5]))
        }
    }

    /// Folders one or two levels below `dir` that hold a `.git` (repositories and worktrees).
    /// ponytail: `find` per folder and day; cache by folder if plans get slow.
    func reposBelow(_ dir: String) -> [String] {
        guard let r = Exec.run(["find", "-H", dir, "-mindepth", "2", "-maxdepth", "3", "-name", ".git"], quiet: true) else { return [] }
        return String(decoding: r.out, as: UTF8.self).split(separator: "\n").map { String($0.dropLast(5)) }
    }

    /// Your commits authored in [from, to) on any branch, oldest first; none without the repo's `user.email` (they
    /// would be anyone's). Author time: a rebase moves the commit time of all commits to its own moment.
    func commits(_ cwd: String, from: Timestamp, to: Timestamp, git: String) -> [(ts: Timestamp, subject: String)] {
        let email = Exec.run([git, "-C", cwd, "config", "user.email"], quiet: true)
            .map { String(decoding: $0.out, as: UTF8.self).trimmed(" \n\r\t") } ?? ""
        guard !email.isEmpty, let r = Exec.run([git, "-C", cwd, "log", "--all", "--no-merges", "--since=@\(Int(from))",
                                                "--author=<\(email)>", "--format=%at%x09%s"], quiet: true), r.status == 0 else { return [] }
        return String(decoding: r.out, as: UTF8.self).split(separator: "\n").compactMap { line -> (ts: Timestamp, subject: String)? in
            guard let tab = line.firstIndex(of: "\t"), let ts = Double(line[..<tab]), ts >= from, ts < to else { return nil }
            return (ts, String(line[line.index(after: tab)...]))
        }.sorted { $0.ts < $1.ts }
    }

    /// Keys of sessions active in [from, to) — in branches, titles, typed messages and their briefs — that match no task
    /// (only keys of known projects, `allowed`).
    public func unknownKeys(_ store: Store, from: Timestamp, to: Timestamp) throws -> [String: [String]] {
        let ix = try index(store), ps = knownProjects(jira: JiraCache.load(store).projects, registry: ix)
        var out: [String: [String]] = [:]
        func add(_ k: String, _ sid: String) {
            guard ix[k] == nil, Self.allowed(k, ps), !(out[k]?.contains(sid) ?? false) else { return }
            out[k, default: []].append(sid)
        }
        try store.db.query("""
            SELECT id, git_branch, title FROM session WHERE last_at >= ? AND coalesce(started_at, last_at) < ?
            """, [.real(from), .real(to)]) { r in
            for text in [r.text(1), r.text(2)].compactMap({ $0 }) { for k in keys(in: text) { add(k, r.text(0) ?? "") } }
        }
        try store.db.query("SELECT DISTINCT key, session_id FROM task_key WHERE at >= ? AND at < ?", [.real(from), .real(to)]) {
            add($0.text(0) ?? "", $0.text(1) ?? "")
        }
        return out
    }
}
