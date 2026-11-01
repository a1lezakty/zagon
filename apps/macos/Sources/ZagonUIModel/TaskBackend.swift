import Foundation
import ZagonCore

/// Tasks and the worklog plan where they live: the `zagon` of this Mac (inside Zagon.app) or of a server over ssh,
/// asked with `--json`. Edits go through the same CLI; the plan goes to Jira only by `commit`, and only while it is
/// still the plan that was shown.
public struct TaskBackend: Sendable {
    public enum Source: Hashable, Sendable {
        case local, server(String)
        /// As kept in settings: "" = this Mac, else the ssh alias.
        public var saved: String { if case .server(let h) = self { return h } else { return "" } }
        public init(saved: String) { self = saved.isEmpty ? .local : .server(saved) }
    }
    public let source: Source
    /// `zagon <args>` with a time limit; nil = no answer in time.
    let run: @Sendable (_ args: [String], _ timeout: Double) throws -> Proc.Result?

    public init(source: Source, run: @escaping @Sendable (_ args: [String], _ timeout: Double) throws -> Proc.Result?) {
        self.source = source; self.run = run
    }

    /// The CLI inside Zagon.app with the login shell's PATH (git, for links by branch).
    public static func local(cli: String, path: String) -> TaskBackend {
        TaskBackend(source: .local) { try Proc.run(cli, $0, env: ["PATH": path], timeout: $1, stop: stoppable($0) ? .kill : nil) }
    }

    public static func server(_ host: String, controlDir: String = Remote.controlDir(), ssh: String = "/usr/bin/ssh") -> TaskBackend {
        TaskBackend(source: .server(host)) {
            try Proc.run(ssh, Remote.sshArguments(host: host, zagon: $0, controlDir: controlDir, stoppable: stoppable($0)),
                         timeout: $1, stop: stoppable($0) ? .closeInput : nil)
        }
    }

