import CSys
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// "What was done" for one local day (`SummaryDoc`): an overview and a card per line of work (project → task or
/// theme: what it was, what was done, what is left, time and price). Written by an AI (`claude -p` on a cheap model,
/// or `codex exec`) from a compact digest that holds no conversation text beyond the first words of typed messages,
/// else made without AI from the same facts (sessions with time and branch, commits, top edited files). One AI call
/// per day: the result is kept in `summary` (and exported); the evening message adds the ribbon.
public struct DaySummary {
    public struct SessionFacts: Sendable {
        public var id: String, tool: String
        public var project: String?, title: String?, cwd: String?, branch: String?
        public var workingSec: Double, waitingSec: Double, tokens: Int, cost = 0.0
        /// Keys of the tasks the session is linked to during the day.
        public var tasks: [String] = []
        /// First words of the first typed messages of the day, and of the last ones.
        public var prompts: [String] = []
        public var lastPrompts: [String] = []
        /// Files written by Edit / Write / MultiEdit / NotebookEdit during the day, most edited first.
        public var files: [String] = []
    }
    public struct Facts: Sendable {
        public var day: String
        public var sessionSec = 0.0, userSec = 0.0, tokens = 0
        public var sessions: [SessionFacts] = []
        /// Repository name → your commit subjects of the day.
        public var commits: [(repo: String, subjects: [String])] = []
        /// Task key → title, for the tasks the sessions are linked to.
        public var tasks: [String: String] = [:]
        public var weekPct: Double?
    }

    public let store: Store
    public var config: NotifyConfig
    public var paths: ZagonPaths
    /// Where Claude Code transcripts live (to find typed messages and edited files of the day).
    public var claudeRoot: String
    public var searchPath: String? = Sys.env("PATH")
    /// Runs a command: (argv, stdin, cwd, timeout) → (status, stdout). Replaced in tests.
    public var runner: ([String], [UInt8], String?, Double) -> (status: Int32, out: [UInt8]) = {
        Sys.capture($0, stdin: $1, cwd: $2, timeout: $3, env: HookSpool.internalEnv)
    }
    public var log: (String) -> Void = { _ in }
    static let maxDigest = 12000

    public init(store: Store, config: NotifyConfig, paths: ZagonPaths, claudeRoot: String) {
        self.store = store; self.config = config; self.paths = paths; self.claudeRoot = claudeRoot
    }

    // MARK: facts

