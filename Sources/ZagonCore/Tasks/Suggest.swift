/// A link proposed by meaning for a stretch of work no key linked; it counts nowhere until accepted.
public struct Suggestion: Codable, Sendable, Equatable {
    /// The `task_session` row: what `task accept|reject` take.
    public var id: Int
    public var taskId: Int, key: String, title: String
    public var sessionId: String, sessionTitle: String?, project: String?
    public var start: Timestamp, end: Timestamp
    /// The session's working time in [start, end).
    public var workedSec: Double
    public var confidence: Double, reason: String
    /// The day's worklog text the AI wrote for it; set as "what was done" when accepted (if none is there).
    public var done: String = ""
}

/// Suggests tasks for the day's work that no key linked. One AI call per day (the summary's engine, read-only for
/// everything) over a compact digest: the stretches (project, folder, title, first words of typed messages, edited
/// files, commits), the candidate tasks (title, status; from Jira, read-only: description, last comments, your
/// earlier worklogs) and samples of how you write in Jira (`styleSamples`). Per stretch the AI names a task only when
/// sure (`minConfidence`), else it suggests a new task (`NewTaskDraft`: title, description, worklog text in your
/// style); stretches of one piece of work share one new task. Without an engine (or when it fails): shared words of
/// titles, projects and task names, and no new tasks.
/// Results are `suggested` links over the stretch; accept makes them `manual` for that period, reject unlinks the
/// task from the session for good.
public struct TaskSuggester {
    public let store: Store
    public var linker: TaskLinker
    public var jira: JiraClient?
    /// The engine and its settings (`[summary] engine, model, timeout`).
    public var engine: DaySummary
    public var minConfidence = 0.7
    /// The evening message (`[tasks] evening_suggestions = false` turns it off; commands keep working).
    public var evening = true
    /// Samples of your Jira texts in the ask (`[tasks] style_samples = false` leaves them out).
    public var styleSamplesOn = true
    /// The language of the message, the prompt and the AI's reasons: `[notify] lang`, as other notifications.
    var words: Words { engine.config.lang.words() }
    public var idleGap: Double = 20 * 60
    public var log: (String) -> Void = { _ in }
    /// Stretches with less work than this are not worth a suggestion; longer work than `maxSegment` is cut into
    /// pieces (a long session often moves between tasks).
    static let minSegment: Double = 10 * 60, maxSegment: Double = 2 * 3600
    static let maxPrompt = 16000, maxTaskBlock = 5000, maxTasks = 20, maxStyle = 3000
    /// The digest's size limit (`maxPrompt`; smaller in tests).
    var promptLimit = TaskSuggester.maxPrompt
    /// How far back Jira worklogs and updates make a task a candidate.
    static let lookback = 14

    public init(store: Store, linker: TaskLinker, jira: JiraClient?, engine: DaySummary) {
        self.store = store; self.linker = linker; self.jira = jira; self.engine = engine
    }

    /// From config.toml: `[tasks] key_pattern, suggest_min_confidence`, `[jira]`, and the summary's engine.
    public static func load(store: Store, paths: ZagonPaths, config: NotifyConfig, claudeRoot: String,
                            log: @escaping (String) -> Void = { _ in }) throws -> TaskSuggester {
        let text = Sys.readFile(paths.config).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let linker = try TaskLinker(patterns: [TOMLLite.string(in: text, section: "tasks", key: "key_pattern") ?? TaskLinker.defaultPattern])
        var jira: JiraClient?
        if let c = JiraConfig.load(configText: text) {
            do { jira = try JiraClient(c) } catch { log("suggest: Jira not available: \(error)") }
        }
        var engine = DaySummary(store: store, config: config, paths: paths, claudeRoot: claudeRoot)
        engine.log = log
        var s = TaskSuggester(store: store, linker: linker, jira: jira, engine: engine)
        if let v = TOMLLite.raw(in: text, section: "tasks", key: "suggest_min_confidence").flatMap({ Double(String($0.prefix { $0 != " " && $0 != "#" })) }),
           v > 0 { s.minConfidence = v }
        s.evening = TOMLLite.raw(in: text, section: "tasks", key: "evening_suggestions").map { !$0.hasPrefix("false") } ?? true
        s.styleSamplesOn = TOMLLite.raw(in: text, section: "tasks", key: "style_samples").map { !$0.hasPrefix("false") } ?? true
        s.log = log
        return s
    }

    // MARK: running

    public struct Run: Sendable, Encodable {
        public var items: [Suggestion]
        /// New tasks suggested for work no task fits.
        public var drafts: [NewTaskDraft] = []
        /// False: nothing new to ask (every stretch of the day was asked about), these are the stored suggestions.
        public var made: Bool
        public var engine: String
        /// Stretches without a link now; how many went to the AI this time (new ones only; the digest has a size limit).
        public var segments = 0, asked = 0
        public var seconds = 0.0, costUSD: Double?, inputTokens: Int?, outputTokens: Int?
        public var note: String?
    }