    /// `zagon summary` (minutes of AI calls) stops, there too, when the task waiting for it is cancelled.
    static func stoppable(_ args: [String]) -> Bool { args.first == "summary" }

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
        /// The zagon there does not know an option or a command of this app.
        var older = false
    }

    /// stdout, and the `jira: …` warning from stderr; a failure as one short line without home folders.
    func call(_ args: [String], timeout: Double = 120) throws -> (out: Data, jira: String?) {
        guard let r = try run(args, timeout) else { throw Failure(description: "no answer in \(Int(timeout)) s") }
        guard r.status == 0 else { throw failure(r) }
        let err = String(decoding: r.err, as: UTF8.self).split(separator: "\n").map(String.init)
        return (r.out, err.last { $0.hasPrefix("jira: ") }.map { Remote.scrubHomes(String($0.dropFirst(6))) })
    }

    func decode<T: Decodable>(_ args: [String], timeout: Double = 120) throws -> (T, jira: String?) {
        let (out, jira) = try call(args, timeout: timeout)
        // A login banner may come first: the JSON is the last line.
        return (try Self.parse(out.split(separator: UInt8(ascii: "\n")).last.map { Data($0) } ?? out, args), jira)
    }

    static func parse<T: Decodable>(_ line: Data, _ args: [String]) throws -> T {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        guard let v = try? d.decode(T.self, from: line) else {
            throw Failure(description: "zagon answered \(args.prefix(2).joined(separator: " ")) in a form this app does not read (another version?)")
        }
        return v
    }

    struct Digest: Decodable { var commitDigest: String? }

    /// Also what is in Jira with no work here (`worked` false); a zagon from before `--all` sends only its list.
    public func list() throws -> [TaskListLine] {
        do { return try decode(["task", "list", "--all", "--json"]).0 }
        catch let e as Failure where e.older { return try decode(["task", "list", "--json"]).0 }
    }
    /// `scan: false` right after an edit: nothing new to read, and the answer comes sooner.
    public func card(_ key: String, scan: Bool = true) throws -> TaskCard {
        try decode(["task", "show", "--json"] + (scan ? [] : ["--no-scan"]) + ["--", key]).0
    }
    /// `refresh`: the day summary and the texts made anew first when sessions worked after it (AI calls, minutes).
    /// `comments`: tasks whose day summary goes as a comment, not in the worklog (the digest counts them).
    public func plan(_ day: String, refresh: Bool = false, scan: Bool = true, comments: [String] = []) throws -> WorklogPlan {
        let args = ["log", "plan", "--json"] + (refresh ? ["--refresh"] : []) + (scan ? [] : ["--no-scan"])
            + comments.map { "--summary-comment=" + $0 } + ["--", day]
        let (out, jira) = try call(args, timeout: refresh ? 900 : 120)
        var line = out.split(separator: UInt8(ascii: "\n")).last.map { Data($0) } ?? out
        // `commit_digest` came with `log commit --expect`; a zagon from before sends none, and `DayPlan` may require it.
        let digest = (try? Self.parse(line, args) as Digest)?.commitDigest.flatMap { $0.isEmpty ? nil : $0 }
        let extras = try? Self.parse(line, args) as PlanExtras
        if digest == nil, line.first == UInt8(ascii: "{") { line = Data("{\"commit_digest\":\"\",".utf8) + line.dropFirst() }
        return WorklogPlan(plan: try Self.parse(line, args), jiraError: jira, digest: digest, extras: extras, comments: comments)
    }

    /// What a zagon from 0.1.5 adds to `log plan --json`: the worklog zone, texts per row, exclusions. All optional:
    /// an older zagon reads as before.
    struct PlanExtras: Decodable, Sendable {
        struct Session: Decodable, Sendable { var id, title, role, how: String?; var seconds: Double? }
        struct Row: Decodable, Sendable {
            var id: Int
            var textSource, summary, summarySource: String?
            var daySummary: Bool?
            var sessions: [Session]?
        }
        struct Part: Decodable, Sendable { var kind, name, project: String?; var seconds: Double }
        var tz: String?
        var summaryBuiltAt: Double?
        var sessionsAfterSummary: Int?
        var excluded, unassigned: [Part]?
        var rows: [Row]?
    }

    // MARK: texts and exclusions (a zagon from 0.1.5)

    /// The row's text typed by hand (`summary`: its day summary); a rebuild keeps it.
    public func setText(_ row: Int, _ text: String, summary: Bool) throws {
        _ = try call(["log", "text", "set", String(row)] + (summary ? ["--summary"] : []) + ["--", text])
    }
    /// The row's text written anew, or shorter, by one AI call.
    public func rebuildText(_ row: Int, summary: Bool, shorten: Bool) throws {
        _ = try call(["log", "text", "rebuild", String(row)] + (summary ? ["--summary"] : []) + (shorten ? ["--shorten"] : []),
                     timeout: 300)
    }
    /// Keeps a project (folder), a task (key) or a session (id) out of the plans, or lets it back in.
    public func exclude(_ kind: String, _ name: String, add: Bool) throws {
        _ = try call(["log", "exclude", add ? "add" : "rm", kind, "--", name])
    }

    /// `[worklog]` of that machine's config.toml as `log config --json` answers.
    public struct WorklogConfig: Decodable, Sendable, Equatable {
        public struct Exclusion: Decodable, Sendable, Hashable {
            public var kind, name: String
            public init(kind: String, name: String) { self.kind = kind; self.name = name }
        }
        /// nil = the machine's zone.
        public var tz: String?
        public var machineTz: String?
        /// Typed in config.toml; Jira's own projects come on top of them.
        public var projects: [String]?
        public var jiraProjects: [String]?
        public var daySummary: Bool?
        public var rebuildAtEnd: Bool?
        public var exclude: [Exclusion]?
        public init(tz: String? = nil, machineTz: String? = nil, projects: [String]? = nil, jiraProjects: [String]? = nil,
                    daySummary: Bool? = nil, rebuildAtEnd: Bool? = nil, exclude: [Exclusion]? = nil) {
            self.tz = tz; self.machineTz = machineTz; self.projects = projects; self.jiraProjects = jiraProjects
            self.daySummary = daySummary; self.rebuildAtEnd = rebuildAtEnd; self.exclude = exclude
        }
    }
    /// nil: a zagon from before `log config`.
    public func worklogConfig() throws -> WorklogConfig? {
        do { return try decode(["log", "config", "--json"]).0 } catch let e as Failure where e.older { return nil }
    }
    /// One `[worklog]` key: `tz` (an IANA name, "system" = the machine's), `projects` (comma-separated),
    /// `day_summary`, `rebuild_at_end` (true / false).
    public func setWorklogConfig(_ key: String, _ value: String) throws { _ = try call(["log", "config", key, "--", value]) }

    // `--` keeps a text that starts with "-" from being read as an option.
    public func addTodo(_ key: String, _ text: String) throws { _ = try call(["task", "todo", "--", key, text]) }
    /// `number` is 1-based in creation order (the card's order).
    public func checkTodo(_ key: String, number: Int, done: Bool) throws {
        _ = try call(["task", "todo", done ? "--check" : "--uncheck", String(number), "--", key])
    }
    public func addNote(_ key: String, _ text: String) throws { _ = try call(["task", "note", "--", key, text]) }
    public func setStatus(_ key: String, _ state: TaskState) throws {
        let s: TaskStatus = switch state { case .planned: .planned; case .active: .inProgress; case .review: .review; case .done: .done }
        _ = try call(["task", "status", "--", key, s.rawValue])
    }

    // MARK: suggested new tasks

    /// Open suggested new tasks of all days, newest day first; a zagon from before 0.1.1 suggests none.
    public func drafts() throws -> [NewTaskDraft] {
        do { return try decode(["task", "drafts", "--json"]).0 } catch let e as Failure where e.older { return [] }
    }
    public struct JiraProjects: Decodable, Sendable, Equatable {
        public struct Project: Decodable, Sendable, Equatable { public var key, name: String }
        /// The last project used there (nil: none yet).
        public var `default`: String?
        public var projects: [Project]
    }
    /// Fails when Jira is not connected there.
    public func jiraProjects() throws -> JiraProjects { try decode(["task", "jira-projects", "--json"]).0 }
    /// The issue type a new task gets in Jira project `project` there (its name in that Jira).
    public func jiraType(_ project: String) throws -> String { try answer(["task", "jira-projects", "--type-of=" + project]) }
    /// The suggestions, and the Jira projects to make them in when there are any (nil: Jira does not answer there).
    public func suggestions() throws -> (drafts: [NewTaskDraft], jira: JiraProjects?) {
        let d = try drafts()
        return (d, d.isEmpty ? nil : try? jiraProjects())
    }
    /// Makes the suggested task in Zagon only; the CLI's answer line. Texts go as `--opt=value`: one starting with "-"
    /// stays a value.
    public func accept(_ id: String, title: String? = nil, description: String? = nil) throws -> String {
        try answer(["task", "accept"] + (title.map { ["--title=" + $0] } ?? []) + (description.map { ["--description=" + $0] } ?? []) + ["--", id])
    }
    /// Writes to Jira: only after the user pressed Create in the confirmation.
    public func createInJira(_ id: String, project: String, title: String, description: String) throws -> String {
        try answer(["task", "accept", "--create-in-jira", "--project=" + project, "--title=" + title, "--description=" + description,
                    "--yes", "--", id], timeout: 300)
    }
    public func reject(_ id: String) throws -> String { try answer(["task", "reject", "--", id]) }

    /// The last line printed (the outcome).
    func answer(_ args: [String], timeout: Double = 120) throws -> String {
        String(decoding: try call(args, timeout: timeout).out, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
    }

    public enum Commit: Sendable {
        /// What the CLI reported; `problems` are its "not logged …" lines.
        case written(logged: Int, failed: Int, problems: [String])
        /// The plan is no longer the one shown: nothing was written, this is the new one.
        case changed(WorklogPlan)
        case nothing
    }

    /// Writes the day's planned rows to Jira if the plan is still `shown` (`log commit` plans the day again itself and
    /// writes what it planned).
    /// A plan made while Jira failed did not keep clear of the worklogs already there: such a plan is never written.
    public func commit(_ day: String, shown: WorklogPlan) throws -> Commit {
        if let e = shown.jiraError { throw Failure(description: "the plan was made without Jira (\(e)): reload it") }
        if let digest = shown.digest {
            // The CLI plans the day again and writes only if that is the plan shown (exit 3 otherwise).
            guard shown.plan.jiraSec != nil else { throw Failure(description: "Jira is not connected there ([jira] in config.toml)") }
            guard !Self.toJira(shown.plan).isEmpty else { return .nothing }
            // The same comment choice as the plan shown: the digest counts it.
            guard let r = try run(["log", "commit", "--yes", "--no-scan", "--expect", digest] + shown.comments.map { "--summary-comment=" + $0 }
                                  + ["--", day], 300) else {
                throw Failure(description: "no answer in 300 s: part may be written, reload the plan")
            }
            if r.status == 3 { return .changed(try plan(day, comments: shown.comments)) }
            return try written(r)
        }
        // A zagon from before `--expect`: the check is made here, a moment before the CLI's own plan.
        let fresh = try plan(day)
        if let e = fresh.jiraError { throw Failure(description: "Jira does not answer: \(e)") }
        guard fresh.plan.jiraSec != nil else { throw Failure(description: "Jira is not connected there ([jira] in config.toml)") }
        guard Self.toJira(fresh.plan) == Self.toJira(shown.plan) else { return .changed(fresh) }
        guard !Self.toJira(fresh.plan).isEmpty else { return .nothing }
        // ponytail: here the CLI plans the day once more and writes that; the check above is a moment earlier (no
        // rescan in between). Gone with servers on a zagon that has `--expect`.
        guard let r = try run(["log", "commit", "--yes", "--no-scan", "--", day], 300) else {
            throw Failure(description: "no answer in 300 s: part may be written, reload the plan")
        }
        return try written(r)
    }

    /// What `log commit` reported.
    func written(_ r: Proc.Result) throws -> Commit {
        let lines = String(decoding: r.out, as: UTF8.self).split(separator: "\n").map(String.init)
        // Exit 1 with the summary line = some rows failed; anything else is a failure before writing.
        guard let m = lines.last?.wholeMatch(of: /(\d+) worklogs logged(?:, (\d+) not logged)?/) else { throw failure(r) }
        return .written(logged: Int(m.1) ?? 0, failed: m.2.flatMap { Int($0) } ?? 0,
                        problems: lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("not logged") }
                            .map(Remote.scrubHomes))
    }

    func failure(_ r: Proc.Result) -> Failure {
        // ArgumentParser prints the reason first and the usage after it.
        let err = String(decoding: r.err, as: UTF8.self).split(separator: "\n").map(String.init)
        let why = err.first { $0.hasPrefix("Error: ") }.map { String($0.dropFirst(7)) } ?? err.last ?? "exit \(r.status)"
        // A zagon from before `task` / `--json` does not know the words.
        if ["Unexpected argument", "Unknown option"].contains(where: why.contains) {
            return Failure(description: "zagon there is older than this app, update it (\(Remote.scrubHomes(why)))", older: true)
        }
        return Failure(description: Remote.scrubHomes(why))
    }

    /// The rows `log commit` would write, as compared.
    static func toJira(_ p: DayPlan) -> [String] {
        p.rows.filter { $0.state == "planned" && $0.jiraKey != nil }
            .map { "\($0.jiraKey ?? "")|\($0.start)|\($0.end)|\($0.seconds)|\($0.text)" }
    }

    public static func day(_ d: Date, _ zone: TimeZone = .autoupdatingCurrent) -> String { StoreDataProvider.day(d, zone) }
}

