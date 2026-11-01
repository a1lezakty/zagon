import ArgumentParser
import ZagonCore

/// `zagon log …`: the day's worklog plan; writes to Jira only on `commit` after confirmation.
struct LogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log", abstract: "Worklog plan for a day; writes to Jira only on commit with confirmation.",
        subcommands: [Plan.self, Commit.self, Skip.self, ReconcileRange.self, Text.self, Exclude.self, Config.self, AtEnd.self])

    static func day(_ d: String?) throws -> String {
        let day = d ?? Time.dayString(Time.now())
        guard Time.parseDay(day) != nil else { throw ValidationError("date must be YYYY-MM-DD") }
        return day
    }

    struct Plan: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "What to log: time per task, without overlapping Jira worklogs.")
        @Argument(help: "YYYY-MM-DD, default today.") var date: String?
        @Option(help: "user: your time | sessions: wall-clock time any session worked (default).") var time: TaskTime.Base?
        @Flag(help: "Build the day's texts again (one AI call) if a session worked after they were built.") var refresh = false
        @Option(name: .customLong("summary-comment"), help: "A task whose day summary goes as an issue comment (repeat): its commit_digest is for that.")
        var summaryComment: [String] = []
        @OptionGroup var common: Common
        @OptionGroup var report: ReportOptions
        func run() throws {
            let store = try prepare(common, report), w = try common.worklog(store, base: time)
            try Settings.inZone(w.config.tz) {
                let (made, err) = try w.plan(try LogCommand.day(date), refresh: refresh)
                var p = made
                if !summaryComment.isEmpty { p.commitDigest = DayPlan.commitDigest(p.rows, commentKeys: LogCommand.keys(summaryComment)) }
                if report.json { try emit(p); if let err { warn("jira: \(err)") }; return }
                print(TaskText.plan(p, base: w.base, jiraError: err))
            }
        }
    }

    static func keys(_ xs: [String]) -> Set<String> { Set(xs.map { $0.uppercased() }) }

    struct Commit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Re-plan the day, show it and write it to Jira (asks first).")
        @Argument(help: "YYYY-MM-DD, default today.") var date: String?
        @Flag(help: "Do not ask (scripts).") var yes = false
        @Option(help: "Write only if the rows are still those shown: commit_digest of `log plan --json`; else nothing is written, exit 3.")
        var expect: String?
        @Option(help: "user: your time | sessions: wall-clock time any session worked (default).") var time: TaskTime.Base?
        @Option(name: .customLong("summary-comment"), help: "A task whose day summary goes as one issue comment instead of into its worklog (repeat).")
        var summaryComment: [String] = []
        @OptionGroup var common: Common
        @OptionGroup var report: ReportOptions
        func run() throws {
            let store = try prepare(common, report), w = try common.worklog(store, base: time)
            guard w.jira != nil else {
                throw ValidationError("Jira is not connected" + (w.jiraSetupError.map { ": \($0)" } ?? " ([jira] in config.toml)"))
            }
            try Settings.inZone(w.config.tz) {
                let day = try LogCommand.day(date), comments = LogCommand.keys(summaryComment)
                // Always re-plan against fresh transcripts and fresh Jira: a plan from earlier may be stale.
                let rows = try w.plan(day, strict: true).plan.rows.filter { $0.state == "planned" && $0.jiraKey != nil }
                if let expect, DayPlan.commitDigest(rows, commentKeys: comments) != expect {
                    print("plan changed: nothing logged; show `zagon log plan \(day)` again")
                    throw ExitCode(3)
                }
                guard !rows.isEmpty else { print("nothing to log to Jira for \(day)"); return }
                print(TaskText.rows(rows))
                let issue = Worklog.issueComments(rows, commentKeys: comments)
                for c in issue { print("comment on \(c.key): day summary (\(c.text.count) characters)") }
                if !yes {
                    let total = rows.reduce(0) { $0 + $1.seconds }
                    print("Log \(rows.count) worklogs (\(Fmt.dur(Double(total))))" + (issue.isEmpty ? "" : " and \(issue.count) comments")
                          + " to Jira? [y/N] ", terminator: "")
                    guard let a = readLine(), ["y", "yes"].contains(a.lowercased()) else { print("nothing logged"); return }
                }
                let r = try w.write(rows, day: day, commentKeys: comments)
                for l in r.lines { print("  " + l) }
                print("\(r.logged) written" + (r.failed > 0 ? ", \(r.failed) not written" : ""))
                if r.failed > 0 { throw ExitCode(1) }
            }
        }
    }

    struct ReconcileRange: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reconcile", abstract: "Sessions against your Jira worklogs over a range of days, per task and day; reads Jira only.")
        @Option(help: "First day, YYYY-MM-DD.") var from: String
        @Option(help: "Last day, YYYY-MM-DD, default today.") var to: String?
        @Flag(help: "Markdown: totals, tasks, each day with its sessions and worklogs.") var md = false
        @Flag(help: "CSV: a line per task and day.") var csv = false
        @Option(help: "user: your time | sessions: wall-clock time any session worked (default).") var time: TaskTime.Base?
        @OptionGroup var common: Common
        @OptionGroup var report: ReportOptions
        func validate() throws {
            if [report.json, md, csv].filter({ $0 }).count > 1 { throw ValidationError("one of --json, --md, --csv") }
        }
        func run() throws {
            let store = try prepare(common, report), w = try common.worklog(store, base: time)
            let r = try Settings.inZone(w.config.tz) { try w.reconcile(from: try LogCommand.day(from), to: try LogCommand.day(to)) }
            if report.json { print(try ReconcileText.json(r)) }
            else if md { print(ReconcileText.markdown(r)) }
            else if csv { print(ReconcileText.csv(r), terminator: "") }
            else { print(ReconcileText.text(r)) }
        }
    }

    struct Skip: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Do not log these plan rows (they stay out of later plans).")
        @Argument(help: "Row ids (#N in the plan).") var ids: [Int]
        @OptionGroup var common: Common
        func run() throws {
            let wl = Worklog(store: try common.open())
            for id in ids {
                if let r = try wl.skip(id) { print("  skipped #\(r.id) \(r.day) \(r.taskKey ?? "-")") }
                else { print("  #\(id): no planned row") }
            }
        }
    }

    struct Text: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "A plan row's worklog text: set it by hand or build it again.",
                                                        subcommands: [Set.self, Rebuild.self])
        struct Set: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Set a planned row's text by hand (a rebuild of the day keeps it); \"\" goes back to the built one.")
            @Argument(help: "Row id (#N in the plan).") var row: Int
            @Argument(help: "The text.") var text: String
            @Flag(help: "The task's day summary on this row instead of the row's text.") var summary = false
            @OptionGroup var common: Common
            @OptionGroup var report: ReportOptions
            func run() throws {
                let store = try common.open(), w = try common.worklog(store)
                try Settings.inZone(w.config.tz) {
                    let r = try w.setText(row: row, day: try LogCommand.rowDay(store, row), summary: summary, text: text)
                    if report.json { try emit(r) } else { print(TaskText.rows([r])) }
                }
            }
        }
        struct Rebuild: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Build a planned row's text again with one AI call (replaces a text set by hand).")
            @Argument(help: "Row id (#N in the plan).") var row: Int
            @Flag(help: "The task's day summary on this row instead of the row's text.") var summary = false
            @Flag(help: "Make the current text shorter instead (a text set by hand stays set by hand).") var shorten = false
            @OptionGroup var common: Common
            @OptionGroup var report: ReportOptions
            func run() throws {
                let store = try prepare(common, report), w = try common.worklog(store)
                try Settings.inZone(w.config.tz) {
                    let r = try w.rebuildText(row: row, day: try LogCommand.rowDay(store, row), summary: summary, shorten: shorten)
                    if report.json { try emit(r) } else { print(TaskText.rows([r]) + (summary ? "\n" + (r.summary ?? "") : "")) }
                }
            }
        }
    }

    /// The day of a plan row.
    static func rowDay(_ store: Store, _ id: Int) throws -> String {
        guard let d = try store.db.one("SELECT day FROM worklog_plan WHERE id = ?", [.int(Int64(id))], { $0.text(0) }) ?? nil else {
            throw ValidationError("no plan row #\(id)")
        }
        return d
    }

    struct Exclude: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Work that is never logged: a project, a task or a session ([worklog] exclude in config.toml).",
            discussion: "Excluded time is in no plan row, not in \"no task\" and not in log reconcile.",
            subcommands: [Add.self, Remove.self, List.self])
        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Exclude a project (folder or repository name), a task (key or #id) or a session (id).")
            @Argument(help: "project | task | session") var kind: String
            @Argument(help: "Its name, key or id.") var name: String
            @OptionGroup var common: Common
            func run() throws { try Exclude.change(common, kind, name, true) }
        }
        struct Remove: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "rm", abstract: "Count it again.")
            @Argument(help: "project | task | session") var kind: String
            @Argument(help: "Its name, key or id.") var name: String
            @OptionGroup var common: Common
            func run() throws { try Exclude.change(common, kind, name, false) }
        }
        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "What is excluded.")
            @OptionGroup var common: Common
            @Flag(help: "Print JSON: [{kind, name}].") var json = false
            func run() throws {
                let x = WorklogConfig.load(ZagonPaths(dir: common.dataDir)).exclude
                if json { try emit(x); return }
                print(x.isEmpty ? "nothing excluded" : x.map { "\($0.kind) \($0.name)" }.joined(separator: "\n"))
            }
        }
        static func change(_ c: Common, _ kind: String, _ name: String, _ on: Bool) throws {
            guard WorklogExclusion.kinds.contains(kind) else { throw ValidationError("kind must be project, task or session") }
            let x = WorklogExclusion(kind: kind, name: kind == "task" ? name.uppercased() : name)
            do {
                let changed = try WorklogConfig.setExcluded(ZagonPaths(dir: c.dataDir), x, on)
                print(changed ? (on ? "excluded \(kind) \(x.name)" : "\(kind) \(x.name) counts again") : "nothing to change")
            } catch { throw ValidationError("\(error)") }
        }
    }

    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or set [worklog] in config.toml: tz, projects, day_summary, rebuild_at_end.",
            discussion: "tz: the zone worklog days are cut in (system = the database's); projects: Jira project keys to count "
                + "besides Jira's own list, comma separated; day_summary, rebuild_at_end: true | false.")
        @Argument(help: "Key to set.") var key: String?
        @Argument(help: "Value.") var value: String?
        @Flag(help: "Print JSON.") var json = false
        @OptionGroup var common: Common
        func run() throws {
            let paths = ZagonPaths(dir: common.dataDir)
            if let key {
                guard let value else { throw ValidationError("a value is needed: zagon log config \(key) <value>") }
                do { try WorklogConfig.set(paths, key, value) } catch { throw ValidationError("\(error)") }
            }
            common.applyTimezone()
            let s = WorklogSettings(WorklogConfig.load(paths), jiraProjects: (try? common.open()).map { JiraCache.load($0).projects.sorted() } ?? [])
            if json { try emit(s); return }
            print("tz \(s.tz ?? "\(s.machineTz) (the database's zone)")\nprojects \(s.projects.joined(separator: ", "))"
                  + (s.jiraProjects.isEmpty ? "" : " (+ Jira: \(s.jiraProjects.joined(separator: ", ")))")
                  + "\nday_summary \(s.daySummary)\nrebuild_at_end \(s.rebuildAtEnd)"
                  + (s.exclude.isEmpty ? "" : "\nexclude " + s.exclude.map { "\($0.kind):\($0.name)" }.joined(separator: ", ")))
        }
    }

    /// For the service: at 23:55 in the worklog zone builds the day's texts again (once a day, `[worklog]
    /// rebuild_at_end`); prints the seconds until it is due next.
    struct AtEnd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "at-end", abstract: "Rebuild today's texts if it is 23:55 or later in the worklog zone; prints seconds to the next time.",
                                                        shouldDisplay: false)
        @OptionGroup var common: Common
        func run() throws {
            let store = try common.open(), w = try common.worklog(store)
            try Settings.inZone(w.config.tz) {
                let now = Time.now(), day = Time.dayString(now), (_, end) = Time.dayBounds(day)!, due = end - 300
                let mark = "wltext_auto:" + day
                if w.config.rebuildAtEnd, now >= due,
                   try store.db.one("SELECT 1 FROM meta WHERE key = ?", [.text(mark)], { _ in true }) != true {
                    // Marked first: a failed AI call must not come back every minute.
                    try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, 1)", [.text(mark)])
                    let p = try w.plan(day, refresh: true, now: now).plan
                    warn("worklog texts of \(day): " + (p.notes.first { $0.hasPrefix("texts not rebuilt") } ?? "rebuilt"))
                }
                print(Int(max(60, (now >= due ? Time.dayBounds(Time.addDays(day, 1)!)!.end - 300 : due) - Time.now())))
            }
        }
    }
}
