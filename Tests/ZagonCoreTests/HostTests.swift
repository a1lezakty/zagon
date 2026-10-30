import Foundation
import Testing
@testable import ZagonCore

@Suite struct HostTests {
    @Test func hostIsPinnedAtTheFirstOpen() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let first = try Store(path: dir + "/z.db")
        #expect(first.host == Ingest.hostName())
        // The machine got another name since (X.local -> X-2.local): the database keeps the first one.
        try first.db.run("UPDATE meta SET value = 'X.local' WHERE key = 'host'")
        let again = try Store(path: dir + "/z.db")
        #expect(again.host == "X.local")
        #expect(Ingest(store: again, sources: []).host == "X.local")
    }

    @Test func databaseFromBeforePinningKeepsItsHost() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try Store(path: dir + "/z.db")
        try s.db.run("DELETE FROM meta WHERE key = 'host'")
        for (id, host) in [("claude:a", "old"), ("claude:b", "old"), ("claude:c", "other")] {
            try s.db.run("INSERT INTO session(id, tool, host) VALUES(?, 'claude', ?)", [.text(id), .text(host)])
        }
        #expect(try Store(path: dir + "/z.db").host == "old")
    }

    @Test func rowsOfAnotherHostStayOutOfTheLocalDay() throws {
        let env = ClaudeEnv()  // host "test"
        let db = env.store.db, h = Int64(Time.hour(T0))
        // Imported from a server: its session, usage, tool calls, working time and user actions.
        try db.run("INSERT INTO session(id, tool, host, project) VALUES('claude:SRV', 'claude', 'server', 'api-server')")
        try db.run("INSERT INTO usage_hour(file_id, session_id, agent, hour, model, input, requests) VALUES(0, 'claude:SRV', '', ?, 'm', 1000, 1)", [.int(h)])
        try db.run("INSERT INTO tool_use(file_id, session_id, hour, name, n) VALUES(0, 'claude:SRV', ?, 'Bash', 5)", [.int(h)])
        try db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(0, 'claude:SRV', ?, ?, 'working')",
                   [.real(T0 + 2 * hour), .real(T0 + 3 * hour)])
        for t in [T0 + 2 * hour, T0 + 2 * hour + 5 * minute] {
            try db.run("INSERT INTO user_action(file_id, session_id, ts, kind) VALUES(0, 'claude:SRV', ?, 'msg')", [.real(t)])
        }
        // Local work the same day.
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1", input: 10, output: 1),
                                    typed(T0 + 10 * minute), assistantLine(T0 + 11 * minute, id: "m2", input: 20, output: 2)])
        env.scan()
        let day = Time.dayString(T0)
        let total = try db.one("""
            SELECT input, requests, tool_calls, session_sec, user_sec FROM day_agg
            WHERE day = ? AND host = 'test' AND tool = '' AND project = '' AND model = ''
            """, [.text(day)]) { ($0.int(0), $0.int(1), $0.int(2), $0.real(3), $0.real(4)) }
        #expect(total?.0 == 30 && total?.1 == 2 && total?.2 == 0)
        #expect(total?.3 == 2 * minute)   // two one-minute turns, not the server's hour
        #expect(total?.4 == 10 * minute)  // typed, read, typed; the server's actions are not counted here
        #expect(env.int("SELECT count(*) FROM day_agg WHERE host <> 'test'") == 0)
    }
}