/// A day's plan, and why Jira was left out of it (nil: fine or not connected).
public struct WorklogPlan: Sendable {
    public var plan: DayPlan
    public var jiraError: String?
    /// The plan's `commit_digest`: `log commit --expect` writes only this plan (nil: a zagon from before it).
    public var digest: String?
    var extras: TaskBackend.PlanExtras?
    /// Tasks whose day summary this plan sends as a comment (`--summary-comment`).
    public var comments: [String] = []
    /// The worklog zone the plan is cut in (nil: a zagon from before it).
    public var zone: String? { extras?.tz }
    /// Sessions with work after the day summary, or all of them with no summary (nil: a zagon from before texts).
    public var newSessions: Int? { extras?.sessionsAfterSummary }
    /// When its day summary was made (epoch seconds; nil: none, or a zagon from before texts).
    public var summaryBuiltAt: Double? { extras?.summaryBuiltAt }
    public func worklog(_ f: Fmt) -> WorklogData { TaskBackend.worklog(plan, jiraError: jiraError, extras: extras, comments: comments, f) }
}

/// What the task screens got from one source; an error is one grey line, the data stays.
public struct TaskCache: Sendable {
    public var list: [TaskItem]?
    /// Full cards by key (time over the whole history), loaded when a task is opened.
    public var cards: [String: TaskItem] = [:]
    public var plans: [String: WorklogPlan] = [:]
    /// Reconciliations by "from|to".
    public var reconciles: [String: Reconciliation] = [:]
    /// Suggested new tasks; `jira`: where they may be made in Jira (nil: not connected there, or nothing to suggest).
    public var drafts: [NewTaskDraft]?
    public var jira: TaskBackend.JiraProjects?
    /// The AI engine whose CLI the source does not have: its suggestions are made without AI (nil: it has one, or not
    /// known).
    public var noCli: String?
    /// What the last accept or reject answered.
    public var draftNote: String?
    public var loading = 0
    public var error: String?
    /// The last commit's outcome.
    public var message: String?
    public init() {}
}

