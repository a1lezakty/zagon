import Foundation
import Testing
@testable import ZagonCore

/// export → ExportImport into an empty store must give the same days, agents, tools and intervals; incremental
/// exports applied on top (also twice) must not double anything.
@Suite struct ExportRoundTripTests {
    static let fixtures = Bundle.module.resourcePath! + "/Fixtures"

    func export(_ s: Store, since: Int) throws -> [String] {
        var out: [String] = []
        try Export.run(store: s, since: since) { out.append($0) }
        return out
    }

    /// Everything the Day screen shows, in a comparable form.
    func picture(_ s: Store) throws -> String {
        var parts: [String] = []
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var days: [String] = []
        try s.db.query("SELECT DISTINCT day FROM day_agg ORDER BY day") { days.append($0.text(0) ?? "") }
        for d in days {
            var r = try Reports(store: s).day(d)
            r.sessions.sort { $0.id < $1.id }
            parts.append(String(decoding: try e.encode(r), as: UTF8.self))
        }
        try s.db.query("""
            SELECT session_id, agent, model, sum(input), sum(output), sum(cache_read), sum(cache_write), sum(requests), sum(tool_calls)
            FROM usage_hour GROUP BY 1, 2, 3 ORDER BY 1, 2, 3
            """) { r in parts.append("agent \((0..<9).map { r.text(Int32($0)) ?? "" }.joined(separator: " "))") }
        try s.db.query("SELECT session_id, hour, name, sum(n) FROM tool_use GROUP BY 1, 2, 3 ORDER BY 1, 2, 3") { r in
            parts.append("tool \(r.text(0) ?? "") \(r.int(1)) \(r.text(2) ?? "") \(r.int(3))")
        }
        var spans: [String: [Interval]] = [:]
        try s.db.query("SELECT session_id, kind, start, \"end\" FROM activity") {
            spans["\($0.text(0) ?? "") \($0.text(1) ?? "")", default: []].append(Interval($0.real(2), $0.real(3)))
        }
        // Your time: user_activity at the source, imported as activity kind 'user'.
        try s.db.query("SELECT start, \"end\" FROM user_activity") { spans[" user", default: []].append(Interval($0.real(0), $0.real(1))) }
        for (k, xs) in spans.sorted(by: { $0.key < $1.key }) {
            parts.append("spans \(k) " + Intervals.merge(xs).map { "\($0.start)-\($0.end)" }.joined(separator: ","))
        }
        for l in try s.latestLimits() { parts.append("limit \(l) ") }  // export carries the latest reading per window
        return parts.joined(separator: "\n")
    }

    /// `zoneChange`: the zone id changes before the second scan (`zagon tz`, or another test setting `TZ` for the whole
    /// process), so the server rebuilds every day; a day left empty must still reach the client.
    @Test(arguments: [false, true]) func roundTripAndIncrementalWithoutDoubling(zoneChange: Bool) throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fm = FileManager.default
        try fm.copyItem(atPath: Self.fixtures + "/claude", toPath: dir + "/claude")
        try fm.copyItem(atPath: Self.fixtures + "/codex/home", toPath: dir + "/codex")
        let src = try Store(path: ":memory:")
        var o = IngestOptions(); o.host = "server"
        let ingest = Ingest(store: src, sources: [ClaudeSource.spec(root: dir + "/claude")] + CodexSource.specs(codexHome: dir + "/codex"),
                            options: o)
        try ingest.scan()
        let claude = "claude:a19cca56-ae2e-443b-aa60-d6fae7caee25"
        let paths = ZagonPaths(home: dir, dir: dir + "/zagon")
        func hook(_ event: String, _ ts: Double) {
            HookSpool.append(HookSpool.hookLine(tool: "claude", event: event,
                                                payload: Array("{\"session_id\":\"a19cca56-ae2e-443b-aa60-d6fae7caee25\"}".utf8), ts: ts)!,
                             paths: paths, ts: ts)
        }
        let t0 = try #require(try src.db.one("SELECT last_at FROM session WHERE id = ?", [.text(claude)]) { $0.optReal(0) } ?? nil)
        hook("PermissionRequest", t0 + 60); hook("PostToolUse", t0 + 200)
        try SpoolIngest.run(store: src, spoolDir: paths.spool, now: t0 + 300)
        try src.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: 41, resetsAt: t0 + 9000, windowMinutes: 300, ts: t0))

        let full = try export(src, since: 0)
        #expect(full.contains { $0.contains("\"type\":\"activity\"") && $0.contains("\"kind\":\"waiting\"") })
        #expect(full.contains { $0.contains("\"type\":\"day\"") && $0.contains("\"usage\":[{") && $0.contains("\"tools\":[{") })
        let dst = try Store(path: ":memory:")
        let imp = try ExportImport(store: dst, source: "server")
        try imp.apply(full)
        let want = try picture(src)
        #expect(want.contains("agent \(claude) agent-") && want.contains("spans  user"))  // sub-agents and your time present
        #expect(try picture(dst) == want)
        try imp.apply(full)  // the same export again
        #expect(try picture(dst) == want)

        // Changes: a sub-agent file truncated (its contribution retracted), a new session on another day, a new wait.
        let agent = try #require(Ingest.walk(dir + "/claude").first { $0.contains("/subagents/") })
        try "".write(toFile: dir + "/claude/" + agent, atomically: false, encoding: .utf8)
        try fm.createDirectory(atPath: dir + "/claude/-home-user-project-2", withIntermediateDirectories: true)
        let ts = "2026-10-29T09:00:00.000Z", ts2 = "2026-10-29T09:20:00.000Z"
        try """
            {"type":"user","timestamp":"\(ts)","sessionId":"s2","cwd":"/home/user/project-2","message":{"role":"user","content":"Do the thing"}}
            {"type":"assistant","timestamp":"\(ts2)","sessionId":"s2","cwd":"/home/user/project-2","message":{"id":"msg_s2","model":"claude-opus-4","role":"assistant","content":[{"type":"tool_use","id":"toolu_s2","name":"Bash","input":{"command":"true"}}],"usage":{"input_tokens":11,"output_tokens":7,"cache_read_input_tokens":100}}}

            """.write(toFile: dir + "/claude/-home-user-project-2/s2.jsonl", atomically: false, encoding: .utf8)
        if zoneChange { try ingest.checkTimezone("TZ=Elsewhere/Zone") }
        try ingest.scan()
        hook("PermissionRequest", t0 + 400); hook("Stop", t0 + 500)
        try SpoolIngest.run(store: src, spoolDir: paths.spool, now: t0 + 600)

        let delta = try export(src, since: imp.seq)
        #expect(delta.count < full.count)
        try imp.apply(delta)
        let want2 = try picture(src)
        #expect(want2 != want)
        #expect(try picture(dst) == want2)
        try imp.apply(delta)
        #expect(try picture(dst) == want2)
        // Nothing new since: header and limits only.
        #expect(Set(try export(src, since: imp.seq).compactMap { JValue.parse($0)?["type"]?.string }) == ["export", "limit"])
    }
}
