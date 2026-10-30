import Foundation
import Testing
@testable import ZagonCore

/// The zone of this test process is never changed here (tests run in parallel and cut days in it): switching zones
/// is checked on the binary.
@Suite struct TimezoneTests {
    func read(_ p: ZagonPaths) -> String { Sys.readFile(p.config).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    @Test func topLevelKeyGoesBeforeSections() {
        #expect(TOMLLite.setting("", section: "", key: "timezone", to: "Asia/Almaty") == "timezone = \"Asia/Almaty\"\n")
        #expect(TOMLLite.setting("a = 1", section: "", key: "timezone", to: "UTC") == "a = 1\ntimezone = \"UTC\"\n")
        let text = "# zagon\n[notify]\nenabled = true\n\n[telegram]\nchat_id = 1\n"
        let set = TOMLLite.setting(text, section: "", key: "timezone", to: "Asia/Almaty")
        #expect(set == "# zagon\ntimezone = \"Asia/Almaty\"\n\n[notify]\nenabled = true\n\n[telegram]\nchat_id = 1\n")
        #expect(TOMLLite.setting(set, section: "", key: "timezone", to: "UTC")
                == "# zagon\ntimezone = \"UTC\"\n\n[notify]\nenabled = true\n\n[telegram]\nchat_id = 1\n")
        #expect(TOMLLite.string(in: set, section: "notify", key: "timezone") == nil)
    }

    @Test func setTimezoneKeepsTheRestOfTheFile() throws {
        let dir = makeTempDir(), p = ZagonPaths(home: dir, dir: dir + "/z")
        // No zone: the system's (TZ / /etc/localtime), as before.
        #expect(Settings.timezone(p) == nil)
        Sys.mkdirs(p.dir)
        Sys.writeFile(p.config, Array("# mine\n[notify]\nquiet = \"23:00-08:00\"\ntimezone = \"Europe/Moscow\"\n".utf8), mode: 0o640)
        #expect(Settings.timezone(p) == "Europe/Moscow")  // the older place still counts
        try Settings.setTimezone(p, "Asia/Almaty")
        #expect(read(p) == "# mine\ntimezone = \"Asia/Almaty\"\n\n[notify]\nquiet = \"23:00-08:00\"\n")
        #expect(Settings.timezone(p) == "Asia/Almaty")
        var st = stat()
        stat(p.config, &st)
        #expect(st.st_mode & 0o777 == 0o640)
        let before = read(p)
        #expect(throws: SettingsError.self) { try Settings.setTimezone(p, "Nowhere/Zone") }
        #expect(read(p) == before)
        try Settings.setTimezone(p, nil)
        #expect(Settings.timezone(p) == nil && read(p) == "# mine\n\n[notify]\nquiet = \"23:00-08:00\"\n")
    }

    @Test func zoneNames() {
        for z in ["Asia/Almaty", "UTC", "Etc/GMT-3", "America/Argentina/Buenos_Aires"] { #expect(Settings.isZone(z), "\(z)") }
        for z in ["", "Nowhere/Zone", "../etc/passwd", "/etc/localtime", "Asia/../UTC", "Asia//Almaty", "Asia/Almaty ",
                  "zone.tab", "Asia/Almaty\n"] {
            #expect(!Settings.isZone(z), "\(z)")
        }
    }

    /// `YYYY-MM-DD HH:MM` of `t` shifted by `offset` hours, read as UTC.
    func utcClock(_ t: Double, offset: Double) -> String {
        var s = time_t(t + offset * 3600), v = tm()
        gmtime_r(&s, &v)
        func p2(_ x: Int32) -> String { x < 10 ? "0\(x)" : "\(x)" }
        return "\(v.tm_year + 1900)-\(p2(v.tm_mon + 1))-\(p2(v.tm_mday)) \(p2(v.tm_hour)):\(p2(v.tm_min))"
    }

    @Test(.enabled(if: Sys.exists(zagonBin))) func cliShowsAndSets() throws {
        let dir = makeTempDir(), z = dir + "/z", p = ZagonPaths(home: dir, dir: z)
        let env = ["HOME": dir, "PATH": "/usr/bin:/bin"]
        var (status, out) = try runZagon(["tz", "--data-dir", z], stdin: [], env: env)
        #expect(status == 0 && String(decoding: out, as: UTF8.self).contains(" (system zone), now "))
        let t0 = Sys.now()
        (status, out) = try runZagon(["tz", "Etc/GMT-3", "--data-dir", z], stdin: [], env: env)
        let line = String(decoding: out, as: UTF8.self)
        // Etc/GMT-3 is UTC+3 all year.
        #expect(status == 0 && [utcClock(t0, offset: 3), utcClock(Sys.now(), offset: 3)].contains { line == "Etc/GMT-3 (config.toml), now \($0)\n" },
                "\(line)")
        #expect(Settings.timezone(p) == "Etc/GMT-3")
        (status, _) = try runZagon(["tz", "Bad/Zone", "--data-dir", z], stdin: [], env: env)
        #expect(status != 0 && Settings.timezone(p) == "Etc/GMT-3")
        (status, out) = try runZagon(["tz", "system", "--data-dir", z], stdin: [], env: env)
        #expect(status == 0 && Settings.timezone(p) == nil && String(decoding: out, as: UTF8.self).contains(" (system zone), now "))
    }

