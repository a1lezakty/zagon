import Foundation
import Testing
@testable import ZagonCore

/// Synthetic transcripts (no real data): two Claude sessions on 2026-10-29.
private let sessionA = "aaaaaaaa-1111-2222-3333-444444444444", sessionB = "bbbbbbbb-1111-2222-3333-444444444444"
private let transcriptA = """
    {"type":"user","timestamp":"2026-10-29T10:00:00Z","cwd":"/work/p1","gitBranch":"PROJ-1-x","message":{"role":"user","content":"refactor the parser module"}}
    {"type":"assistant","timestamp":"2026-10-29T10:01:00Z","cwd":"/work/p1","gitBranch":"PROJ-1-x","message":{"id":"msg_a1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":10},"content":[{"type":"tool_use","name":"Edit","id":"toolu_a1"}]}}
    {"type":"assistant","timestamp":"2026-10-29T10:05:00Z","cwd":"/work/p1","gitBranch":"PROJ-1-x","message":{"id":"msg_a2","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":100},"content":[{"type":"text","text":"x"}]}}
    {"type":"custom-title","customTitle":"Parser refactor"}

    """
private let transcriptB = """
    {"type":"user","timestamp":"2026-10-29T11:00:00Z","cwd":"/work/p2","message":{"role":"user","content":"fix the flaky tests"}}
    {"type":"assistant","timestamp":"2026-10-29T11:02:00Z","cwd":"/work/p2","message":{"id":"msg_b1","model":"claude-sonnet-5-5","usage":{"input_tokens":300,"output_tokens":30},"content":[{"type":"tool_use","name":"Bash","id":"toolu_b1"}]}}

    """
private let day = Time.dayString(Time.parseISO("2026-10-29T10:30:00Z")!)

final class FakeHandoff: HandoffService {
    var calls: [String] = []
    func create(session: String, task: String?, compress: Bool, exclude: String?) throws -> String {
        calls.append("create \(session) \(task ?? "-") \(compress)" + (exclude.map { " -\($0)" } ?? "")); return "handoff h1 created"
    }
    func get(_ ref: String) throws -> String { calls.append("get \(ref)"); return "HANDOFF TEXT for \(ref)" }
    func list(limit: Int) throws -> String { calls.append("list \(limit)"); return "1 handoff" }
}

final class FakeTasks: TaskService {
    var calls: [String] = []
    var fields: TaskFields?
    func list(status: String?, all: Bool, limit: Int) throws -> String { calls.append("list \(status ?? "-") \(limit)"); return "0 tasks" }
    func get(_ ref: String) throws -> String { calls.append("get \(ref)"); return "task \(ref)" }
    func create(_ f: TaskFields) throws -> String { fields = f; calls.append("create"); return "created ZAG-1" }
    func update(_ ref: String, _ f: TaskFields) throws -> String { fields = f; calls.append("update \(ref)"); return "updated" }
    func worklogPlan(day: String) throws -> String { calls.append("plan \(day)"); return "plan" }
    func worklogCommit(day: String, ids: [Int]?) throws -> String {
        calls.append("commit \(day) \(ids.map { "\($0)" } ?? "all")"); return "written"
    }
}

struct MCPFixture {
    let dir: String, store: Store, server: MCPServer
    let now = Time.now()

