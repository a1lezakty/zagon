import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// The period on the worklog screen: the CLI's JSON read as it comes, the groups, totals, days and exports made of it.
final class ReconcileTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    /// Saturday 31 Oct 2026, noon.
    var now: Date { StoreDataProvider.start("2026-10-31", utc).addingTimeInterval(12 * 3600) }
    func fmt(_ lang: Lang = .en) -> Fmt { Fmt(lang: lang, timeZone: utc, now: now) }
    var sample: Reconciliation { .sample(now: now, zone: utc) }

    /// `zagon log reconcile --json` as the core prints it (snake_case, sorted keys, nil fields left out).
    let json = """
        {"base":"sessions","coverage_from":"2026-10-02","days":[{"before_coverage":true,"day":"2026-10-01","jira_only_sec":0,"jira_sec":7200,\
        "rows":[],"session_sec":0,"unlogged_sec":0},{"before_coverage":false,"day":"2026-10-28","jira_only_sec":0,"jira_sec":0,"rows":[\
        {"done":"Dark theme.","jira_key":"PROJ-21","jira_sec":0,"key":"PROJ-21","session_sec":12600,"sessions":[{"branch":"PROJ-21-dark",\
        "host":"build-box","id":"s1","project":"web-app","sec":12600,"title":"web-app — dark theme","tool":"claude"}],"status":"only_sessions",\
        "task_id":4,"title":"Settings page","worklogs":[]},{"branch":"main","jira_sec":0,"project":"scripts","session_sec":600,"sessions":[],\
        "status":"no_task","worklogs":[]}],"session_sec":13200,"unlogged_sec":13200}],"from":"2026-10-01","jira":"connected",\
        "tasks":[{"jira_key":"PROJ-21","jira_sec":0,"key":"PROJ-21","session_sec":12600,"sessions":[],"status":"only_sessions","task_id":4,\
        "title":"Settings page","worklogs":[]},{"branch":"main","jira_sec":0,"project":"scripts","session_sec":600,"sessions":[],\
        "status":"no_task","worklogs":[]}],"to":"2026-10-31","to_requested":"2026-11-27","tolerance_min":15,"totals":{"jira_before_coverage_sec":7200,\
        "jira_only_sec":0,"jira_sec":0,"no_task_sec":600,"session_sec":13200,"unlogged_sec":13200,"zagon_only_sec":0}}
        """

    func testReadsTheCLIAnswer() throws {
        let calls = Calls(), out = Data(("Last login: a banner\n" + json + "\n").utf8)
        let b = TaskBackend(source: .server("build-box")) { args, timeout in
            calls.add(args.joined(separator: " ") + " @\(Int(timeout))")
            return Proc.Result(status: 0, out: out, err: Data())
        }
        let r = try b.reconcile(from: "2026-10-01", to: "2026-11-27")
        XCTAssertEqual(calls.all, ["log reconcile --json --from 2026-10-01 --to 2026-11-27 @300"])
        XCTAssertEqual(r.coverageFrom, "2026-10-02")
        XCTAssertEqual(r.toRequested, "2026-11-27")
        XCTAssertEqual(r.totals.jiraBeforeCoverageSec, 7200)
        XCTAssertEqual(r.days.count, 2)
        XCTAssertTrue(r.days[0].beforeCoverage)
        XCTAssertEqual(r.days[1].rows[0].sessions?.first?.branch, "PROJ-21-dark")
        XCTAssertEqual(r.tasks.map(\.id), ["t4", "-scripts|main"])

        let vm = ReconcileVM(r, fmt())
        XCTAssertEqual(vm.groups.map(\.kind), [.onlySessions, .noTask])
        XCTAssertEqual(vm.days("t4").map(\.action), ["Log 3h 30m"])
        XCTAssertEqual(vm.days("-scripts|main").map(\.action), [nil])
        XCTAssertTrue(vm.hint.hasPrefix("November 27 has not come yet: counted to today, October 31."), vm.hint)
        XCTAssertEqual(vm.coverage?.bold, "on October 2")
    }

    func testAnswerFromAnotherVersionIsAFailure() {
        let b = TaskBackend(source: .local) { _, _ in Proc.Result(status: 0, out: Data("{\"from\":1}".utf8), err: Data()) }
        XCTAssertThrowsError(try b.reconcile(from: "2026-10-01", to: "2026-10-31")) {
            XCTAssertTrue(String(describing: $0).contains("another version"), "\($0)")
        }
    }

    func testSampleAddsUpAsTheCLIDoes() {
        let r = sample, t = r.totals
        XCTAssertEqual(t.sessionSec - t.jiraSec, t.unloggedSec - t.jiraOnlySec)
        let counted = r.days.filter { !$0.beforeCoverage }
        XCTAssertEqual(counted.reduce(0) { $0 + $1.sessionSec }, t.sessionSec)
        XCTAssertEqual(counted.reduce(0) { $0 + $1.jiraSec }, t.jiraSec)
        XCTAssertEqual(r.tasks.reduce(0) { $0 + $1.sessionSec }, t.sessionSec)
        XCTAssertEqual(r.days.filter(\.beforeCoverage).reduce(0) { $0 + $1.jiraSec }, t.jiraBeforeCoverageSec)
        XCTAssertEqual([r.from, r.coverageFrom, r.to, r.toRequested], ["2026-09-01", "2026-09-30", "2026-10-31", "2026-11-27"])
    }

    func testGroupsFiltersAndTotals() {
        let vm = ReconcileVM(sample, fmt())
        XCTAssertEqual(vm.groups.map(\.kind), [.onlySessions, .mismatch, .onlyJira, .match, .zagonOnly, .noTask])
        XCTAssertEqual(vm.groups.map(\.rows.count), [3, 3, 2, 5, 2, 2])
        XCTAssertEqual(vm.filters.map(\.title), ["All · 17", "Not in Jira · 3", "Apart · 3", "Not in sessions · 2", "Match · 5",
                                                 "Only in Zagon · 2", "No task · 2"])
        XCTAssertEqual(vm.groups(.onlyJira).map(\.kind), [.onlyJira])
        XCTAssertEqual(vm.count(vm.groups[5]), "2 places")
        XCTAssertEqual(ReconcileVM(sample, fmt(.ru)).count(vm.groups[0]), "3 задачи")

        let apart = vm.groups[1].rows
        XCTAssertEqual(apart.map(\.key), ["PROJ-21", "PROJ-12", "PROJ-18"])
        XCTAssertEqual(apart.map(\.diff), ["+4h 40m", "+3h 50m", "−1h 50m"])
        XCTAssertEqual(apart.map(\.sign), [1, 1, -1])
        XCTAssertEqual(vm.groups[3].rows.map(\.sign), [0, 0, 0, 0, 0])
        XCTAssertNil(vm.groups[4].rows[0].diff)  // no Jira side
        XCTAssertEqual(vm.groups[5].rows.first?.title, "web-app · branch fix/login-redirect")
        XCTAssertEqual(vm.groups[2].jira, "6h 00m")
        XCTAssertEqual(vm.groups[2].sessions, "—")

        // Over two days of work: hours, not "6d 1h"; not logged and beyond sessions add up per task and day.
        XCTAssertEqual(vm.stats.map(\.value), ["145h 20m", "110h 20m", "10h 10m", "45h 10m"])
        XCTAssertEqual(vm.total.diff, "+35h 00m")
        XCTAssertEqual(vm.stats[0].label, "work in sessions, Sep 30–Oct 31")
        XCTAssertEqual(vm.notes.count, 3)
    }

    func testChart() {
        let vm = ReconcileVM(sample, fmt())
        XCTAssertEqual(vm.bars.count, 88)  // 1 Sep … 27 Nov
        XCTAssertEqual(vm.coverageIndex, 29)
        XCTAssertEqual(vm.todayIndex, 60)
        XCTAssertEqual(vm.bars[61].kind, .future)
        XCTAssertEqual(vm.bars[10].kind, .before)
        XCTAssertEqual(vm.bars[59].kind, .counted)
        let wide = vm.ticks(slot: 11), narrow = vm.ticks(slot: 5)
        XCTAssertEqual(wide.first?.label, "Sep 1")
        XCTAssertTrue(wide.contains { $0.index == 30 && $0.label == "Oct 1" })
        XCTAssertTrue(wide.contains { $0.index == 6 && $0.label == "7" })  // a Monday
        XCTAssertTrue(wide.contains { $0.index == 34 && $0.label == "5" })
        XCTAssertTrue(narrow.contains { $0.index == 30 })
        XCTAssertFalse(narrow.contains { $0.index == 27 || $0.index == 34 })  // Mondays 28 Sep and 5 Oct would sit on "Oct 1"
        for (slot, ticks) in [(11.0, wide), (5.0, narrow)] {
            for (a, b) in zip(ticks, ticks.dropFirst()) {
                XCTAssertLessThan(Double(a.index) * slot + Double(a.label.count) * 7, Double(b.index) * slot, "\(a.label) on \(b.label)")
            }
        }
    }

    func testAxisFirstDayNextToMonth() {
        // From Aug 31: the first day's label would sit on "Sep 1", the month stays.
        let vm = ReconcileVM(.sample(now: StoreDataProvider.start("2026-10-30", utc).addingTimeInterval(12 * 3600), zone: utc), fmt())
        XCTAssertEqual(vm.ticks(slot: 11).prefix(2).map { $0.label }, ["Sep 1", "7"])
        XCTAssertEqual(vm.ticks(slot: 60).prefix(2).map { $0.label }, ["Aug 31", "Sep 1"])  // room for both
        let ru = ReconcileVM(.sample(now: StoreDataProvider.start("2026-10-30", utc).addingTimeInterval(12 * 3600), zone: utc), fmt(.ru))
        XCTAssertEqual(ru.ticks(slot: 11).first?.index, 1)
    }

    func testOpenTaskDayByDay() {
        let vm = ReconcileVM(sample, fmt())
        let days = vm.days("t4")  // PROJ-21
        XCTAssertEqual(days.map(\.day), ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29",
                                         "2026-10-30"])
        XCTAssertEqual(days.map(\.kind), [.match, .match, .match, .match, .mismatch, .onlySessions, .onlyJira, .mismatch])
        XCTAssertEqual(days.map(\.action), [nil, nil, nil, nil, "Add 2h 20m", "Log 3h 30m", nil, "Add 40m"])
        XCTAssertEqual(days.map(\.primary), [false, false, false, false, false, true, false, false])
        XCTAssertEqual(days[5].title, "Wed, October 28")
        XCTAssertEqual(days[5].sessions.first?.meta, "build-box · Claude · branch PROJ-21-settings-page")
        XCTAssertEqual(days[6].sessionTime, "—")
        XCTAssertEqual(days[6].worklogs.first?.span, "10:00–12:00 · 2h 00m")
        XCTAssertEqual(vm.dayGroups.first?.title, "Thu, October 1 · sessions 4h 30m · Jira 4h 40m")
    }

    func testWithoutJira() {
        let vm = ReconcileVM(.sample(now: now, zone: utc, jira: false), fmt())
        XCTAssertFalse(vm.connected)
        XCTAssertEqual(vm.warnings, ["Jira is not connected: sessions only."])
        XCTAssertEqual(vm.stats.count, 3)
        XCTAssertNil(vm.coverage?.after.range(of: "Jira worklogs"))
        XCTAssertFalse(vm.groups.contains { $0.kind == .onlyJira })
        XCTAssertTrue(vm.days("t4").allSatisfy { $0.action == nil })  // nothing can go to Jira
        XCTAssertEqual(vm.notes, [])
        XCTAssertFalse(vm.hint.contains("Match"))
    }

    func testNothingAtAll() {
        let vm = ReconcileVM(.sample(now: now, zone: utc, empty: true), fmt(.ru))
        XCTAssertTrue(vm.empty)
        XCTAssertNil(vm.coverage)
        XCTAssertEqual(vm.warnings, ["Сессий пока нет — сверять нечего."])
        XCTAssertTrue(vm.markdown().contains("За этот период нет ни работы, ни ворклогов."))
        XCTAssertEqual(vm.csv(), "day,key,jira_key,title,status,sessions_min,jira_min,diff_min,sessions,worklogs\n")
    }

    func testExports() {
        let vm = ReconcileVM(sample, fmt())
        let md = vm.markdown()
        XCTAssertTrue(md.hasPrefix("# Sessions against Jira · Sep 1–Nov 27\n"), md)
        XCTAssertTrue(md.contains("| not logged | 45h 10m |"))
        XCTAssertTrue(md.contains("| PROJ-21 | Web app: settings page, dark theme | 31h 20m | 26h 40m | +4h 40m | apart |"))
        XCTAssertTrue(md.contains("| **Period total** | | **145h 20m** | **110h 20m** | **+35h 00m** | |"))
        XCTAssertTrue(md.contains("### Wed, October 28 · sessions"))
        XCTAssertTrue(md.contains("  - Jira 10:00–12:00 · 2h 00m · Web app: settings page, dark theme"))
        var only = ReconcileVM.Sections()
        only.days = false
        only.totals = false
        let tasks = vm.markdown(only)
        XCTAssertFalse(tasks.contains("## Totals"))
        XCTAssertFalse(tasks.contains("## By day"))
        XCTAssertTrue(tasks.contains("## Tasks"))

        let csv = vm.csv().split(separator: "\n")
        XCTAssertEqual(csv.count, 1 + sample.days.reduce(0) { $0 + $1.rows.count })
        XCTAssertTrue(csv.contains("2026-10-28,PROJ-21,PROJ-21,\"Web app: settings page, dark theme\",only_sessions,210,0,210,"
                                   + "\"web-app — web app: settings page, dark theme\","))
        XCTAssertTrue(csv.contains { $0.hasPrefix("2026-10-29,PROJ-21,PROJ-21,") && $0.contains(",only_jira,0,120,-120,,\"10:00–12:00 ") })
        XCTAssertEqual(vm.fileName(csv: true), "zagon-reconcile-2026-09-01_2026-11-27.csv")
    }

    func testConfirmationListsTheDayPlan() throws {
        func plan(_ rows: String) throws -> WorklogPlan {
            let line = Data("""
                {"commit_digest":"ab","day":"2026-10-28","jira_sec":0,"notes":[],"rows":[\(rows)],"session_sec":12600,"tasks":[],\
                "unassigned_sec":0,"unknown_keys":[],"unplaced":{},"user_sec":12600}
                """.utf8)
            return WorklogPlan(plan: try TaskBackend.parse(line, ["log", "plan"]), jiraError: nil, digest: "ab")
        }
        let start = StoreDataProvider.start("2026-10-28", utc).timeIntervalSince1970 + 10 * 3600
        let row = """
            {"day":"2026-10-28","end":\(start + 12600),"id":3,"jira_key":"PROJ-21","seconds":12600,"start":\(start),"state":"planned",\
            "task_key":"PROJ-21","text":"Dark theme."}
            """
        let logged = row.replacingOccurrences(of: "\"planned\"", with: "\"logged\"")
        let c = ReconcileVM.confirmation(try plan(row + "," + logged), key: "PROJ-21", fmt())
        XCTAssertEqual(c.title, "Log 1 worklog to Jira · 3h 30m?")
        XCTAssertEqual(c.detail, "The whole day's plan, all tasks, Wed, October 28:\nPROJ-21 10:00–13:30 · 3h 30m — Dark theme.\n"
                       + "The plan is checked again just before writing.")
        // The row pressed is not in the plan: the others would be written, so it says so.
        XCTAssertTrue(ReconcileVM.confirmation(try plan(row), key: "PROJ-40", fmt()).detail
            .hasSuffix("\nPROJ-40 is not in the day's plan: its time did not fit, or it is already logged."))
        let none = ReconcileVM.confirmation(try plan(logged), key: "PROJ-21", fmt())
        XCTAssertNil(none.title)
        XCTAssertEqual(none.detail, "Wed, October 28: the day's plan has nothing for Jira.")
        // What `commit` refuses is not offered.
        var failed = try plan(row)
        failed.jiraError = "HTTP 401"
        XCTAssertNil(ReconcileVM.confirmation(failed, key: "PROJ-21", fmt()).title)
        failed.jiraError = nil
        failed.plan.jiraSec = nil
        XCTAssertEqual(ReconcileVM.confirmation(failed, key: "PROJ-21", fmt()).title, nil)
    }

    func testQuickPeriods() {
        let f = fmt(), d = { StoreDataProvider.day($0, self.utc) }
        func range(_ p: RecPeriod) -> [String] { let r = p.range(f); return [d(r.from), d(r.to)] }
        XCTAssertEqual(range(.today), ["2026-10-31", "2026-10-31"])
        XCTAssertEqual(range(.yesterday), ["2026-10-30", "2026-10-30"])
        XCTAssertEqual(range(.thisWeek), ["2026-10-26", "2026-11-01"])
        XCTAssertEqual(range(.lastWeek), ["2026-10-19", "2026-10-25"])
        XCTAssertEqual(range(.thisMonth), ["2026-10-01", "2026-10-31"])
        XCTAssertEqual(range(.lastMonth), ["2026-09-01", "2026-09-30"])
        func shift(_ a: String, _ b: String, _ dir: Int) -> [String] {
            let r = RecPeriod.shift(StoreDataProvider.start(a, utc), StoreDataProvider.start(b, utc), by: dir, f)
            return [d(r.from), d(r.to)]
        }
        XCTAssertEqual(shift("2026-10-01", "2026-10-31", 1), ["2026-11-01", "2026-11-30"])
        XCTAssertEqual(shift("2026-09-01", "2026-10-31", -1), ["2026-07-01", "2026-08-31"])
        XCTAssertEqual(shift("2026-10-26", "2026-11-01", -1), ["2026-10-19", "2026-10-25"])
        XCTAssertEqual(shift("2026-09-01", "2026-11-27", 1), ["2026-11-28", "2027-02-23"])
    }

    func testPeriodBeforeTheSessionsAndPastPeriod() {
        var r = sample
        r.toRequested = "2026-09-20"
        r.to = "2026-09-20"
        let vm = ReconcileVM(r, fmt())
        XCTAssertEqual(vm.coverageIndex, vm.bars.count)  // all of it before the sessions
        XCTAssertNil(vm.todayIndex)  // nothing to come: no line at the right edge
    }

    func testEveryKeyInBothLanguages() {
        let en = Set(Strings.en.keys.filter { $0.hasPrefix("rec.") }), ru = Set(Strings.ru.keys.filter { $0.hasPrefix("rec.") })
        XCTAssertEqual(en.subtracting(ru.map { $0.replacingOccurrences(of: ".few", with: ".many") }), [])
        for k in RecKind.allCases { for p in ["rec.f.", "rec.g.", "rec.k."] { XCTAssertNotNil(Strings.ru[p + k.rawValue], p + k.rawValue) } }
        for p in RecPeriod.allCases { XCTAssertNotNil(Strings.en["rec.q." + p.rawValue]) }
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    func add(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}
