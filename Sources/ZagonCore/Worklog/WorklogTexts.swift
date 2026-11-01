/// The texts of a day's worklog plan, kept in `meta` apart from the plan rows (which are planned again and again):
/// a short text per row, by task, day and row start (`wltext:<source>:<day>:<task>:<start>`), and the day's summary
/// per task (`wlsum:<source>:<day>:<task>`); source `auto` (built by an AI) or `manual` (set by hand, never replaced
/// by a rebuild). `wltext_built:<day>` is when the day's texts were last built.
public struct WorklogTexts {
    public let store: Store
    var db: SQLite { store.db }
    public init(store: Store) { self.store = store }

    static func rowKey(_ source: String, _ day: String, _ task: Int, _ start: Timestamp) -> String {
        "wltext:\(source):\(day):\(task):\(Int64(start.rounded()))"
    }
    static func sumKey(_ source: String, _ day: String, _ task: Int) -> String { "wlsum:\(source):\(day):\(task)" }
    static func builtKey(_ day: String) -> String { "wltext_built:\(day)" }

    func get(_ key: String) throws -> String? {
        try db.one("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.text(0) } ?? nil
    }

    /// Sets (nil: removes) a kept value.
    func put(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2", [.text(key), .text(value)])
        } else { try db.run("DELETE FROM meta WHERE key = ?", [.text(key)]) }
    }

    /// A kept row text: the one at the row's start, else one whose start is inside the row (the row grew earlier),
    /// else one inside none of the task's rows (`siblings`) whose nearest row this is (the row moved).
    func row(_ source: String, _ day: String, _ task: Int, _ start: Timestamp, _ end: Timestamp, siblings: [Interval] = []) throws -> String? {
        if let t = try get(Self.rowKey(source, day, task, start)) { return t }
        let prefix = "wltext:\(source):\(day):\(task):"
        var kept: [(start: Timestamp, text: String)] = []
        try db.query("SELECT key, value FROM meta WHERE key >= ?1 AND key < ?2 ORDER BY key", [.text(prefix), .text(prefix + "\u{7F}")]) { r in
            if let s = r.text(0).flatMap({ Double($0.dropFirst(prefix.count)) }), let t = r.text(1) { kept.append((s, t)) }
        }
        if let k = kept.first(where: { $0.start >= start && $0.start < end }) { return k.text }
        func distance(_ iv: Interval, _ t: Timestamp) -> Double { t < iv.start ? iv.start - t : t >= iv.end ? t - iv.end : 0 }
        let mine = Interval(start, end)
        return kept.first { k in
            !siblings.contains { k.start >= $0.start && k.start < $0.end }
                && (siblings.min { distance($0, k.start) < distance($1, k.start) }.map { $0.start == start && $0.end == end } ?? true)
                && distance(mine, k.start) < 12 * 3600
        }?.text
    }

    /// The row's text and where it came from: set by hand, else built, else the task's "what was done" of the day
    /// (`manual` or `summary`), else `fallback` (its sessions' titles).
    public func rowText(day: String, task: Int, start: Timestamp, end: Timestamp, siblings: [Interval] = [],
                        fallback: () throws -> String) throws -> (text: String, source: String) {
        if let t = try row("manual", day, task, start, end, siblings: siblings), !t.isEmpty { return (t, "manual") }
        if let t = try row("auto", day, task, start, end, siblings: siblings), !t.isEmpty { return (t, "summary") }
        if let (t, s) = try db.one("SELECT text, source FROM task_done WHERE task_id = ? AND day = ? ORDER BY source = 'manual' DESC",
                                   [.int(Int64(task)), .text(day)], { ($0.text(0) ?? "", $0.text(1) ?? "") }), !t.isEmpty {
            return (t, s == "manual" ? "manual" : "summary")
        }
        return (try fallback(), "titles")
    }

    /// The task's summary of the day: set by hand, else built; nil when there is none.
    public func summary(day: String, task: Int) throws -> (text: String, source: String)? {
        if let t = try get(Self.sumKey("manual", day, task)), !t.isEmpty { return (t, "manual") }
        if let t = try get(Self.sumKey("auto", day, task)), !t.isEmpty { return (t, "summary") }
        return nil
    }

    public func builtAt(_ day: String) throws -> Timestamp? {
        try db.one("SELECT value FROM meta WHERE key = ?", [.text(Self.builtKey(day))]) { $0.optReal(0) } ?? nil
    }