    /// The day's suggestions. The AI is asked only about work it was not asked about yet and no open suggestion
    /// covers (the asked periods are kept per day); `again` drops the open ones and asks about all. Suggestions whose
    /// time got a link since are dropped first.
    public func suggest(_ day: String, again: Bool = false, now: Timestamp = Time.now()) throws -> Run {
        guard let (from, to) = Time.dayBounds(day) else { throw TaskError("bad day \(day)") }
        let metaKey = "suggest:" + day
        if again {
            try store.db.transaction {
                try store.db.run("DELETE FROM task_session WHERE how = 'suggested' AND start >= ? AND start < ?",
                                 [.real(from - LinkHow.maxNudge), .real(to - LinkHow.maxNudge)])
                try store.db.run("DELETE FROM meta WHERE key = ?", [.text(metaKey)])
                try dropDrafts(day: day)
            }
        }
        try linker.linkSessions(store)
        try linker.linkDay(store, from: from, to: to)
        try dropStale(from: from, to: to)
        let prev = try meta(metaKey)
        let p = try prepare(day, from: from, to: to, now: now, skip: try skipPeriods(day, from: from, to: to), relink: false)
        guard !p.segs.isEmpty else {
            return Run(items: try list(day), drafts: try drafts(day), made: false, engine: prev?["engine"]?.string ?? "none", segments: 0)
        }
        var run = Run(items: [], made: true, engine: "none", segments: p.segs.count, asked: p.asked.count)
        if p.missing > 0 { run.note = "\(p.missing) of your Jira issues of those days are not read yet (zagon task import reads them)" }
        let blocked = try self.blocked()
        let allowed = { (seg: Segment, task: Int) in !blocked.contains("\(task) \(seg.session)") }
        let byKey = Dictionary(p.cands.map { ($0.task.key, $0.task.id) }, uniquingKeysWith: { a, _ in a })
        let segById = Dictionary(uniqueKeysWithValues: p.segs.map { ($0.id, $0) })
        var picks: [(seg: Segment, task: Int, confidence: Double, reason: String)] = [], done: [String: String] = [:]
        var news: [(segs: [Segment], title: String, description: String, done: String, confidence: Double)] = []
        var askedNow: [Segment] = []
        if ["claude", "codex"].contains(engine.config.summaryEngine) {
            let t0 = Time.now()
            if let r = engine.complete(p.prompt, what: "suggest") {
                run.engine = r.engine; run.seconds = Time.now() - t0
                run.costUSD = r.result?["total_cost_usd"]?.double
                if let u = r.result?["usage"] {
                    let input: Double = u["input_tokens"]?.double ?? 0, read: Double = u["cache_read_input_tokens"]?.double ?? 0
                    let write: Double = u["cache_creation_input_tokens"]?.double ?? 0  // one sum is too slow to type-check on macOS
                    run.inputTokens = Int(input + read + write)
                    run.outputTokens = u["output_tokens"]?.double.map(Int.init)
                }
                askedNow = p.asked.compactMap { segById[$0] }
                // Per stretch the most confident task not rejected for that session; else the new task it was given.
                for a in Self.parse(r.text, segments: Set(p.asked), keys: Set(byKey.keys), min: minConfidence) {
                    let seg = segById[a.segment]!, task = byKey[a.key]!
                    if !picks.contains(where: { $0.seg.id == seg.id }) && allowed(seg, task) {
                        picks.append((seg, task, a.confidence, a.reason)); done[seg.id] = a.done
                    }
                }
                for n in Self.parseNew(r.text, segments: Set(p.asked)) {
                    let segs = n.segments.filter { id in !picks.contains { $0.seg.id == id } }.compactMap { segById[$0] }
                    if !segs.isEmpty { news.append((segs, n.title, n.description, n.done, n.confidence)) }
                }
                if picks.isEmpty && news.isEmpty && !r.text.isEmpty { log("suggest: the answer gave no usable suggestion") }
            } else {
                run.note = "the \(engine.config.summaryEngine) call failed; suggested by shared words for now, the rest is asked next time"
            }
        }
        if run.engine == "none" {
            for x in Self.byWords(p.segs, p.facts, p.cands, words: words) where x.confidence >= minConfidence && allowed(x.seg, x.task) { picks.append(x) }
        }
        try store.db.transaction {
            // Read again: another run (daemon, CLI, MCP) may have stored suggestions meanwhile.
            let cur = try meta(metaKey)
            var items = cur?["items"]?.array ?? [], asked = cur?["asked"]?.array ?? []
            let taken = try openPeriods(from: from, to: to)
            // Another run (daemon, CLI, MCP) may have suggested a task or a new one for this work meanwhile.
            let drafted = try draftPeriods(day)
            let free = { (g: Segment) in
                !((taken[g.session] ?? []) + (drafted[g.session] ?? [])).contains(where: { $0.start < g.end && $0.end > g.start })
            }
            for x in picks where free(x.seg) {
                try Tasks(store: store).link(x.task, session: x.seg.session, how: .suggested, start: x.seg.start, end: x.seg.end)
                items.append(.object([.init("t", .number("\(x.task)")), .init("s", .string(x.seg.session)),
                                      .init("a", .number("\(x.seg.start)")), .init("c", .number("\(x.confidence)")),
                                      .init("r", .string(x.reason)), .init("w", .string(done[x.seg.id] ?? ""))]))
            }
            try addDrafts(news.compactMap { n in
                let segs = n.segs.filter(free)
                return segs.isEmpty ? nil : (segs, n.title, n.description, n.done, n.confidence)
            }, day: day, now: now)
            for g in askedNow {
                asked.append(.object([.init("s", .string(g.session)), .init("a", .number("\(g.start)")), .init("b", .number("\(g.end)"))]))
            }
            let engineName = run.engine != "none" ? run.engine : cur?["engine"]?.string ?? "none"
            let cost = (cur?["cost"]?.double ?? 0) + (run.costUSD ?? 0)
            try setMeta(metaKey, .object([.init("engine", .string(engineName)), .init("at", .number("\(now)")),
                                          .init("cost", .number("\(cost)")), .init("items", .array(items)), .init("asked", .array(asked))]))
        }
        run.items = try list(day)
        run.drafts = try drafts(day)
        return run
    }

    /// Work not to ask about: open suggestions of the day and periods the AI was asked about already.
    func skipPeriods(_ day: String, from: Timestamp, to: Timestamp) throws -> [String: [Interval]] {
        var skip = try openPeriods(from: from, to: to)
        for x in try meta("suggest:" + day)?["asked"]?.array ?? [] {
            if let s = x["s"]?.string, let a = x["a"]?.double, let b = x["b"]?.double { skip[s, default: []].append(Interval(a, b)) }
        }
        return skip
    }

    /// Drops open suggestions of the day whose time (any of it) got a link since.
    func dropStale(from: Timestamp, to: Timestamp) throws {
        let map = try Tasks(store: store).linkMap()
        var stale: [Int] = []
        try store.db.query("""
            SELECT rowid, session_id, start, "end" FROM task_session WHERE how = 'suggested' AND start >= ? AND start < ?
            """, [.real(from - LinkHow.maxNudge), .real(to - LinkHow.maxNudge)]) { r in
            if !Self.covered(map, r.text(1) ?? "", r.real(2) + LinkHow.suggested.nudge, r.real(3)).isEmpty { stale.append(r.int(0)) }
        }
        for id in stale { try store.db.run("DELETE FROM task_session WHERE rowid = ? AND how = 'suggested'", [.int(Int64(id))]) }
    }

