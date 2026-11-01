import Foundation
import Testing
@testable import ZagonCore

/// doctor's checks of what runs: the service and its health line, notification channels, Codex's hooks and
/// compressed rollouts, the versions writing the logs. Each on its own temporary HOME.
extension InstallerTests {
    final class Active: @unchecked Sendable { var units: Set<String> = [] }

    func line(_ checks: [Installer.Check], _ part: String) -> String? {
        checks.map { ($0.tag ?? ($0.ok ? "ok" : "MISSING")) + " " + $0.text }.first { $0.contains(part) }
    }

    func setMtime(_ path: String, _ t: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: path)
    }

    #if os(Linux)
    @Test func doctorServiceRunsAndHealth() throws {
        var (home, o) = setUp()
        o.searchPath = home + "/fake-bin"
        Sys.mkdirs(o.searchPath!); Sys.writeFile(o.searchPath! + "/systemctl", [0], mode: 0o755)
        o.systemUnitDir = home + "/system"; Sys.mkdirs(o.systemUnitDir)
        let active = Active()
        var i = installer(o)
        i.runner = { argv in argv.contains("is-active") ? (active.units.contains(argv.last!) ? 0 : 3) : 0 }
        #expect(line(i.doctor(), "service:") == "MISSING service: \(o.userUnitDir)/zagon.service missing")
        #expect(line(i.doctor(), "daemon:") == "MISSING daemon: no health line in \(home)/.zagon/logs/daemon.log: it has not run here")

        // A stopped user unit beside the system unit; neither runs.
        let system = "zagon-\(i.userName).service"
        Sys.mkdirs(o.userUnitDir); Sys.writeFile(o.userUnitDir + "/zagon.service", [0]); Sys.writeFile(o.systemUnitDir + "/" + system, [0])
        let stopped = try #require(line(i.doctor(), "service:"))
        #expect(stopped.hasPrefix("MISSING service: \(o.userUnitDir)/zagon.service present, enabled, not running; system unit "
            + "\(o.systemUnitDir)/\(system) present, not running; start it: "))
        #expect(stopped.hasSuffix("systemctl enable --now \(system)"))
        active.units = [system]
        #expect(line(i.doctor(), "service:")?.hasPrefix("ok service:") == true)
        active.units = ["zagon.service"]
        #expect(line(i.doctor(), "service:")?.hasSuffix("enabled, running; system unit \(o.systemUnitDir)/\(system) present, not running") == true)

        let log = home + "/.zagon/logs/daemon.log"
        Sys.mkdirs(home + "/.zagon/logs")
        Sys.writeFile(log, Array("\(LogFile.iso(o.now - 20 * 60)) health: rss 13.0 MB\n\(LogFile.iso(o.now - 60)) notify: sent x via ntfy\n".utf8))
        #expect(line(i.doctor(), "daemon:")?.hasPrefix("MISSING daemon: no health line for 20 min (one every 10 min while it runs)") == true)
        Sys.append(log, Array("\(LogFile.iso(o.now - 120)) start: pid 1\n".utf8))
        #expect(line(i.doctor(), "daemon:") == "ok daemon: last health line 2 min ago")
    }

    /// Root on a server without a user manager: install enables the system unit instead; another account gets the hint.
    @Test func installRootWithoutUserBusUsesTheSystemUnit() throws {
        var (home, o) = setUp()
        let fb = home + "/fake-bin"
        o.searchPath = fb; Sys.mkdirs(fb); Sys.writeFile(fb + "/systemctl", [0], mode: 0o755)
        o.systemUnitDir = home + "/system"; Sys.mkdirs(o.systemUnitDir)
        o.enableService = true; o.root = true
        let calls = Calls()
        var i = installer(o, calls)
        i.runner = { calls.argv.append($0); return $0.contains("--user") ? 1 : 0 }
        try i.install()
        let system = "zagon-\(i.userName).service"
        let unit = String(decoding: Sys.readFile(o.systemUnitDir + "/" + system) ?? [], as: UTF8.self)
        #expect(unit.contains("User=\(i.userName)\n") && unit.contains("WantedBy=multi-user.target"))
        #expect(calls.argv.contains([fb + "/systemctl", "enable", "--now", system]))
        #expect(!calls.argv.contains { $0.contains("--user") && $0.contains("enable") })

        o.root = false; o.systemUnitDir = home + "/system2"; Sys.mkdirs(o.systemUnitDir)
        calls.argv = []
        var logged: [String] = []
        i = installer(o, calls)
        i.runner = { calls.argv.append($0); return $0.contains("--user") ? 1 : 0 }
        i.log = { logged.append($0) }
        try i.install()
        #expect(Sys.listDir(o.systemUnitDir).isEmpty)
        #expect(logged.contains("service: systemd --user is not available (1); sudo zagon install --system-service --enable-service"))
    }
    #endif

    @Test func doctorCodexHooksRolloutsAndVersions() throws {
        var (home, o) = setUp()
        o.claude = false
        try setMtime(home + "/.codex/hooks.json", o.now - 3600)
        let day = home + "/.codex/sessions/2025/10/30"
        Sys.mkdirs(day)
        func rollout(_ name: String, started: Double, version: String) {
            Sys.writeFile(day + "/" + name, Array(("{\"timestamp\":\"\(LogFile.iso(started))\",\"type\":\"session_meta\",\"payload\":"
                + "{\"id\":\"x\",\"cli_version\":\"\(version)\"}}\n{\"type\":\"event_msg\"}\n").utf8))
        }
        rollout("rollout-2025-10-30T08-00-00-a.jsonl", started: o.now - 7200, version: "0.150.0")
        // Started before the hooks were installed: nothing to expect of them.
        #expect(line(Installer(o).doctor(), "codex: no hook") == "info codex: no hook event yet (no Codex session since the hooks were installed)")
        #expect(line(Installer(o).doctor(), "codex 0.") == "info codex 0.150.0 (newest rollout), tested up to \(Installer.testedCodex)")

        rollout("rollout-2025-10-30T09-50-00-b.jsonl", started: o.now - 600, version: "0.170.1")
        #expect(line(Installer(o).doctor(), "codex: a session") == "warn codex: a session started 10 min ago but no Codex hook event came since"
            + " (last: never): open /hooks in Codex once and trust Zagon's hooks; Codex statuses come from them")
        #expect(line(Installer(o).doctor(), "codex 0.")?.hasPrefix("warn codex 0.170.1 (newest rollout), tested up to") == true)

        Sys.mkdirs(o.paths.spool)
        Sys.writeFile(o.paths.spool + "/2025-10-30.ndjson", Array(("{\"kind\":\"hook\",\"tool\":\"codex\",\"event\":\"SessionStart\",\"ts\":\(Int(o.now) - 590).250}\n"
            + "{\"kind\":\"hook\",\"tool\":\"claude\",\"event\":\"Stop\",\"ts\":\(Int(o.now) - 10)}\n").utf8))
        #expect(line(Installer(o).doctor(), "codex: last hook") == "info codex: last hook event 9 min ago")
        #expect(line(Installer(o).doctor(), "compressed") == nil)

        Sys.writeFile(day + "/rollout-2025-10-30T10-00-00-c.jsonl.zst", [0x28, 0xB5, 0x2F, 0xFD])
        let zst = Installer(o).doctor().first { $0.text.contains("compressed") }
        #expect(zst?.ok == true)
        if CodexSource.isRollout("rollout-x.jsonl.zst") {
            #expect(zst?.tag == "info" && zst?.text == "codex: 1 compressed rollout(s) (.jsonl.zst), read")
        } else {
            #expect(zst?.tag == "warn" && zst?.text == "codex: 1 compressed rollout(s) (rollout-*.jsonl.zst) are not read yet: the tokens and limits in them are missing")
        }
    }

    @Test func doctorClaudeVersion() throws {
        var (home, o) = setUp()
        o.codex = false
        let dir = home + "/.claude/projects/-home-user-p"
        Sys.mkdirs(dir + "/s1/subagents")
        Sys.writeFile(dir + "/old.jsonl", Array("{\"type\":\"user\",\"version\":\"9.9.9\"}\n".utf8))
        try setMtime(dir + "/old.jsonl", o.now - 86400)
        Sys.writeFile(dir + "/s1.jsonl", Array("{\"type\":\"user\",\"version\":\"2.1.300\"}\n{\"type\":\"assistant\",\"version\":\"2.1.401\"}\n{\"type\":\"file-history-snapshot\"}\n".utf8))
        #expect(line(Installer(o).doctor(), "claude code") == "info claude code 2.1.401 (newest transcript), tested up to \(Installer.testedClaude)")
        Sys.append(dir + "/s1.jsonl", Array("{\"type\":\"assistant\", \"version\": \"2.2.0\"}\n".utf8))
        #expect(line(Installer(o).doctor(), "claude code")?.hasPrefix("warn claude code 2.2.0 (newest transcript)") == true)
        #expect(Installer.newer("2.2.0", than: "2.1.316", parts: 2) && !Installer.newer("2.1.999", than: "2.1.316", parts: 2)
                && !Installer.newer("1.9.0", than: "2.1.316", parts: 2) && Installer.newer("0.170.0", than: "0.166.0", parts: 2))
    }

    @Test func doctorNotify() throws {
        var (home, o) = setUp()
        #expect(line(Installer(o).doctor(), "notify:") == "info notify: no channel ([telegram] or [ntfy] in \(o.paths.config)): "
            + "limits, waiting sessions and the day summary are sent nowhere")
        Sys.mkdirs(o.paths.dir)
        Sys.writeFile(o.paths.config, Array("[telegram]\nchat_id = \"1\"\ntoken_file = \"\(home)/tg\"\n\n[ntfy]\ntopic = \"t\"\n".utf8))
        #expect(line(Installer(o).doctor(), "notify:") == "warn notify: [telegram] is set but cannot send (token_file cannot be read); "
            + "[ntfy] is set but cannot send (no curl on PATH)")
        o.searchPath = home + "/fake-bin"
        Sys.mkdirs(o.searchPath!); Sys.writeFile(o.searchPath! + "/curl", [0], mode: 0o755)
        Sys.writeFile(home + "/tg", Array("not-a-real-token\n".utf8), mode: 0o600)
        #expect(line(Installer(o).doctor(), "notify:") == "info notify: telegram, ntfy")
        Sys.mkdirs(o.paths.dir + "/logs")
        Sys.writeFile(o.paths.dir + "/logs/daemon.log", Array("\(LogFile.iso(o.now - 7200)) notify: sent summary via telegram\n".utf8))
        #expect(line(Installer(o).doctor(), "notify:") == "info notify: telegram, ntfy; last sent 2 h ago")
        Sys.append(o.paths.dir + "/logs/daemon.log", Array("\(LogFile.iso(o.now - 300)) notify: no channel accepted waiting:s1, will retry\n".utf8))
        #expect(line(Installer(o).doctor(), "notify:") == "warn notify: telegram, ntfy; the last message was not accepted 5 min ago (see daemon.log)")
    }

    @Test func doctorArchive() throws {
        var (home, o) = setUp()
        o.managedSettingsDir = home + "/managed"
        let dir = home + "/.zagon/archive"
        #expect(line(Installer(o).doctor(), "archive:") == "info archive: \(dir) keeps copies of Claude Code transcripts and Codex rollouts"
            + " with no time limit (no cleanupPeriodDays in Claude Code's managed settings; zagon daemon --no-archive turns it off)")
        Sys.mkdirs(o.managedSettingsDir)
        Sys.writeFile(o.managedSettingsDir + "/managed-settings.json", Array("{\"cleanupPeriodDays\": 14}".utf8))
        #expect(line(Installer(o).doctor(), "archive:") == "info archive: \(dir) keeps copies of Claude Code transcripts for 14 days"
            + " (cleanupPeriodDays 14 in \(home)/managed/managed-settings.json), of Codex rollouts with no time limit")
        Sys.writeFile(home + "/.claude/remote-settings.json", Array("{\"cleanupPeriodDays\": 0}".utf8))
        #expect(line(Installer(o).doctor(), "archive:")?.hasPrefix("info archive: \(dir) keeps no copies of Claude Code transcripts (cleanupPeriodDays 0 in") == true)
        Sys.mkdirs(o.userUnitDir)
        Sys.writeFile(o.userUnitDir + "/zagon.service", Array("[Service]\nExecStart=/z daemon --no-archive\n".utf8))
        #expect(line(Installer(o).doctor(), "archive:") == "info archive: off (--no-archive in the service unit)")
    }
}
