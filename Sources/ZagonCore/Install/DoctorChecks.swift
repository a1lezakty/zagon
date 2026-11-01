#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// doctor's checks of what runs, beside those of what is installed: the service and its health line, notification
/// channels, Codex's hooks and compressed rollouts, the versions of Claude Code and Codex that write the logs.
extension Installer {
    /// The newest versions the parsers are tested on (fixtures in Tests/ZagonCoreTests/Fixtures). A newer minor version
    /// may write what they do not know yet.
    public static let testedClaude = "2.1.316", testedCodex = "0.166.0"

    /// A daemon writes a health line every 10 minutes (and `start:` / `full pass` lines on start).
    static let healthMaxAge = 900.0

    // MARK: service

    #if os(Linux)
    /// Each unit file there and whether systemd runs it (`is-active`): ok when at least one runs (a user unit `install`
    /// wrote next to the system unit stays stopped).
    func serviceCheck(_ add: (Bool, String) -> Void) {
        let sc = Sys.which("systemctl", path: o.searchPath)
        // Another account's user manager (root doctor for a sudo user): --machine, systemd 248+.
        let user = forOther ? ["--user", "--machine=\(userName)@"] : ["--user"]
        func ask(_ args: [String]) -> Bool { sc.map { runner([$0] + args) == 0 } ?? false }
        var parts: [String] = [], running = false
        if Sys.exists(userUnit) {
            let on = ask(user + ["is-active", "--quiet", "zagon.service"])
            running = running || on
            parts.append("\(userUnit) present" + (sc == nil ? "" : (ask(user + ["is-enabled", "--quiet", "zagon.service"]) ? ", enabled" : ", not enabled")
                + (on ? ", running" : ", not running")))
        }
        if Sys.exists(systemUnit) {
            let on = ask(["is-active", "--quiet", Sys.basename(systemUnit)])
            running = running || on
            parts.append("system unit \(systemUnit) present" + (sc == nil ? "" : on ? ", running" : ", not running"))
        }
        guard !parts.isEmpty else { add(false, "service: \(userUnit) missing"); return }
        guard let _ = sc else { add(true, "service: " + parts.joined(separator: "; ") + " (no systemctl: see the daemon line)"); return }
        let start = Sys.exists(systemUnit) ? (geteuid() == 0 ? "" : "sudo ") + "systemctl enable --now \(Sys.basename(systemUnit))"
            : (forOther ? "as \(userName): " : "") + "systemctl --user enable --now zagon.service"
        add(running, "service: " + parts.joined(separator: "; ") + (running ? "" : "; start it: " + start))
    }

    /// The daemon's last `health:` / `start:` / `full pass` line is at most 15 minutes old.
    func healthCheck(_ log: [String], _ add: (Bool, String) -> Void) {
        let path = o.paths.dir + "/logs/daemon.log"
        guard let l = log.last(where: { $0.contains(" health: ") || $0.contains(" start: ") || $0.contains(" full pass (") }),
              let t = Self.logTime(l) else {
            add(false, "daemon: no health line in \(path): it has not run here")
            return
        }
        let age = o.now - t
        add(age <= Self.healthMaxAge, "daemon: " + (age <= Self.healthMaxAge ? "last health line \(Self.ago(age))"
            : "no health line for \(Self.ago(age).dropLast(4)) (one every 10 min while it runs): stopped or stuck, see \(path)"))
    }
    #endif

    /// The daemon's log, newest line last; the rotated file before it when the current one was just started.
    func daemonLog() -> [String] {
        let p = o.paths.dir + "/logs/daemon.log"
        let cur = LogFile.tail(p, lines: 2000)
        return cur.count < 50 ? LogFile.tail(p + ".1", lines: 2000) + cur : cur
    }

    /// The time of a log line (`<UTC time> <text>`).
    static func logTime(_ l: String) -> Double? {
        l.split(separator: " ", maxSplits: 1).first.flatMap { Time.parseISO(String($0)) }
    }

    // MARK: notifications

