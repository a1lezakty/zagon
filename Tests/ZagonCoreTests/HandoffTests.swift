import Foundation
import Testing
@testable import ZagonCore

/// Secret-looking strings are assembled at run time, so the repository's push guard never sees a literal token.
private let pat = "github" + "_pat_" + "11ABCDEFG0" + String(repeating: "aB3", count: 20)
private let secrets: [(input: String, secret: String)] = [
    ("export GH=\(pat)", pat),
    ("ghp_" + "Ab3dEf6hIj9lMn2pQr5tUv8xYz1bCd4fGh7j", "Ab3dEf6hIj9lMn2pQr5tUv8xYz1bCd4fGh7j"),
    ("key " + "sk-" + "ant-" + "api03-Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Jh1Gf0", "api03-Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Jh1Gf0"),
    ("OPENAI " + "sk-" + "proj-Qw1Er2Ty3Ui4Op5As6Df7Gh8Jk9Lz0", "Qw1Er2Ty3Ui4Op5As6Df7Gh8Jk9Lz0"),
    ("slack " + "xo" + "xb-1234567890-1234567890123-AbCdEfGhIjKlMnOp", "1234567890123-AbCdEfGhIjKlMnOp"),
    ("aws AKIA" + "IOSFODNN7EXAMPL3 there", "IOSFODNN7EXAMPL3"),
    ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "dozjgNryP4J3jVmNHl0w5N"),
    ("-----BEGIN " + "RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1x2y3z\nqwerty\n-----END RSA PRIVATE KEY-----", "MIIEowIBAAKCAQEA1x2y3z"),
    ("cut -----BEGIN " + "OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA", "b3BlbnNzaC1rZXktdjEAAAAA"),
    ("password=hunter2xyz done", "hunter2xyz"),
    ("DB_PASSWORD: 'Sup3r$ecret!'", "Sup3r$ecret!"),
    (#"{"api_key": "abcd1234efgh5678"}"#, "abcd1234efgh5678"),
    ("curl -H 'x-api-key: kq83jd9a0s' url", "kq83jd9a0s"),
    ("token=deadbeefcafebabe1234&x=1", "deadbeefcafebabe1234"),
    ("client_secret = s3cr3t-value", "s3cr3t-value"),
    ("Authorization: Bearer abcDEF123456ghiJKL789", "abcDEF123456ghiJKL789"),
    ("postgres://admin:Pa55word@db.local/x", "Pa55word"),
    ("the signing key is 3q2+7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "3q2+7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
    ("pasted Zk3mQ9xL2pR7vT1wY8sB4nC6hJ0dF5gA3eK9uM2q here", "Zk3mQ9xL2pR7vT1wY8sB4nC6hJ0dF5gA3eK9uM2q"),
    ("DB_PASSWORD=12345678", "12345678"),
    (#"password: "correct horse battery"#, "horse battery"),                      // cut before the closing quote
    (#"curl -d "{\"user\":\"a\",\"password\":\"hunter2\"}""#, "hunter2"),           // escaped JSON
    ("gitlab glpat-" + "Ab1Cd2Ef3Gh4Ij5Kl6Mn", "Ab1Cd2Ef3Gh4Ij5Kl6Mn"),
    ("maps AIza" + "SyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q", "SyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q"),
    ("x " + String(repeating: "3f9a", count: 16), String(repeating: "3f9a", count: 16)),
    (#""password": "correct horse battery staple""#, "horse battery"),
    ("secret=987654", "987654"),
    ("url x:ghp_" + "Ab3dEf6hIj9lMn2pQr5tUv8xYz1bCd4fGh7j", "Ab3dEf6hIj9lMn2pQr5tUv8xYz1bCd4fGh7j"),
    ("foo." + "sk-" + "Qw1Er2Ty3Ui4Op5As6Df7Gh8Jk9Lz0", "Qw1Er2Ty3Ui4Op5As6Df7Gh8Jk9Lz0"),
]

private func write(_ lines: [String], _ path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: false, encoding: .utf8)
}

private func sections(_ md: String) -> [String] {
    md.split(separator: "\n").filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
}

@Suite struct RedactTests {
    @Test func noSecretSurvives() {
        for (input, secret) in secrets {
            let out = Redact.clean(input)
            #expect(!out.contains(secret), "\(input.prefix(12))…")
            #expect(out.contains(Redact.mark))
        }
        // and all of them inside one text
        let all = Redact.clean(secrets.map(\.input).joined(separator: "\n"))
        #expect(secrets.allSatisfy { !all.contains($0.secret) })
    }

    @Test func ordinaryTextStays() {
        for s in ["total_tokens: 14264", "Sources/ZagonCore/Codex/CodexSource.swift:42", "a token count of 5",
                  "codex resume 019b9f0c-3cb8-7072-8510-e948f3b3984b", "git: main@1cc2711", "basic setup works",
                  "/home/user/zagon/Tests/ZagonCoreTests/HandoffTests.swift", "max_tokens=4096",
                  "cd /home/u/key-management-service/backend-api/x"] {
            #expect(Redact.clean(s) == s)
        }
    }

    @Test func sensitiveFiles() {
        for p in [".env", "app/.env.local", "certs/server.pem", "~/.ssh/id_ed25519", "tls.key", ".netrc"] {
            #expect(Redact.isSensitivePath(p))
        }
        for p in ["main.swift", "identity.swift", "docs/env.md", "keyboard.swift"] { #expect(!Redact.isSensitivePath(p)) }
        #expect(Redact.mentionsSensitiveFile("cat app/.env | grep X"))
        #expect(!Redact.mentionsSensitiveFile("swift test --filter Env"))
    }
}

@Suite struct HandoffBuildTests {
    let dir = makeTempDir()
    var cwd: String { dir + "/work/app" }

    func claudeLog(id: String) -> String {
        let path = dir + "/claude/-work-app/\(id).jsonl"
        func rec(_ type: String, _ ts: String, _ content: String, extra: String = "") -> String {
            #"{"type":"\#(type)","timestamp":"2026-10-30T10:\#(ts)Z","cwd":"\#(cwd)","gitBranch":"PROJ-7-login","sessionId":"\#(id)"\#(extra),"message":{"role":"\#(type)","content":\#(content)}}"#
        }
        write([
            #"{"type":"custom-title","customTitle":"Login bug","sessionId":"\#(id)"}"#,
            rec("user", "00:00", #""Fix the login bug, my token=abc123secretvalue9""#),
            rec("user", "00:01", #""<system-reminder>injected</system-reminder>""#, extra: #","isMeta":true"#),
            rec("assistant", "00:02", #"[{"type":"text","text":"I will look at auth.swift first."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"\#(cwd)/Sources/auth.swift","old_string":"a","new_string":"b"}}]"#),
            rec("user", "00:03", #"[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]"#,
                extra: #","toolUseResult":{"filePath":"\#(cwd)/Sources/auth.swift","structuredPatch":[{"oldStart":40,"oldLines":3,"newStart":42,"newLines":3,"lines":[]}]}"#),
            rec("assistant", "00:04", #"[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cat .env"}}]"#),
            rec("user", "00:05", #"[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Exit code 1\nDB_PASSWORD=supersecret"}]"#),
            rec("assistant", "00:06", #"[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift test"}}]"#),
            rec("user", "00:07", #"[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"Exit code 1\nerror: build failed at X.swift:3\nmore"}]"#),
            rec("assistant", "00:08", #"[{"type":"tool_use","id":"t4","name":"TodoWrite","input":{"todos":[{"content":"Add a test","status":"pending","activeForm":"x"},{"content":"Fix bug","status":"completed","activeForm":"x"},{"content":"Run CI","status":"in_progress","activeForm":"x"}]}}]"#),
            rec("assistant", "00:09", #"[{"type":"text","text":"SIDECHAIN talk"}]"#, extra: #","isSidechain":true"#),
            rec("user", "00:10", #""now also update the docs""#),
            rec("assistant", "00:11", #"[{"type":"text","text":"Done with the fix. Next I would update README."}]"#),
            #"{"type":"assistant","truncated":"#, // a cut line is skipped
        ], path)
        return path
    }

    @Test func claudeSessionHandoff() {
        let id = "11111111-2222-3333-4444-555555555555"
        let d = SessionDigest.read(tool: .claude, id: id, path: claudeLog(id: id))
        let doc = Handoff.build([d], git: Handoff.Git(branch: "PROJ-7-login", sha: "abc1234", changed: ["Sources/auth.swift"]))
        let md = doc.markdown
        #expect(doc.name == "claude-" + id && doc.cwd == cwd)
        #expect(md.hasPrefix("handoff: v1 | from: claude | session: \(id) | cwd: \(cwd) | git: PROJ-7-login@abc1234\n"))
        #expect(sections(md) == ["Goal", "Decisions", "Current state", "Files", "Open problems", "Next steps", "How to continue"])
        #expect(md.hasSuffix(Handoff.footer + "\n"))
        #expect(md.split(separator: "\n")[1] == Handoff.framing)
        #expect(md.contains("Title: Login bug"))
        #expect(md.contains("- Fix the login bug, my token=[redacted]"))
        #expect(md.contains("- now also update the docs")) // the latest request is one of the first two
        #expect(md.contains("- I will look at auth.swift first."))
        #expect(md.contains("Done with the fix. Next I would update README."))
        #expect(md.contains("Uncommitted: Sources/auth.swift"))
        #expect(md.contains("- Sources/auth.swift:42"))
        #expect(md.contains("- Bash: error: build failed at X.swift:3"))
        #expect(md.contains("- Bash: (output of a call on a sensitive file omitted)"))
        #expect(md.contains("- [pending] Add a test") && md.contains("- [in progress] Run CI") && !md.contains("Fix bug"))
        #expect(md.contains("cd \(cwd)\ngit checkout PROJ-7-login\nclaude --resume \(id)\n"))
        for leak in ["abc123secretvalue9", "supersecret", "SIDECHAIN", "injected"] { #expect(!md.contains(leak), "\(leak)") }
    }

    @Test func codexSessionHandoff() {
        let id = "019a0000-1111-2222-3333-444455556666"
        let path = dir + "/codex/sessions/2026/10/30/rollout-2026-10-30T10-00-00-\(id).jsonl"
        func line(_ ts: String, _ type: String, _ payload: String) -> String {
            #"{"timestamp":"2026-10-30T10:\#(ts).000Z","type":"\#(type)","payload":\#(payload)}"#
        }
        write([
            line("00:00", "session_meta", #"{"id":"\#(id)","cwd":"\#(cwd)","git":{"branch":"feat-x"}}"#),
            line("00:01", "event_msg", #"{"type":"task_started","turn_id":"t1"}"#),
            line("00:02", "event_msg", #"{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"Port the parser"}]}}"#),
            line("00:03", "response_item", #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Plan: port it step by step."}]}"#),
            line("00:04", "response_item", #"{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Port\",\"status\":\"in_progress\"},{\"step\":\"Test\",\"status\":\"pending\"},{\"step\":\"Read\",\"status\":\"completed\"}]}","call_id":"p1"}"#),
            line("00:05", "response_item", #"{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: src/a.rs\n@@\n-x\n+y\n*** Add File: src/b.rs\n+z\n*** End Patch","call_id":"c0"}"#),
            line("00:06", "response_item", #"{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cargo test\"}","call_id":"c1"}"#),
            line("00:07", "response_item", #"{"type":"function_call_output","call_id":"c1","output":"Chunk ID: 1\nWall time: 1\nProcess exited with code 101\nOriginal token count: 3\nOutput:\nerror[E0425]: cannot find value `q`\n"}"#),
            line("00:08", "response_item", #"{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"ls\"}","call_id":"c2"}"#),
            line("00:09", "response_item", #"{"type":"function_call_output","call_id":"c2","output":"Process exited with code 0\nOutput:\nerror-looking file name\n"}"#),
            line("00:10", "response_item", #"{"type":"custom_tool_call_output","call_id":"c0","output":"{\"output\":\"patch rejected\",\"metadata\":{\"exit_code\":1}}"}"#),
            line("00:11", "response_item", #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Tests fail on q."}]}"#),
        ], path)
        let d = SessionDigest.read(tool: .codex, id: id, path: path)
        let md = Handoff.build([d]).markdown
        #expect(md.hasPrefix("handoff: v1 | from: codex | session: \(id) | cwd: \(cwd) | git: feat-x@?\n"))
        #expect(md.contains("- Port the parser") && md.contains("Tests fail on q."))
        #expect(md.contains("- src/b.rs:1\n- src/a.rs\n"))
        #expect(md.contains("- exec_command: error[E0425]: cannot find value `q`"))
        #expect(md.contains("- apply_patch: patch rejected"))
        #expect(!md.contains("error-looking"))
        #expect(md.contains("- [in progress] Port\n- [pending] Test\n"))
        #expect(md.contains("codex resume \(id)"))
    }

    @Test func budgetOnAHugeSession() {
        let id = "22222222-2222-3333-4444-555555555555"
        var lines: [String] = []
        let long = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 60)
        for i in 0..<300 {
            let ts = String(format: "%02d:%02d", i / 60, i % 60)
            lines.append(#"{"type":"user","timestamp":"2026-10-30T11:\#(ts)Z","cwd":"\#(cwd)","message":{"role":"user","content":"Request \#(i): \#(long)"}}"#)
            lines.append(#"{"type":"assistant","timestamp":"2026-10-30T11:\#(ts)Z","cwd":"\#(cwd)","message":{"role":"assistant","content":[{"type":"text","text":"Answer \#(i): \#(long)"},{"type":"tool_use","id":"e\#(i)","name":"Write","input":{"file_path":"\#(cwd)/f\#(i).swift"}}]}}"#)
            lines.append(#"{"type":"user","timestamp":"2026-10-30T11:\#(ts)Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"e\#(i)","is_error":true,"content":"failure number \#(i) \#(long)"}]}}"#)
        }
        let path = dir + "/claude/-big/\(id).jsonl"
        write(lines, path)
        let md = Handoff.build([SessionDigest.read(tool: .claude, id: id, path: path)]).markdown
        #expect(md.utf8.count <= Handoff.targetBytes)
        #expect(Handoff.estimatedTokens(md) >= 1500 && Handoff.estimatedTokens(md) <= 2500)
        #expect(sections(md).count == 7 && md.hasSuffix(Handoff.footer + "\n"))
        #expect(md.contains("Latest requests:\n") && md.contains("- Request 299: Lorem"))
        #expect(Redact.clean(cwd) == cwd) // a temp path with a UUID is not a secret
    }

    @Test func secretsOnTheCutAndBashModeNeverLeak() {
        let id = "44444444-2222-3333-4444-555555555555", tok = "ghp_" + "Ab3dEf6hIj9lMn2pQr5tUv8xYz1bCd4fGh7j"
        let path = dir + "/claude/-cut/\(id).jsonl"
        func u(_ ts: String, _ content: String) -> String {
            #"{"type":"user","timestamp":"2026-10-30T12:\#(ts)Z","cwd":"\#(cwd)","message":{"role":"user","content":\#(content)}}"#
        }
        let pad = String(repeating: "x", count: SessionDigest.textCap - 10)
        write([
            u("00:00", #""\#(pad) \#(tok)""#),                                    // over the 2,500 display cut
            u("00:01", #""<bash-input>cat .env</bash-input>""#),
            u("00:02", #""<bash-stdout>STRIPE=rk_live_shortseg</bash-stdout><bash-stderr></bash-stderr>""#),
            #"{"type":"assistant","timestamp":"2026-10-30T12:00:03Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make"}}]}}"#,
            u("00:04", #"[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"\#(String(repeating: "y", count: 490)) \#(tok)"}]"#),
        ], path)
        let md = Handoff.build([SessionDigest.read(tool: .claude, id: id, path: path)]).markdown
        #expect(!md.contains("Ab3dEf6hIj9l") && !md.contains("rk_live"))
        #expect(md.contains("- !cat .env"))

        // a PEM block shrinks to [redacted] by more than the overshoot: the raw cut must not leave a token prefix
        let pem = "-----BEGIN " + "RSA PRIVATE KEY-----\\n" + String(repeating: "QUJD", count: 500) + "\\n-----END RSA PRIVATE KEY-----"
        let id2 = "66666666-2222-3333-4444-555555555555", path2 = dir + "/claude/-cut/\(id2).jsonl"
        // the token starts 10 characters before the raw cut (the decoded PEM has two newlines instead of `\\n`)
        let fillLen = SessionDigest.textCap + SessionDigest.overshoot - 10 - (pem.count - 2) - 1
        let fill = String(String(repeating: "word ", count: fillLen / 5 + 1).prefix(fillLen - 1)) + " "
        write([u("01:00", #""\#(pem) \#(fill)\#(tok)""#),
               #"{"type":"assistant","timestamp":"2026-10-30T12:01:01Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"aws s3 ls"}}]}}"#,
               u("01:02", #"[{"type":"tool_result","tool_use_id":"t9","is_error":true,"content":"Exit code 1\n\u001b[1mAKIA\#("IOSFODNN7EXAMPL3")\u001b[0m denied"}]"#),
               u("01:03", #""<local-command-stdout>Total cost: $1.20</local-command-stdout>""#)], path2)
        let md2 = Handoff.build([SessionDigest.read(tool: .claude, id: id2, path: path2)]).markdown
        #expect(!md2.contains("ghp_") && !md2.contains("QUJDQUJD") && !md2.contains("IOSFODNN7"))
        #expect(!md2.contains("\u{1B}") && !md2.contains("Total cost"))
    }

    @Test func codexPatchOnSensitiveFileHidesItsError() {
        let id = "019a0000-1111-2222-3333-777755556666"
        let path = dir + "/codex/sessions/2026/10/30/rollout-2026-10-30T12-00-00-\(id).jsonl"
        write([
            #"{"timestamp":"2026-10-30T12:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#,
            #"{"timestamp":"2026-10-30T12:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: .env\n@@\n-A=1\n+A=2\n*** End Patch","call_id":"c1"}}"#,
            #"{"timestamp":"2026-10-30T12:00:02Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"{\"output\":\"Failed to find expected lines in .env: DB_URL=abc\",\"metadata\":{\"exit_code\":1}}"}}"#,
        ], path)
        let md = Handoff.build([SessionDigest.read(tool: .codex, id: id, path: path)]).markdown
        #expect(md.contains("- apply_patch: (output of a call on a sensitive file omitted)"))
        #expect(md.contains("- .env\n") && !md.contains("DB_URL"))
    }

    @Test func noiseIsNotTheGoalAndTheStartCwdWins() {
        let id = "55555555-2222-3333-4444-555555555555"
        let path = dir + "/claude/-noise/\(id).jsonl"
        func rec(_ type: String, _ ts: String, _ c: String, cwd: String? = nil, extra: String = "") -> String {
            #"{"type":"\#(type)","timestamp":"2026-10-30T13:\#(ts)Z","cwd":"\#(cwd ?? self.cwd)","gitBranch":"feat"\#(extra),"message":{"role":"\#(type)","content":\#(c)}}"#
        }
        write([
            rec("user", "00:00", #""<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>""#),
            rec("user", "00:01", #""Implement the cache layer please""#),
            rec("assistant", "00:02", #"[{"type":"text","text":"Starting on the cache."}]"#),
            rec("user", "00:03", #"[{"type":"text","text":"[Request interrupted by user for tool use]"}]"#),
            rec("assistant", "00:04", #"[{"type":"text","text":"Cache layer is in place; tests pass."}]"#, cwd: cwd + "/sub"),
            rec("user", "00:05", #""<command-name>/compact</command-name><command-args>keep the cache notes</command-args>""#, cwd: cwd + "/sub"),
            rec("assistant", "00:06", #"[{"type":"text","text":"You've hit your usage limit"}]"#, cwd: cwd + "/sub",
                extra: #","isApiErrorMessage":true"#),
        ], path)
        let d = SessionDigest.read(tool: .claude, id: id, path: path)
        let md = Handoff.build([d]).markdown
        #expect(d.cwd == cwd)
        #expect(md.contains("## Goal\n- Implement the cache layer please\n- /compact keep the cache notes\n"))
        #expect(!md.contains("/clear") && !md.contains("interrupted") && !md.contains("usage limit"))
        #expect(md.contains("## Current state\nCache layer is in place; tests pass."))
        #expect(md.contains("## Decisions\n- Starting on the cache.\n"))
    }

    @Test func latestPrefersTheCurrentDirectory() throws {
        let claude = dir + "/claude-latest"
        write([#"{"type":"user","message":{"content":"a"}}"#], claude + "/" + Handoff.claudeProjectDir(cwd) + "/here.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)],
                                              ofItemAtPath: claude + "/" + Handoff.claudeProjectDir(cwd) + "/here.jsonl")
        write([#"{"type":"user","message":{"content":"b"}}"#], claude + "/-elsewhere/there.jsonl")
        #expect(Handoff.find("latest", claudeDir: claude, codexHome: dir + "/none", cwd: cwd)?.1 == "here")
        #expect(Handoff.find("latest", claudeDir: claude, codexHome: dir + "/none", cwd: "/nowhere")?.1 == "there")
        #expect(Handoff.claudeProjectDir("/home/user/zagon-codex") == "-home-user-zagon-codex")
    }

    @Test func taskHandoffAndFind() throws {
        let a = "33333333-2222-3333-4444-555555555555", b = "019a0000-1111-2222-3333-444455556666"
        _ = claudeLog(id: a)
        codexSessionHandoff()  // writes the Codex rollout of `b`
        let doc = try Handoff.create(["claude:" + a, b], task: "PROJ-7", claudeDir: dir + "/claude", codexHome: dir + "/codex")
        #expect(doc.name == "task-PROJ-7")
        #expect(doc.markdown.hasPrefix("handoff: v1 | from: claude, codex | task: PROJ-7 | sessions: \(a), \(b) | cwd: \(cwd)"))
        #expect(doc.markdown.contains("claude --resume \(a)\ncodex resume \(b)\n"))
        #expect(Handoff.find("../etc/passwd", claudeDir: dir + "/claude", codexHome: dir + "/codex") == nil)
        #expect(Handoff.find("codex:" + a, claudeDir: dir + "/claude", codexHome: dir + "/codex") == nil)
        #expect(throws: Handoff.Failure.self) {
            try Handoff.create(["nope"], claudeDir: dir + "/claude", codexHome: dir + "/codex")
        }
    }
}

@Suite struct HandoffHookTests {
    let dir = makeTempDir()

    func payload(_ cwd: String, source: String = "startup") -> [UInt8] {
        Array(#"{"session_id":"s1","cwd":"\#(cwd)","hook_event_name":"SessionStart","source":"\#(source)"}"#.utf8)
    }

    @Test func pendingHandoffIsAddedOnce() throws {
        let store = HandoffStore(paths: ZagonPaths(home: dir, dir: dir + "/.zagon"))
        let cwd = dir + "/proj"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let md = "handoff: v1 | from: claude\n\n## Goal\n- \"quoted\" and\ttabs\n\n" + Handoff.footer + "\n"
        #expect(store.save(Handoff.Document(name: "claude-x", markdown: md, cwd: cwd)) != nil)
        #expect(store.markPending("claude-x", cwd: cwd + "/"))
        #expect(store.list().map(\.waitingIn) == [Sys.realPath(cwd)])  // macOS: /var is /private/var
        #expect(store.sessionStart(payload: payload(cwd, source: "resume")) == nil) // the same conversation goes on
        #expect(store.sessionStart(payload: payload(dir)) == nil)                   // another directory
        let out = try #require(store.sessionStart(payload: payload(cwd)))
        let j = try #require(JValue.parse(out))
        #expect(j["hookSpecificOutput"]?["hookEventName"]?.string == "SessionStart")
        #expect(j["hookSpecificOutput"]?["additionalContext"]?.string == md)
        #expect(store.sessionStart(payload: payload(cwd)) == nil) // used
        #expect(store.list().map(\.waitingIn) == [nil])
        #expect(store.get("claude-x") == md && store.get("../x") == nil)

        // a handoff left waiting for days is not pushed into an unrelated session
        #expect(store.markPending("claude-x", cwd: cwd))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -HandoffStore.pendingTTL - 60)],
                                              ofItemAtPath: store.dir + "/pending/" + HandoffStore.key(HandoffStore.norm(cwd)))
        #expect(store.sessionStart(payload: payload(cwd)) == nil)
    }

    @Test func hookJSONStaysUnderTheLimit() throws {
        let md = String(repeating: "строка с \"кавычками\" и\n", count: 2000) + Handoff.footer + "\n"
        let out = HandoffStore.hookJSON(md)
        #expect(out.utf16.count <= Handoff.hookLimit)
        let ctx = try #require(JValue.parse(out)?["hookSpecificOutput"]?["additionalContext"]?.string)
        #expect(ctx.hasSuffix(Handoff.footer + "\n") && ctx.utf16.count <= Handoff.hookLimit)
    }

    @Test(.enabled(if: Sys.exists(zagonBin))) func binaryPrintsOnlyAPendingHandoff() throws {
        let cwd = dir + "/p2"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let env = ["HOME": dir, "ZAGON_DIR": dir + "/.zagon", "PATH": "/usr/bin:/bin"]
        #expect(try runZagon(["hook", "claude", "SessionStart"], stdin: payload(cwd), env: env) == (0, []))
        let store = HandoffStore(paths: ZagonPaths(home: dir, dir: dir + "/.zagon"))
        store.save(Handoff.Document(name: "codex-y", markdown: "handoff: v1\n" + Handoff.footer + "\n", cwd: cwd))
        store.markPending("codex-y", cwd: cwd)
        let (rc, out) = try runZagon(["hook", "claude", "SessionStart"], stdin: payload(cwd), env: env)
        #expect(rc == 0 && JValue.parse(out) != nil)
        #expect(try runZagon(["hook", "claude", "SessionStart"], stdin: payload(cwd), env: env) == (0, []))
        #expect(try runZagon(["hook", "codex", "SessionStart"], stdin: payload(cwd), env: env) == (0, []))
    }
}

@Suite struct HandoffDeliveryTests {
    let dir = makeTempDir()
    static let md = "handoff: v1 | from: claude | session: s\n\n## Goal\n- it's \"x\" $HOME `y`\n\n" + Handoff.footer + "\n"

    @Test func aiResultIsCheckedAndRedacted() throws {
        let stub = dir + "/claude"
        #expect(writeScript(stub, "#!/bin/sh\ncat > /dev/null\nprintf %s \"$ZAGON_INTERNAL\" > \"$0.env\"\n"
                                  + "printf '%s' '{\"result\":\"## Goal\\n- short, token=abcdefgh12345678\"}'\n"))
        let out = try #require(Handoff.compress(Self.md, tool: "claude", runDir: dir + "/run", bin: stub))
        #expect(out.hasPrefix("handoff: v1 | from: claude | session: s\n" + Handoff.framing + "\n\n## Goal\n- short, token=[redacted]"))
        #expect(out.hasSuffix(Handoff.footer + "\n"))
        #expect(Sys.readFile(stub + ".env") == Array("1".utf8)) // its hooks write no spool line
        let bad = dir + "/bad"
        #expect(writeScript(bad, "#!/bin/sh\nexit 3\n"))
        #expect(Handoff.compress(Self.md, tool: "claude", runDir: dir + "/run", bin: bad) == nil)
        #expect(Handoff.compress(Self.md, tool: "codex", runDir: dir + "/run", bin: bad) == nil)
    }

    @Test func codexRunsWithoutTheUsersConfigInAReadOnlySandbox() throws {
        // records its arguments (NUL-separated) and ZAGON_INTERNAL, answers through the -o file
        let stub = dir + "/codex"
        #expect(writeScript(stub, """
            #!/bin/sh
            printf '%s\\0' "$@" > "$0.argv"; printf %s "$ZAGON_INTERNAL" > "$0.env"; cat > /dev/null
            while [ $# -gt 0 ]; do [ "$1" = -o ] && printf '## Goal\\n- short\\n' > "$2"; shift; done

            """))
        let run = dir + "/run"
        let out = try #require(Handoff.compress(Self.md, tool: "codex", runDir: run, bin: stub))
        #expect(out.contains("\n## Goal\n- short\n") && out.hasSuffix(Handoff.footer + "\n"))
        let argv = try #require(Sys.readFile(stub + ".argv")).split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        #expect(argv == ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "-c", "features.hooks=false",
                         "-s", "read-only", "-C", run, "-o", run + "/codex-last-\(getpid()).txt", Handoff.aiPrompt, ""])
        #expect(Sys.readFile(stub + ".env") == Array("1".utf8))
        #expect(!Sys.exists(run + "/codex-last-\(getpid()).txt"))
    }

    @Test func anAIThatHangsIsKilledAtTheTimeout() throws {
        let stub = dir + "/hang"
        #expect(writeScript(stub, "#!/bin/sh\ncat > /dev/null\nsleep 30\n"))
        for tool in ["claude", "codex"] {
            let t0 = Sys.now()
            #expect(Handoff.compress(Self.md, tool: tool, runDir: dir + "/run", bin: stub, timeout: 1) == nil)
            #expect(Sys.now() - t0 < 10, "\(tool) was not stopped at the timeout")
        }
    }

    @Test func cursorAgentsAndShellQuoting() throws {
        let p = try #require(Handoff.cursorRule(Self.md, cwd: dir))
        let rule = try String(contentsOfFile: p, encoding: .utf8)
        #expect(p == dir + "/.cursor/rules/zagon-handoff.mdc" && rule.contains("\nalwaysApply: true\n---\n\n" + Self.md))

        try "# Project\n\nRules.\n".write(toFile: dir + "/AGENTS.md", atomically: false, encoding: .utf8)
        #expect(Handoff.agentsPointer(cwd: dir, handoffPath: "/h/a.md"))
        #expect(Handoff.agentsPointer(cwd: dir, handoffPath: "/h/b.md"))
        let agents = try String(contentsOfFile: dir + "/AGENTS.md", encoding: .utf8)
        #expect(agents.hasPrefix("# Project\n\nRules.\n\n<!-- zagon-handoff --> Previous session handoff: /h/b.md"))
        #expect(agents.components(separatedBy: "zagon-handoff").count == 2)

        // a repository that ships symlinks out of the project gets nothing written through them
        let evil = makeTempDir(), outside = evil + "/outside.txt"
        try "keep".write(toFile: outside, atomically: false, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: evil + "/repo/.cursor/rules", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: evil + "/repo/.cursor/rules/zagon-handoff.mdc", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: evil + "/repo/AGENTS.md", withDestinationPath: outside)
        #expect(Handoff.cursorRule(Self.md, cwd: evil + "/repo") == nil)
        #expect(!Handoff.agentsPointer(cwd: evil + "/repo", handoffPath: "/h/c.md"))
        #expect(try String(contentsOfFile: outside, encoding: .utf8) == "keep")
        // …nor through a planted temp file next to it, nor into a symlinked .cursor
        try FileManager.default.createDirectory(atPath: evil + "/r2/.cursor/rules", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: evil + "/r2/.cursor/rules/zagon-handoff.mdc.zagon-tmp", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: evil + "/r2/AGENTS.md.zagon-tmp", withDestinationPath: outside)
        #expect(Handoff.cursorRule(Self.md, cwd: evil + "/r2") != nil)
        #expect(Handoff.agentsPointer(cwd: evil + "/r2", handoffPath: "/h/d.md"))
        #expect(try String(contentsOfFile: outside, encoding: .utf8) == "keep")
        try FileManager.default.createDirectory(atPath: evil + "/r3", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: evil + "/r3/.cursor", withDestinationPath: evil + "/elsewhere")
        #expect(Handoff.cursorRule(Self.md, cwd: evil + "/r3") == nil && !FileManager.default.fileExists(atPath: evil + "/elsewhere"))

        let back = try shell("printf %s " + Sys.shellQuote(Self.md), stdin: [])
        #expect(String(decoding: back, as: UTF8.self) == Self.md)
        let osc = Handoff.osc52(Self.md)
        #expect(osc.hasPrefix("\u{1B}]52;c;") && osc.hasSuffix("\u{07}"))
        #expect(Data(base64Encoded: String(osc.dropFirst(7).dropLast())) == Data(Self.md.utf8))
    }
}
