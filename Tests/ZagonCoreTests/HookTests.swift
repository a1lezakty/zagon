import Foundation
import Testing
@testable import ZagonCore

func makeTempDir() -> String {
    let d = NSTemporaryDirectory() + "zagon-test-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// An executable script for a test to run. A child process writes it: a file this process has just written can fail
/// to exec with ETXTBSY, because a child that a parallel test is spawning meanwhile may still hold the descriptor.
@discardableResult
func writeScript(_ path: String, _ text: String) -> Bool {
    Sys.capture(["/bin/sh", "-c", "cat > \"$0\" && chmod 755 \"$0\"", path], stdin: Array(text.utf8)).status == 0
}

/// The `zagon` executable built next to the tests (`swift build --build-tests` / `swift test`).
let zagonBin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().path + "/.build/debug/zagon"

/// Runs the binary with exactly `env`, feeds `stdin`, returns (exit status, stdout).
func runZagon(_ args: [String], stdin: [UInt8], env: [String: String]) throws -> (Int32, [UInt8]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: zagonBin)
    p.arguments = args
    p.environment = env
    let inP = Pipe(), outP = Pipe()
    p.standardInput = inP; p.standardOutput = outP; p.standardError = FileHandle.nullDevice
    try p.run()
    inP.fileHandleForWriting.write(Data(stdin))
    try inP.fileHandleForWriting.close()
    let out = outP.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, Array(out))
}

func shell(_ cmd: String, stdin: [UInt8]) throws -> [UInt8] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let inP = Pipe(), outP = Pipe()
    p.standardInput = inP; p.standardOutput = outP
    try p.run()
    inP.fileHandleForWriting.write(Data(stdin))
    try inP.fileHandleForWriting.close()
    let out = outP.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Array(out)
}

