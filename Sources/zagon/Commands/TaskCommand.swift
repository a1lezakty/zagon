import ArgumentParser
import ZagonCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// `zagon task …`: the own task registry. Shared setup for `task`, `log` and `mcp` is the Common extension below.

extension Common {
    var configText: String { Sys.readFile(dataDir + "/config.toml").map { String(decoding: $0, as: UTF8.self) } ?? "" }

    func linker() throws -> TaskLinker {
        try TaskLinker(patterns: [TOMLLite.string(in: configText, section: "tasks", key: "key_pattern") ?? TaskLinker.defaultPattern])
    }

    /// `--time`, else `[worklog] time` in config.toml, else the sessions' wall-clock time.
    func timeBase(_ flag: TaskTime.Base?) -> TaskTime.Base {
        flag ?? TOMLLite.string(in: configText, section: "worklog", key: "time").flatMap(TaskTime.Base.init) ?? .sessions
    }

    /// nil when `[jira]` is not configured.
    func jira() throws -> JiraClient? { try JiraConfig.load(configText: configText).map(JiraClient.init) }

    /// Suggestions by meaning: the summary's engine (`[summary]`), `[tasks] suggest_min_confidence`, Jira read-only.
    func suggester(_ store: Store) throws -> TaskSuggester {
        let paths = ZagonPaths(dir: dataDir)
        var s = try TaskSuggester.load(store: store, paths: paths, config: NotifyConfig.load(paths), claudeRoot: claudeDir, log: warn)
        s.idleGap = idleGap * 60
        return s
    }

    /// Linking, time options and Jira (a configured Jira that cannot start is kept as `jiraSetupError`).
    func worklog(_ store: Store, base: TaskTime.Base? = nil) throws -> DayWorklog {
        var client: JiraClient?, err: String?
        do { client = try jira() } catch { err = "\(error)" }
        return DayWorklog(store: store, linker: try linker(), jira: client, jiraSetupError: err, idleGap: idleGap * 60,
                          base: timeBase(base))
    }
}

func warn(_ s: String) { _ = Sys.writeAll(fd: 2, Array((s + "\n").utf8)) }

func taskRef(_ tasks: Tasks, _ ref: String) throws -> TaskItem {
    guard let t = try tasks.find(ref) else { throw ValidationError("no task \(ref)") }
    return t
}

extension TaskStatus: ExpressibleByArgument {}
extension TaskTime.Base: ExpressibleByArgument {}