    /// Tasks linked anywhere in [a, b) of the session.
    static func covered(_ map: LinkMap, _ sid: String, _ a: Timestamp, _ b: Timestamp) -> [Int] {
        let cuts = [a] + map.edges(sid).filter { $0 > a && $0 < b }.sorted() + [b]
        var out: [Int] = []
        for (x, y) in zip(cuts, cuts.dropFirst()) where y > x {
            for t in map.tasks(sid, at: (x + y) / 2) where !out.contains(t.task) { out.append(t.task) }
        }
        return out
    }

    /// What the next call would send for the day (only work not asked yet): no AI call, no suggestion stored (the
    /// day's links are refreshed and Jira is read, as for a real run).
    public func prompt(_ day: String, now: Timestamp = Time.now()) throws -> String {
        guard let (from, to) = Time.dayBounds(day) else { throw TaskError("bad day \(day)") }
        return try prepare(day, from: from, to: to, now: now, skip: try skipPeriods(day, from: from, to: to)).prompt
    }

    struct Prepared {
        var segs: [Segment], facts: [String: Facts], cands: [Candidate], prompt: String, asked: [String]
        /// Jira issues with your worklogs or updates those days that are not tasks here.
        var missing: Int
    }

    func prepare(_ day: String, from: Timestamp, to: Timestamp, now: Timestamp, skip: [String: [Interval]],
                 relink: Bool = true) throws -> Prepared {
        if relink {
            try linker.linkSessions(store)
            try linker.linkDay(store, from: from, to: to)
        }
        let segs = try segments(from: from, to: to, skip: skip)
        guard !segs.isEmpty else { return Prepared(segs: [], facts: [:], cands: [], prompt: "", asked: [], missing: 0) }
        let (cands, missing) = try candidates(day, from: from, to: to, now: now)
        let facts = try self.facts(segs, from: from, to: to)
        let (prompt, asked) = Self.prompt(segs, facts, cands, style: styleSamples(day, now: now), limit: promptLimit, words: words)
        return Prepared(segs: segs, facts: facts, cands: cands, prompt: prompt, asked: asked, missing: missing)
    }

    /// Open suggestions of the day per session.
    func openPeriods(from: Timestamp, to: Timestamp) throws -> [String: [Interval]] {
        var out: [String: [Interval]] = [:]
        try store.db.query("""
            SELECT session_id, start, "end" FROM task_session WHERE how = 'suggested' AND start >= ? AND start < ?
            """, [.real(from - LinkHow.maxNudge), .real(to - LinkHow.maxNudge)]) {
            out[$0.text(0) ?? "", default: []].append(Interval($0.real(1) + LinkHow.suggested.nudge, $0.real(2)))
        }
        return out
    }

    /// "task session" pairs never to suggest: rejected, or unlinked by hand.
    func blocked() throws -> Set<String> {
        var out = Set(try meta("suggest:rejected")?.array?.compactMap(\.string) ?? [])
        try store.db.query("SELECT task_id, session_id FROM task_session WHERE how = 'unlinked'") { out.insert("\($0.int(0)) \($0.text(1) ?? "")") }
        return out
    }

    /// Open suggestions of the day (not accepted, rejected, or covered by a link since), longest first.
    public func list(_ day: String) throws -> [Suggestion] {
        guard let (from, to) = Time.dayBounds(day) else { throw TaskError("bad day \(day)") }
        var why: [String: (Double, String, String)] = [:]
        for i in try meta("suggest:" + day)?["items"]?.array ?? [] {
            guard let t = i["t"]?.double, let s = i["s"]?.string, let a = i["a"]?.double else { continue }
            why["\(Int(t)) \(s) \(a)"] = (i["c"]?.double ?? 0, i["r"]?.string ?? "", i["w"]?.string ?? "")
        }
        let map = try Tasks(store: store).linkMap()
        var out: [Suggestion] = []
        try store.db.query("""
            SELECT ts.rowid, ts.task_id, ts.session_id, ts.start, ts."end", t.key, t.title, s.title, \(Projects.sessionSQL())
            FROM task_session ts JOIN task t ON t.id = ts.task_id LEFT JOIN session s ON s.id = ts.session_id
            WHERE ts.how = 'suggested' AND ts.start >= ? AND ts.start < ?
            """, [.real(from - LinkHow.maxNudge), .real(to - LinkHow.maxNudge)]) { r in
            let start = r.real(3) + LinkHow.suggested.nudge, sid = r.text(2) ?? ""
            guard Self.covered(map, sid, start, r.real(4)).isEmpty else { return }
            let w = why["\(r.int(1)) \(sid) \(start)"]
            out.append(Suggestion(id: r.int(0), taskId: r.int(1), key: r.text(5) ?? "", title: r.text(6) ?? "",
                                  sessionId: sid, sessionTitle: r.text(7), project: r.text(8),
                                  start: start, end: r.real(4), workedSec: 0, confidence: w?.0 ?? 0, reason: w?.1 ?? "", done: w?.2 ?? ""))
        }
        for i in out.indices {
            out[i].workedSec = try TaskLinker.working(store.db, out[i].sessionId)
                .reduce(0) { $0 + max(0, min($1.end, out[i].end) - max($1.start, out[i].start)) }
        }
        return out.sorted { $0.workedSec > $1.workedSec }
    }

    /// Accept: the task is linked by hand for the suggestion's period, unless any of that time got a link since (the
    /// day's links are refreshed first); then the suggestion is dropped. `task`, `start`: what the id was shown with
    /// (a bot button), refused if the id now holds another. Returns a line per id.
    public func accept(_ ids: [Int], task: Int? = nil, start: Int? = nil) throws -> [String] {
        var fresh = Set<String>(), out: [String] = []
        for id in ids {
            guard let s = try row(id, task: task, start: start) else { out.append("#\(id): no such open suggestion"); continue }
            let day = Time.dayString(s.start)
            if fresh.insert(day).inserted, let (from, to) = Time.dayBounds(day) {
                try linker.linkSessions(store); try linker.linkDay(store, from: from, to: to)
            }
            let now = Self.covered(try Tasks(store: store).linkMap(), s.session, s.start, s.end)
            if !now.isEmpty {
                try store.db.run("DELETE FROM task_session WHERE rowid = ? AND how = 'suggested'", [.int(Int64(id))])
                let keys = try now.map { try Tasks(store: store).get($0)?.key ?? "#\($0)" }
                out.append("#\(id) not accepted: that time is linked to \(keys.joined(separator: ", ")) now; suggestion dropped")
                continue
            }
            let text = try list(day).first { $0.id == id }?.done ?? ""
            try store.db.run("UPDATE OR REPLACE task_session SET how = 'manual', start = ? WHERE rowid = ? AND how = 'suggested'",
                             [.real(s.start), .int(Int64(id))])
            // The stretch's text stands for the day only when it is all the task's work that day.
            if !text.isEmpty, try Tasks(store: store).done(s.task).first(where: { $0.day == day }) == nil, let (from, to) = Time.dayBounds(day),
               try store.db.one("""
                   SELECT count(*) FROM task_session WHERE task_id = ? AND how NOT IN ('unlinked', 'suggested') AND start < ? AND "end" > ?
                   """, [.int(Int64(s.task)), .real(to), .real(from)], { $0.int(0) }) == 1 {
                try Tasks(store: store).setDone(s.task, day: day, text: text, source: "auto")
            }
            out.append("#\(id) accepted: \(s.key) \(Txt.clock(s.start))–\(Txt.clock(s.end))")
        }
        return out
    }

