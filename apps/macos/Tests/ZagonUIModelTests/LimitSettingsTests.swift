import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

final class LimitSettingsTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testPace() throws {
        let p = MockDataProvider(lang: .en, timeZone: utc)
        let f = Fmt(lang: .en, timeZone: utc, now: p.now)
        let lim = p.limits()
        let five = PaceVM(title: "5 hours", window: try XCTUnwrap(lim.fiveHour), minutes: 300,
                          history: [LimitPoint(p.at(30, 10), 30), LimitPoint(p.at(29, 10), 99)], base: Palette.fiveHour, f: f)
        XCTAssertEqual(five.now.x, 142.0 / 300, accuracy: 1e-9)
        XCTAssertEqual(five.points.count, 3)  // origin, 10:00 (yesterday's reading is outside the window), now
        XCTAssertEqual(five.verdict, "15% ahead of even pace")
        XCTAssertTrue(five.ahead)
        XCTAssertEqual(five.color, Palette.waiting)

        let week = PaceVM(title: "Week", window: try XCTUnwrap(lim.week), minutes: 10080, history: [], base: Palette.week, f: f)
        XCTAssertEqual(week.now.x, 4.1125 / 7, accuracy: 1e-9)
        XCTAssertEqual(week.verdict, "18% behind even pace")
        XCTAssertEqual(week.color, Palette.week)
        // Work week: Mon 09:00 → Mon 09:00 holds 5 weekdays of time, and all of the 4.1125 days passed are weekdays.
        let work = PaceVM(title: "Week", window: try XCTUnwrap(lim.week), minutes: 10080, history: [], base: Palette.week,
                          weekdaysOnly: true, f: f)
        XCTAssertEqual(work.now.x, 4.1125 / 5, accuracy: 1e-9)
        XCTAssertEqual(PaceVM(title: "", window: LimitWindow(usedPct: 50, resetsAt: p.at(30, 14)), minutes: 300, history: [],
                              base: 0, f: Fmt(lang: .ru, timeZone: utc, now: p.at(30, 11.5))).verdict, "ровный темп")
    }

    func testPaceFromProviders() throws {
        let mock = MockDataProvider(lang: .en, timeZone: utc)
        let f = Fmt(lang: .en, timeZone: utc, now: mock.now)
        let both = PaceVM.both(mock, weekdaysOnly: false, f)
        XCTAssertEqual(both.five?.title, "5 hours")
        XCTAssertEqual(both.five?.points.count, 7)  // origin, five readings, now
        XCTAssertEqual(both.week?.points.count, 6)
        XCTAssertEqual(MainVM(mock, f).five?.leftPct, 38)
        XCTAssertEqual(MainVM(mock, f).five?.leftLine, "left")

        let store = try StoreDataProvider.fixture(StoreDataProviderTests.fixtures)
        let history = store.limitHistory(.fiveHour)
        XCTAssertEqual(try XCTUnwrap(history.last?.pct), 61.6, accuracy: 0.01)
        XCTAssertTrue(zip(history, history.dropFirst()).allSatisfy { $0.at < $1.at })
        XCTAssertFalse(store.limitHistory(.week).isEmpty)
    }

    func testNotifySettingsFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-\(UUID().uuidString)/config.toml").path
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        XCTAssertEqual(try NotifySettings.load(path), NotifySettings())
        var s = try NotifySettings.load(path)
        s.toggle("codex.week", 60)
        try s.save(path)
        XCTAssertEqual(try NotifySettings.load(path).thresholds("codex.week"), [60, 80, 95])
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        // Not UTF-8 (a Latin-1 byte in a comment): never rewritten.
        let latin = Data([0x23, 0x20, 0xE9, 0x0A]) + Data("[notify]\nlimit_reset = true\n".utf8)
        try latin.write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try s.save(path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), latin)
    }

    /// The app reads what the notifier reads, and an edit keeps quoted keys and comments.
    func testNotifySettingsCommentsAndQuotedKeys() {
        let text = "[notify]\nlimit_reset = false   # no reset pings\n\n[notify.limits] # mine\n\"claude.five_hour\" = [90] # one\n"
        var s = NotifySettings.parse(text)
        XCTAssertFalse(s.limitReset)
        XCTAssertEqual(s.thresholds("claude.five_hour"), [90])
        s.toggle("claude.five_hour", 95)
        let out = s.apply(to: text)
        XCTAssertEqual(out, "[notify]\nlimit_reset = false   # no reset pings\n\n[notify.limits] # mine\n\"claude.five_hour\" = [90, 95] # one\n")
        let core = NotifyConfig.parse(out, home: "")
        XCTAssertEqual(core.limits["claude.five_hour"], [90, 95])
        XCTAssertFalse(core.limitReset)
        XCTAssertEqual(NotifySettings.parse(out), s)
    }

    /// Whatever the file looks like, after an edit the notifier reads the new setting.
    func testNotifySettingsAsTheNotifierReadsThem() {
        let text = "[notify]\n\"limit_reset\" = false\n[notify.limits]\nclaude.week = [90]\n'claude.week' = [60]\nclaude.week = [70]\n"
        var s = NotifySettings.parse(text)
        XCTAssertEqual(s.limitReset, NotifyConfig.parse(text, home: "").limitReset)
        XCTAssertEqual(s.thresholds("claude.week").map(Double.init), NotifyConfig.parse(text, home: "").limits["claude.week"])
        XCTAssertEqual(s.apply(to: text), text)  // unchanged settings: the file is not touched
        s.limitReset = false
        s.set("claude.week", 95, on: true)
        let out = s.apply(to: text)
        let core = NotifyConfig.parse(out, home: "")
        XCTAssertFalse(core.limitReset)
        XCTAssertEqual(core.limits["claude.week"], s.thresholds("claude.week").map(Double.init))
        XCTAssertEqual(out.components(separatedBy: "claude.week").count - 1, 1)  // one line left for the key
        XCTAssertEqual(NotifySettings.parse(out), s)
        s.set("claude.week", 95, on: true)  // already on: stays on
        XCTAssertTrue(s.thresholds("claude.week").contains(95))
    }

    func testPaceOfEndedWindow() {
        let mock = MockDataProvider(lang: .en, timeZone: utc)
        let f = Fmt(lang: .en, timeZone: utc, now: mock.now)
        let ended = PaceVM(title: "Week", window: LimitWindow(usedPct: 97, resetsAt: mock.at(30, 9)), minutes: 10080,
                           history: mock.limitHistory(.week), base: Palette.week, f: f)
        XCTAssertEqual(ended.points.count, 1)
        XCTAssertEqual(ended.verdict, "")
        XCTAssertEqual(ended.color, Palette.week)
    }

    func testNotifySettingsEditOnlyTheirLines() {
        let text = "# mine\n[telegram]\nchat_id = \"1\"\n\n[notify]\nquiet = \"23:00-08:00\"\n"
        var s = NotifySettings.parse(text)
        XCTAssertEqual(s.thresholds("claude.week"), [80, 95])
        XCTAssertTrue(s.limitReset)
        s.toggle("claude.week", 50)
        s.toggle("claude.week", 95)
        s.limitReset = false
        let out = s.apply(to: text)
        XCTAssertEqual(out, "# mine\n[telegram]\nchat_id = \"1\"\n\n[notify]\nlimit_reset = false\nquiet = \"23:00-08:00\"\n\n"
                       + "[notify.limits]\nclaude.week = [50, 80]\n")
        XCTAssertEqual(NotifySettings.parse(out), s)
        XCTAssertEqual(NotifySettings().apply(to: ""), "")  // defaults equal to the file: nothing written
        XCTAssertEqual(NotifySettings.parse("[notify.limits]\ncodex.week = [100, 7, 55]\nclaude.week = []\n").thresholds,
                       ["codex.week": [55, 100], "claude.week": []])
        XCTAssertEqual(NotifySettings.title("codex.week", Fmt(lang: .ru, now: Date())), "Codex · неделя")
        XCTAssertEqual(NotifySettings.title("claude.five_hour", Fmt(lang: .en, now: Date())), "Claude · 5 hours")
    }
}
