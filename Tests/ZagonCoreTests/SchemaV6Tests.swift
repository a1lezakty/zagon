import Foundation
import Testing
@testable import ZagonCore

@Suite struct SchemaV6Tests {
    /// The leader L drives the worker W over tmux; W's last message is L's, the leader's own last one is the human's.
    func driven() -> ClaudeEnv {
        let env = ClaudeEnv()
        env.write("-w-alpha/W.jsonl", lines: [
            typed(T0 + 1, session: "W"), assistantLine(T0 + minute, id: "w1", output: 1, session: "W"),
            typed(T0 + 5 * minute, session: "W"), assistantLine(T0 + 6 * minute, id: "w2", output: 1, session: "W"),
            typed(T0 + 20 * minute + 1, session: "W"), assistantLine(T0 + 21 * minute, id: "w3", output: 1, session: "W")])
        env.write("-w-root/L.jsonl", lines: [
            typed(T0 - minute, session: "L", cwd: "/w/root"),
            assistantLine(T0, id: "l1", tools: [("toolu_1", "Bash")], command: "tmux send-keys -t w 'read the brief' Enter",
                          session: "L", cwd: "/w/root"),
            assistantLine(T0 + 20 * minute, id: "l2", tools: [("toolu_2", "Bash")], command: "tmux send-keys -t w 'go on' Enter",
                          session: "L", cwd: "/w/root")])
        env.scan()
        try! env.store.db.run("UPDATE session SET title = 'lead', title_rank = 99 WHERE id = 'claude:L'")
        return env
    }

    func driver(_ env: ClaudeEnv, _ s: String) -> String? {
        try! env.store.db.one("SELECT driver FROM session WHERE id = ?", [.text("claude:" + s)]) { $0.text(0) } ?? nil
    }

    @Test func aWorkerWhoseLastMessageAnotherSessionTypedIsDrivenByIt() throws {
        let env = driven()
        #expect(driver(env, "W") == "claude:L" && driver(env, "L") == nil)
        try env.store.setStatus(sessionId: "claude:W", tool: .claude, status: "waiting_input", at: T0 + 22 * minute)
        try env.store.setStatus(sessionId: "claude:L", tool: .claude, status: "waiting_input", at: T0 + 22 * minute)
        let live = try Query(store: env.store).liveSessions(now: T0 + 23 * minute)
        #expect(live.first { $0.id == "claude:W" }?.driver == "lead" && live.first { $0.id == "claude:L" }?.driver == nil)
        let s = try Reports(store: env.store).sessions(from: T0 - hour, to: T0 + hour)
        #expect(s.first { $0.id == "claude:W" }?.driver == "lead" && s.first { $0.id == "claude:L" }?.driver == nil)
        // Untitled driver: another session.
        try env.store.db.run("UPDATE session SET title = NULL WHERE id = 'claude:L'")
        #expect(try Query(store: env.store).liveSessions(now: T0 + 23 * minute).first { $0.id == "claude:W" }?.driver == "")

        // You answer the worker yourself: it waits for you again.
        env.append("-w-alpha/W.jsonl", typed(T0 + 30 * minute, session: "W") + "\n")
        env.scan()
        #expect(driver(env, "W") == nil)
    }

    @Test func theDriverTravelsWithTheExport() throws {
        let env = driven()
        var lines: [String] = []
        try Export.run(store: env.store, since: 0) { lines.append($0) }
        #expect(lines.contains { $0.contains(#""driver":"claude:L""#) })
        let dst = try Store(path: ":memory:")
        try ExportImport(store: dst, source: "box").apply(lines)
        #expect(try dst.db.one("SELECT driver FROM session WHERE id = 'claude:W'") { $0.text(0) } == "claude:L")
        #expect(try dst.db.one("SELECT count(*) FROM session WHERE driver IS NOT NULL") { $0.int(0) } == 1)
    }

    @Test func aDatabaseFromV5GetsTheDriversOnItsNextScan() throws {
        let env = driven()
        // As v5 left it: no drivers, rules 3.
        try env.store.db.exec("UPDATE session SET driver = NULL; UPDATE meta SET value = '3' WHERE key = 'day_rules'")
        env.scan()
        #expect(driver(env, "W") == "claude:L")
    }
}
