import Foundation
import Testing
@testable import ZagonCore

final class FakeChannel: Channel, @unchecked Sendable {
    let name = "fake"
    var ok = true
    var sent: [Message] = []
    func send(_ m: Message) -> Bool { if ok { sent.append(m) }; return ok }
}

/// Container runs with TZ=UTC, so local days are UTC days here.
let day0 = Time.dayBounds("2026-10-30")!.start

@Suite struct NotifyConfigTests {
    @Test func parsesKeysCommentsAndDefaults() {
        let c = NotifyConfig.parse("""
            [notify]
            waiting_minutes = 5 # comment
            long_work_minutes = 0
            summary_at = "21:30"
            worklog_at = ""
            quiet = "22:00-07:30"
            enabled = false
            [notify.limits]
            claude.five_hour = [95, 80, 90, 42, 101, 77]   # sorted, off-grid values dropped
            codex.week = []
            "codex.gpt-5-codex" = [60]
            [telegram]
            token_file = "~/.config/zagon/tok"
            chat_id = 123456789
            commands = false
            [ntfy]
            topic = "zt"
            [summary]
            engine = 'codex'
            timeout = 30
            """, home: "/h")
        #expect(c.limits == ["claude.five_hour": [80, 90, 95], "codex.week": [], "codex.gpt-5-codex": [60]])
        #expect(c.thresholds("claude.week") == [80, 95] && c.thresholds("codex.week") == [])
        #expect(c.waitingMinutes == 5 && c.longWorkMinutes == 0 && !c.enabled)
        #expect(c.summaryAt == 21 * 60 + 30 && c.worklogAt == nil)
        #expect(c.quiet == ClockRange(start: 22 * 60, end: 7 * 60 + 30))
        #expect(c.telegramTokenFile == "/h/.config/zagon/tok" && c.telegramChatId == "123456789" && !c.telegramCommands)
        #expect(c.ntfyTopic == "zt" && c.summaryEngine == "codex" && c.summaryTimeout == 30)
        let d = NotifyConfig.parse("", home: "/h")
        #expect(d == NotifyConfig())
        #expect(d.thresholds("claude.five_hour") == [80, 95] && d.summaryAt == 20 * 60 && d.worklogAt == 19 * 60 && d.quiet == ClockRange(start: 1380, end: 480))
        #expect(d.quiet!.contains(23 * 60 + 30) && d.quiet!.contains(7 * 60) && !d.quiet!.contains(8 * 60) && !d.quiet!.contains(12 * 60))
    }
}

@Suite struct NotifierTests {
    func setUp(_ config: NotifyConfig = NotifyConfig()) throws -> (Store, Notifier, FakeChannel) {
        let store = try Store(path: ":memory:"), ch = FakeChannel()
        var c = config
        c.quiet = nil
        c.summaryAt = nil; c.worklogAt = nil
        if c.lang == .auto { c.lang = .ru }  // the expectations are Russian unless a test asks for English
        let n = Notifier(store: store, config: c, channels: [ch])
        n.log = { _ in }
        return (store, n, ch)
    }

    func limit(_ s: Store, _ pct: Double, at ts: Double, resets: Double?, tool: ToolKind = .claude, window: String = "five_hour") throws {
        try s.addLimitSnapshot(LimitSnapshot(tool: tool, window: window, usedPct: pct, resetsAt: resets, windowMinutes: 300, ts: ts))
    }

    @Test func limitThresholdsOncePerWindowAndReset() throws {
        let (s, n, ch) = try setUp()
        let t = day0 + 10 * 3600, resets = t + 2 * 3600
        try limit(s, 70, at: t, resets: resets)
        #expect(try n.tick(now: t + 1).isEmpty)
        try limit(s, 82, at: t + 600, resets: resets)
        #expect(try n.tick(now: t + 601) == ["limit:claude:five_hour:80"])
        #expect(ch.sent.last?.title == "Claude: лимит 5 ч — 80 %")
        // pace 12 %/10 min from 70 % → 100 % in 15 min, before the reset
        #expect(ch.sent.last?.text.contains("Кончится к 10:25") == true)
        #expect(try n.tick(now: t + 700).isEmpty)
        try limit(s, 86, at: t + 900, resets: resets + 30)  // a drifting reset time is the same window
        #expect(try n.tick(now: t + 901).isEmpty)
        try limit(s, 96, at: t + 1200, resets: resets)
        #expect(try n.tick(now: t + 1201) == ["limit:claude:five_hour:95"])
        #expect(ch.sent.last?.priority == 5)
        // The window resets: one "reset" notification, then the next window starts over.
        #expect(try n.tick(now: resets + 60) == ["reset:claude:five_hour"])
        #expect(ch.sent.last?.text == "Было 96 %.")
        #expect(try n.tick(now: resets + 120).isEmpty)
        try limit(s, 81, at: resets + 3600, resets: resets + 5 * 3600)
        #expect(try n.tick(now: resets + 3601) == ["limit:claude:five_hour:80"])
    }

    @Test func jumpSendsOnlyTheTopThresholdAndStaleIsSkipped() throws {
        let (s, n, ch) = try setUp()
        let t = day0 + 10 * 3600
        try limit(s, 97, at: t, resets: t + 3600, tool: .codex, window: "primary")
        #expect(try n.tick(now: t + 5) == ["limit:codex:primary:95"])
        try limit(s, 97, at: t + 60, resets: t + 3600, tool: .codex, window: "primary")
        #expect(try n.tick(now: t + 65).isEmpty)  // 80 was marked together with 95
        // A reading from two hours ago (service was down): marked, not sent.
        try limit(s, 85, at: t - 2 * 3600, resets: t + 3 * 3600, window: "seven_day")
        #expect(try n.tick(now: t + 70).isEmpty)
        #expect(ch.sent.count == 1)
    }

