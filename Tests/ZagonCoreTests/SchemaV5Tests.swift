import Foundation
import Testing
@testable import ZagonCore

/// A queued message (`attachment` `queued_command`): sent while the agent was working.
func queuedLine(_ t: Timestamp, prompt: String, origin: String? = #"{"kind":"human"}"#, mode: String = "prompt",
                cwd: String = "/w/alpha") -> String {
    let o = origin.map { #","origin":\#($0)"# } ?? ""
    return #"{"parentUuid":"00000000-0000-4000-8000-000000000001","isSidechain":false,"attachment":{"type":"queued_command","prompt":\#(prompt),"commandMode":"\#(mode)"\#(o),"delivery_id":"d1","timestamp":"\#(iso(t))"},"type":"attachment","uuid":"00000000-0000-4000-8000-000000000004","timestamp":"\#(iso(t))","userType":"external","cwd":\#(js(cwd)),"sessionId":"S","version":"2.1.0","gitBranch":"main"}"#
}

let channelOrigin = #"{"kind":"channel","server":"plugin:telegram:telegram"}"#
func channelText(_ s: String) -> String {
    js("<channel source=\"plugin:telegram:telegram\" chat_id=\"1\" message_id=\"7\" user=\"u\" ts=\"2026-10-20T10:00:00Z\">\n\(s)\n</channel>")
}

@Suite struct SchemaV5Tests {
    // MARK: cache writes kept for an hour

    @Test func oneHourCacheWritesAreReadAndPricedAtTwiceTheInput() {
        let out = parse([assistantLine(T0, id: "m1", cacheWrite: 1000, cacheWrite1h: 600)])
        #expect(out.usage.map(\.cacheWrite) == [1000] && out.usage.map(\.cacheWrite1h) == [600])
        #expect(out.usage.first?.cwd == "/w/alpha")
        // JSONDecoder fallback (a non-object block) reads the split too.
        let odd = #"{"type":"assistant","timestamp":"\#(iso(T0))","message":{"id":"m2","model":"claude-opus-4-1","content":["odd"],"usage":{"input_tokens":1,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}"#
        #expect(Array(odd.utf8).withUnsafeBytes { ClaudeParser.scan($0, wantText: false) } == nil)
        #expect(parse([odd]).usage.map(\.cacheWrite1h) == [20])

        // Opus: 5-minute writes 1.25x input ($6.25 / M), 1-hour writes 2x ($10 / M).
        #expect(Pricing.cost(model: "claude-opus-4-1", input: 0, output: 0, cacheRead: 0, cacheWrite: 3_000_000,
                             cacheWrite1h: 1_000_000) == 2 * 6.25 + 10)
        #expect(Pricing.cost(model: "claude-sonnet-4-5", input: 0, output: 0, cacheRead: 0, cacheWrite: 1_000_000,
                             cacheWrite1h: 1_000_000) == 6)
    }

    @Test func dayReportsCarryTheSplitAndTheCost() throws {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0),
                                    assistantLine(T0 + minute, id: "m1", input: 1_000_000, cacheWrite: 1_000_000, cacheWrite1h: 400_000),
                                    // the same request rewritten: the last record wins, split included
                                    assistantLine(T0 + minute, id: "m1", input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000,
                                                  cacheWrite1h: 1_000_000)])
        env.scan()
        let r = try Reports(store: env.store).day("2026-10-20")
        #expect(r.tokens.cacheWrite == 1_000_000 && r.tokens.cacheWrite1h == 1_000_000 && r.tokens.requests == 1)
        let want = 5.0 + 25 + 10  // input, output, 1-hour writes of Opus
        #expect(abs(r.cost - want) < 1e-9 && abs((r.models.first?.cost ?? 0) - want) < 1e-9)
        #expect(abs((r.projects.first?.cost ?? 0) - want) < 1e-9)
        #expect(abs(try Query(store: env.store).day("2026-10-20").cost - want) < 1e-9)
        let s = try Reports(store: env.store).sessions(from: T0 - hour, to: T0 + hour)
        #expect(s.count == 1 && abs(s[0].cost - want) < 1e-9)
        let w = try Reports(store: env.store).week(ending: "2026-10-20")
        #expect(abs(w.cost - want) < 1e-9 && abs((w.days.last?.cost ?? 0) - want) < 1e-9)
    }

    // MARK: project by the directory of each segment

    @Test func tokensAndTimeStayWithTheDirectoryTheyWereSpentIn() throws {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0),
                                    assistantLine(T0 + minute, id: "m1", output: 100),
                                    // inside the folder it started in: still its project
                                    assistantLine(T0 + 1.5 * minute, id: "m1b", output: 1, cwd: "/w/alpha/src"),
                                    assistantLine(T0 + 2 * minute, id: "m2", output: 50, cwd: "/w/beta"),
                                    assistantLine(T0 + 3 * minute, id: "m3", output: 5, cwd: "/w/beta")])
        env.scan()
        // Listed by the directory it started in, not the last one.
        #expect(try env.store.db.one("SELECT project || ' ' || cwd FROM session") { $0.text(0) } == "alpha /w/alpha")
        let r = try Reports(store: env.store).day("2026-10-20")
        let p = Dictionary(uniqueKeysWithValues: r.projects.map { ($0.project, $0) })
        #expect(p.count == 2 && p["alpha"]?.tokens.output == 101 && p["beta"]?.tokens.output == 55)
        #expect(p["alpha"]?.sessionSec == 1.5 * minute && p["beta"]?.sessionSec == 1.5 * minute && r.sessionSec == 3 * minute)
        let q = try Query(store: env.store).day("2026-10-20")
        #expect(Dictionary(uniqueKeysWithValues: q.byProject.map { ($0.name, $0.tokens) }) == ["alpha": 101, "beta": 55])
        let w = try Query(store: env.store).week(from: "2026-10-20")
        #expect(Dictionary(uniqueKeysWithValues: w.projects[0].map { ($0.project, $0.sessionSec) })
                == ["alpha": 1.5 * minute, "beta": 1.5 * minute])

        // A later `cd` moves nothing that was counted.
        env.append(mainFile, assistantLine(T0 + 4 * minute, id: "m4", output: 1, cwd: "/w/gamma") + "\n")
        env.scan()
        let r2 = try Reports(store: env.store).day("2026-10-20")
        #expect(r2.projects.first { $0.project == "alpha" }?.tokens.output == 101)
        #expect(try env.store.db.one("SELECT project FROM session") { $0.text(0) } == "alpha")
    }

    // MARK: your messages

    @Test func queuedMessagesAreTypedOnlyFromTheHumanOrAChannel() {
        let out = parse([
            queuedLine(T0, prompt: js("also check the tests")),
            queuedLine(T0 + 1, prompt: channelText("ship it"), origin: channelOrigin),
            queuedLine(T0 + 2, prompt: #"[{"type":"text","text":"look"},{"type":"image","source":{"type":"base64","data":"x"}}]"#),
            queuedLine(T0 + 3, prompt: js("<task-notification>x</task-notification>"), origin: #"{"kind":"task-notification"}"#,
                       mode: "task-notification"),
            queuedLine(T0 + 4, prompt: js("<agent-message>x</agent-message>"), origin: #"{"kind":"peer","from":"uds:/x"}"#),
            queuedLine(T0 + 5, prompt: js("<system-reminder>x</system-reminder>"), origin: nil),  // old shape, generated
            queuedLine(T0 + 6, prompt: js("typed long ago"), origin: nil),                        // old shape, typed
        ])
        #expect(out.badLines == 0)
        #expect(out.userMessages.map(\.ts) == [T0, T0 + 1, T0 + 2, T0 + 6])
        #expect(out.userMessages.map(\.text) == ["also check the tests", "ship it", "look", "typed long ago"])
        #expect(out.userMessages.map(\.channel) == [false, true, false, false])
        // Sub-agents never get typed messages.
        #expect(parse([queuedLine(T0, prompt: js("x"))], agent: "agent-a").userMessages.isEmpty)
        // A channel `user` record says so too.
        let rec = userLine(T0, content: channelText("fix"), extra: #","isMeta":true,"origin":\#(channelOrigin),"turnOrigin":"peer""#)
        #expect(parse([rec]).userMessages.map(\.channel) == [true])
    }

    @Test func relayTargets() {
        #expect(ClaudeParser.relayTargets(#"tmux send-keys -t worker-1 "go on" Enter"#) == ["worker-1"])
        #expect(ClaudeParser.relayTargets("tmux send-keys -t =W1:0.1 x Enter; sleep 1; tmux send-keys -t w2 Enter") == ["w1", "w2"])
        #expect(ClaudeParser.relayTargets(#"for s in a b; do tmux send-keys -t "$s" go Enter; done"#) == [""])
        #expect(ClaudeParser.relayTargets("tmux send-keys -t %3 x") == [""])
        #expect(ClaudeParser.relayTargets("tmux send-keys x Enter") == [""])
        #expect(ClaudeParser.relayTargets("tmux -L sock send-keys -tfoo Enter") == ["foo"])
        #expect(ClaudeParser.relayTargets("/usr/bin/tmux send -lt w6 'x' Enter") == ["w6"])
        // Typed text is not read as options; a command that only mentions send-keys is no relay.
        #expect(ClaudeParser.relayTargets(#"tmux send-keys "use -test now" Enter"#) == [""])
        #expect(ClaudeParser.relayTargets("rg -n send-keys Sources; git log -S paste-buffer").isEmpty)
        #expect(ClaudeParser.relayTargets("tmux capture-pane -p -t w").isEmpty)
        #expect(ClaudeParser.relayTargets("tmux load-buffer /tmp/b && tmux paste-buffer -t 'w3'") == ["w3"])
        #expect(ClaudeParser.relayTargets("tmux new-session -d -s w4 claude\ntmux send-keys -t w4 'read it' Enter") == ["w4"])
        // Only Bash calls that type into a terminal make a relay; the command itself is not kept.
        let out = parse([assistantLine(T0, id: "m1", tools: [("toolu_1", "Bash")], command: "tmux send-keys -t w 'x' Enter"),
                         assistantLine(T0 + 1, id: "m2", tools: [("toolu_2", "Bash")], command: "tmux capture-pane -p -t w"),
                         assistantLine(T0 + 2, id: "m3", tools: [("toolu_3", "Grep")], command: "send-keys"),
                         assistantLine(T0 + 3, id: "m4", tools: [("toolu_4", "Bash")], command: "grep -rn send-keys ."),
                         assistantLine(T0 + 4, id: "m5", tools: [("toolu_5", "Bash")], command: "tmux send -t w2 x Enter")])
        #expect(out.relays == [Relay(sessionId: "claude:S", ts: T0, targets: ["w"]), Relay(sessionId: "claude:S", ts: T0 + 4, targets: ["w2"])])
    }

    func userMsgs(_ env: ClaudeEnv, _ s: String) -> Int { env.int("SELECT user_msgs FROM session WHERE id = ?", [.text("claude:" + s)]) }
    func youSec(_ env: ClaudeEnv) -> Double { env.real("SELECT coalesce(sum(\"end\" - start), 0) FROM user_activity") }

    @Test func messagesTypedByAnotherSessionAreNotYours() {
        let env = ClaudeEnv()
        // The worker W gets a brief 1 s after the leader's send-keys, a message from the human at 5 min, another
        // relayed one at 20 min.
        env.write("-w-alpha/W.jsonl", lines: [
            typed(T0 + 1, session: "W"), assistantLine(T0 + minute, id: "w1", output: 1, session: "W"),
            typed(T0 + 5 * minute, session: "W"), assistantLine(T0 + 6 * minute, id: "w2", output: 1, session: "W"),
            typed(T0 + 20 * minute + 1, session: "W"), assistantLine(T0 + 21 * minute, id: "w3", output: 1, session: "W")])
        env.scan()
        #expect(userMsgs(env, "W") == 3 && youSec(env) == 20 * minute)  // no relay seen yet
        env.write("-w-root/L.jsonl", lines: [
            assistantLine(T0, id: "l1", tools: [("toolu_1", "Bash")], command: "tmux send-keys -t w 'read the brief' Enter",
                          session: "L", cwd: "/w/root"),
            assistantLine(T0 + 20 * minute, id: "l2", tools: [("toolu_2", "Bash")], command: "tmux send-keys -t w 'go on' Enter",
                          session: "L", cwd: "/w/root")])
        env.scan()
        #expect(userMsgs(env, "W") == 1)
        #expect(env.int("SELECT count(*) FROM user_action WHERE session_id = 'claude:W' AND kind = 'msg'") == 3)  // turns stay
        // Yours: the end of the answer you replied to (1 min) and your message (5 min). The relayed messages and the
        // `read` before the second one are not.
        #expect(youSec(env) == 4 * minute)
    }

    @Test func aNamedSessionTakesOnlyRelaysAimedAtIt() {
        let env = ClaudeEnv()
        let name = #"{"type":"agent-name","agentName":"Docs site","sessionId":"W"}"#
        env.write("-w-alpha/W.jsonl", lines: [name, typed(T0 + 2, session: "W"), typed(T0 + 10 * minute + 2, session: "W"),
                                              typed(T0 + 20 * minute + 2, session: "W")])
        env.write("-w-root/L.jsonl", lines: [
            assistantLine(T0, id: "l1", tools: [("toolu_1", "Bash")], command: "tmux send-keys -t other x Enter", session: "L"),
            assistantLine(T0 + 10 * minute, id: "l2", tools: [("toolu_2", "Bash")], command: "tmux send-keys -t docs x Enter", session: "L"),
            assistantLine(T0 + 20 * minute, id: "l3", tools: [("toolu_3", "Bash")], command: #"tmux send-keys -t "$w" x Enter"#,
                          session: "L"),
        ])
        // Channel messages are always the human's, even right after a relay.
        env.write("-w-c/C.jsonl", lines: [userLine(T0 + 10 * minute + 3, content: channelText("hi"),
                                                   extra: #","isMeta":true,"origin":\#(channelOrigin),"turnOrigin":"peer""#)])
        // An unnamed session: a relay aimed at another session's name is not for it.
        env.write("-w-o/O.jsonl", lines: [#"{"type":"agent-name","agentName":"Other","sessionId":"O"}"#])
        env.write("-w-u/U.jsonl", lines: [typed(T0 + 3, session: "U"), typed(T0 + 10 * minute + 4, session: "U"),
                                          typed(T0 + 20 * minute + 3, session: "U")])
        env.scan()
        // W: aimed elsewhere: yours; `docs` names it (prefix of "docs site"); `$w` could be anyone: not yours.
        // U: `other` is O's name: yours; `docs` is no session's whole name, `$w` anyone's: not yours.
        #expect(userMsgs(env, "W") == 1 && userMsgs(env, "C") == 1 && userMsgs(env, "U") == 1)
        // A relay of the session itself does not count (it typed into some other pane).
        let env2 = ClaudeEnv()
        env2.write(mainFile, lines: [assistantLine(T0, id: "a1", tools: [("toolu_1", "Bash")], command: "tmux send-keys -t x y"),
                                     typed(T0 + 2)])
        env2.scan()
        #expect(userMsgs(env2, "S") == 1)
    }

    // MARK: v5 migration and recount

    @Test func migrationFromV4KeepsEveryRowAndMarksFilesForRecount() throws {
        let path = tempDir() + "/z.db"
        do {
            let db = try SQLite(path: path)
            for sql in Schema.migrations.prefix(4) { try db.exec(sql) }
            try db.exec("""
                PRAGMA user_version=4;
                INSERT INTO source_file(id, path, tool, offset) VALUES(1, '/gone/s.jsonl', 'claude', 10);
                INSERT INTO source_file(id, path, tool) VALUES(2, 'export:mac', 'export');
                INSERT INTO usage_hour(file_id, session_id, agent, hour, model, input, output, cache_read, cache_write, requests)
                  VALUES(1, 'claude:s', '', 1792490400, 'claude-opus-4-1', 1, 2, 3, 4, 5);
                INSERT INTO msg(id, file_id, hour, model, input, output, cache_read, cache_write) VALUES(9, 1, 1792490400, 'm', 1, 2, 3, 4);
                """)
        }
        let store = try Store(path: path)
        #expect(store.userVersion == Schema.migrations.count)
        #expect(try store.db.one("""
            SELECT input || ',' || output || ',' || cache_read || ',' || cache_write || ',' || cache_write_1h || ',' || requests
                   || ',' || quote(cwd) FROM usage_hour
            """) { $0.text(0) } == "1,2,3,4,0,5,''")
        #expect(try store.db.one("SELECT group_concat(id || ':' || recount) FROM source_file") { $0.text(0) } == "1:1,2:0")
        // The original is gone and there is no archive copy: the rows stay.
        try Ingest(store: store, sources: [ClaudeSource.spec(root: "/gone")]).scan()
        #expect(try store.db.one("SELECT sum(input) FROM usage_hour") { $0.int(0) } == 1)
        #expect(try store.db.one("SELECT recount FROM source_file WHERE id = 1") { $0.int(0) } == 0)
    }

    /// Forgets what v5 adds, as the migration leaves rows of a v4 database: no directory, no 1-hour split.
    func asBeforeV5(_ env: ClaudeEnv) throws {
        try env.store.db.exec("""
            CREATE TEMP TABLE u AS SELECT file_id, session_id, agent, hour, model, sum(input) i, sum(output) o,
              sum(cache_read) cr, sum(cache_write) cw, sum(requests) r, sum(tool_calls) tc FROM usage_hour GROUP BY 1, 2, 3, 4, 5;
            DELETE FROM usage_hour;
            INSERT INTO usage_hour(file_id, session_id, agent, hour, model, input, output, cache_read, cache_write, requests,
              tool_calls) SELECT * FROM u;
            DROP TABLE u;
            UPDATE msg SET cwd = NULL, cache_write_1h = 0; UPDATE source_file SET recount = 1;
            """)
    }
    func split(_ env: ClaudeEnv) -> String? {
        try! env.store.db.one("SELECT group_concat(cwd || ':' || output || ':' || cache_write_1h) FROM usage_hour") { $0.text(0) } ?? nil
    }

    @Test func recountFillsTheNewColumnsFromTheOriginalOrTheArchiveCopy() throws {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1", output: 7, cacheWrite: 10, cacheWrite1h: 4),
                                    assistantLine(T0 + 2 * minute, id: "m2", output: 1, cwd: "/w/beta")])
        env.write("-w-alpha/S2.jsonl", lines: [typed(T0, session: "S2"), assistantLine(T0 + minute, id: "n1", output: 3, session: "S2")])
        env.scan()
        let want = split(env)
        #expect(want == "/w/alpha:7:4,/w/beta:1:0,/w/alpha:3:0")
        let before = env.tokens()

        // Original still there: counted again from byte 0, nothing doubles.
        try asBeforeV5(env)
        #expect(env.scan().fromArchive == 0)
        #expect(split(env) == want && env.tokens() == before)
        #expect(env.int("SELECT sum(recount) FROM source_file") == 0 && env.int("SELECT sum(resets) FROM source_file") == 0)

        // Original gone: S from its archive copy; S2 has no copy, so its rows stay as they were.
        let archive = Archive(store: env.store, dir: tempDir() + "/archive")
        var a = archive; a.idle = 0
        #expect(try a.tick().written == 2)
        try env.store.db.run("DELETE FROM meta WHERE key LIKE 'archive:file:%' AND value LIKE '%S2%'")
        try asBeforeV5(env)
        try FileManager.default.removeItem(atPath: env.path(mainFile))
        try FileManager.default.removeItem(atPath: env.path("-w-alpha/S2.jsonl"))
        #expect(env.scan().fromArchive == 1)
        #expect(split(env) == "/w/alpha:7:4,/w/beta:1:0,:3:0" && env.tokens() == before)
        #expect(env.int("SELECT sum(recount) FROM source_file") == 0)
        #expect(env.int("SELECT user_msgs FROM session WHERE id = 'claude:S'") == 1)
        let copy = try env.store.db.one("SELECT value FROM meta WHERE key LIKE 'archive:file:%'") { $0.text(0) ?? "" } ?? ""
        #expect(FileManager.default.fileExists(atPath: copy) && !FileManager.default.fileExists(atPath: copy + ".recount"))
    }

    @Test func aRecountThatWouldCountOldCopiesAgainKeepsTheOldRows() throws {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1", output: 7)])
        env.scan()
        // A resumed session's file, read after the original but sorting before it, holds a copy of m1 and its own m2.
        env.write("-w-alpha/0.jsonl", lines: [typed(T0, session: "0"), assistantLine(T0 + minute, id: "m1", output: 7, session: "0"),
                                              assistantLine(T0 + 2 * minute, id: "m2", output: 5, session: "0")])
        env.scan()
        func perSession() -> String? {
            try! env.store.db.one("""
                SELECT group_concat(s) FROM (SELECT session_id || '=' || sum(output) s FROM usage_hour GROUP BY session_id
                ORDER BY session_id)
                """) { $0.text(0) } ?? nil
        }
        #expect(perSession() == "claude:0=5,claude:S=7")
        // Request ids older than `dedup_days` have left the ledger.
        try env.store.db.run("DELETE FROM msg WHERE model <> ''")
        try asBeforeV5(env)
        let st = env.scan()
        // 0 would claim m1 again: its recount is rolled back; S's recount reproduces its rows and is kept.
        #expect(st.recountsKept == 1 && perSession() == "claude:0=5,claude:S=7")
        #expect(split(env) == "/w/alpha:7:0,:5:0")
        #expect(env.int("SELECT sum(recount) FROM source_file") == 0)

        // The original gone without a copy: its rows stay, and the copy still does not count m1 again.
        try env.store.db.run("DELETE FROM msg WHERE model <> ''")
        try asBeforeV5(env)
        try FileManager.default.removeItem(atPath: env.path(mainFile))
        #expect(env.scan().recountsKept == 1 && perSession() == "claude:0=5,claude:S=7")
    }

    @Test func aRequestMovedToTheNextHourDoesNotBlockTheRecount() throws {
        // Tailed in two passes the first hour's row went away; read in one batch it nets to an all-zero row.
        let env = ClaudeEnv()
        let h = Double(Time.hour(T0) + 3600)
        env.write(mainFile, lines: [typed(h - 30), assistantLine(h - 1, id: "m1", output: 1)])
        env.scan()
        env.append(mainFile, assistantLine(h + 1, id: "m1", output: 9, cacheWrite: 5, cacheWrite1h: 5) + "\n")
        env.scan()
        #expect(env.int("SELECT count(*) FROM usage_hour") == 1)
        try asBeforeV5(env)
        #expect(env.scan().recountsKept == 0)
        #expect(env.int("SELECT sum(output) FROM usage_hour") == 9 && env.int("SELECT sum(cache_write_1h) FROM usage_hour") == 5)
    }

    // MARK: sessions started at home

    /// A home directory with checkouts: `repo` (a subdir inside), `main` with a worktree `wt` (absolute gitdir) and `wt2`
    /// (relative), `sup` with a submodule `mod`, notes outside any repo, and a git checkout at home itself (dotfiles).
    func homeTree() -> String {
        let h = tempDir()
        for d in ["repo/.git", "repo/src/deep", "main/.git/worktrees/wt", "main/.git/worktrees/wt2", "wt/x", "wt2",
                  "sup/.git/modules/mod", "sup/mod", "notes", ".git"] { Sys.mkdirs(h + "/" + d) }
        Sys.writeFile(h + "/main/.git/worktrees/wt/commondir", Array("../..\n".utf8))
        Sys.writeFile(h + "/main/.git/worktrees/wt2/commondir", Array("../..\n".utf8))
        Sys.writeFile(h + "/wt/.git", Array("gitdir: \(h)/main/.git/worktrees/wt\n".utf8))
        Sys.writeFile(h + "/wt2/.git", Array("gitdir: ../main/.git/worktrees/wt2\n".utf8))
        Sys.writeFile(h + "/sup/mod/.git", Array("gitdir: ../.git/modules/mod\n".utf8))
        return h
    }

    @Test func directoriesResolveToTheirGitCheckout() {
        let h = homeTree()
        func p(_ rel: String) -> String { Projects.resolve(h + rel, home: h).project }
        #expect(p("/repo") == "repo" && p("/repo/src/deep") == "repo")
        #expect(p("/wt") == "main" && p("/wt/x") == "main" && p("/wt2") == "main" && p("/main") == "main")
        #expect(p("/sup/mod") == "mod" && p("/sup") == "sup")
        #expect(p("/notes") == "notes")            // not the dotfiles checkout at home
        #expect(p("/gone/away") == "away")         // no longer on disk: its last component
        #expect(Projects.resolve(h, home: h).home && Projects.resolve(h + "/", home: h).home && Projects.resolve("/", home: h).home)
        #expect(!Projects.resolve(h + "/repo", home: h).home)
    }

    @Test func aSessionStartedAtHomeCountsEachCheckout() throws {
        let h = homeTree()
        let env = ClaudeEnv { $0.home = h }
        env.write("-h/H.jsonl", lines: [typed(T0, session: "H", cwd: h),
                                        assistantLine(T0 + minute, id: "h1", output: 1, session: "H", cwd: h),
                                        assistantLine(T0 + 2 * minute, id: "h2", output: 10, session: "H", cwd: h + "/repo/src/deep"),
                                        assistantLine(T0 + 3 * minute, id: "h3", output: 100, session: "H", cwd: h + "/wt/x"),
                                        assistantLine(T0 + 4 * minute, id: "h4", output: 1000, session: "H", cwd: h + "/notes")])
        // A session started in a project folder keeps the old rule: inside it, its project; outside, the last component.
        env.write("-r/R.jsonl", lines: [typed(T0, session: "R", cwd: h + "/repo"),
                                        // the call that runs `cd` is still in the start folder
                                        assistantLine(T0 + 30, id: "r0", session: "R", cwd: h + "/repo"),
                                        assistantLine(T0 + minute, id: "r1", output: 3, session: "R", cwd: h + "/repo/src"),
                                        assistantLine(T0 + 2 * minute, id: "r2", output: 4, session: "R", cwd: h + "/wt/x")])
        env.scan()
        let home = Sys.basename(h)
        let want = [home: 1, "repo": 13, "main": 100, "notes": 1000, "x": 4]
        let r = try Reports(store: env.store).day("2026-10-20")
        #expect(Dictionary(uniqueKeysWithValues: r.projects.map { ($0.project, $0.tokens.output) }) == want)
        let q = try Query(store: env.store).day("2026-10-20")
        #expect(Dictionary(uniqueKeysWithValues: q.byProject.map { ($0.name, $0.tokens) }) == want)
        #expect(env.int("SELECT count(*) FROM dir_project WHERE home = 1") == 1)

        // Another machine gets the same projects from the exported directories, after they are gone here too.
        var lines: [String] = []
        try Export.run(store: env.store, since: 0) { lines.append($0) }
        #expect(lines.contains { $0.contains(#""type":"dir""#) })
        try FileManager.default.removeItem(atPath: h)
        let dst = try Store(path: ":memory:")
        try ExportImport(store: dst, source: "box").apply(lines)
        #expect(Dictionary(uniqueKeysWithValues: try Query(store: dst).day("2026-10-20").byProject.map { ($0.name, $0.tokens) })
                == want)
    }

    @Test func exportKeepsTheOldUsageShapeAndAddsTheSplit() throws {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1", output: 4, cacheWrite: 10, cacheWrite1h: 6),
                                    assistantLine(T0 + 2 * minute, id: "m2", output: 3, cwd: "/w/beta")])
        env.scan()
        var lines: [String] = []
        try Export.run(store: env.store, since: 0) { lines.append($0) }
        let day = try #require(lines.compactMap { JValue.parse($0) }.first { $0["type"]?.string == "day" })
        let usage = day["usage"]?.array ?? [], split = day["usage_cwd"]?.array ?? []
        #expect(usage.count == 1 && usage.first?["cwd"] == nil && usage.first?["output"]?.double == 7)
        #expect(usage.first?["cache_write_1h"]?.double == 6)
        #expect(split.compactMap { $0["cwd"]?.string } == ["/w/alpha", "/w/beta"])
        #expect(day["rows"]?.array?.contains { $0["cache_write_1h"]?.double == 6 } == true)
        // A new client stores the split; one fed an export without it (an older server) still gets every token.
        for keepSplit in [true, false] {
            let dst = try Store(path: ":memory:")
            let feed = lines.map { keepSplit ? $0 : $0.replacingOccurrences(of: #""usage_cwd":["#, with: #""old_usage_cwd":["#) }
            try ExportImport(store: dst, source: "box").apply(feed)
            let q = try Query(store: dst).day("2026-10-20")
            #expect(q.tokens.output == 7 && q.tokens.cacheWrite1h == 6)
            #expect(Dictionary(uniqueKeysWithValues: q.byProject.map { ($0.name, $0.tokens) })
                    == (keepSplit ? ["alpha": 14, "beta": 3] : ["alpha": 17]))
        }
    }

    @Test func aCopyShorterThanWhatWasCountedIsNotUsed() throws {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1", output: 7)])
        env.scan()
        var a = Archive(store: env.store, dir: tempDir() + "/archive"); a.idle = 0
        try a.tick()
        env.append(mainFile, assistantLine(T0 + 2 * minute, id: "m2", output: 5) + "\n")
        env.scan()
        try asBeforeV5(env)
        try FileManager.default.removeItem(atPath: env.path(mainFile))
        #expect(env.scan().fromArchive == 0)
        #expect(split(env) == ":12:0")  // kept as it was: nothing lost
    }
}
