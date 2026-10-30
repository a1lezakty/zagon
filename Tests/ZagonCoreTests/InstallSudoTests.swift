import Foundation
import Testing
@testable import ZagonCore

extension InstallerTests {
    @Test func targetAccount() throws {
        let al = Account(name: "al", uid: 1000, gid: 1000, home: "/home/al")
        let lookup: (String) -> Account? = { $0 == "al" ? al : $0 == "root" ? Account(name: "root", uid: 0, gid: 0, home: "/root") : nil }
        #expect(try Account.target(explicit: "al", uid: 1000, sudoUser: nil, lookup: lookup) == al)
        #expect(throws: InstallError.self) { try Account.target(explicit: "ghost", uid: 0, sudoUser: nil, lookup: lookup) }
        #expect(try Account.target(explicit: nil, uid: 0, sudoUser: "al", lookup: lookup) == al)       // sudo zagon install
        #expect(try Account.target(explicit: nil, uid: 0, sudoUser: nil, lookup: lookup) == nil)      // root's own install
        #expect(try Account.target(explicit: nil, uid: 0, sudoUser: "root", lookup: lookup) == nil)
        #expect(try Account.target(explicit: nil, uid: 1000, sudoUser: "al", lookup: lookup) == nil)  // not root: own files
        #expect(throws: InstallError.self) { try Account.target(explicit: nil, uid: 0, sudoUser: "ghost", lookup: lookup) }
        let o = Installer.Options(user: al)
        #expect(o.paths.home == "/home/al" && o.user == al)
        #expect(Account.named("root")?.uid == 0)
    }

    @Test func binMustBeAnAbsoluteExecutable() throws {
        let (home, o0) = setUp()
        let before = snapshot(home)
        Sys.writeFile(home + "/plain", [0], mode: 0o644)
        for bad in ["zagon", "bin/zagon", "./bin/zagon", home + "/bin", home + "/missing", home + "/plain"] {
            var o = o0
            o.zagon = bad
            #expect(throws: InstallError.self, "\(bad)") { try installer(o).install() }
        }
        #expect(snapshot(home).filter { $0.key != "plain" } == before)  // nothing written
    }

    #if os(Linux)
    func owner(_ path: String) -> UInt32 {
        var st = stat()
        return lstat(path, &st) == 0 ? UInt32(st.st_uid) : .max
    }

    /// Root installing for another account (sudo): its files are created by it, the unit runs as it, its CLIs are not
    /// run as root.
    @Test(.enabled(if: geteuid() == 0, "needs root")) func sudoInstallWritesAsTheUser() throws {
        let nobody = UInt32(65534)
        let (home, o0) = setUp()
        let user = Account(name: "nobody", uid: nobody, gid: nobody, home: home)
        for p in [home, home + "/.claude", home + "/.claude/settings.json", home + "/.codex", home + "/.codex/hooks.json",
                  home + "/.codex/config.toml"] { chown(p, nobody, nobody) }
        let root = makeTempDir()  // binary, system unit dir, fake CLIs: root's
        Sys.writeFile(root + "/zagon", [0], mode: 0o755)
        Sys.mkdirs(root + "/bin"); Sys.mkdirs(root + "/system")
        for b in ["claude", "codex", "systemctl"] { Sys.writeFile(root + "/bin/" + b, [0], mode: 0o755) }
        var o = Installer.Options(paths: o0.paths, user: user, zagon: root + "/zagon")
        o.claudeDir = o0.claudeDir; o.codexDir = o0.codexDir; o.codex = true; o.userUnitDir = o0.userUnitDir
        o.claudeJSON = o0.claudeJSON; o.now = o0.now
        o.searchPath = root + "/bin"; o.systemService = true; o.enableService = true; o.systemUnitDir = root + "/system"
        let calls = Calls()
        try installer(o, calls).install()

        for p in [".claude/settings.json", ".codex/hooks.json", ".zagon", ".zagon/spool", ".zagon/config.toml",
                  ".config/systemd/user/zagon.service"] {
            #expect(owner(home + "/" + p) == nobody, "\(p)")
        }
        let backups = Sys.listDir(home + "/.zagon/backup")
        #expect(backups.count == 1 && Sys.listDir(home + "/.zagon/backup/" + backups[0]).allSatisfy { owner(home + "/.zagon/backup/\(backups[0])/" + $0) == nobody })
        let unit = String(decoding: Sys.readFile(root + "/system/zagon-nobody.service") ?? [], as: UTF8.self)
        #expect(unit.contains("User=nobody\n") && unit.contains("Environment=HOME=\(home)\n") && owner(root + "/system/zagon-nobody.service") == 0)
        #expect(calls.argv.map { Sys.basename($0[0]) } == ["systemctl", "systemctl"] && !calls.argv.joined().contains("--user"))
        // This thread is root again.
        Sys.writeFile(root + "/after", [1])
        #expect(owner(root + "/after") == 0)

        calls.argv = []
        try installer(o, calls).uninstall()
        #expect(Sys.readFile(home + "/.claude/settings.json") == Array(settings.utf8) && owner(home + "/.claude/settings.json") == nobody)
        #expect(!Sys.exists(root + "/system/zagon-nobody.service") && !Sys.exists(o.userUnitDir + "/zagon.service"))
        #expect(!calls.argv.joined().contains("--user") && !calls.argv.contains { Sys.basename($0[0]) != "systemctl" })
    }

    /// A symlink the user planted in their home cannot make root's install write through it.
    @Test(.enabled(if: geteuid() == 0, "needs root")) func sudoInstallDoesNotFollowPlantedLinks() throws {
        let nobody = UInt32(65534)
        let (home, o0) = setUp(files: false)
        let root = makeTempDir()
        Sys.writeFile(root + "/victim", Array("{}\n".utf8))
        Sys.mkdirs(home + "/.claude")
        symlink(root + "/victim", home + "/.claude/settings.json")
        for p in [home, home + "/.claude"] { chown(p, nobody, nobody) }
        lchown(home + "/.claude/settings.json", nobody, nobody)
        var o = o0
        o.user = Account(name: "nobody", uid: nobody, gid: nobody, home: home)
        o.codex = false
        do { try installer(o).install(); Issue.record("installed through a planted link") }
        catch { #expect("\(error)".hasPrefix("cannot write \(home)/.claude/settings.json"), "\(error)") }
        #expect(Sys.readFile(root + "/victim") == Array("{}\n".utf8) && owner(root + "/victim") == 0)
    }
    #endif
}

extension DaySummaryTests {
    @Test func phraseRedactsSecrets() {
        let token = "ghp_" + "Ab3dEf6hIj9lMn2pQr5tUv8xYz1bCd4fGh7j"
        let p = DaySummary.phrase("deploy with\n  password=Hunter2-very-secret and \(token) please")
        #expect(p == "deploy with password=[redacted] and [redacted] please")
        // A key across the 120-character cut is redacted before the cut.
        let long = DaySummary.phrase(String(repeating: "word ", count: 22) + token + " tail")
        #expect(!long.contains("ghp_") && !long.contains("Ab3dEf") && long.hasSuffix("…"))
        #expect(DaySummary.phrase("<command-name>/clear</command-name>") == "")
    }
}
