import Foundation
import Testing
@testable import ZagonCore

/// Feeds complete lines (a partial last line is held back, like Ingest does) to a Codex parser.
private func parse(_ text: String, rel: String = "rollout-2026-01-01T00-00-00-00000000-0000-0000-0000-000000000001.jsonl",
                   state: String? = nil) -> (ParseOutput, String?) {
    var p = CodexParser(relativePath: rel, state: state)
    var out = ParseOutput()
    var bytes = Array(text.utf8)
    if let nl = bytes.lastIndex(of: 0x0A) { bytes.removeSubrange((nl + 1)...) } else { bytes = [] }
    var start = 0
    for (i, b) in bytes.enumerated() where b == 0x0A {
        bytes[start..<i].withUnsafeBytes { p.parse(line: $0, into: &out) }
        start = i + 1
    }
    return (out, p.saveState())
}

private let home = Bundle.module.resourcePath! + "/Fixtures/codex/home"

private func fixture(_ idSuffix: String) throws -> (String, String) {
    let e = FileManager.default.enumerator(atPath: home)!
    while let rel = e.nextObject() as? String {
        if rel.hasSuffix(idSuffix + ".jsonl") { return (rel, try String(contentsOfFile: home + "/" + rel, encoding: .utf8)) }
    }
    throw CocoaError(.fileNoSuchFile)
}

private func byModel(_ u: [UsageRecord]) -> [String: Int] { u.reduce(into: [:]) { $0[$1.model, default: 0] += $1.total } }

@Suite struct CodexParserTests {
    // Sanitized real rollouts; expected totals = `threads.tokens_used` of the original threads.
    @Test(arguments: [
        ("e948f3b3984b", ["gpt-5.2-codex": 1_302_360], 46, 16, 62),
        ("a2af923175a1", ["gpt-5.4": 5_909_214, "gpt-5.3-codex": 19_137_690], 227, 51, 184),
        ("5f04da6fae8a", ["gpt-5.4": 1_058_452], 42, 8, 22),
        ("6fd374aa651e", ["gpt-5.6-sol": 14_264], 0, 1, 1), // CLI 0.166 `exec`: ordinal, token_usage_record, world_state
    ])
    func realMainThreads(id: String, tokens: [String: Int], tools: Int, msgs: Int, requests: Int) throws {
        let (rel, text) = try fixture(id)
        let (out, _) = parse(text, rel: rel)
        #expect(out.badLines == 0)
        #expect(byModel(out.usage) == tokens)
        #expect(out.usage.count == requests)
        #expect(out.tools.count == tools)
        #expect(out.userMessages.count == msgs)
        #expect(out.usage.allSatisfy { $0.sessionId == "codex:" + rel.suffix(42).prefix(36) })
        #expect(out.usage.allSatisfy { $0.agent == "" && $0.messageId == nil })
        #expect(out.meta.first?.cwd == "/work/p1")
        #expect(!out.events.isEmpty)
        #expect(out.events.allSatisfy { $0.ts >= out.userMessages[0].ts }) // injected context is not agent activity
        #expect(Set(out.limits.map(\.window)) == ["primary", "secondary"])
        #expect(out.limits.first { $0.window == "primary" }?.windowMinutes == 300)
        #expect(out.limits.first { $0.window == "secondary" }?.windowMinutes == 10080)
    }

    @Test(arguments: [("a532305231f0", 93_436), ("42acb9b74c16", 26_632)])
    func subAgentsGoToParent(id: String, tokens: Int) throws {
        let (rel, text) = try fixture(id)
        let (out, _) = parse(text, rel: rel)
        let parent = "codex:019e91fb-669f-74f0-8128-bc93a0d2c3bb"
        #expect(out.usage.reduce(0) { $0 + $1.total } == tokens)
        #expect(out.usage.allSatisfy { $0.sessionId == parent && $0.agent == String(rel.suffix(42).prefix(36)) })
        #expect(out.events.allSatisfy { $0.sessionId == parent })
        #expect(out.userMessages.isEmpty) // generated prompts, not typed
        #expect(out.meta.isEmpty)         // must not overwrite the parent's model / cwd
    }

