import Foundation
import Testing
@testable import ZagonCore

/// Every test works on its own temporary HOME; nothing reads or writes the real ~/.claude or ~/.codex.
@Suite struct InstallerTests {
    let settings = """
        {
            "model": "opus",
            "env": {"A": "1"},
            "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": "afplay done.wav"}]}],
                "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh", "timeout": 1.0}]}]
            },
            "statusLine": {"type": "command", "command": "~/.claude/sl.sh --x 'a b'", "padding": 0},
            "rate": 0.10,
            "x": "\\u00e9\\/"
        }
        """
    let codexHooks = "{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [{\"type\": \"command\", \"command\": \"notify-me\", \"timeout\": 5}]\n      }\n    ]\n  }\n}\n"
    let codexConfig = "model = \"gpt-5\"\n\n[features]\nweb_search = true\n"

    final class Calls: @unchecked Sendable { var argv: [[String]] = [] }

    func setUp(files: Bool = true) -> (String, Installer.Options) {
        let home = makeTempDir()
        Sys.mkdirs(home + "/bin")
        Sys.writeFile(home + "/bin/zagon", [0], mode: 0o755)
        if files {
            Sys.mkdirs(home + "/.claude"); Sys.mkdirs(home + "/.codex")
            Sys.writeFile(home + "/.claude/settings.json", Array(settings.utf8))
            Sys.writeFile(home + "/.codex/hooks.json", Array(codexHooks.utf8))
            Sys.writeFile(home + "/.codex/config.toml", Array(codexConfig.utf8))
        }
        var o = Installer.Options(paths: ZagonPaths(home: home, dir: home + "/.zagon"), zagon: home + "/bin/zagon")
        o.claudeDir = home + "/.claude"; o.codexDir = home + "/.codex"; o.codex = true
        o.userUnitDir = home + "/.config/systemd/user"; o.claudeJSON = home + "/.claude.json"
        o.searchPath = home + "/no-bin"; o.now = 1_761_800_000
        return (home, o)
    }

    func installer(_ o: Installer.Options, _ calls: Calls = Calls()) -> Installer {
        var i = Installer(o)
        i.log = { _ in }
        i.runner = { calls.argv.append($0); return 0 }
        return i
    }

    /// All regular files under `dir` with their bytes.
    func snapshot(_ dir: String) -> [String: [UInt8]] {
        var out: [String: [UInt8]] = [:]
        let e = FileManager.default.enumerator(atPath: dir)
        while let rel = e?.nextObject() as? String {
            if !Sys.isDir(dir + "/" + rel), let b = Sys.readFile(dir + "/" + rel) { out[rel] = b }
        }
        return out
    }

    func json(_ path: String) throws -> JValue {
        let b = try #require(Sys.readFile(path))
        return try #require(JValue.parse(b))
    }

    func commands(_ doc: JValue, _ event: String) -> [String] {
        (doc["hooks"]?[event]?.array ?? []).flatMap { $0["hooks"]?.array ?? [] }.compactMap { $0["command"]?.string }
    }

