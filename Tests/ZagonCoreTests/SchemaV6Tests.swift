import Foundation
import Testing
@testable import ZagonCore

@Suite struct SchemaV6Tests {
    /// The leader L drives the worker W over tmux: every message of W is L's; the leader's own one is the human's.
    func driven() -> ClaudeEnv {
        let env = ClaudeEnv()
        env.write("-w-alpha/W.jsonl", lines: [
            typed(T0 + 1, session: "W"), assistantLine(T0 + minute, id: "w1", output: 1, session: "W"),
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
        #expect(live.first { $0.id == "claude:W" }?.drivenBy == "lead" && live.first { $0.id == "claude:L" }?.drivenBy == nil)
        let s = try Reports(store: env.store).sessions(from: T0 - hour, to: T0 + hour)
        #expect(s.first { $0.id == "claude:W" }?.drivenBy == "lead" && s.first { $0.id == "claude:L" }?.drivenBy == nil)
        func by() throws -> String? { try Query(store: env.store).liveSessions(now: T0 + 23 * minute).first { $0.id == "claude:W" }?.drivenBy }
        // An untitled driver goes by its project; one that ended leaves the worker waiting for you.
        try env.store.db.run("UPDATE session SET title = NULL WHERE id = 'claude:L'")
        #expect(try by() == "root")
        try env.store.setStatus(sessionId: "claude:L", tool: .claude, status: "ended", at: T0 + 22 * minute + 1)
        #expect(try by() == nil)

        // You answer the worker yourself: it waits for you again.
        env.append("-w-alpha/W.jsonl", typed(T0 + 30 * minute, session: "W") + "\n")
        env.scan()
        #expect(driver(env, "W") == nil)
    }

    /// Counts the user actions again, as after an upgrade (names are read then).
    func recount(_ env: ClaudeEnv) throws {
        try env.store.db.exec("UPDATE meta SET value = '3' WHERE key = 'day_rules'")
        env.scan()
    }

    @Test func aSessionYouTypeInIsNotHiddenByALooseRelay() throws {
        let env = driven()
        // H (unnamed) has your message, then one typed 5 s after L sent keys to some pane (`-t %3`).
        env.write("-w-beta/H.jsonl", lines: [
            typed(T0 + 2 * minute, session: "H", cwd: "/w/beta"), assistantLine(T0 + 3 * minute, id: "h1", output: 1, session: "H", cwd: "/w/beta"),
            typed(T0 + 40 * minute + 5, session: "H", cwd: "/w/beta"), assistantLine(T0 + 41 * minute, id: "h2", output: 1, session: "H", cwd: "/w/beta")])
        env.append("-w-root/L.jsonl", assistantLine(T0 + 40 * minute, id: "l3", tools: [("toolu_3", "Bash")],
                                                    command: "tmux send-keys -t %3 'ok' Enter", session: "L", cwd: "/w/root") + "\n")
        env.scan()
        #expect(driver(env, "H") == nil && driver(env, "W") == "claude:L")
        #expect(env.int("SELECT user_msgs FROM session WHERE id = 'claude:H'") == 1)  // the loose match still is not yours

        // A named session with your messages: only a relay aimed at exactly its name makes it driven.
        try env.store.db.run("UPDATE session SET title = 'beta-web', title_rank = 99 WHERE id = 'claude:H'")
        env.append("-w-root/L.jsonl", assistantLine(T0 + 50 * minute, id: "l4", tools: [("toolu_4", "Bash")],
                                                    command: "tmux send-keys -t beta 'go' Enter", session: "L", cwd: "/w/root") + "\n")
        env.append("-w-beta/H.jsonl", typed(T0 + 50 * minute + 3, session: "H", cwd: "/w/beta") + "\n")
        try recount(env)
        #expect(driver(env, "H") == nil)  // `beta` is only a prefix of its name
        env.append("-w-root/L.jsonl", assistantLine(T0 + 60 * minute, id: "l5", tools: [("toolu_5", "Bash")],
                                                    command: "tmux send-keys -t beta-web 'go' Enter", session: "L", cwd: "/w/root") + "\n")
        env.append("-w-beta/H.jsonl", typed(T0 + 60 * minute + 3, session: "H", cwd: "/w/beta") + "\n")
        env.scan()
        #expect(driver(env, "H") == "claude:L")
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
