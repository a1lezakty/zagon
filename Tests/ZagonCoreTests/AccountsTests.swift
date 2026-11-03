import Foundation
import Testing
@testable import ZagonCore

/// Two Claude Code accounts on one machine (`CLAUDE_CONFIG_DIR`): transcripts of both, sessions and limit readings
/// marked with their account, limits and notifications per account, schema v8.
@Suite struct AccountsTests {
    func write(_ path: String, _ lines: [String]) {
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func spoolLine(_ s: Store, _ line: String) throws {
        var res = SpoolIngest.Result()
        try SpoolIngest.apply(Array(line.utf8), store: s, names: SpoolIngest.Names(home: "/home/u", map: ["/home/u/.claude-x": "corp"]),
                              into: &res)
    }

    @Test func namesFromTheMapTheFolderAndTheDefault() {
        let m = Accounts.map("[accounts]\n\"~/.work-claude/\" = \"corp\"\n'/srv/c' = 'ops'\n", home: "/home/u")
        #expect(m == ["/home/u/.work-claude": "corp", "/srv/c": "ops"])
        #expect(Accounts.name(configDir: nil, home: "/home/u", map: m) == "default")
        #expect(Accounts.name(configDir: "", home: "/home/u", map: m) == "default")
        #expect(Accounts.name(configDir: "/home/u/.claude/", home: "/home/u", map: m) == "default")
        #expect(Accounts.name(configDir: "/home/u/.claude", home: "/home/u", map: ["/home/u/.claude": "mine"]) == "default")
        #expect(Accounts.name(configDir: "/home/u/.work-claude", home: "/home/u", map: m) == "corp")
        #expect(Accounts.name(configDir: "/root/.claude-corp", home: "/home/u", map: [:]) == "corp")
        #expect(Accounts.name(configDir: "/x/.claude_team", home: "/home/u", map: [:]) == "team")
        #expect(Accounts.name(configDir: "/x/second", home: "/home/u", map: [:]) == "second")
        #expect(Accounts.configDir(transcript: "/root/.claude-corp/projects/-root-Z-p/abc.jsonl") == "/root/.claude-corp")
        #expect(Accounts.configDir(transcript: "/root/.claude-corp/projects/-root-Z-p/abc/subagents/a.jsonl") == nil)
        #expect(Accounts.configDir(transcript: "relative/projects/p/a.jsonl") == nil)
        #expect(Accounts.tag("corp") == " (corp)" && Accounts.tag("default").isEmpty && Accounts.tag(nil).isEmpty)
    }

    @Test func twoRootsGiveSessionsWithTheirAccounts() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write(dir + "/home/.claude/projects/-w-alpha/p1.jsonl",
              [typed(T0, session: "p1"), assistantLine(T0 + minute, id: "m1", model: "claude-opus-4-1", input: 5, session: "p1")])
        write(dir + "/home/.claude-corp/projects/-w-beta/c1.jsonl",
              [typed(T0, session: "c1", cwd: "/w/beta"),
               assistantLine(T0 + minute, id: "m2", model: "claude-sonnet-4-5", input: 7, session: "c1", cwd: "/w/beta"),
               #"{"type":"custom-title","customTitle":"Corp work","sessionId":"c1"}"#])
        let s = try Store(path: dir + "/z.db")
        let paths = ZagonPaths(home: dir + "/home", dir: dir + "/data")
        // No setting: the corp folder is learned from a hook (its transcript path) and becomes a root.
        try spoolLine(s, #"{"kind":"hook","tool":"claude","event":"Stop","ts":\#(T0 + 2 * minute),"session_id":"c1","cwd":"/w/beta","transcript_path":"\#(dir)/home/.claude-corp/projects/-w-beta/c1.jsonl"}"#)
        // The same folder through a link is one root (its real path).
        try FileManager.default.createSymbolicLink(atPath: dir + "/home/corp-link", withDestinationPath: dir + "/home/.claude-corp")
        try spoolLine(s, #"{"kind":"hook","tool":"claude","event":"Stop","ts":\#(T0 + 3 * minute),"session_id":"c1","config_dir":"\#(dir)/home/corp-link"}"#)
        let roots = Accounts.claudeRoots(defaultRoot: dir + "/home/.claude/projects", paths: paths, db: s.db)
        #expect(roots.map(\.account) == ["default", "corp"])
        #expect(roots.last?.root == (Sys.realPath(dir + "/home/.claude-corp") ?? "") + "/projects")
        let ingest = Ingest(store: s, sources: roots.map { ClaudeSource.spec(root: $0.root, account: $0.account) })
        try ingest.scan()
        let rows = try queryRows(s, "SELECT id, account, title, model, host FROM session ORDER BY id")
        #expect(rows == [["claude:c1", "corp", "Corp work", "claude-sonnet-4-5", s.host],
                         ["claude:p1", "default", "", "claude-opus-4-1", s.host]])
        let live = try Query(store: s).liveSessions(now: T0 + 3 * minute)
        #expect(live.first { $0.id == "claude:c1" }?.account == "corp")
        #expect(try Reports(store: s).sessions(limit: 10).first { $0.id == "claude:c1" }?.account == "corp")
        // Handoff finds a session in any account's folder.
        #expect(Handoff.find("c1", claudeDirs: roots.map(\.root), codexHome: dir + "/none")?.2.hasPrefix(dir + "/home/.claude-corp/") == true)
        #expect(Handoff.find("c1", claudeDir: roots[0].root, codexHome: dir + "/none") == nil)
    }

    @Test func oneSessionCopiedIntoAnotherAccountCountsOnce() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let history = [typed(T0, session: "d1"), assistantLine(T0 + minute, id: "m1", input: 5, output: 1, session: "d1")]
        write(dir + "/a/projects/-w-alpha/d1.jsonl", history)
        // The copy goes on under the other account.
        write(dir + "/b/projects/-w-alpha/d1.jsonl",
              history + [typed(T0 + 10 * minute, session: "d1"), assistantLine(T0 + 11 * minute, id: "m2", input: 7, output: 1, session: "d1")])
        let s = try Store(path: ":memory:")
        try Ingest(store: s, sources: [ClaudeSource.spec(root: dir + "/a/projects", account: "default"),
                                       ClaudeSource.spec(root: dir + "/b/projects", account: "corp")]).scan()
        #expect(try queryRows(s, "SELECT user_msgs, account FROM session WHERE id = 'claude:d1'") == [["2", "corp"]])
        #expect(try queryRows(s, "SELECT sum(input) FROM usage_hour") == [["12"]])
    }

    @Test func aSessionKnownOnlyFromHooksIsThisMachinesWithItsAccount() throws {
        let s = try Store(path: ":memory:")
        try spoolLine(s, #"{"kind":"hook","tool":"claude","event":"UserPromptSubmit","ts":\#(T0),"session_id":"h1","config_dir":"/home/u/.claude-x"}"#)
        try spoolLine(s, #"{"kind":"hook","tool":"claude","event":"Stop","ts":\#(T0 + 1),"session_id":"h2","cwd":"/w/a","transcript_path":"/home/u/.claude/projects/-w-a/h2.jsonl"}"#)
        try spoolLine(s, #"{"kind":"hook","tool":"codex","event":"Stop","ts":\#(T0 + 2),"session_id":"x1","cwd":"/w/a"}"#)
        let rows = try queryRows(s, "SELECT id, coalesce(host, 'NULL'), coalesce(account, 'NULL'), status FROM session ORDER BY id")
        #expect(rows == [["claude:h1", s.host, "corp", "working"], ["claude:h2", s.host, "default", "waiting_input"],
                         ["codex:x1", s.host, "NULL", "waiting_input"]])
        // A folder without `projects` (here: none on disk) is not learned as a root; the default one never is.
        #expect(try queryRows(s, "SELECT key FROM meta WHERE key LIKE 'claude_dir:%'").isEmpty)
        // A later hook of the session under another account moves it there (a session resumed under that account).
        try spoolLine(s, #"{"kind":"hook","tool":"claude","event":"UserPromptSubmit","ts":\#(T0 + 5),"session_id":"h2","config_dir":"/home/u/.claude-x"}"#)
        #expect(try queryRows(s, "SELECT account FROM session WHERE id = 'claude:h2'") == [["corp"]])
        // The export carries the host and the account.
        var lines: [JValue] = []
        try Export.run(store: s, since: 0) { if let v = JValue.parse($0), v["type"] == "session" { lines.append(v) } }
        #expect(lines.allSatisfy { $0["host"]?.string == s.host })
        #expect(lines.first { $0["id"] == .string("claude:h1") }?["account"]?.string == "corp")
    }

    @Test func limitsAreKeptAndShownPerAccount() throws {
        let s = try Store(path: ":memory:")
        let now = T0 + 10 * minute
        // personal: week 86 %, corp: 0 %, resets earlier — before accounts the later reset (personal's) hid nothing, but
        // a corp window resetting later would have replaced personal's reading.
        try spoolLine(s, #"{"kind":"limits","tool":"claude","ts":\#(T0),"session_id":"p","five_hour_pct":20,"five_hour_resets_at":\#(T0 + 3 * hour),"seven_day_pct":86,"seven_day_resets_at":\#(T0 + 50 * hour)}"#)
        try spoolLine(s, #"{"kind":"limits","tool":"claude","ts":\#(T0 + 1),"session_id":"c","config_dir":"/home/u/.claude-x","five_hour_pct":0,"five_hour_resets_at":\#(T0 + 4 * hour),"seven_day_pct":0,"seven_day_resets_at":\#(T0 + 100 * hour)}"#)
        let latest = try s.latestLimits()
        #expect(latest.map { "\($0.account) \($0.window) \(Int($0.usedPct))" }
                == ["default five_hour 20", "default seven_day 86", "corp five_hour 0", "corp seven_day 0"])
        // A status line of a zagon before accounts (no folder): its session's account.
        try s.mergeSession(SessionMeta(id: "claude:c2", tool: .claude, account: "corp"))
        try spoolLine(s, #"{"kind":"limits","tool":"claude","ts":\#(T0 + 2 * minute),"session_id":"c2","seven_day_pct":1,"seven_day_resets_at":\#(T0 + 100 * hour)}"#)
        #expect(try s.latestLimits().first { $0.account == "corp" && $0.window == "seven_day" }?.usedPct == 1)
        #expect(try s.latestLimits().first { $0.account == "default" && $0.window == "seven_day" }?.usedPct == 86)
        // A status line of this zagon says its folder, "" for the default account: never the session's account.
        try spoolLine(s, #"{"kind":"limits","tool":"claude","ts":\#(T0 + 3 * minute),"session_id":"c2","config_dir":"","five_hour_pct":25,"five_hour_resets_at":\#(T0 + 3 * hour)}"#)
        #expect(try s.latestLimits().first { $0.account == "default" && $0.window == "five_hour" }?.usedPct == 25)
        #expect(try s.latestLimits().first { $0.account == "corp" && $0.window == "five_hour" }?.usedPct == 0)
        #expect(try Query(store: s).limits(now: now).map(\.account) == ["default", "default", "corp", "corp"])
        // Labels: once another account has readings, every reading of the tool says whose it is.
        let labeled = Accounts.labeled(try s.latestLimits(), now: now, localAccount: "personal")
        #expect(labeled.map { $0.1 } == ["personal", "personal", "corp", "corp"])
        #expect(Accounts.labeled(try s.latestLimits(), now: T0 + 9 * 86400, localAccount: nil).map { $0.1 } == [nil, nil])
        let text = try ZagonMCP.limitsText(store: s, now: T0 + 10 * minute, localAccount: "personal")
        #expect(text.contains("Claude (personal) week: 86% used") && text.contains("Claude (corp) week: 1% used"))
        // Exported with the account; imported readings keep it apart.
        var lines: [String] = []
        try Export.run(store: s, since: 0, account: "personal") { lines.append($0) }
        // Another account's readings are a line type a client before v8 skips (it would mix them into the default's).
        let all = lines.compactMap { JValue.parse($0) }
        let corp = all.filter { $0["type"] == "account_limit" }
        #expect(corp.count == 2 && corp.allSatisfy { $0["account_id"]?.string == "corp" && $0["host"] == nil && $0["account"] == nil })
        #expect(all.filter { $0["type"] == "limit" }.allSatisfy { $0["account_id"] == nil && $0["account"]?.string == "personal" })
        let mac = try Store(path: ":memory:")
        try ExportImport(store: mac, source: "build-box").apply(lines)
        #expect(try mac.latestLimits().map { "\($0.account) \(Int($0.usedPct))" } == ["default 25", "default 86", "corp 0", "corp 1"])
        #expect(try mac.db.one("SELECT value FROM meta WHERE key = 'limit_account:build-box'") { $0.text(0) } == "personal")
    }

    @Test func notificationsPerAccountWithItsThresholdsAndName() throws {
        let s = try Store(path: ":memory:")
        try s.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "seven_day", usedPct: 96, resetsAt: T0 + 50 * hour,
                                             windowMinutes: 10080, ts: T0))
        try s.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "seven_day", usedPct: 92, resetsAt: T0 + 100 * hour,
                                             windowMinutes: 10080, ts: T0, account: "corp"))
        var config = NotifyConfig.parse("[notify]\nlang = \"en\"\n[limits]\naccount = \"personal\"\n[notify.limits]\nclaude.week = [95]\n"
                                        + "[notify.limits.corp]\nclaude.week = [90]\n", home: "/home/u")
        config.quiet = nil
        #expect(config.thresholds("claude.week") == [95] && config.thresholds("claude.week", account: "corp") == [90])
        #expect(config.thresholds("claude.five_hour", account: "corp") == [80, 95])
        let n = Notifier(store: s, config: config, channels: [])
        let events = try n.limitEvents(now: T0 + minute)
        #expect(events.map(\.key).sorted() == ["limit:claude:corp/seven_day:90", "limit:claude:seven_day:95"])
        let titles = try events.compactMap { try $0.make()?.title }.sorted()
        #expect(titles == ["Claude (corp): weekly limit — 90%", "Claude (personal): weekly limit — 95%"])
        // One account alone: as before, no label, the same key.
        let one = try Store(path: ":memory:")
        try one.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "seven_day", usedPct: 96, resetsAt: T0 + 50 * hour,
                                               windowMinutes: 10080, ts: T0))
        let single = try Notifier(store: one, config: config, channels: []).limitEvents(now: T0 + minute)
        #expect(single.map(\.key) == ["limit:claude:seven_day:95"])
        #expect(try single.first?.make()?.title == "Claude: weekly limit — 95%")
    }