    @Test func resumeFromSavedStateGivesSameTotals() throws {
        let (rel, text) = try fixture("a2af923175a1")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cut = lines.count / 2
        let (a, state) = parse(lines[..<cut].joined(separator: "\n") + "\n", rel: rel)
        let (b, _) = parse(lines[cut...].joined(separator: "\n"), rel: rel, state: state)
        let whole = parse(text, rel: rel).0
        #expect(byModel(a.usage + b.usage) == byModel(whole.usage))
        #expect(a.userMessages.count + b.userMessages.count == whole.userMessages.count)
    }

    static let meta = #"{"timestamp":"2026-10-30T10:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/w","cli_version":"0.1","originator":"codex_cli_rs","model_provider":"openai","git":{"branch":"PROJ-1-x"}}}"#
    static let ctx = #"{"timestamp":"2026-10-30T10:00:01.000Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/w","model":"gpt-5","effort":"high"}}"#
    static func tc(_ ts: String, last: Int, total: Int, cached: Int = 0, limits: String = "") -> String {
        func u(_ n: Int) -> String {
            #"{"input_tokens":\#(n - 10),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":3,"total_tokens":\#(n)}"#
        }
        return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(u(total)),"last_token_usage":\#(u(last))}\#(limits)}}"#
    }

    @Test func duplicateTokenCountIsCountedOnce() {
        let text = [Self.meta, Self.ctx, Self.tc("2026-10-30T10:00:02Z", last: 100, total: 100, cached: 40),
                    Self.tc("2026-10-30T10:00:03Z", last: 100, total: 100, cached: 40),
                    // last repeats but total grew by two requests: count the total's increment
                    Self.tc("2026-10-30T10:00:04Z", last: 100, total: 300, cached: 80)].joined(separator: "\n") + "\n"
        let (out, _) = parse(text)
        #expect(out.usage.map(\.total) == [100, 200])
        #expect(out.usage[0] == UsageRecord(sessionId: "codex:s1", ts: 1_793_354_402, model: "gpt-5", input: 50, output: 10,
                                            cacheRead: 40, cwd: "/w"))
        #expect(out.meta == [SessionMeta(id: "codex:s1", tool: .codex, project: "w", cwd: "/w", gitBranch: "PROJ-1-x"),
                             SessionMeta(id: "codex:s1", tool: .codex, model: "gpt-5")])
    }

    @Test func oldResetsInSecondsAndNewResetsAt() {
        let old = #","rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_in_seconds":600},"secondary":{"used_percent":3,"window_minutes":10080,"resets_in_seconds":86400}}"#
        let new = #","rate_limits":{"limit_id":"codex","primary":{"used_percent":13,"window_minutes":300,"resets_at":1793355000},"secondary":null}"#
        let text = [Self.tc("2026-10-30T10:00:00Z", last: 50, total: 50, limits: old),
                    Self.tc("2026-10-30T10:00:10Z", last: 50, total: 100, limits: new)].joined(separator: "\n") + "\n"
        let (out, _) = parse(text)
        let t0: Timestamp = 1_793_354_400
        #expect(out.limits == [
            LimitSnapshot(tool: .codex, window: "primary", usedPct: 12.5, resetsAt: t0 + 600, windowMinutes: 300, ts: t0),
            LimitSnapshot(tool: .codex, window: "secondary", usedPct: 3, resetsAt: t0 + 86400, windowMinutes: 10080, ts: t0),
            LimitSnapshot(tool: .codex, window: "primary", usedPct: 13, resetsAt: 1_793_355_000, windowMinutes: 300, ts: t0 + 10),
        ])
    }

    @Test func unknownTypesBadLinesAndTruncatedTail() {
        let text = [
            Self.meta,
            #"{"timestamp":"2026-10-30T10:00:02Z","type":"event_msg","payload":{"type":"brand_new_event","x":1}}"#,
            #"{"timestamp":"2026-10-30T10:00:02Z","type":"something_else","payload":{}}"#,
            #"{"timestamp":"2026-10-30T10:00:03Z","type":"event_msg","payload":{"type":"user_message","message":"hi","images":[]}}"#,
            // the same message as an app-server item: ignored, this file already uses user_message
            #"{"timestamp":"2026-10-30T10:00:03Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"hi"}]}}}"#,
            #"{"timestamp":"2026-10-30T10:00:04Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}","call_id":"c1"}}"#,
            #"{"timestamp":"2026-10-30T10:00:05Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"x","call_id":"c2"}}"#,
            #"{"timestamp":"2026-10-30T10:00:06Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted","duration_ms":5}}"#,
            #"{"timestamp":"2026-10-30T10:00:07Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_us"#, // corrupt
            #"{"timestamp":"2026-10-30T10:00:08Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"#, // no newline yet
        ].joined(separator: "\n")
        let (out, _) = parse(text)
        #expect(out.badLines == 1)
        #expect(out.userMessages == [UserMessage(sessionId: "codex:s1", ts: 1_793_354_403, text: "hi", cwd: "/w")])
        #expect(out.tools == [ToolCall(sessionId: "codex:s1", ts: 1_793_354_404, name: "shell", callId: "c1"),
                              ToolCall(sessionId: "codex:s1", ts: 1_793_354_405, name: "apply_patch", callId: "c2")])
        #expect(out.events.map(\.ts) == [1_793_354_404, 1_793_354_405, 1_793_354_406])
        #expect(out.usage.isEmpty)
    }

    @Test func userMessageKindIsChosenPerTurn() {
        func um(_ ts: String) -> String {
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"user_message","message":"a"}}"#
        }
        func ic(_ ts: String) -> String {
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"b"}]}}}"#
        }
        let started = #"{"timestamp":"2026-10-30T10:59:59Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#
        // an old CLI wrote user_message; the session was resumed by a CLI that writes item_completed only.
        // turn_context comes with every request, so it must not reset the choice inside a turn.
        let text = [Self.meta, Self.ctx, um("2026-10-30T10:00:02Z"), Self.ctx, ic("2026-10-30T10:00:02Z"),
                    started, ic("2026-10-30T11:00:00Z")].joined(separator: "\n") + "\n"
        #expect(parse(text).0.userMessages.map(\.ts) == [1_793_354_402, 1_793_358_000])
    }

    @Test(arguments: ["1e19", "99999999999999999999", "-1", "9000000000000000000"])
    func absurdNumbersDoNotTrap(n: String) {
        let u = #"{"input_tokens":\#(n),"cached_input_tokens":\#(n),"output_tokens":\#(n),"total_tokens":\#(n)}"#
        let line = #"{"timestamp":"2026-10-30T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(u),"last_token_usage":\#(u)},"rate_limits":{"primary":{"used_percent":1,"window_minutes":\#(n)}}}}"#
        let (out, _) = parse([line, line.replacingOccurrences(of: "10:00:00", with: "10:00:01")].joined(separator: "\n") + "\n")
        #expect(out.usage.isEmpty)
        #expect(out.limits.map(\.windowMinutes) == [nil])
    }

    @Test func sessionIdFromFileNameWithoutMeta() {
        let rel = "2026/10/30/rollout-2026-10-30T10-00-00-019a0000-1111-2222-3333-444455556666.jsonl"
        let (out, _) = parse(Self.tc("2026-10-30T10:00:00Z", last: 5, total: 5) + "\n", rel: rel)
        #expect(out.usage.map(\.sessionId) == ["codex:019a0000-1111-2222-3333-444455556666"])
        #expect(out.usage.map(\.model) == ["unknown"])
    }

    @Test func specsAcceptRolloutsOnly() {
        let specs = CodexSource.specs(codexHome: "/h")
        #expect(specs.map(\.root) == ["/h/sessions", "/h/archived_sessions"])
        #expect(specs[0].accepts("2026/10/30/rollout-2026-10-30T10-00-00-x.jsonl"))
        #expect(specs[1].accepts("rollout-2026-10-30T10-00-00-x.jsonl"))
        #expect(specs[0].accepts("2026/10/30/rollout-x.jsonl.zst"))
        #expect(!specs[0].accepts("2026/10/30/rollout-compress-x.tmp"))
        #expect(CodexParser.idFromName("rollout-2026-10-30T10-00-00-019a0000-1111-2222-3333-444455556666.jsonl.zst")
                == "019a0000-1111-2222-3333-444455556666")
        #expect(!specs[0].accepts("history.jsonl"))
    }
}

