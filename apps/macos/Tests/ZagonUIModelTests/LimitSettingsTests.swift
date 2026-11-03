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

    /// A second Claude Code account: a ring-in-ring of its own next to the default account's (both then nested), its
    /// session a tag; the icon stays the default account's below 80 %, the tip names it; with one account nothing
    /// changes.
    func testOtherAccounts() {
        var p = MockDataProvider(lang: .en, timeZone: utc)
        let f = Fmt(lang: .en, timeZone: utc, now: p.now)
        let one = MainVM(p, f)
        XCTAssertTrue(one.ais.isEmpty)
        XCTAssertTrue((one.waiting + one.working + one.idle).allSatisfy { $0.tag.isEmpty })
        p.otherAccounts = true
        let two = MainVM(p, f)
        XCTAssertEqual([two.five?.pct, two.week?.pct], [one.five?.pct, one.week?.pct])
        let icon = MenuBarVM(p.limits(), f), single = MenuBarVM(MockDataProvider(lang: .en, timeZone: utc).limits(), f)
        XCTAssertEqual([icon.ais, icon.accounts], [single.ais, []])
        XCTAssertEqual(icon.tip, "Claude: 5 hours 62%, week 41% · Claude · corp: 5 hours 23%, week 58%")
        XCTAssertEqual(two.ais.map(\.name), ["Claude", "Claude · corp"])
        XCTAssertEqual(two.ais.map { [$0.five.pct, $0.week.pct] }, [[62, 41], [23, 58]])
        XCTAssertEqual(two.ais[1].fiveLine, "5h until 15:30")
        XCTAssertEqual(two.ais[1].weekLine, "week 58%")
        XCTAssertFalse(two.limitsMissing)
        XCTAssertEqual(two.working.filter { !$0.tag.isEmpty }.map { $0.title + $0.tag }, ["cli-tool — parser (corp)"])
        XCTAssertEqual(MainVM(p, Fmt(lang: .ru, timeZone: utc, now: p.now)).ais[1].weekLine, "неделя 58 %")
        // With Codex: Claude's accounts together, then Codex.
        p.codexLimits = true
        XCTAssertEqual(MainVM(p, f).ais.map(\.name), ["Claude", "Claude · corp", "Codex"])
        // The default Claude account without a current reading stays next to its other account, with "–"; the other
        // account idle since its reset has its "–" and no line under the rings.
        var l = p.limits()
        l.claude.fiveHour?.resetsAt = p.now.addingTimeInterval(-60)
        l.claude.week?.resetsAt = p.now.addingTimeInterval(-60)
        l.others[0].limits.fiveHour?.resetsAt = p.now.addingTimeInterval(-60)
        let idle = MainVM(ZagonUIModelTests.Fixed(base: p, l: l), f)
        XCTAssertEqual(idle.ais.map(\.name), ["Claude", "Claude · corp", "Codex"])
        XCTAssertEqual(idle.ais.map { [$0.five.pct, $0.week.pct] }, [[nil, nil], [nil, 58], [18, 71]])
        XCTAssertEqual(idle.waitHint, "Claude: new readings come with its next reply.")
        l.claude = p.limits().claude
        XCTAssertFalse(MainVM(ZagonUIModelTests.Fixed(base: p, l: l), f).limitsMissing)

        // The icon: another account at 80 % or over follows the default one's rings, its higher number inside.
        var hot = p.limits()
        hot.others[0].limits.week?.usedPct = 85
        let warm = MenuBarVM(hot, f)
        XCTAssertEqual(warm.ais.map(\.tool), [.claude, .codex])
        XCTAssertEqual(warm.accounts.map { [$0.five, $0.week, $0.inside] }, [[23, 85, 85]])
        XCTAssertTrue(warm.alarm)
        XCTAssertTrue(warm.spoken.hasSuffix("Claude · corp: 5 hours 23% used, week 85% used"), warm.spoken)
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

        // Both current, Claude without a week; over 100 %. Codex with only its week: no 5-hour window (`weekOnly`).
        let soon = p.now.addingTimeInterval(600)
        let gap = MenuBarVM(Limits(claude: AILimits(fiveHour: LimitWindow(usedPct: 103, resetsAt: soon, tool: .claude)),
                                   codex: AILimits(week: LimitWindow(usedPct: 20, resetsAt: soon, tool: .codex))), f)
        XCTAssertTrue(gap.nested)
        XCTAssertEqual([gap.ais[0].five, gap.ais[0].week, gap.ais[1].five, gap.ais[1].week], [103, nil, nil, 20])
        XCTAssertTrue(gap.alarm)
        XCTAssertEqual(gap.tip, "Claude: 5 ч 103 %, неделя – · Codex: неделя 20 % (без 5-часового лимита)")

        let none = MenuBarVM(Limits(), f)
        XCTAssertEqual([none.tip, none.spoken], ["5 ч: – · неделя: –", "Zagon: нет данных"])
    }

    /// A plan without a 5-hour window (any AI): the week ring alone with the week's number, alarm by the week. Not
    /// when the 5 hours only reset (the next reply brings them back) or nobody used Claude since.
    func testWeekOnly() {
        var p = MockDataProvider(lang: .ru, timeZone: utc)
        let f = Fmt(lang: .ru, timeZone: utc, now: p.now)
        let fixed = { (l: Limits) in MainVM(ZagonUIModelTests.Fixed(base: p, l: l), f) }
        let week = { (pct: Double, tool: Tool, read: Date) in LimitWindow(usedPct: pct, resetsAt: p.at(33, 9), tool: tool, readAt: read) }

        // Only the week, Claude alone: one ring, the week's number; no hint, nothing missing.
        p.weekOnly = true
        var l = p.limits()
        l.claudeSeen = p.ago(1)
        XCTAssertTrue(l.weekOnly(.claude, at: p.now))
        XCTAssertFalse(l.claudeHint(at: p.now))
        let one = MenuBarVM(l, f)
        XCTAssertEqual(one.ais, [MenuBarVM.AI(tool: .claude, five: nil, week: 41, colors: .standard(.claude), weekOnly: true)])
        XCTAssertFalse(one.nested)
        XCTAssertEqual(one.tip, "Claude: неделя 41 % (без 5-часового лимита)")
        XCTAssertEqual(one.spoken, "Zagon: Claude: неделя — использовано 41 % (без 5-часового лимита)")
        let panel = fixed(l)
        XCTAssertTrue(panel.weekOnly)
        XCTAssertNil(panel.five)
        XCTAssertEqual(panel.week?.pct, 41)
        XCTAssertFalse(panel.limitsMissing)
        XCTAssertNil(panel.claudeHint)
        XCTAssertNil(panel.forecast)
        XCTAssertEqual(panel.limitsHeader, "ЛИМИТЫ CLAUDE")
        // Alarm by the week: digits from 80 %, the ring from 95 %.
        l.claude.week = week(85, .claude, p.ago(1))
        XCTAssertTrue(MenuBarVM(l, f).alarm)

        // Both AIs: Claude's week ring alone, Codex's ring-in-ring; alarm by Claude's week even next to Codex.
        p.codexLimits = true
        l = p.limits()
        let both = MenuBarVM(l, f)
        XCTAssertTrue(both.nested)
        XCTAssertEqual(both.ais.map(\.weekOnly), [true, false])
        XCTAssertEqual(both.ais.map { [$0.five, $0.week] }, [[nil, 41], [18, 71]])
        XCTAssertEqual(both.tip, "Claude: неделя 41 % (без 5-часового лимита) · Codex: 5 ч 18 %, неделя 71 %")
        XCTAssertFalse(both.alarm)
        l.claude.week = week(85, .claude, p.ago(1))
        XCTAssertTrue(MenuBarVM(l, f).alarm)
        let rings = fixed(p.limits()).ais
        XCTAssertEqual(rings.map(\.weekOnly), [true, false])
        XCTAssertEqual(rings[0].spoken, "Claude: " + rings[0].week.spoken + " (без 5-часового лимита)")
        XCTAssertFalse(fixed(p.limits()).limitsMissing)
        // Codex without its 5 hours, alone: the same, no session needed.
        let codex = Limits(codex: AILimits(week: week(30, .codex, p.ago(1))))
        XCTAssertTrue(codex.weekOnly(.codex, at: p.now))
        XCTAssertEqual(MenuBarVM(codex, f).ais.map(\.weekOnly), [true])

        // The 5 hours came back: as before.
        p.codexLimits = false
        p.weekOnly = false
        l = p.limits()
        l.claudeSeen = p.ago(1)
        XCTAssertFalse(l.weekOnly(.claude, at: p.now))
        XCTAssertEqual(MenuBarVM(l, f).ais, [MenuBarVM.AI(tool: .claude, five: 62, week: 41, colors: .standard(.claude))])
        XCTAssertFalse(fixed(l).weekOnly)

        // The 5-hour reading from before, the week coming alone for 10 minutes since it was due, Claude used: week-only.
        // While the window still runs (the plan changed in it), and after its reset.
        for five in [LimitWindow(usedPct: 30, resetsAt: p.at(30, 14), tool: .claude, readAt: p.ago(40)),
                     LimitWindow(usedPct: 30, resetsAt: p.ago(40), tool: .claude, readAt: p.ago(200))] {
            l = Limits(claude: AILimits(fiveHour: five, week: week(41, .claude, p.ago(1)), weekAlone: p.ago(12)), claudeSeen: p.ago(1))
            XCTAssertTrue(l.weekOnly(.claude, at: p.now))
            XCTAssertNil(l.forRings(at: p.now).claude.fiveHour)
            XCTAssertEqual(MenuBarVM(l, f).ais.map { [$0.five, $0.week] }, [[nil, 41]])
            XCTAssertNil(fixed(l).limitsAge)  // the old 5-hour reading does not age the rings
            // Under 10 minutes: not yet.
            l.claude.weekAlone = p.ago(5)
            XCTAssertFalse(l.weekOnly(.claude, at: p.now))
            // Nobody at Claude since it was due (a status line left open re-sends its reading): not week-only.
            l.claude.weekAlone = p.ago(12)
            l.claudeSeen = p.ago(300)
            XCTAssertFalse(l.weekOnly(.claude, at: p.now))
        }
        // The 5 hours reset, live use: the first reading after a long idle comes seconds before the reply that brings
        // them back. Not week-only: the stale ring with "–" next to the week, as before.
        l = Limits(claude: AILimits(fiveHour: LimitWindow(usedPct: 30, resetsAt: p.ago(180), tool: .claude, readAt: p.ago(200)),
                                    week: week(41, .claude, p.ago(0.1)), weekAlone: p.ago(0.1)), claudeSeen: p.ago(0.1))
        XCTAssertFalse(l.weekOnly(.claude, at: p.now))
        let reset = MenuBarVM(l, f)
        XCTAssertEqual(reset.ais, [MenuBarVM.AI(tool: .claude, five: nil, week: 41, colors: .standard(.claude))])
        XCTAssertTrue(reset.tip.hasPrefix("Claude: 5 ч –, неделя 41 %"))
        XCTAssertTrue(fixed(l).limitsMissing)
        // No week reading since the reset at all: as before.
        l.claude.weekAlone = nil
        XCTAssertFalse(l.weekOnly(.claude, at: p.now))
        // The plan changed while the 5 hours ran, nobody at Claude across their old reset: still week-only (the week
        // came alone before it).
        l = Limits(claude: AILimits(fiveHour: LimitWindow(usedPct: 30, resetsAt: p.ago(30), tool: .claude, readAt: p.ago(90)),
                                    week: week(41, .claude, p.ago(1)), weekAlone: p.ago(88)), claudeSeen: p.ago(40))
        XCTAssertTrue(l.weekOnly(.claude, at: p.now))
        XCTAssertFalse(l.claudeHint(at: p.now))
        // Both AIs, the panel's ring-in-ring follows the same rule: nobody at Claude since the week came alone, both rings.
        l = Limits(claude: AILimits(fiveHour: LimitWindow(usedPct: 30, resetsAt: p.ago(40), tool: .claude, readAt: p.ago(200)),
                                    week: week(41, .claude, p.ago(1)), weekAlone: p.ago(12)), claudeSeen: p.ago(300))
        l.codex = AILimits(fiveHour: LimitWindow(usedPct: 18, resetsAt: p.at(30, 16), tool: .codex, readAt: p.ago(6)),
                           week: week(71, .codex, p.ago(6)))
        XCTAssertFalse(l.claude.weekOnly(at: p.now) == l.weekOnly(.claude, at: p.now))  // the guard decides here
        XCTAssertEqual(fixed(l).ais.map(\.weekOnly), [false, false])
        XCTAssertEqual(MenuBarVM(l, f).ais.map(\.weekOnly), [false, false])
        XCTAssertTrue(fixed(l).limitsMissing)
        // The pace view stays Claude's when only its week comes and Codex has an old 5-hour reading.
        l = Limits(claude: AILimits(week: week(41, .claude, p.ago(1))),
                   codex: AILimits(fiveHour: LimitWindow(usedPct: 18, resetsAt: p.ago(60), tool: .codex, readAt: p.ago(400))))
        XCTAssertTrue(fixed(l).weekOnly)
        XCTAssertTrue(fixed(l).paceFits)
        // The week itself stale: nothing current, no week-only.
        l = Limits(claude: AILimits(week: LimitWindow(usedPct: 41, resetsAt: p.ago(1), tool: .claude, readAt: p.ago(60))))
        XCTAssertFalse(l.weekOnly(.claude, at: p.now))
    }

    /// Claude used where its status line does not run (the VS Code / Cursor extension): no reading, yet it is shown with
    /// "–" and where its limits come from, not left out as if broken.
    func testClaudeHint() {
        var p = MockDataProvider(lang: .ru, timeZone: utc)
        let f = Fmt(lang: .ru, timeZone: utc, now: p.now)
        let hint = "Лимиты Claude из панели Cursor или VS Code появятся, когда Zagon включён в редакторах. Или включи claudeCode.useTerminal."
        let reload = "Лимиты Claude из панели редактора появятся после следующего сообщения в ней (в окне, открытом раньше, — Developer: Reload Window)."
        let terminal = "Лимиты Claude приходят из claude в терминале. В Cursor и VS Code включи claudeCode.useTerminal."
        let fixed = { (l: Limits) in MainVM(ZagonUIModelTests.Fixed(base: p, l: l), f) }

        // Sessions, no reading: Claude alone, its pair of rings with "–"; editors found without the setting: turn it on.
        p.claudeUnread = true
        var unread = p.limits()
        XCTAssertTrue(unread.claudeHint(at: p.now))
        let alone = MenuBarVM(unread, f)
        XCTAssertEqual(alone.ais, [MenuBarVM.AI(tool: .claude, five: nil, week: nil, colors: .standard(.claude))])
        XCTAssertEqual(alone.tip, "Claude: 5 ч –, неделя –\n" + hint)
        XCTAssertTrue(alone.spoken.hasSuffix("нет данных. " + hint))
        let panel = MainVM(p, f)
        XCTAssertEqual(panel.claudeHint, hint)
        XCTAssertTrue(panel.claudeEnable)
        XCTAssertTrue(panel.limitsMissing)
        XCTAssertTrue(panel.ais.isEmpty)
        XCTAssertNil(panel.five)
        XCTAssertEqual(panel.limitsHeader, "ЛИМИТЫ CLAUDE")
        // On in one editor (off in another): the panel's next message brings them, nothing to turn on.
        unread.claudeEditors?.on = ["/Users/you/.cursor-server/data/Machine/settings.json"]
        XCTAssertEqual(MenuBarVM(unread, f).tip, "Claude: 5 ч –, неделя –\n" + reload)
        XCTAssertEqual(fixed(unread).claudeHint, reload)
        XCTAssertFalse(fixed(unread).claudeEnable)
        // No editors (not read, or only files left alone): only the terminal, nothing to turn on.
        for editors in [nil, Installer.EditorPanels(other: ["/Users/you/.config/Code/User/settings.json is not a JSON object"])] {
            unread.claudeEditors = editors
            XCTAssertEqual(MenuBarVM(unread, f).tip, "Claude: 5 ч –, неделя –\n" + terminal)
            XCTAssertEqual(fixed(unread).claudeHint, terminal)
            XCTAssertFalse(fixed(unread).claudeEnable)
        }
        // A stale Codex reading stays out: Claude's rings.
        unread.codex = AILimits(week: LimitWindow(usedPct: 30, resetsAt: p.now - 60, tool: .codex))
        XCTAssertEqual(MenuBarVM(unread, f).ais.map(\.tool), [.claude])
        XCTAssertNil(fixed(unread).week)
        XCTAssertEqual(fixed(unread).limitsHeader, "ЛИМИТЫ CLAUDE")
        // With Codex: both, a ring-in-ring each (before, Codex alone).
        p.codexLimits = true
        let both = MenuBarVM(p.limits(), f)
        XCTAssertTrue(both.nested)
        XCTAssertEqual(both.ais.map { [$0.five, $0.week] }, [[nil, nil], [18, 71]])
        XCTAssertEqual(both.tip, "Claude: 5 ч –, неделя – · Codex: 5 ч 18 %, неделя 71 %\n" + hint)
        XCTAssertEqual(MainVM(p, f).ais.map { [$0.five.pct, $0.week.pct] }, [[nil, nil], [18, 71]])
        XCTAssertEqual(MainVM(p, f).claudeHint, hint)

        // A current reading: as before.
        p.claudeUnread = false
        var l = p.limits()
        l.claudeSeen = p.now
        XCTAssertFalse(l.claudeHint(at: p.now))
        XCTAssertEqual(MenuBarVM(l, f).tip, "Claude: 5 ч 62 %, неделя 41 % · Codex: 5 ч 18 %, неделя 71 %")
        XCTAssertNil(fixed(l).claudeHint)
        // No Claude session in 7 days: Codex alone, as before.
        l.claude = AILimits()
        for seen in [nil, p.now - 8 * 86400] {
            l.claudeSeen = seen
            XCTAssertEqual(l.tools(at: p.now), [.codex])
            XCTAssertEqual(MenuBarVM(l, f).tip, "Codex: 5 ч 18 %, неделя 71 %")
            XCTAssertNil(fixed(l).claudeHint)
        }

        // Read when last used, both windows reset since: Claude idle, the reading is just old.
        let used = p.now - 2 * 86400
        var old = Limits(claude: AILimits(fiveHour: LimitWindow(usedPct: 97, resetsAt: used + 3600, tool: .claude),
                                          week: LimitWindow(usedPct: 47, resetsAt: used + 86400, tool: .claude)),
                         claudeSeen: used)
        XCTAssertFalse(old.claudeHint(at: p.now))
        XCTAssertEqual(MenuBarVM(old, f).tip, "Claude: 5 ч –, неделя –")
        XCTAssertNil(fixed(old).claudeHint)
        // Used after a reset and no new reading came (a terminal reply would bring one): the hint. Also with the week
        // still current (claude in a terminal days ago, the editor's panel since).
        old.claudeSeen = used + 2 * 3600
        XCTAssertTrue(old.claudeHint(at: p.now))
        XCTAssertEqual(MenuBarVM(old, f).tip, "Claude: 5 ч –, неделя –\n" + terminal)
        old.claude.week?.resetsAt = p.now + 86400
        XCTAssertTrue(old.claudeHint(at: p.now))
        XCTAssertEqual(MenuBarVM(old, f).tip, "Claude: 5 ч –, неделя 47 %\n" + terminal)
        XCTAssertEqual(fixed(old).claudeHint, terminal)
        // A plan without a 5-hour window: the current week is enough; the week reset before the last use is not.
        old.claude.fiveHour = nil
        XCTAssertFalse(old.claudeHint(at: p.now))
        old.claude.week?.resetsAt = used + 3600
        XCTAssertTrue(old.claudeHint(at: p.now))
    }

    /// Settings → Claude limits from the IDE panel: editors named from their paths, what on / off can change.
    func testEditorPanelsCard() {
        let f = Fmt(lang: .en, timeZone: utc, now: Date(timeIntervalSince1970: 0))
        let app = "/Users/you/Library/Application Support"
        let none = EditorPanelsVM(Installer.EditorPanels(), f)
        XCTAssertEqual(none.lines, [.init(on: false, text: "No VS Code or Cursor editors found")])
        XCTAssertEqual([none.canEnable, none.canDisable], [false, false])

        let off = EditorPanelsVM(MockDataProvider.editors, f)
        XCTAssertEqual(off.lines, [.init(on: false, text: "Off: Cursor, Code")])
        XCTAssertEqual([off.canEnable, off.canDisable, off.notes.isEmpty], [true, false, true])

        let some = EditorPanelsVM(Installer.EditorPanels(
            on: [app + "/Cursor/User/settings.json", app + "/Cursor/User/profiles/1a2b/settings.json",
                 app + "/Cursor/User/profiles/3c4d/settings.json", "/Users/you/.cursor-server/data/Machine/settings.json"],
            off: ["/home/you/.config/Code/User/settings.json"]), f)
        XCTAssertEqual(some.lines, [.init(on: true, text: "On: Cursor, Cursor (profile), cursor-server (Remote-SSH)"),
                                    .init(on: false, text: "Off: Code")])
        XCTAssertEqual([some.canEnable, some.canDisable], [true, true])

        // Only files left alone: no "not found", the notes say what is there.
        let other = EditorPanelsVM(Installer.EditorPanels(on: [app + "/Code/User/settings.json"],
                                                          other: [app + "/Cursor/User/settings.json runs /opt/w, not /Users/you/.zagon/bin/claude-wrap: no limits from that panel"]), f)
        XCTAssertEqual(other.lines, [.init(on: true, text: "On: Code")])
        XCTAssertEqual(other.notes, ["~/Library/Application Support/Cursor/User/settings.json runs /opt/w, not ~/.zagon/bin/claude-wrap: no limits from that panel"])
        XCTAssertEqual([other.canEnable, other.canDisable], [false, true])
        let alone = EditorPanelsVM(Installer.EditorPanels(other: ["x is not a JSON object"]), f)
        XCTAssertEqual([alone.lines.isEmpty, alone.canEnable, alone.canDisable], [true, false, false])
        XCTAssertEqual(EditorPanelsVM(Installer.EditorPanels(), Fmt(lang: .ru, timeZone: utc, now: f.now)).lines.map(\.text),
                       ["Редакторы VS Code и Cursor не найдены"])
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
