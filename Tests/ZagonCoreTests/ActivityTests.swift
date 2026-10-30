import Testing
@testable import ZagonCore

/// The day totals row of `day_agg`: (session_sec, user_sec).
func dayTotals(_ env: ClaudeEnv, _ ts: Timestamp) -> (session: Double, user: Double)? {
    try! env.store.db.one("SELECT session_sec, user_sec FROM day_agg WHERE day=? AND tool='' AND project='' AND model=''",
                          [.text(Time.dayString(ts))]) { ($0.real(0), $0.real(1)) }
}

@Suite struct IntervalTests {
    @Test func merge() {
        let m = Intervals.merge([Interval(5, 7), Interval(1, 3), Interval(3, 4), Interval(2, 2.5), Interval(8, 8), Interval(10, 9)])
        #expect(m == [Interval(1, 4), Interval(5, 7)])
        #expect(Intervals.merge([]) == [])
        #expect(Intervals.merge([Interval(0, 10), Interval(2, 3)]) == [Interval(0, 10)])
    }

    @Test func covered() {
        let xs = [Interval(1, 4), Interval(2, 6), Interval(10, 20)]
        #expect(Intervals.covered(xs, from: 3, to: 12) == 5)
        #expect(Intervals.covered(xs, from: 0, to: 100) == 15)
        #expect(Intervals.covered(xs, from: 6, to: 10) == 0)
    }

    @Test func chain() {
        #expect(Intervals.chain([100, 0, 5, 10, 40, 101], gap: 10) == [Interval(0, 10), Interval(100, 101)])
        #expect(Intervals.chain([0, 10, 20], gap: 10) == [Interval(0, 20)])  // a gap equal to the limit still chains
        #expect(Intervals.chain([0, 10.5], gap: 10) == [])
        #expect(Intervals.chain([], gap: 10) == [])
        #expect(Intervals.chain([3, 3, 3], gap: 0) == [])
    }

    @Test func turnBuilder() {
        var tb = TurnBuilder(), out = TurnBuilder.Output()
        let gap = 30 * minute, idle = 20 * minute
        tb.user("s", 0, idleGap: idle, into: &out)
        for t in [60.0, 10 * minute] { tb.agent("s", t, sessionGap: gap, into: &out) }
        tb.agent("s", 40 * minute + 1, sessionGap: gap, into: &out)  // silence longer than session_gap
        tb.agent("s", 50 * minute, sessionGap: gap, into: &out)
        #expect(out.closed.map { $0.interval } == [Interval(0, 10 * minute)])
        #expect(tb.open["s"] == Interval(40 * minute + 1, 50 * minute))
        // The reply comes 15 min after the answer ended: the end of the answer is a `read` action.
        tb.user("s", 65 * minute, idleGap: idle, into: &out)
        #expect(out.closed.map { $0.interval }.last == Interval(40 * minute + 1, 50 * minute))
        #expect(out.actions.map { "\($0.kind)@\(Int($0.ts / minute))" } == ["msg@0", "read@50", "msg@65"])
        // A copy of old history far before the open turn is not activity now.
        tb.user("s", 10 * minute, idleGap: idle, into: &out)
        tb.agent("s", 1 * minute, sessionGap: gap, into: &out)
        #expect(out.actions.count == 3 && tb.open["s"] == Interval(65 * minute, 65 * minute))
        // A reply later than idle_gap leaves no `read`.
        tb.agent("s", 66 * minute, sessionGap: gap, into: &out)
        tb.user("s", 90 * minute, idleGap: idle, into: &out)
        #expect(out.actions.map { $0.kind } == ["msg", "read", "msg", "msg"])
    }
}