@Suite struct CodexThreadsTests {
    func makeHome() throws -> String {
        let dir = NSTemporaryDirectory() + "zagon-codex-test-\(UInt64.random(in: 0...UInt64.max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for n in [2, 10] {
            let db = try SQLite(path: dir + "/state_\(n).sqlite")
            try db.exec("PRAGMA journal_mode=WAL")
            try db.exec("""
                CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER, updated_at INTEGER,
                  source TEXT, cwd TEXT, title TEXT, tokens_used INTEGER, archived INTEGER, git_branch TEXT,
                  first_user_message TEXT, model TEXT, thread_source TEXT, name TEXT)
                """)
            guard n == 10 else { continue }
            try db.exec("""
                INSERT INTO threads VALUES
                 ('a', '', 1, 100, 'vscode', '/w/a', 'fix the build please', 5, 0, 'PROJ-7-x', 'fix the build please', 'gpt-5', 'user', 'Fix build'),
                 ('b', '', 1, 200, 'cli', '/w/b', 'secret first prompt', 5, 1, NULL, 'secret first prompt', NULL, NULL, NULL),
                 ('c', '', 1, 300, 'cli', '/w/c', 'Renamed', 5, 0, NULL, 'other text', 'gpt-5', NULL, ''),
                 ('d', '', 1, 400, '{"subagent":{"other":"guardian"}}', '/w/a', 'guardian', 5, 0, NULL, '', 'x', 'subagent', 'guardian'),
                 ('e', '', 1, 50, 'cli', '/w/e', 'typed but unknown', 5, 0, NULL, NULL, NULL, NULL, NULL);
                """)
        }
        return dir
    }

    @Test func mergesTitlesNeverTheFirstMessage() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(CodexThreads.stateFile(codexHome: home)?.hasSuffix("/state_10.sqlite") == true)
        let s = try Store(path: ":memory:")
        try s.mergeSession(SessionMeta(id: "codex:a", tool: .codex, model: "gpt-5"))
        #expect(try CodexThreads.sync(store: s, codexHome: home, host: "h") == 4)
        var rows: [String] = []
        try s.db.query("SELECT id, coalesce(title,'-'), title_rank, coalesce(cwd,'-'), coalesce(git_branch,'-'), coalesce(model,'-') FROM session ORDER BY id") { r in
            rows.append((0..<6).map { r.text(Int32($0)) ?? "?" }.joined(separator: "|"))
        }
        #expect(rows == ["codex:a|Fix build|3|/w/a|PROJ-7-x|gpt-5", "codex:b|-|0|/w/b|-|-", "codex:c|Renamed|3|/w/c|-|gpt-5",
                         "codex:e|-|0|/w/e|-|-"])
        #expect(try CodexThreads.sync(store: s, codexHome: home) == 0) // nothing changed: no merge, no seq churn
        // Codex archives and renames without touching updated_at
        try SQLite(path: home + "/state_10.sqlite").exec("UPDATE threads SET archived = 1 WHERE id = 'a'; UPDATE threads SET name = 'New' WHERE id = 'c'")
        #expect(try CodexThreads.sync(store: s, codexHome: home) == 2)
        #expect(try s.db.one("SELECT archived FROM session WHERE id = 'codex:a'") { $0.optInt(0) } == 1)
        #expect(try s.db.one("SELECT title FROM session WHERE id = 'codex:c'") { $0.text(0) } == "New")
        #expect(try s.db.one("SELECT project FROM session WHERE id = 'codex:a'") { $0.text(0) } == "a")
    }

    @Test func noStateFile() throws {
        #expect(try CodexThreads.sync(store: Store(path: ":memory:"), codexHome: "/nonexistent") == 0)
    }

    @Test func uriEscapesSpecialCharacters() {
        #expect(CodexThreads.uri("/a b/c?d#e%f") == "file:/a b/c%3Fd%23e%25f")
    }
}

