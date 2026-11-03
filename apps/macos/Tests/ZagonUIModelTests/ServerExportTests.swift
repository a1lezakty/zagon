import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// A 0.1.6 server's export (`Tests/ZagonCoreTests/Fixtures/server-export-016.ndjson`: a real one with every text
/// replaced) on a Mac that already holds the server's readings from before the server was updated, when it kept two
/// Claude Code accounts as one: the other account's 5 hours (later reset) were stored as this one's.
final class ServerExportTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/ZagonCoreTests/Fixtures")
    static let export = fixtures.appendingPathComponent("server-export-016.ndjson")
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
        XCTAssertEqual(vm.ais.map(\.name), ["Claude", "Claude · corp", "Codex"])
        XCTAssertEqual(vm.ais[1].five.pct, 32)
        XCTAssertEqual(try store.db.one("SELECT count(*) FROM session WHERE account = 'corp'") { $0.int(0) }, 11)
    }

    /// A 0.1.7 server's sessions (`server-export-017-bg.ndjson`, texts replaced): a worker whose turn ended with two
    /// background tasks running, one whose tasks ended, both driven by the lead. A Mac 0.1.6 pulled them without the
    /// columns it did not know and moved its cursor; after its update nothing about them changed on the server, so an
    /// incremental pull alone would never bring their tasks: the cursor of another schema pulls from zero once.
    func testBackgroundFromAServerPulledBeforeTheUpdate() throws {
        let now = Date(timeIntervalSince1970: 1_793_705_666)  // a minute after the export
        let p = StoreDataProvider.empty(now: now), store = p.reader
        let lines = try String(decoding: Data(contentsOf: Self.fixtures.appendingPathComponent("server-export-017-bg.ndjson")),
                               as: UTF8.self).split(separator: "\n").map(String.init)
        func pull(_ ls: [String]) throws { try Remote.apply(Data(ls.joined(separator: "\n").utf8), alias: "build-box", store: store) }
        func cursor() throws -> Int { try Remote.cursor("build-box", db: store.db) }
        let f = Fmt(lang: .ru, timeZone: TimeZone(identifier: "UTC")!, now: now)

        // Mac 0.1.6: no bg_tasks / bg_until, no schema by the cursor.
        try pull(lines.map { $0.replacing(/"bg_tasks":"[^"]*",|"bg_until":[0-9.]+,/, with: "") })
        try store.db.run("DELETE FROM meta WHERE key = 'remote_schema:build-box'")
        XCTAssertEqual(try cursor(), 176_559)
        var vm = MainVM(p, f)
        XCTAssertEqual(vm.working.map(\.title), ["example-project — lead"])
        // The symptom: "driven by lead · turn ended", not in background.
        XCTAssertEqual(vm.idle.map(\.title), ["example-project — worker-done", "example-project — worker-bg"])
        XCTAssertEqual(vm.idle.last.map { $0.subtitle.hasSuffix(" · под управлением lead · ход окончен 24 мин назад") }, true)

        // Updated: the next pull has nothing new, but its schema is not the cursor's: the one after starts from zero.
        try pull([lines[0].replacing("\"since\":0", with: "\"since\":176559")])
        XCTAssertEqual(try cursor(), 0)
        try pull(lines)
        XCTAssertEqual(try cursor(), 176_559)
        vm = MainVM(p, f)
        XCTAssertEqual(vm.working.map(\.title), ["example-project — worker-bg", "example-project — lead"])
        XCTAssertEqual(vm.working.first.map { $0.subtitle.hasSuffix(" · в фоне (2 задачи) · 24 мин") }, true)
        XCTAssertEqual(vm.working.first?.tag, " (corp)")
        // Its tasks ended 2 hours ago and it has waited longer than half an hour: idle.
        XCTAssertEqual(vm.idle.map(\.title), ["example-project — worker-done"])
        // Same schemas from now on: the cursor moves as before.
        try pull([lines[0]])
        XCTAssertEqual(try cursor(), 176_559)
    }
}
