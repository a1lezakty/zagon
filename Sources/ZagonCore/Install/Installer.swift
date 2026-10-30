import CSys
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public struct InstallError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// The account whose home install / uninstall / doctor work in.
public struct Account: Sendable, Equatable {
    public var name: String, uid: UInt32, gid: UInt32, home: String
    public init(name: String, uid: UInt32, gid: UInt32, home: String) { self.name = name; self.uid = uid; self.gid = gid; self.home = home }

    /// From the passwd database.
    public static func named(_ name: String) -> Account? {
        guard let pw = getpwnam(name) else { return nil }
        return Account(name: String(cString: pw.pointee.pw_name), uid: UInt32(pw.pointee.pw_uid), gid: UInt32(pw.pointee.pw_gid),
                       home: String(cString: pw.pointee.pw_dir))
    }

    /// Whom to install for: `explicit` (`--user`); else, for root under sudo, the user who ran sudo (`SUDO_USER`):
    /// `$USER` / `$HOME` are root's there or a mix. nil = this process's own account and `$HOME`.
    public static func target(explicit: String?, uid: UInt32 = UInt32(getuid()), sudoUser: String? = Sys.env("SUDO_USER"),
                              lookup: (String) -> Account? = named) throws -> Account? {
        if let explicit {
            guard let a = lookup(explicit) else { throw InstallError("no such user: \(explicit)") }
            return a
        }
        guard uid == 0, let su = sudoUser, !su.isEmpty, su != "root" else { return nil }
        guard let a = lookup(su) else { throw InstallError("SUDO_USER \(su) is not in the passwd database; pass --user") }
        return a
    }
}