/// Codex archives a session by renaming its rollout `sessions/YYYY/MM/DD/<name>` → `archived_sessions/<name>`
/// (same inode; unarchive renames it back) and setting `threads.archived` / `archived_at` (not `updated_at`).
struct CodexArchiveScenario {
    static let name = "rollout-2026-01-08T19-18-57-019b9f0c-3cb8-7072-8510-e948f3b3984b.jsonl"
    let sessionId = "codex:019b9f0c-3cb8-7072-8510-e948f3b3984b"
    let tokens = ["gpt-5.2-codex": 1_302_360]
    let codexHome = NSTemporaryDirectory() + "zagon-codex-archive-\(UInt64.random(in: 0...UInt64.max))"
    var live: String { codexHome + "/sessions/2026/01/08/" + Self.name }
    var archived: String { codexHome + "/archived_sessions/" + Self.name }

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: codexHome + "/sessions/2026/01/08", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: codexHome + "/archived_sessions", withIntermediateDirectories: true)
        try fm.copyItem(atPath: home + "/sessions/2026/01/08/" + Self.name, toPath: live)
        try SQLite(path: codexHome + "/state_5.sqlite").exec("""
            CREATE TABLE threads(id TEXT PRIMARY KEY, updated_at INTEGER, archived INTEGER, archived_at INTEGER);
            INSERT INTO threads VALUES('\(sessionId.dropFirst(6))', 1767899937, 0, NULL);
            """)
    }
    func archive() throws {
        try FileManager.default.moveItem(atPath: live, toPath: archived)
        try SQLite(path: codexHome + "/state_5.sqlite").exec("UPDATE threads SET archived = 1, archived_at = updated_at + 54")
    }
    func remove() { try? FileManager.default.removeItem(atPath: codexHome) }
}

