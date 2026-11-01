import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// Cursor's agent in the app: a third AI with sessions and time, no rings.
final class CursorUITests: XCTestCase {
    func testSessionsCommandAndDayNote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-cursor-\(UUID().uuidString)").path
        let paths = ZagonPaths(home: dir, dir: dir + "/z")
        let t = 1778004000.0  // 2026-05-05 18:00 UTC
        try FileManager.default.createDirectory(atPath: paths.spool, withIntermediateDirectories: true)
        // Lines as `zagon hook` writes them for Cursor (HookSpool.cursorLine).
        let lines = [("UserPromptSubmit", t), ("PostToolUse", t + 60), ("Stop", t + 120), ("UserPromptSubmit", t + 200)].map {
            #"{"kind":"hook","tool":"cursor","event":"\#($0.0)","ts":\#($0.1),"session_id":"c-9","cwd":"/w/app","model":"gpt-5"}"#
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: paths.spool + "/" + Sys.utcDay(t) + ".cursor.ndjson",
                                                         atomically: false, encoding: .utf8)
        let store = try Store(path: dir + "/z.db")
        try Ingest(store: store, sources: CursorSource.specs(paths: paths, root: dir + "/none")).scan()
        try SpoolIngest.run(store: store, spoolDir: paths.spool, now: t + 210)

        let now = Date(timeIntervalSince1970: t + 210), utc = TimeZone(identifier: "UTC")!
        let p = StoreDataProvider(store: store, writer: store, now: now, host: "laptop")
        p.refresh { _ in }
        p.writeQueue.sync {}  // the first refresh makes it ready
        let s = try XCTUnwrap(p.liveSessions().first)
        XCTAssertEqual(s.tool, .cursor)
        XCTAssertEqual(s.command, "cursor '/w/app'")
        XCTAssertEqual(p.command(tool: "cursor", id: "c-9", cwd: "/w/app", host: "build-box"),
                       "cursor --remote ssh-remote+build-box '/w/app'")
        XCTAssertEqual(p.command(tool: "cursor", id: "c-9", cwd: nil, host: nil), "cursor")

        let f = Fmt(lang: .en, timeZone: utc, now: now)
        let main = MainVM(p, f)
        XCTAssertEqual(main.working.map(\.subtitle), ["laptop · Cursor · GPT-5"])
        XCTAssertTrue(main.ais.isEmpty)
        XCTAssertEqual(Limits()[.cursor].week == nil, true)
        XCTAssertFalse(Tool.withLimits.contains(.cursor))

        let day = DayVM(p.day(now), f)
        XCTAssertGreaterThanOrEqual(p.day(now).cursorSec, 120)
        XCTAssertTrue(day.limitNotes.contains { $0.text.hasPrefix("Cursor ") && $0.text.contains("approximate") },
                      "\(day.limitNotes.map(\.text))")
    }
}
