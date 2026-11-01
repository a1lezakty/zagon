import Foundation
import Testing
@testable import ZagonCore

/// Whose limits the rings show when readings come from this machine and from servers (two accounts): the export says
/// the server's host and `[limits] account`, the store keeps each source's newest reading in `meta`.
@Suite struct LimitSourceTests {
    func reading(_ pct: Double, at ts: Timestamp, resets: Timestamp, window: String = "five_hour") -> LimitSnapshot {
        LimitSnapshot(tool: .claude, window: window, usedPct: pct, resetsAt: resets, windowMinutes: 300, ts: ts)
    }

    func limitLines(_ s: Store, account: String? = nil) throws -> [JValue] {
        var out: [JValue] = []
        try Export.run(store: s, since: 0, account: account) { if let v = JValue.parse($0), v["type"] == "limit" { out.append(v) } }
        return out
    }

    func meta(_ s: Store, _ key: String) throws -> Double? {
        try s.db.one("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.optReal(0) } ?? nil
    }

    @Test func theExportCarriesHostAndAccountAndLeavesAnUnsetAccountOut() throws {
        let s = try Store(path: ":memory:")
        try s.addLimitSnapshot(reading(40, at: T0, resets: T0 + 4 * hour))
        let set = try #require(try limitLines(s, account: "work").first)
        #expect(set["host"]?.string == s.host && !s.host.isEmpty)
        #expect(set["account"]?.string == "work")
        let unset = try #require(try limitLines(s).first)
        #expect(unset["host"]?.string == s.host && unset["account"] == nil)
    }

    @Test func eachSourceKeepsOnlyItsNewestReadingInMeta() throws {
        let s = try Store(path: ":memory:")
        try s.addLimitSnapshot(reading(40, at: T0, resets: T0 + 4 * hour))
        try s.addLimitSnapshot(reading(30, at: T0 - hour, resets: T0 + 4 * hour))  // a late older one
        try s.addLimitSnapshot(reading(20, at: T0 + minute, resets: T0 + 4 * hour), source: "build-box")
        #expect(try meta(s, "limit_src:claude:five_hour:") == T0)
        #expect(try meta(s, "limit_src:claude:five_hour:build-box") == T0 + minute)
    }

    @Test func anImportWithoutHostOrAccountStillWorks() throws {
        let mac = try Store(path: ":memory:")
        // A 0.1.4 server's lines.
        let lines = ["{\"type\":\"export\",\"schema\":7,\"since\":0,\"seq\":3}",
                     "{\"type\":\"limit\",\"tool\":\"claude\",\"window\":\"five_hour\",\"used_pct\":25,\"resets_at\":\(T0 + 3 * hour),"
                        + "\"window_minutes\":300,\"ts\":\(T0)}"]
        try ExportImport(store: mac, source: "build-box").apply(lines)
        #expect(try mac.latestLimits().map(\.usedPct) == [25])
        #expect(try Query(store: mac).limitSources(now: T0 + minute)
                == [LimitSource(tool: .claude, window: "five_hour", source: "build-box", account: nil, several: false)])
    }

    @Test func twoSourcesAreLabelledWithTheAccountOfTheReadingShown() throws {
        let server = try Store(path: ":memory:"), mac = try Store(path: ":memory:")
        // This Mac (account "work"): 5-hour window resetting at +2 h; the server (account "personal"): a later period.
        try mac.addLimitSnapshot(reading(60, at: T0, resets: T0 + 2 * hour))
        try server.addLimitSnapshot(reading(15, at: T0 + minute, resets: T0 + 4 * hour))
        var lines: [String] = []
        try Export.run(store: server, since: 0, account: "personal") { lines.append($0) }
        try ExportImport(store: mac, source: "build-box").apply(lines)
        let q = Query(store: mac)
        #expect(try q.limitSources(now: T0 + 2 * minute, localAccount: "work")
                == [LimitSource(tool: .claude, window: "five_hour", source: "build-box", account: "personal", several: true)])

        // This Mac's window resets later now: its reading is shown. Its newest one is a lower re-send of the same
        // period: the period, not the exact reading, names the source.
        try mac.addLimitSnapshot(reading(5, at: T0 + 3 * minute, resets: T0 + 5 * hour))
        try mac.addLimitSnapshot(reading(3, at: T0 + 4 * minute, resets: T0 + 5 * hour))
        #expect(try q.limitSources(now: T0 + 5 * minute, localAccount: "work")
                == [LimitSource(tool: .claude, window: "five_hour", source: "", account: "work", several: true)])

        // Nine days on the server has read nothing since: one source left, no label needed.
        try mac.addLimitSnapshot(reading(10, at: T0 + 9 * 86400, resets: T0 + 9 * 86400 + 4 * hour))
        #expect(try q.limitSources(now: T0 + 9 * 86400 + minute, localAccount: "work")
                == [LimitSource(tool: .claude, window: "five_hour", source: "", account: "work", several: false)])

        #expect(try mac.db.one("SELECT value FROM meta WHERE key = 'limit_account:build-box'") { $0.text(0) } == "personal")
        // A later export without the account (the server's config changed) drops it.
        lines = []
        try Export.run(store: server, since: 0) { lines.append($0) }
        try ExportImport(store: mac, source: "build-box").apply(lines)
        #expect(try mac.db.one("SELECT value FROM meta WHERE key = 'limit_account:build-box'") { $0.text(0) } == nil)
    }
}