struct TaskCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "task", abstract: "Own task registry: sessions, time, TODO, notes, what was done.",
        subcommands: [Add.self, List.self, Show.self, Todo.self, Note.self, Done.self, Status.self, Link.self, Import.self,
                       Suggest.self, Accept.self, Reject.self])

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a task (own key ZAG-N unless --key).")
        @Argument(help: "Title.") var title: [String]
        @Option(help: "Key, e.g. PROJ-123 (also the Jira key unless --jira / --no-jira).") var key: String?
        @Option(help: "Jira key, if it differs from the key.") var jira: String?
        @Flag(help: "The key is not a Jira issue.") var noJira = false
        @Option(help: "Description.") var description: String?
        @Option(help: "planned | in_progress | done") var status: TaskStatus = .planned
        @OptionGroup var common: Common
        func run() throws {
            let store = try common.open(), tasks = Tasks(store: store)
            var t = try tasks.add(title: title.joined(separator: " "), key: key, jiraKey: jira, description: description, status: status)
            if noJira { t.jiraKey = nil; try tasks.update(t) }
            try common.linker().linkSessions(store)
            print("\(t.key)  \(t.title)" + (t.jiraKey.map { "  (Jira \($0))" } ?? ""))
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Tasks with their time over the last 7 days.")
        @Option(help: "planned | in_progress | done") var status: TaskStatus?
        @Option(help: "user: your time | sessions: wall-clock time any session worked (default).") var time: TaskTime.Base?
        @OptionGroup var common: Common
        @OptionGroup var report: ReportOptions
        func run() throws {
            let store = try prepare(common, report)
            try common.linker().linkSessions(store)
            let base = common.timeBase(time)
            let lines = try Tasks(store: store).overview(status: status, base: base, idleGap: common.idleGap * 60)
            if report.json { try emit(lines) } else { print(TaskText.list(lines, base: base)) }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "One task: time, Jira, TODO, notes, what was done, sessions.")
        @Argument(help: "Key, Jira key or id.") var task: String
        @Option(help: "user: your time | sessions: wall-clock time any session worked (default).") var time: TaskTime.Base?
        @OptionGroup var common: Common
        @OptionGroup var report: ReportOptions
        func run() throws {
            let store = try prepare(common, report), w = try common.worklog(store, base: time)
            try w.linker.linkSessions(store)
            if let e = w.jiraSetupError { warn("jira: \(e)") }
            let tasks = Tasks(store: store)
            let c = try tasks.card(try taskRef(tasks, task), base: w.base, idleGap: w.idleGap, jira: w.jira)
            if report.json { try emit(c) } else { print(TaskText.card(c, base: w.base, jiraConnected: w.jira != nil)) }
        }
    }

    struct Todo: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a TODO, or check / uncheck one by number.")
        @Argument(help: "Key, Jira key or id.") var task: String
        @Argument(help: "Text of a new TODO.") var text: [String] = []
        @Option(help: "Mark TODO #N done.") var check: Int?
        @Option(help: "Mark TODO #N not done.") var uncheck: Int?
        @OptionGroup var common: Common
        func run() throws {
            let tasks = Tasks(store: try common.open()), t = try taskRef(tasks, task)
            if let n = check { try tasks.checkTodo(t.id, number: n) }
            if let n = uncheck { try tasks.checkTodo(t.id, number: n, done: false) }
            if !text.isEmpty { try tasks.addTodo(t.id, text.joined(separator: " ")) }
            for (i, x) in try tasks.todos(t.id).enumerated() { print("  \(i + 1). [\(x.done ? "x" : " ")] \(x.text)") }
        }
    }

    struct Note: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a note.")
        @Argument(help: "Key, Jira key or id.") var task: String
        @Argument(help: "Text.") var text: [String]
        @OptionGroup var common: Common
        func run() throws {
            let tasks = Tasks(store: try common.open()), t = try taskRef(tasks, task)
            try tasks.addNote(t.id, text.joined(separator: " "))
        }
    }

    struct Done: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set what was done on a day (manual; used as the worklog text).")
        @Argument(help: "Key, Jira key or id.") var task: String
        @Argument(help: "Text.") var text: [String]
        @Option(help: "YYYY-MM-DD, default today.") var day: String?
        @OptionGroup var common: Common
        func run() throws {
            let tasks = Tasks(store: try common.open()), t = try taskRef(tasks, task)
            try tasks.setDone(t.id, day: day ?? Time.dayString(Time.now()), text: text.joined(separator: " "))
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change the status: planned | in_progress | done.")
        @Argument(help: "Key, Jira key or id.") var task: String
        @Argument var status: TaskStatus
        @OptionGroup var common: Common
        func run() throws {
            let tasks = Tasks(store: try common.open()), t = try taskRef(tasks, task)
            try tasks.setStatus(t.id, status)
        }
    }

    struct Link: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Link a session by hand (beats automatic links), or unlink it.")
        @Argument(help: "Key, Jira key or id.") var task: String
        @Argument(help: "Session id or a unique part of it.") var session: String
        @Flag(help: "Not this task: removes the link and keeps automatic linking from adding it back.") var unlink = false
        @OptionGroup var common: Common
        func run() throws {
            let store = try common.open(), tasks = Tasks(store: store), t = try taskRef(tasks, task)
            var ids: [String] = []
            try store.db.query("SELECT id FROM session WHERE id = ?1 OR id LIKE '%:' || ?1 || '%' LIMIT 3", [.text(session)]) {
                if let s = $0.text(0) { ids.append(s) }
            }
            guard ids.count == 1 || ids.contains(session) else {
                throw ValidationError(ids.isEmpty ? "no session \(session)" : "ambiguous session \(session): \(ids.joined(separator: ", "))")
            }
            let sid = ids.contains(session) ? session : ids[0]
            try tasks.link(t.id, session: sid, how: unlink ? .unlinked : .manual)
            print("\(unlink ? "unlinked" : "linked") \(sid) \(unlink ? "from" : "to") \(t.key)")
        }
    }

    struct Suggest: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Suggest tasks for the day's work no key linked (one AI call per day; Jira read-only).",
            discussion: "Suggestions count nowhere until accepted: `task accept <id…>` links the task for that time, "
                + "`task reject <id…>` never suggests that task for that session again (its other links stay).")
        @Argument(help: "YYYY-MM-DD, default today.") var date: String?
        @Flag(help: "Drop the day's open suggestions and ask again.") var again = false
        @Flag(help: "Print what would be sent to the AI: no AI call, no suggestion stored (links are refreshed, Jira is read).")
        var prompt = false
        @OptionGroup var common: Common
        @OptionGroup var report: ReportOptions
        func run() throws {
            let day = try LogCommand.day(date), store = try prepare(common, report)
            if prompt { print(try common.suggester(store).prompt(day)); return }
            let r = try common.suggester(store).suggest(day, again: again)
            if report.json { try emit(r); return }
            print(SuggestText.run(r, day: day))
        }
    }

    struct Accept: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Accept suggestions: link their task for that time.")
        @Argument(help: "Suggestion ids (from `task suggest`).") var ids: [Int]
        @OptionGroup var common: Common
        func run() throws {
            for l in try common.suggester(try common.open()).accept(ids) { print(l) }
        }
    }

    struct Reject: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reject suggestions: never suggest that task for that session.")
        @Argument(help: "Suggestion ids (from `task suggest`).") var ids: [Int]
        @OptionGroup var common: Common
        func run() throws {
            for l in try common.suggester(try common.open()).reject(ids) { print(l) }
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create tasks for your Jira issues (read-only in Jira).")
        @Option(help: "JQL.") var jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
        @OptionGroup var common: Common
        func run() throws {
            guard let jira = try common.jira() else { throw ValidationError("Jira is not configured ([jira] in config.toml)") }
            let store = try common.open(), tasks = Tasks(store: store)
            var added = 0
            for i in try jira.search(jql) where try tasks.find(i.key) == nil {
                try tasks.add(title: i.summary, key: i.key, status: TaskStatus(jiraCategory: i.statusCategory))
                added += 1
                print("  + \(i.key)  \(i.summary)")
            }
            try common.linker().linkSessions(store)
            print("\(added) new tasks")
        }
    }
}