    /// Reject: that task is never suggested for that session again (`suggest:rejected`). Its links to the session
    /// stay, also those that come later from keys or commits.
    public func reject(_ ids: [Int], task: Int? = nil, start: Int? = nil) throws -> [String] {
        try ids.map { id in
            guard let s = try row(id, task: task, start: start) else { return "#\(id): no such open suggestion" }
            try store.db.transaction {
                try store.db.run("DELETE FROM task_session WHERE rowid = ? AND how = 'suggested'", [.int(Int64(id))])
                var r = try meta("suggest:rejected")?.array ?? []
                if !r.contains(.string("\(s.task) \(s.session)")) { r.append(.string("\(s.task) \(s.session)")) }
                try setMeta("suggest:rejected", .array(r))
            }
            return "#\(id) rejected: \(s.key) is not suggested for this session again"
        }
    }

    func row(_ id: Int, task: Int? = nil, start: Int? = nil) throws -> (task: Int, session: String, key: String, start: Timestamp, end: Timestamp)? {
        let r = try store.db.one("""
            SELECT ts.task_id, ts.session_id, t.key, ts.start, ts."end" FROM task_session ts JOIN task t ON t.id = ts.task_id
            WHERE ts.rowid = ? AND ts.how = 'suggested'
            """, [.int(Int64(id))]) { ($0.int(0), $0.text(1) ?? "", $0.text(2) ?? "", $0.real(3) + LinkHow.suggested.nudge, $0.real(4)) }
        if let r, (task.map { $0 != r.0 } ?? false) || (start.map { $0 != Int(r.3) } ?? false) { return nil }
        return r
    }

    func meta(_ key: String) throws -> JValue? {
        try store.db.one("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.text(0) }?.flatMap { JValue.parse($0) }
    }

    func setMeta(_ key: String, _ v: JValue) throws {
        try store.db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2", [.text(key), .text(v.compact)])
    }

    // MARK: stretches without a link

    struct Segment { var id: String, session: String, start: Timestamp, end: Timestamp, worked: Double }

    /// Per session, runs of working time no link covers (pauses up to `idleGap` join them, linked work between
    /// ends them, so does work in `skip`), with at least `minSegment` and at most `maxSegment` of work; ids S1… by start.
    func segments(from: Timestamp, to: Timestamp, skip: [String: [Interval]] = [:]) throws -> [Segment] {
        let map = try Tasks(store: store).linkMap()
        var sids: [String] = []
        try store.db.query("SELECT DISTINCT session_id FROM activity WHERE kind = 'working' AND start < ? AND \"end\" > ?",
                           [.real(to), .real(from)]) { sids.append($0.text(0) ?? "") }
        var out: [Segment] = []
        for sid in sids {
            let skipped = skip[sid] ?? []
            let edges = (map.edges(sid) + skipped.flatMap { [$0.start, $0.end] }).sorted()
            var run: Segment?
            func close() { if let r = run, r.worked >= Self.minSegment { out.append(r) }; run = nil }
            for iv in try TaskLinker.working(store.db, sid) where iv.end > from && iv.start < to {
                let a0 = max(iv.start, from), b0 = min(iv.end, to)
                let cuts = [a0] + edges.filter { $0 > a0 && $0 < b0 } + [b0]
                for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
                    let mid = (a + b) / 2
                    if !map.tasks(sid, at: mid).isEmpty || skipped.contains(where: { $0.start <= mid && mid < $0.end }) { close(); continue }
                    var a = a
                    while a < b {
                        if run == nil || a - run!.end > idleGap { close(); run = Segment(id: "", session: sid, start: a, end: a, worked: 0) }
                        let piece = min(b, a + Self.maxSegment - run!.worked)
                        run!.end = piece; run!.worked += piece - a; a = piece
                        if run!.worked >= Self.maxSegment { close() }
                    }
                }
            }
            close()
        }
        out.sort { $0.start < $1.start }
        for i in out.indices { out[i].id = "S\(i + 1)" }
        return out
    }

    // MARK: facts

    struct Facts {
        var project: String?, title: String?, cwd: String?
        var prompts: [(ts: Timestamp, text: String)] = []
        var files: [(ts: Timestamp, path: String)] = []
        var commits: [(ts: Timestamp, subject: String)] = []
    }