// MARK: - what the screens show

extension TaskBackend {
    static func state(_ s: TaskStatus) -> TaskState {
        switch s { case .planned: .planned; case .inProgress: .active; case .review: .review; case .done: .done }
    }

    /// A list line: time over the last 7 days.
    public static func item(_ l: TaskListLine) -> TaskItem {
        TaskItem(key: l.task.key, title: l.task.title, description: l.task.description ?? "", state: state(l.task.status),
                 userSec: l.weekSec, sessionSec: l.weekSessionSec, sessionCount: l.sessions, jiraKey: l.task.jiraKey,
                 worked: l.worked ?? true, jiraStatus: l.jiraStatus)
    }

    /// A card: time over the task's whole history; `sessions` as this Mac knows them; days shown in `zone`.
    public static func item(_ c: TaskCard, sessions: [TaskSession], zone: TimeZone = .autoupdatingCurrent) -> TaskItem {
        let t = c.task
        var days: [String] = [], done: [(day: Date, text: String)] = []
        for d in c.done where !days.contains(d.day) {  // newest first, the manual text before the auto one
            days.append(d.day)
            done.append((StoreDataProvider.start(d.day, zone), d.text))
        }
        return TaskItem(
            key: t.key, title: t.title, description: t.description ?? "", state: state(t.status),
            // A zagon from before 0.1.1 sends no `jira_status_here`: then by the status category.
            jira: c.jira.map { JiraInfo(status: $0.status, statusMatches: (c.jiraStatusHere ?? TaskStatus(jiraCategory: $0.statusCategory)) == t.status,
                                        loggedSec: c.jiraLoggedSec ?? 0) },
            userSec: c.time.userSec, sessionSec: c.time.sessionSec, tokens: c.time.tokens.total,
            // Claude's and Codex's weekly limits are different limits: the larger share, not a sum.
            weekPct: c.time.weekPct.values.max() ?? 0,
            todo: c.todos.map { TodoItem($0.text, done: $0.done) }, doneByDay: done, sessions: sessions,
            sessionCount: c.sessions.count, notes: c.notes.map(\.text), jiraKey: t.jiraKey, jiraError: c.jiraError.map(Remote.scrubHomes))
    }

