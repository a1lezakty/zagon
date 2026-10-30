import Foundation
import Testing
@testable import ZagonCore

/// A store built by a real scan of the synthetic Claude fixtures (`Fixtures/scenario/generate.py`) plus their hook and
/// status-line spool. "Now" of the scenario: 2026-10-30 11:42 UTC.
enum QueryFixture {
    static let now: Timestamp = 1_793_360_520

    /// Scans a copy of the fixtures (spool retention would delete old files in place). Days are UTC: the test process
    /// starts in UTC (Tests/CTestZone).
    static func store(root: String = Bundle.module.resourcePath! + "/Fixtures/scenario") throws -> Store {
        let dir = tempDir()
        try FileManager.default.copyItem(atPath: root, toPath: dir + "/claude")
        let store = try Store(path: ":memory:")
        var o = IngestOptions()
        o.host = "laptop"
        try Ingest(store: store, sources: [ClaudeSource.spec(root: dir + "/claude/projects")], options: o).scan()
        try SpoolIngest.run(store: store, spoolDir: dir + "/claude/spool", now: now)
        try? FileManager.default.removeItem(atPath: dir)
        return store
    }
}

@Suite(.serialized) struct QueryTests {
    let q: Query
    init() throws { q = Query(store: try QueryFixture.store()) }

    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Timestamp { Time.localMidnight(2026, 10, day) + Double(h * 3600 + m * 60) }

    @Test func limitsAndPace() throws {
        let l = try q.limits(now: QueryFixture.now)
        let five = try #require(l.first { $0.window == "five_hour" })
        #expect(abs(five.usedPct - 61.6) < 0.01)
        #expect(five.resetsAt == at(30, 14, 20))
        #expect(abs((five.pctPerHour ?? 0) - 18) < 0.5)
        // 20 minutes after the last reading the rate is stale: no forecast.
        #expect(try q.limits(now: QueryFixture.now + 1200).first { $0.window == "five_hour" }?.pctPerHour == nil)
        let week = try #require(l.first { $0.window == "seven_day" })
        #expect(week.usedPct == 41 && week.resetsAt == at(33, 9))
    }

    @Test func liveSessions() throws {
        let live = try q.liveSessions(now: QueryFixture.now)
        func titles(_ s: LiveState) -> [String] { live.filter { $0.state == s }.compactMap(\.title) }
        #expect(titles(.waitingPermission) == ["demo video"])
        #expect(titles(.waitingInput) == ["PROJ-12"])
        #expect(Set(titles(.working)) == ["mockups", "run 300", "parser"])
        #expect(Set(titles(.idle)) == ["worker", "shell aliases"])
        let video = try #require(live.first { $0.title == "demo video" })
        #expect(video.since == at(30, 11, 30) && video.host == "laptop" && video.cwd == "/work/web-app")
        #expect(video.model == "claude-opus-5-5" && !video.nativeId.contains(":"))
        #expect(try q.hosts() == ["laptop"])
    }

    @Test func overtakenWaits() throws {
        let store = try QueryFixture.store()
        let q = Query(store: store)
        // "demo video" asks for permission since 11:30; Esc at 11:40 writes an interrupt line but fires no hook.
        let id = try #require(q.liveSessions(now: QueryFixture.now).first { $0.title == "demo video" }?.id)
        try store.db.run("UPDATE session SET last_at = ? WHERE id = ?", [.real(at(30, 11, 40)), .text(id)])
        #expect(try q.liveSessions(now: QueryFixture.now).first { $0.id == id }?.state == .working)
        // A permission request nobody answered for over 30 minutes is idle.
        try store.db.run("UPDATE session SET last_at = status_at WHERE id = ?", [.text(id)])
        #expect(try q.liveSessions(now: QueryFixture.now).first { $0.id == id }?.state == .waitingPermission)
        #expect(try q.liveSessions(now: QueryFixture.now + 3600).first { $0.id == id }?.state == .idle)
    }

