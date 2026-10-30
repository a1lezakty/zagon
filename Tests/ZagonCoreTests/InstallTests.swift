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

    @Test func refusesBrokenJSON() throws {
        let (home, o) = setUp()
        Sys.writeFile(home + "/.claude/settings.json", Array("{\"a\": 1,}".utf8))
        #expect(throws: InstallError.self) { try installer(o).install() }
        #expect(Sys.readFile(home + "/.claude/settings.json") == Array("{\"a\": 1,}".utf8))
    }
}