/// `zagon install` / `uninstall` / `doctor`.
///
/// Config files are edited as ordered JSON (unknown keys kept, indentation and final newline of the file kept).
/// Before a file is changed it is copied to `~/.zagon/backup/<ts>/` (or an `<name>.absent` marker is left).
/// Uninstall restores that copy byte for byte when the file still is exactly what install made of it; if the user
/// changed it since, only Zagon's entries are removed.
public struct Installer {
    public static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse",
                                      "Notification", "Stop", "SessionEnd"]
    public static let codexEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop",
                                     "Interrupt", "SessionEnd"]

    public struct Options {
        public var paths: ZagonPaths
        /// The account `paths` belong to when it is not this process's (root for a sudo user); its files are written
        /// as that user, and the system unit runs as it.
        public var user: Account?
        /// Absolute path written into hooks, status line, MCP and the unit.
        public var zagon: String
        public var claudeDir: String
        public var codexDir: String
        public var claude = true
        public var codex: Bool
        public var statusLine = true
        public var mcp = true
        public var enableService = false
        public var systemService = false
        public var systemUnitDir = "/etc/systemd/system"
        public var userUnitDir: String
        /// Claude Code's own state file, where `claude mcp add --scope user` registers servers.
        public var claudeJSON: String
        /// PATH used to find `claude`, `codex`, `systemctl`.
        public var searchPath: String?
        public var now: Double

        /// `user`: its home replaces `$HOME` for every path.
        public init(paths: ZagonPaths? = nil, user: Account? = nil, zagon: String = Sys.executablePath()) {
            let paths = paths ?? ZagonPaths(home: user?.home)
            self.paths = paths
            self.user = user
            self.zagon = zagon
            claudeDir = Sys.env("CLAUDE_CONFIG_DIR") ?? paths.home + "/.claude"
            codexDir = Sys.env("CODEX_HOME") ?? paths.home + "/.codex"
            codex = Sys.isDir(codexDir)
            userUnitDir = (Sys.env("XDG_CONFIG_HOME") ?? paths.home + "/.config") + "/systemd/user"
            claudeJSON = Sys.env("CLAUDE_CONFIG_DIR").map { $0 + "/.claude.json" } ?? paths.home + "/.claude.json"
            searchPath = Sys.env("PATH")
            now = Sys.now()
        }
    }

    public var o: Options
    /// Runs an external command (argv[0] absolute); returns its exit status.
    public var runner: ([String]) -> Int32 = { Sys.run($0, quiet: true) }
    public var log: (String) -> Void = { print($0) }

    public init(_ o: Options) { self.o = o }

    var exe: String { Sys.shellQuote(o.zagon) }
    var claudeSettings: String { o.claudeDir + "/settings.json" }
    var codexHooks: String { o.codexDir + "/hooks.json" }
    var codexConfig: String { o.codexDir + "/config.toml" }
    var userUnit: String { o.userUnitDir + "/zagon.service" }
    var systemUnit: String { o.systemUnitDir + "/zagon-\(userName).service" }
    /// Who the system unit runs as: `o.user`, else this process's account (not `$USER`, which sudo may keep).
    var userName: String {
        o.user?.name ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_name) } ?? Sys.env("USER") ?? Sys.basename(o.paths.home)
    }
    /// Root working for another account: its CLIs (`claude mcp`, `systemctl --user`) are not run from here.
    var forOther: Bool { o.user.map { $0.uid != UInt32(getuid()) } ?? false }

    /// Runs `body` with the file identity of `o.user` when root works for another account: files in that home are
    /// created by their owner, and a symlink planted there cannot make root write elsewhere. This thread only.
    func asUser<T>(_ body: () throws -> T) throws -> T {
        guard let u = o.user, forOther, geteuid() == 0 else { return try body() }
        guard z_as_user(u.uid, u.gid) == 0 else {
            throw InstallError("cannot act as \(u.name) here; run zagon install as \(u.name), without sudo")
        }
        defer { z_as_root() }
        return try body()
    }

    // MARK: install

    public func install() throws {
        // Hooks and the status line run this path from any directory: a relative or wrong one fails every event.
        guard o.zagon.hasPrefix("/"), access(o.zagon, X_OK) == 0, !Sys.isDir(o.zagon) else {
            throw InstallError("--bin must be the absolute path of the zagon executable, got \(o.zagon)")
        }
        try asUser { try installFiles() }
        try installService()
    }

    /// Everything in the user's home.
    func installFiles() throws {
        Sys.mkdirs(o.paths.spool)
        var backupDir: String?
        func backup(_ name: String, _ cur: [UInt8]?) throws {
            if backupDir == nil {
                var d = o.paths.backup + "/" + Sys.stamp(o.now), n = 2
                while Sys.exists(d) { d = o.paths.backup + "/" + Sys.stamp(o.now) + "-\(n)"; n += 1 }
                guard Sys.mkdirs(d) else { throw InstallError("cannot create \(d)") }
                backupDir = d
            }
            let ok = cur.map { Sys.writeFile(backupDir! + "/" + name, $0, mode: 0o600) }
                ?? Sys.writeFile(backupDir! + "/" + name + ".absent", [], mode: 0o600)
            guard ok else { throw InstallError("cannot write backup of \(name)") }
        }

        if o.claude {
            let cur = Sys.readFile(claudeSettings)
            let new = try installed(cur, tool: "claude", statusLine: o.statusLine)
            if new != cur {
                try backup("claude-settings.json", cur)
                if o.statusLine {
                    // Wrapping now: remember the user's command (nil = there was none) for the wrapper and uninstall.
                    let orig = try statusCommand(cur)
                    if orig.map({ !isOurs($0, "statusline") }) ?? true { try setConfig(orig) }
                }
                Sys.mkdirs(o.claudeDir)
                guard Sys.writeFile(claudeSettings, new!) else { throw InstallError("cannot write \(claudeSettings)") }
                log("claude: hooks\(o.statusLine ? " and status line" : "") installed in \(claudeSettings)")
            } else { log("claude: already installed") }
        }
        if o.codex {
            let cur = Sys.readFile(codexHooks)
            let new = try installed(cur, tool: "codex", statusLine: false)
            if new != cur {
                try backup("codex-hooks.json", cur)
                Sys.mkdirs(o.codexDir)
                guard Sys.writeFile(codexHooks, new!) else { throw InstallError("cannot write \(codexHooks)") }
                log("codex: hooks installed in \(codexHooks); open /hooks in Codex once to trust them")
            } else { log("codex: already installed") }
        }
        if o.mcp && forOther {
            log("mcp: not registered from sudo; run `zagon install` as \(userName) for it")
        } else if o.mcp {
            if o.claude, let claude = Sys.which("claude", path: o.searchPath), !claudeHasMCP() {
                let rc = runner([claude, "mcp", "add", "--scope", "user", "zagon", "--", o.zagon, "mcp"])
                log(rc == 0 ? "claude: MCP server zagon added" : "claude: `claude mcp add` failed (\(rc))")
            }
            if o.codex, let codex = Sys.which("codex", path: o.searchPath), !codexHasMCP() {
                try backup("codex-config.toml", Sys.readFile(codexConfig))
                let rc = runner([codex, "mcp", "add", "zagon", "--", o.zagon, "mcp"])
                log(rc == 0 ? "codex: MCP server zagon added" : "codex: `codex mcp add` failed (\(rc))")
            }
        }
        if let backupDir { log("backup: \(backupDir)") }
    }

    func setConfig(_ original: String?) throws {
        let cur = Sys.readFile(o.paths.config).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let new = TOMLLite.setting(cur, section: StatusLine.configSection, key: StatusLine.configKey, to: original)
        guard new != cur else { return }
        Sys.mkdirs(o.paths.dir)
        guard Sys.writeFile(o.paths.config, Array(new.utf8), mode: 0o600) else { throw InstallError("cannot write \(o.paths.config)") }
    }

    func installService() throws {
        #if !os(Linux)
        if o.enableService || o.systemService { log("service: skipped (on macOS Zagon.app collects data)") }
        #else
        let user = unitText(system: false)
        try asUser {
            if Sys.readFile(userUnit) != Array(user.utf8) {
                Sys.mkdirs(Sys.dirname(userUnit), mode: 0o755)
                guard Sys.writeFile(userUnit, Array(user.utf8)) else { throw InstallError("cannot write \(userUnit)") }
                log("service: wrote \(userUnit)")
            }
        }
        if o.systemService {
            let sys = unitText(system: true)
            if Sys.readFile(systemUnit) != Array(sys.utf8) {
                guard Sys.writeFile(systemUnit, Array(sys.utf8)) else { throw InstallError("cannot write \(systemUnit) (root needed)") }
                log("service: wrote \(systemUnit)")
            }
        }
        guard o.enableService else {
            if !o.systemService { log("service: enable with `zagon install --enable-service`") }
            return
        }
        guard let sc = Sys.which("systemctl", path: o.searchPath) else { log("service: systemctl not found"); return }
        if o.systemService {
            _ = runner([sc, "daemon-reload"])
            let rc = runner([sc, "enable", "--now", Sys.basename(systemUnit)])
            log(rc == 0 ? "service: \(Sys.basename(systemUnit)) enabled" : "service: enabling the system unit failed (\(rc))")
        } else if forOther {
            log("service: as \(userName): systemctl --user enable --now zagon.service (or here: --system-service)")
            lingerNote().map(log)
        } else {
            _ = runner([sc, "--user", "daemon-reload"])
            let rc = runner([sc, "--user", "enable", "--now", "zagon.service"])
            log(rc == 0 ? "service: zagon.service enabled (systemd --user)"
                : "service: systemd --user is not available (\(rc)); sudo zagon install --system-service --enable-service")
            if rc == 0 { lingerNote().map(log) }
        }
        #endif
    }

    /// Keeps `exe` as `<exe>.prev` (a hard link, else a copy) for `zagon update`. The old .prev is replaced only once the
    /// copy is complete, so a failure keeps it. Returns the .prev path, nil when it could not be kept.
    public static func keepPrevious(_ exe: String) -> String? {
        let prev = exe + ".prev", tmp = prev + ".new"
        _ = Sys.remove(tmp)
        // Also after success: a rename between two links of one file (.prev already that binary) does nothing and
        // leaves the source in place.
        defer { _ = Sys.remove(tmp) }
        guard link(exe, tmp) == 0 || Sys.readFile(exe).map({ Sys.writeFile(tmp, $0, mode: 0o755) }) == true,
              rename(tmp, prev) == 0 else { return nil }
        return prev
    }

    /// What `zagon update` from `old` to `new` turns on by itself: lines to print, only when it crosses 0.1.1 (none
    /// for a build from source, whose version is "dev").
    public static func updateNews(from old: String, to new: String) -> [String] {
        func v(_ s: String) -> [Int]? {
            let p = s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
            return p.count == 3 && !p.contains(nil) ? p.compactMap { $0 } : nil
        }
        guard let o = v(old), let n = v(new), o.lexicographicallyPrecedes([0, 1, 1]), !n.lexicographicallyPrecedes([0, 1, 1])
        else { return [] }
        return ["new in 0.1.1: a daily AI summary at 20:00 (one Haiku call, ~$0.005) and evening task suggestions (one more call)",
                "turn off: zagon summary --at off; [tasks] evening_suggestions = false in ~/.zagon/config.toml (README: Privacy)"]
    }

    /// systemd stops an account's --user services when its last login ends (ssh logout) unless it lingers; turning
    /// that on needs root, so it is only advised. loginctl knows nothing of an account with no login (root installing
    /// for another one): then the flag file `enable-linger` writes decides.
    func lingerNote() -> String? {
        guard let lc = Sys.which("loginctl", path: o.searchPath) else { return nil }
        let r = Sys.capture([lc, "show-user", userName, "-p", "Linger", "--value"], timeout: 10)
        let no = r.status == 0 ? String(decoding: r.out, as: UTF8.self).split(whereSeparator: \.isWhitespace) == ["no"]
            : !Sys.exists("/var/lib/systemd/linger/" + userName)
        guard no else { return nil }
        return "service: it stops when you log out of ssh; to keep it running: sudo loginctl enable-linger \(userName)"
    }

    func unitText(system: Bool) -> String {
        let exec = o.zagon.contains(" ") ? "\"\(o.zagon)\"" : o.zagon
        var s = "[Unit]\nDescription=Zagon session tracker\n\n[Service]\nExecStart=\(exec) daemon\nRestart=on-failure\nRestartSec=10\n"
            // The daemon itself stays under ~15 MB anon; the limit also covers the day summary's `claude -p` child
            // (~250 MB peak, same cgroup).
            + "MemoryHigh=256M\nMemoryMax=512M\nNice=10\n"
        if system { s += "User=\(userName)\nEnvironment=HOME=\(o.paths.home)\n" }
        if o.paths.dir != o.paths.home + "/.zagon" { s += "Environment=ZAGON_DIR=\(o.paths.dir)\n" }
        return s + "\n[Install]\nWantedBy=\(system ? "multi-user.target" : "default.target")\n"
    }

    // MARK: uninstall

    public func uninstall() throws {
        try asUser { try uninstallFiles() }
        if o.mcp && forOther {
            log("mcp: not removed from sudo; run `zagon uninstall` as \(userName) for it")
        } else if o.mcp {
            if let claude = Sys.which("claude", path: o.searchPath), claudeHasMCP() {
                _ = runner([claude, "mcp", "remove", "--scope", "user", "zagon"]); log("claude: MCP server zagon removed")
            }
            if let codex = Sys.which("codex", path: o.searchPath), codexHasMCP() {
                _ = runner([codex, "mcp", "remove", "zagon"]); log("codex: MCP server zagon removed")
            }
        }
        let sc = Sys.which("systemctl", path: o.searchPath)
        for (unit, user) in [(userUnit, true), (systemUnit, false)] where Sys.exists(unit) {
            if let sc, !(user && forOther) {
                _ = runner(user ? [sc, "--user", "disable", "--now", "zagon.service"] : [sc, "disable", "--now", Sys.basename(unit)])
            }
            Sys.remove(unit)
            log("service: removed \(unit)")
        }
    }

    /// Hook files and config.toml in the user's home.
    func uninstallFiles() throws {
        if o.claude {
            let original = TOMLLite.string(at: o.paths.config, section: StatusLine.configSection, key: StatusLine.configKey)
            try restore(path: claudeSettings, name: "claude-settings.json",
                        redo: { try installed($0, tool: "claude", statusLine: o.statusLine) },
                        strip: { try stripped($0, statusOriginal: original) })
            try setConfig(nil)
        }
        if o.codex {
            try restore(path: codexHooks, name: "codex-hooks.json",
                        redo: { try installed($0, tool: "codex", statusLine: false) },
                        strip: { try stripped($0, statusOriginal: nil) })
        }
    }

    /// Restores the newest backup of `name` if the file is still exactly what install produced from it,
    /// otherwise removes only Zagon's entries.
    func restore(path: String, name: String, redo: ([UInt8]?) throws -> [UInt8]?,
                 strip: ([UInt8]) throws -> [UInt8]?) throws {
        let cur = Sys.readFile(path)
        for d in Sys.listDir(o.paths.backup).reversed() {
            let dir = o.paths.backup + "/" + d
            let orig = Sys.readFile(dir + "/" + name)  // nil = the file did not exist (".absent")
            guard orig != nil || Sys.exists(dir + "/" + name + ".absent") else { continue }
            // A copy taken by a re-install (e.g. a new binary path) already holds our entries: look further back.
            if let orig, (try? strip(orig)) != nil { continue }
            if let c = cur, (try? redo(orig)) == c {
                if let orig { guard Sys.writeFile(path, orig) else { throw InstallError("cannot write \(path)") } }
                else { Sys.remove(path) }
                log("restored \(path) from \(dir)")
                return
            }
            break
        }
        guard let cur, let new = try strip(cur) else { return }
        guard Sys.writeFile(path, new) else { throw InstallError("cannot write \(path)") }
        log("removed zagon entries from \(path) (it changed since install, backup not applied)")
    }

    // MARK: JSON edits

    struct Format { var indent = "  ", newline = true }

    static func format(of b: [UInt8]) -> Format {
        var f = Format(indent: "  ", newline: b.last == 0x0A)
        if let nl = b.firstIndex(of: 0x0A) {
            let ws = b[(nl + 1)...].prefix { $0 == 0x20 || $0 == 0x09 }
            if !ws.isEmpty { f.indent = String(decoding: ws, as: UTF8.self) }
        }
        return f
    }

    func load(_ cur: [UInt8]?) throws -> JValue {
        guard let cur, cur.contains(where: { $0 > 0x20 }) else { return .object([]) }
        guard let v = JValue.parse(cur), case .object = v else { throw InstallError("not a JSON object; left untouched") }
        return v
    }

    func command(_ tool: String, _ event: String) -> String { "\(exe) hook \(tool) \(event)" }

    /// `<…/zagon> <rest>` with any path to a binary named zagon.
    func isOurs(_ cmd: String, _ rest: String) -> Bool {
        let c = cmd.trimmingSpaces
        let bin: Substring, tail: Substring
        if c.hasPrefix("'"), let e = c.dropFirst().firstIndex(of: "'") {
            bin = c[c.index(after: c.startIndex)..<e]; tail = c[c.index(after: e)...]
        } else if let sp = c.firstIndex(of: " ") {
            bin = c[..<sp]; tail = c[sp...]
        } else { return false }
        return Sys.basename(String(bin)) == "zagon" && tail.trimmingSpaces == rest
    }

    func isOurHook(_ cmd: String) -> Bool {
        let parts = cmd.trimmingSpaces.split(separator: " ")
        guard parts.count >= 4, parts[parts.count - 3] == "hook" else { return false }
        return isOurs(cmd, parts.suffix(3).joined(separator: " "))
    }

    func statusCommand(_ cur: [UInt8]?) throws -> String? { try load(cur)["statusLine"]?["command"]?.string }

    /// The file with Zagon installed (same bytes if nothing had to change).
    func installed(_ cur: [UInt8]?, tool: String, statusLine: Bool) throws -> [UInt8]? {
        var doc = try load(cur)
        var changed = false
        var hooks = doc["hooks"] ?? .object([])
        guard case .object = hooks else { throw InstallError("\"hooks\" is not an object; left untouched") }
        for e in tool == "claude" ? Self.claudeEvents : Self.codexEvents {
            let want = command(tool, e)
            var groups = hooks[e]?.array ?? []
            var found = false
            for (gi, g) in groups.enumerated() {
                guard var hs = g["hooks"]?.array else { continue }
                for (hi, h) in hs.enumerated() {
                    guard let c = h["command"]?.string, isOurs(c, "hook \(tool) \(e)") else { continue }
                    found = true
                    if c != want { hs[hi]["command"] = .string(want); groups[gi]["hooks"] = .array(hs); changed = true }
                }
            }
            if !found {
                groups.append(.object([.init("hooks", .array([.object([.init("type", .string("command")),
                                                                        .init("command", .string(want))])]))]))
                changed = true
            }
            hooks[e] = .array(groups)
        }
        doc["hooks"] = hooks
        if statusLine {
            let want = "\(exe) statusline"
            if case .object = doc["statusLine"] ?? .null {
                if doc["statusLine"]?["command"]?.string != want {
                    doc["statusLine"]?["command"] = .string(want)
                    if doc["statusLine"]?["type"] == nil { doc["statusLine"]?["type"] = .string("command") }
                    changed = true
                }
            } else {
                doc["statusLine"] = .object([.init("type", .string("command")), .init("command", .string(want))])
                changed = true
            }
        }
        guard changed else { return cur }
        let f = cur.map(Self.format) ?? Format()
        return Array((doc.pretty(indent: f.indent) + (f.newline ? "\n" : "")).utf8)
    }

    /// The file without Zagon's hooks and status line; nil if there was nothing of ours.
    func stripped(_ cur: [UInt8], statusOriginal: String?) throws -> [UInt8]? {
        var doc = try load(cur)
        var changed = false
        if case .object(let events)? = doc["hooks"] {
            var kept: [JValue.Member] = []
            for ev in events {
                guard case .array(let groups) = ev.value else { kept.append(ev); continue }
                var newGroups: [JValue] = []
                for g in groups {
                    guard let hs = g["hooks"]?.array else { newGroups.append(g); continue }
                    let rest = hs.filter { !($0["command"]?.string.map(isOurHook) ?? false) }
                    if rest.count == hs.count { newGroups.append(g); continue }
                    changed = true
                    if !rest.isEmpty { var g2 = g; g2["hooks"] = .array(rest); newGroups.append(g2) }
                }
                if !newGroups.isEmpty || groups.isEmpty { kept.append(.init(ev.key, .array(newGroups))) }
            }
            doc["hooks"] = kept.isEmpty && changed ? nil : .object(kept)
        }
        if let c = doc["statusLine"]?["command"]?.string, isOurs(c, "statusline") {
            if let statusOriginal { doc["statusLine"]?["command"] = .string(statusOriginal) } else { doc["statusLine"] = nil }
            changed = true
        }
        guard changed else { return nil }
        let f = Self.format(of: cur)
        return Array((doc.pretty(indent: f.indent) + (f.newline ? "\n" : "")).utf8)
    }

    // MARK: MCP

    func claudeHasMCP() -> Bool {
        guard let b = Sys.readFile(o.claudeJSON), let v = JValue.parse(b, maxDepth: 512) else { return false }
        return v["mcpServers"]?["zagon"] != nil
    }

    func codexHasMCP() -> Bool {
        guard let b = Sys.readFile(codexConfig) else { return false }
        let t = String(decoding: b, as: UTF8.self)
        return TOMLLite.hasSection(t, "mcp_servers.zagon")
    }

    // MARK: doctor

    public struct Check: Sendable {
        public var ok: Bool
        public var text: String
    }

    public func doctor() -> [Check] {
        var out: [Check] = []
        func add(_ ok: Bool, _ t: String) { out.append(Check(ok: ok, text: t)) }
        add(Sys.exists(o.zagon), "binary \(o.zagon)")
        func hookChecks(_ path: String, _ tool: String, _ events: [String]) {
            guard let b = Sys.readFile(path), let doc = try? load(b) else { add(false, "\(tool): \(path) missing or unreadable"); return }
            var missing: [String] = [], stale: [String] = []
            for e in events {
                let cmds = (doc["hooks"]?[e]?.array ?? []).flatMap { $0["hooks"]?.array ?? [] }.compactMap { $0["command"]?.string }
                if cmds.contains(command(tool, e)) { continue }
                if cmds.contains(where: { isOurs($0, "hook \(tool) \(e)") }) { stale.append(e) } else { missing.append(e) }
            }
            add(missing.isEmpty && stale.isEmpty, "\(tool): hooks " + (missing.isEmpty && stale.isEmpty ? "installed (\(events.count))"
                : (missing.isEmpty ? "" : "missing \(missing.joined(separator: ","))") + (stale.isEmpty ? "" : " other zagon path \(stale.joined(separator: ","))")))
            if tool == "claude" {
                let sl = doc["statusLine"]?["command"]?.string
                let orig = TOMLLite.string(at: o.paths.config, section: StatusLine.configSection, key: StatusLine.configKey)
                add(sl == "\(exe) statusline", "claude: status line " + (sl == "\(exe) statusline"
                    ? "wrapped (original command: \(orig == nil ? "none" : "saved in config.toml"))" : "not wrapped"))
            }
        }
        if o.claude { hookChecks(claudeSettings, "claude", Self.claudeEvents) }
        if o.codex {
            hookChecks(codexHooks, "codex", Self.codexEvents)
            let cfg = Sys.readFile(codexConfig).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let off = ["hooks", "codex_hooks"].contains { TOMLLite.raw(in: cfg, section: "features", key: $0) == "false" }
            add(!off, "codex: hooks feature " + (off ? "disabled in config.toml [features]" : "enabled (trust them once in /hooks)"))
        }
        if o.mcp {
            for (tool, on, has) in [("claude", o.claude, claudeHasMCP()), ("codex", o.codex, codexHasMCP())] where on {
                if !has && Sys.which(tool, path: o.searchPath) == nil { add(true, "\(tool): MCP skipped (no \(tool) CLI on PATH)"); continue }
                add(has, "\(tool): MCP server zagon " + (has ? "registered" : "not registered"))
            }
        }
        #if os(Linux)
        let unit = Sys.exists(userUnit)
        var unitText = "service: \(userUnit) " + (unit ? "present" : "missing")
        if unit, let sc = Sys.which("systemctl", path: o.searchPath) {
            unitText += runner([sc, "--user", "is-enabled", "--quiet", "zagon.service"]) == 0 ? ", enabled" : ", not enabled"
        }
        if Sys.exists(systemUnit) { unitText += "; system unit \(systemUnit) present" }
        add(unit || Sys.exists(systemUnit), unitText)
        #else
        add(true, "service: none (Zagon.app collects data on macOS)")
        #endif
        let files = Sys.listDir(o.paths.spool).filter { $0.hasSuffix(".ndjson") }
        if let last = files.last, let m = Sys.mtime(o.paths.spool + "/" + last) {
            add(true, "spool: last write \(Int(o.now - m)) s ago (\(files.count) file(s))")
        } else {
            add(Sys.isDir(o.paths.spool), "spool: \(o.paths.spool) " + (Sys.isDir(o.paths.spool) ? "empty (no hook has fired yet)" : "missing"))
        }
        return out
    }
}
