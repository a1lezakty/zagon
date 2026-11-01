import ArgumentParser
import ZagonCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `zagon update [--check]`: replaces this binary with the latest GitHub release (Linux). Network only on this
/// command; the daemon never checks for updates.
struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Update this binary to the latest release and restart the service (Linux; on macOS Zagon.app updates itself).",
        discussion: "The previous binary stays next to it as <name>.prev: mv it back to roll back.")
    @Flag(help: "Only tell whether a newer release exists.") var check = false
    @Option(help: "Where the release files are (https), e.g. https://github.com/a1lezakty/zagon/releases/download/v0.1.0 for a fixed version.")
    var from = "https://github.com/a1lezakty/zagon/releases/latest/download"
    @Flag(name: .customLong("restart-services"), help: ArgumentHelp("Only restart the running services of this binary (install.sh).", visibility: .hidden))
    var restartOnly = false
    @Option(help: ArgumentHelp("With --restart-services: the account install.sh installed for.", visibility: .hidden)) var user: String?
    @Option(name: .customLong("db-schema"), help: ArgumentHelp("Only print the schema of <data-dir>/zagon.db and the one this binary reads (an update asks the new binary).", visibility: .hidden))
    var dbSchema: String?

    func run() throws {
        if let dbSchema { SchemaCheck.answer(dataDir: dbSchema).map { print($0) }; return }
        #if os(Linux)
        if restartOnly { Self.restartServices(Sys.executablePath(), user: user); return }
        #if arch(x86_64)
        let asset = "zagon-linux-x86_64"
        #elseif arch(arm64)
        let asset = "zagon-linux-aarch64"
        #else
        let asset = ""
        #endif
        guard !asset.isEmpty else { throw InstallError("no release build for this CPU; build from source") }
        guard let curl = Sys.which("curl") else { throw InstallError("curl is needed for zagon update") }
        let exe = Sys.executablePath(), dir = Sys.dirname(exe), base = from.hasSuffix("/") ? String(from.dropLast()) : from
        let get = [curl, "--proto", "=https", "--tlsv1.2", "-fsSL"]
        // sudo drops proxy variables (https_proxy…), so a download that works for the user fails under it
        let proxy = geteuid() == 0 && Sys.env("SUDO_USER") != nil ? "; behind a proxy: sudo -E zagon update" : ""

        let sums = Sys.capture(get + ["--max-time", "60", base + "/SHA256SUMS"])
        guard sums.status == 0 else { throw InstallError("cannot download \(base)/SHA256SUMS (curl exit \(sums.status))\(proxy)") }
        guard let want = Self.sum(of: asset, in: String(decoding: sums.out, as: UTF8.self)) else {
            throw InstallError("\(asset) is not listed in \(base)/SHA256SUMS")
        }
        if try Self.sha256(exe) == want { print("zagon \(zagonVersion) is up to date"); return }
        if check { print("zagon \(zagonVersion): the release differs from this binary; `zagon update` installs it"); return }

        guard access(dir, W_OK) == 0, access(exe, W_OK) == 0 else {
            if errno == EROFS { throw InstallError("\(dir) is read-only: install zagon somewhere writable (install.sh)") }
            throw InstallError("cannot write \(exe): run sudo zagon update (or reinstall to ~/.local/bin)")
        }
        // Same directory as the binary, so the final rename is atomic.
        let tmp = dir + "/.zagon-update-\(getpid())", fd = Sys.createExclusive(tmp)
        guard fd >= 0 else { throw InstallError("cannot create \(tmp)") }
        close(fd)
        defer { _ = Sys.remove(tmp) }
        guard Sys.run(get + ["--max-time", "600", "-o", tmp, base + "/" + asset]) == 0 else {
            throw InstallError("cannot download \(base)/\(asset)\(proxy)")
        }
        guard try Self.sha256(tmp) == want else { throw InstallError("checksum mismatch for \(asset): nothing replaced") }
        chmod(tmp, 0o755)
        let probe = Sys.capture([tmp, "--version"], timeout: 30)
        guard probe.status == 0 else { throw InstallError("the downloaded binary does not run here (exit \(probe.status)): nothing replaced") }
        let new = String(decoding: probe.out, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "?"
        // A new schema makes .prev useless with the database; one the new binary cannot read would stop its service.
        // Every database is asked before anything is printed or copied.
        let answers = Self.dataDirs(exe, user: user).compactMap { d -> (db: String, answer: String)? in
            let r = Sys.capture([tmp, "update", "--db-schema", d], timeout: 60)
            return r.status == 0 ? (d + "/zagon.db", String(decoding: r.out, as: UTF8.self)) : nil  // else a release without it
        }
        let notes = answers.map { SchemaCheck.notes(answer: $0.answer, db: $0.db, exe: exe, old: zagonVersion, new: new) }
        if let n = notes.first(where: \.stop) { throw InstallError(n.lines.joined(separator: "\n")) }
        for (a, n) in zip(answers, notes) {
            n.lines.forEach { print($0) }
            if let v = SchemaCheck.migrates(answer: a.answer) {
                print(SchemaCheck.snapshotNote(SchemaCheck.snapshot(db: a.db, version: v), db: a.db, exe: exe, old: zagonVersion))
            }
        }

        guard let prev = Installer.keepPrevious(exe) else {
            throw InstallError("cannot keep the old binary as \(exe).prev: nothing replaced")
        }
        guard rename(tmp, exe) == 0 else { throw InstallError("cannot replace \(exe) (errno \(errno))") }
        print("zagon \(zagonVersion) -> \(new) (\(exe); the old one is \(Sys.basename(prev)))")
        Self.restartServices(exe)
        #else
        print(Sys.executablePath().contains(".app/Contents/")
              ? "Zagon.app updates itself (and the zagon inside it); see its settings."
              : "On macOS releases ship as Zagon.app; this zagon is built from source: git pull && swift build -c release")
        #endif
    }

    /// The hash `name` has in a sha256sum listing.
    static func sum(of name: String, in listing: String) -> String? {
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count == 2, f[1] == name || f[1] == "*" + name { return String(f[0]).lowercased() }
        }
        return nil
    }

    static func sha256(_ path: String) throws -> String {
        guard let tool = Sys.which("sha256sum") else { throw InstallError("sha256sum is needed for zagon update") }
        let r = Sys.capture([tool, path], timeout: 60)
        guard r.status == 0, let h = String(decoding: r.out, as: UTF8.self).split(separator: " ").first, h.count == 64 else {
            throw InstallError("cannot hash \(path)")
        }
        return String(h).lowercased()
    }

    /// Restarts the running zagon units whose ExecStart is this binary, after a daemon-reload (install.sh may have just
    /// rewritten them): the system units (`zagon-<user>.service`) as root, the user unit of this account and of the
    /// account installed for (`user`, else the sudo user). Two of them on one database would be two versions writing it,
    /// so a stopped enabled unit gets the command to start it only while no unit of its account runs (one per account,
    /// the system unit first); a stopped disabled one (the user unit `install` writes next to a system unit) is not mentioned.
    static func restartServices(_ exe: String, user: String? = nil) {
        guard let sc = Sys.which("systemctl") else { return }
        let root = geteuid() == 0
        let sysDir = Installer.Options().systemUnitDir
        let system = Sys.listDir(sysDir).sorted().filter { $0.hasPrefix("zagon") && $0.hasSuffix(".service") && runs(sysDir + "/" + $0, exe) }
        if root && !system.isEmpty { _ = Sys.run([sc, "daemon-reload"], quiet: true) }
        let systemStates = system.map { (unit: $0, state: state([sc], $0)) }
        // This account (its $HOME, as `zagon install` uses it; as root the passwd home, since sudo may keep the caller's),
        // then the account installed for: `--user`, else the sudo user.
        let me = getpwuid(getuid()).flatMap { Account.named(String(cString: $0.pointee.pw_name)) }
        var units = [(dir: Installer.Options(user: root ? me : nil).userUnitDir, name: me?.name ?? "", other: false)]
        if let a = try? Account.target(explicit: user), a.uid != getuid() {
            units.append((Installer.Options(user: a).userUnitDir, a.name, true))
        }
        let userStates = units.filter { runs($0.dir + "/zagon.service", exe) }.map { u in
            // This account: plain --user on its own runtime dir, whatever XDG_RUNTIME_DIR sudo -E or su carried over
            // (any systemd); another account: --machine (systemd 248+, as root).
            let ctl = u.other ? [sc, "--user", "--machine=\(u.name)@"] : [sc, "--user"]
            let env = u.other ? [:] : ["XDG_RUNTIME_DIR": "/run/user/\(getuid())"]
            _ = Sys.capture(ctl + ["daemon-reload"], timeout: 60, env: env)
            return (u: u, ctl: ctl, env: env, state: state(ctl, "zagon.service", env: env))
        }
        // The account a system unit is for: zagon-<user>.service.
        func account(_ f: String) -> String { f.hasPrefix("zagon-") ? String(f.dropFirst(6).dropLast(8)) : "" }
        var busy = Set(systemStates.filter { $0.state == .running }.map { account($0.unit) }
                       + userStates.filter { $0.state == .running }.map(\.u.name))

        for (f, s) in systemStates {
            switch s {
            case .running where root:
                print(Sys.run([sc, "try-restart", f], quiet: true) == 0 ? "service: \(f) restarted" : "service: restarting \(f) failed")
            case .running: print("service: sudo systemctl restart \(f)")
            case .stopped where !busy.contains(account(f)):  // one start hint per account: the system unit's
                busy.insert(account(f))
                print("service: \(f) is not running; start it: \(root ? "" : "sudo ")systemctl start \(f)")
            default: break
            }
        }
        for (u, ctl, env, s) in userStates {
            let unit = "zagon.service of \(u.name.isEmpty ? "this account" : u.name) (systemd --user)", start = u.other ? "as \(u.name): " : ""
            switch s {
            case .running:
                print(Sys.capture(ctl + ["try-restart", "zagon.service"], timeout: 60, env: env).status == 0
                      ? "service: \(unit) restarted" : "service: restarting \(unit) failed")
            case .stopped where !busy.contains(u.name): print("service: \(unit) is not running; start it: \(start)systemctl --user start zagon.service")
            // For this account no user manager means nothing of it runs; another account's may be out of --machine's reach.
            case .unknown where u.other && !busy.contains(u.name): print("service: as \(u.name): systemctl --user restart zagon.service")
            default: break
            }
        }
    }

    enum UnitState { case running, stopped, unused, unknown }

    /// running: active or starting; stopped: not running but enabled; unused: neither; unknown: the manager cannot be
    /// asked (no user manager, no systemd). `try-restart` exits 0 on a stopped unit too, so it cannot tell.
    static func state(_ ctl: [String], _ unit: String, env: [String: String] = [:]) -> UnitState {
        func ask(_ verb: String) -> String {
            String(decoding: Sys.capture(ctl + [verb, unit], timeout: 60, env: env).out, as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? ""
        }
        switch ask("is-active") {
        case "": return .unknown
        case "active", "activating", "reloading", "refreshing": return .running
        default: return ask("is-enabled").hasPrefix("enabled") ? .stopped : .unused
        }
    }

    /// The databases the update concerns: this account's, the account installed for (`--user`, else the sudo user),
    /// and those of the units that run `exe` (their `ZAGON_DIR`, else `HOME`).
    static func dataDirs(_ exe: String, user: String?) -> [String] {
        let target = (try? Account.target(explicit: user)) ?? nil
        var dirs = [ZagonPaths().dir] + (target.map { [$0.home + "/.zagon"] } ?? [])
        let sysDir = Installer.Options().systemUnitDir
        let units = Sys.listDir(sysDir).filter { $0.hasPrefix("zagon") && $0.hasSuffix(".service") }.map { sysDir + "/" + $0 }
            + [Installer.Options().userUnitDir + "/zagon.service"]
            + (target.map { [Installer.Options(user: $0).userUnitDir + "/zagon.service"] } ?? [])
        for u in units where runs(u, exe) {
            var env: [String: String] = [:]
            for line in Sys.readFile(u).map({ String(decoding: $0, as: UTF8.self) })?.split(separator: "\n") ?? []
            where line.hasPrefix("Environment=") {
                // Environment=K=V or Environment="K=V" (one assignment, as install writes it)
                var a = line.dropFirst("Environment=".count)
                if a.hasPrefix("\""), a.hasSuffix("\""), a.count >= 2 { a = a.dropFirst().dropLast() }
                let kv = a.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { env[String(kv[0])] = String(kv[1]) }
            }
            if let d = env["ZAGON_DIR"] ?? env["HOME"].map({ $0 + "/.zagon" }) { dirs.append(d) }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert(Sys.realPath($0) ?? $0).inserted }
    }

    /// Whether `unit` starts `exe`: `ExecStart=<path> daemon` (path quoted if it has spaces), as `zagon install` writes it.
    static func runs(_ unit: String, _ exe: String) -> Bool {
        guard let text = Sys.readFile(unit).map({ String(decoding: $0, as: UTF8.self) }),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("ExecStart=") }) else { return false }
        let cmd = line.dropFirst("ExecStart=".count)
        let path = cmd.hasPrefix("\"") ? cmd.dropFirst().prefix { $0 != "\"" } : cmd.prefix { $0 != " " }
        return Sys.realPath(String(path)) == exe
    }
}