    @Test func migrationFromV7KeepsReadingsAsDefaultAndGivesHookSessionsTheHost() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            let db = try SQLite(path: dir + "/z.db")
            for sql in Schema.migrations.prefix(7) { try db.exec(sql) }
            try db.exec("PRAGMA user_version=7")
            try db.exec("""
                INSERT INTO meta(key, value) VALUES('host', 'build-box'), ('seq', 10), ('remote_seq:srv', 5);
                INSERT INTO limit_snapshot VALUES('claude', 'seven_day', 86, 1000, 10080, 500);
                INSERT INTO limit_snapshot VALUES('claude', 'seven_day', 87, 1000, 10080, 600);
                INSERT INTO session(id, tool, host, seq) VALUES('claude:a', 'claude', NULL, 3), ('claude:b', 'claude', 'other', 4);
                """)
        }
        let s = try Store(path: dir + "/z.db")
        #expect(s.userVersion == 8 && s.host == "build-box")
        #expect(try queryRows(s, "SELECT account, used_pct, ts FROM limit_snapshot ORDER BY ts") == [["default", "86.0", "500.0"],
                                                                                                    ["default", "87.0", "600.0"]])
        #expect(try queryRows(s, "SELECT id, host, seq FROM session ORDER BY id") == [["claude:a", "build-box", "11"],
                                                                                      ["claude:b", "other", "4"]])
        #expect(try queryRows(s, "SELECT key FROM meta WHERE key LIKE 'remote%'").isEmpty)
        #expect(try s.latestLimits().map(\.usedPct) == [87])
        // Readings of two accounts at the same moment no longer replace each other.
        try s.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "seven_day", usedPct: 1, resetsAt: 2000, windowMinutes: 10080,
                                             ts: 600, account: "corp"))
        #expect(try queryRows(s, "SELECT count(*) FROM limit_snapshot") == [["3"]])
    }

    @Test func statusLineAndHookLinesCarryTheConfigFolder() throws {
        let input = Array(#"{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1}}}"#.utf8)
        let line = try #require(StatusLine.limitsLine(input, ts: 5, configDir: "/root/.claude-corp")?.line)
        #expect(JValue.parse(Array(line.utf8))?["config_dir"]?.string == "/root/.claude-corp")
        #expect(JValue.parse(Array(try #require(StatusLine.limitsLine(input, ts: 5, configDir: nil)?.line).utf8))?["config_dir"]?.string == "")
        let payload = Array(#"{"session_id":"s1","cwd":"/w","transcript_path":"/t.jsonl","hook_event_name":"Stop"}"#.utf8)
        let hook = try #require(HookSpool.hookLine(tool: "claude", event: "Stop", payload: payload, ts: 1, configDir: "/root/.claude-corp"))
        #expect(JValue.parse(Array(hook.utf8))?["config_dir"]?.string == "/root/.claude-corp")
        let codex = try #require(HookSpool.hookLine(tool: "codex", event: "Stop", payload: payload, ts: 1, configDir: "/root/.claude-corp"))
        #expect(JValue.parse(Array(codex.utf8))?["config_dir"] == nil)
    }
}

/// Rows of a query as text ("" for NULL, numbers as SQLite prints them); the columns are those of its SELECT list.
func queryRows(_ s: Store, _ sql: String) throws -> [[String]] {
    let list = sql.dropFirst(7).components(separatedBy: " FROM ")[0]
    var depth = 0, n: Int32 = 1
    for c in list { if c == "(" { depth += 1 } else if c == ")" { depth -= 1 } else if c == ",", depth == 0 { n += 1 } }
    var out: [[String]] = []
    try s.db.query(sql) { r in out.append((0..<n).map { r.text($0) ?? "" }) }
    return out
}
