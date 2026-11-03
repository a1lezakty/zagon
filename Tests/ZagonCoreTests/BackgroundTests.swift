import Foundation
import Testing
@testable import ZagonCore

// Background tasks of a Claude session from its transcript (anonymized shapes of Claude Code 2.1 records).

func bgLaunch(_ t: Timestamp, _ result: String, session: String = "S") -> String {
    userLine(t, content: #"[{"tool_use_id":"toolu_9","type":"tool_result","content":"started"}]"#,
             extra: #","toolUseResult":\#(result)"#, session: session)
}
func bgBash(_ t: Timestamp, _ id: String, session: String = "S") -> String {
    bgLaunch(t, #"{"stdout":"","stderr":"","interrupted":false,"isImage":false,"backgroundTaskId":"\#(id)"}"#, session: session)
}
func bgAgent(_ t: Timestamp, _ id: String) -> String {
    bgLaunch(t, #"{"isAsync":true,"status":"async_launched","agentId":"\#(id)","description":"x","prompt":"y"}"#)
}
func bgMonitor(_ t: Timestamp, _ id: String, persistent: Bool, timeoutMs: Int) -> String {
    bgLaunch(t, #"{"taskId":"\#(id)","timeoutMs":\#(timeoutMs),"persistent":\#(persistent)}"#)
}
func bgStop(_ t: Timestamp, _ id: String) -> String {
    bgLaunch(t, #"{"message":"stopped","task_id":"\#(id)","task_type":"local_bash","command":"sleep 1"}"#)
}
/// A task notification queued for the agent; `status` nil = a monitor event.
func bgDone(_ t: Timestamp, _ id: String, status: String? = "completed", session: String = "S") -> String {
    let body = "<task-notification>\n<task-id>\(id)</task-id>\n<tool-use-id>toolu_9</tool-use-id>\n"
        + (status.map { "<status>\($0)</status>\n" } ?? "<event>line</event>\n") + "<summary>done</summary>\n</task-notification>"
    return #"{"type":"queue-operation","operation":"enqueue","timestamp":"\#(iso(t))","sessionId":"\#(session)","content":\#(js(body))}"#
}

@Suite struct BackgroundTests {
    @Test func launchesAndEndsFromTheTranscript() {
        let out = parse([bgBash(T0, "b1"), bgAgent(T0 + 1, "a1"), bgMonitor(T0 + 2, "m1", persistent: false, timeoutMs: 600_000),
                         bgMonitor(T0 + 3, "m2", persistent: true, timeoutMs: 3_600_000), toolResult(T0 + 4),
                         bgDone(T0 + 5, "b1"), bgDone(T0 + 6, "m2", status: nil), bgDone(T0 + 7, "a1", status: "killed"),
                         bgStop(T0 + 8, "m2")])
        #expect(out.badLines == 0)
        let cap = UserTime.driverIdle
        #expect(out.background == [
            BackgroundTask(sessionId: "claude:S", id: "b1", ts: T0, until: T0 + cap),
            BackgroundTask(sessionId: "claude:S", id: "a1", ts: T0 + 1, until: T0 + 1 + cap),
            BackgroundTask(sessionId: "claude:S", id: "m1", ts: T0 + 2, until: T0 + 2 + 600),
            BackgroundTask(sessionId: "claude:S", id: "m2", ts: T0 + 3, until: T0 + 3 + cap),
            BackgroundTask(sessionId: "claude:S", id: "b1", ts: T0 + 5, until: nil),
            BackgroundTask(sessionId: "claude:S", id: "a1", ts: T0 + 7, until: nil),
            BackgroundTask(sessionId: "claude:S", id: "m2", ts: T0 + 8, until: nil)])
        // The fallback decoder reads the same (a spaced line), and a sub-agent's tasks are not the session's.
        #expect(parse([bgBash(T0, "b1").replacingOccurrences(of: #"{"parentUuid""#, with: #"{ "parentUuid""#)]).background.count == 1)
        #expect(parse([bgBash(T0, "b1"), bgDone(T0 + 1, "b1")], agent: "agent-x").background.isEmpty)
    }

    func open(_ env: ClaudeEnv, _ s: String = "S") -> String? {
        try! env.store.db.one("SELECT bg_tasks FROM session WHERE id = ?", [.text("claude:" + s)]) { $0.text(0) } ?? nil
    }

    @Test func ingestKeepsTheOpenOnesAcrossPasses() throws {
        let env = ClaudeEnv()
        env.write("-w-alpha/S.jsonl", lines: [typed(T0), bgBash(T0 + 10, "b1"), bgBash(T0 + 20, "b2")])
        env.scan()
        #expect(Background.count(open(env), now: T0 + 30) == 2)
        env.append("-w-alpha/S.jsonl", bgDone(T0 + 40, "b1") + "\n")
        env.scan()
        #expect(Background.count(open(env), now: T0 + 50) == 1 && open(env)?.hasPrefix("b2@") == true)
        // Past the cap it stops counting; the next record drops it.
        #expect(Background.count(open(env), now: T0 + 20 + UserTime.driverIdle + 1) == 0)
        env.append("-w-alpha/S.jsonl", bgDone(T0 + 50, "b2", status: "failed") + "\n")
        env.scan()
        #expect(open(env) == nil)
        #expect(try (env.store.db.one("SELECT bg_until FROM session WHERE id = 'claude:S'") { $0.optReal(0) } ?? nil) == nil)
    }

    @Test func aNewProcessDropsTheTasksOfTheOldOne() throws {
        let env = ClaudeEnv()
        env.write("-w-alpha/S.jsonl", lines: [typed(T0), bgBash(T0 + 10, "b1"), bgBash(T0 + 100, "b2")])
        env.scan()
        var res = SpoolIngest.Result()
        let line = #"{"kind":"hook","tool":"claude","event":"SessionStart","source":"resume","session_id":"S","ts":\#(T0 + 50)}"#
        try SpoolIngest.apply(Array(line.utf8), store: env.store, into: &res)
        #expect(Background.count(open(env), now: T0 + 200) == 1 && open(env)?.hasPrefix("b2@") == true)
        let compact = #"{"kind":"hook","tool":"claude","event":"SessionStart","source":"compact","session_id":"S","ts":\#(T0 + 300)}"#
        try SpoolIngest.apply(Array(compact.utf8), store: env.store, into: &res)
        #expect(Background.count(open(env), now: T0 + 400) == 1)
    }

    /// The v9 upgrade: files already read past their launches are recounted once; tokens stay as they were.
    @Test func theUpgradeRecountFindsTasksLaunchedBefore() throws {
        let env = ClaudeEnv()
        env.write("-w-alpha/S.jsonl", lines: [typed(T0), assistantLine(T0 + 5, id: "m1", input: 10, output: 5),
                                              bgBash(T0 + 10, "b1"), bgBash(T0 + 20, "b2"), bgDone(T0 + 30, "b1")])
        env.scan()
        func tokens() throws -> Int { try env.store.db.one("SELECT sum(input + output) FROM usage_hour") { $0.int(0) } ?? 0 }
        let before = try tokens()
        try env.store.db.run("UPDATE session SET bg_tasks = NULL, bg_until = NULL")  // as a 0.1.6 store has it
        for st in Schema.v9.split(separator: ";") where st.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("UPDATE") {
            try env.store.db.exec(String(st))
        }
        env.scan()
        #expect(open(env)?.hasPrefix("b2@") == true && Background.count(open(env), now: T0 + 40) == 1)
        #expect(try tokens() == before && before == 15)
    }
}
