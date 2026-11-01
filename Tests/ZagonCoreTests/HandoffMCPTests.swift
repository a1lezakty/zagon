import Foundation
import Testing
@testable import ZagonCore

/// handoff_create / handoff_get / handoff_list and the resume prompt over JSON-RPC, with the real `HandoffTools` on
/// the synthetic transcripts of `MCPFixture` (session A: /work/p1, titled "Parser refactor"; session B: newer).
private struct HandoffRPC {
    let f: MCPFixture
    let server: MCPServer
    let paths: ZagonPaths
    let startedAt: Timestamp
    let a = "aaaaaaaa-1111-2222-3333-444444444444", b = "bbbbbbbb-1111-2222-3333-444444444444"

    /// `bAge`: seconds since B's log was written; `spool`: SessionStart hooks (session, seconds after server start, source);
    /// `pid`: the client pid recorded with a session's hook; `clientPid`: this server's client.
    init(bAge: Double = 1800, spool: [(String, Double, String)] = [], pid: [String: Int32] = [:],
         clientPid: Int32? = nil) throws {
        f = try MCPFixture()
        paths = ZagonPaths(home: f.dir, dir: f.dir + "/.zagon")
        let now = Date()
        startedAt = now.timeIntervalSince1970 - 600
        for (id, age) in [(h0a, 3600.0), (h0b, bAge)] { try Self.setAge(f.dir + "/claude/-work-p1/\(id).jsonl", age) }
        for (id, after, source) in spool {
            let payload = #"{"session_id":"\#(id)","cwd":"/work/p1","hook_event_name":"SessionStart","source":"\#(source)"}"#
            let ts = startedAt + after
            HookSpool.append(HookSpool.hookLine(tool: "claude", event: "SessionStart", payload: Array(payload.utf8), ts: ts,
                                                pid: pid[id])!, paths: paths, ts: ts)
        }
        let tools = HandoffTools(store: f.store, claudeDir: f.dir + "/claude", codexHome: f.dir + "/no-codex", paths: paths,
                                 cwd: "/work/p1", startedAt: startedAt, clientPid: clientPid)
        server = ZagonMCP.server(store: f.store, exportDir: f.dir + "/exports", handoff: tools)
    }