@Suite struct WorkingTimeTests {
    @Test func parallelSubAgentsAreNotDoubleCounted() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1", tools: [("toolu_t", "Task")]),
                                    toolResult(T0 + 60 * minute, id: "toolu_t"), assistantLine(T0 + 60 * minute + 10, id: "m2")])
        for a in ["agent-a1", "agent-b2"] {
            let events = stride(from: 10.0, through: 50, by: 10).map { assistantLine(T0 + $0 * minute, id: "\(a)-\($0)") }
            env.write("-w-alpha/S/subagents/\(a).jsonl",
                      lines: [typed(T0 + minute, "part")] + events + [assistantLine(T0 + 60 * minute, id: "\(a)-end")])
        }
        env.scan()
        // The main file is silent while it waits (longer than session_gap): 10:00-10:01 and 11:00-11:00:10.
        // Each sub-agent: 10:01-11:00. Union per session: 10:00-11:00:10, not 70 s + 2 x 59 min.
        #expect(env.int("SELECT count(*) FROM activity") == 4)
        #expect(dayTotals(env, T0)?.session == 3610)
        #expect(env.real("SELECT session_sec FROM day_agg WHERE tool='claude' AND project='alpha' AND model=''") == 3610)
        #expect(try! Reports(store: env.store).sessions(from: T0 - hour, to: T0 + 2 * hour).map(\.workingSec) == [3610])
    }

    @Test func sessionGapEndsAnInterval() {
        func run(_ gap: Double?) -> Double? {
            let env = ClaudeEnv { if let gap { $0.sessionGap = gap } }
            env.write(mainFile, lines: [0.0, 20, 60, 70].map { assistantLine(T0 + $0 * minute, id: "m\($0)") })
            env.scan()
            return dayTotals(env, T0)?.session
        }
        #expect(run(nil) == 30 * minute)
        #expect(run(45 * minute) == 70 * minute)
    }

    @Test func channelMessageStartsATurn() {
        let env = ClaudeEnv()
        let channel = #","isMeta":true,"origin":{"kind":"channel"},"turnOrigin":"peer""#
        env.write(mainFile, lines: [typed(T0)] + [5.0, 10].map { assistantLine(T0 + $0 * minute, id: "a\($0)") }
                  + [userLine(T0 + 12 * minute, content: js("<channel source=\"t\">\nnext\n</channel>"), extra: channel)]
                  + [15.0, 20].map { assistantLine(T0 + $0 * minute, id: "b\($0)") })
        env.scan()
        var xs: [Interval] = []
        try! env.store.db.query("SELECT start, \"end\" FROM activity WHERE kind = 'working' ORDER BY start", []) {
            xs.append(Interval($0.real(0), $0.real(1)))
        }
        #expect(xs == [Interval(T0, T0 + 10 * minute), Interval(T0 + 12 * minute, T0 + 20 * minute)])
    }

    @Test func tailingExtendsTheOpenInterval() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1")])
        env.scan()
        #expect(dayTotals(env, T0)?.session == minute)
        env.append(mainFile, assistantLine(T0 + 10 * minute, id: "m2") + "\n")
        env.scan()
        #expect(dayTotals(env, T0)?.session == 10 * minute)
        #expect(env.int("SELECT count(*) FROM activity") == 1)
    }
}

@Suite struct UserTimeTests {
    /// Session A answers until 10:15, the reply comes at 10:30; session B runs inside the same stretch.
    func scenario(_ configure: (inout IngestOptions) -> Void = { _ in }) -> ClaudeEnv {
        let env = ClaudeEnv(configure)
        let m = minute
        env.write("-w-alpha/A.jsonl", lines: [
            typed(T0, session: "A"), assistantLine(T0 + m, id: "a1", session: "A"), assistantLine(T0 + 15 * m, id: "a2", session: "A"),
            typed(T0 + 30 * m, session: "A"), assistantLine(T0 + 31 * m, id: "a3", session: "A"),
            assistantLine(T0 + 32 * m, id: "a4", session: "A"),
            typed(T0 + 120 * m, session: "A"),
        ])
        env.write("-w-beta/B.jsonl", lines: [
            typed(T0 + 10 * m, session: "B", cwd: "/w/beta"), assistantLine(T0 + 11 * m, id: "b1", session: "B", cwd: "/w/beta"),
            typed(T0 + 25 * m, session: "B", cwd: "/w/beta"),
        ])
        env.scan()
        return env
    }

    @Test func actionsChainAcrossSessionsWithReads() {
        let env = scenario()
        #expect(env.int("SELECT count(*) FROM user_action WHERE kind='msg'") == 5)
        var reads: [Double] = []
        try! env.store.db.query("SELECT ts FROM user_action WHERE kind='read' ORDER BY ts") { reads.append(($0.real(0) - T0) / minute) }
        #expect(reads == [11, 15])
        // 10:00…10:30 as one stretch: the sessions overlap, they are not summed; 12:00 alone is no time.
        let t = dayTotals(env, T0)
        #expect(t?.user == 30 * minute)
        #expect(t?.session == (15 + 2 + 1) * minute)
        #expect(env.real("SELECT session_sec FROM day_agg WHERE project='beta' AND model=''") == minute)
        #expect(env.int("SELECT user_msgs FROM session WHERE id='claude:A'") == 3)
    }

    @Test func idleGapIsConfigurable() {
        let env = scenario { $0.idleGap = 10 * minute }
        #expect(env.int("SELECT count(*) FROM user_action WHERE kind='read'") == 0)
        // 10:00…10:10 and 10:25…10:30.
        #expect(dayTotals(env, T0)?.user == 15 * minute)
    }

    @Test func newActionsRebuildUserTime() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1")])
        env.scan()
        #expect(dayTotals(env, T0)?.user == 0)
        env.append(mainFile, typed(T0 + 5 * minute) + "\n")
        env.scan()
        #expect(dayTotals(env, T0)?.user == 5 * minute)
    }
}