    /// Per session of the segments: names, typed messages and edited files of the day (Claude transcripts), commits.
    func facts(_ segs: [Segment], from: Timestamp, to: Timestamp) throws -> [String: Facts] {
        var out: [String: Facts] = [:]
        for sid in Set(segs.map(\.session)) {
            var f = Facts()
            try store.db.query("SELECT \(Projects.sessionSQL("session")), title, cwd FROM session WHERE id = ?", [.text(sid)]) {
                f.project = $0.text(0); f.title = $0.text(1); f.cwd = $0.text(2)
            }
            out[sid] = f
        }
        var files: [(path: String, sid: String, agent: String)] = []
        try store.db.query("SELECT path, session_id, agent FROM source_file WHERE tool = 'claude' AND mtime >= ?", [.real(from)]) { r in
            if let p = r.text(0), let sid = r.text(1), out[sid] != nil { files.append((p, sid, r.text(2) ?? "")) }
        }
        for file in files {
            var parser = file.agent.isEmpty
                ? ClaudeSource.spec(root: engine.claudeRoot, indexPrompts: true).makeParser(file.path, "p/" + Sys.basename(file.path), nil)
                : nil
            Lines.each(file.path) { line in
                if parser != nil && contains(line, "\"type\":\"user\"") {
                    var o = ParseOutput()
                    parser!.parse(line: line, into: &o)
                    for m in o.userMessages where m.ts >= from && m.ts < to {
                        if let t = m.text.map(DaySummary.phrase), !t.isEmpty { out[file.sid]!.prompts.append((m.ts, t)) }
                    }
                }
                guard contains(line, "\"tool_use\""), DaySummary.editTools.contains(where: { line.has("\"name\":\"\($0)\"") }),
                      line.count < 8 << 20, let v = JValue.parse(Array(line)),
                      let ts = v["timestamp"]?.string.flatMap(Time.parseISO), ts >= from, ts < to else { return }
                for b in v["message"]?["content"]?.array ?? [] where b["type"]?.string == "tool_use" {
                    guard let name = b["name"]?.string, DaySummary.editTools.contains(name),
                          let p = b["input"]?["file_path"]?.string ?? b["input"]?["notebook_path"]?.string else { continue }
                    out[file.sid]!.files.append((ts, p))
                }
            }
        }
        var byRepo: [String: [(ts: Timestamp, subject: String)]] = [:]
        for (sid, f) in out {
            guard let cwd = f.cwd, let top = linker.gitInfo(cwd, git: "git")?.top else { continue }
            if byRepo[top] == nil { byRepo[top] = linker.commits(top, from: from, to: to, git: "git") }
            out[sid]!.commits = byRepo[top]!
        }
        return out
    }

    // MARK: candidates

    struct Candidate {
        var task: TaskItem
        var score = 0.0
        var description: String?, comments: [String] = [], worklogs: [String] = []
    }

    /// Tasks worth offering: your Jira worklogs of the last `lookback` days, links of those days, in progress, created
    /// then, Jira issues assigned to you and updated then; best first, at most `maxTasks`. Jira is read once per day (cached in
    /// `meta`; for today at most an hour) and failures only drop the Jira part. Your Jira issues with those signals
    /// that are no task here yet become tasks (with no work, they stay out of the task list); `missing`: those Jira
    /// issues not read into `JiraCache`, so not offered.
    func candidates(_ day: String, from: Timestamp, to: Timestamp, now: Timestamp) throws -> (cands: [Candidate], missing: Int) {
        let tasks = Tasks(store: store)
        var c: [Int: Candidate] = [:]
        let since = from - Double(Self.lookback) * 86400
        let j = jiraFacts(day, since: since, from: from, to: to, now: now)
        let cache = JiraCache.current(store, jira, now: now, log: log)
        // Made a task "before" the window: it is offered for its Jira signals, not as a task created then.
        for k in Set(Array(j.worklogs.keys) + j.updated + j.near) where cache.mine.contains(k) { _ = try tasks.findOrAdopt(k, at: since - 1) }
        for t in try tasks.list() {
            c[t.id] = Candidate(task: t, score: (t.status == .inProgress ? 1 : t.status == .review ? 0.3 : t.status == .planned ? 0.2 : 0)
                                    + (t.created >= since ? 0.5 : 0))
        }
        let byKey = Dictionary(c.values.flatMap { v in [v.task.key, v.task.jiraKey].compactMap { $0 }.map { ($0, v.task.id) } },
                               uniquingKeysWith: { a, _ in a })
        try store.db.query("""
            SELECT ts.task_id, count(DISTINCT ts.session_id) FROM task_session ts JOIN session s ON s.id = ts.session_id
            WHERE ts.how NOT IN ('unlinked', 'suggested') AND s.last_at >= ? AND coalesce(s.started_at, s.last_at) < ? GROUP BY ts.task_id
            """, [.real(since), .real(from)]) { r in c[r.int(0)]?.score += 1 + min(Double(r.int(1)), 5) * 0.1 }
        // Signals: updated in Jira on the day or the next (2.5), your worklogs (2 the day before … 0.5 two weeks
        // before), links of those days before this one (1+; work with a key is linked already, the rest is more
        // often another task), in progress (1), created then (0.5), updated then (0.5).
        for (k, w) in j.worklogs {
            guard let id = byKey[k] else { continue }
            c[id]?.score += 0.5 + 1.5 * max(0, 1 - (from - w.last) / (Double(Self.lookback) * 86400)); c[id]?.worklogs = w.texts
        }
        for k in j.updated { if let id = byKey[k] { c[id]?.score += 0.5 } }
        for k in j.near { if let id = byKey[k] { c[id]?.score += 2.5 } }
        let missing = Set(Array(j.worklogs.keys) + j.near).filter { byKey[$0] == nil }.count
        var top = c.values.filter { $0.score > 0.5 }.sorted { ($0.score, $0.task.updated) > ($1.score, $1.task.updated) }
        top = Array(top.prefix(Self.maxTasks))
        let ctx = jiraContext(day, keys: top.compactMap(\.task.jiraKey), now: now)
        for i in top.indices {
            if let k = top[i].task.jiraKey, let x = ctx[k] { top[i].description = x.description; top[i].comments = x.comments }
            else if top[i].description == nil { top[i].description = top[i].task.description }
        }
        return (top, missing)
    }

    /// A cache of `day` read at `now` is still good: read the same day, and for today not older than an hour.
    func fresh(_ v: JValue?, day: String, now: Timestamp) -> Bool {
        guard let v, v["at"]?.string == Time.dayString(now) else { return false }
        return day != Time.dayString(now) || now - (v["ts"]?.double ?? 0) < 3600
    }

    /// Writes a Jira cache of the day and drops those of other days (only the day being suggested is ever reused).
    func setCache(_ key: String, day: String, _ members: [JValue.Member], now: Timestamp) {
        _ = try? store.db.run("DELETE FROM meta WHERE (key LIKE 'suggest:jira:%' OR key LIKE 'suggest:jira-ctx:%') AND key NOT LIKE ?",
                              [.text("%:" + day)])
        try? setMeta(key, .object([.init("at", .string(Time.dayString(now))), .init("ts", .number("\(now)"))] + members))
    }

