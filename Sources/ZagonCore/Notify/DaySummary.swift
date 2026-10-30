import CSys
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// "What was done" for one local day: plain (titles, projects, time, edited files, commits) or written by an AI
/// (`claude -p` on a cheap model, or `codex exec`) from a compact digest that holds no conversation text beyond
/// the first words of typed messages. The result goes to the `summary` table; the evening message adds the ribbon.
public struct DaySummary {
    public struct SessionFacts: Sendable {
        public var id: String, tool: String
        public var project: String?, title: String?, cwd: String?
        public var workingSec: Double, waitingSec: Double, tokens: Int
        /// First words of the first typed messages of the day.
        public var prompts: [String] = []
        /// Files written by Edit / Write / MultiEdit / NotebookEdit during the day.
        public var files: [String] = []
    }
    public struct Facts: Sendable {
        public var day: String
        public var sessionSec = 0.0, userSec = 0.0, tokens = 0
        public var sessions: [SessionFacts] = []
        /// Repository name → your commit subjects of the day.
        public var commits: [(repo: String, subjects: [String])] = []
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
    static let maxDigest = 6000

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
                                           workingSec: l.workingSec, waitingSec: waiting[l.id] ?? 0, tokens: l.tokens.total))
        }
        f.sessions.sort { ($0.workingSec, $0.tokens) > ($1.workingSec, $1.tokens) }
        try transcripts(&f, from: s, to: e)
        f.commits = commits(f.sessions.compactMap(\.cwd), day: day)
        if let w = try store.latestLimits().first(where: { $0.tool == .claude && $0.window == "seven_day" }),
           w.resetsAt.map({ $0 > now }) ?? true { f.weekPct = w.usedPct }
        return f
    }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Typed messages (main thread) and edited files (all threads) from the Claude transcripts touched since `from`.
    func transcripts(_ f: inout Facts, from: Double, to: Double) throws {
        let index = Dictionary(uniqueKeysWithValues: f.sessions.enumerated().map { ($1.id, $0) })
        var files: [(path: String, sid: String, agent: String)] = []
        try store.db.query("SELECT path, session_id, agent FROM source_file WHERE tool = 'claude' AND mtime >= ?",
                           [.real(from)]) { r in
            if let p = r.text(0), let sid = r.text(1), index[sid] != nil { files.append((p, sid, r.text(2) ?? "")) }
        }
        for file in files {
            let i = index[file.sid]!
            var parser = file.agent.isEmpty
                ? ClaudeSource.spec(root: claudeRoot, indexPrompts: true).makeParser(file.path, "p/" + Sys.basename(file.path), nil)
                : nil
            var edited: [String] = []
            Lines.each(file.path) { line in
                if parser != nil && f.sessions[i].prompts.count < 3 && contains(line, "\"type\":\"user\"") {
                    var out = ParseOutput()
                    parser!.parse(line: line, into: &out)
                    for m in out.userMessages where m.ts >= from && m.ts < to {
                        guard let t = m.text.map(DaySummary.phrase), !t.isEmpty, f.sessions[i].prompts.count < 3 else { continue }
                        f.sessions[i].prompts.append(t)
                    }
                }
                guard contains(line, "\"tool_use\""), DaySummary.editTools.contains(where: { line.has("\"name\":\"\($0)\"") }),
                      line.count < 8 << 20, let v = JValue.parse(Array(line)),
                      let ts = v["timestamp"]?.string.flatMap(Time.parseISO), ts >= from, ts < to else { return }
                for b in v["message"]?["content"]?.array ?? [] where b["type"]?.string == "tool_use" {
                    guard let name = b["name"]?.string, DaySummary.editTools.contains(name),
                          let p = b["input"]?["file_path"]?.string ?? b["input"]?["notebook_path"]?.string else { continue }
                    edited.append(p)
                }
            }
            for p in edited where !f.sessions[i].files.contains(p) { f.sessions[i].files.append(p) }
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

    /// "What was done" without AI: per project, session titles, time, files, commits.
    public static func plain(_ f: Facts, _ w: Words) -> String {
        var lines: [String] = []
        var order: [String] = [], groups: [String: [SessionFacts]] = [:]
        for s in f.sessions {
            let p = s.project ?? w.tool(s.tool)
            if groups[p] == nil { order.append(p) }
            groups[p, default: []].append(s)
        }
        for p in order {
            let ss = groups[p]!
            let titles = ss.compactMap { $0.title ?? $0.prompts.first }.prefix(3)
            var line = "• \(p) — \(w.dur(ss.reduce(0) { $0 + $1.workingSec }))"
            if !titles.isEmpty { line += ": " + titles.joined(separator: "; ") }
            let files = Set(ss.flatMap(\.files)).map(Sys.basename).sorted()
            if !files.isEmpty {
                line += w.t(". Файлы: ", ". Files: ") + files.prefix(5).joined(separator: ", ")
                    + (files.count > 5 ? w.t(" и ещё \(files.count - 5)", " and \(files.count - 5) more") : "")
            }
            if let c = f.commits.first(where: { $0.repo == p }) {
                line += w.t(". Коммиты", ". Commits") + " (\(c.subjects.count)): " + c.subjects.prefix(3).joined(separator: "; ")
            }
            lines.append(line + ".")
        }
        for c in f.commits where groups[c.repo] == nil {
            lines.append("• \(c.repo) — " + w.t("коммиты", "commits") + " (\(c.subjects.count)): " + c.subjects.prefix(3).joined(separator: "; ") + ".")
        }
        return lines.isEmpty ? w.t("Сессий за день не было.", "No sessions this day.") : lines.joined(separator: "\n")
    }

    /// Who waited for you longest.
    public static func longestWait(_ f: Facts, _ w: Words) -> String? {
        guard let s = f.sessions.max(by: { $0.waitingSec < $1.waitingSec }), s.waitingSec >= 60 else { return nil }
        return w.t("Дольше всех ждала тебя ", "Waited for you longest: ") + "\(s.project ?? w.name(nil, s.title)) — \(w.dur(s.waitingSec))."
    }

    /// Compact input for the AI, at most `maxDigest` characters.
    public static func digest(_ f: Facts, _ w: Words) -> String {
        var out = headline(f, w) + "\n"
        for s in f.sessions {
            var b = w.t("\nПроект \(s.project ?? "—") (\(w.tool(s.tool))), сессия «\(s.title ?? "без названия")», работала \(w.dur(s.workingSec)), \(w.tokens(s.tokens)) токенов.",
                        "\nProject \(s.project ?? "—") (\(w.tool(s.tool))), session “\(s.title ?? "untitled")”, worked \(w.dur(s.workingSec)), \(w.tokens(s.tokens)) tokens.")
            if !s.prompts.isEmpty {
                b += w.t("\n  Начала запросов: ", "\n  First words of prompts: ") + s.prompts.map { w.t("«\($0)»", "“\($0)”") }.joined(separator: "; ")
            }
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
            Ниже выжимка рабочего дня разработчика: проекты, сессии ИИ-агентов, время, начала запросов, изменённые файлы, \
            коммиты. Напиши по-русски, что сделано за день: от 3 до 7 пунктов, каждый с новой строки и начинается с \
            «• <проект> — ». Коротко и по делу, без вступления и выводов. Не добавляй того, чего нет в выжимке.


            """, """
            Below is a digest of a developer's working day: projects, AI agent sessions, time, first words of prompts, \
            changed files, commits. Write in English what was done during the day: 3 to 7 points, each on its own line \
            starting with "• <project> — ". Short and to the point, no intro and no conclusions. Do not add anything that \
            is not in the digest.


            """)
    }

    /// The wording of `config.lang`.
    var words: Words { config.lang.words() }

    /// The summary from the configured engine; nil when it is off, missing, failed or timed out.
    public func ai(_ digest: String) -> (text: String, engine: String)? {
        complete(DaySummary.instruction(words) + digest).map { ($0.text, $0.engine) }
    }

    /// One prompt to the configured engine (the summary's: engine, model, timeout), without the user's config, hooks
    /// or tools; `result` is claude's JSON answer (usage, cost, time), nil for codex. `what` names it in the log.
    public func complete(_ text: String, what: String = "summary") -> (text: String, engine: String, result: JValue?)? {
        let prompt = Array(text.utf8)
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

    /// Builds the summary of `day`, stores it in `summary` and returns the text with the engine that wrote it.
    public func make(_ day: String, now: Double = Sys.now()) throws -> (facts: Facts, text: String, engine: String) {
        let f = try facts(day, now: now)
        var text = DaySummary.plain(f, words), engine = "none"
        if !f.sessions.isEmpty, let r = ai(DaySummary.digest(f, words)) { (text, engine) = (r.text, r.engine) }
        try store.db.run("INSERT OR REPLACE INTO summary(day, engine, text, created) VALUES(?, ?, ?, ?)",
                         [.text(day), .text(engine), .text(text), .real(now)])
        return (f, text, engine)
    }

    /// The evening message: numbers, what was done, who waited longest, and the ribbon.
    public func message(_ day: String, now: Double = Sys.now()) throws -> Message {
        let (f, text, _) = try make(day, now: now)
        let w = words
        var body = DaySummary.headline(f, w) + "\n\n" + text
        if let l = DaySummary.longestWait(f, w) { body += "\n\n" + l }
        return Message(title: w.t("Сводка дня", "Day summary"), text: body, photo: try ribbon(f),
                       buttons: [[.init(w.t("Подробнее", "Details"), "day:\(day)")]])
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