    /// Sets a row's text by hand (nil: drops it, the row goes back to the built one).
    public func setManual(day: String, task: Int, start: Timestamp, text: String?) throws {
        try put(Self.rowKey("manual", day, task, start), text.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func setManualSummary(day: String, task: Int, text: String?) throws {
        try put(Self.sumKey("manual", day, task), text.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Keeps what a build made and when; a row or task the answer left out keeps its earlier built text.
    func saveBuilt(day: String, rows: [(task: Int, start: Timestamp, text: String)], summaries: [Int: String], now: Timestamp) throws {
        try db.transaction {
            for r in rows { try put(Self.rowKey("auto", day, r.task, r.start), r.text) }
            for (t, s) in summaries { try put(Self.sumKey("auto", day, t), s) }
            try db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2", [.text(Self.builtKey(day)), .real(now)])
        }
    }

    /// The day summary as one text with its section titles (empty sections left out).
    public static func summaryText(was: String, found: String, done: String, _ w: Words) -> String {
        [(w.t("Что было в задаче", "What the task was"), was), (w.t("Что найдено при проверке", "What the check found"), found),
         (w.t("Что сделано", "What was done"), done)]
            .filter { !$0.1.trimmed(" \n").isEmpty }.map { "\($0.0)\n\($0.1.trimmed(" \n"))" }.joined(separator: "\n\n")
    }

    /// First line of the day-summary comment on a Jira issue; a comment that starts with it (in either language) is
    /// that day's, so it is written once.
    public static func commentHeader(_ day: String, _ w: Words) -> String { w.t("Итог дня — ", "Day summary — ") + day }
    static func isCommentOf(_ body: String, day: String) -> Bool {
        let first = body.split(separator: "\n", maxSplits: 1).first.map { String($0).trimmed(" \r") } ?? ""
        return first == commentHeader(day, .ru) || first == commentHeader(day, .english)
    }
}

/// Builds a day's worklog texts with one AI call: for each plan row 1–2 sentences about its stretch, for each task the
/// day's summary (what the task was, what the check found, what was done). The input holds, per row, its sessions'
/// first words of typed messages, short last answers and `ГОТОВО:` / `DONE:` lines inside the row's time, and the
/// task's commits of the day; at most `maxDigest` characters.
public struct WorklogTextBuilder {
    /// The AI engine and its settings (`[summary]`), the language (`[notify] lang`) and where transcripts are.
    public var engine: DaySummary
    public var log: (String) -> Void = { _ in }
    static let maxDigest = 16000

    public init(engine: DaySummary) { self.engine = engine }
    var store: Store { engine.store }
    var words: Words { engine.config.lang.words() }

    public struct RowInput: Sendable {
        public var id: Int, task: Int, start: Timestamp, end: Timestamp
        public var sessions: [RowSession]
        public init(id: Int, task: Int, start: Timestamp, end: Timestamp, sessions: [RowSession]) {
            self.id = id; self.task = task; self.start = start; self.end = end; self.sessions = sessions
        }
    }
    public struct TaskInput: Sendable {
        public var id: Int, key: String, title: String
        public var rows: [RowInput]
        public init(id: Int, key: String, title: String, rows: [RowInput]) { self.id = id; self.key = key; self.title = title; self.rows = rows }
    }

    /// What a session said in the day: typed messages (`prompt`), the assistant's texts (`reply`) and report lines (`done`).
    struct Said { enum Kind { case prompt, reply, done }; var ts: Timestamp; var kind: Kind; var text: String }

    /// The whole day: texts for all `tasks`' rows and the summaries (when `summaries`). nil = the engine is off or failed
    /// (the plan keeps its other texts).
    @discardableResult
    public func build(day: String, tasks: [TaskInput], summaries: Bool, now: Timestamp = Time.now()) throws -> Int? {
        guard !tasks.isEmpty, let (from, to) = Time.dayBounds(day) else { return nil }
        let said = try self.said(Set(tasks.flatMap { $0.rows.flatMap { $0.sessions.map(\.id) } }), from: from, to: to)
        let w = words
        let prompt = Self.instruction(w, summaries: summaries) + digest(day: day, tasks, said: said)
        guard var got = ask(prompt) else { return nil }
        if got.hasMeta {
            log("worklog texts: the answer talks about its input, asking once more")
            if let again = ask(prompt + "\n\n" + Self.noMeta(w)) { got = again }
            got.dropMeta()
        }
        let ids = Dictionary(tasks.flatMap { t in t.rows.map { ($0.id, (t.id, $0.start)) } }, uniquingKeysWith: { a, _ in a })
        let rows = got.rows.compactMap { id, text in ids[id].map { (task: $0.0, start: $0.1, text: text) } }
        var sums: [Int: String] = [:]
        if summaries {
            for t in tasks { if let s = got.tasks[t.key], !s.isEmpty { sums[t.id] = s } }
        }
        try WorklogTexts(store: store).saveBuilt(day: day, rows: rows, summaries: sums, now: now)
        return rows.count
    }

    /// One row again (its text, or with `summary` its task's summary); `shorten` makes `current` shorter instead.
    /// Returns the new text, nil when the engine gave nothing usable.
    public func rebuild(day: String, task: TaskInput, row: RowInput, summary: Bool, shorten current: String?) throws -> String? {
        guard let (from, to) = Time.dayBounds(day) else { return nil }
        let w = words
        let prompt: String
        if let current {
            prompt = w.t(summary
                ? "Сократи итог дня по задаче примерно вдвое: те же разделы с теми же заголовками, суть и цифры сохрани, без вводных слов. Ответь только текстом.\n\n"
                : "Сократи текст ворклога до одной короткой фразы о сути работы. Ответь только текстом.\n\n",
                summary
                ? "Shorten this day summary of a task by about half: the same sections with the same titles, keep the substance and figures. Answer with the text only.\n\n"
                : "Shorten this worklog text to one short sentence about the substance of the work. Answer with the text only.\n\n") + current
        } else {
            let said = try self.said(Set(task.rows.flatMap { $0.sessions.map(\.id) }), from: from, to: to)
            let one = TaskInput(id: task.id, key: task.key, title: task.title, rows: summary ? task.rows : [row])
            prompt = Self.instruction(w, summaries: summary) + digest(day: day, [one], said: said)
        }
        guard let r = engine.complete(prompt, what: "worklog text") else { return nil }
        var text: String
        if current != nil { text = Self.clean(r.text) }
        else {
            guard let got = Answer.parse(r.text, w) else { return nil }
            text = summary ? got.tasks[task.key] ?? "" : got.rows[row.id] ?? ""
        }
        guard !text.isEmpty, !Answer.isMeta(text) else { return nil }
        if text.count > 4000 { text = String(text.prefix(3999)) + "…" }
        return text
    }

    func ask(_ prompt: String) -> Answer? {
        guard let r = engine.complete(prompt, what: "worklog texts") else { return nil }
        guard let a = Answer.parse(r.text, words) else { log("worklog texts: the \(r.engine) answer has no texts"); return nil }
        return a
    }

    /// The AI's answer: `{"rows": {"12": "…"}, "tasks": {"PROJ-1": {"was": "…", "found": "…", "done": "…"}}}`.
    struct Answer {
        var rows: [Int: String] = [:]
        var tasks: [String: String] = [:]

        static func parse(_ text: String, _ w: Words) -> Answer? {
            guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
                  let v = JValue.parse(String(text[a...b])) else { return nil }
            var out = Answer()
            if case .object(let m)? = v["rows"] {
                for x in m { if let id = Int(x.key), let t = x.value.string.map(WorklogTextBuilder.clean), !t.isEmpty { out.rows[id] = t } }
            }
            if case .object(let m)? = v["tasks"] {
                for x in m {
                    func f(_ k: String) -> String { WorklogTextBuilder.clean(x.value[k]?.string ?? "") }
                    let s = WorklogTexts.summaryText(was: f("was"), found: f("found"), done: f("done"), w)
                    if !s.isEmpty { out.tasks[x.key.uppercased()] = s }
                }
            }
            return out.rows.isEmpty && out.tasks.isEmpty ? nil : out
        }

        var hasMeta: Bool { rows.values.contains(where: Answer.isMeta) || tasks.values.contains(where: Answer.isMeta) }
        mutating func dropMeta() { rows = rows.filter { !Answer.isMeta($0.value) }; tasks = tasks.filter { !Answer.isMeta($0.value) } }

        /// Phrases about the input rather than the work ("the digest has no results", "not visible in the session").
        static let metaPhrases = ["выжимк", "не видно", "итогов нет", "итоги не", "нет итогов", "в сессии не", "из сессии не",
                                  "по сессии не", "the digest", "in the digest", "not visible", "no results", "no information about",
                                  "not shown in", "the session does not"]
        static func isMeta(_ s: String) -> Bool { let l = s.lowercased(); return metaPhrases.contains { l.contains($0) } }
    }

    /// Trimmed, with home and system paths cut to their last part (`~/x/y.md` → `y.md`).
    static func clean(_ s: String) -> String {
        var out = s.trimmed(" \n\t\r")
        if out.hasPrefix("```") { out = out.split(separator: "\n").filter { !$0.hasPrefix("```") }.joined(separator: "\n") }
        return out.replacing(pathPattern) { m in m.output[1].substring.map(String.init) ?? "" }
    }

    nonisolated(unsafe) static let pathPattern = try! Regex(#"(?:~|/root|/home/[^\s/]+|/Users/[^\s/]+)(?:/[^\s/«»"',;:()]+)*/([^\s/«»"',;:()]+)"#)

    static func instruction(_ w: Words, summaries: Bool) -> String {
        w.t("""
            Ниже — рабочий день разработчика по строкам ворклога в Jira: задача, строка (номер, время), что в это время \
            писал пользователь, что отвечал исполнитель и строки отчётов. Для каждой строки напиши 1–2 фразы о том, что \
            делалось в её отрезке: суть работы и результат, человеческим языком.\(summaries ? """
             Для каждой задачи напиши итог дня тремя разделами: was — что было в задаче (с чем пришли, какая проблема, \
            1–3 предложения), found — что найдено при проверке (факты, цифры, выводы; если нечего, пусто), done — что \
            сделано за день (коротко, можно пунктами через «- »).
            """ : "") Пиши по-русски, только о работе. Не упоминай людей по именам, пути к файлам, ИИ, агентов, сессии, \
            эту выжимку и нехватку данных: если о строке известно мало, опиши то, что известно. Ответь только JSON без \
            пояснений: {"rows": {"<номер строки>": "<текст>"}\(summaries ? ", \"tasks\": {\"<ключ задачи>\": {\"was\": \"…\", \"found\": \"…\", \"done\": \"…\"}}" : "")}

            """, """
            Below is a developer's working day by Jira worklog rows: the task, the row (number, time), what the user wrote \
            then, what the agent answered and report lines. For each row write 1-2 sentences about what was done in its \
            stretch: the substance of the work and the result, in plain words.\(summaries ? """
             For each task write the day's summary in three sections: was — what the task was (the ask or the problem, \
            1-3 sentences), found — what the check found (facts, figures, conclusions; empty if nothing), done — what was \
            done that day (short, may be points starting with "- ").
            """ : "") Write in English, only about the work. Do not name people, file paths, AI, agents, sessions, this \
            digest or missing data: if little is known about a row, describe what is known. Answer with JSON only: \
            {"rows": {"<row number>": "<text>"}\(summaries ? ", \"tasks\": {\"<task key>\": {\"was\": \"…\", \"found\": \"…\", \"done\": \"…\"}}" : "")}

            """)
    }

    static func noMeta(_ w: Words) -> String {
        w.t("В прошлом ответе были фразы о выжимке или о нехватке данных. Так писать нельзя: только о самой работе.",
            "The last answer talked about the digest or missing data. Do not: write only about the work itself.")
    }

    /// The input: per task its rows, per row its sessions' words inside the row's time; then the task's commits.
    /// Cut to `maxDigest` with fewer words per session if needed; every row is named either way.
    func digest(day: String, _ tasks: [TaskInput], said: [String: [Said]]) -> String {
        var cwds = Set<String>()
        for id in Set(tasks.flatMap { $0.rows.flatMap { $0.sessions.map(\.id) } }) {
            if let c = (try? store.db.one("SELECT cwd FROM session WHERE id = ?", [.text(id)]) { $0.text(0) }) ?? nil { cwds.insert(c) }
        }
        let commits = engine.commits(cwds.sorted(), day: day)
        for (prompts, replies, len) in [(3, 2, 300), (2, 1, 160), (1, 1, 100)] {
            let d = digest(tasks, said: said, commits: commits, prompts: prompts, replies: replies, len: len)
            if d.count <= Self.maxDigest || len == 100 { return String(d.prefix(Self.maxDigest)) }
        }
        return ""
    }

    func digest(_ tasks: [TaskInput], said: [String: [Said]], commits: [(repo: String, subjects: [String])],
                prompts: Int, replies: Int, len: Int) -> String {
        let w = words
        func cut(_ s: String) -> String { Txt.oneLine(s, len) }
        func q(_ xs: [String]) -> String { xs.map { w.t("«\(cut($0))»", "“\(cut($0))”") }.joined(separator: "; ") }
        var out = ""
        for t in tasks {
            out += w.t("Задача \(t.key) «\(t.title)»\n", "Task \(t.key) “\(t.title)”\n")
            for r in t.rows {
                out += w.t("  Строка \(r.id): ", "  Row \(r.id): ") + "\(Txt.clock(r.start))–\(Txt.clock(r.end)) (\(w.dur(r.end - r.start)))\n"
                for s in r.sessions.prefix(4) {
                    let in_ = (said[s.id] ?? []).filter { $0.ts >= r.start && $0.ts < r.end }
                    let p = in_.filter { $0.kind == .prompt }.prefix(prompts).map(\.text)
                    let a = in_.filter { $0.kind == .reply }.suffix(replies).map(\.text)
                    let d = in_.filter { $0.kind == .done }.suffix(2).map(\.text)
                    guard !p.isEmpty || !a.isEmpty || !d.isEmpty else { continue }
                    out += "    [\(s.title ?? "—"), \(s.role)]"
                    if !p.isEmpty { out += w.t(" писал: ", " wrote: ") + q(p) }
                    if !a.isEmpty { out += w.t(" ответ: ", " answer: ") + q(a) }
                    if !d.isEmpty { out += w.t(" отчёт: ", " report: ") + q(d) }
                    out += "\n"
                }
            }
            let mine = commits.flatMap { c in c.subjects.filter { DaySummary.mentions($0, t.key) } }
            if !mine.isEmpty { out += w.t("  Коммиты: ", "  Commits: ") + mine.prefix(8).joined(separator: "; ") + "\n" }
        }
        return out
    }

    /// Typed messages, the assistant's texts and report lines of the sessions' main Claude transcripts in [from, to).
    /// ponytail: Claude transcripts only; Codex sessions give the AI their titles alone.
    func said(_ sessions: Set<String>, from: Timestamp, to: Timestamp) throws -> [String: [Said]] {
        var files: [(path: String, sid: String)] = []
        try store.db.query("SELECT path, session_id FROM source_file WHERE tool = 'claude' AND agent = '' AND mtime >= ?", [.real(from)]) { r in
            if let p = r.text(0), let sid = r.text(1), sessions.contains(sid) { files.append((p, sid)) }
        }
        var out: [String: [Said]] = [:]
        func done(_ s: String, _ ts: Timestamp, _ sid: String) {
            for l in s.split(separator: "\n") {
                guard let r = l.firstRange(of: "ГОТОВО:") ?? l.firstRange(of: "DONE:") else { continue }
                let t = Redact.clean(String(l[r.lowerBound...]))
                if !t.isEmpty { out[sid, default: []].append(Said(ts: ts, kind: .done, text: t)) }
            }
        }
        for f in files {
            var parser: (any LineParser)? = ClaudeSource.spec(root: engine.claudeRoot, indexPrompts: true).makeParser(f.path, "p/" + Sys.basename(f.path), nil)
            Lines.each(f.path) { line in
                if contains(line, "\"type\":\"user\"") && !contains(line, "\"tool_result\"") {
                    var o = ParseOutput()
                    parser!.parse(line: line, into: &o)
                    for m in o.userMessages where m.ts >= from && m.ts < to {
                        if let t = m.text.map(DaySummary.phrase), !t.isEmpty { out[f.sid, default: []].append(Said(ts: m.ts, kind: .prompt, text: t)) }
                    }
                    return
                }
                guard contains(line, "\"type\":\"assistant\""), line.count < 4 << 20, let v = JValue.parse(Array(line)),
                      let ts = v["timestamp"]?.string.flatMap(Time.parseISO), ts >= from, ts < to else { return }
                for b in v["message"]?["content"]?.array ?? [] {
                    if b["type"]?.string == "text", let t = b["text"]?.string {
                        let one = Redact.clean(t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
                        if one.count >= 20 { out[f.sid, default: []].append(Said(ts: ts, kind: .reply, text: String(one.suffix(600)))) }
                        done(t, ts, f.sid)
                    } else if b["type"]?.string == "tool_use", let i = b["input"] {
                        for k in ["command", "content", "new_string"] { if let s = i[k]?.string, s.count < 1 << 16 { done(s, ts, f.sid) } }
                    }
                }
            }
            parser = nil
        }
        for k in out.keys { out[k]!.sort { $0.ts < $1.ts } }
        return out
    }
}
