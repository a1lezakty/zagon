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
        XCTAssertEqual(main.five?.pct, 62)
        XCTAssertEqual(main.five?.resetLine, "resets at 14:20")
        XCTAssertEqual(main.week?.resetLine, "resets Mon 09:00")
        XCTAssertEqual(main.forecast?.plain, "At this pace the 5-hour limit runs out at 13:50, 30m before the reset.")
        // Claude used, with a current reading: no hint; the hint once the readings are gone.
        var limits = p.limits()
        XCTAssertNotNil(limits.claudeSeen)
        XCTAssertNil(main.claudeHint)
        limits.claude = AILimits()
        XCTAssertTrue(limits.claudeHint(at: p.now))
        XCTAssertEqual(main.waiting.map(\.title), ["web-app — demo video", "api-server — PROJ-12"])
        XCTAssertEqual(main.waiting.map(\.time), ["12m", "4m"])
        XCTAssertEqual(main.waiting.first?.subtitle, "laptop · asks for permission")
        XCTAssertEqual(Set(main.working.map(\.title)), ["zagon — mockups", "ml-train — run 300", "cli-tool — parser"])
        XCTAssertEqual(main.working.first { $0.title.hasPrefix("zagon") }?.subtitle, "laptop · Opus 5.5")
        XCTAssertEqual(main.idle.count, 2)
        let video = try XCTUnwrap(p.liveSessions().first { $0.title.hasSuffix("demo video") })
        XCTAssertEqual(main.waiting.first?.command, "cd '/work/web-app' && claude --resume " + String(video.id.dropFirst(7)))

        let day = DayVM(p.day(p.now.addingTimeInterval(-86400)), f)
        let data = p.day(p.now.addingTimeInterval(-86400))
        XCTAssertEqual(data.hostProjects, ["laptop": data.projects])  // one machine: its list is the day's
        XCTAssertEqual(day.title, "Thursday, October 29")
        XCTAssertEqual(day.timeline.lanes.count, 7)
        XCTAssertEqual(day.timeline.ticks.first, "08")
        XCTAssertEqual(day.limitNotes.map(\.text), ["5-hour limit hit 1 time: 13:40–14:20", "week over the day: +13% (24 → 37%)"])
        XCTAssertEqual(day.longestWait, "Waited for you longest: “cli-tool — parser”, 1h 50m, from 15:10 to 17:00.")
        XCTAssertEqual(day.usage(.model).map(\.name), ["Opus 5.5", "Sonnet 5.5", "Haiku 4.5"])
        XCTAssertEqual(day.usage(.agent).map(\.name), ["main thread", "agent-a7f3"])
        XCTAssertTrue(day.usage(.tool).allSatisfy { $0.tokens.hasSuffix(" calls") && $0.cost.isEmpty })
        XCTAssertFalse(day.hasSummary)
        XCTAssertNil(day.summaryNote)
        // Without a written summary: projects with their sessions' time and branch, most time first.
        XCTAssertEqual(Set(day.projects.map(\.name)), ["api-server", "web-app", "ml-train", "docs-site", "cli-tool", "tracker"])
        XCTAssertTrue(day.projects.allSatisfy { !$0.sessions.isEmpty && !$0.numbers.isEmpty })
        XCTAssertTrue(day.projects.flatMap(\.sessions).contains { $0.hasSuffix(" · PROJ-12-check") })
        XCTAssertTrue(day.markdown.contains("## What was done\n\n### "))
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

    /// When Claude was last used: Claude's sessions of the last 7 days only.
    func testClaudeSeen() throws {
        let p = try StoreDataProvider.fixture(Self.fixtures)
        let last = try XCTUnwrap(p.limits().claudeSeen)
        XCTAssertLessThan(p.now.timeIntervalSince(last), 86400)
        _ = try p.query.db.run("UPDATE session SET tool = 'codex' WHERE last_at >= ?", [.real(p.now.timeIntervalSince1970 - 86400)])
        _ = try p.query.db.run("UPDATE session SET last_at = ? WHERE tool = 'claude'", [.real(p.now.timeIntervalSince1970 - 8 * 86400)])
        XCTAssertNil(p.limits().claudeSeen)
    }

    /// `AILimits.weekAlone`: the first week reading over a minute after the 5-hour one was due; none while both come.
    func testWeekAlone() throws {
        let p = try StoreDataProvider.fixture(Self.fixtures)
        let now = p.now.timeIntervalSince1970
        _ = try p.query.db.run("DELETE FROM limit_snapshot")
        func add(_ window: String, _ pct: Double, resets: Double, at ts: Double, account: String = "default") throws {
            _ = try p.query.db.run("INSERT INTO limit_snapshot(tool, window, used_pct, resets_at, ts, account) VALUES('claude', ?, ?, ?, ?, ?)",
                                   [.text(window), .real(pct), .real(resets), .real(ts), .text(account)])
        }
        // Both come: nothing alone; nor with another account's week readings since.
        try add("five_hour", 30, resets: now + 3600, at: now - 120)
        try add("seven_day", 40, resets: now + 86400, at: now - 120)
        try add("seven_day", 10, resets: now + 86400, at: now - 30, account: "corp")
        try add("seven_day", 10, resets: now + 86400, at: now, account: "corp")
        XCTAssertNil(p.limits().claude.weekAlone)
        _ = try p.query.db.run("DELETE FROM limit_snapshot WHERE account = 'corp'")
        // The week alone since: from its first reading over a minute after the 5 hours'.
        try add("seven_day", 40, resets: now + 86400, at: now - 90)  // within the minute: a reset's own reading
        try add("seven_day", 41, resets: now + 86400, at: now - 30)
        try add("seven_day", 41, resets: now + 86400, at: now)
        let l = p.limits()
        XCTAssertEqual(l.claude.weekAlone?.timeIntervalSince1970, now - 30)
        XCTAssertEqual(l.claude.week?.readAt?.timeIntervalSince1970, now)
        // The 5 hours over: due at their reset.
        _ = try p.query.db.run("UPDATE limit_snapshot SET resets_at = ? WHERE window = 'five_hour'", [.real(now - 100)])
        XCTAssertEqual(p.limits().claude.weekAlone?.timeIntervalSince1970, now - 30)
        _ = try p.query.db.run("UPDATE limit_snapshot SET resets_at = ? WHERE window = 'five_hour'", [.real(now - 50)])
        XCTAssertNil(p.limits().claude.weekAlone)
        // The plan changed while the 5 hours ran: the week came alone for 10 minutes before their reset, so it counts
        // from then, not from the reset.
        _ = try p.query.db.run("DELETE FROM limit_snapshot")
        try add("five_hour", 30, resets: now - 300, at: now - 2000)
        for t in stride(from: now - 1900, through: now, by: 100) { try add("seven_day", 40, resets: now + 86400, at: t) }
        XCTAssertEqual(p.limits().claude.weekAlone?.timeIntervalSince1970, now - 1900)
        // Under 10 minutes alone before the reset (a normal plan): from the reset.
        _ = try p.query.db.run("DELETE FROM limit_snapshot WHERE window = 'seven_day' AND ts < ?", [.real(now - 800)])
        XCTAssertEqual(try XCTUnwrap(p.limits().claude.weekAlone).timeIntervalSince1970, now - 200, accuracy: 0.01)
    }

    /// Claude Code accounts: the default account's rings stay its own; the others with a reading within 8 days get a
    /// ring-in-ring each next to it; with readings of another account only, the rings are that account's and no hint.
    func testAccountLimits() throws {
        let p = try StoreDataProvider.fixture(Self.fixtures)
        let f = Fmt(lang: .en, timeZone: TimeZone(identifier: "UTC")!, now: p.now)
        let now = p.now.timeIntervalSince1970
        let before = p.limits()
        XCTAssertTrue(before.others.isEmpty)
        XCTAssertTrue(MainVM(p, f).ais.isEmpty)
        // Another account, fuller and read later than the default one.
        for (window, pct, resets) in [("five_hour", 23.0, now + 3 * 3600), ("seven_day", 97, now + 5 * 86400)] {
            try p.reader.addLimitSnapshot(LimitSnapshot(tool: .claude, window: window, usedPct: pct, resetsAt: resets,
                                                        ts: now - 60, account: "corp"))
        }
        let l = p.limits()
        XCTAssertEqual(l.claude.fiveHour?.usedPct, before.claude.fiveHour?.usedPct)
        XCTAssertEqual(l.claude.week?.usedPct, before.claude.week?.usedPct)
        XCTAssertEqual(l.others.map(\.account), ["corp"])
        XCTAssertEqual(l.others.first?.limits.week?.usedPct, 97)
        let main = MainVM(p, f)
        XCTAssertEqual(main.five?.pct, 62)
        XCTAssertNil(main.limitsSource)
        XCTAssertEqual(main.ais.map(\.name), ["Claude", "Claude · corp"])
        XCTAssertEqual(main.ais.map { [$0.five.pct, $0.week.pct] }, [[62, 41], [23, 97]])
        XCTAssertEqual(main.ais[1].fiveLine, "5h until 14:42")
        XCTAssertEqual(main.ais[1].weekLeftLine, "week 3%")
        XCTAssertEqual(main.ais[1].week.color, Palette.waiting)   // red from 95 %, as the default account's
        XCTAssertTrue(main.ais[1].spoken.hasPrefix("Claude · corp: 5 hours: 23% used"))
        // Over 8 days old: not listed.
        _ = try p.reader.db.run("UPDATE limit_snapshot SET ts = ?, resets_at = ? WHERE account = 'corp'",
                                [.real(now - 9 * 86400), .real(now - 8 * 86400)])
        XCTAssertTrue(p.limits().others.isEmpty)
        // Claude Code run only under another account (no default reading within 8 days): the rings are that account's,
        // say so, and it has no line of its own; its sessions count for the hint.
        _ = try p.reader.db.run("UPDATE limit_snapshot SET ts = ?, resets_at = ? WHERE account = 'corp'", [.real(now - 60), .real(now + 3600)])
        _ = try p.reader.db.run("UPDATE limit_snapshot SET ts = ts - 9 * 86400, resets_at = resets_at - 9 * 86400 WHERE account = 'default'")
        _ = try p.reader.db.run("UPDATE session SET account = 'corp' WHERE tool = 'claude'")
        let only = p.limits()
        XCTAssertEqual([only.claude.fiveHour?.usedPct, only.claude.week?.usedPct], [23, 97])
        XCTAssertEqual(only.claude.fiveHour?.from, LimitFrom(account: "corp"))
        XCTAssertTrue(only.others.isEmpty)
        XCTAssertNotNil(only.claudeSeen)
        XCTAssertFalse(only.claudeHint(at: p.now))
        let ringsOnly = MainVM(p, f)
        XCTAssertEqual(ringsOnly.five?.pct, 23)
        XCTAssertEqual(ringsOnly.limitsSource, "this Mac · corp")
        XCTAssertTrue(ringsOnly.ais.isEmpty)
        XCTAssertFalse(ringsOnly.limitsMissing)
        // The default account reads again: back in the rings, the other account on its line.
        _ = try p.reader.db.run("UPDATE limit_snapshot SET ts = ts + 9 * 86400, resets_at = resets_at + 9 * 86400 WHERE account = 'default'")
        XCTAssertEqual(p.limits().claude.fiveHour?.usedPct, before.claude.fiveHour?.usedPct)
        XCTAssertNil(p.limits().claude.fiveHour?.from)
        XCTAssertEqual(p.limits().others.map(\.account), ["corp"])
    }

    /// A session of another Claude Code account carries its tag in the panel, the day's lanes and its project's sessions.
    func testAccountTags() throws {
        let p = try StoreDataProvider.fixture(Self.fixtures)
        let f = Fmt(lang: .en, timeZone: TimeZone(identifier: "UTC")!, now: p.now)
        _ = try p.reader.db.run("UPDATE session SET account = 'default' WHERE tool = 'claude'")
        _ = try p.reader.db.run("UPDATE session SET account = 'corp' WHERE title LIKE '%parser%'")
        let main = MainVM(p, f)
        XCTAssertEqual(main.working.map { $0.title + $0.tag }.sorted(),
                       ["cli-tool — parser (corp)", "ml-train — run 300", "zagon — mockups"])
        XCTAssertTrue((main.waiting + main.idle).allSatisfy { $0.tag.isEmpty })
        let day = DayVM(p.day(p.now.addingTimeInterval(-86400)), f)
        XCTAssertEqual(day.timeline.lanes.filter { !$0.tag.isEmpty }.map { $0.title + $0.tag }, ["cli-tool — parser (corp)"])
        XCTAssertEqual(day.projects.first { $0.name == "cli-tool" }?.sessions.map { $0.hasPrefix("parser (corp) — ") }, [true])
    }

    /// Under the hint, the editors' settings of the home folder: off in the editor found, then on.
    func testClaudeEditors() throws {
        let p = try StoreDataProvider.fixture(Self.fixtures)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-editors-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = home + "/Library/Application Support/Cursor/User"
        try FileManager.default.createDirectory(atPath: user, withIntermediateDirectories: true)
        try "{}".write(toFile: user + "/settings.json", atomically: true, encoding: .utf8)
        p.paths = ZagonPaths(home: home, dir: home + "/.zagon")
        XCTAssertNil(p.limits().claudeEditors)  // current readings: no hint, not read
        _ = try p.query.db.run("DELETE FROM limit_snapshot")
        XCTAssertEqual(p.limits().claudeEditors, Installer.EditorPanels(off: [user + "/settings.json"]))
        let script = Installer.wrapScript(p.paths)
        try FileManager.default.createDirectory(atPath: home + "/.zagon/bin", withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: script, atomically: true, encoding: .utf8)
        try #"{"claudeCode.claudeProcessWrapper": "\#(script)"}"#.write(toFile: user + "/settings.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(p.limits().claudeEditors, Installer.EditorPanels(off: [user + "/settings.json"]))  // read a minute ago
        p.forgetEditors()
        XCTAssertEqual(p.limits().claudeEditors, Installer.EditorPanels(on: [user + "/settings.json"]))
    }

    /// Today's price per AI adds up to the day's; the tokens of a Codex session count for Codex.
    func testCostPerTool() throws {
        let p = try StoreDataProvider.fixture(Self.fixtures)
        let f = Fmt(lang: .en, timeZone: TimeZone(identifier: "UTC")!, now: p.now)
        let before = p.todayTotals()
        XCTAssertGreaterThan(before.cost, 0)
        XCTAssertEqual(Array(before.costByTool.keys), [.claude])
        XCTAssertEqual(before.costByTool[.claude] ?? 0, before.cost, accuracy: 1e-9)
        XCTAssertEqual(MainVM(p, f).costSplit, [])

        let hour = (p.now.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        _ = try p.query.db.run("""
            INSERT INTO usage_hour(file_id, session_id, agent, hour, model, input, output) VALUES (0, 'codex:s1', '', ?, 'gpt-5.5', 1000000, 100000)
            """, [.real(hour)])
        let t = p.todayTotals()
        XCTAssertEqual(t.costByTool[.codex] ?? 0, 8, accuracy: 1e-9)  // 1M input at $5 + 0.1M output at $30
        XCTAssertEqual(t.costByTool[.claude], before.costByTool[.claude])
        XCTAssertEqual(t.cost, before.cost + 8, accuracy: 1e-9)
        XCTAssertEqual(MainVM(p, f).costSplit, ["Claude " + f.cost(before.cost), "Codex $8"])
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
    }
}
