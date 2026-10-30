import Foundation
import Testing
@testable import ZagonCore

@Suite struct StoreTests {
    @Test func migratesToCurrentVersion() throws {
        let s = try Store(path: ":memory:")
        #expect(s.userVersion == Store.schemaVersion)
        try s.mergeSession(SessionMeta(id: "claude:x", tool: .claude, title: "a", titleRank: TitleRank.aiTitle))
        try s.mergeSession(SessionMeta(id: "claude:x", tool: .claude, title: "b", titleRank: TitleRank.none))
        #expect(try s.db.one("SELECT title FROM session") { $0.text(0) } == "a")
        try s.mergeSession(SessionMeta(id: "claude:x", tool: .claude, title: "c", titleRank: TitleRank.customTitle))
        #expect(try s.db.one("SELECT title FROM session") { $0.text(0) } == "c")
    }

    @Test func refusesNewerSchema() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/z.db"
        _ = try Store(path: path)
        // Without meta.host an open that went on would write it.
        try SQLite(path: path).exec("DELETE FROM meta WHERE key='host'; PRAGMA user_version=\(Store.schemaVersion + 1)")
        #expect(throws: StoreError.self) { try Store(path: path) }
        #expect(try SQLite(path: path).one("SELECT count(*) FROM meta WHERE key='host'") { $0.int(0) } == 0)
    }
}
