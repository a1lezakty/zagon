import Foundation
import Testing
@testable import ZagonCore

/// Fixtures/claude: per project folder one main transcript and one of its sub-agents of one Claude Code version, real
/// structure with all text replaced (scripts/sanitize.py, bulky record types the parser ignores left out). The
/// expected numbers are computed here straight from the JSON, without the byte scanner or Ingest.
@Suite struct ClaudeFixtureTests {
    static let root = Bundle.module.resourcePath! + "/Fixtures/claude"
    /// Project folder -> the Claude Code versions its records carry (the newest one is what Zagon is tested with).
    static let versions = ["-home-user-project-1": ["2.1.233", "2.1.250"], "-home-user-project-2": ["2.1.316"]]

    struct Expected {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, requests = 0, tools = Set<String>(), typed = 0
        var title: String?, titleRank = 0, cwd: String?, session = "", versions = Set<String>(), noUsage = 0
    }

    static func expected(_ project: String) throws -> Expected {
        var e = Expected()
        var last: [String: [String: Any]] = [:]   // message id -> usage of its last record
        var owner: [String: String] = [:]         // message id -> first file that had it
        let files = Ingest.walk(root).filter { $0.hasPrefix(project + "/") && ClaudeSource.layout($0) != nil }.sorted()
        #expect(files.count == 2)
        e.session = "claude:" + (ClaudeSource.layout(files[0])?.session ?? "")
        for rel in files {
            let isSub = rel.contains("/subagents/")
            let text = try String(contentsOfFile: root + "/" + rel, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let m = o["message"] as? [String: Any]
                if let v = o["version"] as? String { e.versions.insert(v) }
                if !isSub, ["assistant", "user"].contains(o["type"] as? String), e.cwd == nil, let c = o["cwd"] as? String { e.cwd = c }  // where it started
                switch o["type"] as? String {
                case "assistant":
                    if m?["usage"] == nil { e.noUsage += 1 }
                    if let id = m?["id"] as? String, let u = m?["usage"] as? [String: Any] {
                        if owner[id, default: rel] == rel { owner[id] = rel; last[id] = u }
                    }
                    for b in m?["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "tool_use" {
                        e.tools.insert(b["id"] as! String)
                    }
                case "user" where !isSub:
                    if ["isMeta", "isCompactSummary", "isVisibleInTranscriptOnly", "isSidechain"].contains(where: { o[$0] as? Bool == true }) { continue }
                    if let origin = o["turnOrigin"] as? String, origin != "human" { continue }
                    var t = m?["content"] as? String
                    if let blocks = m?["content"] as? [[String: Any]] {
                        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) || blocks.isEmpty { continue }
                        t = blocks.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
                    }
                    guard let t else { continue }
                    if o["turnOrigin"] == nil, ["<task-notification", "<local-command-stdout", "<local-command-caveat",
                                                "<system-reminder", "<channel"].contains(where: { t.hasPrefix($0) }) { continue }
                    e.typed += 1
                case "custom-title" where !isSub, "agent-name" where !isSub, "ai-title" where !isSub:
                    let title = (o["customTitle"] ?? o["agentName"] ?? o["aiTitle"]) as? String
                    let rank = o["customTitle"] != nil ? TitleRank.customTitle : o["agentName"] != nil ? TitleRank.agentName : TitleRank.aiTitle
                    if let title, !title.isEmpty, rank >= e.titleRank { e.title = title; e.titleRank = rank }
                default: break
                }
            }
        }
        for u in last.values {
            e.input += u["input_tokens"] as? Int ?? 0; e.output += u["output_tokens"] as? Int ?? 0
            e.cacheRead += u["cache_read_input_tokens"] as? Int ?? 0; e.cacheWrite += u["cache_creation_input_tokens"] as? Int ?? 0
        }
        e.requests = last.count
        return e
    }

    @Test(arguments: versions.keys.sorted()) func ingestMatchesIndependentCount(project: String) throws {
        let e = try Self.expected(project)
        #expect(e.versions == Set(Self.versions[project] ?? []))
        #expect(e.requests > 20 && e.tools.count > 20 && e.typed > 0 && e.title != nil)  // the fixture is not trivial
        let env = ClaudeEnv()
        try FileManager.default.copyItem(atPath: Self.root + "/" + project, toPath: env.root + "/" + project)
        let st = env.scan()
        #expect(st.badLines == 0 && st.filesRead == 2 && st.noUsage == e.noUsage && e.noUsage == 0)
        let row = try env.store.db.one("""
            SELECT sum(input), sum(output), sum(cache_read), sum(cache_write), sum(requests), count(DISTINCT session_id),
                   count(DISTINCT agent) FROM usage_hour
            """) { r in (0..<7).map { r.int(Int32($0)) } }
        #expect(row == [e.input, e.output, e.cacheRead, e.cacheWrite, e.requests, 1, 2])
        #expect(env.toolCalls() == e.tools.count)
        let session = try env.store.db.one("SELECT id, user_msgs, title, title_rank, cwd, project FROM session") { r in
            [r.text(0), "\(r.int(1))", r.text(2), "\(r.int(3))", r.text(4), r.text(5)]
        }
        #expect(session == [e.session, "\(e.typed)", e.title, "\(e.titleRank)", e.cwd,
                            e.cwd.map { ClaudeParser.project($0) }])
        // Day aggregates add up to the same totals, and a second scan changes nothing.
        let days = try env.store.db.one("SELECT sum(input), sum(output), sum(requests), sum(tool_calls) FROM day_agg WHERE tool='' AND project='' AND model=''") {
            [$0.int(0), $0.int(1), $0.int(2), $0.int(3)]
        }
        #expect(days == [e.input, e.output, e.requests, e.tools.count])
        #expect(env.scan().filesRead == 0 && env.tokens() == (e.input, e.output, e.requests))
    }
}
