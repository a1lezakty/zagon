import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

final class LimitSettingsTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    /// Both AIs only with a current reading each; a stale one (read before its reset) does not count.
    func testLimitsPerAI() {
        var p = MockDataProvider(lang: .en, timeZone: utc)
        XCTAssertEqual(p.limits().tools(at: p.now), [.claude])
        XCTAssertFalse(p.limits().both(at: p.now))
        p.codexLimits = true
        let l = p.limits()
        XCTAssertEqual(l.tools(at: p.now), [.claude, .codex])
        XCTAssertTrue(l.both(at: p.now))
        XCTAssertEqual([l.claude.fiveHour?.usedPct, l.codex.fiveHour?.usedPct, l.codex.week?.usedPct], [62, 18, 71])
        XCTAssertEqual(l.fiveHour?.tool, .claude)

        let soon = p.now.addingTimeInterval(3600), gone = p.now.addingTimeInterval(-60)
        var mixed = Limits(claude: AILimits(fiveHour: LimitWindow(usedPct: 97, resetsAt: gone, tool: .claude)),
                           codex: AILimits(week: LimitWindow(usedPct: 30, resetsAt: soon, tool: .codex)))
        XCTAssertEqual(mixed.tools(at: p.now), [.codex])
        XCTAssertEqual(mixed.shown(at: p.now).week?.usedPct, 30)
        XCTAssertNil(mixed.shown(at: p.now).fiveHour)  // Claude's stale window is not Codex's
        mixed.codex = AILimits()
        XCTAssertEqual(mixed.tools(at: p.now), [])
        XCTAssertEqual(mixed.shown(at: p.now).fiveHour?.usedPct, 97)  // nothing current: as before, the stale one
        XCTAssertEqual(Limits(fiveHour: nil, week: LimitWindow(usedPct: 5, resetsAt: soon, tool: .codex)).codex.week?.usedPct, 5)
    }

    /// The status item: a pair of rings for one AI, a ring-in-ring per AI for two; the tip names the AIs.
    func testMenuBar() {
        var p = MockDataProvider(lang: .ru, timeZone: utc)
        let f = Fmt(lang: .ru, timeZone: utc, now: p.now)
        let one = MenuBarVM(p.limits(), f)
        XCTAssertFalse(one.nested)
        XCTAssertEqual(one.ais, [MenuBarVM.AI(tool: .claude, five: 62, week: 41, colors: .standard(.claude))])
        XCTAssertEqual(one.tip, "Claude: 5 ч 62 %, неделя 41 %")
        XCTAssertFalse(one.alarm)

        p.codexLimits = true
        let violet = RingColors(five: Palette.violet, week: Palette.violet)
        let both = MenuBarVM(p.limits(), colors: { $0 == .codex ? violet : .standard($0) }, f)
        XCTAssertTrue(both.nested)
        XCTAssertEqual(both.ais.map(\.tool), [.claude, .codex])
        XCTAssertEqual(both.ais[1], MenuBarVM.AI(tool: .codex, five: 18, week: 71, colors: violet))
        XCTAssertEqual(both.tip, "Claude: 5 ч 62 %, неделя 41 % · Codex: 5 ч 18 %, неделя 71 %")
        XCTAssertEqual(both.spoken, "Zagon: Claude: 5 часов — использовано 62 %, неделя — использовано 41 %; "
                       + "Codex: 5 часов — использовано 18 %, неделя — использовано 71 %")

        // Red: a pair's digits from 80 %; a ring-in-ring shows only the 5-hour digits, its week turns red from 95 %.
        let ai = { (five: Int?, week: Int?) in MenuBarVM.AI(tool: .codex, five: five, week: week, colors: violet) }
        XCTAssertTrue(MenuBarVM(ais: [ai(10, 85)], f).alarm)
        XCTAssertFalse(MenuBarVM(ais: [ai(10, 10), ai(10, 85)], f).alarm)
        XCTAssertTrue(MenuBarVM(ais: [ai(10, 10), ai(10, 95)], f).alarm)
        XCTAssertTrue(MenuBarVM(ais: [ai(80, nil), ai(nil, nil)], f).alarm)

        // A stale reading is no AI: Codex alone with its pair; nothing at all: no names.
        p.codexLimits = false
        p.staleLimits = true
        var stale = p.limits()
        XCTAssertEqual(MenuBarVM(stale, f).ais, [MenuBarVM.AI(tool: .claude, five: nil, week: 47, colors: .standard(.claude))])
        stale.claude.week = nil
        stale.codex = AILimits(fiveHour: LimitWindow(usedPct: 9, resetsAt: p.now.addingTimeInterval(600), tool: .codex))
        XCTAssertEqual(MenuBarVM(stale, f).ais, [MenuBarVM.AI(tool: .codex, five: 9, week: nil, colors: .standard(.codex))])
        // Nothing current, each AI with one stale window: named after Claude, whose window is there.
        let gone = p.now.addingTimeInterval(-60)
        let old = MenuBarVM(Limits(claude: AILimits(week: LimitWindow(usedPct: 50, resetsAt: gone, tool: .claude)),
                                   codex: AILimits(fiveHour: LimitWindow(usedPct: 50, resetsAt: gone, tool: .codex))), f)
        XCTAssertEqual(old.tip, "Claude: 5 ч –, неделя –")

        // Both current, Claude without a week; over 100 %.
        let soon = p.now.addingTimeInterval(600)
        let gap = MenuBarVM(Limits(claude: AILimits(fiveHour: LimitWindow(usedPct: 103, resetsAt: soon, tool: .claude)),
                                   codex: AILimits(week: LimitWindow(usedPct: 20, resetsAt: soon, tool: .codex))), f)
        XCTAssertTrue(gap.nested)
        XCTAssertEqual([gap.ais[0].five, gap.ais[0].week, gap.ais[1].five, gap.ais[1].week], [103, nil, nil, 20])
        XCTAssertTrue(gap.alarm)
        XCTAssertEqual(gap.tip, "Claude: 5 ч 103 %, неделя – · Codex: 5 ч –, неделя 20 %")

        let none = MenuBarVM(Limits(), f)
        XCTAssertEqual([none.tip, none.spoken], ["5 ч: – · неделя: –", "Zagon: нет данных"])
    }

    /// The status item's picture is drawn when what it shows changes, not each time the label asks for it (0.1.2 drew it
    /// on every update of the app, and a redraw set off the next one: a busy core).
    @MainActor
    func testStatusIconDrawsOnlyOnChange() async {
        var p = MockDataProvider(lang: .ru, timeZone: utc)
        let f = Fmt(lang: .ru, timeZone: utc, now: p.now)
        var reads = 0, draws = 0, fail = false
        let icon = StatusIcon<Int>(limits: { reads += 1; return p.limits() }) { _ in
            if fail { return nil }
            draws += 1
            return draws
        }
        let update = { (mono: Bool, dark: Bool) in icon.update(colors: RingColors.standard, mono: mono, dark: dark, f) }
        XCTAssertNil(icon.image)
        XCTAssertTrue(update(false, true))
        XCTAssertEqual(icon.look?.vm.ais.map(\.five), [62])

        // The label asks on every change of the app: no reading, no drawing.
        for _ in 0..<100 { XCTAssertEqual(icon.image, 1) }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(draws, 1)
        // The timer with nothing new: one reading, the same picture.
        XCTAssertFalse(update(false, true))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(draws, 1)

        // New numbers, the mode, the bar's shade, a colour: drawn again, once each.
        p.codexLimits = true
        XCTAssertTrue(update(false, true))
        XCTAssertTrue(update(true, true))
        XCTAssertTrue(update(true, false))
        XCTAssertTrue(icon.update(colors: { _ in RingColors(five: Palette.violet, week: Palette.week) }, mono: true, dark: false, f))
        XCTAssertEqual(draws, 5)
        XCTAssertEqual(icon.image, 5)

        // A failed drawing keeps the last picture and is tried again.
        fail = true
        XCTAssertFalse(update(false, false))
        XCTAssertEqual(icon.image, 5)
        fail = false
        XCTAssertTrue(update(false, false))
        XCTAssertEqual(icon.image, 6)
    }

    func testRingColors() throws {
        XCTAssertEqual(RingColors.standard(.claude), RingColors(five: Palette.fiveHour, week: Palette.week))
        let codex = RingColors.standard(.codex)
        XCTAssertNotEqual(codex.five, codex.week)
        XCTAssertTrue(Set([codex.five, codex.week]).isDisjoint(with: [Palette.fiveHour, Palette.week]))
        XCTAssertTrue(Set(RingColors.swatches).isSuperset(of: [codex.five, codex.week, Palette.fiveHour, Palette.week]))
        XCTAssertFalse(RingColors.swatches.contains(Palette.waiting) || RingColors.swatches.contains(Palette.bad))

        let name = "zagon.test.ringColors.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(RingColors.load(.codex, d), codex)
        RingColors(five: 0x123456, week: Palette.good).save(.codex, d)
        XCTAssertEqual(RingColors.load(.codex, d), RingColors(five: 0x123456, week: Palette.good))
        XCTAssertEqual(RingColors.load(.claude, d), .standard(.claude))
        d.set("blue", forKey: "ringColor.codex.fiveHour")
        d.set(-1, forKey: "ringColor.codex.week")
        XCTAssertEqual(RingColors.load(.codex, d), codex)
    }

    func testPace() throws {
        let p = MockDataProvider(lang: .en, timeZone: utc)
        let f = Fmt(lang: .en, timeZone: utc, now: p.now)
        let lim = p.limits()
        let five = PaceVM(title: "5 hours", window: try XCTUnwrap(lim.fiveHour), minutes: 300,
                          history: [LimitPoint(p.at(30, 10), 30), LimitPoint(p.at(29, 10), 99)], base: Palette.fiveHour, f: f)
        XCTAssertEqual(five.now.x, 142.0 / 300, accuracy: 1e-9)
        XCTAssertEqual(five.points.count, 3)  // origin, 10:00 (yesterday's reading is outside the window), now
        XCTAssertEqual(five.verdict, "15% ahead of schedule")
        XCTAssertTrue(five.ahead)
        XCTAssertEqual(five.color, Palette.waiting)

        let week = PaceVM(title: "Week", window: try XCTUnwrap(lim.week), minutes: 10080, history: [], base: Palette.week, f: f)
        XCTAssertEqual(week.now.x, 4.1125 / 7, accuracy: 1e-9)
        XCTAssertEqual(week.verdict, "18% behind schedule")
        XCTAssertEqual(week.color, Palette.week)
        // Work week: Mon 09:00 → Mon 09:00 holds 5 weekdays of time, and all of the 4.1125 days passed are weekdays.
        let work = PaceVM(title: "Week", window: try XCTUnwrap(lim.week), minutes: 10080, history: [], base: Palette.week,
                          weekdaysOnly: true, f: f)
        XCTAssertEqual(work.now.x, 4.1125 / 5, accuracy: 1e-9)
        XCTAssertEqual(PaceVM(title: "", window: LimitWindow(usedPct: 50, resetsAt: p.at(30, 14)), minutes: 300, history: [],
                              base: 0, f: Fmt(lang: .ru, timeZone: utc, now: p.at(30, 11.5))).verdict, "по графику")
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