@Suite struct CodexArchiveTests {
    func tokens(_ s: Store) throws -> [String: Int] {
        var t: [String: Int] = [:]
        try s.db.query("SELECT model, sum(input + output + cache_read + cache_write) FROM usage_hour GROUP BY model") {
            t[$0.text(0) ?? ""] = $0.int(1)
        }
        return t
    }

    @Test func archivedSessionIsCountedOnceAndFlagged() throws {
        let sc = try CodexArchiveScenario()
        defer { sc.remove() }
        let store = try Store(path: ":memory:")
        let ingest = Ingest(store: store, sources: CodexSource.specs(codexHome: sc.codexHome))
        try ingest.scan()
        #expect(try CodexThreads.sync(store: store, codexHome: sc.codexHome) == 1)
        #expect(try tokens(store) == sc.tokens)

        try sc.archive()
        let st = try ingest.scan()
        #expect(st.moves == 1 && st.resets == 0)
        #expect(try CodexThreads.sync(store: store, codexHome: sc.codexHome) == 1)
        #expect(try tokens(store) == sc.tokens) // not doubled: Codex usage has no messageId to dedup by
        #expect(try store.db.one("SELECT archived FROM session WHERE id = ?", [.text(sc.sessionId)]) { $0.optInt(0) } == 1)
    }

    /// A real rollout compressed by Codex after it was read, and one only ever seen compressed: the same tokens.
    @Test func compressedRolloutIsCountedOnce() throws {
        let sc = try CodexArchiveScenario()
        defer { sc.remove() }
        let store = try Store(path: ":memory:")
        let ingest = Ingest(store: store, sources: CodexSource.specs(codexHome: sc.codexHome))
        try ingest.scan()
        _ = try Archive(store: store, dir: sc.codexHome).compress(sc.live, size: Sys.fileSize(sc.live)!, to: sc.live + ".zst")
        try FileManager.default.removeItem(atPath: sc.live)
        let st = try ingest.scan()
        #expect(st.resets == 0 && st.moves == 1)
        #expect(try tokens(store) == sc.tokens)

        let fresh = try Store(path: ":memory:")
        try Ingest(store: fresh, sources: CodexSource.specs(codexHome: sc.codexHome)).scan()
        #expect(try tokens(fresh) == sc.tokens)
        #expect(try fresh.db.one("SELECT count(*) FROM session WHERE id = ?", [.text(sc.sessionId)]) { $0.int(0) } == 1)
        // Handoff finds and reads it.
        let found = Handoff.find(sc.sessionId, claudeDir: "/nonexistent", codexHome: sc.codexHome)
        #expect(found?.2 == sc.live + ".zst")
        #expect(SessionDigest.read(tool: .codex, id: "x", path: sc.live + ".zst").cwd != nil)
    }
}