    @Test func day() throws {
        let d = try q.day("2026-10-29")
        #expect(d.lanes.count == 7)
        #expect(d.lanes.first?.project == "tracker")
        let api = try #require(d.lanes.first { $0.title == "PROJ-12" })
        #expect(api.intervals.filter(\.waiting).map { [$0.start, $0.end] }
                == [[at(29, 11, 30), at(29, 12, 10)], [at(29, 16), at(29, 16, 30)]])
        let work = api.intervals.filter { !$0.waiting }
        #expect(work.first?.start == at(29, 9) && work.last?.end == at(29, 18, 30))
        #expect(d.limitHits == [Interval(at(29, 13, 40), at(29, 14, 20))])
        #expect(d.weekPctStart == 24 && d.weekPctEnd == 37)
        #expect(d.byProject.count == 6 && d.byProject.reduce(0) { $0 + $1.tokens } == d.tokens.total)
        #expect(Set(d.byModel.map(\.name)) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"])
        #expect(Set(d.byAgent.map(\.name)) == ["", "agent-a7f3"])
        #expect(d.byHost.map(\.name) == ["laptop"])
        #expect(d.byTool.reduce(0) { $0 + $1.count } > 0)
        #expect(abs(d.cost - d.byProject.reduce(0) { $0 + $1.cost }) < 1e-6 && d.cost > 0)
        #expect(d.sessionSec > 30 * 3600)
        #expect(d.userSec > 0)
        #expect(d.summary == nil)
    }

    @Test func weekAndMonth() throws {
        let w = try q.week(from: "2026-10-26")
        #expect(w.days.first == "2026-10-26" && w.days.last == "2026-11-01")
        #expect(w.projects[0].map(\.project) == ["ml-train", "api-server", "dotfiles"])
        #expect(w.projects[5].isEmpty && w.projects[6].isEmpty)
        #expect(w.limitByDay[3] == 37 && w.limitByDay[4] == 41 && w.limitByDay[0] == nil)
        #expect(w.totals.sessionSec > w.previous.sessionSec && w.previousSec["api-server"] ?? 0 > 0)
        let h = try q.hours(from: "2026-10-01", count: 31)
        #expect(abs(h[0] - 6.5) < 0.05 && h[3] == 0 && h[30] == 0)
    }

    /// Days read from the raw tables equal `day_agg` when cut in the scan's zone; cut elsewhere (5:30 later) the days
    /// change and the whole stays.
    @Test func daysInAnyZone() throws {
        let days = (0..<45).map { Time.addDays("2026-09-20", $0)! }
        let r = q.reports
        var total = (tokens: 0, session: 0.0, user: 0.0)
        for day in days {
            let a = try r.day(day, withSessions: false), b = try q.day(day, detail: false)
            #expect(a.tokens.total == b.tokens.total && abs(a.sessionSec - b.sessionSec) < 1e-6 && abs(a.userSec - b.userSec) < 1e-6)
            total.tokens += b.tokens.total; total.session += b.sessionSec; total.user += b.userSec
        }
        #expect(total.tokens > 0 && total.session > 0 && total.user > 0)
        let shifted: DayBounds = { Time.dayBounds($0).map { ($0.0 + 5.5 * 3600, $0.1 + 5.5 * 3600) } }
        var moved = (tokens: 0, session: 0.0, user: 0.0), changed = false
        for day in days {
            let b = try q.day(day, detail: false, bounds: shifted), a = try q.day(day, detail: false)
            moved.tokens += b.tokens.total; moved.session += b.sessionSec; moved.user += b.userSec
            changed = changed || a.tokens.total != b.tokens.total || abs(a.sessionSec - b.sessionSec) > 1
        }
        #expect(changed)
        #expect(moved.tokens == total.tokens && abs(moved.session - total.session) < 1e-3 && abs(moved.user - total.user) < 1e-3)
        let h = try q.hours(from: "2026-09-20", count: 45, bounds: shifted)
        #expect(abs(h.reduce(0, +) * 3600 - total.session) < 1e-3)
    }

    /// Your time on two machines at once counts once: a server's imported stretch over the same minutes adds nothing.
    @Test func yourTimeIsOneUnion() throws {
        let store = try QueryFixture.store()
        let q = Query(store: store)
        let before = try q.day("2026-10-29", detail: false).userSec
        var first: (Double, Double)?
        try store.db.query("SELECT start, \"end\" FROM user_activity WHERE start >= ? ORDER BY start LIMIT 1",
                           [.real(Time.localMidnight(2026, 10, 29))]) { first = ($0.real(0), $0.real(1)) }
        let (s, e) = try #require(first)
        try store.db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(99, '', ?, ?, 'user')", [.real(s), .real(e)])
        #expect(abs(try q.day("2026-10-29", detail: false).userSec - before) < 1e-6)
        let night = Time.localMidnight(2026, 10, 29) + 60
        try store.db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(99, '', ?, ?, 'user')",
                         [.real(night), .real(night + 600)])
        #expect(abs(try q.day("2026-10-29", detail: false).userSec - before - 600) < 1e-6)
    }

    @Test func limitHitCarriedOver() throws {
        // The 100 % stretch began at 13:40; a range from 14:00 starts inside it and ends at the 14:20 reset.
        #expect(try q.limitHits(from: at(29, 14), to: at(30, 0)).map { [$0.start, $0.end] } == [[at(29, 14), at(29, 14, 20)]])
    }

    @Test func search() throws {
        #expect(Set(try q.search("demo video").compactMap(\.title)) == ["demo video", "main"])
        #expect(try q.search("gpu box").map(\.title) == ["run 300"])
        // "--" can't be indexed: it is left out of the message search instead of breaking it.
        #expect(try q.search("gpu --").map(\.title) == ["run 300"])
        #expect(try q.search("\"%_").isEmpty)
        #expect(try q.search(" ").isEmpty)
    }

    @Test func workDayAndSessionWork() throws {
        let w = try q.workDay("2026-10-29")
        #expect(w.work.count > 0)
        #expect(w.sessionSec > 0)
        let id = try #require(q.liveSessions(now: QueryFixture.now).first { $0.title == "run 300" }?.id)
        let s = try #require(try q.sessionWork(id))
        #expect(s.project == "ml-train" && s.workingSec > 7 * 3600 && s.tokens > 0)
    }

    @Test func pricing() {
        func io(_ m: String) -> [Double]? { Pricing.rates(m).map { [$0.input, $0.output, $0.cacheRead] } }
        // By model, not by family: Opus 4 / 4.1 cost three times Opus 4.5+, Haiku 3.5 less than Haiku 4.5.
        #expect(io("claude-opus-4-20250514") == [15, 75, 1.5] && io("claude-opus-4-1-20250805") == [15, 75, 1.5])
        #expect(io("claude-opus-4-5-20251101") == [5, 25, 0.5] && io("claude-opus-5-5") == [4, 20, 0.2])
        #expect(io("claude-sonnet-4-5-20250929") == [3, 15, 0.3] && io("claude-sonnet-5") == [2, 10, 0.2])
        #expect(io("claude-3-5-haiku-20241022") == [0.8, 4, 0.08] && io("claude-haiku-4-5-20251001") == [1, 5, 0.1])
        #expect(io("claude-fable-5-1") == [10, 50, 0.25])
        #expect(io("gpt-5") == [1.25, 10, 0.125] && io("gpt-5-mini-2025-08-07") == [0.25, 2, 0.025])
        #expect(io("gpt-5-nano") == [0.05, 0.4, 0.005] && io("gpt-5-codex") == [1.25, 10, 0.125])
        #expect(io("codex-mini-latest") == [1.5, 6, 0.375] && io("gpt-5.3-codex") == [1.75, 14, 0.175])
        // Cloud ids and suffixes find the same row.
        for m in ["us.anthropic.claude-opus-4-1-20250805-v1:0", "claude-opus-4-1@20250805", "Claude-Opus-4-1[1m]"] {
            #expect(io(m) == [15, 75, 1.5], "\(m)")
        }
        // Anthropic cache writes: 1.25x input for 5 minutes, 2x for an hour.
        #expect(Pricing.rates("claude-opus-5-5").map { [$0.cacheWrite, $0.cacheWrite1h] } == [5, 8])
        #expect(Pricing.cost(model: "claude-opus-5-5", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0) == 4)
        // Unknown: no rates, $0 in `cost`, all its tokens unpriced.
        for m in ["unknown", "codex-auto-review", "claude-opus-9", "gpt-5.6"] { #expect(Pricing.rates(m) == nil, "\(m)") }
        #expect(Pricing.cost(model: "unknown", input: 1_000_000, output: 1, cacheRead: 1, cacheWrite: 1) == 0)
        var t = TokenTotals(); t.input = 3; t.output = 4
        #expect(Pricing.unpriced(model: "unknown", t) == 7 && Pricing.unpriced(model: "gpt-5.4", t) == 0)
    }
}