    @Test func mcpToolNeedsConfirm() throws {
        let dir = makeTempDir(), p = ZagonPaths(home: dir, dir: dir + "/z")
        let tool = try #require(SettingsTools.tools(p).first)
        #expect(try tool.run(MCPArgs(.object([]))).contains("(system zone), now "))
        #expect(throws: MCPToolError.self) { try tool.run(MCPArgs(["zone": "UTC"])) }
        #expect(throws: MCPToolError.self) { try tool.run(MCPArgs(["zone": "Nowhere/Zone", "confirm": true])) }
        #expect(Settings.timezone(p) == nil)
        // Writing (not applying: `system` keeps this process in its own zone).
        try Settings.setTimezone(p, "UTC")
        #expect(try tool.run(MCPArgs(["zone": "system", "confirm": true])).contains("(system zone)"))
        #expect(Settings.timezone(p) == nil)
    }

    #if os(Linux)
    /// The service restarts itself (same pid) when config.toml names another zone, and rebuilds days in it.
    @Test(.enabled(if: Sys.exists(zagonBin))) func daemonFollowsTheZone() throws {
        let dir = makeTempDir(), z = dir + "/z", logPath = z + "/logs/daemon.log"
        Sys.mkdirs(dir + "/claude"); Sys.mkdirs(dir + "/codex")
        let env = ["HOME": dir, "PATH": "/usr/bin:/bin"]
        let d = Process()
        d.executableURL = URL(fileURLWithPath: zagonBin)
        d.arguments = ["daemon", "--no-notify", "--no-archive", "--data-dir", z, "--claude-dir", dir + "/claude", "--codex-dir", dir + "/codex"]
        d.environment = env
        d.standardOutput = FileHandle.nullDevice; d.standardError = FileHandle.nullDevice
        try d.run()
        defer { d.terminate(); d.waitUntilExit() }
        func log() -> [String] { (Sys.readFile(logPath).map { String(decoding: $0, as: UTF8.self) } ?? "").split(separator: "\n").map(String.init) }
        func waitFor(_ what: String, count: Int) -> Bool {
            for _ in 0..<300 {
                if log().filter({ $0.contains(what) }).count >= count { return true }
                usleep(100_000)
            }
            return false
        }
        func metaTZ() throws -> String? {
            let s = try Store(path: z + "/zagon.db")
            return try s.db.one("SELECT value FROM meta WHERE key = 'tz'") { $0.text(0) } ?? nil
        }
        #expect(waitFor("full pass (start)", count: 1))
        let system = try metaTZ()
        #expect(system?.hasPrefix("TZ=") == false)

        _ = try runZagon(["tz", "Etc/GMT-3", "--data-dir", z], stdin: [], env: env)
        #expect(waitFor("restarting", count: 1) && waitFor("full pass (start)", count: 2))
        #expect(try metaTZ() == "TZ=Etc/GMT-3")
        let pids = log().filter { $0.contains(" start: pid ") }.map { $0.split(separator: " ")[3].dropLast() }
        #expect(pids.count == 2 && pids.allSatisfy { Int($0) == Int(d.processIdentifier) }, "\(pids)")

        _ = try runZagon(["tz", "system", "--data-dir", z], stdin: [], env: env)
        #expect(waitFor("restarting", count: 2) && waitFor("full pass (start)", count: 3))
        #expect(try metaTZ() == system)  // TZ as the service was started with, not the one it had set
    }
    #endif
}

extension ChannelTests {
    @Test func botTimezone() throws {
        let dir = makeTempDir(), mock = try MockHTTP(dir: dir), paths = ZagonPaths(home: dir, dir: dir + "/z")
        let store = try Store(path: ":memory:")
        let tg = try #require(config(dir, mock).channels(paths).first as? Telegram)
        let bot = Bot(telegram: tg, store: store, paths: paths, lang: .ru)
        bot.log = { _ in }
        var changes = 0
        bot.onTimezoneChange = { changes += 1 }  // a service would restart here; this process keeps its zone
        func send(_ texts: [String]) {
            let u = texts.enumerated().map { #"{"update_id": \#(100 + $0.offset), "message": {"chat": {"id": 123456789}, "text": "\#($0.element)"}}"# }
            Sys.writeFile(dir + "/updates.json", Array(("[" + u.joined(separator: ",") + "]").utf8))
        }
        func replies() -> [String] {
            mock.requests.filter { $0.path.hasSuffix("/sendMessage") }.compactMap { JValue.parse($0.body)?["text"]?.string }
        }
        send(["/tz", "/tz Nowhere/Zone", "/tz Etc/GMT-3"])
        #expect(bot.pollOnce(timeout: 0) == 3)
        var r = replies()
        #expect(r.count == 2)
        #expect(r.first?.hasPrefix("Пояс \(Settings.zoneName()) (системный), сейчас ") == true)
        #expect(r.last == "Нет такого пояса: Nowhere/Zone. Пример: /tz Asia/Almaty, /tz system")
        // Written; the answer waits until the zone is in effect (after the restart).
        #expect(Settings.timezone(paths) == "Etc/GMT-3" && changes == 1)
        #expect(try store.db.one("SELECT value FROM meta WHERE key = 'telegram:tz_reply'") { $0.text(0) } == "1")
        bot.pollOnce(timeout: 0)
        #expect(replies().count == 2)

        // Back to the machine's zone, which this process already uses: answered at once, the note is gone.
        send(["/tz system"])
        bot.pollOnce(timeout: 0)
        r = replies()
        #expect(r.count == 3 && r.last?.hasPrefix("Пояс \(Settings.zoneName()) (системный), сейчас ") == true)
        #expect(Settings.timezone(paths) == nil && changes == 2)
        #expect(try store.db.one("SELECT count(*) FROM meta WHERE key = 'telegram:tz_reply'") { $0.int(0) } == 0)
    }
}