func spoolLines(_ dir: String) -> [String] {
    Sys.listDir(dir + "/spool").filter { $0.hasSuffix(".ndjson") }.flatMap { name in
        String(decoding: Sys.readFile(dir + "/spool/" + name) ?? [], as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

let hookPayload = Array("""
    {"session_id":"s-1","transcript_path":"/h/t.jsonl","cwd":"/w","hook_event_name":"UserPromptSubmit",
     "permission_mode":"default","prompt":"SECRET PROMPT","tool_input":{"command":"SECRET INPUT"},"n":[1,{"a":null}]}
    """.utf8)

#if os(Linux)
/// `zagon hook` records the process that ran the hook command, skipping the `sh -c` Claude Code wraps it in.
@Suite struct ClientPidTests {
    @Test(.enabled(if: Sys.exists(zagonBin))) func throughAShellAndDirectly() throws {
        let dir = makeTempDir(), me = ProcessInfo.processInfo.processIdentifier
        // `; true` keeps sh alive as the hook's parent (a lone command may be exec'd in place of the shell)
        _ = try shell("ZAGON_DIR=\(Sys.shellQuote(dir)) \(Sys.shellQuote(zagonBin)) hook claude Stop; true", stdin: hookPayload)
        _ = try runZagon(["hook", "claude", "Stop"], stdin: hookPayload, env: ["ZAGON_DIR": dir, "PATH": "/usr/bin:/bin"])
        let pids = spoolLines(dir).compactMap { JValue.parse($0)?["pid"] }
        #expect(pids == [.number("\(me)"), .number("\(me)")])
    }
}
#endif

@Suite struct HookSpoolTests {
    @Test func lineKeepsIdsAndDropsText() throws {
        let line = try #require(HookSpool.hookLine(tool: "claude", event: "UserPromptSubmit", payload: hookPayload, ts: 1.5))
        #expect(!line.contains("SECRET"))
        #expect(!line.contains("\n"))
        let v = try #require(JValue.parse(line))
        #expect(v["session_id"]?.string == "s-1")
        #expect(v["cwd"]?.string == "/w")
        #expect(v["transcript_path"]?.string == "/h/t.jsonl")
        #expect(v["permission_mode"]?.string == "default")
        #expect(v["ts"] == .number("1.500"))
        #expect(v["pid"] == nil)
        let withPid = try #require(HookSpool.hookLine(tool: "claude", event: "SessionStart", payload: hookPayload, ts: 1, pid: 4242))
        #expect(JValue.parse(withPid)?["pid"] == .number("4242"))
        for junk in ["", "null", "[1]", "{", "{\"session_id\":1}", "{\"session_id\":\"\"}", "\u{0}\u{FF}"] {
            #expect(HookSpool.hookLine(tool: "claude", event: "Stop", payload: Array(junk.utf8), ts: 1) == nil)
        }
    }

    /// Other editors' agents run the hooks of `~/.claude/settings.json` with their own input (shapes from their docs):
    /// nothing is recorded and a waiting handoff stays for Claude Code. Claude Code with its config elsewhere
    /// (`CLAUDE_CONFIG_DIR`) and Codex without a transcript still count.
    @Test func otherAgentsCallsAreIgnored() throws {
        let dir = makeTempDir(), cwd = makeTempDir()
        let paths = ZagonPaths(home: dir, dir: dir)
        func feed(_ event: String, _ payload: String, tool: String = "claude") {
            var fds: [Int32] = [0, 0]
            #expect(pipe(&fds) == 0)
            let b = Array(payload.utf8)
            _ = b.withUnsafeBytes { write(fds[1], $0.baseAddress, b.count) }
            close(fds[1])
            HookSpool.handleHook(args: [tool, event], stdinFD: fds[0], paths: paths)
            close(fds[0])
        }
        #expect(HandoffStore(paths: paths).markPending("h-1", cwd: cwd))
        let roots = js(cwd)
        feed("SessionStart", #"{"conversation_id":"c-1","generation_id":"g-1","model":"default","hook_event_name":"sessionStart","cursor_version":"1.7.2","workspace_roots":[\#(roots)],"user_email":null,"transcript_path":null,"session_id":"c-1","is_background_agent":false,"composer_mode":"agent","cwd":\#(roots)}"#)
        feed("Stop", #"{"conversation_id":"c-1","generation_id":"g-2","model":"default","hook_event_name":"stop","cursor_version":"1.7.2","workspace_roots":[\#(roots)],"user_email":null,"transcript_path":"/h/.cursor/projects/p/agent-transcripts/c-1.txt","status":"completed","loop_count":0}"#)
        // Devin (ex-Windsurf): no cwd, no transcript. Trae: workspace roots. VS Code's agent: a timestamp.
        feed("SessionStart", #"{"hook_event_name":"SessionStart","session_id":"d-1","prompt_id":"p-1"}"#)
        feed("Stop", #"{"session_id":"t-1","cwd":\#(roots),"hook_event_name":"Stop","workspace_roots":[\#(roots)]}"#)
        feed("UserPromptSubmit", #"{"timestamp":"2026-10-20T10:00:00.000Z","cwd":\#(roots),"session_id":"v-1","hook_event_name":"UserPromptSubmit","transcript_path":"/h/v-1.json","prompt":"x"}"#)
        #expect(spoolLines(dir).isEmpty)
        #expect(Sys.listDir(dir + "/handoffs/pending").count == 1)
        #expect(!Sys.listDir(dir + "/handoffs/pending").contains { $0.hasSuffix(".used") })

        // Claude Code's input as 2.1.x builds it, its config elsewhere; Codex with no transcript.
        feed("Stop", #"{"session_id":"s-2","transcript_path":"/h/other-config/projects/p/s-2.jsonl","cwd":\#(roots),"scratchpad_dir":"/tmp/x","permission_mode":"default","agent_type":"main","effort":"high","hook_event_name":"Stop","stop_hook_active":false}"#)
        feed("Stop", #"{"session_id":"x-1","transcript_path":null,"cwd":\#(roots),"hook_event_name":"Stop","model":"gpt-5","turn_id":"u-1"}"#, tool: "codex")
        #expect(spoolLines(dir).compactMap { JValue.parse($0)?["session_id"]?.string } == ["s-2", "x-1"])
    }

    @Test(.enabled(if: Sys.exists(zagonBin))) func binaryAlwaysExitsZeroSilently() throws {
        let tmp = makeTempDir()
        let file = tmp + "/plain-file"
        Sys.writeFile(file, [1])
        let full = tmp + "/full"
        Sys.mkdirs(full + "/spool")
        _ = symlink("/dev/full", full + "/spool/" + Sys.utcDay(Sys.now()) + ".ndjson")
        let cases: [([String], [UInt8], String)] = [
            (["hook", "claude", "Stop"], Array("not json at all \u{1}".utf8), tmp + "/a"),   // garbage
            (["hook", "claude", "Stop"], [], tmp + "/b"),                                   // empty stdin
            (["hook"], hookPayload, tmp + "/c"),                                            // no tool / event
            (["hook", "claude", "Stop", "--extra", "-x"], hookPayload, tmp + "/d"),         // unknown args
            (["hook", "claude", "Stop"], hookPayload, file + "/zagon"),                     // cannot create the dir
            (["hook", "claude", "Stop"], hookPayload, full),                                // disk full
            (["hook", "codex", "Stop"], Array("{\"a\":".utf8) + Array(repeating: 0x5B, count: 100_000), tmp + "/e"), // deep
        ]
        for (args, input, dir) in cases {
            let (rc, out) = try runZagon(args, stdin: input, env: ["ZAGON_DIR": dir, "PATH": "/usr/bin:/bin"])
            #expect(rc == 0, "\(args) \(dir)")
            #expect(out.isEmpty)
        }
        #expect(spoolLines(tmp + "/a").isEmpty)
        #expect(spoolLines(tmp + "/c").count == 1)
        // Missing directories are created and the line lands there.
        let (rc, _) = try runZagon(["hook", "claude", "UserPromptSubmit"], stdin: hookPayload,
                                   env: ["ZAGON_DIR": tmp + "/new/deep", "PATH": "/usr/bin:/bin"])
        #expect(rc == 0)
        let lines = spoolLines(tmp + "/new/deep")
        #expect(lines.count == 1)
        #expect(lines.first?.contains("\"event\":\"UserPromptSubmit\"") == true)
        #expect(lines.first?.contains("SECRET") == false)
    }
}

@Suite struct SpoolIngestTests {
    func hook(_ dir: String, _ tool: String, _ event: String, _ ts: Double, sid: String = "s1", extra: String = "") {
        let p = "{\"session_id\":\"\(sid)\",\"cwd\":\"/w\",\"hook_event_name\":\"\(event)\"\(extra)}"
        HookSpool.append(HookSpool.hookLine(tool: tool, event: event, payload: Array(p.utf8), ts: ts)!,
                         paths: ZagonPaths(home: dir, dir: dir), ts: ts)
    }

    func status(_ s: Store, _ id: String) throws -> (String?, Double?) {
        try s.db.one("SELECT status, status_at FROM session WHERE id = ?", [.text(id)]) { ($0.text(0), $0.optReal(1)) } ?? (nil, nil)
    }

    func waiting(_ s: Store, _ id: String) throws -> [[Double]] {
        var out: [[Double]] = []
        try s.db.query("SELECT start, \"end\" FROM activity WHERE session_id = ? AND kind = 'waiting' ORDER BY start",
                       [.text(id)]) { out.append([$0.real(0), $0.real(1)]) }
        return out
    }

    @Test func statusMapping() {
        let m: [(String, String, String?, String?)] = [
            ("claude", "UserPromptSubmit", nil, "working"), ("claude", "PermissionRequest", nil, "waiting_permission"),
            ("claude", "Notification", "idle_prompt", "waiting_input"),
            ("claude", "Notification", "permission_prompt", "waiting_permission"),
            ("claude", "Notification", "auth_success", nil), ("claude", "Stop", nil, "waiting_input"),
            ("claude", "SessionEnd", nil, "ended"), ("claude", "Interrupt", nil, nil),
            ("codex", "UserPromptSubmit", nil, "working"), ("codex", "PermissionRequest", nil, "waiting_permission"),
            ("codex", "Stop", nil, "waiting_input"), ("codex", "Interrupt", nil, "waiting_input"),
            ("codex", "SessionEnd", nil, "ended"), ("codex", "Notification", "idle_prompt", nil),
        ]
        for (tool, event, nt, want) in m {
            #expect(SpoolIngest.status(tool: tool, event: event, notificationType: nt, source: nil) == want, "\(tool) \(event)")
        }
        #expect(SpoolIngest.status(tool: "claude", event: "SessionStart", notificationType: nil, source: "compact") == nil)
    }

    @Test func statusesWaitingIntervalsAndOffsets() throws {
        let dir = makeTempDir(), store = try Store(path: ":memory:")
        let day = 1_761_800_000.0  // 2025-10-30 UTC
        hook(dir, "claude", "SessionStart", day + 100, extra: ",\"source\":\"startup\"")
        hook(dir, "claude", "UserPromptSubmit", day + 110)
        hook(dir, "claude", "PermissionRequest", day + 120)
        hook(dir, "claude", "PostToolUse", day + 130)
        hook(dir, "claude", "Stop", day + 140)
        hook(dir, "claude", "Notification", day + 200, extra: ",\"notification_type\":\"idle_prompt\"")
        hook(dir, "claude", "UserPromptSubmit", day + 90)  // older than what is stored: ignored
        hook(dir, "codex", "UserPromptSubmit", day + 150, sid: "t1")
        hook(dir, "codex", "Interrupt", day + 160, sid: "t1")
        HookSpool.append("{garbage", paths: ZagonPaths(home: dir, dir: dir), ts: day)
        let r = try SpoolIngest.run(store: store, spoolDir: dir + "/spool", now: day + 1000)
        #expect(r.lines == 10 && r.bad == 1 && r.statuses == 7)
        #expect(try status(store, "claude:s1") == ("waiting_input", day + 140))
        #expect(try status(store, "codex:t1") == ("waiting_input", day + 160))
        #expect(try store.db.one("SELECT cwd FROM session WHERE id = 'claude:s1'") { $0.text(0) } == "/w")
        #expect(try waiting(store, "claude:s1") == [[day + 100, day + 110], [day + 120, day + 130]])

        // Nothing new: nothing applied twice.
        #expect(try SpoolIngest.run(store: store, spoolDir: dir + "/spool", now: day + 1000) == SpoolIngest.Result())

        // A partial last line waits for its newline.
        let file = dir + "/spool/" + Sys.utcDay(day + 300) + ".ndjson"
        let end = HookSpool.hookLine(tool: "claude", event: "SessionEnd",
                                     payload: Array("{\"session_id\":\"s1\"}".utf8), ts: day + 300)!
        Sys.append(file, Array(end.utf8.prefix(20)))
        #expect(try SpoolIngest.run(store: store, spoolDir: dir + "/spool", now: day + 1000).lines == 0)
        Sys.append(file, Array(end.utf8.dropFirst(20)) + [0x0A])
        #expect(try SpoolIngest.run(store: store, spoolDir: dir + "/spool", now: day + 1000).statuses == 1)
        #expect(try status(store, "claude:s1") == ("ended", day + 300))
        #expect(try waiting(store, "claude:s1").last == [day + 140, day + 300])
    }

    @Test func limitsAndExpiry() throws {
        let dir = makeTempDir(), store = try Store(path: ":memory:")
        let t = 1_761_800_000.0
        func reading(_ pct: Double, _ ts: Double) {
            let input = "{\"session_id\":\"s\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(pct),\"resets_at\":1761810000},\"seven_day\":{\"used_percentage\":41}}}"
            HookSpool.append(StatusLine.limitsLine(Array(input.utf8), ts: ts)!.line, paths: ZagonPaths(home: dir, dir: dir), ts: ts)
        }
        reading(62.5, t); reading(62.5, t + 10); reading(63, t + 20); reading(63, t + 100)
        Sys.writeFile(dir + "/spool/2020-01-01.ndjson", Array("{}\n".utf8))
        let r = try SpoolIngest.run(store: store, spoolDir: dir + "/spool", now: t + 200)
        #expect(r.expired == 1 && !Sys.exists(dir + "/spool/2020-01-01.ndjson"))
        #expect(r.limits == 5)  // five_hour: 62.5, 63, 63 again after 60 s; seven_day: 41, again after 60 s
        let latest = try store.latestLimits()
        #expect(latest.map(\.window) == ["five_hour", "seven_day"])
        #expect(latest[0].usedPct == 63 && latest[0].resetsAt == 1_761_810_000 && latest[0].windowMinutes == 300)
        #expect(latest[1].usedPct == 41 && latest[1].resetsAt == nil && latest[1].windowMinutes == 10080)
    }
}

@Suite struct StatusLineTests {
    let input = Array("""
        {"session_id":"s","model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":61.6,"resets_at":1761810000},
        "seven_day":{"used_percentage":41,"resets_at":1762300000}},"workspace":{"current_dir":"/w"}}
        """.utf8)

    @Test func limitsLineHandlesMissingFields() throws {
        let l = try #require(StatusLine.limitsLine(input, ts: 2))
        #expect(l.text == "5h 62% · wk 41%")
        let v = try #require(JValue.parse(l.line))
        #expect(v["five_hour_pct"] == .number("61.6") && v["seven_day_resets_at"] == .number("1762300000"))
        #expect(StatusLine.limitsLine(Array("{\"session_id\":\"s\"}".utf8), ts: 2) == nil)
        #expect(StatusLine.limitsLine(Array("{\"rate_limits\":{}}".utf8), ts: 2) == nil)
        #expect(StatusLine.limitsLine(Array("{\"rate_limits\":{\"seven_day\":{\"used_percentage\":\"x\"}}}".utf8), ts: 2) == nil)
        #expect(StatusLine.limitsLine(Array("{\"rate_limits\":{\"seven_day\":{\"used_percentage\":7}}}".utf8), ts: 2)?.text == "wk 7%")
        #expect(StatusLine.limitsLine(Array("garbage".utf8), ts: 2) == nil)
    }

    @Test(.enabled(if: Sys.exists(zagonBin))) func internalRunsRecordNothing() throws {
        let dir = makeTempDir()
        Sys.writeFile(dir + "/config.toml", Array("[statusline]\noriginal_command = \"echo mine\"\n".utf8))
        let env = ["ZAGON_DIR": dir, "PATH": "/usr/bin:/bin", "ZAGON_INTERNAL": "1"]
        #expect(try runZagon(["hook", "claude", "UserPromptSubmit"], stdin: hookPayload, env: env) == (0, []))
        #expect(try runZagon(["statusline"], stdin: input, env: env) == (0, []))
        #expect(spoolLines(dir).isEmpty)
        // Any other value is a normal run.
        #expect(try runZagon(["hook", "claude", "Stop"], stdin: hookPayload, env: env.merging(["ZAGON_INTERNAL": "0"]) { $1 }).0 == 0)
        #expect(spoolLines(dir).count == 1)
    }

    @Test(.enabled(if: Sys.exists(zagonBin))) func wrapperPassesOriginalOutputThrough() throws {
        let dir = makeTempDir()
        let script = dir + "/my status.sh"
        // Echoes its stdin back, then bytes that are not UTF-8, colors, no final newline; exits non-zero.
        writeScript(script, "#!/bin/sh\ncat\nprintf '\\033[32m%s\\033[0m \\377 line2' \"$1\"\nexit 3\n")
        let cmd = Sys.shellQuote(script) + " 'arg one'"
        Sys.writeFile(dir + "/config.toml", Array("[statusline]\noriginal_command = \(TOMLLite.quote(cmd))\n".utf8))
        let env = ["ZAGON_DIR": dir, "PATH": "/usr/bin:/bin"]
        let direct = try shell(cmd, stdin: input)
        let (rc, out) = try runZagon(["statusline"], stdin: input, env: env)
        #expect(out == direct)
        #expect(out.count > input.count)
        #expect(rc == 3)
        #expect(spoolLines(dir).count == 1)

        // No original command: own short line.
        Sys.writeFile(dir + "/config.toml", [])
        #expect(try runZagon(["statusline"], stdin: input, env: env).1 == Array("Opus · 5h 62% · wk 41%\n".utf8))
        // No limits in the input (API key users, first render): a short line all the same, nothing spooled.
        #expect(try runZagon(["statusline"], stdin: Array("{\"model\":{\"display_name\":\"Opus\"}}".utf8), env: env).1
                == Array("Opus\n".utf8))
        #expect(try runZagon(["statusline"], stdin: Array("{}".utf8), env: env).1 == Array("zagon\n".utf8))
        #expect(spoolLines(dir).count == 1)  // the same reading again within a minute is not spooled

        // The saved command calls the wrapper again: no loop.
        Sys.writeFile(dir + "/config.toml", Array("[statusline]\noriginal_command = \(TOMLLite.quote(zagonBin + " statusline"))\n".utf8))
        #expect(try runZagon(["statusline"], stdin: input, env: env) == (0, Array("Opus · 5h 62% · wk 41%\n".utf8)))
    }
}