    public static func draft(_ d: NewTaskDraft, _ f: Fmt) -> DraftVM {
        var sessions: [String] = []
        for s in d.stretches { if let t = s.sessionTitle, !t.isEmpty, !sessions.contains(t) { sessions.append(t) } }
        return DraftVM(id: d.id, title: f.t("draft.title", d.title, f.duration(d.workedSec)),
                       meta: ([f.dayTitleShortWeekday(StoreDataProvider.start(d.day, f.calendar.timeZone))] + sessions)
                           .joined(separator: " · "),
                       name: d.title, description: d.description, worked: f.duration(d.workedSec))
    }

    /// The plan as the worklog screen shows it; skipped rows are left out, rows being written count as in Jira.
    static func worklog(_ p: DayPlan, jiraError: String?, extras x: PlanExtras? = nil, comments: [String] = [], _ f: Fmt) -> WorklogData {
        var more: [Int: PlanExtras.Row] = [:]
        for r in x?.rows ?? [] { more[r.id] = r }
        let rows = p.rows.filter { $0.state != "skipped" }.map { r in
            // The Jira issue the row goes to, when it is not the task's own key.
            let key = r.taskKey.map { t in r.jiraKey.map { $0 == t ? t : t + " → " + $0 } ?? t } ?? r.jiraKey ?? "—"
            let m = more[r.id], task = r.taskKey ?? r.jiraKey
            return WorklogRow(key: key, start: StoreDataProvider.date(r.start), end: StoreDataProvider.date(r.end), text: r.text,
                              destination: r.state == "logged" || r.state == "writing" ? .alreadyLogged : r.jiraKey != nil ? .jira : .zagonOnly,
                              id: r.id, taskKey: task, textSource: m?.textSource.flatMap(WorklogTextSource.init(rawValue:)),
                              daySummary: m?.daySummary ?? false, summary: m?.summary,
                              summarySource: m?.summarySource.flatMap(WorklogTextSource.init(rawValue:)),
                              summaryAsComment: task.map(comments.contains) ?? false,
                              sessions: (m?.sessions ?? []).map {
                                  WorklogSession(id: $0.id ?? "", title: $0.title ?? "", role: $0.role ?? "", how: $0.how ?? "", sec: $0.seconds ?? 0)
                              })
        }
        var notes = p.rows.filter { $0.state == "writing" }.map { f.t("worklog.writing", $0.jiraKey ?? "—", f.timeSpan(
            StoreDataProvider.date($0.start), StoreDataProvider.date($0.end))) }
        // By project when the zagon there says so: each can be kept out of the plans.
        let unassigned = (x?.unassigned ?? []).filter { $0.seconds >= 60 }.map { WorklogPart(kind: "project", name: $0.project ?? "—", sec: $0.seconds) }
        if p.unassignedSec >= 60, x?.unassigned == nil { notes.append(f.t("worklog.noTask", f.duration(p.unassignedSec))) }
        if !p.unknownKeys.isEmpty { notes.append(f.t("worklog.unknownKeys", p.unknownKeys.joined(separator: ", "))) }
        notes += p.unplaced.sorted { $0.key < $1.key }.map { f.t("worklog.unplaced", $0.key, f.duration(Double($0.value))) }
        notes += p.notes.map(Remote.scrubHomes)
        let blocked = jiraError.map { f.t("worklog.jiraFailed", Remote.scrubHomes($0)) } ?? (p.jiraSec == nil ? f.t("worklog.jiraOff") : nil)
        // The plan has no work stretches of its own: no "from–to" under your time.
        return WorklogData(day: StoreDataProvider.start(p.day, f.calendar.timeZone), workStart: nil, workEnd: nil,
                           userSec: p.userSec, sessionSec: p.sessionSec, rows: rows, splits: [], notes: notes,
                           jiraSec: p.jiraSec, jiraBlocked: blocked, zone: x?.tz,
                           texts: x?.tz == nil ? nil : WorklogTexts(builtAt: x?.summaryBuiltAt.map(StoreDataProvider.date),
                                                                    newSessions: x?.sessionsAfterSummary ?? 0),
                           excluded: (x?.excluded ?? []).map { WorklogPart(kind: $0.kind ?? "", name: $0.name ?? "", sec: $0.seconds) },
                           unassigned: unassigned)
    }
}