    init(handoff: HandoffService? = nil, tasks: TaskService? = nil) throws {
        dir = tempDir()
        let root = dir + "/claude/-work-p1"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try transcriptA.write(toFile: root + "/\(sessionA).jsonl", atomically: false, encoding: .utf8)
        try transcriptB.write(toFile: root + "/\(sessionB).jsonl", atomically: false, encoding: .utf8)
        store = try Store(path: dir + "/zagon.db")
        _ = try Ingest(store: store, sources: [ClaudeSource.spec(root: dir + "/claude")]).scan()
        let n = now
        try store.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: 30, resetsAt: n + 3 * 3600, ts: n - 2400))
        try store.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: 50, resetsAt: n + 3 * 3600, ts: n))
        try store.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "seven_day", usedPct: 17, resetsAt: n + 3 * 86400, ts: n))
        try store.addLimitSnapshot(LimitSnapshot(tool: .codex, window: "primary", usedPct: 1, resetsAt: n + 3600,
                                                 windowMinutes: 300, ts: n - 60))
        try store.addLimitSnapshot(LimitSnapshot(tool: .codex, window: "secondary", usedPct: 90, resetsAt: n + 86400,
                                                 windowMinutes: 10080, ts: n - 1200))
        try store.addLimitSnapshot(LimitSnapshot(tool: .codex, window: "secondary", usedPct: 100, resetsAt: n + 86400,
                                                 windowMinutes: 10080, ts: n))
        try store.setStatus(sessionId: "claude:" + sessionB, tool: .claude, status: "waiting_input", at: n - 600)
        server = ZagonMCP.server(store: store, exportDir: dir + "/exports", handoff: handoff, tasks: tasks, now: { n })
    }

    func rpc(_ line: String) throws -> JValue {
        let out = try #require(server.handle(line))
        return try #require(JValue.parse(out))
    }

    func request(_ method: String, _ params: String = "{}", id: String = "1") throws -> JValue {
        try rpc(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#)
    }

    /// tools/call → (text, isError).
    func call(_ tool: String, _ args: String = "{}") throws -> (String, Bool) {
        let r = try request("tools/call", #"{"name":"\#(tool)","arguments":\#(args)}"#)
        let res = try #require(r["result"], "\(r.compact)")
        return (res["content"]?.array?.first?["text"]?.string ?? "", res["isError"] == .bool(true))
    }

    func errorCode(_ r: JValue) -> String? { if case .number(let n)? = r["error"]?["code"] { return n }; return nil }
}

@Suite struct MCPTests {
    @Test func handshake() throws {
        let f = try MCPFixture()
        let r = try f.request("initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}"#)
        #expect(r["jsonrpc"]?.string == "2.0" && r["id"] == .number("1"))
        #expect(r["result"]?["protocolVersion"]?.string == "2025-06-18")
        #expect(r["result"]?["capabilities"]?["tools"] != nil && r["result"]?["capabilities"]?["prompts"] != nil)
        #expect(r["result"]?["serverInfo"]?["name"]?.string == "zagon")
        #expect(r["result"]?["serverInfo"]?["version"]?.string == zagonVersion)  // the one `zagon --version` prints
        let old = try f.request("initialize", #"{"protocolVersion":"1999-01-01"}"#)
        #expect(old["result"]?["protocolVersion"]?.string == MCPServer.protocolVersions[0])
        #expect(f.server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try f.request("ping", id: #""p-1""#) == ["jsonrpc": "2.0", "id": "p-1", "result": .object([])])
    }

    @Test func listsAllTools() throws {
        let f = try MCPFixture()
        let tools = try #require(try f.request("tools/list")["result"]?["tools"]?.array)
        #expect(tools.compactMap { $0["name"]?.string } == [
            "limits", "sessions", "day", "week", "range", "search", "export_day",
            "handoff_create", "handoff_get", "handoff_list", "task_list", "task_get", "task_create", "task_update",
            "worklog_plan", "worklog_commit", "worklog_reconcile", "task_suggestions", "task_suggestions_answer", "task_create_in_jira"])
        for t in tools {
            #expect(t["inputSchema"]?["type"]?.string == "object")
            #expect((t["description"]?.string?.count ?? 0) > 30)
        }
        let commit = try #require(tools.first { $0["name"]?.string == "worklog_commit" })
        #expect(commit["inputSchema"]?["required"] == ["date", "confirm"])
        #expect(commit["annotations"] == ["readOnlyHint": false, "destructiveHint": false])
        #expect(tools[0]["annotations"] == ["readOnlyHint": true])
        #expect(commit["description"]?.string?.contains("ONLY when the user explicitly asks") == true)
    }

    @Test func reportTools() throws {
        let f = try MCPFixture()
        let (limits, e1) = try f.call("limits")
        #expect(!e1)
        #expect(limits.contains("Claude 5h: 50% used, resets") && limits.contains("in 3h 00m"))
        #expect(limits.contains("runs out at") && limits.contains("before the reset"))   // +20 % in 40 min, 50 % left
        #expect(limits.contains("Claude week: 17% used") && limits.contains("Codex 5h: 1% used"))
        #expect(limits.contains("Codex week: 100% used, resets") && limits.contains("; limit reached"))

        let (sessions, _) = try f.call("sessions")
        let lines = sessions.split(separator: "\n").map(String.init)
        #expect(lines.first == "2 sessions: 1 waiting for the user, 0 working")
        #expect(lines.count == 3 && lines[1].contains("bbbbbbbb") && lines[1].contains("waiting for input 10m"))
        #expect(lines[2].contains("\"Parser refactor\"") && lines[2].contains("p1 (PROJ-1-x)"))
        #expect(lines[2].contains("resume: cd /work/p1 && claude --resume \(sessionA)"))

        let (d, _) = try f.call("day", #"{"date":"\#(day)"}"#)
        #expect(d.hasPrefix("\(day) (Thu): 1.8k tokens"))   // 1460 + 330
        #expect(d.contains("2 sessions") && d.contains("claude-opus-5-5 1.5k (82%)") && d.contains("Edit 1"))
        #expect(d.contains("\"Parser refactor\""))
        #expect(try f.call("day", #"{"date":"2020-01-01"}"#).0 == "2020-01-01: no activity recorded.")

        let (w, _) = try f.call("week", #"{"start":"\#(Time.addDays(day, -2)!)"}"#)
        #expect(w.contains("1.8k tokens") && w.contains("(new vs the 7 days before: 0)") && w.contains("- \(day) Thu: 1.8k"))

        let (r, _) = try f.call("range", #"{"from":"\#(Time.addDays(day, -9)!)","to":"\#(day)"}"#)
        #expect(r.contains("(10 days, 1 active): 1.8k tokens") && r.contains("days: \(day) 1.8k"))
    }

    @Test func search() throws {
        let f = try MCPFixture()
        let (s, _) = try f.call("search", #"{"text":"PARSE"}"#)   // prefix, any case; title + message
        #expect(s.hasPrefix("1 sessions match") && s.contains("aaaaaaaa") && s.contains("matches: title + 1 message"))
        let (flaky, _) = try f.call("search", #"{"text":"flaky test"}"#)
        #expect(flaky.contains("bbbbbbbb") && flaky.contains("matches: 1 message") && !flaky.contains("aaaaaaaa"))
        #expect(try f.call("search", #"{"text":"parser flaky"}"#).0.hasPrefix("No sessions match"))
        #expect(try f.call("search", #"{"text":"parser","from":"\#(Time.addDays(day, 1)!)"}"#).0.hasPrefix("No sessions match"))
        #expect(try f.call("search", #"{"text":"\"* OR NEAR("}"#).0.hasPrefix("No sessions match"))   // no FTS syntax leaks
        let (empty, isErr) = try f.call("search", #"{"text":"*"}"#)
        #expect(isErr && empty.contains("at least one word"))
    }

    @Test func exportDay() throws {
        let f = try MCPFixture()
        let (t, isErr) = try f.call("export_day", #"{"date":"\#(day)"}"#)
        let path = f.dir + "/exports/\(day).md"
        #expect(!isErr && t.hasPrefix("Wrote \(path)") && t.contains("2 sessions"))
        let md = try String(contentsOfFile: path, encoding: .utf8)
        #expect(md.hasPrefix("# \(day)") && md.contains("| Parser refactor | claude | p1 | PROJ-1-x | 1.5k |"))
        #expect(md.contains("| claude-sonnet-5-5 | 330 | 18% |"))
    }

    @Test func protocolErrors() throws {
        let f = try MCPFixture()
        #expect(f.errorCode(try f.request("nope/method")) == "-32601")
        #expect(f.errorCode(try f.request("tools/call", #"{"name":"nope"}"#)) == "-32602")
        #expect(f.errorCode(try f.request("tools/call", #"{}"#)) == "-32602")
        #expect(f.errorCode(try f.request("tools/call", #"{"name":"day","arguments":[1]}"#)) == "-32602")
        #expect(f.errorCode(try f.request("tools/list", "[1]")) == "-32602")
        let parse = try f.rpc("{not json")
        #expect(f.errorCode(parse) == "-32700" && parse["id"] == .null)
        #expect(f.errorCode(try f.rpc(#"{"id":1,"method":"ping"}"#)) == "-32600")
        #expect(f.errorCode(try f.rpc(#"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#)) == "-32600")
        let plus = try f.rpc(#"{"jsonrpc":"2.0","id":+1,"method":"ping"}"#)   // not a JSON number: not echoed
        #expect(f.errorCode(plus) == "-32600" && plus["id"] == .null)
        #expect(f.server.handle(#"{"jsonrpc":"2.0","id":5,"result":{}}"#) == nil)   // a client response: ignored
        #expect(f.server.handle("   ") == nil)
        let batch = try #require(JValue.parse(f.server.handle(
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#) ?? ""))
        #expect(batch.array?.count == 1)
        // Bad arguments of a known tool: a tool result with isError, so the model can retry.
        for (tool, args, msg) in [("day", #"{"date":"2026-13-01"}"#, "date must be a date"),
                                  ("day", #"{"date":"3000000000-01-01"}"#, "date must be a date"),   // used to trap
                                  ("range", #"{"from":"999-01-01"}"#, "from must be a date"),
                                  ("day", #"{"date":"2026-02-31"}"#, "date must be a date"),
                                  ("day", #"{"date":5}"#, "date must be a string"),
                                  ("range", #"{}"#, "from is required"),
                                  ("range", #"{"from":"2026-10-29","to":"2026-10-01"}"#, "must not be after"),
                                  ("sessions", #"{"limit":"x"}"#, "limit must be an integer"),
                                  ("search", #"{}"#, "text is required")] {
            let (t, isErr) = try f.call(tool, args)
            #expect(isErr && t.contains(msg), "\(tool) \(args): \(t)")
        }
    }

    @Test func laterToolsWithoutServices() throws {
        let f = try MCPFixture()
        for tool in ["handoff_create", "handoff_get", "handoff_list", "task_list", "task_get", "task_create", "task_update",
                     "worklog_plan"] {
            let args = tool == "task_get" || tool == "task_update" ? #"{"ref":"ZAG-1"}"# : tool == "task_create" ? #"{"title":"t"}"# : "{}"
            let (t, isErr) = try f.call(tool, args)
            #expect(isErr && t == "\(tool) is not available in this build (\(tool.hasPrefix("handoff") ? "handoff" : "the task registry") is not included yet).")
        }
        let (c, isErr) = try f.call("worklog_commit", #"{"date":"2026-10-29"}"#)
        #expect(isErr && c.contains("needs confirm: true"))
        let prompts = try #require(try f.request("prompts/list")["result"]?["prompts"]?.array)
        #expect(prompts.count == 1 && prompts[0]["name"]?.string == "resume")
        let r = try f.request("prompts/get", #"{"name":"resume","arguments":{"id":"latest"}}"#)
        #expect(f.errorCode(r) == "-32603" && r["error"]?["message"]?.string?.contains("not available in this build") == true)
        #expect(f.errorCode(try f.request("prompts/get", #"{"name":"nope"}"#)) == "-32602")
    }

    @Test func laterToolsReachServices() throws {
        let h = FakeHandoff(), t = FakeTasks()
        let f = try MCPFixture(handoff: h, tasks: t)
        #expect(try f.call("handoff_create", #"{"task":"PROJ-1","compress":true}"#) == ("handoff h1 created", false))
        #expect(try f.call("handoff_get").0 == "HANDOFF TEXT for latest")
        let r = try f.request("prompts/get", #"{"name":"resume","arguments":{"id":""}}"#)
        #expect(r["result"]?["messages"]?.array?.first?["content"]?["text"]?.string == "HANDOFF TEXT for latest")
        #expect(h.calls == ["create latest PROJ-1 true", "get latest", "get latest"])
        #expect(f.errorCode(try f.request("prompts/get", #"{"name":"resume","arguments":{"id":5}}"#)) == "-32602")

        #expect(try f.call("task_update", #"{"ref":"ZAG-1","status":"in_progress","note":"n","todo_done":2}"#).1 == false)
        #expect(t.fields?.status == "in_progress" && t.fields?.note == "n" && t.fields?.todoDone == 2 && t.fields?.title == nil)
        #expect(try f.call("task_update", #"{"ref":"ZAG-1","status":"closed"}"#).1)
        #expect(try f.call("worklog_commit", #"{"date":"2026-10-29","confirm":false}"#).1)
        #expect(try f.call("worklog_commit", #"{"date":"2026-10-29","confirm":true,"ids":[3,4]}"#) == ("written", false))
        #expect(t.calls == ["update ZAG-1", "commit 2026-10-29 [3, 4]"])
    }

    @Test func resumeCommandIsQuoted() {
        #expect(ReportTools.resumeCommand(id: "codex:x; rm -rf ~", tool: "codex", cwd: "/w/a b")
                == "cd '/w/a b' && codex resume 'x; rm -rf ~'")
        #expect(ReportTools.resumeCommand(id: "claude:abc-1", tool: "claude", cwd: nil) == "claude --resume abc-1")
        #expect(ReportTools.resumeCommand(id: "claude:", tool: "claude", cwd: nil) == nil)
    }

    /// The real binary: every stdout line is a JSON-RPC response, one per request with an id, nothing else.
    @Test func binaryStdoutIsProtocolOnly() throws {
        let f = try MCPFixture()
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"limits","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"day","arguments":{"date":"\#(day)"}}}"#,
            "garbage",
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search","arguments":{"text":"parser"}}}"#,
        ].joined(separator: "\n") + "\n"
        var env = ["HOME": f.dir, "PATH": "/usr/bin:/bin"]
        env["TZ"] = ProcessInfo.processInfo.environment["TZ"]   // same local days as the ingest above
        let (status, out) = try runZagon(["mcp", "--db", f.dir + "/zagon.db", "--no-scan", "--data-dir", f.dir],
                                         stdin: Array(input.utf8), env: env)
        #expect(status == 0)
        let lines = String(decoding: out, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.last == "" && lines.count == 7)   // 6 responses + trailing newline
        let msgs = lines.dropLast().compactMap { JValue.parse(String($0)) }
        #expect(msgs.count == 6 && msgs.allSatisfy { $0["jsonrpc"]?.string == "2.0" })
        #expect(msgs.map { $0["id"] ?? .null } == [.number("1"), .number("2"), .number("3"), .number("4"), .null, .number("5")])
        #expect(msgs[3]["result"]?["content"]?.array?.first?["text"]?.string?.contains("1.8k tokens") == true)
    }
}
