import Foundation
import Testing
@testable import ZagonCore

// Builders of Claude Code transcript lines in the shape the CLI writes (compact JSON, `type` near the end,
// plenty of fields Zagon does not read).

/// 2026-10-20 10:00:00 UTC.
let T0 = Time.parseISO("2026-10-20T10:00:00Z")!
let minute = 60.0, hour = 3600.0

func iso(_ t: Timestamp) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date(timeIntervalSince1970: t))
}

/// A JSON string literal.
func js(_ s: String) -> String {
    var o = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += "\\n"
        case "\t": o += "\\t"
        default: if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
        }
    }
    return o + "\""
}

/// `command` = the shell command of every tool call (a Bash `input.command`).
func assistantLine(_ t: Timestamp, id: String, model: String = "claude-opus-4-1", input: Int = 0, output: Int = 0,
                   cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, tools: [(id: String, name: String)] = [],
                   command: String = "ls \"a b\" ]}", session: String = "S", cwd: String = "/w/alpha", branch: String = "main",
                   usage: Bool = true) -> String {
    var content = [#"{"type":"text","text":"done {\"x\":[1,\"]\"]} \\ ok"}"#]
    for t in tools {
        content.append(#"{"type":"tool_use","id":"\#(t.id)","name":"\#(t.name)","input":{"command":\#(js(command)),"opts":{"k":[1,{"z":"}"}]}}}"#)
    }
    let u = usage ? #","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"cache_creation":{"ephemeral_5m_input_tokens":\#(cacheWrite - cacheWrite1h),"ephemeral_1h_input_tokens":\#(cacheWrite1h)},"output_tokens":\#(output),"service_tier":"standard","server_tool_use":{"web_search_requests":0}}"# : ""
    return #"{"parentUuid":"00000000-0000-4000-8000-000000000001","isSidechain":false,"userType":"external","cwd":\#(js(cwd)),"sessionId":"\#(session)","version":"2.0.14","gitBranch":\#(js(branch)),"message":{"id":"\#(id)","type":"message","role":"assistant","model":"\#(model)","content":[\#(content.joined(separator: ","))],"stop_reason":null,"stop_sequence":null\#(u)},"requestId":"req_1","type":"assistant","uuid":"00000000-0000-4000-8000-000000000002","timestamp":"\#(iso(t))"}"#
}

/// A user record; `content` is raw JSON (a string literal or a block array), `extra` raw `,"key":value` pairs.
func userLine(_ t: Timestamp, content: String, extra: String = "", session: String = "S", cwd: String = "/w/alpha",
              branch: String = "main") -> String {
    #"{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":\#(js(cwd)),"sessionId":"\#(session)","version":"2.0.14","gitBranch":\#(js(branch)),"type":"user","message":{"role":"user","content":\#(content)},"uuid":"00000000-0000-4000-8000-000000000003","timestamp":"\#(iso(t))"\#(extra)}"#
}

func typed(_ t: Timestamp, _ text: String = "please fix it", session: String = "S", cwd: String = "/w/alpha") -> String {
    userLine(t, content: js(text), session: session, cwd: cwd)
}

func toolResult(_ t: Timestamp, id: String = "toolu_1", session: String = "S") -> String {
    userLine(t, content: #"[{"tool_use_id":"\#(id)","type":"tool_result","content":"out \"q\" ]}","is_error":false}]"#,
             extra: #","toolUseResult":{"stdout":"x","stderr":"","interrupted":false}"#, session: session)
}

/// Feeds lines to one parser instance.
func parse(_ lines: [String], agent: String = "", indexPrompts: Bool = true) -> ParseOutput {
    var p = ClaudeParser(sessionId: "claude:S", agent: agent, indexPrompts: indexPrompts)
    var out = ParseOutput()
    for l in lines { Array(l.utf8).withUnsafeBytes { p.parse(line: $0, into: &out) } }
    return out
}

@Suite struct ClaudeParserTests {
    @Test func assistantUsageModelAndTools() {
        let out = parse([assistantLine(T0, id: "msg_1", model: "claude-sonnet-4-5", input: 11, output: 22, cacheRead: 33,
                                       cacheWrite: 44, tools: [("toolu_a", "Bash"), ("toolu_b", "Read")])])
        #expect(out.badLines == 0)
        #expect(out.usage == [UsageRecord(sessionId: "claude:S", agent: "", ts: T0, model: "claude-sonnet-4-5", input: 11,
                                          output: 22, cacheRead: 33, cacheWrite: 44, messageId: "msg_1", cwd: "/w/alpha")])
        #expect(out.tools == [ToolCall(sessionId: "claude:S", ts: T0, name: "Bash", callId: "toolu_a"),
                              ToolCall(sessionId: "claude:S", ts: T0, name: "Read", callId: "toolu_b")])
        #expect(out.events == [ActivityEvent(sessionId: "claude:S", ts: T0, cwd: "/w/alpha")])
        #expect(out.userMessages.isEmpty)
        #expect(out.meta == [SessionMeta(id: "claude:S", tool: .claude, project: "alpha", cwd: "/w/alpha", gitBranch: "main",
                                         model: "claude-sonnet-4-5")])
        // No usage block: activity only.
        let noUsage = parse([assistantLine(T0, id: "msg_2", usage: false)])
        #expect(noUsage.usage.isEmpty && noUsage.events.count == 1)
    }

    @Test func typedMessagesVersusOtherUserRecords() {
        let human = [
            typed(T0, "fix the \"bug\"\nnow"),
            userLine(T0 + 1, content: #"[{"type":"text","text":"from blocks"}]"#),
            userLine(T0 + 2, content: #"[{"type":"image","source":{"type":"base64","data":"AAAA"}}]"#),  // image only
            userLine(T0 + 3, content: js("<task-notification> typed by hand"), extra: #","turnOrigin":"human""#),
        ]
        let other = [
            toolResult(T0 + 10),
            userLine(T0 + 11, content: js("Caveat: meta"), extra: #","isMeta":true"#),
            userLine(T0 + 12, content: js("summary"), extra: #","isCompactSummary":true,"isVisibleInTranscriptOnly":true"#),
            userLine(T0 + 13, content: js("<task-notification><task-id>1</task-id></task-notification>")),
            userLine(T0 + 14, content: js("<local-command-stdout>x</local-command-stdout>")),
            userLine(T0 + 15, content: #"[{"type":"text","text":"<system-reminder>r</system-reminder>"}]"#),
            userLine(T0 + 16, content: js("done"), extra: #","turnOrigin":"task_notification""#),
            userLine(T0 + 17, content: js("hi"), extra: #","turnOrigin":"peer","isMeta":true"#),
            userLine(T0 + 18, content: "[]"),
        ]
        let out = parse(human + other)
        #expect(out.badLines == 0)
        #expect(out.userMessages.map(\.ts) == [T0, T0 + 1, T0 + 2, T0 + 3])
        #expect(out.userMessages.map(\.text) == ["fix the \"bug\"\nnow", "from blocks", "", "<task-notification> typed by hand"])
        #expect(out.events.map(\.ts) == (10...18).map { T0 + Double($0) })

        // Without the search index the parser still passes the text (task keys; Ingest does not index it), and
        // notifications are still not typed messages.
        let plain = parse(human + other, indexPrompts: false)
        #expect(plain.userMessages.map(\.ts) == [T0, T0 + 1, T0 + 2, T0 + 3])
        #expect(plain.userMessages.map(\.text) == out.userMessages.map(\.text))
        #expect(plain.events.count == other.count)

        // Long texts are cut for the index.
        let long = parse([typed(T0, String(repeating: "é", count: 3000))])
        #expect(long.userMessages.first?.text?.utf8.count == ClaudeParser.textLimit)
    }

    @Test func channelMessagesAreTyped() {
        let channel = #","isMeta":true,"origin":{"kind":"channel","server":"plugin:telegram:telegram"},"turnOrigin":"peer","promptSource":"system""#
        let out = parse([
            userLine(T0, content: js("<channel source=\"plugin:telegram:telegram\" chat_id=\"1\" user=\"u\">\nfix the build\n</channel>"),
                     extra: channel),
            userLine(T0 + 1, content: js("hi"), extra: #","isMeta":true,"origin":{"kind":"peer"},"turnOrigin":"peer""#),
            userLine(T0 + 2, content: js("<task-notification><tool-use-id>toolu_1</tool-use-id></task-notification>"),
                     extra: #","origin":{"kind":"task-notification"},"turnOrigin":"task_notification""#),
            userLine(T0 + 3, content: js("typed"), extra: #","origin":"human""#),  // another shape: still readable
        ])
        #expect(out.badLines == 0)
        #expect(out.userMessages.map(\.ts) == [T0, T0 + 3])
        #expect(out.userMessages.map(\.text) == ["fix the build", "typed"])
        #expect(out.events.map(\.ts) == [T0 + 1, T0 + 2])
    }

    @Test func titlesAndRanks() {
        let out = parse([
            #"{"type":"ai-title","aiTitle":"Auto","sessionId":"S"}"#,
            #"{"type":"ai-title","aiTitle":"Auto","sessionId":"S"}"#,           // same title: sent once
            #"{"type":"agent-name","agentName":"Agent é","sessionId":"S"}"#,
            #"{"type":"custom-title","customTitle":"Mine","sessionId":"S"}"#,
            #"{"type":"custom-title","customTitle":"","sessionId":"S"}"#,         // empty: ignored
        ])
        #expect(out.meta.map { [$0.title ?? "-", "\($0.titleRank)"] } ==
                [["Auto", "\(TitleRank.aiTitle)"], ["Agent é", "\(TitleRank.agentName)"], ["Mine", "\(TitleRank.customTitle)"]])
        // A sub-agent file never names the session.
        #expect(parse([#"{"type":"custom-title","customTitle":"Mine","sessionId":"S"}"#], agent: "agent-a").meta.isEmpty)
    }

    @Test func sessionMeta() {
        let out = parse([
            typed(T0, cwd: "/home/u/proj"),
            assistantLine(T0 + 1, id: "m1", model: "<synthetic>", cwd: "/home/u/proj"),
            assistantLine(T0 + 2, id: "m2", model: "claude-opus-4-1", cwd: "/home/u/proj"),
            assistantLine(T0 + 3, id: "m3", model: "claude-opus-4-1", cwd: "/home/u/proj", branch: ""),
            assistantLine(T0 + 4, id: "m4", model: "claude-opus-4-1", cwd: "/home/u/other", branch: "dev"),
        ])
        #expect(out.meta == [
            SessionMeta(id: "claude:S", tool: .claude, project: "proj", cwd: "/home/u/proj", gitBranch: "main"),
            SessionMeta(id: "claude:S", tool: .claude, model: "claude-opus-4-1"),
            SessionMeta(id: "claude:S", tool: .claude, project: "other", cwd: "/home/u/other", gitBranch: "dev"),
        ])
        #expect(out.usage.map(\.model) == ["<synthetic>", "claude-opus-4-1", "claude-opus-4-1", "claude-opus-4-1"])
        #expect(ClaudeParser.project("/") == "/" && ClaudeParser.project("/a/b/") == "b" && ClaudeParser.project("x") == "x")
    }

    @Test func subAgentRecords() {
        let out = parse([typed(T0, "task prompt"), assistantLine(T0 + 5, id: "m1", input: 1, output: 2), toolResult(T0 + 6)],
                        agent: "agent-a1")
        #expect(out.userMessages.isEmpty)
        #expect(out.events.map(\.ts) == [T0, T0 + 5, T0 + 6])
        #expect(out.usage.map(\.agent) == ["agent-a1"])
        #expect(out.meta == [SessionMeta(id: "claude:S", tool: .claude)])  // creates the session, no cwd/model
    }

    @Test func unknownFieldsAndTypesAreSkipped() {
        let out = parse([
            #"{"type":"attachment","attachment":{"type":"user","message":{"content":"x"}},"timestamp":"\#(iso(T0))"}"#,
            #"{"type":"progress","data":{"message":{"type":"assistant","message":{"id":"m9","usage":{"output_tokens":5}}}},"timestamp":"\#(iso(T0))"}"#,
            #"{"type":"file-history-snapshot","snapshot":{}}"#,
            #"{"type":"system","subtype":"x","isMeta":false}"#,
            #"{"future":[1,{"a":null}],"type":"assistant","timestamp":"\#(iso(T0))","message":{"id":"m1","usage":{"output_tokens":7,"new_counter":{"x":1}},"content":[{"type":"thinking","thinking":"t","signature":"s"}],"extra":true}}"#,
        ])
        #expect(out.badLines == 0)
        #expect(out.usage.map(\.output) == [7] && out.usage.map(\.model) == ["?"])
        #expect(out.events.count == 1 && out.userMessages.isEmpty && out.tools.isEmpty)
    }

    @Test func scannerFallsBackToDecoder() {
        // A non-object element in `content` is beyond the byte scanner; JSONDecoder still gets the usage.
        let line = #"{"type":"assistant","timestamp":"\#(iso(T0))","message":{"id":"m1","model":"claude-haiku-4-5","content":["odd",{"type":"tool_use","id":"toolu_1","name":"Bash"}],"usage":{"input_tokens":4,"output_tokens":5}}}"#
        #expect(Array(line.utf8).withUnsafeBytes { ClaudeParser.scan($0, wantText: false) } == nil)
        #expect(Array(line.utf8).withUnsafeBytes { ClaudeParser.decode($0) } != nil)
        let out = parse([line])
        #expect(out.badLines == 0 && out.usage.map(\.input) == [4] && out.usage.map(\.output) == [5])
        #expect(out.usage.first?.model == "claude-haiku-4-5")
        // Whitespace and CRLF are fine for the scanner itself.
        let spaced = "{ \"type\" : \"assistant\",\"timestamp\": \"\(iso(T0))\", \"message\": { \"id\": \"m2\", \"usage\": { \"output_tokens\": 3 } } }\r"
        #expect(Array(spaced.utf8).withUnsafeBytes { ClaudeParser.scan($0, wantText: false) }?.message?.usage?.output_tokens == 3)
    }

    @Test func garbageLinesAreCountedNotFatal() {
        let out = parse([
            #"{"type":"assistant","message":{"id":"m1","usage":{"output_tokens":5"#,  // cut
            #"{"type":"user" garbage"#,
            #"{"type":"assistant","message":{}} trailing"#,
            "\u{1}\u{2}\"type\":\"user\"\u{FF}",
            "not json at all",                                                   // not relevant: not counted
            #"{"type":"assistant","timestamp":"bad","message":{"id":"m2","usage":{"output_tokens":1}}}"#,  // no time: dropped
            assistantLine(T0, id: "m3", output: 9),
        ])
        #expect(out.badLines == 4)
        #expect(out.usage.map(\.output) == [9])
    }

    @Test func layout() {
        #expect(ClaudeSource.layout("-w-alpha/S.jsonl")! == ("S", ""))
        #expect(ClaudeSource.layout("-w-alpha/S/subagents/agent-a1.jsonl")! == ("S", "agent-a1"))
        #expect(ClaudeSource.layout("-w-alpha/S/subagents/workflows/wf_1/agent-b2.jsonl")! == ("S", "agent-b2"))
        for rel in ["S.jsonl", "-w-alpha/S.json", "-w-alpha/S/subagents/workflows/wf_1/journal.jsonl",
                    "-w-alpha/S/other/agent-x.jsonl", "-w-alpha/S/subagents/agent-a1.meta.json", "-w-alpha/S/x.jsonl"] {
            #expect(ClaudeSource.layout(rel) == nil, "\(rel)")
        }
    }
}