    @Test func categories() throws {
        #expect(NotifyConfig.limitCategory(.claude, "five_hour") == "claude.five_hour")
        #expect(NotifyConfig.limitCategory(.claude, "seven_day") == "claude.week")
        #expect(NotifyConfig.limitCategory(.codex, "primary") == "codex.five_hour")
        #expect(NotifyConfig.limitCategory(.codex, "secondary") == "codex.week")
        #expect(NotifyConfig.limitCategory(.codex, "gpt-5-codex:secondary") == "codex.gpt-5-codex")
        var c = NotifyConfig()
        c.limits = ["claude.week": [], "codex.gpt-5-codex": [50]]
        let (s, n, ch) = try setUp(c)
        let t = day0 + 10 * 3600
        try limit(s, 90, at: t, resets: t + 600, window: "seven_day")
        try limit(s, 55, at: t, resets: t + 600, tool: .codex, window: "gpt-5-codex:secondary")
        try limit(s, 55, at: t, resets: t + 600, tool: .codex, window: "secondary")  // default [80, 95]: below
        #expect(try n.tick(now: t + 1) == ["limit:codex:gpt-5-codex:secondary:50"])
        #expect(ch.sent.last?.title == "Codex: лимит 5 ч — 50 %")  // window length comes from window_minutes
        #expect(try n.tick(now: t + 700) == ["reset:codex:gpt-5-codex:secondary"])  // claude.week is off: no reset either
    }

    @Test func quietHoursMarkWithoutSending() throws {
        let (s, n, ch) = try setUp()
        n.config.quiet = ClockRange(start: 23 * 60, end: 8 * 60)
        let t = day0 + 23.5 * 3600
        try limit(s, 90, at: t, resets: t + 3600)
        #expect(try n.tick(now: t + 1).isEmpty)
        #expect(try n.tick(now: day0 + 24 * 3600 + 8.5 * 3600).isEmpty)  // not delivered later either
        #expect(ch.sent.isEmpty)
    }

    func session(_ s: Store, _ id: String, status: String, at: Double, lastAt: Double?) throws {
        try s.mergeSession(SessionMeta(id: id, tool: .claude, project: "api-server", title: "fix login flow"))
        try s.setStatus(sessionId: id, tool: .claude, status: status, at: at)
        try s.db.run("UPDATE session SET last_at = ? WHERE id = ?", [.of(lastAt), .text(id)])
    }

    @Test func waitingLongerThanConfigured() throws {
        let (s, n, ch) = try setUp()
        let t = day0 + 11 * 3600
        try session(s, "claude:a", status: "waiting_permission", at: t, lastAt: t - 5)
        try session(s, "claude:fresh", status: "waiting_input", at: t, lastAt: nil)        // just opened
        try session(s, "claude:old", status: "waiting_input", at: t, lastAt: t - 7200)     // resumed, nothing new
        #expect(try n.tick(now: t + 9 * 60).isEmpty)
        #expect(try n.tick(now: t + 11 * 60) == ["wait:claude:a"])
        let m = try #require(ch.sent.last)
        #expect(m.title == "Ждёт тебя 11 мин" && m.text == "api-server — fix login flow. Просит разрешение.")
        #expect(m.buttons == [[Message.Button("Команда подключения", "resume:claude:a")]])
        #expect(try n.tick(now: t + 20 * 60).isEmpty)
        // Answered, worked, waits again: a new occurrence.
        try s.setStatus(sessionId: "claude:a", tool: .claude, status: "working", at: t + 21 * 60)
        try session(s, "claude:a", status: "waiting_input", at: t + 30 * 60, lastAt: t + 30 * 60)
        #expect(try n.tick(now: t + 41 * 60) == ["wait:claude:a"])
        #expect(ch.sent.last?.text.hasSuffix("Ждёт ответа.") == true)
    }

