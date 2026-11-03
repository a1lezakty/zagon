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

/// The first record of a fork's transcript.
func forkMark(_ t: Timestamp, session: String = "S") -> String {
    #"{"type":"history-suppression","sessionId":"\#(session)","cause":"fork_inherit","ts":"\#(iso(t))"}"#
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
        #expect(parse([forkMark(T0)]).background == [BackgroundTask(sessionId: "claude:S", id: "", ts: T0, until: nil)])
        #expect(parse([forkMark(T0).replacingOccurrences(of: "fork_inherit", with: "restored_owner_mismatch")]).background.isEmpty)
    }

    /// A fork copies the history with its launches but without their ends: only its own launches count.
    @Test func aForkDoesNotInheritTheTasks() {
        let env = ClaudeEnv()
        env.write("-w-alpha/F.jsonl", lines: [forkMark(T0 + 100, session: "F"), bgBash(T0 + 10, "b1", session: "F"),
                                              typed(T0 + 110, session: "F"), bgBash(T0 + 120, "b2", session: "F")])
        env.scan()
        #expect(Background.count(open(env, "F"), now: T0 + 200) == 1 && open(env, "F")?.hasPrefix("b2@") == true)
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
        // An ended task counts for the grace period more.
        #expect(Background.count(open(env), now: T0 + 50) == 2 && Background.count(open(env), now: T0 + 40 + 121) == 1)
        // Past the cap it stops counting; the next record drops it.
        #expect(Background.count(open(env), now: T0 + 20 + UserTime.driverIdle + 1) == 0)
        env.append("-w-alpha/S.jsonl", bgDone(T0 + 50, "b2", status: "failed") + "\n")
        env.scan()
        #expect(Background.count(open(env), now: T0 + 50 + 121) == 0)
        #expect(try (env.store.db.one("SELECT bg_until FROM session WHERE id = 'claude:S'") { $0.optReal(0) } ?? nil) == T0 + 50 + 120)
        // Ended tasks go with the next task record after their grace.
        env.append("-w-alpha/S.jsonl", bgBash(T0 + 10 * minute, "b3") + "\n")
        env.scan()
        #expect(open(env)?.hasPrefix("b3@") == true && Background.count(open(env), now: T0 + 11 * minute) == 1)
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

    /// The hook of the new process read before the transcript of the old one (`zagon notify`, a spool-only batch).
    @Test func theRestartHoldsWhenTheHookIsReadFirst() throws {
        let env = ClaudeEnv()
        var res = SpoolIngest.Result()
        let line = #"{"kind":"hook","tool":"claude","event":"SessionStart","source":"resume","session_id":"S","ts":\#(T0 + 50)}"#
        try SpoolIngest.apply(Array(line.utf8), store: env.store, into: &res)
        env.write("-w-alpha/S.jsonl", lines: [typed(T0), bgBash(T0 + 10, "b1"), bgBash(T0 + 100, "b2")])
        env.scan()
        #expect(Background.count(open(env), now: T0 + 200) == 1 && open(env)?.hasPrefix("b2@") == true)
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
        #expect(Background.count(open(env), now: T0 + 40) == 2 && Background.count(open(env), now: T0 + 200) == 1)
        #expect(try tokens() == before && before == 15)
    }

    /// A session whose turn ended with a task in the background works; a driven one without is neutral.
    @Test func readSideWorkingInBackgroundAndDriven() throws {
        let env = ClaudeEnv(), now = T0 + 40 * minute
        env.write("-w-alpha/S.jsonl", lines: [typed(T0), assistantLine(T0 + 5, id: "s1", output: 1), bgBash(T0 + 10, "b1")])
        env.scan()
        try env.store.setStatus(sessionId: "claude:S", tool: .claude, status: "waiting_input", at: T0 + minute)
        try env.store.mergeSession(SessionMeta(id: "claude:L", tool: .claude, title: "lead"))
        try env.store.setStatus(sessionId: "claude:L", tool: .claude, status: "working", at: T0 + 39 * minute)
        env.write("-w-beta/W.jsonl", lines: [typed(T0, session: "W", cwd: "/w/beta"),
                                             assistantLine(T0 + 5, id: "w1", output: 1, session: "W", cwd: "/w/beta")])
        env.scan()
        try env.store.mergeSession(SessionMeta(id: "claude:W", tool: .claude, title: "worker"))
        try env.store.db.run("UPDATE session SET driver = 'claude:L' WHERE id = 'claude:W'")
        try env.store.setStatus(sessionId: "claude:W", tool: .claude, status: "waiting_input", at: T0 + 35 * minute)

        let live = try Query(store: env.store).liveSessions(now: now)
        let s = try #require(live.first { $0.id == "claude:S" })
        #expect(s.state == .working && s.background == 1 && s.since == T0 + minute)  // past idleAfter: still working
        #expect(live.first { $0.id == "claude:W" }?.background == 0)
        let lines = try Reports(store: env.store).sessions(from: T0 - hour, to: T0 + hour, now: now)
        let ls = try #require(lines.first { $0.id == "claude:S" }), lw = try #require(lines.first { $0.id == "claude:W" })
        #expect(ls.background == 1 && lw.background == nil && !ReportTools.waiting(ls) && !ReportTools.waiting(lw))
        // CLI and MCP lines.
        #expect(ls.turnState(now: now) == "working in background (1 task) · 39m")
        #expect(lw.turnState(now: now) == "driven by lead · turn ended 5m ago")

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        Sys.writeFile(dir + "/token", Array("1:x\n".utf8))
        Sys.writeFile(dir + "/curl", [0], mode: 0o755)
        var c = NotifyConfig()
        c.telegramTokenFile = dir + "/token"; c.telegramChatId = "1"
        let bot = Bot(telegram: try #require(Telegram(c, curl: Curl(searchPath: dir), tmpDir: dir)), store: env.store, lang: .en)
        let text = try bot.sessions(now: now)
        #expect(text.contains("▶ working in background · 39 min · alpha"))
        #expect(text.contains("· driven by lead · turn ended 5 min ago · "))
        #expect(!text.contains("waits"))
        bot.lang = .ru
        let ru = try bot.sessions(now: now)
        #expect(ru.contains("▶ работает в фоне · 39 мин") && ru.contains("под управлением lead · ход окончен 5 мин назад"))

        var nc = NotifyConfig(); nc.quiet = nil; nc.summaryAt = nil; nc.worklogAt = nil; nc.waitingMinutes = 5
        let n = Notifier(store: env.store, config: nc, channels: [])
        // While its task runs the wait is `waiting_background_minutes` (60), not 5.
        #expect(try n.waitingEvents(now: now).isEmpty)
        #expect(try n.waitingEvents(now: T0 + 62 * minute).map(\.key) == ["wait:claude:S"])
        // The task ended (and its grace passed): the usual wait.
        env.append("-w-alpha/S.jsonl", bgDone(T0 + 20 * minute, "b1") + "\n")
        env.scan()
        #expect(try n.waitingEvents(now: now).map(\.key) == ["wait:claude:S"])
        // The agent took up the notification (the transcript moved past the stop before its hooks): no alert.
        env.append("-w-alpha/S.jsonl", toolResult(T0 + 20 * minute + 4) + "\n")
        env.scan()
        #expect(try n.waitingEvents(now: now).isEmpty)
    }
}
