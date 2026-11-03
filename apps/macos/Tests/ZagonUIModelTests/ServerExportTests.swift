import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// A 0.1.6 server's export (`Tests/ZagonCoreTests/Fixtures/server-export-016.ndjson`: a real one with every text
/// replaced) on a Mac that already holds the server's readings from before the server was updated, when it kept two
/// Claude Code accounts as one: the other account's 5 hours (later reset) were stored as this one's.
final class ServerExportTests: XCTestCase {
    static let export = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/ZagonCoreTests/Fixtures/server-export-016.ndjson")
    let now = Date(timeIntervalSince1970: 1_793_699_950)   // a minute after the export's readings

    func testRingsAndOtherAccountAfterTheUpdate() throws {
        let p = StoreDataProvider.empty(now: now), store = p.reader
        let t = now.timeIntervalSince1970
        // Before the update: the other account's 5 hours (resets 12:10) as the default account's, then this one's week.
        for (m, pct) in [(-55.0, 30.0), (-50, 31)] {
            try store.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: pct, resetsAt: 1_793_707_800,
                                                     windowMinutes: 300, ts: t + m * 60), source: "build-box")
        }
        for m in [-20.0, -10] {
            try store.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "seven_day", usedPct: 88, resetsAt: 1_793_883_600,
                                                     windowMinutes: 10080, ts: t + m * 60), source: "build-box")
        }
        let n = try Remote.apply(try Data(contentsOf: Self.export), alias: "build-box", store: store, checked: ["build-box"])
        XCTAssertEqual(n.limits, 6)
        XCTAssertEqual(n.sessions, 213)

        let l = p.limits()
        XCTAssertEqual(l.claude.fiveHour?.usedPct, 10)   // this account's, not the other's 31 % stuck until 12:10
        XCTAssertEqual(l.claude.week?.usedPct, 88)
        XCTAssertEqual(l.others.map(\.account), ["corp"])
        XCTAssertEqual(l.others.first?.limits.fiveHour?.usedPct, 32)
        XCTAssertEqual(l.others.first?.limits.week?.usedPct, 5)

        let vm = MainVM(p, Fmt(lang: .en, timeZone: TimeZone(identifier: "UTC")!, now: now))
        XCTAssertEqual(vm.five?.pct, 10)                 // the 5-hour ring is there
        XCTAssertEqual(vm.week?.pct, 88)
        XCTAssertEqual(vm.accounts.map(\.name), ["Claude · corp"])
        XCTAssertEqual(try store.db.one("SELECT count(*) FROM session WHERE account = 'corp'") { $0.int(0) }, 11)
    }
}