    static func setAge(_ path: String, _ age: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
    func touch(_ path: String, age: Double) throws { try Self.setAge(path, age) }

    func request(_ method: String, _ params: String) throws -> JValue {
        let out = try #require(server.handle(#"{"jsonrpc":"2.0","id":7,"method":"\#(method)","params":\#(params)}"#))
        return try #require(JValue.parse(out))
    }

    func call(_ tool: String, _ args: String = "{}") throws -> (String, Bool) {
        let r = try request("tools/call", #"{"name":"\#(tool)","arguments":\#(args)}"#)
        let res = try #require(r["result"], "\(r.compact)")
        return (res["content"]?.array?.first?["text"]?.string ?? "", res["isError"] == .bool(true))
    }

    func resume(_ id: String) throws -> String? {
        try request("prompts/get", #"{"name":"resume","arguments":{"id":"\#(id)"}}"#)["result"]?["messages"]?.array?
            .first?["content"]?["text"]?.string
    }
}

@Suite struct HandoffMCPTests {
    @Test func createGetList() throws {
        let h = try HandoffRPC()
        let (made, err) = try h.call("handoff_create")
        #expect(!err && made.hasPrefix("Handoff claude-\(h.b) saved: \(h.f.dir)/.zagon/handoffs/claude-\(h.b).md, "))
        let (md, e2) = try h.call("handoff_get", #"{"id":"claude-\#(h.b)"}"#)
        #expect(!e2 && md.hasPrefix("handoff: v1 | from: claude | session: \(h.b) | cwd: /work/p2"))
        #expect(md.hasSuffix(Handoff.footer + "\n") && md.contains("- fix the flaky tests"))

        let (fresh, e3) = try h.call("handoff_get", #"{"id":"claude:\#(h.a)"}"#) // a session id: built now, not saved
        #expect(!e3 && fresh.contains("Title: Parser refactor") && fresh.contains("- refactor the parser module"))
        #expect(try h.call("handoff_list").0.split(separator: "\n").count == 1)
        _ = try h.call("handoff_create", #"{"session":"claude:\#(h.a)"}"#)
        HandoffStore(paths: h.paths).markPending("claude-\(h.a)", cwd: "/work/p1")
        let rows = try h.call("handoff_list", #"{"limit":5}"#).0.split(separator: "\n")
        #expect(rows.count == 2)
        #expect(rows.contains { $0.hasPrefix("claude-\(h.a) | Parser refactor | ") && $0.hasSuffix("waits for the next Claude Code session in /work/p1") })
        #expect(rows.contains { $0.hasPrefix("claude-\(h.b) | fix the flaky tests | ") && $0.contains(" bytes") })

        let (miss, e5) = try h.call("handoff_get", #"{"id":"claude:nope"}"#)
        #expect(e5 && miss == "no Claude Code or Codex session matches 'claude:nope'")
    }

    @Test func theHookSpoolNamesThisConversation() throws {
        // B is this conversation (its SessionStart came with the server), even though its log is old: latest is A
        let h = try HandoffRPC(spool: [(h0b, 2, "startup")])
        #expect(try h.call("handoff_create").0.hasPrefix("Handoff claude-\(h.a) saved"))
        let text = try #require(try h.resume("latest"))
        #expect(text.hasPrefix("handoff: v1 | from: claude | session: \(h.a) |") && text.contains(Handoff.framing))
        #expect(try h.call("handoff_create", #"{"session":"current"}"#).0.hasPrefix("Handoff claude-\(h.b) saved"))
        // A Cursor chat opened later in the same folder (its lines carry no pid) is not this conversation.
        let cur = #"{"conversation_id":"c-1","cursor_version":"3.1.0","workspace_roots":["/work/p1"],"hook_event_name":"sessionStart"}"#
        let ts = h.startedAt + 300
        HookSpool.append(try #require(HookSpool.cursorLine(event: "SessionStart", payload: Array(cur.utf8), ts: ts)),
                         paths: h.paths, ts: ts, name: ".cursor")
        #expect(try h.call("handoff_create", #"{"session":"current"}"#).0.hasPrefix("Handoff claude-\(h.b) saved"))
    }

    @Test func afterClearTheEarlierConversationIsBack() throws {
        // A started with the server, `/clear` started C (no log yet): only C is this conversation, A and B are not hidden
        let h = try HandoffRPC(spool: [(h0a, 1, "startup"), ("cccccccc-1111-2222-3333-444444444444", 300, "clear")])
        #expect(try h.call("handoff_create").0.hasPrefix("Handoff claude-\(h.b) saved"))
        #expect(try h.call("handoff_create", #"{"exclude":"\#(h.b)"}"#).0.hasPrefix("Handoff claude-\(h.a) saved"))
    }

    @Test func theClientPidNamesThisConversation() throws {
        // A started with this server (pid 4242); B started later in the same directory from another terminal
        let h = try HandoffRPC(spool: [(h0a, 1, "startup"), (h0b, 300, "startup")], pid: [h0a: 4242, h0b: 5151], clientPid: 4242)
        #expect(try h.call("handoff_create", #"{"session":"current"}"#).0.hasPrefix("Handoff claude-\(h.a) saved"))
        #expect(try h.call("handoff_create").0.hasPrefix("Handoff claude-\(h.b) saved"))   // latest skips A only
        // `/clear` in the same process: the new session C is this conversation
        let c = "cccccccc-1111-2222-3333-444444444444"
        let h2 = try HandoffRPC(spool: [(h0a, 1, "startup"), (c, 300, "clear")], pid: [h0a: 4242, c: 4242], clientPid: 4242)
        #expect(try h2.call("handoff_create", #"{"session":"current"}"#).0.contains("claude:\(c)"))
        // only another process's SessionStart: not taken for this conversation
        let h3 = try HandoffRPC(spool: [(h0b, 2, "startup")], pid: [h0b: 5151], clientPid: 4242)
        #expect(try h3.call("handoff_create", #"{"session":"current"}"#).0.contains("session id is unknown"))
    }

    @Test func withoutHooksAJustWrittenLogIsTheCaller() throws {
        let h = try HandoffRPC(bAge: 0)
        #expect(try h.call("handoff_create").0.hasPrefix("Handoff claude-\(h.a) saved"))
        #expect(try h.call("handoff_create", #"{"session":"current"}"#).0.contains("session id is unknown"))
        // an explicit id is trusted instead of the guess
        #expect(try h.call("handoff_create", #"{"exclude":"claude:\#(h.a)"}"#).0.hasPrefix("Handoff claude-\(h.b) saved"))
    }

    @Test func getKeepsASavedHandoffUntilTheLogChanges() throws {
        let h = try HandoffRPC()
        _ = try h.call("handoff_create")
        let saved = h.paths.dir + "/handoffs/claude-\(h.b).md"
        try (try String(contentsOfFile: saved, encoding: .utf8) + "SHORTENED\n").write(toFile: saved, atomically: false, encoding: .utf8)
        #expect(try h.resume("latest")?.hasSuffix("SHORTENED\n") == true)
        try h.touch(h.f.dir + "/claude/-work-p1/\(h.b).jsonl", age: -5) // the session went on after the handoff
        #expect(try h.resume("latest")?.contains("SHORTENED") == false)
        #expect(try String(contentsOfFile: saved, encoding: .utf8).hasSuffix("SHORTENED\n")) // get wrote nothing
    }

    @Test func taskHandoffFromTheRegistry() throws {
        let h = try HandoffRPC()
        try h.f.store.db.exec("""
            INSERT INTO task(id, key, title, status, jira_key, created, updated) VALUES
              (1, 'PROJ-9', 't', 'open', 'JIRA-9', 0, 0), (2, 'PROJ-10', 'u', 'open', NULL, 0, 0);
            INSERT INTO task_session(task_id, session_id, how, start, "end") VALUES(1, 'claude:\(h.a)', 'manual', 0, 1e18),
              (1, 'claude:\(h.b)', 'branch', 0, 100), (1, 'claude:\(h.b)', 'branch', 200, 1e18), (1, 'claude:gone', 'manual', 0, 1e18);
            """)
        #expect(try h.call("handoff_create", #"{"task":"JIRA-9"}"#).0.hasPrefix("Handoff task-PROJ-9 saved"))
        #expect(try h.call("handoff_get", #"{"id":"task-PROJ-9"}"#).0
            .hasPrefix("handoff: v1 | from: claude | task: PROJ-9 | sessions: \(h.a), \(h.b) |"))
        try h.f.store.db.exec("UPDATE task_session SET how = 'unlinked' WHERE session_id = 'claude:\(h.b)'")
        #expect(try h.call("handoff_create", #"{"task":"1"}"#).0.hasPrefix("Handoff task-PROJ-9 saved"))
        #expect(try h.call("handoff_get", #"{"id":"task-PROJ-9"}"#).0.contains("| sessions: \(h.a) |"))
        #expect(try h.call("handoff_create", #"{"task":"PROJ-10"}"#) == ("task PROJ-10 has no linked sessions", true))
        #expect(try h.call("handoff_create", #"{"task":"NOPE-1"}"#) == ("no task NOPE-1", true))
    }

    @Test func emptyListAndSchema() throws {
        let h = try HandoffRPC()
        #expect(try h.call("handoff_list") == ("No handoffs yet; create one with handoff_create.", false))
        let tools = try #require(try h.request("tools/list", "{}")["result"]?["tools"]?.array)
        let create = try #require(tools.first { $0["name"]?.string == "handoff_create" })
        #expect(create["inputSchema"]?["properties"]?["exclude"]?["type"]?.string == "string")
        #expect(tools.first { $0["name"]?.string == "handoff_get" }?["annotations"] == ["readOnlyHint": true])
    }
}

private let h0a = "aaaaaaaa-1111-2222-3333-444444444444", h0b = "bbbbbbbb-1111-2222-3333-444444444444"