    @Test func longWorkFinished() throws {
        let (s, n, ch) = try setUp()
        let t = day0 + 12 * 3600
        func work(_ id: String, _ minutes: Double) throws {
            try s.mergeSession(SessionMeta(id: id, tool: .claude, project: "p-" + id.suffix(1)))
            try s.db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(1, ?, ?, ?, 'working')",
                         [.text(id), .real(t - minutes * 60), .real(t)])
        }
        try work("claude:a", 20); try work("claude:b", 10); try work("claude:c", 30); try work("claude:d", 25)
        try s.setStatus(sessionId: "claude:a", tool: .claude, status: "waiting_input", at: t + 5)
        try s.setStatus(sessionId: "claude:b", tool: .claude, status: "waiting_input", at: t + 5)
        try s.setStatus(sessionId: "claude:c", tool: .claude, status: "waiting_permission", at: t)
        // d: no hooks → finished only after 10 minutes of silence
        #expect(try n.tick(now: t + 60) == ["done:claude:a"])
        #expect(ch.sent.last?.title == "Готово: p-a" && ch.sent.last?.text == "p-a — работала 20 мин.")
        #expect(try n.tick(now: t + 11 * 60) == ["done:claude:d"])
        #expect(try n.tick(now: t + 20 * 60).isEmpty)
    }

    /// A Claude session that worked `minutes` up to `t` and stopped (Stop hook at t + 5); its transcript is `path`.
    func stopped(_ s: Store, _ id: String, file: Int, minutes: Double, at t: Double, path: String? = nil) throws {
        try session(s, id, status: "waiting_input", at: t + 5, lastAt: t)
        try s.db.run("INSERT INTO source_file(id, path, tool, session_id) VALUES(?, ?, 'claude', ?)",
                     [.of(file), .text(path ?? "/nonexistent/\(id).jsonl"), .text(id)])
        try s.db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(?, ?, ?, ?, 'working')",
                     [.of(file), .text(id), .real(t - minutes * 60), .real(t)])
    }

    @Test func doneWaitsForTheSessionsOwnSubAgent() throws {
        let (s, n, _) = try setUp()
        let t = day0 + 12 * 3600
        try stopped(s, "claude:a", file: 1, minutes: 20, at: t)
        try s.db.run("INSERT INTO source_file(id, path, tool, session_id, agent) VALUES(2, '/x/agent-1.jsonl', 'claude', 'claude:a', 'agent-1')")
        try s.db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(2, 'claude:a', ?, ?, 'working')",
                     [.real(t - 120), .real(t + 40)])
        #expect(try n.tick(now: t + 60).isEmpty)  // the sub-agent wrote 20 s ago
        #expect(try n.tick(now: t + 101) == ["done:claude:a"])
    }

    @Test func doneWaitsForBackgroundCallsOfThisTurn() throws {
        let (s, n, _) = try setUp()
        let t = day0 + 12 * 3600, dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func launch(_ id: String, _ ts: Double, agent: Bool = false) -> String {
            let input = agent ? #"{"prompt":"x","run_in_background":"true"}"# : #"{"command":"x","run_in_background":true}"#
            return #"{"type":"assistant","timestamp":"\#(iso(ts))","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(agent ? "Agent" : "Bash")","input":\#(input)}]}}"#
        }
        // a: a watcher launched hours ago never reports; a sub-agent of this turn reports later.
        let a = dir + "/a.jsonl", b = dir + "/b.jsonl"
        _ = FileManager.default.createFile(atPath: a, contents: Data((launch("toolu_old", t - 3 * 3600) + "\n" + launch("toolu_bg1", t - 300, agent: true) + "\n").utf8))
        _ = FileManager.default.createFile(atPath: b, contents: Data((launch("toolu_b", t - 300) + "\n").utf8))
        try stopped(s, "claude:a", file: 1, minutes: 20, at: t, path: a)
        try stopped(s, "claude:b", file: 2, minutes: 20, at: t, path: b)
        try s.setStatus(sessionId: "claude:b", tool: .claude, status: "ended", at: t + 5)  // closed: nothing will come back
        #expect(try n.tick(now: t + 60) == ["done:claude:b"])
        let h = try #require(FileHandle(forWritingAtPath: a))
        h.seekToEndOfFile()
        h.write(Data((#"{"type":"user","timestamp":"\#(iso(t + 90))","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>\n<tool-use-id>toolu_bg1</tool-use-id>\n</task-notification>"}}"# + "\n").utf8))
        h.closeFile()
        #expect(try n.tick(now: t + 80).isEmpty)  // written later than now (replay at a past time)
        #expect(try n.tick(now: t + 120) == ["done:claude:a"])
    }

    @Test func doneCoversTheWaitOfTheSameStop() throws {
        let (s, n, ch) = try setUp()
        let t = day0 + 12 * 3600
        try stopped(s, "claude:a", file: 1, minutes: 20, at: t)
        #expect(try n.tick(now: t + 60) == ["done:claude:a"])
        #expect(try n.tick(now: t + 16 * 60).isEmpty)  // no "waiting 15 min" after "done"
        // A short turn later and a new stop: its wait is news.
        try s.db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(1, 'claude:a', ?, ?, 'working')",
                     [.real(t + 20 * 60), .real(t + 25 * 60)])
        try session(s, "claude:a", status: "waiting_input", at: t + 25 * 60, lastAt: t + 25 * 60)
        #expect(try n.tick(now: t + 36 * 60) == ["wait:claude:a"])
        #expect(ch.sent.map(\.title) == ["Готово: api-server", "Ждёт тебя 11 мин"])
    }

    @Test func unsentMessageIsRetriedOnlyForItsOccurrence() throws {
        let (s, n, ch) = try setUp()
        let t = day0 + 11 * 3600
        try session(s, "claude:a", status: "waiting_input", at: t, lastAt: t)
        ch.ok = false
        #expect(try n.tick(now: t + 11 * 60).isEmpty)
        #expect(n.pending["wait:claude:a"]?.message.title == "Ждёт тебя 11 мин")
        // Answered and waiting again before any channel came back: the new wait is built fresh.
        try session(s, "claude:a", status: "waiting_input", at: t + 30 * 60, lastAt: t + 30 * 60)
        ch.ok = true
        #expect(try n.tick(now: t + 42 * 60) == ["wait:claude:a"])
        #expect(ch.sent.map(\.title) == ["Ждёт тебя 12 мин"])

        // Stale, quiet hours and nothing to send drop the unsent message too.
        let (s2, n2, ch2) = try setUp()
        try session(s2, "claude:a", status: "waiting_input", at: t, lastAt: t)
        ch2.ok = false
        #expect(try n2.tick(now: t + 11 * 60).isEmpty)
        #expect(n2.pending.keys.sorted() == ["wait:claude:a"])
        #expect(try n2.tick(now: t + 10 * 60 + 3601).isEmpty)  // an hour past due
        #expect(n2.pending.isEmpty)
        try session(s2, "claude:b", status: "waiting_input", at: t + 2 * 3600, lastAt: t + 2 * 3600)
        #expect(try n2.tick(now: t + 2 * 3600 + 11 * 60).isEmpty)
        #expect(n2.pending.keys.sorted() == ["wait:claude:b"])
        n2.config.quiet = ClockRange(start: 13 * 60, end: 14 * 60)
        #expect(try n2.tick(now: t + 2 * 3600 + 12 * 60).isEmpty)
        #expect(n2.pending.isEmpty)

        let (_, n3, ch3) = try setUp()
        n3.config.summaryAt = 20 * 60
        n3.summary = { $0 == "2026-10-30" ? Message(title: "Сводка дня", text: $0) : nil }
        ch3.ok = false
        #expect(try n3.tick(now: day0 + 20 * 3600 + 5).isEmpty)
        #expect(n3.pending["summary"] != nil)
        ch3.ok = true
        #expect(try n3.tick(now: day0 + 86400 + 20 * 3600 + 5).isEmpty)  // next day: no summary, not yesterday's
        #expect(n3.pending.isEmpty && ch3.sent.isEmpty)
    }

    @Test func englishMessages() throws {
        var c = NotifyConfig()
        c.lang = .en
        let (s, n, ch) = try setUp(c)
        let t = day0 + 10 * 3600, resets = t + 2 * 3600
        try stopped(s, "claude:b", file: 1, minutes: 20, at: t)
        try limit(s, 70, at: t, resets: resets)
        try limit(s, 82, at: t + 600, resets: resets)
        try session(s, "claude:a", status: "waiting_permission", at: t + 60, lastAt: t)
        #expect(try n.tick(now: t + 601) == ["done:claude:b", "limit:claude:five_hour:80"])
        #expect(try n.tick(now: t + 720) == ["wait:claude:a"])
        #expect(try n.tick(now: resets + 60) == ["reset:claude:five_hour"])
        #expect(ch.sent.map(\.title) == ["Done: api-server", "Claude: 5 h limit — 80%", "Waiting for you 11 min", "Claude: 5 h limit reset"])
        #expect(ch.sent.map(\.text) == ["api-server — fix login flow — worked 20 min.", "Now 82%. Runs out by 10:25 at this pace. Resets at 12:00.",
                                        "api-server — fix login flow. Asks for permission.", "Was 82%."])
        #expect(ch.sent[2].buttons == [[Message.Button("Resume command", "resume:claude:a")]])
        try s.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "seven_day", usedPct: 96, resetsAt: resets + 7 * 86400,
                                             windowMinutes: 10080, ts: resets + 120))
        #expect(try n.tick(now: resets + 121) == ["limit:claude:seven_day:95"])
        #expect(ch.sent.last?.title == "Claude: weekly limit — 95%")
    }

    @Test func clockEventsOncePerDayAndRetryWithoutRebuild() throws {
        let (_, n, ch) = try setUp()
        n.config.summaryAt = 20 * 60; n.config.worklogAt = 19 * 60
        var built: [String] = []
        n.summary = { built.append($0); return Message(title: "Сводка дня", text: $0) }
        #expect(try n.tick(now: day0 + 18 * 3600).isEmpty)
        #expect(try n.tick(now: day0 + 19.5 * 3600).isEmpty)  // worklog: no provider (tasks package) yet
        n.worklogPlan = { Message(title: "Что логировать", text: $0, buttons: [[.init("Залогировать", "log:ok:\($0)")]]) }
        #expect(try n.tick(now: day0 + 19.6 * 3600).isEmpty)  // already handled today
        ch.ok = false
        #expect(try n.tick(now: day0 + 20 * 3600 + 5).isEmpty)
        ch.ok = true
        #expect(try n.tick(now: day0 + 20 * 3600 + 35) == ["summary"])
        #expect(built == ["2026-10-30"] && ch.sent.map(\.text) == ["2026-10-30"])
        #expect(try n.tick(now: day0 + 23 * 3600).isEmpty)
        #expect(try n.tick(now: day0 + 86400 + 19 * 3600 + 1) == ["worklog"])
        #expect(ch.sent.last?.buttons.first?.first?.data == "log:ok:2026-10-31")
    }
}