    /// Which channels send, whether `[notify]` is on, and how the last message went (from the log).
    func notifyCheck(_ log: [String], _ add: (String, String) -> Void) {
        let c = NotifyConfig.load(o.paths)
        let names = c.channels(o.paths, searchPath: o.searchPath).map(\.name)
        var broken: [String] = []
        if (c.telegramTokenFile != nil || c.telegramChatId != nil) && !names.contains("telegram") {
            broken.append("[telegram] is set but cannot send (" + (c.telegramChatId == nil ? "no chat_id"
                : c.telegramTokenFile.flatMap(Sys.readFile) == nil ? "token_file cannot be read" : "no curl on PATH") + ")")
        }
        if c.ntfyTopic != nil && !names.contains("ntfy") { broken.append("[ntfy] is set but cannot send (no curl on PATH)") }
        guard !names.isEmpty else {
            add(broken.isEmpty ? "info" : "warn", "notify: " + (broken.isEmpty
                ? "no channel ([telegram] or [ntfy] in \(o.paths.config)): limits, waiting sessions and the day summary are sent nowhere"
                : broken.joined(separator: "; ")))
            return
        }
        let sent = log.last { $0.contains(" notify: sent ") }, failed = log.last { $0.contains(" notify: no channel accepted ") }
        let failedAt = failed.flatMap(Self.logTime), sentAt = sent.flatMap(Self.logTime)
        var t = "notify: " + names.joined(separator: ", ") + (c.enabled ? "" : " (alerts off: [notify] enabled = false)")
        if let f = failedAt, f > sentAt ?? 0 {
            add("warn", t + "; the last message was not accepted \(Self.ago(o.now - f)) (see daemon.log)" + broken.map { "; " + $0 }.joined())
            return
        }
        t += sentAt.map { "; last sent \(Self.ago(o.now - $0))" } ?? ""
        add(broken.isEmpty ? "info" : "warn", t + broken.map { "; " + $0 }.joined())
    }

    // MARK: Codex

