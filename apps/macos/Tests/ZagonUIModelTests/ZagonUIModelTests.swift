import Foundation
import XCTest
@testable import ZagonUIModel

final class ZagonUIModelTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func env(_ lang: Lang) -> (MockDataProvider, Fmt) {
        let p = MockDataProvider(lang: lang, timeZone: utc)
        return (p, Fmt(lang: lang, timeZone: utc, now: p.now))
    }

    func testStringTablesMatch() {
        func placeholders(_ s: String) -> Set<String> {
            Set((0..<6).map { "{\($0)}" }.filter { s.contains($0) })
        }
        func base(_ k: String) -> String {
            for f in [".one", ".few", ".many"] where k.hasSuffix(f) { return String(k.dropLast(f.count)) }
            return k
        }
        XCTAssertEqual(Set(Strings.en.keys.map(base)), Set(Strings.ru.keys.map(base)))
        for (k, ru) in Strings.ru {
            let en = Strings.en[k] ?? Strings.en[base(k) + ".many"]!
            XCTAssertEqual(placeholders(en), placeholders(ru), k)
        }
        XCTAssertEqual(Strings.ru.keys.filter { $0.hasSuffix(".few") }.count,
                       Strings.ru.keys.filter { $0.hasSuffix(".one") }.count)
    }

    func testNumbersAndDurations() {
        let (_, en) = env(.en), (_, ru) = env(.ru)
        XCTAssertEqual(en.tokens(18_400_000), "18.4M")
        XCTAssertEqual(ru.tokens(18_400_000), "18,4 млн")
        XCTAssertEqual(en.tokens(118_000_000), "118M")
        XCTAssertEqual(en.tokens(640_000), "640K")
        XCTAssertEqual(en.tokens(940), "940")
        XCTAssertEqual(en.tokens(999_400), "999K")
        XCTAssertEqual(en.tokens(999_600), "1.0M")
        XCTAssertEqual(en.tokens(99_960_000), "100M")
        XCTAssertEqual(en.tokens(999_600_000), "1.0B")
        XCTAssertEqual(en.cost(1600), "$1,600")
        XCTAssertEqual(ru.cost(1600), "$1\u{00A0}600")
        XCTAssertEqual(en.cost(0.4), "<$1")
        XCTAssertEqual(en.duration(41 * 60), "41m")
        XCTAssertEqual(en.duration(65 * 60), "1h 05m")
        XCTAssertEqual(ru.duration(7 * 3600 + 20 * 60), "7 ч 20 м")
        XCTAssertEqual(en.duration((2 * 24 + 21) * 3600 + 18 * 60), "2d 21h")
        XCTAssertEqual(en.duration(10), "1m")
        XCTAssertEqual(en.delta(112, 100), "+12%")
        XCTAssertEqual(ru.delta(78, 100), "\u{2212}22 %")
        XCTAssertEqual(en.delta(5, 0), "new")
    }

    func testRussianPlurals() {
        let t = L10n(.ru)
        XCTAssertEqual([1, 2, 5, 11, 21, 22, 112].map { t.plural("sessions", $0) },
                       ["1 сессия", "2 сессии", "5 сессий", "11 сессий", "21 сессия", "22 сессии", "112 сессий"])
        XCTAssertEqual(L10n(.en).plural("sessions", 1), "1 session")
        XCTAssertEqual(L10n(.en).plural("sessions", 3), "3 sessions")
    }

    func testMain() {
        let (p, f) = env(.en)
        let vm = MainVM(p, f)
        XCTAssertEqual(vm.statusLabel, "62%")
        XCTAssertEqual(vm.five?.resetLine, "resets at 14:20")
        XCTAssertEqual(vm.five?.inLine, "in 2h 38m")
        XCTAssertEqual(vm.week?.resetLine, "resets Mon 09:00")
        XCTAssertEqual(vm.week?.inLine, "in 2d 21h")
        XCTAssertEqual(vm.forecast?.bold, "at 13:50")
        XCTAssertEqual(vm.forecast?.after, ", 30m before the reset.")
        XCTAssertEqual(vm.waitingHeader, "WAITING FOR YOU · 2")
        XCTAssertEqual(vm.waiting.map(\.time), ["12m", "4m"])
        XCTAssertEqual(vm.waiting.first?.subtitle, "build-box · asks for permission")
        XCTAssertEqual(vm.working.count, 3)
        XCTAssertEqual(vm.idle.count, 4)
        XCTAssertEqual(vm.totals.map(\.value), ["7h 20m", "18.4M", "$212"])

        let ru = MainVM(env(.ru).0, env(.ru).1)
        XCTAssertEqual(ru.five?.resetLine, "сброс в 14:20")
        XCTAssertEqual(ru.week?.resetLine, "сброс пн 09:00")
        XCTAssertEqual(ru.forecast?.plain, "При таком темпе 5-часовой лимит кончится в 13:50 — за 30 мин до сброса.")
        XCTAssertEqual(ru.waitingHeader, "ЖДУТ ТЕБЯ · 2")
    }

    func testRingTurnsRedNearTheLimit() {
        let (p, f) = env(.en)
        let w = LimitWindow(usedPct: 96, resetsAt: p.now.addingTimeInterval(3600))
        XCTAssertEqual(RingVM(title: "", window: w, base: Palette.fiveHour, f: f).color, Palette.waiting)
        XCTAssertNil(MainVM.forecast(LimitWindow(usedPct: 50, resetsAt: p.now.addingTimeInterval(3600), pctPerHour: 10), f))
        let stale = RingVM(title: "", window: LimitWindow(usedPct: 97, resetsAt: p.now.addingTimeInterval(-600)),
                           base: Palette.fiveHour, f: f)
        XCTAssertNil(stale.pct)
        XCTAssertNil(stale.leftPct)
        XCTAssertEqual([stale.resetLine, stale.inLine], ["reset at 11:32", "no new reading"])
        XCTAssertEqual(stale.color, Palette.fiveHour)
        XCTAssertEqual(stale.spoken, ": reset at 11:32, no new reading")
    }

    /// No reading, an old one, a stale one: the panel says so in words instead of 0 %.
    func testLimitsWithoutCurrentReadings() {
        let (p, f) = env(.ru)
        let vm = MainVM(p, f)
        XCTAssertEqual(vm.limitsHeader, "ЛИМИТЫ CLAUDE")
        XCTAssertNil(vm.limitsAge)
        XCTAssertFalse(vm.limitsMissing)
        XCTAssertNil(vm.noSessions)
        XCTAssertEqual(vm.five?.spoken, "5 часов: использовано 62 %, сброс в 14:20, через 2 ч 38 м")
        XCTAssertEqual(vm.five?.spokenLeft, "5 часов: осталось 38 %, через 2 ч 38 м")

        var stale = MockDataProvider(lang: .ru, timeZone: TimeZone(identifier: "UTC")!)
        stale.staleLimits = true
        let old = MainVM(stale, f)
        XCTAssertNil(old.five?.pct)
        XCTAssertEqual(old.week?.pct, 47)
        XCTAssertTrue(old.limitsMissing)
        XCTAssertEqual(old.limitsAge, "обновлено 6 ч 30 м назад")
        XCTAssertEqual(old.five?.spoken, "5 часов: сброшен в 09:20, нет новых данных")

        let empty = MainVM(StoreDataProvider.empty(), f)
        XCTAssertNil(empty.five)
        XCTAssertEqual(empty.limitsHeader, "ЛИМИТЫ")
        XCTAssertTrue(empty.limitsMissing)
        XCTAssertEqual(empty.noSessions, "Сейчас ни одна сессия не работает.")
        XCTAssertEqual(old.five?.spokenLeft, old.five?.spoken)

        let none = RingVM.empty("Неделя", f)
        XCTAssertEqual([none.pct == nil ? "–" : "?", none.resetLine, none.spoken], ["–", "нет данных", "Неделя: нет данных"])
    }

    func testDay() {
        let (p, f) = env(.en)
        let vm = DayVM(p.day(p.at(29, 15)), f)
        XCTAssertEqual(vm.title, "Thursday, October 29")
        XCTAssertEqual(vm.stats.map(\.value), ["9h 40m", "2h 15m", "31.2M", "$348"])
        XCTAssertEqual(vm.limitNotes.map(\.text), ["5-hour limit hit 1 time: 13:40–14:20", "week over the day: +13% (24 → 37%)"])
        XCTAssertEqual(vm.timeline.ticks, ["08", "10", "12", "14", "16", "18", "20", "22", "24"])
        XCTAssertEqual(vm.timeline.lanes.count, 7)
        let seg = vm.timeline.lanes[1].segments[0]
        XCTAssertEqual(seg.x, 1.0 / 16, accuracy: 1e-9)
        XCTAssertEqual(seg.width, 2.5 / 16, accuracy: 1e-9)
        XCTAssertEqual(vm.timeline.lanes[2].segments.last.map { $0.x + $0.width } ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(vm.longestWait, "Waited for you longest: “cli-tool — parser”, 1h 50m, from 15:10 to 17:00.")
        XCTAssertEqual(vm.summaryNote, "Summary written by Claude Haiku at 23:59, 0.2% of the weekly limit.")
        let usage = vm.usage(.project)
        XCTAssertEqual(usage.map(\.name).last, "other")
        XCTAssertEqual(usage[0].share, 10.6 / 31.2, accuracy: 1e-9)
        XCTAssertEqual(vm.usage(.agent).first?.name, "main thread")
        XCTAssertEqual(vm.done(titles: true).first?.project, "tracker")
        XCTAssertTrue(vm.markdown.hasPrefix("# Thursday, October 29\n"))
        XCTAssertTrue(DayVM(p.day(p.at(4, 0)), f).timeline.lanes.isEmpty)
        let reset = DayData(day: p.at(29, 0), totals: Totals(sessionSec: 3600, tokens: 1, cost: 1), weekPctStart: 95, weekPctEnd: 37)
        XCTAssertTrue(DayVM(reset, f).limitNotes.isEmpty)

        let ru = DayVM(env(.ru).0.day(p.at(29, 0)), env(.ru).1)
        XCTAssertEqual(ru.title, "Четверг, 29 октября")
        XCTAssertEqual(ru.limitNotes.first?.text, "5-часовой упёрся 1 раз: 13:40–14:20")
        XCTAssertEqual(ru.limitNotes.last?.text, "неделя за день: +13 % (24 → 37 %)")
    }

    func testWeek() {
        let (p, f) = env(.en)
        let vm = WeekVM(p.week(containing: p.now), weekLimit: p.limits().week, f)
        XCTAssertEqual(vm.title, "October 26 – November 1")
        XCTAssertEqual(vm.stats.map(\.value), ["36h 50m", "9h 10m", "118M", "$1,600"])
        XCTAssertEqual(vm.stats.map(\.delta), ["+12% vs last week", "+4%", "+21%", "+19%"])
        XCTAssertEqual(vm.stats.map(\.good), [true, true, false, false])
        XCTAssertEqual(vm.projects.map(\.delta), ["+18%", "new", "\u{2212}22%", "new", "\u{2212}5%"])
        XCTAssertEqual(vm.projects.last?.name, "other")
        let days = vm.days(.hours)
        XCTAssertEqual(days.map(\.isToday), [false, false, false, false, true, false, false])
        XCTAssertEqual(days[4].label, "Fri 30 · today")
        XCTAssertEqual(days[3].total, "9h 42m")
        XCTAssertEqual(days[5].total, "—")
        XCTAssertEqual(days[0].parts.count, 3)
        XCTAssertEqual(vm.limit.map(\.text), ["7%", "15%", "24%", "37%", "41%", "", ""])
        XCTAssertEqual(vm.limitForecast?.bold, "70%")
        XCTAssertEqual(vm.limitForecast?.plain,
                       "At this pace the week will be at about 70% by the reset Mon 09:00. Headroom: about 2 days like Thursday.")
        XCTAssertNil(WeekVM(p.week(containing: p.at(12, 0)), weekLimit: p.limits().week, f).limitForecast)
        // A window opened on Wednesday: Monday and Tuesday readings belong to the previous window.
        var w = p.week(containing: p.now)
        w.limitByDay = [80, 90, 3, 10, 14, nil, nil]
        let midweek = WeekVM(w, weekLimit: LimitWindow(usedPct: 14, resetsAt: p.at(35, 9)), f).limitForecast
        XCTAssertTrue(midweek?.after.contains("like Thursday") ?? false, midweek?.plain ?? "nil")

        let ru = WeekVM(env(.ru).0.week(containing: p.now), weekLimit: p.limits().week, env(.ru).1)
        XCTAssertEqual(ru.title, "26 октября — 1 ноября")
        XCTAssertEqual(ru.limitForecast?.plain, "При таком темпе к сбросу пн 09:00 будет около 70 %. Запас — примерно 2 дня как четверг.")
    }

    func testCalendar() {
        let (p, f) = env(.en)
        let vm = CalendarVM(p.month(containing: p.now), selected: p.at(29, 0), f)
        XCTAssertEqual(vm.title, "October 2026")
        XCTAssertEqual(vm.weekdays, ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        XCTAssertEqual(vm.cells.prefix(4).map { $0?.day }, [nil, nil, nil, 1])
        XCTAssertEqual(vm.cells.count % 7, 0)
        let cells = vm.cells.compactMap { $0 }
        XCTAssertEqual(cells.filter(\.selected).map(\.day), [29])
        XCTAssertEqual(cells.filter(\.today).map(\.day), [30])
        XCTAssertEqual(cells.filter(\.future).map(\.day), [31])
        XCTAssertEqual(cells[3].hours, "—")
        XCTAssertEqual(cells[28].hours, "9h")
        XCTAssertEqual(cells[9].hours, "<1h")
        XCTAssertEqual(cells[28].level, 5)
        XCTAssertEqual([nil, 0, 1.9, 4.4, 6.9, 8.9, 9].map(CalendarVM.level), [0, 0, 1, 2, 3, 4, 5])
        XCTAssertEqual(vm.footer[1], "Transcripts archived since October 1.")
        let card = CalendarVM.card(p.day(p.at(29, 0)), f)
        XCTAssertEqual(card.stats.map(\.value), ["9h 40m", "31.2M", "$348"])
        XCTAssertEqual(card.bullets.count, 3)
        let hits = CalendarVM.hits(p.search("demo video"), f)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].meta, "build-box · Oct 30 04:10–07:59 · Opus 5.5")
        XCTAssertTrue(p.search("").isEmpty)
        let ru = CalendarVM.hits(env(.ru).0.search("демо видео"), env(.ru).1)
        XCTAssertEqual(ru.map(\.meta), ["build-box · 30 окт 04:10–07:59 · Opus 5.5", "build-box · 29 окт 21:40–22:31 · Opus 5.5"])
        XCTAssertEqual(CalendarVM(env(.ru).0.month(containing: p.now), selected: p.now, env(.ru).1).title, "Октябрь 2026")
    }

    func testTasks() {
        let (p, f) = env(.en)
        let vm = TasksVM(p.tasks(), filter: .active, f)
        XCTAssertEqual(vm.filters.map(\.label), ["Active · 4", "Planned · 4", "Done · 1"])
        XCTAssertEqual(vm.rows.map(\.key), ["PROJ-21", "PROJ-12", "ZAG-1", "ZAG-2"])
        XCTAssertEqual(vm.rows[0].sessions, "5 sessions")
        XCTAssertEqual(vm.rows[2].sync, "no Jira")
        let d = vm.detail(nil)!
        XCTAssertEqual(d.key, "PROJ-21")
        XCTAssertEqual(d.stats.map(\.value), ["9h 30m", "14h 20m", "21.4M", "11%"])
        XCTAssertEqual(d.jiraLines.map(\.text), ["Status matches: “In Progress”.",
                                                 "Logged 7h 30m of 9h 30m: 2h 00m not logged yet, it goes into the evening plan."])
        XCTAssertEqual(d.done.map(\.day), ["Thu, October 29", "Fri, October 30"])
        XCTAssertEqual(d.sessions.map(\.meta), ["build-box · Opus 5.5 · Oct 29–30", "build-box · Opus 5.5 · Oct 29–30",
                                                "build-box · GPT-5 · Oct 30"])
        let (rp, rf) = env(.ru)
        XCTAssertEqual(rf.dayRange(rp.at(29, 9), rp.at(30, 1)), "29–30 окт")
        XCTAssertEqual(f.dayRange(p.at(31, 9), p.at(33, 1)), "Oct 31–Nov 2")
        XCTAssertTrue(d.sessions[2].codex)
        XCTAssertEqual(vm.detail("ZAG-1")?.jiraLines.map(\.color), [Palette.muted])
        XCTAssertEqual(TasksVM(p.tasks(), filter: .done, f).rows.map(\.status), ["Done"])
    }

    func testWorklog() {
        let (p, f) = env(.en)
        let vm = WorklogVM(p.worklog(p.now), f)
        XCTAssertEqual(vm.title, "What to log — Friday, October 30")
        XCTAssertEqual(vm.stats.map(\.value), ["6h 30m", "11h 10m", "2h 00m", "1h 00m"])
        XCTAssertEqual(vm.stats[0].label, "your work time, 06:00–12:30")
        XCTAssertEqual(vm.ticks, ["06", "07", "08", "09", "10", "11", "12", "13"])
        XCTAssertEqual(vm.segments.map(\.logged), [true, false, false, false])
        XCTAssertEqual(vm.segments[3].x, 3.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(vm.segments[3].label, "ZAG-1 · 3h 30m")
        XCTAssertEqual(vm.segments.map(\.label).prefix(3), ["", "PROJ", "PROJ"])
        XCTAssertEqual(vm.commitTitle, "Log 2 worklogs to Jira · 1h 00m")
        XCTAssertEqual(vm.notes, ["08:00–09:00: 2 sessions ran at once (web-app, API question), the time is split by activity: 30m + 30m.",
                                  "Nothing overlaps the worklogs already in Jira.",
                                  "ZAG-1 is not in Jira, it stays in Zagon only."])
        XCTAssertEqual(vm.copyText.split(separator: "\n").count, 3)
        XCTAssertNil(WorklogVM(p.worklog(p.at(29, 0)), f).commitTitle)

        let ru = WorklogVM(env(.ru).0.worklog(p.now), env(.ru).1)
        XCTAssertEqual(ru.title, "Что логировать — пятница, 30 октября")
        XCTAssertEqual(ru.commitTitle, "Залогировать 2 ворклога в Jira · 1 ч 00 м")
    }

    func testWorklogOverlap() {
        let (p, _) = env(.en)
        let a = WorklogRow(key: "A-1", start: p.at(30, 9), end: p.at(30, 10), text: "", destination: .jira)
        let b = WorklogRow(key: "B-1", start: p.at(30, 9.5), end: p.at(30, 11), text: "", destination: .alreadyLogged)
        let c = WorklogRow(key: "C-1", start: p.at(30, 10), end: p.at(30, 11), text: "", destination: .jira)
        XCTAssertEqual(WorklogVM.overlaps([a, c], logged: [b]).map(\.key), ["A-1", "C-1"])
        XCTAssertTrue(WorklogVM.overlaps([a, c], logged: []).isEmpty)
        // Exact duplicates: of a logged row and of another pending row.
        XCTAssertEqual(WorklogVM.overlaps([b], logged: [b]).map(\.key), ["B-1"])
        XCTAssertEqual(WorklogVM.overlaps([a, a], logged: []).count, 2)
    }
}
