import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// Screens built from a real store: the synthetic Claude fixtures scanned by ZagonCore (see generate.py there).
final class StoreDataProviderTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/ZagonCoreTests/Fixtures/scenario").path

    func testScreensFromFixtureStore() throws {
        let p = try StoreDataProvider.fixture(Self.fixtures)
        let f = Fmt(lang: .en, timeZone: TimeZone(identifier: "UTC")!, now: p.now)

        let main = MainVM(p, f)
        XCTAssertEqual(main.statusLabel, "62%")
        XCTAssertEqual(main.five?.resetLine, "resets at 14:20")
        XCTAssertEqual(main.week?.resetLine, "resets Mon 09:00")
        XCTAssertEqual(main.forecast?.plain, "At this pace the 5-hour limit runs out at 13:50, 30m before the reset.")
        XCTAssertEqual(main.waiting.map(\.title), ["web-app — demo video", "api-server — PROJ-12"])
        XCTAssertEqual(main.waiting.map(\.time), ["12m", "4m"])
        XCTAssertEqual(main.waiting.first?.subtitle, "laptop · asks for permission")
        XCTAssertEqual(Set(main.working.map(\.title)), ["zagon — mockups", "ml-train — run 300", "cli-tool — parser"])
        XCTAssertEqual(main.working.first { $0.title.hasPrefix("zagon") }?.subtitle, "laptop · Opus 5.5")
        XCTAssertEqual(main.idle.count, 2)
        let video = try XCTUnwrap(p.liveSessions().first { $0.title.hasSuffix("demo video") })
        XCTAssertEqual(main.waiting.first?.command, "cd '/work/web-app' && claude --resume " + String(video.id.dropFirst(7)))

        let day = DayVM(p.day(p.now.addingTimeInterval(-86400)), f)
        XCTAssertEqual(day.title, "Thursday, October 29")
        XCTAssertEqual(day.timeline.lanes.count, 7)
        XCTAssertEqual(day.timeline.ticks.first, "08")
        XCTAssertEqual(day.limitNotes.map(\.text), ["5-hour limit hit 1 time: 13:40–14:20", "week over the day: +13% (24 → 37%)"])
        XCTAssertEqual(day.longestWait, "Waited for you longest: “cli-tool — parser”, 1h 50m, from 15:10 to 17:00.")
        XCTAssertEqual(day.usage(.model).map(\.name), ["Opus 5.5", "Sonnet 5.5", "Haiku 4.5"])
        XCTAssertEqual(day.usage(.agent).map(\.name), ["main thread", "agent-a7f3"])
        XCTAssertTrue(day.usage(.tool).allSatisfy { $0.tokens.hasSuffix(" calls") && $0.cost.isEmpty })
        XCTAssertEqual(day.done(titles: true).first?.project, "tracker")
        XCTAssertFalse(day.hasSummary)
        XCTAssertEqual(day.done(titles: false).first?.project, "tracker")
        XCTAssertEqual(day.usage(.project).count, 5)
        XCTAssertEqual(day.usage(.project).last?.name, "other")
        XCTAssertFalse(day.isEmpty)

        let week = WeekVM(p.week(containing: p.now), weekLimit: p.limits().week, f)
        XCTAssertEqual(week.title, "October 26 – November 1")
        XCTAssertEqual(week.limit.map(\.text), ["", "", "", "37%", "41%", "", ""])
        XCTAssertEqual(week.days(.hours).map(\.isToday), [false, false, false, false, true, false, false])
        XCTAssertEqual(week.days(.hours)[5].total, "—")
        XCTAssertEqual(week.legend.count, 5)
        XCTAssertEqual(week.legend.last?.name, "other")
        XCTAssertNotNil(week.limitForecast)

        let cal = CalendarVM(p.month(containing: p.now), selected: p.now, f)
        let cells = cal.cells.compactMap { $0 }
        XCTAssertEqual(cells.first?.hours, "6h")
        XCTAssertEqual(cells[3].hours, "—")
        XCTAssertEqual(cells.filter(\.future).map(\.day), [31])
        XCTAssertEqual(Set(p.search("demo video").map(\.title)), ["web-app — demo video", "web-app — main"])

        XCTAssertTrue(p.tasks().isEmpty)
        let log = WorklogVM(p.worklog(p.now), f)
        XCTAssertTrue(log.rows.isEmpty)
        XCTAssertNil(log.commitTitle)
        XCTAssertEqual(p.hosts().map(\.name), ["laptop"])
    }

    /// The chosen zone cuts the days of every machine's data: per-day sums move, the whole stays.
    func testTimeZoneMovesDaysNotTotals() throws {
        let p = try StoreDataProvider.fixture(Self.fixtures)
        func days(_ id: String) -> [Totals] {
            let z = TimeZone(identifier: id)!
            p.timeZone = z
            var c = Calendar(identifier: .gregorian)
            c.timeZone = z
            let first = c.date(from: DateComponents(year: 2026, month: 9, day: 15))!
            return (0..<60).map { p.day(c.date(byAdding: .day, value: $0, to: first)!).totals }
        }
        let utc = days("UTC"), india = days("Asia/Kolkata"), la = days("America/Los_Angeles")
        func sum(_ xs: [Totals]) -> (Int, Double, Double) {
            (xs.reduce(0) { $0 + $1.tokens }, xs.reduce(0) { $0 + $1.sessionSec }, xs.reduce(0) { $0 + $1.userSec })
        }
        let total = sum(utc)
        XCTAssertGreaterThan(total.0, 0)
        for other in [india, la] {
            XCTAssertNotEqual(other.map(\.sessionSec), utc.map(\.sessionSec))
            XCTAssertEqual(sum(other).0, total.0)
            XCTAssertEqual(sum(other).1, total.1, accuracy: 1e-3)
            XCTAssertEqual(sum(other).2, total.2, accuracy: 1e-3)
        }
        // The calendar follows the zone too.
        p.timeZone = TimeZone(identifier: "UTC")!
        let monthUTC = p.month(containing: p.now).hours.compactMap { $0 }
        p.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let monthIndia = p.month(containing: p.now).hours.compactMap { $0 }
        XCTAssertNotEqual(monthUTC, monthIndia)
    }

    func testZoneLabelsAndSearch() throws {
        let d = Date(timeIntervalSince1970: 1_793_360_520)  // 2026-10-30
        XCTAssertEqual(Zones.offset(TimeZone(identifier: "Asia/Kolkata")!, at: d), "UTC+5:30")
        XCTAssertEqual(Zones.offset(TimeZone(identifier: "America/Los_Angeles")!, at: d), "UTC−7")
        XCTAssertEqual(Zones.offset(TimeZone(identifier: "UTC")!, at: d), "UTC")
        XCTAssertEqual(Zones.label(TimeZone(identifier: "UTC")!, at: d), "UTC")
        XCTAssertEqual(Zones.label(TimeZone(identifier: "America/St_Johns")!, at: d), "America/St Johns · UTC−2:30")
        XCTAssertFalse(Zones.wholeHours(TimeZone(identifier: "Asia/Kolkata")!, at: d))
        XCTAssertTrue(Zones.wholeHours(TimeZone(identifier: "Asia/Almaty")!, at: d))
        // Linux lists the old name Asia/Calcutta, macOS Asia/Kolkata: the search is checked on a zone both list.
        XCTAssertTrue(Zones.search("kathmandu", at: d).contains("Asia/Kathmandu"))
        XCTAssertTrue(Zones.search("UTC+5:45", at: d).contains("Asia/Kathmandu"))
        XCTAssertTrue(Zones.search("utc-7", at: d).contains("America/Los_Angeles"))
        XCTAssertTrue(Zones.search("st johns", at: d).contains("America/St_Johns"))
        XCTAssertFalse(Zones.search("utc+1", at: d).contains { (TimeZone(identifier: $0)?.secondsFromGMT(for: d) ?? 0) >= 10 * 3600 })
        XCTAssertTrue(Zones.search("utc+1", at: d).contains("Europe/Paris"))
        let zero = Zones.search("utc+0", at: d)
        XCTAssertFalse(zero.isEmpty)
        XCTAssertTrue(zero.allSatisfy { TimeZone(identifier: $0)?.secondsFromGMT(for: d) == 0 })
        XCTAssertFalse(Zones.search("gmt", at: d).isEmpty, "a name word, not an offset")
        let all = Zones.search("", at: d)
        XCTAssertGreaterThan(all.count, 300)
        XCTAssertLessThan(try XCTUnwrap(all.firstIndex(of: "America/Los_Angeles")), try XCTUnwrap(all.firstIndex(of: "Asia/Kathmandu")))
    }

    /// Each day ends where the next begins, also where a DST change skips midnight (Santiago) or repeats an hour.
    func testDayBoundsAreContiguous() throws {
        for id in ["America/Santiago", "America/Los_Angeles", "Asia/Kathmandu", "UTC"] {
            let z = try XCTUnwrap(TimeZone(identifier: id))
            var day = "2026-01-01"
            for _ in 0..<365 {
                let next = try XCTUnwrap(Time.addDays(day, 1))
                let a = try XCTUnwrap(StoreDataProvider.bounds(day, z)), b = try XCTUnwrap(StoreDataProvider.bounds(next, z))
                XCTAssertEqual(a.1, b.0, "\(id) \(day)")
                XCTAssertTrue([23.0, 24, 25].contains((a.1 - a.0) / 3600), "\(id) \(day)")
                XCTAssertEqual(StoreDataProvider.day(Date(timeIntervalSince1970: a.0 + 1), z), day)
                day = next
            }
        }
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let fallBack = try XCTUnwrap(StoreDataProvider.bounds("2026-11-01", la))
        XCTAssertEqual(fallBack.1 - fallBack.0, 25 * 3600)
    }

    /// This Mac's sessions resume here whatever name the Mac had when they ran; a server's go over ssh by its alias.
    func testOwnSessionsResumeLocally() throws {
        let p = try StoreDataProvider.fixture(Self.fixtures)
        XCTAssertEqual(p.shown("laptop-2.local"), "laptop")
        XCTAssertFalse(p.command(tool: "claude", id: "abc", cwd: "/w", host: p.shown("laptop-2.local")).contains("ssh"))
        XCTAssertFalse(p.serverOnline("build-box"), "grey until the first pull")
    }

    func testModelNames() {
        XCTAssertEqual(["claude-opus-4-1-20250805", "claude-3-5-sonnet-20241022", "claude-haiku-4-5", "gpt-5-codex", "", "o3"]
            .map(StoreDataProvider.modelName), ["Opus 4.1", "Sonnet 3.5", "Haiku 4.5", "GPT-5-codex", "", "o3"])
        XCTAssertEqual(StoreDataProvider.title("PROJ-12", "api-server", "claude:x"), "api-server — PROJ-12")
        XCTAssertEqual(StoreDataProvider.title("api-server fixes", "api-server", "claude:x"), "api-server fixes")
        XCTAssertEqual(StoreDataProvider.title(nil, nil, "claude:0123456789"), "01234567")
        XCTAssertEqual(StoreDataProvider.doneItems("- zagon: mockups\nplain line\n\n").map { [$0.project, $0.text] },
                       [["zagon", "mockups"], ["", "plain line"]])
    }
}