// MARK: - the same answers from a store in this process

extension TaskBackend {
    /// What the CLI answers to `task list`, `task show` and `log plan` (without Jira), from a store here: the samples
    /// and tests go through the same JSON as a real CLI.
    public static func inProcess(_ store: Store, queue: DispatchQueue, now: Date) -> TaskBackend {
        nonisolated(unsafe) let store = store
        return TaskBackend(source: .local) { args, _ in
            try queue.sync {
                let e = JSONEncoder()
                e.keyEncodingStrategy = .convertToSnakeCase
                e.outputFormatting = [.sortedKeys]
                let linker = try TaskLinker()
                try linker.linkSessions(store)
                let tasks = Tasks(store: store), ts = now.timeIntervalSince1970
                let words = args.filter { $0 != "--json" && $0 != "--" && $0 != "--all" }
                let out: Data
                switch (words.first, words.dropFirst().first, words.dropFirst(2).first) {
                case ("task", "list", nil): out = try e.encode(try tasks.overview(all: args.contains("--all"), now: ts))
                case ("task", "show", let k?):
                    guard let t = try tasks.find(k) ?? tasks.jiraOnly(k) else { return Proc.Result(status: 64, out: Data(), err: Data("Error: no task \(k)\n".utf8)) }
                    out = try e.encode(try tasks.card(t, now: ts))
                case ("log", "plan", let d?):
                    out = try e.encode(try DayWorklog(store: store, linker: linker, jira: nil).plan(d).plan)
                default: return Proc.Result(status: 64, out: Data(), err: Data("Error: not here: \(words.joined(separator: " "))\n".utf8))
                }
                return Proc.Result(status: 0, out: out, err: Data())
            }
        }
    }
}
