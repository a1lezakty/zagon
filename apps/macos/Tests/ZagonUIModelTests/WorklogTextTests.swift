import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// "What to log" with texts per row (zagon 0.1.5): the plan's new fields as the core's contract sends them, a plan from
/// an older zagon read as before, and the CLI calls the screen and the settings make.
final class WorklogTextTests: XCTestCase {
    // 2026-10-31 in Asia/Nicosia (UTC+2): 15:45–16:45 and 22:00–23:45; the summary made at 23:50, now 23:58.
    static let day = "2026-10-31", now = Date(timeIntervalSince1970: 1_793_483_880)

    static func plan(new: Bool = true) -> String {
        let more = new ? """
            "tz":"Asia/Nicosia","summary_built_at":1793483400.0,"sessions_after_summary":2,
            "unassigned":[{"project":"example-project","seconds":3000},{"project":"—","seconds":1200}],
            "excluded":[{"kind":"project","name":"dotfiles","seconds":34800},{"kind":"session","name":"3f0c9a2e-0000","seconds":600},
                        {"kind":"task","name":"PROJ-9","seconds":0}],
            """ : ""
        let row1 = new ? """
            ,"text_source":"summary","day_summary":false,"summary":null,"summary_source":null,
            "sessions":[{"id":"a1","title":"worker-a","role":"worker","how":"brief","seconds":2400}]
            """ : ""
        let row2 = new ? """
            ,"text_source":"manual","day_summary":true,"summary":"What the task was\\nA check.","summary_source":"summary",
            "sessions":[{"id":"c3","title":"lead","role":"leader","how":"message","seconds":29100},
                        {"id":"a1","title":"worker-a","role":"worker","how":"odd","seconds":24600}]
            """ : ""
        return """
            {"day":"\(day)",\(more)"user_sec":30600,"session_sec":71400,"jira_sec":18000,"unassigned_sec":4200,"unknown_keys":[],
            "unplaced":{},"notes":[],"commit_digest":"9a1f","tasks":[],"rows":[
            {"id":41,"day":"\(day)","task_id":7,"task_key":"PROJ-1","jira_key":"PROJ-1","start":1793454300.0,"end":1793457900.0,
             "seconds":3600,"state":"planned","jira_worklog_id":null,"text":"Short text."\(row1)},
            {"id":44,"day":"\(day)","task_id":7,"task_key":"PROJ-1","jira_key":"PROJ-1","start":1793476800.0,"end":1793483100.0,
             "seconds":6300,"state":"planned","jira_worklog_id":null,"text":"Row text."\(row2)}]}
            """.replacingOccurrences(of: "\n", with: "")
    }

    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var all: [[String]] = []
        func add(_ a: [String]) { lock.lock(); all.append(a); lock.unlock() }
    }

    func backend(_ calls: Calls, plan: String = WorklogTextTests.plan()) -> TaskBackend {
        TaskBackend(source: .server("build-box")) { args, _ in
            calls.add(args)
            let out: String
            switch (args.first, args.dropFirst().first) {
            case ("log", "plan"): out = plan
            // As the core of 0.1.5 answers: the line of 0.1.4, then the day summary comments.
            case ("log", "commit"): out = """
                  logged #41 PROJ-1 15:45–16:45 1h
                  not logged #44 PROJ-1 22:00–23:45: overlaps a worklog now in Jira
                1 worklogs logged, 1 not logged
                  commented day summary on PROJ-1
                  day summary on PROJ-2 already commented
                  not sure day summary on PROJ-3 reached Jira (timeout): the next commit checks Jira first
                1 comments written, 1 not written
                """
            case ("log", "config"):
                out = #"{"tz":"Asia/Nicosia","machine_tz":"Asia/Almaty","projects":["OPS"],"jira_projects":["PROJ","OPS"],"day_summary":true,"rebuild_at_end":false,"exclude":[{"kind":"project","name":"dotfiles"}]}"#
            default: out = ""
            }
            return Proc.Result(status: 0, out: Data(out.utf8), err: Data())
        }
    }

    static func fmt(_ lang: Lang) -> Fmt { Fmt(lang: lang, timeZone: TimeZone(identifier: "Asia/Nicosia")!, now: now) }

    func testPlanTextsSessionsAndExclusions() throws {
        let calls = Calls()
        let plan = try backend(calls).plan(Self.day)
        XCTAssertEqual(plan.zone, "Asia/Nicosia")
        XCTAssertEqual(plan.newSessions, 2)
        let f = Self.fmt(.en), w = plan.worklog(f)
        XCTAssertEqual(w.zone, "Asia/Nicosia")
        XCTAssertEqual(w.texts, WorklogSummaryInfo(builtAt: Date(timeIntervalSince1970: 1_793_483_400), newSessions: 2))
        XCTAssertEqual(w.rows.map(\.textSource), [.summary, .manual])
        XCTAssertEqual(w.rows.map(\.daySummary), [false, true])
        XCTAssertEqual(w.rows[1].written, "Row text.\n\nWhat the task was\nA check.", "the day summary goes under the text")
        XCTAssertEqual(w.rows[0].written, "Short text.")
        XCTAssertEqual(w.excluded.map(\.name), ["dotfiles", "3f0c9a2e-0000"], "no line for an exclusion with no time that day")
        XCTAssertEqual(w.unassigned, [WorklogPart(kind: "project", name: "example-project", sec: 3000), WorklogPart(kind: "project", name: "—", sec: 1200)])
        XCTAssertFalse(w.notes.contains { $0.contains("linked to no task") }, "time with no task is shown by project instead")

        let vm = WorklogVM(w, f, machine: TimeZone(identifier: "Asia/Almaty"), host: "build-box")
        XCTAssertEqual(vm.textsTitle, "Texts from the day summary")
        XCTAssertEqual(vm.textsDetail, "rebuilt 23:50 · 2 sessions · 2 sessions after it")
        XCTAssertEqual(vm.zoneLine, "Worklog time zone: Asia/Nicosia · UTC+2 · the day is 00:00–24:00 in it, not in Zagon's zone (Asia/Almaty · UTC+5)")
        XCTAssertEqual(vm.rows.map(\.span), [f.timeSpan(w.rows[0].start, w.rows[0].end), f.timeSpan(w.rows[1].start, w.rows[1].end)])
        XCTAssertTrue(vm.rows[0].span.hasPrefix("15:45"), "intervals in the worklog zone: \(vm.rows[0].span)")
        XCTAssertEqual(vm.rows[1].sessions.map(\.role), ["leader", "worker"])
        XCTAssertEqual(vm.rows[1].sessions.map(\.how), ["build-box · key PROJ-1 in the request", "build-box · odd"], "an unknown way as it came")
        XCTAssertEqual(vm.rows[1].explain,
                       "The text is about all the work on PROJ-1 that day. Session hours run in parallel; the worklog's time is yours, \(vm.rows[1].span).")
        XCTAssertTrue(vm.rows.allSatisfy(\.editable))
        XCTAssertEqual(vm.excluded.map(\.text), ["Excluded: 9h 40m — dotfiles", "Excluded: 10m — session 3f0c9a2e"])
        XCTAssertEqual(vm.unassigned.map(\.text), ["No task: 50m — example-project", "No task: 20m — no project"])
        XCTAssertEqual(vm.unassigned.map(\.action), [true, false], "time of no project cannot be kept out")
        XCTAssertEqual(vm.rows.map(\.anchor), ["1793397600|PROJ-1|1793454300", "1793397600|PROJ-1|summary"])
        XCTAssertEqual(vm.commitNotes, ["Day summary of PROJ-1: in its worklog, under the row's text."])
        XCTAssertTrue(ReconcileVM.confirmation(plan, key: "PROJ-1", f).detail.hasSuffix("\nDay summary of PROJ-1: in its worklog, under the row's text."),
                      "the period's confirmation says it too")
        XCTAssertTrue(vm.copyText.contains("Row text.\n\nWhat the task was"))

        let ru = WorklogVM(plan.worklog(Self.fmt(.ru)), Self.fmt(.ru), machine: TimeZone(identifier: "Asia/Nicosia"), host: nil)
        XCTAssertEqual(ru.textsDetail, "пересобрано 23:50 · 2 сессии · есть 2 новые")
        XCTAssertEqual(ru.zoneLine, "Пояс ворклогов: Asia/Nicosia · UTC+2 · день 00:00–24:00, как в Zagon")
        XCTAssertEqual(ru.rows[0].sessions.map(\.how), ["ключ PROJ-1 в брифе"])
        XCTAssertEqual(ru.unassigned.map(\.text).last, "Без задачи: 20 мин — без проекта")
    }

    func testNoSummaryYetAndAnOlderZagon() throws {
        let calls = Calls()
        let none = Self.plan().replacingOccurrences(of: #""summary_built_at":1793483400.0"#, with: #""summary_built_at":null"#)
        let vm = WorklogVM(try backend(calls, plan: none).plan(Self.day).worklog(Self.fmt(.ru)), Self.fmt(.ru))
        XCTAssertEqual(vm.textsTitle, "Сводки дня нет")
        XCTAssertEqual(vm.textsDetail, "тексты по названиям сессий · 2 сессии")

        let old = try backend(calls, plan: Self.plan(new: false)).plan(Self.day)
        XCTAssertNil(old.zone)
        let w = old.worklog(Self.fmt(.en))
        XCTAssertNil(w.texts)
        XCTAssertEqual(w.rows.map(\.textSource), [nil, nil])
        XCTAssertTrue(w.unassigned.isEmpty)
        XCTAssertTrue(w.notes.contains("1h 10m in sessions linked to no task."), "\(w.notes)")
        let ovm = WorklogVM(w, Self.fmt(.en))
        XCTAssertNil(ovm.textsTitle)
        XCTAssertNil(ovm.zoneLine)
        XCTAssertFalse(ovm.rows.contains(where: \.editable), "no text editing against an older zagon")
    }

    func testCallsOfTheScreenAndTheSettings() throws {
        let calls = Calls(), b = backend(calls)
        let shown = try b.plan(Self.day, refresh: true, scan: false, comments: ["PROJ-1"])
        XCTAssertEqual(calls.all.last, ["log", "plan", "--json", "--refresh", "--no-scan", "--with-summary", "--summary-comment=PROJ-1", "--", Self.day])
        let w = shown.worklog(Self.fmt(.en))
        XCTAssertTrue(w.rows[1].summaryAsComment)
        XCTAssertEqual(w.rows[1].written, "Row text.", "the summary goes as a comment, the worklog keeps the text")
        XCTAssertEqual(WorklogVM(w, Self.fmt(.ru)).commitNotes, ["Итог дня по PROJ-1 — отдельным комментарием к задаче, один на задачу и день."])

        guard case .written(let logged, let failed, let problems) = try b.commit(Self.day, shown: shown) else { return XCTFail("not written") }
        XCTAssertEqual([logged, failed], [2, 2], "worklogs and comments both count")
        XCTAssertEqual(problems, ["not logged #44 PROJ-1 22:00–23:45: overlaps a worklog now in Jira", "day summary on PROJ-2 already commented",
                                  "not sure day summary on PROJ-3 reached Jira (timeout): the next commit checks Jira first"])
        XCTAssertEqual(calls.all.last, ["log", "commit", "--yes", "--no-scan", "--expect", "9a1f", "--with-summary", "--summary-comment=PROJ-1",
                                        "--", Self.day], "the commit makes the same day summary choice as the plan shown (its digest counts it)")
        guard case .written(let n, let bad, let why) = try b.written(Proc.Result(status: 1, out: Data(
            "0 worklogs logged\n  day summary on PROJ-1 not written: HTTP 400\n0 comments written, 1 not written\n".utf8), err: Data()))
        else { return XCTFail("not read") }
        XCTAssertEqual([n, bad], [0, 1])
        XCTAssertEqual(why, ["day summary on PROJ-1 not written: HTTP 400"])

        try b.setText(44, "-starts with a dash", summary: true)
        XCTAssertEqual(calls.all.last, ["log", "text", "set", "44", "--summary", "--", "-starts with a dash"])
        try b.rebuildText(41, summary: false, shorten: true)
        XCTAssertEqual(calls.all.last, ["log", "text", "rebuild", "41", "--shorten"])
        try b.exclude("project", "example-project", add: true)
        XCTAssertEqual(calls.all.last, ["log", "exclude", "add", "project", "--", "example-project"])
        try b.exclude("task", "PROJ-1", add: false)
        XCTAssertEqual(calls.all.last, ["log", "exclude", "rm", "task", "--", "PROJ-1"])
        try b.setWorklogConfig("projects", "OPS,DATA")
        XCTAssertEqual(calls.all.last, ["log", "config", "projects", "--", "OPS,DATA"])
        XCTAssertEqual(try b.worklogConfig(), TaskBackend.WorklogConfig(
            tz: "Asia/Nicosia", machineTz: "Asia/Almaty", projects: ["OPS"], jiraProjects: ["PROJ", "OPS"], daySummary: true,
            rebuildAtEnd: false, exclude: [.init(kind: "project", name: "dotfiles")]))
        let older = TaskBackend(source: .local) { _, _ in
            Proc.Result(status: 64, out: Data(), err: Data("Error: Unexpected argument 'config'\nUsage: zagon log <subcommand>\n".utf8))
        }
        XCTAssertNil(try older.worklogConfig(), "a zagon from before `log config`: the card says so instead of failing")

        try b.editProjects(add: "DATA", remove: nil)
        XCTAssertEqual(calls.all.suffix(2), [["log", "config", "--json"], ["log", "config", "projects", "--", "OPS,DATA"]],
                       "each machine's own list: read there, one key added")
        XCTAssertEqual(TaskBackend.edited(["OPS", "DATA"], add: nil, remove: "OPS"), ["DATA"])
        XCTAssertEqual(TaskBackend.edited(["OPS"], add: "OPS", remove: nil), ["OPS"])
    }

    func testAnOlderZagonIsAskedWithoutDaySummaries() throws {
        let calls = Calls(), plan = Self.plan(new: false)
        let b = TaskBackend(source: .local) { args, _ in
            calls.add(args)
            if args.contains("--with-summary") { return Proc.Result(status: 64, out: Data(), err: Data("Error: Unknown option '--with-summary'\n".utf8)) }
            return Proc.Result(status: 0, out: Data((args[1] == "plan" ? plan : "1 worklogs logged").utf8), err: Data())
        }
        let p = try b.plan(Self.day)
        XCTAssertFalse(p.summaries)
        XCTAssertEqual(calls.all, [["log", "plan", "--json", "--with-summary", "--", Self.day], ["log", "plan", "--json", "--", Self.day]])
        _ = try b.commit(Self.day, shown: p)
        XCTAssertEqual(calls.all.last, ["log", "commit", "--yes", "--no-scan", "--expect", "9a1f", "--", Self.day])
    }

    func testRebuildOnOpening() throws {
        let p = try backend(Calls()).plan(Self.day), yesterday = "2026-10-30", now = Self.now
        XCTAssertFalse(p.staleOnOpen(day: Self.day, today: Self.day, yesterday: yesterday, now: now), "the summary is 8 minutes old")
        XCTAssertTrue(p.staleOnOpen(day: Self.day, today: "2026-11-01", yesterday: Self.day, now: now.addingTimeInterval(3600)), "yesterday, an hour later")
        XCTAssertFalse(p.staleOnOpen(day: Self.day, today: "2026-11-03", yesterday: "2026-11-02", now: now.addingTimeInterval(3 * 86400)),
                       "browsing back costs no AI calls")
        let none = try backend(Calls(), plan: Self.plan().replacingOccurrences(of: #""summary_built_at":1793483400.0"#, with: #""summary_built_at":null"#))
            .plan(Self.day)
        XCTAssertTrue(none.staleOnOpen(day: Self.day, today: Self.day, yesterday: yesterday, now: now))
        let fresh = try backend(Calls(), plan: Self.plan().replacingOccurrences(of: #""sessions_after_summary":2"#, with: #""sessions_after_summary":0"#))
            .plan(Self.day)
        XCTAssertFalse(fresh.staleOnOpen(day: Self.day, today: Self.day, yesterday: yesterday, now: now.addingTimeInterval(3600)))
        XCTAssertFalse(try backend(Calls(), plan: Self.plan(new: false)).plan(Self.day)
            .staleOnOpen(day: Self.day, today: Self.day, yesterday: yesterday, now: now), "an older zagon has no rebuild")
    }
}