    /// Your worklogs per issue from [since, from) (the last start, a few texts), keys of issues assigned to you
    /// updated since `since`, and of those updated on the day or the next.
    func jiraFacts(_ day: String, since: Timestamp, from: Timestamp, to: Timestamp, now: Timestamp)
        -> (worklogs: [String: (last: Timestamp, texts: [String])], updated: [String], near: [String]) {
        guard let jira else { return ([:], [], []) }
        let key = "suggest:jira:" + day
        if let v = try? meta(key), fresh(v, day: day, now: now) {
            var w: [String: (last: Timestamp, texts: [String])] = [:]
            for m in Self.members(v["worklogs"]) { w[m.key] = (m.value["last"]?.double ?? 0, m.value["texts"]?.array?.compactMap(\.string) ?? []) }
            return (w, v["updated"]?.array?.compactMap(\.string) ?? [], v["near"]?.array?.compactMap(\.string) ?? [])
        }
        do {
            var w: [String: (last: Timestamp, texts: [String])] = [:]
            for x in try jira.myWorklogs(from: since, to: from).sorted(by: { $0.started > $1.started }) {
                var e = w[x.issueKey] ?? (x.started, [])
                if let t = x.comment.map(Self.clip(70)), !t.isEmpty, !e.texts.contains(t), e.texts.count < 2 { e.texts.append(t) }
                w[x.issueKey] = e
            }
            let updated = try jira.search("assignee = currentUser() AND updated >= \"\(JiraClient.utcDay(since))\" ORDER BY updated DESC",
                                          limit: 100).map(\.key)
            let near = try jira.search("assignee = currentUser() AND updated >= \"\(day)\" AND updated < \"\(Time.addDays(day, 2) ?? day)\"",
                                       limit: 100).map(\.key)
            setCache(key, day: day, [.init("worklogs", .object(w.map { k, e in .init(k, .object([.init("last", .number("\(e.last)")),
                                                                                         .init("texts", .array(e.texts.map(JValue.string)))])) })),
                                     .init("updated", .array(updated.map(JValue.string))),
                                     .init("near", .array(near.map(JValue.string)))], now: now)
            return (w, updated, near)
        } catch {
            log("suggest: Jira failed, suggesting without it: \(error)")
            return ([:], [], [])
        }
    }

    /// Clipped description and last two comments per issue, cached for the day it was read.
    func jiraContext(_ day: String, keys: [String], now: Timestamp) -> [String: (description: String?, comments: [String])] {
        guard let jira, !keys.isEmpty else { return [:] }
        let key = "suggest:jira-ctx:" + day
        var out: [String: (description: String?, comments: [String])] = [:]
        if let v = try? meta(key), fresh(v, day: day, now: now) {
            for m in Self.members(v["issues"]) { out[m.key] = (m.value["d"]?.string, m.value["c"]?.array?.compactMap(\.string) ?? []) }
        }
        for k in keys where out[k] == nil {
            do {
                guard let x = try jira.context(k) else { continue }
                out[k] = (x.description.map(Self.clip(120)), x.comments.suffix(2).map(Self.clip(70)))
            } catch { log("suggest: Jira \(k) failed: \(error)"); break }
        }
        setCache(key, day: day, [.init("issues", .object(out.map { k, x in
            .init(k, .object([.init("d", x.description.map(JValue.string) ?? .null), .init("c", .array(x.comments.map(JValue.string)))]))
        }))], now: now)
        return out
    }

    static func members(_ v: JValue?) -> [JValue.Member] { if case .object(let m)? = v { return m }; return [] }

    /// Samples of how you write in Jira, for the AI to write new tasks and worklogs the same way: issues you created
    /// (title and the start of the description), your worklog comments of the last `lookback` days, your comments; only
    /// your own texts (Jira `myself`), clipped, at most `maxStyle` characters; read once per day (cached in `meta`).
    /// Empty without Jira or when it fails.
    func styleSamples(_ day: String, now: Timestamp) -> String {
        guard let jira, styleSamplesOn else { return "" }
        let key = "suggest:style"
        if let v = try? meta(key), v["at"]?.string == Time.dayString(now), let t = v["text"]?.string { return t }
        do {
            let t = try jira.myTexts(since: now - Double(Self.lookback) * 86400)
            let text = Self.style(t, words: words)
            try setMeta(key, .object([.init("at", .string(Time.dayString(now))), .init("text", .string(text)),
                                      .init("n", .array([t.issues.count, t.worklogs.count, t.comments.count].map { .number("\($0)") }))]))
            return text
        } catch {
            log("suggest: Jira texts failed, no style samples: \(error)")
            return ""
        }
    }

    static func style(_ t: JiraTexts, words w: Words) -> String {
        var out: [String] = []
        if !t.issues.isEmpty {
            out.append(w.t("Задачи, которые он завёл (название — описание):", "Tasks they created (title — description):"))
            out += t.issues.map { "- " + clip(100)($0.summary) + ($0.description.isEmpty ? "" : " — " + lines($0.description, 300)) }
        }
        if !t.worklogs.isEmpty { out.append(w.t("Его ворклоги:", "Their worklogs:")); out += t.worklogs.map { "- " + clip(150)($0) } }
        if !t.comments.isEmpty { out.append(w.t("Его комментарии:", "Their comments:")); out += t.comments.map { "- " + lines($0, 250) } }
        var text = ""
        for l in out where text.count + l.count + 1 <= maxStyle { text += l + "\n" }
        return text.trimmed("\n")
    }

    /// One line, at most `n` characters.
    static func clip(_ n: Int) -> (String) -> String {
        { s in
            let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return t.count > n ? String(t.prefix(n - 1)) + "…" : t
        }
    }

    // MARK: prompt and answer

