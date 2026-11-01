import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// The rings say whose limits they are only when readings come from more than one source (two accounts).
final class LimitSourceTests: XCTestCase {
    func testLabelsOnlyWithTwoSourcesAndNotAfterTheServerIsDropped() throws {
        let p = try StoreDataProvider.fixture(StoreDataProviderTests.fixtures)
        let f = Fmt(lang: .en, timeZone: TimeZone(identifier: "UTC")!, now: p.now)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-limits-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "[limits]\naccount = \"work\"\n".write(toFile: dir + "/config.toml", atomically: false, encoding: .utf8)
        p.paths = ZagonPaths(dir: dir)

        // This Mac's readings alone: no label.
        XCTAssertNotNil(MainVM(p, f).five?.pct)
        XCTAssertNil(MainVM(p, f).limitsSource)

        // A server on another account: its 5-hour window resets later, so the ring is its; the week stays this Mac's.
        let server = try Store(path: ":memory:")
        let now = p.now.timeIntervalSince1970, five = try XCTUnwrap(p.limits().claude.fiveHour).resetsAt.timeIntervalSince1970
        try server.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: 9, resetsAt: five + 3600,
                                                  windowMinutes: 300, ts: now - 60))
        var out = ""
        try Export.run(store: server, since: 0, account: "personal") { out += $0 + "\n" }
        try Remote.apply(Data(out.utf8), alias: "build-box", store: p.reader)
        let vm = MainVM(p, f)
        XCTAssertEqual(vm.five?.pct, 9)
        XCTAssertEqual(vm.limitsSource, "build-box · personal / this Mac · work")

        // Unchecked: the alias is no source any more.
        try Remote.drop("build-box", db: p.reader.db)
        XCTAssertNil(MainVM(p, f).limitsSource)
    }

    func testBothAIsEachSayTheirOwn() {
        var p = MockDataProvider(lang: .en)
        p.codexLimits = true
        p.twoSources = true
        let vm = MainVM(p, Fmt(lang: .en, timeZone: TimeZone(identifier: "UTC")!, now: p.now))
        XCTAssertEqual(vm.ais.map(\.source), ["build-box · work", "this Mac · personal"])
        XCTAssertNil(vm.limitsSource)
        XCTAssertTrue(vm.ais[0].spoken.hasPrefix("Claude (build-box · work): "))
    }
}
