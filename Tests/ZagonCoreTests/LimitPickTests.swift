import Foundation
import Testing
@testable import ZagonCore

/// Which reading counts as the current one: `ts` is when a reading was written, and a status line left open re-sends
/// its last reading with a fresh time.
@Suite struct LimitPickTests {
    let resets = T0 + 4 * hour

    func add(_ s: Store, _ pct: Double, at ts: Timestamp, resets: Timestamp? = nil) throws {
        try s.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: pct, resetsAt: resets ?? self.resets,
                                             windowMinutes: 300, ts: ts))
    }

    func five(_ s: Store, now: Timestamp) throws -> LimitReading? {
        try Query(store: s).limits(now: now).first { $0.tool == .claude && $0.window == "five_hour" }
    }

    @Test func anIdleSessionReSendingAnOldPercentWithAFreshTimeDoesNotWin() throws {
        let s = try Store(path: ":memory:")
        // The working session: 10 → 14 %; an idle one keeps re-sending the 8 % it saw an hour ago.
        try add(s, 8, at: T0 - hour)
        try add(s, 10, at: T0); try add(s, 12, at: T0 + minute); try add(s, 14, at: T0 + 2 * minute)
        try add(s, 8, at: T0 + 3 * minute); try add(s, 8, at: T0 + 4 * minute)
        let r = try #require(try five(s, now: T0 + 5 * minute))
        #expect(r.usedPct == 14 && r.ts == T0 + 2 * minute)
        #expect(try s.latestLimits().map(\.usedPct) == [14])
        // The export sends the same reading.
        var lines: [String] = []
        try Export.run(store: s, since: 0) { lines.append($0) }
        #expect(lines.filter { $0.contains("\"type\":\"limit\"") }.map { JValue.parse($0)?["used_pct"]?.double } == [14])
        // The same percent re-sent later is the newest of equals: still current then.
        try add(s, 14, at: T0 + 6 * minute)
        #expect(try five(s, now: T0 + 7 * minute)?.ts == T0 + 6 * minute)
    }

    @Test func aNewerWindowPeriodWinsAndAReadingOfAnEndedOneIsIgnored() throws {
        let s = try Store(path: ":memory:")
        try add(s, 90, at: T0, resets: T0 + minute)
        try add(s, 3, at: T0 + 2 * minute, resets: T0 + 5 * hour)
        // Codex reset times drift by seconds between readings of one period.
        try add(s, 4, at: T0 + 3 * minute, resets: T0 + 5 * hour - 7)
        // A late report of the period that has already reset, written last (seen in Codex rollouts).
        try add(s, 76, at: T0 + 4 * minute, resets: T0 + minute)
        var r = try #require(try five(s, now: T0 + 5 * minute))
        #expect(r.usedPct == 4 && r.ts == T0 + 3 * minute)
        // A reading without a reset time does not hide newer ones of a known period...
        try s.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: 50, windowMinutes: 300, ts: T0 + 5 * minute))
        try add(s, 5, at: T0 + 6 * minute, resets: T0 + 5 * hour)
        r = try #require(try five(s, now: T0 + 7 * minute))
        #expect(r.usedPct == 5)
        // ...and is current once newer than that period's end; its pace starts within the last hour only.
        try s.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: 1, windowMinutes: 300, ts: T0 + 6 * hour))
        try s.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: 2, windowMinutes: 300,
                                             ts: T0 + 6 * hour + 20 * minute))
        r = try #require(try five(s, now: T0 + 6 * hour + 20 * minute))
        #expect(r.usedPct == 2 && abs((r.pctPerHour ?? 0) - 3) < 1e-9)  // from 1 %, not from the 50 % hours before
    }

    /// A pace starts from the usage at its first reading, not from that reading when it is an older one re-sent.
    @Test func paceIgnoresAnOldReadingReSentAtItsStart() throws {
        let s = try Store(path: ":memory:"), resets = T0 + 150 * minute
        try add(s, 65, at: T0 - 4000, resets: resets)
        try add(s, 40, at: T0 - 3000, resets: resets)  // re-sent by an idle session
        try add(s, 70, at: T0, resets: resets)
        let r = try #require(try five(s, now: T0))
        #expect(abs((r.pctPerHour ?? 0) - 6) < 1e-9)  // (70 - 65) over 50 minutes, not (70 - 40)
        let base = try #require(try Store.paceBase(s.db, s.latestLimits()[0], from: T0 - 3600, to: T0 - 900))
        #expect(base.pct == 65 && base.ts == T0 - 3000)
        // Alerts take the same start: at 6 %/h the 30 % left last past the reset in 2.5 hours (from the re-sent 40 %
        // it would be 36 %/h, out in 50 minutes).
        let n = Notifier(store: s, config: NotifyConfig(), channels: [])
        #expect(try n.forecast(s.latestLimits()[0]) == nil)
    }

    /// Readings of one window as (offset in minutes from 10:00 local on 20.10, percent, reset in hours from 10:00).
    func store(_ window: String, _ rows: [(Double, Double, Double)]) throws -> Store {
        let s = try Store(path: ":memory:"), at = Time.localMidnight(2026, 10, 20) + 10 * hour
        for (m, pct, r) in rows {
            try s.addLimitSnapshot(LimitSnapshot(tool: .claude, window: window, usedPct: pct, resetsAt: at + r * hour,
                                                 windowMinutes: window == "five_hour" ? 300 : 10080, ts: at + m * minute))
        }
        return s
    }

    /// Task shares of the weekly limit add up its growth: an idle session re-sending an older percent between the
    /// working one's readings is no drop and rise again.
    @Test func limitGrowthCountsAReSentOlderPercentOnce() throws {
        let at = Time.localMidnight(2026, 10, 20) + 10 * hour
        // 20 % before the range; in it: re-sent 12, 22, re-sent 12, 24, re-sent 12, 25 (+5); the reset at 11:30; then 3,
        // a late 12 of the ended week, 5 (+5).
        let s = try store("seven_day", [(-60, 20, 1.5), (10, 12, 1.5), (20, 22, 1.5), (30, 12, 1.5), (40, 24, 1.5), (50, 12, 1.5),
                                        (60, 25, 1.5), (95, 3, 169.5), (100, 12, 1.5), (110, 5, 169.5)])
        let g = try TaskTime.limitGrowth(s.db, tool: "claude", window: "seven_day", from: at, to: at + 2 * hour)
        #expect(g == 10)  // the old sum of rises: 10 + 12 + 13 + 9 = 44
    }

    /// The Day screen: a re-sent lower reading neither ends a stretch at 100 % nor becomes the week's percent at the end of
    /// the day; the Week screen's percent per day likewise.
    @Test func dayAndWeekUseTheUsageNotTheLastReading() throws {
        let at = Time.localMidnight(2026, 10, 20) + 10 * hour
        let five = try store("five_hour", [(0, 100, 2), (10, 97, 2), (20, 100, 2), (180, 4, 7)])
        let q = Query(store: five)
        #expect(try q.limitHits(from: at - hour, to: at + 5 * hour) == [Interval(at, at + 2 * hour)])  // old: 2 stretches

        let week = try Query(store: store("seven_day", [(-900, 29, 50), (0, 30, 50), (10, 33, 50), (20, 28, 50)]))
        let d = try week.day("2026-10-20")
        #expect(d.weekPctStart == 30 && d.weekPctEnd == 33)  // old: 30 and 28
        #expect(try week.week(from: "2026-10-19").limitByDay[1] == 33)
    }
}