    @Test func freshHome() throws {
        let (home, o) = setUp(files: false)
        let before = snapshot(home)
        try installer(o).install()
        let s = try json(home + "/.claude/settings.json")
        for e in Installer.claudeEvents { #expect(commands(s, e) == ["\(home)/bin/zagon hook claude \(e)"]) }
        #expect(s["statusLine"] == .object([.init("type", .string("command")), .init("command", .string("\(home)/bin/zagon statusline"))]))
        let c = try json(home + "/.codex/hooks.json")
        for e in Installer.codexEvents { #expect(commands(c, e) == ["\(home)/bin/zagon hook codex \(e)"]) }
        #if os(Linux)
        let unit = String(decoding: Sys.readFile(o.userUnitDir + "/zagon.service") ?? [], as: UTF8.self)
        #expect(unit.contains("ExecStart=\(home)/bin/zagon daemon\n") && !unit.contains("ZAGON_DIR"))
        #expect(unit.contains("Restart=on-failure\n") && unit.contains("MemoryHigh=256M\nMemoryMax=512M\nNice=10\n"))
        #else
        #expect(!Sys.exists(o.userUnitDir + "/zagon.service"))  // macOS: Zagon.app is the service
        #endif
        #expect(Sys.isDir(home + "/.zagon/spool"))
        #expect(TOMLLite.string(at: o.paths.config, section: "statusline", key: "original_command") == nil)

        let installed = snapshot(home)
        try installer(o).install()
        #expect(snapshot(home) == installed)  // second run changes nothing, not even a new backup

        try installer(o).uninstall()
        #expect(snapshot(home).filter { !$0.key.hasPrefix(".zagon/") } == before)
    }

    @Test func keepsForeignEntriesAndRestoresBytes() throws {
        let (home, o) = setUp()
        let before = snapshot(home)
        try installer(o).install()
        let s = try json(home + "/.claude/settings.json")
        #expect(s["model"]?.string == "opus" && s["env"]?["A"]?.string == "1" && s["rate"] == .number("0.10"))
        #expect(commands(s, "Stop") == ["afplay done.wav", "\(home)/bin/zagon hook claude Stop"])
        #expect(commands(s, "PreToolUse") == ["guard.sh"])
        #expect(s["hooks"]?["PreToolUse"]?.array?.first?["hooks"]?.array?.first?["timeout"] == .number("1.0"))
        #expect(s["statusLine"]?["command"]?.string == "\(home)/bin/zagon statusline")
        #expect(s["statusLine"]?["padding"] == .number("0"))
        #expect(TOMLLite.string(at: o.paths.config, section: "statusline", key: "original_command") == "~/.claude/sl.sh --x 'a b'")
        let text = String(decoding: Sys.readFile(home + "/.claude/settings.json")!, as: UTF8.self)
        #expect(text.hasPrefix("{\n    \"model\"") && !text.hasSuffix("\n"))  // indent and final newline kept
        #expect(try commands(json(home + "/.codex/hooks.json"), "Stop") == ["notify-me", "\(home)/bin/zagon hook codex Stop"])
        #expect(Sys.readFile(home + "/.codex/config.toml") == Array(codexConfig.utf8))
        let backups = Sys.listDir(o.paths.backup)
        #expect(backups.count == 1)
        #expect(Sys.readFile(o.paths.backup + "/" + backups[0] + "/claude-settings.json") == Array(settings.utf8))

        let installed = snapshot(home)
        try installer(o).install()
        #expect(snapshot(home) == installed)

        try installer(o).uninstall()
        let after = snapshot(home)
        for f in [".claude/settings.json", ".codex/hooks.json", ".codex/config.toml"] { #expect(after[f] == before[f], "\(f)") }
        #expect(!Sys.exists(o.userUnitDir + "/zagon.service"))
        #expect(TOMLLite.string(at: o.paths.config, section: "statusline", key: "original_command") == nil)
    }

    @Test func reinstallWithMovedBinaryStillRestoresOriginal() throws {
        let (home, o) = setUp()
        let before = snapshot(home)
        try installer(o).install()
        var o2 = o
        o2.zagon = home + "/other bin/zagon"
        Sys.mkdirs(home + "/other bin"); Sys.writeFile(o2.zagon, [0], mode: 0o755)
        try installer(o2).install()
        let s = try json(home + "/.claude/settings.json")
        #expect(commands(s, "Stop") == ["afplay done.wav", "'\(home)/other bin/zagon' hook claude Stop"])
        #expect(s["statusLine"]?["command"]?.string == "'\(home)/other bin/zagon' statusline")
        // The saved original is still the user's command, not the first wrapper.
        #expect(TOMLLite.string(at: o.paths.config, section: "statusline", key: "original_command") == "~/.claude/sl.sh --x 'a b'")
        #expect(Sys.listDir(o.paths.backup).count == 2)
        try installer(o2).uninstall()
        #expect(snapshot(home)[".claude/settings.json"] == before[".claude/settings.json"])
        #expect(snapshot(home)[".codex/hooks.json"] == before[".codex/hooks.json"])
    }

    @Test func userEditAfterInstallRemovesOnlyOurs() throws {
        let (home, o) = setUp()
        try installer(o).install()
        var s = try json(home + "/.claude/settings.json")
        s["newKey"] = .bool(true)
        Sys.writeFile(home + "/.claude/settings.json", Array(s.pretty().utf8))
        try installer(o).uninstall()
        let r = try json(home + "/.claude/settings.json")
        #expect(r["newKey"] == .bool(true) && r["model"]?.string == "opus")
        #expect(commands(r, "Stop") == ["afplay done.wav"] && commands(r, "PreToolUse") == ["guard.sh"])
        for e in Installer.claudeEvents where e != "Stop" { #expect(r["hooks"]?[e] == nil) }
        #expect(r["statusLine"]?["command"]?.string == "~/.claude/sl.sh --x 'a b'" && r["statusLine"]?["padding"] == .number("0"))
    }

    @Test func mcpServiceAndDoctor() throws {
        let (home, o0) = setUp()
        var o = o0
        o.searchPath = home + "/fake-bin"
        for b in ["claude", "codex", "systemctl"] { Sys.mkdirs(o.searchPath!); Sys.writeFile(o.searchPath! + "/" + b, [0], mode: 0o755) }
        let calls = Calls()
        var i = installer(o, calls)
        i.runner = { argv in
            calls.argv.append(argv)
            // What the real CLIs do, as far as install/doctor look at it.
            if Array(argv.dropFirst().prefix(3)) == ["mcp", "add", "--scope"] { Sys.writeFile(home + "/.claude.json", Array("{\"mcpServers\":{\"zagon\":{}}}".utf8)) }
            if Array(argv.dropFirst().prefix(2)) == ["mcp", "add"], argv[0].hasSuffix("codex") { Sys.append(home + "/.codex/config.toml", Array("\n[mcp_servers.zagon]\ncommand = \"z\"\n".utf8)) }
            return argv.contains("is-enabled") ? 1 : 0
        }
        let notYet = i.doctor()
        #expect(notYet.filter { !$0.ok }.count >= 5)
        o.enableService = true
        i.o = o
        try i.install()
        let z = home + "/bin/zagon", fb = home + "/fake-bin"
        #expect(calls.argv.contains([fb + "/claude", "mcp", "add", "--scope", "user", "zagon", "--", z, "mcp"]))
        #expect(calls.argv.contains([fb + "/codex", "mcp", "add", "zagon", "--", z, "mcp"]))
        #if os(Linux)
        #expect(calls.argv.contains([fb + "/systemctl", "--user", "enable", "--now", "zagon.service"]))
        #else
        #expect(!calls.argv.contains { $0[0] == fb + "/systemctl" })
        #endif
        let checks = i.doctor()
        #expect(checks.filter { !$0.ok }.map(\.text) == [])
        calls.argv = []
        try i.install()
        #expect(!calls.argv.contains { $0.contains("add") })  // already registered

        // --no-mcp: the CLIs are on PATH but not called.
        var (_, o2) = setUp()
        o2.searchPath = o.searchPath; o2.mcp = false
        let offCalls = Calls()
        try installer(o2, offCalls).install()
        #expect(offCalls.argv.isEmpty)
    }

    /// `doctor`'s info lines: the status line's last limit reading, the summary engine's CLI, Jira without its token.
    @Test func doctorInfo() throws {
        var (home, o) = setUp()
        let none = try Installer(o).info()
        #expect(none[0].hasPrefix("claude limits: no reading in 7 days"))
        #expect(none[1].hasPrefix("claude editor panels: not set in any editor;"))
        if Sys.which("claude", path: "/usr/local/bin:/opt/homebrew/bin") == nil {  // a claude installed on this machine is not the test's
            #expect(none[2] == "summary engine: claude CLI not found (summaries and task suggestions are made without AI)")
        }
        #expect(none[3] == "jira: not configured ([jira] in \(home)/.zagon/config.toml)")

        Sys.mkdirs(o.paths.spool)
        Sys.writeFile(o.paths.spool + "/.limits-s-1", Array("1.000 {}".utf8))
        Sys.mkdirs(home + "/.local/bin")
        Sys.writeFile(home + "/.local/bin/claude", [0], mode: 0o755)
        Sys.writeFile(o.paths.config, Array("[jira]\nurl = \"https://jira.example.com\"\nemail = \"a@example.com\"\ntoken_file = \"\(home)/tok\"\n".utf8))
        o.now = Sys.now() + 7 * 60 + 5
        let some = try Installer(o).info()
        #expect(some[0] == "claude limits: last reading 7 min ago")
        #expect(Array(some[2...]) == ["summary engine: claude \(home)/.local/bin/claude", "jira token: cannot read \(home)/tok"])
        Sys.writeFile(home + "/tok", Array("not-a-real-token\n".utf8), mode: 0o600)
        let jira = try Installer(o).info()[3]
        #expect(jira == "jira: configured, jira.example.com")
        o.now += 3 * 86400
        #expect(try Installer(o).info()[0] == "claude limits: last reading 3 days ago")
    }

    /// The script for the editor setting claudeCode.claudeProcessWrapper, and what doctor reads of the editors'
    /// settings (JSONC, never written).
    @Test func editorPanelWrapper() throws {
        let (home, o) = setUp()
        let script = home + "/.zagon/bin/claude-wrap"
        var lines: [String] = []
        var inst = installer(o)
        inst.log = { lines.append($0) }
        try inst.install()
        let text = String(decoding: try #require(Sys.readFile(script)), as: UTF8.self)
        #expect(text.hasPrefix("#!/bin/sh\n") && text.contains("z=\(home)/bin/zagon\n"))
        var st = stat()
        #expect(stat(script, &st) == 0 && st.st_mode & 0o777 == 0o755)
        #expect(lines.contains { $0.contains("add \"claudeCode.claudeProcessWrapper\": \"\(script)\" to the editor's user settings") })

        func panels() throws -> String { try Installer(o).info()[1] }
        #expect(try panels().hasPrefix("claude editor panels: not set in any editor;"))
        let cursor = home + "/.config/Cursor/User/settings.json"
        Sys.mkdirs(Sys.dirname(cursor))
        Sys.writeFile(cursor, Array("{\n  // \"claudeCode.claudeProcessWrapper\": \"/old\",\n  \"editor.tabSize\": 2,\n}\n".utf8))
        #expect(try panels().hasPrefix("claude editor panels: not set in any editor;"))  // commented out
        Sys.writeFile(cursor, Array("{\n  \"claudeCode.claudeProcessWrapper\" :  \"\(script)\", // zagon\n}\n".utf8))
        #expect(try panels() == "claude editor panels: claudeCode.claudeProcessWrapper set in \(cursor)")
        let remote = home + "/.cursor-server/data/Machine/settings.json"
        Sys.mkdirs(Sys.dirname(remote))
        Sys.writeFile(remote, Array("{\"claudeCode.claudeProcessWrapper\": \"/nope/wrap\"}".utf8))
        #expect(try panels() == "claude editor panels: claudeCode.claudeProcessWrapper set in \(cursor); "
            + "\(remote) names /nope/wrap, which does not exist: that editor's panel cannot start Claude")

        lines = []
        inst.log = { lines.append($0) }
        try inst.uninstall()
        #expect(Sys.exists(script))  // a setting left behind still starts Claude through it
        #expect(lines.contains("claude: kept \(script) (without zagon it runs Claude Code directly); remove the editor setting "
            + "claudeCode.claudeProcessWrapper, then the file"))
    }

    /// `zagon update` keeps the old binary as .prev and leaves no .prev.new behind, also when .prev is already a link
    /// to it (rename between two links of one file does nothing).
    @Test func keepPreviousLeavesNoTemporaryFile() throws {
        let dir = makeTempDir(), exe = dir + "/zagon"
        Sys.writeFile(exe, Array("v1".utf8), mode: 0o755)
        #expect(Installer.keepPrevious(exe) == exe + ".prev")
        #expect(Sys.readFile(exe + ".prev") == Array("v1".utf8) && !Sys.exists(exe + ".prev.new"))
        #expect(Installer.keepPrevious(exe) == exe + ".prev")  // .prev is now a link to exe
        #expect(Sys.readFile(exe + ".prev") == Array("v1".utf8) && !Sys.exists(exe + ".prev.new"))
        #expect(Installer.keepPrevious(dir + "/missing") == nil && !Sys.exists(dir + "/missing.prev.new"))
    }

    #if os(Linux)
    /// A --user service stops at ssh logout unless the account lingers: install says how to turn it on, never runs sudo.
    @Test func userServiceWithoutLingerIsAdvised() throws {
        let (home, o0) = setUp()
        var o = o0
        o.searchPath = home + "/fake-bin"; o.enableService = true; o.mcp = false
        Sys.mkdirs(o.searchPath!)
        Sys.writeFile(o.searchPath! + "/systemctl", [0], mode: 0o755)
        func run(linger: String) throws -> [String] {
            Sys.writeFile(o.searchPath! + "/loginctl", Array("#!/bin/sh\necho \(linger)\n".utf8), mode: 0o755)
            var lines: [String] = []
            var i = installer(o)
            i.log = { lines.append($0) }
            try i.install()
            return lines
        }
        let advice = "sudo loginctl enable-linger \(Installer(o).userName)"
        #expect(try run(linger: "no").contains { $0.hasSuffix(advice) })
        #expect(try !run(linger: "yes").contains { $0.contains("linger") })
        // An account with no login: loginctl fails, and no flag file says it lingers.
        #expect(try run(linger: "x; exit 1").contains { $0.hasSuffix(advice) } == !Sys.exists("/var/lib/systemd/linger/root"))
    }
    #endif

    @Test func refusesBrokenJSON() throws {
        let (home, o) = setUp()
        Sys.writeFile(home + "/.claude/settings.json", Array("{\"a\": 1,}".utf8))
        #expect(throws: InstallError.self) { try installer(o).install() }
        #expect(Sys.readFile(home + "/.claude/settings.json") == Array("{\"a\": 1,}".utf8))
    }
}