    public func facts(_ day: String, now: Double = Sys.now()) throws -> Facts {
        var f = Facts(day: day)
        let r = try Reports(store: store).day(day)
        f.sessionSec = r.sessionSec; f.userSec = r.userSec; f.tokens = r.tokens.total
        guard let (s, e) = Time.dayBounds(day) else { return f }
        var waiting: [String: Double] = [:]
        try store.db.query("""
            SELECT session_id, sum(min("end", ?2) - max(start, ?1)) FROM activity
            WHERE kind = 'waiting' AND start < ?2 AND "end" > ?1 GROUP BY session_id
            """, [.real(s), .real(e)]) { waiting[$0.text(0) ?? ""] = $0.real(1) }
        for l in r.sessions where l.workingSec > 0 || l.tokens.total > 0 || waiting[l.id] != nil {
            let cwd = try store.db.one("SELECT cwd FROM session WHERE id = ?", [.text(l.id)]) { $0.text(0) } ?? nil
            f.sessions.append(SessionFacts(id: l.id, tool: l.tool, project: l.project, title: l.title, cwd: cwd,
                                           branch: l.gitBranch.flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 },
                                           workingSec: l.workingSec, waitingSec: waiting[l.id] ?? 0, tokens: l.tokens.total,
                                           cost: l.cost))
        }
        f.sessions.sort { ($0.workingSec, $0.tokens) > ($1.workingSec, $1.tokens) }
        let index = Dictionary(uniqueKeysWithValues: f.sessions.enumerated().map { ($1.id, $0) })
        try store.db.query("""
            SELECT ts.session_id, t.key, t.title FROM task_session ts JOIN task t ON t.id = ts.task_id
            WHERE ts.how NOT IN ('unlinked', 'suggested') AND ts.start < ?2 AND ts."end" > ?1 ORDER BY ts.start
            """, [.real(s), .real(e)]) { row in
            guard let i = row.text(0).flatMap({ index[$0] }), let key = row.text(1) else { return }
            if !f.sessions[i].tasks.contains(key) { f.sessions[i].tasks.append(key) }
            f.tasks[key] = row.text(2) ?? ""
        }
        try transcripts(&f, from: s, to: e)
        f.commits = commits(f.sessions.compactMap(\.cwd), day: day)
        if let w = try store.latestLimits().first(where: { $0.tool == .claude && $0.window == "seven_day" }),
           w.resetsAt.map({ $0 > now }) ?? true { f.weekPct = w.usedPct }
        return f
    }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let firstPrompts = 4, lastPrompts = 2

    /// Typed messages (main thread) and edited files (all threads) from the Claude transcripts touched since `from`.
    func transcripts(_ f: inout Facts, from: Double, to: Double) throws {
        let index = Dictionary(uniqueKeysWithValues: f.sessions.enumerated().map { ($1.id, $0) })
        var files: [(path: String, sid: String, agent: String)] = []
        try store.db.query("SELECT path, session_id, agent FROM source_file WHERE tool = 'claude' AND mtime >= ?",
                           [.real(from)]) { r in
            if let p = r.text(0), let sid = r.text(1), index[sid] != nil { files.append((p, sid, r.text(2) ?? "")) }
        }
        var edits: [Int: [String: Int]] = [:], typed: [Int: [String]] = [:]
        for file in files {
            let i = index[file.sid]!
            var parser = file.agent.isEmpty
                ? ClaudeSource.spec(root: claudeRoot, indexPrompts: true).makeParser(file.path, "p/" + Sys.basename(file.path), nil)
                : nil
            Lines.each(file.path) { line in
                if parser != nil && contains(line, "\"type\":\"user\"") {
                    var out = ParseOutput()
                    parser!.parse(line: line, into: &out)
                    for m in out.userMessages where m.ts >= from && m.ts < to {
                        if let t = m.text.map(DaySummary.phrase), !t.isEmpty { typed[i, default: []].append(t) }
                    }
                }
                guard contains(line, "\"tool_use\""), DaySummary.editTools.contains(where: { line.has("\"name\":\"\($0)\"") }),
                      line.count < 8 << 20, let v = JValue.parse(Array(line)),
                      let ts = v["timestamp"]?.string.flatMap(Time.parseISO), ts >= from, ts < to else { return }
                for b in v["message"]?["content"]?.array ?? [] where b["type"]?.string == "tool_use" {
                    guard let name = b["name"]?.string, DaySummary.editTools.contains(name),
                          let p = b["input"]?["file_path"]?.string ?? b["input"]?["notebook_path"]?.string else { continue }
                    edits[i, default: [:]][p, default: 0] += 1
                }
            }
        }
        for (i, counts) in edits { f.sessions[i].files = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key) }
        for (i, all) in typed {
            var seen: [String] = []
            for t in all where !seen.contains(t) { seen.append(t) }
            f.sessions[i].prompts = Array(seen.prefix(DaySummary.firstPrompts))
            f.sessions[i].lastPrompts = Array(seen.dropFirst(DaySummary.firstPrompts).suffix(DaySummary.lastPrompts))
        }
    }

    /// First words of a typed message, on one line, secrets redacted (it goes to the summary table, Telegram and the
    /// AI prompt). Redacted before it is cut, so a cut cannot hide a key from the patterns.
    static func phrase(_ s: String) -> String {
        let t = s.prefix(2000).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if t.hasPrefix("<") || t.hasPrefix("[Request interrupted") { return "" }  // commands, caveats, interrupts
        let c = Redact.clean(t)
        return c.count > 120 ? String(c.prefix(119)) + "…" : c
    }

    /// Your commits of the day in the repositories the sessions worked in.
    func commits(_ cwds: [String], day: String) -> [(repo: String, subjects: [String])] {
        guard let git = Sys.which("git", path: searchPath), let next = Time.addDays(day, 1) else { return [] }
        var seen = Set<String>(), out: [(String, [String])] = []
        for cwd in cwds where Sys.isDir(cwd) {
            let top = runner([git, "-C", cwd, "rev-parse", "--show-toplevel"], [], nil, 5)
            let repo = String(decoding: top.out, as: UTF8.self).trimmingSpaces.split(separator: "\n").first.map(String.init) ?? ""
            guard top.status == 0, !repo.isEmpty, seen.insert(repo).inserted else { continue }
            let email = String(decoding: runner([git, "-C", repo, "config", "user.email"], [], nil, 5).out, as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? ""
            var args = [git, "-C", repo, "log", "--all", "--no-merges", "--format=%s",
                        "--since=\(day) 00:00:00", "--until=\(next) 00:00:00"]
            if !email.isEmpty { args.append("--author=\(email)") }
            let log = runner(args, [], nil, 10)
            let subjects = String(decoding: log.out, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if log.status == 0 && !subjects.isEmpty { out.append((Sys.basename(repo), Array(subjects.prefix(20)))) }
        }
        return out
    }

    // MARK: text

    /// The day in numbers, one line.
    public static func headline(_ f: Facts, _ w: Words) -> String {
        var s = "\(w.date(f.day)). " + w.t("Сессии работали \(w.dur(f.sessionSec)), ты — \(w.dur(f.userSec)). \(w.tokens(f.tokens)) токенов.",
                                          "Sessions worked \(w.dur(f.sessionSec)), you \(w.dur(f.userSec)). \(w.tokens(f.tokens)) tokens.")
        if let p = f.weekPct { s += w.t(" Неделя: ", " Week: ") + w.pct(p) + "." }
        return s
    }

    /// "What was done" without AI: a card per project and task (the rest of a project's sessions in one card) with
    /// its sessions (time, branch), commits and most edited files.
    public static func plain(_ f: Facts, _ w: Words) -> SummaryDoc {
        struct Group { var project: String; var key: String?; var sessions: [SessionFacts] = []; var commits: [String] = [] }
        var groups: [Group] = []
        for s in f.sessions {
            let p = s.project ?? w.tool(s.tool), k = s.tasks.first
            if let i = groups.firstIndex(where: { $0.project == p && $0.key == k }) { groups[i].sessions.append(s) }
            else { groups.append(Group(project: p, key: k, sessions: [s])) }
        }
        var extra: [Group] = []
        for c in f.commits {
            // A commit goes to the card of the task it names, else to the project's first card.
            for subject in c.subjects {
                let mine = groups.indices.filter { groups[$0].project == c.repo }
                if let i = mine.first(where: { groups[$0].key.map { subject.uppercased().contains($0.uppercased()) } ?? false }) ?? mine.first {
                    groups[i].commits.append(subject)
                } else if let i = extra.firstIndex(where: { $0.project == c.repo }) { extra[i].commits.append(subject) }
                else { extra.append(Group(project: c.repo, commits: [subject])) }
            }
        }
        func list(_ xs: [String], _ n: Int, _ sep: String = "; ") -> String {
            xs.prefix(n).joined(separator: sep) + (xs.count > n ? w.t(" и ещё \(xs.count - n)", " and \(xs.count - n) more") : "")
        }
        let items = (groups + extra).map { g -> SummaryDoc.Item in
            var done = g.sessions.prefix(3).map { s in
                w.t("«\(s.title ?? s.prompts.first ?? "без названия")»", "“\(s.title ?? s.prompts.first ?? "untitled")”")
                    + " — \(w.dur(s.workingSec))" + (s.branch.map { w.t(", ветка ", ", branch ") + $0 } ?? "")
            }
            if g.sessions.count > 3 { done.append(w.t("и ещё сессий: \(g.sessions.count - 3)", "\(g.sessions.count - 3) more sessions")) }
            if !g.commits.isEmpty { done.append(w.t("Коммиты", "Commits") + " (\(g.commits.count)): " + list(g.commits, 3)) }
            var files: [String] = []
            for p in g.sessions.flatMap(\.files) where !files.contains(Sys.basename(p)) { files.append(Sys.basename(p)) }
            if !files.isEmpty { done.append(w.t("Файлы", "Files") + " (\(files.count)): " + list(files, 5, ", ")) }
            let title = g.key.flatMap { f.tasks[$0] } ?? g.sessions.first.flatMap { $0.title ?? $0.prompts.first }
                ?? w.t("Коммиты", "Commits")
            return SummaryDoc.Item(project: g.project, key: g.key, title: title, was: g.sessions.first?.prompts.first,
                                   done: done, sec: g.sessions.reduce(0) { $0 + $1.workingSec },
                                   cost: g.sessions.reduce(0) { $0 + $1.cost })
        }
        let commits = f.commits.reduce(0) { $0 + $1.subjects.count }
        let overview = f.sessions.isEmpty && commits == 0 ? w.t("Сессий за день не было.", "No sessions this day.")
            : w.t("Сессии работали \(w.dur(f.sessionSec)), ты — \(w.dur(f.userSec)). Проекты: \(Set(items.map(\.project)).count), сессии: \(f.sessions.count), коммиты: \(commits).",
                  "Sessions worked \(w.dur(f.sessionSec)), you \(w.dur(f.userSec)). Projects: \(Set(items.map(\.project)).count), sessions: \(f.sessions.count), commits: \(commits).")
        return SummaryDoc(lang: w.en ? "en" : "ru", from: f.day, to: f.day, overview: overview, items: items)
    }

    /// Who waited for you longest.
    public static func longestWait(_ f: Facts, _ w: Words) -> String? {
        guard let s = f.sessions.max(by: { $0.waitingSec < $1.waitingSec }), s.waitingSec >= 60 else { return nil }
        return w.t("Дольше всех ждала тебя ", "Waited for you longest: ") + "\(s.project ?? w.name(nil, s.title)) — \(w.dur(s.waitingSec))."
    }

    /// Compact input for the AI, at most `maxDigest` characters: sessions numbered `[1]…` (the cards name them),
    /// their tasks, branches, first words of typed messages, edited files; then the commits.
    public static func digest(_ f: Facts, _ w: Words) -> String {
        var out = headline(f, w) + "\n"
        if !f.tasks.isEmpty {
            out += w.t("Задачи: ", "Tasks: ") + f.tasks.sorted { $0.key < $1.key }.map { "\($0.key) " + w.t("«\($0.value)»", "“\($0.value)”") }
                .joined(separator: "; ") + "\n"
        }
        func quoted(_ xs: [String]) -> String { xs.map { w.t("«\($0)»", "“\($0)”") }.joined(separator: "; ") }
        for (n, s) in f.sessions.enumerated() {
            var b = "\n[\(n + 1)] " + w.t("Проект \(s.project ?? "—") (\(w.tool(s.tool))), сессия «\(s.title ?? "без названия")»",
                                          "Project \(s.project ?? "—") (\(w.tool(s.tool))), session “\(s.title ?? "untitled")”")
            if let br = s.branch { b += w.t(", ветка ", ", branch ") + br }
            if !s.tasks.isEmpty { b += w.t(", задача ", ", task ") + s.tasks.joined(separator: ", ") }
            b += w.t(", работала \(w.dur(s.workingSec)).", ", worked \(w.dur(s.workingSec)).")
            if !s.prompts.isEmpty { b += w.t("\n  Начала запросов: ", "\n  First words of prompts: ") + quoted(s.prompts) }
            if !s.lastPrompts.isEmpty { b += w.t("\n  Последние запросы: ", "\n  Last prompts: ") + quoted(s.lastPrompts) }
            if !s.files.isEmpty { b += w.t("\n  Файлы: ", "\n  Files: ") + s.files.prefix(12).map(Sys.basename).joined(separator: ", ") }
            if out.count + b.count > maxDigest { break }
            out += b
        }
        for c in f.commits {
            let b = w.t("\nКоммиты в ", "\nCommits in ") + "\(c.repo): " + c.subjects.prefix(10).joined(separator: "; ")
            if out.count + b.count > maxDigest { break }
            out += b
        }
        return String(out.prefix(maxDigest))
    }

    static func instruction(_ w: Words) -> String {
        w.t("""
            Ниже выжимка рабочего дня разработчика: проекты, сессии ИИ-агентов с номерами [N], время, ветки, задачи, \
            начала запросов, изменённые файлы, коммиты. Сгруппируй работу по направлениям: проект → задача (если сессии \
            привязаны к задаче, возьми её ключ) или тема. Для каждого направления: что было (с чем пришли, какая проблема, \
            1–2 предложения), что сделано (2–5 коротких пунктов человеческим языком, о сути, а не о файлах), что осталось \
            (только если это видно: незакрытое, «потом», упавшие тесты; иначе пусто), refs — номера его сессий. Сверху \
            итог дня в 2–3 строки. Пиши по-русски. Не добавляй того, чего нет в выжимке. Ответь только JSON без \
            пояснений, по образцу:
            \(SummaryDoc.answerShape(w, period: false))

            Выжимка:

            """, """
            Below is a digest of a developer's working day: projects, AI agent sessions numbered [N], time, branches, \
            tasks, first words of prompts, changed files, commits. Group the work into lines: project → task (use its key \
            when the sessions are linked to one) or theme. For each line: what it was (the ask or the problem, 1-2 \
            sentences), what was done (2-5 short points in plain words, about the substance rather than files), what is \
            left (only when it shows: unfinished work, "later", failing tests; else empty), refs — the numbers of its \
            sessions. On top, the day in 2-3 lines. Write in English. Do not add anything that is not in the digest. \
            Answer with JSON only, no comments, shaped like:
            \(SummaryDoc.answerShape(w, period: false))

            Digest:

            """)
    }

    /// The wording of `config.lang`.
    var words: Words { config.lang.words() }

    /// The AI's cards for the day's facts; nil when the engine is off, missing, failed, timed out or answered
    /// something unreadable. Sessions no card named and that have no card of their project get a plain one (from 5
    /// minutes of work).
    public func ai(_ f: Facts) -> (doc: SummaryDoc, engine: String)? {
        let w = words
        guard !f.sessions.isEmpty, let r = complete(DaySummary.instruction(w) + DaySummary.digest(f, w)) else { return nil }
        let refs = f.sessions.map { SummaryDoc.Ref(project: $0.project ?? w.tool($0.tool), sec: $0.workingSec, cost: $0.cost) }
        guard var (doc, unused) = SummaryDoc.parse(answer: r.text, refs: refs, tasks: f.tasks, lang: w.en ? "en" : "ru",
                                                   from: f.day, to: f.day) else {
            log("summary: the \(r.engine) answer has no cards"); return nil
        }
        if !unused.isEmpty {
            var rest = f
            // Short ones (a look, a quick question) would only add empty cards.
            rest.sessions = unused.map { f.sessions[$0] }.filter { $0.workingSec >= 300 }; rest.commits = []
            doc.items += DaySummary.plain(rest, w).items
        }
        return (doc, r.engine)
    }

    /// One prompt to the configured engine (the summary's: engine, model, timeout), without the user's config, hooks
    /// or tools; `result` is claude's JSON answer (usage, cost, time), nil for codex. `what` names it in the log.
    public func complete(_ text: String, what: String = "summary") -> (text: String, engine: String, result: JValue?)? {
        let prompt = Array(text.utf8)
        // A user service runs with systemd's PATH: the CLIs' own install places come after it.
        let searchPath = ([searchPath] + [".local/bin", ".claude/local", ".npm-global/bin"].map { paths.home + "/" + $0 }
                          + ["/usr/local/bin", "/opt/homebrew/bin"]).compactMap { $0 }.joined(separator: ":")
        let run = paths.dir + "/run"
        Sys.mkdirs(run)
        switch config.summaryEngine {
        case "claude":
            guard let claude = Sys.which("claude", path: searchPath) else { log("\(what): claude CLI not found"); return nil }
            // --safe-mode: no CLAUDE.md, hooks, plugins, MCP servers or skills of the user; auth works as usual.
            let r = runner([claude, "-p", "--safe-mode", "--model", config.summaryModel, "--tools", "", "--max-turns", "1",
                            "--no-session-persistence", "--output-format", "json"], prompt, run, config.summaryTimeout)
            guard r.status == 0, let v = JValue.parse(r.out), v["is_error"] != .bool(true),
                  let text = v["result"]?.string?.trimmingSpaces, !text.isEmpty else {
                log("\(what): claude failed (\(r.status))"); return nil
            }
            return (String(text), "claude", v)
        case "codex":
            guard let codex = Sys.which("codex", path: searchPath) else { log("\(what): codex CLI not found"); return nil }
            let file = run + "/\(what)-\(Int(Sys.now())).txt"
            defer { Sys.remove(file) }
            // Without the user's config.toml and hooks.
            let r = runner([codex, "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                            "-c", "features.hooks=false", "-o", file, "-"], prompt, run,
                           config.summaryTimeout)
            guard r.status == 0, let out = Sys.readFile(file), !String(decoding: out, as: UTF8.self).trimmingSpaces.isEmpty else {
                log("\(what): codex failed (\(r.status))"); return nil
            }
            return (String(String(decoding: out, as: UTF8.self).trimmingSpaces), "codex", nil)
        default: return nil
        }
    }

    // MARK: kept summaries

    /// A summary as kept: the doc, the engine that wrote it (`none` = without AI) and when.
    public struct Kept: Sendable {
        public var doc: SummaryDoc, engine: String, created: Double
    }

    /// The kept summary of a day or a range key (`SummaryDoc.key`): one written by an AI over one made without,
    /// the newest of each; free text from before counts as none.
    public func kept(_ key: String) throws -> Kept? {
        var out: Kept?
        try store.db.query("SELECT engine, text, created FROM summary WHERE day = ? ORDER BY engine = 'none', created DESC",
                           [.text(key)]) { r in
            if out == nil, let d = SummaryDoc.decode(r.text(1) ?? "") { out = Kept(doc: d, engine: r.text(0) ?? "", created: r.real(2)) }
        }
        return out
    }

    /// Keeps a summary under its key with a new change number (`meta` `summary_seq:<key>`), so `export` sends it.
    func save(_ doc: SummaryDoc, engine: String, now: Double) throws {
        try store.db.transaction {
            try store.db.run("INSERT OR REPLACE INTO summary(day, engine, text, created) VALUES(?, ?, ?, ?)",
                             [.text(doc.key), .text(engine), .text(doc.json), .real(now)])
            let seq = try store.nextSeq()
            try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text("summary_seq:" + doc.key), .int(Int64(seq))])
        }
    }

    /// Builds the summary of `day` (one AI call, else without AI), keeps it and, for the cards of known tasks, sets
    /// the task's "what was done" of the day (`auto`; a text set by hand stays first).
    @discardableResult
    public func make(_ day: String, now: Double = Sys.now()) throws -> (facts: Facts, doc: SummaryDoc, engine: String) {
        let f = try facts(day, now: now)
        var doc = DaySummary.plain(f, words), engine = "none"
        if let r = ai(f) { (doc, engine) = r }
        try save(doc, engine: engine, now: now)
        if engine != "none" {
            let tasks = Tasks(store: store)
            for i in doc.items {
                guard let key = i.key, let t = try tasks.find(key) else { continue }
                try tasks.setDone(t.id, day: day, text: doc.taskText(i), source: "auto")
            }
        }
        return (f, doc, engine)
    }

    /// The evening message: numbers, what was done, who waited longest, and the ribbon.
    public func message(_ day: String, now: Double = Sys.now()) throws -> Message {
        let (f, doc, _) = try make(day, now: now)
        let w = words
        var body = DaySummary.headline(f, w) + "\n\n" + doc.text()
        if let l = DaySummary.longestWait(f, w) { body += "\n\n" + l }
        return Message(title: w.t("Сводка дня", "Day summary"), text: body, photo: try ribbon(f),
                       buttons: [[.init(w.t("Подробнее", "Details"), "day:\(day)")]])
    }

    /// The day's summary at `[summary] time` when no notifier sends it (no channel, notifications off): once a day,
    /// remembered in `meta` (`summary_auto:<day>`). Returns whether it wrote one.
    @discardableResult
    public func autoTick(now: Double = Sys.now()) throws -> Bool {
        guard let at = config.summaryAt, Notifier.localMinute(now) >= at else { return false }
        let day = Time.dayString(now), mark = "summary_auto:" + day
        if try store.db.one("SELECT 1 FROM meta WHERE key = ?", [.text(mark)], { _ in true }) == true { return false }
        try make(day, now: now)
        try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, 1)", [.text(mark)])
        return true
    }

    // MARK: ribbon

    /// The day's PNG: top sessions by working time (numbered as in the summary order), then your time.
    public func ribbon(_ f: Facts) throws -> [UInt8] {
        guard let (s, e) = Time.dayBounds(f.day) else { return [] }
        var rows: [[Timeline.Span]] = []
        for sf in f.sessions.prefix(Timeline.maxRows - 1) {
            var row: [Timeline.Span] = []
            try store.db.query("""
                SELECT start, "end", kind FROM activity WHERE session_id = ? AND start < ? AND "end" > ? AND kind IN ('working', 'waiting')
                """, [.text(sf.id), .real(e), .real(s)]) {
                row.append(Timeline.Span($0.real(0), $0.real(1), $0.text(2) == "waiting" ? .waiting : .working))
            }
            if !row.isEmpty { rows.append(row) }
        }
        var mine: [Timeline.Span] = []
        try store.db.query("SELECT start, \"end\" FROM user_activity WHERE start < ? AND \"end\" > ?", [.real(e), .real(s)]) {
            mine.append(Timeline.Span($0.real(0), $0.real(1), .user))
        }
        if !mine.isEmpty { rows.append(mine) }
        let all = rows.flatMap { $0 }
        var from = s + 8 * 3600, to = s + 20 * 3600
        if let lo = all.map(\.start).min(), let hi = all.map(\.end).max() {
            from = max(s, ((lo - s) / 3600).rounded(.down) * 3600 + s)
            to = min(e, ((hi - s) / 3600).rounded(.up) * 3600 + s)
            if to - from < 4 * 3600 { to = min(e, from + 4 * 3600) }
        }
        return Timeline.png(rows: rows, from: from, to: to)
    }
}

/// Line-by-line reading of a file with a fixed buffer.
enum Lines {
    /// Complete lines from byte `offset` on; returns the offset after the last complete line (a partial last line is
    /// left for the next call).
    @discardableResult
    static func each(_ path: String, from offset: Int = 0, _ body: (UnsafeRawBufferPointer) -> Void) -> Int {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return offset }
        defer { close(fd) }
        guard offset == 0 || lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else { return offset }
        var done = offset
        var buf: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 1 << 18)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            var start = 0
            buf.withUnsafeBytes { b in
                while let nl = b[start...].firstIndex(of: 0x0A) {
                    body(UnsafeRawBufferPointer(rebasing: b[start..<nl]))
                    start = nl + 1
                }
            }
            done += start
            buf.removeFirst(start)
        }
        return done
    }
}

extension UnsafeRawBufferPointer {
    func has(_ s: String) -> Bool {
        var s = s
        return s.withUTF8 { n in count >= n.count && z_memmem(baseAddress, count, n.baseAddress, n.count) != nil }
    }
}