    /// Rollouts Codex compressed (`rollout-*.jsonl.zst`): not read, their tokens and limits are missing.
    func codexCompressed() -> Int {
        ["sessions", "archived_sessions"].reduce(0) { n, d in
            n + Self.files(o.codexDir + "/" + d, depth: 4) { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl.zst") }.count
        }
    }

    /// The newest rollout under `sessions/YYYY/MM/DD` (by name: they start with their time).
    func newestRollout() -> String? {
        func walk(_ dir: String, _ depth: Int) -> String? {
            for e in Sys.listDir(dir).reversed() {
                let p = dir + "/" + e
                if depth == 0 { if e.hasPrefix("rollout-") && e.hasSuffix(".jsonl") { return p } }
                else if Sys.isDir(p), let f = walk(p, depth - 1) { return f }
            }
            return nil
        }
        return walk(o.codexDir + "/sessions", 3)
    }

    /// Time of the last Codex hook event in the spool (newest day file first).
    func lastCodexHook() -> Double? {
        for f in Sys.listDir(o.paths.spool).filter({ $0.hasSuffix(".ndjson") }).reversed() {
            guard let b = Sys.readFile(o.paths.spool + "/" + f) else { continue }
            for l in b.split(separator: 0x0A).reversed() where Self.has(l, "\"kind\":\"hook\",\"tool\":\"codex\"") {
                if let ts = JValue.parse(Array(l))?["ts"]?.double { return ts }
            }
        }
        return nil
    }

    /// Codex's hooks fire separately from Claude's: a Codex session started since they were installed and none of them
    /// came means they are not trusted (Codex asks once, in `/hooks`) or not run.
    func codexHooksCheck(_ add: (String, String) -> Void) {
        let hook = lastCodexHook()
        let installed = Sys.mtime(codexHooks) ?? .infinity
        let started = newestRollout().flatMap { Self.firstLine($0) }.flatMap { l -> Double? in
            let v = JValue.parse(l)
            return (v?["timestamp"]?.string ?? v?["payload"]?["timestamp"]?.string).flatMap { Time.parseISO($0) }
        }
        if let s = started, s > installed, (hook ?? 0) < s - 60 {
            add("warn", "codex: a session started \(Self.ago(o.now - s)) but no Codex hook event came since"
                + " (last: \(hook.map { Self.ago(o.now - $0) } ?? "never")): open /hooks in Codex once and trust Zagon's hooks;"
                + " Codex statuses come from them")
        } else {
            add("info", "codex: " + (hook.map { "last hook event \(Self.ago(o.now - $0))" }
                ?? "no hook event yet (no Codex session since the hooks were installed)"))
        }
        let zst = codexCompressed()
        if zst > 0 {
            // Read once the Codex source takes them.
            if CodexSource.isRollout("rollout-x.jsonl.zst") { add("info", "codex: \(zst) compressed rollout(s) (.jsonl.zst), read") }
            else { add("warn", "codex: \(zst) compressed rollout(s) (rollout-*.jsonl.zst) are not read yet: the tokens and limits in them are missing") }
        }
    }

    // MARK: versions

    /// The versions of Claude Code and Codex that wrote the newest logs, against the tested ones: a newer major or
    /// minor version is a warning (formats change there), a newer patch version a fact.
    func versionChecks(_ add: (String, String) -> Void) {
        func line(_ tool: String, _ v: String?, _ tested: String, _ from: String) {
            guard let v else { return }
            let newer = Self.newer(v, than: tested, parts: 2)
            add(newer ? "warn" : "info", "\(tool) \(v) (\(from)), tested up to \(tested)"
                + (newer ? ": if sessions, tokens or limits look wrong, report it with this output" : ""))
        }
        if o.claude { line("claude code", claudeVersion(), Self.testedClaude, "newest transcript") }
        if o.codex {
            let v = newestRollout().flatMap { Self.firstLine($0) }.flatMap { JValue.parse($0)?["payload"]?["cli_version"]?.string }
            line("codex", v, Self.testedCodex, "newest rollout")
        }
    }

    /// `version` of the newest records of the newest main transcript (`projects/<project>/<session>.jsonl`).
    func claudeVersion() -> String? {
        let root = o.claudeDir + "/projects"
        var best: (path: String, t: Double)?
        for d in Sys.listDir(root) {
            for f in Sys.listDir(root + "/" + d) where f.hasSuffix(".jsonl") {
                let p = root + "/" + d + "/" + f
                if let t = Sys.mtime(p), t > best?.t ?? -1 { best = (p, t) }
            }
        }
        guard let p = best?.path, let size = Sys.fileSize(p), let b = Sys.readFile(p, from: max(0, size - (256 << 10))) else { return nil }
        for l in b.split(separator: 0x0A).reversed() {
            if let v = JValue.topLevelStrings(Array(l), keys: ["version"])?["version"], v.first?.isNumber == true { return v }
        }
        return nil
    }

    /// Whether dotted version `a` is newer than `b` in its first `parts` numbers.
    static func newer(_ a: String, than b: String, parts: Int) -> Bool {
        func n(_ s: String) -> [Int] { s.split(separator: ".").prefix(parts).map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        return n(b).lexicographicallyPrecedes(n(a))
    }

    // MARK: files

    /// The first line of a file (read whole: a rollout's first line, `session_meta`, can be long).
    static func firstLine(_ path: String) -> [UInt8]? {
        Sys.readFile(path).map { b in Array(b.prefix { $0 != 0x0A }) }
    }

    static func has(_ l: ArraySlice<UInt8>, _ s: StaticString) -> Bool { l.withUnsafeBytes { contains($0, s) } }

    /// Names under `dir` (down to `depth` levels) that `match`.
    static func files(_ dir: String, depth: Int, _ match: (String) -> Bool) -> [String] {
        Sys.listDir(dir).flatMap { e -> [String] in
            let p = dir + "/" + e
            if match(e) { return [p] }
            return depth > 0 && Sys.isDir(p) ? files(p, depth: depth - 1, match) : []
        }
    }
}