/// A real Codex home (read-only) copied to a temp dir: counted, every rollout then compressed as Codex does (the
/// original deleted), counted again, and counted fresh from the compressed copy only. All three must agree.
/// `ZAGON_CODEX_HOME=/data/codex swift test --filter compressedCrossCheck`; prints only numbers.
@Suite struct CodexCompressedCrossCheck {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZAGON_CODEX_HOME"] != nil))
    func compressedCrossCheck() throws {
        let fm = FileManager.default, src = ProcessInfo.processInfo.environment["ZAGON_CODEX_HOME"]!
        let home = NSTemporaryDirectory() + "zagon-codex-zst-\(UInt64.random(in: 0...UInt64.max))"
        defer { try? fm.removeItem(atPath: home) }
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        for d in ["sessions", "archived_sessions"] where fm.fileExists(atPath: src + "/" + d) {
            try fm.copyItem(atPath: src + "/" + d, toPath: home + "/" + d)
        }
        func sums(_ s: Store) throws -> [Int] {
            try s.db.one("""
                SELECT (SELECT coalesce(sum(input), 0) FROM usage_hour), (SELECT coalesce(sum(output), 0) FROM usage_hour),
                  (SELECT coalesce(sum(cache_read), 0) FROM usage_hour), (SELECT coalesce(sum(requests), 0) FROM usage_hour),
                  (SELECT coalesce(sum(n), 0) FROM tool_use), (SELECT count(*) FROM session)
                """) { r in (0..<6).map { r.int(Int32($0)) } }!
        }
        let store = try Store(path: ":memory:")
        let ingest = Ingest(store: store, sources: CodexSource.specs(codexHome: home))
        try ingest.scan()
        let before = try sums(store)
        var packed = 0
        for spec in CodexSource.specs(codexHome: home) {
            for rel in Ingest.walk(spec.root) where rel.hasSuffix(".jsonl") && spec.accepts(rel) {
                let p = spec.root + "/" + rel
                _ = try Archive(store: store, dir: home).compress(p, size: Sys.fileSize(p)!, to: p + ".zst")
                try fm.removeItem(atPath: p)
                packed += 1
            }
        }
        let st = try ingest.scan()
        let after = try sums(store)
        let fresh = try Store(path: ":memory:")
        try Ingest(store: fresh, sources: CodexSource.specs(codexHome: home)).scan()
        let only = try sums(fresh)
        print("compressedCrossCheck: \(packed) rollouts; input, output, cache_read, requests, tool calls, sessions: before \(before), "
              + "after \(after), fresh \(only); resets \(st.resets), moves \(st.moves), read \(st.filesRead)")
        #expect(after == before && only == before)
        #expect(st.resets == 0 && st.moves == packed)
    }
}

/// Cross-check on a real Codex home (read-only), e.g. `ZAGON_CODEX_HOME=/data/codex swift test --filter crossCheck`:
/// per-thread rollout totals vs `threads.tokens_used`. Prints only ids and numbers.
@Suite struct CodexCrossCheck {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZAGON_CODEX_HOME"] != nil))
    func crossCheck() throws {
        let home = ProcessInfo.processInfo.environment["ZAGON_CODEX_HOME"]!
        var parsed: [String: Int] = [:] // thread id (sub-agents by their own id) -> tokens
        for spec in CodexSource.specs(codexHome: home) {
            guard let e = FileManager.default.enumerator(atPath: spec.root) else { continue }
            while let rel = e.nextObject() as? String {
                guard spec.accepts(rel) else { continue }
                let (out, _) = parse(try String(contentsOfFile: spec.root + "/" + rel, encoding: .utf8), rel: rel)
                for u in out.usage { parsed[u.agent.isEmpty ? String(u.sessionId.dropFirst(6)) : u.agent, default: 0] += u.total }
            }
        }
        let db = try SQLite(path: CodexThreads.uri(CodexThreads.stateFile(codexHome: home)!) + "?immutable=1", readOnly: true)
        var sumP = 0, sumT = 0
        try db.query("SELECT id, tokens_used FROM threads ORDER BY id") { r in
            let id = r.text(0)!, t = r.int(1)
            guard let p = parsed[id] else { print("codex crosscheck \(id.suffix(8)): no rollout, threads \(t)"); return }
            sumP += p; sumT += t
            if p != t { print("codex crosscheck \(id.suffix(8)): rollout \(p) threads \(t)") }
        }
        print("codex crosscheck total: rollout \(sumP) threads \(sumT) gap \(sumP - sumT)")
        let merged = try CodexThreads.sync(store: Store(path: ":memory:"), codexHome: home)
        print("codex crosscheck threads merged: \(merged)")
        #expect(merged > 0)
        #expect(sumP == sumT)
    }
}
