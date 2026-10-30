import Testing
@testable import ZagonCore

/// Day D = 2026-10-20 (T0 = D 10:00 UTC), with one session on D-1 and one on D-8 (the week before).
@Suite struct ReportTests {
    static let opus = "claude-opus-4-1", haiku = "claude-haiku-4-5"
    let day = 86400.0

    func dataset() -> ClaudeEnv {
        let env = ClaudeEnv(), m = minute, opus = Self.opus
        env.write("-w-alpha/S1.jsonl", lines: [
            typed(T0, session: "S1"),
            assistantLine(T0 + 5 * m, id: "m1", model: opus, input: 100, output: 50, cacheRead: 1000, cacheWrite: 200,
                          tools: [("toolu_1", "Bash")], session: "S1"),
            toolResult(T0 + 6 * m, session: "S1"),
            assistantLine(T0 + 10 * m, id: "m2", model: Self.haiku, input: 10, output: 5,
                          tools: [("toolu_2", "Read"), ("toolu_3", "Bash")], session: "S1"),
            typed(T0 + 20 * m, session: "S1"),
            #"{"type":"custom-title","customTitle":"Fix login","sessionId":"S1"}"#,
        ])
        env.write("-w-beta/S2.jsonl", lines: [
            typed(T0 + 3 * hour, session: "S2", cwd: "/w/beta"),
            assistantLine(T0 + 3 * hour + 30 * m, id: "m3", model: opus, input: 1, output: 2, cacheRead: 3, cacheWrite: 4,
                          session: "S2", cwd: "/w/beta"),
        ])
        env.write("-w-alpha/S3.jsonl", lines: [
            typed(T0 - day, session: "S3"),
            assistantLine(T0 - day + 20 * m, id: "m4", model: opus, input: 1000, session: "S3"),
        ])
        env.write("-w-alpha/S4.jsonl", lines: [
            typed(T0 - 8 * day, session: "S4"),
            assistantLine(T0 - 8 * day + 10 * m, id: "m5", model: opus, input: 7, session: "S4"),
        ])
        env.scan()
        return env
    }

    @Test func dayReport() throws {
        let env = dataset()
        let r = try Reports(store: env.store).day(Time.dayString(T0))
        #expect(r.day == "2026-10-20")
        #expect([r.tokens.input, r.tokens.output, r.tokens.cacheRead, r.tokens.cacheWrite, r.tokens.requests, r.tokens.total]
                == [111, 57, 1003, 204, 3, 1375])
        #expect(r.toolCalls == 3)
        #expect(r.sessionSec == 600 + 1800)
        #expect(r.userSec == 1200)  // 10:00, read 10:10, 10:20
        #expect(r.models.map(\.model) == [Self.opus, Self.haiku])
        #expect(r.models.map(\.tokens.total) == [1360, 15] && r.models.map(\.tokens.requests) == [2, 1])
        #expect(r.projects.map(\.project) == ["alpha", "beta"] && r.projects.map(\.tool) == ["claude", "claude"])
        #expect(r.projects.map(\.tokens.total) == [1365, 10])
        #expect(r.projects.map(\.sessionSec) == [600, 1800] && r.projects.map(\.toolCalls) == [3, 0])
        #expect(r.tools.map { "\($0.name)=\($0.count)" } == ["Bash=2", "Read=1"])
        let start = Time.dayBounds(r.day)!.start
        var hours = Array(repeating: 0, count: 24)
        hours[Int((Double(Time.hour(T0)) - start) / 3600)] = 1365
        hours[Int((Double(Time.hour(T0 + 3 * hour)) - start) / 3600)] = 10
        #expect(r.hours == hours)

        #expect(r.sessions.map(\.id) == ["claude:S1", "claude:S2"])
        let s1 = r.sessions[0]
        #expect(s1.title == "Fix login" && s1.project == "alpha" && s1.gitBranch == "main" && s1.model == Self.haiku)
        #expect(s1.tokens.total == 1365 && s1.workingSec == 600 && s1.userMsgs == 2)
        #expect(s1.startedAt == T0 && s1.lastAt == T0 + 20 * minute && s1.archived == nil && s1.tool == "claude")
        #expect(r.sessions[1].tokens.total == 10 && r.sessions[1].workingSec == 1800)

        #expect(try Reports(store: env.store).day("2026-10-20", withSessions: false).sessions.isEmpty)
        let empty = try Reports(store: env.store).day("2026-10-21")
        #expect(empty.tokens.total == 0 && empty.sessionSec == 0 && empty.projects.isEmpty && empty.sessions.isEmpty)
    }

    @Test func weekReport() throws {
        let env = dataset()
        let w = try Reports(store: env.store).week(ending: "2026-10-20")
        #expect(w.from == "2026-10-14" && w.to == "2026-10-20")
        #expect(w.days.map(\.day) == ["2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20"])
        #expect(w.days.map(\.tokens.total) == [0, 0, 0, 0, 0, 1000, 1375])
        #expect(w.days.map(\.sessionSec) == [0, 0, 0, 0, 0, 1200, 2400])
        #expect(w.tokens.total == 2375 && w.tokens.input == 1111 && w.tokens.requests == 4)
        #expect(w.sessionSec == 3600 && w.userSec == 1200)
        #expect(w.previous.total == 7 && w.previous.requests == 1 && w.previousSessionSec == 600 && w.previousUserSec == 0)
        #expect(w.projects.map(\.project) == ["alpha", "beta"])
        #expect(w.projects.map(\.tokens.total) == [2365, 10] && w.projects.map(\.sessionSec) == [1800, 1800])
        #expect(w.projects.map(\.toolCalls) == [3, 0])
    }

    @Test func sessionLists() throws {
        let env = dataset()
        let reports = Reports(store: env.store)
        // Live list: by last activity, whole-history tokens.
        let live = try reports.sessions()
        #expect(live.map(\.id) == ["claude:S2", "claude:S1", "claude:S3", "claude:S4"])
        #expect(live.map(\.tokens.total) == [10, 1365, 1000, 7] && live.map(\.workingSec) == [1800, 600, 1200, 600])
        #expect(try reports.sessions(limit: 2).map(\.id) == ["claude:S2", "claude:S1"])
        // A range: only sessions with tokens or working time inside it. Working time is clipped to the range;
        // tokens go by UTC hour bucket (the 10:00 bucket starts before T0 + 5 min and is left out).
        let (s, _) = Time.dayBounds("2026-10-19")!
        let before = try reports.sessions(from: s, to: T0)
        #expect(before.map(\.id) == ["claude:S3"] && before.map(\.tokens.total) == [1000] && before.map(\.workingSec) == [1200])
        let range = try reports.sessions(from: T0 + 5 * minute, to: T0 + 3 * hour + 10 * minute)
        #expect(range.map(\.id) == ["claude:S2", "claude:S1"])
        #expect(range.map(\.tokens.total) == [10, 0] && range.map(\.workingSec) == [600, 300])
    }
}
