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
}
