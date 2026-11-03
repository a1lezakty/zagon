import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// "Sessions worked" is wall-clock; the sessions' summed time shows under it as agent time when it is more.
final class WallClockTileTests: XCTestCase {
    func testAgentTimeUnderSessionsWorked() {
        let f = Fmt(lang: .ru, timeZone: TimeZone(identifier: "UTC")!, now: Date())
        let parallel = Totals(sessionSec: 2 * 3600, agentSec: 6 * 3600, tokens: 0, cost: 0)
        XCTAssertEqual(f.agentTime(parallel), "агентного времени " + f.duration(6 * 3600))
        XCTAssertNil(f.agentTime(Totals(sessionSec: 2 * 3600, agentSec: 2 * 3600 + 30, tokens: 0, cost: 0)))
        XCTAssertNil(f.agentTime(Totals(sessionSec: 2 * 3600, tokens: 0, cost: 0)))   // not known
        let day = DayVM(DayData(day: Date(), totals: parallel), f)
        XCTAssertEqual(day.stats.first?.value, f.duration(2 * 3600))
        XCTAssertEqual(day.stats.first?.delta, "агентного времени " + f.duration(6 * 3600))
    }

    /// The week's hours per day are wall-clock: the projects' parts share the day's real hours.
    func testWeekDayHoursAreWallClock() {
        let f = Fmt(lang: .en, timeZone: TimeZone(identifier: "UTC")!, now: Date())
        let empty = Totals(sessionSec: 0, tokens: 0, cost: 0)
        let w = WeekData(start: Date(timeIntervalSince1970: 1_793_059_200), projects: ["a", "b"],
                         days: [[Totals(sessionSec: 4 * 3600, tokens: 0, cost: 0), Totals(sessionSec: 2 * 3600, tokens: 0, cost: 0)]]
                            + Array(repeating: [empty, empty], count: 6),
                         totals: empty, previous: empty, projectRows: [], limitByDay: Array(repeating: nil, count: 7),
                         workedByDay: [2 * 3600, 0, 0, 0, 0, 0, 0])
        let d = WeekVM(w, weekLimit: nil, f).days(.hours)[0]
        XCTAssertEqual(d.total, f.duration(2 * 3600))
        XCTAssertEqual(d.value, 2, accuracy: 1e-9)
        XCTAssertEqual(d.parts.count, 2)
        XCTAssertEqual(d.parts[0].value, 4.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(d.parts[1].value, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(WeekVM(w, weekLimit: nil, f).days(.tokens)[0].total, "—")
    }
}