    /// The ask, in the language of notifications (`[notify] lang`): the reasons come back in it.
    static func instruction(_ w: Words) -> String {
        w.t("""
            Ниже задачи разработчика и отрезки его рабочего дня (работа ИИ-агентов в сессиях), которые не привязаны ни к \
            одной задаче. Для каждого отрезка: если он по смыслу точно относится к задаче из списка (смотри на проект, \
            папку, название сессии, запросы, файлы, коммиты, описание задачи и прошлые ворклоги по ней), дай её ключ. \
            Не натягивай: если подходящей задачи нет или не уверен, предложи новую задачу — короткое название (до 70 \
            символов), описание (что было и что сделано, 2–4 строки) и текст ворклога за этот день (1–2 строки). \
            Отрезки одной работы — одна новая задача с одинаковым названием. Названия, описания и ворклоги пиши так, как \
            пишет сам разработчик (образцы ниже: язык, длина, структура, тон; разделов, которых у него нет, не добавляй); \
            нет образцов — коротко и нейтрально, по-русски. Ответь только JSON-массивом, без текста вокруг: \
            [{"segment": "S1", "key": "ABC-1", "confidence": 0.8, "reason": "почему, до 80 символов", "done": "текст ворклога"}, \
            {"segment": "S2", "new": "Название", "description": "Что было и что сделано", "done": "текст ворклога", \
            "confidence": 0.7}]. confidence — от 0 до 1. Ключи — только из списка задач. reason пиши по-русски.


            """, """
            Below are a developer's tasks and stretches of their working day (AI agents working in sessions) that no task \
            is linked to. For each stretch: if it clearly belongs to a task from the list (look at the project, folder, \
            session title, prompts, files, commits, and the task's description and earlier worklogs), give its key. Do \
            not stretch it: if no task fits or you are not sure, suggest a new task — a short title (up to 70 \
            characters), a description (what it was and what was done, 2–4 lines) and the day's worklog text (1–2 \
            lines). Stretches of one piece of work get one new task with the same title. Write titles, descriptions and \
            worklogs the way the developer writes them (samples below: language, length, structure, tone; add no \
            sections they do not use); without samples — short and plain, in English. Answer with a JSON array only, no \
            text around it: [{"segment": "S1", "key": "ABC-1", "confidence": 0.8, "reason": "why, up to 80 characters", \
            "done": "worklog text"}, {"segment": "S2", "new": "Title", "description": "What it was and what was done", \
            "done": "worklog text", "confidence": 0.7}]. confidence is 0 to 1. Keys only from the task list. Write reason \
            in English.


            """)
    }

    /// The digest (at most `maxPrompt` characters, longest stretches first) and the segment ids in it.
    static func prompt(_ segs: [Segment], _ facts: [String: Facts], _ cands: [Candidate], style: String = "", limit: Int = maxPrompt,
                       words w: Words = .ru) -> (String, [String]) {
        let q = { (s: String) in w.t("«\(s)»", "\"\(s)\"") }
        var tasks = (style.isEmpty ? "" : w.t("Образцы стиля разработчика (его тексты в Jira):\n", "Samples of the developer's style (their texts in Jira):\n")
                     + String(style.prefix(maxStyle)) + "\n\n") + w.t("Задачи:\n", "Tasks:\n")
        if cands.isEmpty { tasks += w.t("(нет — только новые задачи)\n", "(none — new tasks only)\n") }
        for c in cands {
            var b = "\(c.task.key) — \(clip(90)(c.task.title)) [\(c.task.status.rawValue)]\n"
            if let d = c.description.map(clip(120)), !d.isEmpty { b += w.t("  описание: ", "  description: ") + d + "\n" }
            if !c.comments.isEmpty { b += w.t("  комментарии: ", "  comments: ") + c.comments.map(q).joined(separator: "; ") + "\n" }
            if !c.worklogs.isEmpty { b += w.t("  мои прошлые ворклоги: ", "  my earlier worklogs: ") + c.worklogs.map(q).joined(separator: "; ") + "\n" }
            if tasks.count + b.count > maxTaskBlock + (style.isEmpty ? 0 : maxStyle + 100) { break }
            tasks += b
        }
        var out = instruction(w) + tasks + w.t("\nОтрезки без задачи:\n", "\nStretches without a task:\n"), asked: [String] = []
        for s in segs.sorted(by: { $0.worked > $1.worked }) {
            let f = facts[s.session] ?? Facts()
            var b = "\(s.id) · \(Txt.dur(s.worked)) · \(Txt.clock(s.start))–\(Txt.clock(s.end))"
            if let p = f.project { b += w.t(" · проект ", " · project ") + p }
            if let c = f.cwd { b += w.t(" · папка ", " · folder ") + c }
            if let t = f.title { b += w.t(" · сессия ", " · session ") + q(clip(100)(t)) }
            let inside = { (ts: Timestamp) in ts >= s.start - 120 && ts < s.end }
            let prompts = f.prompts.filter { inside($0.ts) }.prefix(3).map { q(clip(100)($0.text)) }
            if !prompts.isEmpty { b += w.t("\n  запросы: ", "\n  prompts: ") + prompts.joined(separator: "; ") }
            var names: [String] = []
            for x in f.files where inside(x.ts) && !names.contains(Sys.basename(x.path)) { names.append(Sys.basename(x.path)) }
            if !names.isEmpty { b += w.t("\n  файлы: ", "\n  files: ") + names.prefix(8).joined(separator: ", ") }
            let commits = f.commits.filter { $0.ts >= s.start && $0.ts < s.end + 1800 }.prefix(4).map { clip(80)($0.subject) }
            if !commits.isEmpty { b += w.t("\n  коммиты: ", "\n  commits: ") + commits.joined(separator: "; ") }
            b += "\n"
            if out.count + b.count > limit { continue }
            out += b; asked.append(s.id)
        }
        return (out, asked)
    }

    /// The AI's answer: a JSON array of {segment, key, confidence, reason} somewhere in the text. Malformed items, a
    /// segment or key not offered, a confidence under `min` (0…1; 1…100 read as percent) are dropped; the rest per
    /// segment, most confident first (the caller takes the first one it may use).
    static func parse(_ text: String, segments: Set<String>, keys: Set<String>, min: Double)
        -> [(segment: String, key: String, confidence: Double, reason: String, done: String)] {
        var best: [String: (segment: String, key: String, confidence: Double, reason: String, done: String)] = [:]
        for x in answer(text) {
            guard let seg = x["segment"]?.string, segments.contains(seg),
                  let key = x["key"]?.string?.uppercased().split(separator: " ").joined(), keys.contains(key),
                  let c = confidence(x) else { continue }
            guard c >= min, (best[seg + " " + key]?.confidence ?? -1) < c else { continue }
            best[seg + " " + key] = (seg, key, c, clip(80)(x["reason"]?.string ?? ""), clip(300)(x["done"]?.string ?? ""))
        }
        return best.values.sorted { ($0.segment, -$0.confidence, $0.key) < ($1.segment, -$1.confidence, $1.key) }
    }

    /// The JSON array somewhere in the AI's answer (text before it may hold brackets too); empty when there is none.
    static func answer(_ text: String) -> [JValue] {
        guard let b = text.lastIndex(of: "]") else { return [] }
        for a in text.indices where text[a] == "[" && a < b {
            if let v = JValue.parse(String(text[a...b]))?.array { return v }
        }
        return []
    }