/// A local stand-in for api.telegram.org and ntfy.sh (Python in the container): records every request.
final class MockHTTP {
    let proc = Process()
    let stdin = Pipe()
    let port: Int
    let log: String
    static let script = #"""
        import base64, json, os, sys, threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        log, updates_file = sys.argv[1], sys.argv[2]
        # exit when the test process goes away (its end of our stdin closes)
        threading.Thread(target=lambda: (sys.stdin.read(), os._exit(0)), daemon=True).start()
        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length') or 0)
                body = self.rfile.read(n)
                with open(log, 'a') as f:
                    f.write(json.dumps({'path': self.path, 'headers': dict(self.headers),
                                        'body': base64.b64encode(body).decode()}) + '\n')
                if self.path.endswith('/getUpdates'):
                    try:
                        res = json.load(open(updates_file)); open(updates_file, 'w').write('[]')
                    except Exception:
                        res = []
                    out = {'ok': True, 'result': res}
                elif '/bot' in self.path:
                    out = {'ok': True, 'result': {'message_id': 1}}
                else:
                    out = {'id': 'm1', 'event': 'message'}
                b = json.dumps(out).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
            def log_message(self, *a): pass
        s = ThreadingHTTPServer(('127.0.0.1', 0), H)
        print(s.server_address[1], flush=True)
        s.serve_forever()
        """#

    init(dir: String) throws {
        log = dir + "/requests.ndjson"
        let script = dir + "/mock.py"
        try MockHTTP.script.write(toFile: script, atomically: true, encoding: .utf8)
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-I", script, log, dir + "/updates.json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardInput = stdin
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        var line = Data()
        while !line.contains(0x0A) {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { throw CocoaError(.fileReadUnknown) }  // the mock did not start
            line.append(d)
        }
        port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
    }
    deinit { proc.terminate() }

    struct Request { var path: String; var headers: [String: String]; var body: [UInt8] }
    var requests: [Request] {
        (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").compactMap { l in
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] else { return nil }
            return Request(path: o["path"] as! String, headers: o["headers"] as! [String: String],
                           body: Array(Data(base64Encoded: o["body"] as! String)!))
        } ?? []
    }
}

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") && Sys.which("curl") != nil,
                             "needs python3 and curl"))
struct ChannelTests {

    func config(_ dir: String, _ mock: MockHTTP) -> NotifyConfig {
        Sys.writeFile(dir + "/token", Array("123:SECRET-token\n".utf8))
        var c = NotifyConfig()
        c.telegramTokenFile = dir + "/token"; c.telegramChatId = "123456789"; c.telegramAPI = "http://127.0.0.1:\(mock.port)"
        c.ntfyURL = "http://127.0.0.1:\(mock.port)/"; c.ntfyTopic = "zagon-test"
        return c
    }

    @Test func telegramAndNtfyRequests() throws {
        let dir = makeTempDir(), mock = try MockHTTP(dir: dir)
        let chans = config(dir, mock).channels(ZagonPaths(home: dir, dir: dir))
        #expect(chans.map(\.name) == ["telegram", "ntfy"])
        let m = Message(title: "Лимит <5 ч>", text: "1 < 2 & \"3\"", priority: 5, tags: ["warning"],
                        buttons: [[.init("Команда подключения", "resume:claude:a")]])
        #expect(chans.allSatisfy { $0.send(m) })
        let png = Timeline.png(rows: [[Timeline.Span(day0, day0 + 3600, .working)]], from: day0, to: day0 + 4 * 3600)
        #expect(chans[0].send(Message(title: "Сводка", text: "день", photo: png)))
        var long = Message(title: "Сводка", text: String(repeating: "а", count: 1500), photo: png)
        long.buttons = [[.init("Подробнее", "day:2026-10-30")]]
        #expect(chans[0].send(long))

        let r = mock.requests
        #expect(r.map(\.path) == ["/bot123:SECRET-token/sendMessage", "/zagon-test", "/bot123:SECRET-token/sendPhoto",
                                  "/bot123:SECRET-token/sendPhoto", "/bot123:SECRET-token/sendMessage"])
        let msg = try #require(JValue.parse(r[0].body))
        #expect(msg["chat_id"] == .number("123456789") && msg["parse_mode"]?.string == "HTML")
        #expect(msg["text"]?.string == "<b>Лимит &lt;5 ч&gt;</b>\n1 &lt; 2 &amp; \"3\"")
        #expect(msg["reply_markup"]?["inline_keyboard"]?.array?.first?.array?.first?["callback_data"]?.string == "resume:claude:a")
        // ntfy: body is the plain text, the Cyrillic title RFC 2047-encoded
        #expect(r[1].body == Array("1 < 2 & \"3\"".utf8))
        #expect(r[1].headers["Title"] == "=?UTF-8?B?" + Ntfy.base64(Array("Лимит <5 ч>".utf8)) + "?=")
        #expect(r[1].headers["Priority"] == "5" && r[1].headers["Tags"] == "warning")
        // photo: multipart with the PNG and the caption
        #expect(r[2].headers["Content-Type"]?.hasPrefix("multipart/form-data") == true)
        #expect(r[2].body.count > png.count && String(decoding: r[2].body, as: UTF8.self).contains("<b>Сводка</b>\nдень"))
        // too long for a caption: picture with the title, then the text with the buttons
        #expect(String(decoding: r[3].body, as: UTF8.self).contains("name=\"caption\"\r\n\r\n<b>Сводка</b>\n\r\n"))
        #expect(JValue.parse(r[4].body)?["reply_markup"] != nil)
        #expect(Sys.listDir(dir + "/run").isEmpty)  // temporary photo files removed
    }

    @Test func botAnswersOnlyItsChat() throws {
        let dir = makeTempDir(), mock = try MockHTTP(dir: dir)
        let store = try Store(path: ":memory:")
        try store.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: 62, resetsAt: Sys.now() + 3600,
                                                 windowMinutes: 300, ts: Sys.now() - 120))
        try store.mergeSession(SessionMeta(id: "claude:abc", tool: .claude, cwd: "/w/my repo"))
        Sys.writeFile(dir + "/updates.json", Array("""
            [{"update_id": 10, "message": {"chat": {"id": 123456789}, "text": "/limits@example_bot"}},
             {"update_id": 11, "message": {"chat": {"id": 555}, "text": "/today"}},
             {"update_id": 12, "callback_query": {"id": "q1", "data": "resume:claude:abc", "message": {"chat": {"id": 123456789}}}},
             {"update_id": 13, "callback_query": {"id": "q2", "data": "log:ok", "message": {"chat": {"id": 123456789}}}}]
            """.utf8))
        let tg = try #require(config(dir, mock).channels(ZagonPaths(home: dir, dir: dir)).first as? Telegram)
        let bot = Bot(telegram: tg, store: store, lang: .ru)
        bot.log = { _ in }
        var seen: [String] = []
        bot.onCallback = { seen.append($0); return Message(title: "", text: "залогировано") }
        #expect(bot.pollOnce(timeout: 0) == 4)
        #expect(bot.offset == 14)
        let r = mock.requests
        #expect(r.map { $0.path.split(separator: "/").last! } == ["getUpdates", "sendMessage", "answerCallbackQuery", "sendMessage",
                                                                   "answerCallbackQuery", "sendMessage"])
        let limits = try #require(JValue.parse(r[1].body)?["text"]?.string)
        #expect(limits.contains("Claude 5 ч: 62 %") && limits.contains("(данные 2 мин назад)"))
        #expect(JValue.parse(r[3].body)?["text"]?.string == "cd '/w/my repo' &amp;&amp; claude --resume abc")
        #expect(seen == ["log:ok"])
        #expect(JValue.parse(r[0].body)?["offset"] == .number("0"))
        #expect(bot.pollOnce(timeout: 0) == 0)
        #expect(JValue.parse(mock.requests.last!.body)?["offset"] == .number("14"))
    }
}

@Suite struct TimelineTests {
    /// Chunks of a PNG with CRCs checked; nil if malformed.
    func chunks(_ b: [UInt8]) -> [(String, [UInt8])]? {
        guard b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        var i = 8, out: [(String, [UInt8])] = []
        func u32(_ k: Int) -> Int { Int(b[k]) << 24 | Int(b[k + 1]) << 16 | Int(b[k + 2]) << 8 | Int(b[k + 3]) }
        while i + 12 <= b.count {
            let n = u32(i), td = Array(b[(i + 4)..<(i + 8 + n)])
            guard Timeline.crc32(td) == UInt32(u32(i + 8 + n)) else { return nil }
            out.append((String(decoding: td.prefix(4), as: UTF8.self), Array(td.dropFirst(4))))
            i += 12 + n
        }
        return i == b.count ? out : nil
    }

    @Test func validPNGUnderSizeLimit() throws {
        var rows: [[Timeline.Span]] = []
        for k in 0..<20 {
            let a: Double = day0 + Double(k) * 1800
            rows.append([Timeline.Span(a, a + 5400, .working), Timeline.Span(a + 5400, a + 6000, .waiting)])
        }
        rows.append([Timeline.Span(day0 + 3600, day0 + 7200, .user)])
        let png = Timeline.png(rows: rows, from: day0, to: day0 + 24 * 3600)
        #expect(png.count <= 200 * 1024)
        let c = try #require(chunks(png))
        #expect(c.map { $0.0 } == ["IHDR", "PLTE", "IDAT", "IEND"])
        let ihdr: [UInt8] = c[0].1
        func u32(_ k: Int) -> Int { Int(ihdr[k]) << 24 | Int(ihdr[k + 1]) << 16 | Int(ihdr[k + 2]) << 8 | Int(ihdr[k + 3]) }
        let w = u32(0), h = u32(4)
        #expect(w == 720 && h == Timeline.top + Timeline.maxRows * Timeline.rowH + 6 && ihdr[8] == 4 && ihdr[9] == 3)
        // Unpack the stored deflate blocks and check the adler and one pixel of the first bar.
        let z = c[2].1
        var raw: [UInt8] = [], i = 2
        while true {
            let final = z[i] & 1 == 1, n = Int(z[i + 1]) | Int(z[i + 2]) << 8
            raw += z[(i + 5)..<(i + 5 + n)]; i += 5 + n
            if final { break }
        }
        #expect(raw.count == h * (1 + w / 2))
        #expect(Timeline.be32(Timeline.adler32(raw)) == Array(z[i..<(i + 4)]))
        let y = Timeline.top + (Timeline.rowH - Timeline.barH) / 2 + 2, x = Timeline.left + 5
        let byte = raw[y * (1 + w / 2) + 1 + x / 2]
        #expect((x % 2 == 0 ? byte >> 4 : byte & 0xF) == Timeline.Kind.working.rawValue)
    }
}

@Suite struct DaySummaryTests {
    /// A synthetic Claude Code transcript (all strings made up) and a git repo with one commit of the day.
    func setUp() throws -> (DaySummary, String) {
        let dir = makeTempDir(), repo = dir + "/repo", root = dir + "/projects"
        Sys.mkdirs(root + "/-repo")
        func iso(_ h: Int, _ m: Int) -> String { "2026-10-30T\(h < 10 ? "0" : "")\(h):\(m < 10 ? "0" : "")\(m):00.000Z" }
        let lines = [
            #"{"type":"user","timestamp":"\#(iso(9, 0))","sessionId":"s1","cwd":"\#(repo)","message":{"role":"user","content":"Fix the parser please\nand add tests"}}"#,
            #"{"type":"assistant","timestamp":"\#(iso(9, 5))","sessionId":"s1","cwd":"\#(repo)","message":{"id":"m1","model":"claude-opus-4","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"\#(repo)/Parser.swift","old_string":"a","new_string":"b"}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"\#(repo)/Other.swift"}}],"usage":{"input_tokens":100,"output_tokens":50}}}"#,
            #"{"type":"user","timestamp":"\#(iso(9, 40))","sessionId":"s1","cwd":"\#(repo)","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"assistant","timestamp":"\#(iso(9, 50))","sessionId":"s1","cwd":"\#(repo)","message":{"id":"m2","model":"claude-opus-4","role":"assistant","content":[{"type":"tool_use","id":"toolu_3","name":"Write","input":{"file_path":"\#(repo)/ParserTests.swift","content":"x"}}],"usage":{"input_tokens":100,"output_tokens":50}}}"#,
            #"{"type":"custom-title","customTitle":"Parser fixes","sessionId":"s1"}"#,
        ]
        Sys.writeFile(root + "/-repo/s1.jsonl", Array((lines.joined(separator: "\n") + "\n").utf8))
        Sys.mkdirs(repo)
        let env = "GIT_AUTHOR_DATE='2026-10-30T10:00:00Z' GIT_COMMITTER_DATE='2026-10-30T10:00:00Z'"
        let before = "GIT_AUTHOR_DATE='2026-10-29T10:00:00Z' GIT_COMMITTER_DATE='2026-10-29T10:00:00Z'"
        _ = try shell("cd '\(repo)' && git init -q && git config user.email me@example.com && git config user.name Me && "
                      + "\(before) git commit -q --allow-empty -m 'Day before' && \(env) git commit -q --allow-empty -m 'Add parser tests' && "
                      + "\(env) git -c user.email=other@example.com commit -q --allow-empty -m 'Not mine'", stdin: [])
        let store = try Store(path: ":memory:")
        try Ingest(store: store, sources: [ClaudeSource.spec(root: root)]).scan()
        try store.mergeSession(SessionMeta(id: "claude:s1", tool: .claude, cwd: repo))
        try store.setStatus(sessionId: "claude:s1", tool: .claude, status: "waiting_input", at: day0 + 9.9 * 3600)
        try store.addActivity(sessionId: "claude:s1", start: day0 + 9.9 * 3600, end: day0 + 10.5 * 3600, kind: "waiting")
        var config = NotifyConfig()
        config.lang = .ru
        var s = DaySummary(store: store, config: config, paths: ZagonPaths(home: dir, dir: dir + "/.zagon"), claudeRoot: root)
        s.searchPath = "/usr/bin:/bin"
        return (s, repo)
    }

    @Test(.enabled(if: Sys.which("git") != nil)) func plainFactsFromTranscriptsAndGit() throws {
        let (s, _) = try setUp()
        let f = try s.facts("2026-10-30", now: day0 + 21 * 3600)
        let one = try #require(f.sessions.first)
        #expect(f.sessions.count == 1 && one.title == "Parser fixes" && one.project == "repo")
        #expect(one.prompts == ["Fix the parser please and add tests"])
        #expect(one.files.map(Sys.basename) == ["Parser.swift", "ParserTests.swift"])
        #expect(f.commits.map(\.repo) == ["repo"])  // not the day before, not someone else's
        #expect(one.workingSec == 900)  // 09:00–09:05 and 09:40–09:50: the /clear line starts a new turn
        #expect(f.commits.first?.subjects == ["Add parser tests"])
        #expect(one.waitingSec == 0.6 * 3600)
        let plain = DaySummary.plain(f, .ru)
        #expect(plain.hasPrefix("• repo — 15 мин: Parser fixes. Файлы: Parser.swift, ParserTests.swift. Коммиты (1): Add parser tests."))
        #expect(DaySummary.longestWait(f, .ru) == "Дольше всех ждала тебя repo — 36 мин.")
        #expect(DaySummary.headline(f, .ru).hasPrefix("Пт, 30 октября. Сессии работали 15 мин, ты — 0 мин. 300 токенов."))
        let d = DaySummary.digest(f, .ru)
        #expect(d.contains("«Fix the parser please and add tests»") && d.contains("Коммиты в repo: Add parser tests"))
        var big = f
        big.sessions = Array(repeating: one, count: 500)
        #expect(DaySummary.digest(big, .ru).count <= DaySummary.maxDigest)
        // The same in English.
        let en = Words.english
        #expect(DaySummary.plain(f, en).hasPrefix("• repo — 15 min: Parser fixes. Files: Parser.swift, ParserTests.swift. Commits (1): Add parser tests."))
        #expect(DaySummary.longestWait(f, en) == "Waited for you longest: repo — 36 min.")
        #expect(DaySummary.headline(f, en).hasPrefix("Fri, October 30. Sessions worked 15 min, you 0 min. 300 tokens."))
        let e = DaySummary.digest(f, en)
        #expect(e.contains("“Fix the parser please and add tests”") && e.contains("Commits in repo: Add parser tests") && !e.contains("токенов"))
        #expect(DaySummary.instruction(en).contains("Write in English") && DaySummary.instruction(.ru).contains("Напиши по-русски"))
        #expect(DaySummary.plain(DaySummary.Facts(day: "2026-10-30"), en) == "No sessions this day.")
    }

    @Test func captureAddsEnvironment() {
        let r = Sys.capture(["/bin/sh", "-c", "printf %s \"$ZAGON_INTERNAL:$ZAGON_X:${PATH:+path}\""],
                            env: ["ZAGON_INTERNAL": "1", "ZAGON_X": "a b"])
        #expect(r.status == 0 && String(decoding: r.out, as: UTF8.self) == "1:a b:path")
    }

    @Test(.enabled(if: Sys.which("git") != nil)) func internalClaudeRunIsIsolated() throws {
        var (s, _) = try setUp()
        let bin = makeTempDir()
        // A stand-in claude: answers with what it was started with.
        writeScript(bin + "/claude", """
            #!/bin/sh
            cat >/dev/null
            printf '{"is_error":false,"result":"• repo — internal=%s pwd=%s args=%s"}' "$ZAGON_INTERNAL" "$(pwd)" "$*"
            """)
        s.searchPath = bin + ":/usr/bin:/bin"
        let r = try #require(s.ai("выжимка"))
        #expect(r.engine == "claude" && r.text.contains("internal=1 pwd=\(s.paths.dir)/run args=-p --safe-mode --model haiku"))
    }

    @Test(.enabled(if: Sys.which("git") != nil)) func aiEngineAndFallback() throws {
        var (s, _) = try setUp()
        var calls: [[String]] = []
        let fakeBin = makeTempDir()
        Sys.writeFile(fakeBin + "/claude", [0], mode: 0o755)
        s.searchPath = fakeBin + ":/usr/bin:/bin"
        let real = s.runner
        s.runner = { argv, input, cwd, t in
            guard argv[0].hasSuffix("/claude") else { return real(argv, input, cwd, t) }
            calls.append(argv + [cwd ?? ""])
            #expect(String(decoding: input, as: UTF8.self).contains("Parser fixes"))
            return (0, Array(#"{"type":"result","is_error":false,"result":"• repo — починен парсер, добавлены тесты"}"#.utf8))
        }
        let m = try s.message("2026-10-30", now: day0 + 21 * 3600)
        #expect(calls.first?.contains("--no-session-persistence") == true && calls.first?.last == s.paths.dir + "/run")
        #expect(m.text.contains("\n\n• repo — починен парсер, добавлены тесты\n\nДольше всех ждала тебя repo"))
        #expect(m.photo.map { $0.count > 1000 && $0.count <= 200 * 1024 } == true)
        #expect(try s.store.db.one("SELECT engine FROM summary WHERE day = '2026-10-30'") { $0.text(0) } == "claude")
        s.runner = { argv, input, cwd, t in argv[0].hasSuffix("/claude") ? (124, []) : real(argv, input, cwd, t) }  // timed out
        let r = try s.make("2026-10-30", now: day0 + 21 * 3600)
        #expect(r.engine == "none" && r.text.hasPrefix("• repo — 15 мин"))
        // In English: the prompt asks for English, the fallback and the message are English.
        s.config.lang = .en
        var prompt = ""
        s.runner = { argv, input, cwd, t in
            guard argv[0].hasSuffix("/claude") else { return real(argv, input, cwd, t) }
            prompt = String(decoding: input, as: UTF8.self)
            return (124, [])
        }
        let m2 = try s.message("2026-10-30", now: day0 + 21 * 3600)
        #expect(prompt.hasPrefix("Below is a digest") && prompt.contains("Project repo (Claude), session “Parser fixes”"))
        #expect(m2.title == "Day summary" && m2.buttons == [[Message.Button("Details", "day:2026-10-30")]])
        #expect(m2.text.hasPrefix("Fri, October 30. Sessions worked 15 min") && m2.text.contains("\n\n• repo — 15 min: Parser fixes")
                && m2.text.hasSuffix("\n\nWaited for you longest: repo — 36 min."))
    }
}

@Suite struct NotifyLangTests {
    @Test func resolvesTheLanguage() {
        #expect(NotifyLang.ru.words(system: ["en-US"]) == .ru && NotifyLang.en.words(system: ["ru-RU"]) == .english)
        #expect(NotifyLang.auto.words(system: ["ru-RU", "en-US"]) == .ru)
        #expect(NotifyLang.auto.words(system: ["en_US.UTF-8"]) == .english && NotifyLang.auto.words(system: []) == .english)
        #if !os(macOS)
        let env = ["LC_ALL": "", "LC_MESSAGES": "ru_RU.UTF-8", "LANG": "en_US.UTF-8"]
        #expect(NotifyLang.systemLanguages { env[$0] } == ["ru_RU.UTF-8"])  // an empty LC_ALL does not count
        #expect(NotifyLang.systemLanguages { ["LANG": "C.UTF-8"][$0] } == ["C.UTF-8"])
        #endif
        #expect(NotifyConfig.parse("[notify]\nlang = \"en\"\n", home: "/h").lang == .en)
        #expect(NotifyConfig.parse("[notify]\nlang = \"ru\"\n", home: "/h").lang == .ru)
        #expect(NotifyConfig.parse("[notify]\nlang = \"de\"\n", home: "/h").lang == .auto && NotifyConfig().lang == .auto)
    }

    @Test func englishFormats() {
        let w = Words.english, now = day0 + 10 * 3600  // Friday
        #expect(w.dur(12 * 60) == "12 min" && w.dur(110 * 60) == "1 h 50 min" && w.dur(40 * 3600) == "40 h")
        #expect(w.pct(61.6) == "62%" && Words.ru.pct(61.6) == "62 %")
        #expect([950, 12_400, 31_240_000, 1_200_000_000].map(w.tokens) == ["950", "12K", "31.2M", "1.2B"])
        #expect([950, 12_400, 31_240_000, 1_200_000_000].map(Words.ru.tokens) == ["950", "12 тыс.", "31,2 млн", "1,2 млрд"])
        #expect(w.date("2026-10-29") == "Thu, October 29" && w.weekday("2026-10-29") == "Thu" && Words.ru.weekday("2026-10-29") == "чт")
        #expect(w.when(now + 3600, now: now) == "at 11:00" && w.when(now + 3 * 86400, now: now) == "Mon 10:00")
        #expect(w.when(now + 10 * 86400, now: now) == "November 9 10:00" && Words.ru.when(now + 10 * 86400, now: now) == "9 ноября 10:00")
        #expect(w.name(nil, nil) == "session" && Words.ru.name(nil, nil) == "сессия" && w.name("p", "t") == "p — t")
    }

    @Test func botRepliesInEnglish() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        Sys.writeFile(dir + "/token", Array("1:x\n".utf8))
        Sys.writeFile(dir + "/curl", [0], mode: 0o755)  // never run: replies are built, not sent
        var c = NotifyConfig()
        c.telegramTokenFile = dir + "/token"; c.telegramChatId = "1"
        let tg = try #require(Telegram(c, curl: Curl(searchPath: dir), tmpDir: dir))
        let store = try Store(path: ":memory:"), now = day0 + 10 * 3600
        try store.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "five_hour", usedPct: 62, resetsAt: now + 3600,
                                                 windowMinutes: 300, ts: now - 120))
        try store.addLimitSnapshot(LimitSnapshot(tool: .claude, window: "seven_day", usedPct: 30, resetsAt: now - 60,
                                                 windowMinutes: 10080, ts: now - 180))
        try store.mergeSession(SessionMeta(id: "claude:a", tool: .claude, project: "api-server", title: "fix login flow"))
        try store.setStatus(sessionId: "claude:a", tool: .claude, status: "waiting_input", at: now - 600)
        let bot = Bot(telegram: tg, store: store, lang: .en)
        let limits = bot.reply("/limits", [], now: now)
        #expect(limits.title == "Limits")
        #expect(Set(limits.text.split(separator: "\n")) == ["Claude 5 h: 62% · resets at 11:00", "Claude weekly: reset", "(data from 2 min ago)"])
        #expect(bot.reply("/sessions", [], now: now).text == "⏳ waits for you 10 min · api-server — fix login flow")
        #expect(bot.reply("/help", [], now: now).text.hasPrefix("/limits — limits\n/sessions — sessions\n/today — today"))
        #expect(bot.reply("/day", ["30-10"], now: now).text == "Format: /day 2026-10-29")
        #expect(bot.reply("/tz", [], now: now).text.hasPrefix("Time zone \(Settings.zoneName()) (system), now "))
        let today = bot.reply("/today", [], now: now)
        #expect(today.title == "Fri, October 30" && today.text.hasPrefix("Sessions 0 min · you 0 min\n0 tokens · 0 requests"))
        #expect(bot.reply("/week", [], now: now).text.hasPrefix("Sessions 0 min · you 0 min · 0 tokens"))
        bot.lang = .ru
        #expect(bot.reply("/sessions", [], now: now).text == "⏳ ждёт тебя 10 мин · api-server — fix login flow")
        #expect(bot.reply("/limits", [], now: now).text.contains("Claude 5 ч: 62 % · сброс в 11:00"))
    }
}
