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
}
