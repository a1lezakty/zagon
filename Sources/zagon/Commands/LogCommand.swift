import ArgumentParser
import ZagonCore

/// `zagon log …`: the day's worklog plan; writes to Jira only on `commit` after confirmation.
struct LogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log", abstract: "Worklog plan for a day; writes to Jira only on commit with confirmation.",
        subcommands: [Plan.self, Commit.self, Skip.self, ReconcileRange.self])

    static func day(_ d: String?) throws -> String {
        let day = d ?? Time.dayString(Time.now())
        guard Time.parseDay(day) != nil else { throw ValidationError("date must be YYYY-MM-DD") }
        return day
    }

    struct Plan: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "What to log: time per task, without overlapping Jira worklogs.")
        @Argument(help: "YYYY-MM-DD, default today.") var date: String?
        @Option(help: "user: your time | sessions: wall-clock time any session worked (default).") var time: TaskTime.Base?
        @OptionGroup var common: Common
        @OptionGroup var report: ReportOptions
        func run() throws {
            let store = try prepare(common, report), w = try common.worklog(store, base: time)
            let (p, err) = try w.plan(try LogCommand.day(date))
            if report.json { try emit(p); if let err { warn("jira: \(err)") }; return }
            print(TaskText.plan(p, base: w.base, jiraError: err))
        }
    }

    struct Commit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Re-plan the day, show it and write it to Jira (asks first).")
        @Argument(help: "YYYY-MM-DD, default today.") var date: String?
        @Flag(help: "Do not ask (scripts).") var yes = false
        @Option(help: "Write only if the rows are still those shown: commit_digest of `log plan --json`; else nothing is written, exit 3.")
        var expect: String?
        @Option(help: "user: your time | sessions: wall-clock time any session worked (default).") var time: TaskTime.Base?
        @OptionGroup var common: Common
        @OptionGroup var report: ReportOptions
        func run() throws {
            let day = try LogCommand.day(date), store = try prepare(common, report), w = try common.worklog(store, base: time)
            guard w.jira != nil else {
                throw ValidationError("Jira is not connected" + (w.jiraSetupError.map { ": \($0)" } ?? " ([jira] in config.toml)"))
            }
            // Always re-plan against fresh transcripts and fresh Jira: a plan from earlier may be stale.
            let rows = try w.plan(day, strict: true).plan.rows.filter { $0.state == "planned" && $0.jiraKey != nil }
            if let expect, DayPlan.commitDigest(rows) != expect {
                print("plan changed: nothing logged; show `zagon log plan \(day)` again")
                throw ExitCode(3)
            }
            guard !rows.isEmpty else { print("nothing to log to Jira for \(day)"); return }
            print(TaskText.rows(rows))
            if !yes {
                let total = rows.reduce(0) { $0 + $1.seconds }
                print("Log \(rows.count) worklogs (\(Fmt.dur(Double(total)))) to Jira? [y/N] ", terminator: "")
                guard let a = readLine(), ["y", "yes"].contains(a.lowercased()) else { print("nothing logged"); return }
            }
            let r = try w.write(rows, day: day)
            for l in r.lines { print("  " + l) }
            print("\(r.logged) worklogs logged" + (r.failed > 0 ? ", \(r.failed) not logged" : ""))
            if r.failed > 0 { throw ExitCode(1) }
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
            let r = try w.reconcile(from: try LogCommand.day(from), to: try LogCommand.day(to))
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
}