    /// 0…1 (1…100 read as percent); nil when missing or out of range.
    static func confidence(_ x: JValue) -> Double? {
        guard let c = x["confidence"]?.double ?? x["confidence"]?.string.flatMap(Double.init), c >= 0, c <= 100 else { return nil }
        return c > 1 ? c / 100 : c
    }

    /// New tasks in the answer: items with a `new` title for an offered segment, one per title (case and spaces aside)
    /// in the order first given, with all its segments; the title is cut to 70 characters, the description to 600, the
    /// worklog text to 300. The caller drops segments a task was found for.
    static func parseNew(_ text: String, segments: Set<String>)
        -> [(segments: [String], title: String, description: String, done: String, confidence: Double)] {
        var out: [(segments: [String], title: String, description: String, done: String, confidence: Double)] = [], seen = Set<String>()
        for x in answer(text) {
            guard let seg = x["segment"]?.string, segments.contains(seg), !seen.contains(seg),
                  let title = x["new"]?.string.map(clip(70)), !title.isEmpty else { continue }
            seen.insert(seg)
            let norm = title.lowercased()
            if let i = out.firstIndex(where: { $0.title.lowercased() == norm }) { out[i].segments.append(seg); continue }
            out.append(([seg], title, Self.lines(x["description"]?.string ?? "", 600), clip(300)(x["done"]?.string ?? ""), confidence(x) ?? 0))
        }
        return out
    }

    /// Lines kept (a description has its structure), each line's spaces squeezed, at most `n` characters.
    static func lines(_ s: String, _ n: Int) -> String {
        let t = s.split(separator: "\n", omittingEmptySubsequences: false).map { clip(10_000)(String($0)) }
            .joined(separator: "\n").trimmed("\n ")
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }

    /// Without AI: the task whose name shares the most words (first 6 letters of words of 4+) with the session's
    /// title, project and folder; 2+ shared words = 0.7, 1 = 0.4, a tie = nothing.
    static func byWords(_ segs: [Segment], _ facts: [String: Facts], _ cands: [Candidate], words w: Words = .ru)
        -> [(seg: Segment, task: Int, confidence: Double, reason: String)] {
        func words(_ s: String) -> [String: String] {
            var out: [String: String] = [:]
            for w in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where w.count >= 4 {
                out[String(w.prefix(6))] = String(w)
            }
            return out
        }
        let tw = cands.map { (task: $0.task.id, words: words($0.task.title)) }
        return segs.compactMap { s in
            let f = facts[s.session] ?? Facts()
            let sw = Set(words([f.title, f.project, f.cwd.map(Sys.basename)].compactMap { $0 }.joined(separator: " ")).keys)
            let scored = tw.map { t in (t, t.words.filter { sw.contains($0.key) }.map(\.value).sorted()) }.filter { !$0.1.isEmpty }
            guard let m = scored.max(by: { $0.1.count < $1.1.count }), scored.filter({ $0.1.count == m.1.count }).count == 1 else { return nil }
            return (s, m.0.task, m.1.count >= 2 ? 0.7 : 0.4, clip(80)(w.t("общие слова: ", "shared words: ") + m.1.joined(separator: ", ")))
        }
    }

    // MARK: bot

    /// The evening message, in `[notify] lang`: the day's suggestions with Yes / No per suggestion (`buttons`: a bot
    /// answers them, else the commands to answer); nil when there are none or `evening` is off.
    public func message(_ day: String, buttons: Bool = true, now: Timestamp = Time.now()) throws -> Message? {
        guard evening else { return nil }
        let r = try suggest(day, now: now)
        guard !r.items.isEmpty || !r.drafts.isEmpty else { return nil }
        let w = words, q = { (s: String) in w.t("«\(s)»", "\"\(s)\"") }
        var lines = ["\(w.date(day)): " + (r.items.isEmpty ? w.t("работа без задачи. Завести новую?", "work without a task. Make a new one?")
                                                           : w.t("работа без ключа задачи. Это она?", "work without a task key. Is it this task?"))]
        for s in r.items {
            lines.append("#\(s.id) \(s.key) — \(w.dur(s.workedSec)), \(w.clock(s.start))–\(w.clock(s.end)), "
                         + q(Self.clip(60)(s.sessionTitle ?? s.project ?? s.sessionId))
                         + (s.reason.isEmpty ? "" : ": \(s.reason)") + " (\(w.pct(s.confidence * 100)))")
        }
        for d in r.drafts { lines.append("#\(d.id) " + w.t("новая задача", "new task") + ": \(q(d.title)) — \(w.dur(d.workedSec))") }
        if !buttons { lines.append(w.t("Ответ: ", "Answer: ") + "zagon task accept <id…> / zagon task reject <id…>") }
        let yes = w.t("Да", "Yes"), no = w.t("Нет", "No"), create = w.t("В Zagon", "To Zagon"), skip = w.t("Не надо", "Skip")
        return Message(title: w.t("Подсказки задач", "Task suggestions"), text: lines.joined(separator: "\n"), buttons: buttons ? r.items.map {
            [.init("\(yes) #\($0.id) \($0.key)", "sg:y:\($0.id):\($0.taskId):\(Int($0.start))"),
             .init("\(no) #\($0.id)", "sg:n:\($0.id):\($0.taskId):\(Int($0.start))")]
        } + r.drafts.map { [.init("\(create) #\($0.id)", "sg:y:\($0.id)"), .init("\(skip) #\($0.id)", "sg:n:\($0.id)")] } : [])
    }

    /// `sg:y|n:<id>:<task>:<start>` buttons (task and start guard against an id reused since), `sg:y|n:N<n>` for a new
    /// task (made in Zagon only); nil for other data.
    public func callback(_ data: String) throws -> Message? {
        let p = data.split(separator: ":")
        if p.count == 3, p[0] == "sg", p[1] == "y" || p[1] == "n", p[2].hasPrefix("N"), Int(p[2].dropFirst()) != nil {
            return Message(title: "", text: p[1] == "y" ? try acceptNew(String(p[2])) : try rejectNew(String(p[2])))
        }
        guard p.count == 5, p[0] == "sg", p[1] == "y" || p[1] == "n", let id = Int(p[2]), let task = Int(p[3]), let start = Int(p[4]) else { return nil }
        let lines = p[1] == "y" ? try accept([id], task: task, start: start) : try reject([id], task: task, start: start)
        return Message(title: "", text: lines.joined(separator: "\n"))
    }
}
