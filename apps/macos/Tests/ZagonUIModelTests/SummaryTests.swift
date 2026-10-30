import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// Written summaries on the screens: cards of a doc, the fallback without one, the `zagon summary` answers and flow,
/// and `[summary] time` in config.toml.
final class SummaryTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    var at: Date { Date(timeIntervalSince1970: 1_793_390_400) }  // 2026-10-30 20:00 UTC
    var f: Fmt { Fmt(lang: .en, timeZone: utc, now: at) }

    var doc: SummaryDoc {
        SummaryDoc(lang: "en", from: "2026-10-30", to: "2026-10-30", overview: "A day on the webhook.", items: [
            .init(project: "api-server", key: "PROJ-12", title: "Webhook retries", was: "Charged twice.", done: ["Key on retries", "Tests"],
                  left: "Load test.", sec: 4500, cost: 12.4),
            .init(project: "api-server", title: "Logs", done: ["Fewer lines"]),
            .init(project: "", title: "Notes", done: ["Wrote them"], sec: 600, cost: 0.3),
            .init(project: "web-app", title: "Theme", done: ["Dark"], sec: 1200),
        ])
    }

    func testCardsOfADoc() {
        let vm = SummaryVM(KeptSummary(doc: doc, engine: "claude", at: at), period: false, f)
        XCTAssertEqual(vm.overview, "A day on the webhook.")
        XCTAssertEqual(vm.cards.map(\.title), ["api-server · PROJ-12 Webhook retries — 1h 15m, $12", "api-server · Logs",
                                              "Notes — 10m, <$1", "web-app · Theme — 20m"])
        XCTAssertEqual(vm.cards[0].was, "Charged twice.")
        XCTAssertEqual(vm.cards[0].done, ["Key on retries", "Tests"])
        XCTAssertEqual(vm.cards[0].left, "Load test.")
        XCTAssertNil(vm.cards[1].was)
        XCTAssertNil(vm.cards[1].left)
        XCTAssertEqual(vm.cards.map(\.color), [Palette.series(0), Palette.series(0), Palette.series(1), Palette.series(2)])
        XCTAssertEqual(vm.note, "Summary written by Claude at 20:00.")
        XCTAssertEqual(vm.markdown, doc.text(markdown: true))
        XCTAssertEqual(SummaryVM(KeptSummary(doc: doc, engine: "none", at: at), period: true, f).note,
                       "Made without AI from the sessions' data, Oct 30 20:00.")

        // The cards keep the doc's language; the note follows the app's.
        var ru = doc
        ru.lang = "ru"
        let r = SummaryVM(KeptSummary(doc: ru, engine: "codex", at: at), period: true, f)
        XCTAssertEqual([r.wasLabel, r.doneLabel, r.leftLabel, r.mainLabel], ["Что было", "Что сделано", "Что осталось", "Главное за период"])
        XCTAssertEqual(r.cards[0].title, "api-server · PROJ-12 Webhook retries — 1 ч 15 м, $12")
        XCTAssertEqual(r.note, "Summary written by Codex on Oct 30 at 20:00.")
    }

    func testDayWithAndWithoutADoc() {
        let projects = [DoneProject("api-server", sec: 3720, cost: 8, sessions: [DoneSession("PROJ-12", branch: "PROJ-12-check", sec: 3700),
                                                                                  DoneSession("quick look", sec: 20)]),
                        DoneProject("", sec: 600, cost: 0, sessions: [DoneSession("scratch", sec: 600)])]
        let none = DayVM(DayData(day: at, totals: Totals(sessionSec: 4320, tokens: 10, cost: 8), projects: projects), f)
        XCTAssertNil(none.summary)
        XCTAssertNil(none.summaryNote)
        XCTAssertEqual(none.projects.map(\.name), ["api-server", "other"])
        XCTAssertEqual(none.projects.map(\.numbers), ["1h 02m · $8", "10m"])
        XCTAssertEqual(none.projects[0].sessions, ["PROJ-12 — 1h 02m · PROJ-12-check", "quick look"])
        XCTAssertEqual(none.projects[1].color, Palette.muted)
        XCTAssertEqual(none.markdown.components(separatedBy: "## What was done\n\n").last,
                       "### api-server — 1h 02m · $8\n\n- PROJ-12 — 1h 02m · PROJ-12-check\n- quick look\n\n### other — 10m\n\n- scratch — 10m\n")

        let written = DayVM(DayData(day: at, totals: Totals(sessionSec: 4320, tokens: 10, cost: 8), doc: doc, projects: projects,
                                    summaryInfo: SummaryInfo(engine: "claude", at: at, weekPct: nil)), f)
        XCTAssertEqual(written.summary?.cards.count, 4)
        XCTAssertEqual(written.summaryNote, "Summary written by Claude at 20:00.")
        XCTAssertEqual(written.markdown.components(separatedBy: "## What was done\n\n").last, doc.text(markdown: true) + "\n")
        XCTAssertEqual(CalendarVM.card(DayData(day: at, totals: Totals(sessionSec: 1, tokens: 1, cost: 1), doc: doc), f).bullets,
                       ["api-server: PROJ-12 Webhook retries", "api-server: Logs", "Notes"])
        XCTAssertEqual(CalendarVM.card(DayData(day: at, totals: Totals(sessionSec: 1, tokens: 1, cost: 1), projects: projects), f).bullets,
                       ["api-server: PROJ-12; quick look", "other: scratch"])
    }

    // MARK: the CLI

    /// The CLI's `--json` envelope, as `zagon summary` prints it.
    func envelope(_ d: SummaryDoc, engine: String = "claude") -> String {
        struct Kept: Encodable { var key: String, engine: String, created: Double, doc: SummaryDoc }
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try! e.encode(Kept(key: d.key, engine: engine, created: at.timeIntervalSince1970, doc: d)), as: UTF8.self)
    }

    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var args: [[String]] = []
        var steps: [TaskBackend.SummaryStep] = []
        func add(_ a: [String]) { lock.withLock { args.append(a) } }
        func step(_ s: TaskBackend.SummaryStep) { lock.withLock { steps.append(s) } }
    }

    func backend(_ calls: Calls, _ answer: @escaping @Sendable ([String]) -> Proc.Result) -> TaskBackend {
        TaskBackend(source: .server("build-box")) { args, timeout in
            calls.add(args + ["@\(Int(timeout))"])
            return answer(args)
        }
    }

    static func ok(_ text: String) -> Proc.Result { Proc.Result(status: 0, out: Data(text.utf8), err: Data()) }

    func testDayAnswerPlanAndErrors() throws {
        let calls = Calls(), line = envelope(doc)
        let b = backend(calls) { args in
            if args.contains("--plan") {
                return Self.ok(#"{"calls":3,"from":"2026-10-26","key":"2026-10-26..2026-11-01","missing":["2026-10-27","2026-10-28"],"#
                          + #""to":"2026-11-01","worked":["2026-10-26","2026-10-27","2026-10-28"]}"#)
            }
            if args.contains("--refresh") {
                return Proc.Result(status: 1, out: Data(), err: Data("Error: cannot write /home/someone/.zagon/zagon.db\n".utf8))
            }
            return Self.ok("Last login: a banner\n" + line + "\n")
        }
        let k = try b.summary(day: "2026-10-30", refresh: false)
        XCTAssertEqual(k, KeptSummary(doc: doc, engine: "claude", at: at))
        XCTAssertThrowsError(try b.summary(day: "2026-10-30", refresh: true)) {
            XCTAssertEqual(String(describing: $0), "cannot write ~/.zagon/zagon.db")
        }
        let plan = try b.summaryPlan(from: "2026-10-26", to: "2026-11-01")
        XCTAssertEqual(plan, SummaryPlan(key: "2026-10-26..2026-11-01", from: "2026-10-26", to: "2026-11-01",
                                         worked: ["2026-10-26", "2026-10-27", "2026-10-28"], missing: ["2026-10-27", "2026-10-28"], calls: 3))
        XCTAssertTrue(plan.needsConfirm)
        XCTAssertFalse(SummaryPlan(key: "", from: "", to: "", worked: ["a"], missing: ["a"], calls: 0).needsConfirm)
        XCTAssertEqual(calls.args, [["summary", "2026-10-30", "--json", "@300"], ["summary", "2026-10-30", "--json", "--refresh", "@300"],
                                    ["summary", "--from", "2026-10-26", "--to", "2026-11-01", "--plan", "--json", "@120"]])

        let old = backend(Calls()) { _ in Proc.Result(status: 64, out: Data(), err: Data("Error: Unknown option '--json'\nUsage: …\n".utf8)) }
        XCTAssertThrowsError(try old.summary(day: "2026-10-30", refresh: false)) {
            XCTAssertTrue(String(describing: $0).hasPrefix("zagon there is older than this app"))
        }
        let garbage = backend(Calls()) { _ in Self.ok("not json\n") }
        XCTAssertThrowsError(try garbage.summary(day: "2026-10-30", refresh: false)) {
            XCTAssertTrue(String(describing: $0).contains("in a form this app does not read"))
        }
    }

    static func planJSON(_ missing: String) -> String {
        #"{"key":"2026-10-26..2026-11-01","from":"2026-10-26","to":"2026-11-01","worked":["2026-10-27","2026-10-28"],"missing":[\#(missing)],"calls":1}"#
    }

    func testPeriodFlowWritesMissingDaysFirst() async throws {
        var period = doc
        period.from = "2026-10-26"; period.to = "2026-11-01"; period.main = ["The webhook"]
        let calls = Calls(), day = envelope(doc), whole = envelope(period)
        let b = backend(calls) { args in Self.ok(args.contains("--plan") ? Self.planJSON("") : args.contains("--from") ? whole : day) }
        let plan = SummaryPlan(key: period.key, from: "2026-10-26", to: "2026-11-01", worked: ["2026-10-27", "2026-10-28"],
                               missing: ["2026-10-27", "2026-10-28"], calls: 3)
        let k = try await b.writePeriod(plan) { calls.step($0) }
        XCTAssertEqual(k.doc.key, "2026-10-26..2026-11-01")
        XCTAssertEqual(k.doc.main, ["The webhook"])
        XCTAssertEqual(calls.steps, [.day(1, of: 2), .day(2, of: 2), .period])
        // After the days the plan is asked again; the period itself is written without writing days again (no --yes).
        XCTAssertEqual(calls.args, [["summary", "2026-10-27", "--json", "--refresh", "@300"], ["summary", "2026-10-28", "--json", "--refresh", "@300"],
                                    ["summary", "--from", "2026-10-26", "--to", "2026-11-01", "--plan", "--json", "@120"],
                                    ["summary", "--from", "2026-10-26", "--to", "2026-11-01", "--json", "--refresh", "@300"]])
        // A day the AI did not answer for is named, and the period is not written.
        let stuck = backend(Calls()) { args in Self.ok(args.contains("--plan") ? Self.planJSON(#""2026-10-28""#) : day) }
        do { _ = try await stuck.writePeriod(plan); XCTFail("written") } catch {
            XCTAssertEqual(String(describing: error), "the AI did not answer for 2026-10-28: try again later")
        }
        _ = try backend(calls) { _ in Self.ok(#"{"at":"off"}"#) }.setSummaryTime(nil)
        XCTAssertEqual(calls.args.last, ["summary", "--at", "off", "--json", "@60"])
    }

    func testNewestOfStoreAndAnswer() {
        let old = KeptSummary(doc: doc, engine: "none", at: at), new = KeptSummary(doc: doc, engine: "claude", at: at.addingTimeInterval(60))
        XCTAssertEqual(SummaryJob.newest(old, new), new)
        XCTAssertEqual(SummaryJob.newest(new, old), new)
        XCTAssertEqual(SummaryJob.newest(nil, old), old)
        XCTAssertNil(SummaryJob.newest(nil, nil))
        // An answer without cards (the server had no sessions that day) does not replace what this Mac shows.
        var empty = doc
        empty.items = []
        XCTAssertNil(SummaryJob.newest(nil, KeptSummary(doc: empty, engine: "none", at: at.addingTimeInterval(120))))
        XCTAssertEqual(SummaryJob.newest(old, KeptSummary(doc: empty, engine: "none", at: at.addingTimeInterval(120))), old)
    }

    /// A summary the CLI answered is kept in this Mac's store and shows on the day before any pull.
    func testKeptSummaryShowsRightAway() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-summary-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = StoreDataProvider(store: try Store(path: dir + "/z.db"), writer: try Store(path: dir + "/z.db"), now: at)
        let ready = expectation(description: "ready")
        p.refresh { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        XCTAssertNil(p.summary("2026-10-30"))
        p.keep(KeptSummary(doc: doc, engine: "claude", at: at))
        XCTAssertEqual(p.summary("2026-10-30"), KeptSummary(doc: doc, engine: "claude", at: at))
        p.timeZone = utc
        XCTAssertEqual(p.day(at).doc, doc)
        XCTAssertEqual(p.day(at).summaryInfo?.engine, "claude")
        // An AI summary wins over one made without, whatever their times.
        p.keep(KeptSummary(doc: SummaryDoc(lang: "en", from: "2026-10-30", to: "2026-10-30", overview: "plain", items: []), engine: "none",
                           at: at.addingTimeInterval(60)))
        XCTAssertEqual(p.summary("2026-10-30")?.engine, "claude")
    }

    // MARK: [summary] time

    func testSummaryTimeInConfig() {
        XCTAssertEqual(NotifySettings.parse("").summaryAt, 20 * 60)
        XCTAssertEqual(NotifySettings.parse("[summary]\ntime = \"07:30\"\n").summaryAt, 7 * 60 + 30)
        XCTAssertNil(NotifySettings.parse("[summary]\ntime = \"\"\n").summaryAt)
        let file = "# mine\n[notify]\nlimit_reset = false\n"
        var s = NotifySettings.parse(file)
        XCTAssertEqual(s.apply(to: file), file, "nothing changed, nothing written")
        s.summaryAt = 21 * 60 + 5
        let on = s.apply(to: file)
        XCTAssertEqual(on, file + "\n[summary]\ntime = \"21:05\"\n")
        XCTAssertEqual(NotifySettings.parse(on).summaryAt, 21 * 60 + 5)
        s.summaryAt = nil
        let off = s.apply(to: on)
        XCTAssertEqual(off, file + "\n[summary]\ntime = \"\"\n")
        XCTAssertNil(NotifySettings.parse(off).summaryAt)
        XCTAssertEqual(NotifySettings.parse(off).limitReset, false)
        XCTAssertEqual(["20:00", "7:05", " 23:59 ", "24:00", "12:60", "12:5", "+1:00", "noon", ""].map(NotifySettings.minutes),
                       [1200, 425, 1439, nil, nil, nil, nil, nil, nil])
        XCTAssertEqual([0, 425, 1439].map(NotifySettings.clock), ["00:00", "07:05", "23:59"])
    }
}
