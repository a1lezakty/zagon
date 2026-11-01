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

    // MARK: service

    #if os(Linux)
    /// Each unit file there and whether systemd runs it (`is-active`): ok when at least one runs (a user unit `install`
    /// wrote next to the system unit stays stopped).
    /// A fresh health line (`alive`) counts as running too: a daemon outside systemd (tmux, a container), or a user
    /// manager this shell cannot ask (`--machine` before systemd 248, no user bus).
    func serviceCheck(alive: Bool, _ add: (Bool, String) -> Void) {
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
        add(running || alive, "service: " + parts.joined(separator: "; ")
            + (running ? "" : alive ? "; but a daemon runs (fresh health line)" : "; start it: " + start))
    }

    /// Seconds a health line may be old: 15 minutes, or 1.5 intervals of a unit's `--health-minutes`.
    var healthMaxAge: Double {
        let every = [userUnit, systemUnit].compactMap { Sys.readFile($0).map { String(decoding: $0, as: UTF8.self) } }.compactMap { t -> Double? in
            guard let r = t.split(separator: "\n").first(where: { $0.hasPrefix("ExecStart=") })?.split(separator: " ")
                .split(whereSeparator: { $0 == "--health-minutes" }).dropFirst().first?.first else { return nil }
            return Double(r)
        }.max()
        return max(900, (every ?? 0) * 90)
    }

    /// The daemon's last `health:` / `start:` / `full pass` line is at most `healthMaxAge` old; returns whether it is.
    func healthCheck(_ log: [String], _ add: (Bool, String) -> Void) -> Bool {
        let path = o.paths.dir + "/logs/daemon.log"
        guard let l = log.last(where: { $0.contains(" health: ") || $0.contains(" start: ") || $0.contains(" full pass (") }),
              let t = Self.logTime(l) else {
            add(false, "daemon: no health line in \(path): it has not run here")
            return false
        }
        let age = o.now - t, fresh = age <= healthMaxAge
        add(fresh, "daemon: " + (fresh ? "last health line \(Self.ago(age))"
            : "no health line for \(Self.ago(age).dropLast(4)) (one every 10 min while it runs): stopped or stuck, see \(path)"))
        return fresh
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

    /// The first line (`session_meta`) of the newest rollout.
    func newestRolloutMeta() -> JValue? { newestRollout().flatMap(Self.firstLine).flatMap { JValue.parse($0) } }

    /// Codex's hooks fire separately from Claude's: a Codex session started since they were installed and none of them
    /// came means they are not trusted (Codex asks once, in `/hooks`) or not run.
    func codexHooksCheck(_ meta: JValue?, _ add: (String, String) -> Void) {
        let hook = lastCodexHook()
        let installed = Sys.mtime(codexHooks) ?? .infinity
        let started = (meta?["timestamp"]?.string ?? meta?["payload"]?["timestamp"]?.string).flatMap { Time.parseISO($0) }
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

    // MARK: Codex hook trust

    /// Codex runs a hook only once the user trusted it in `/hooks`: `[hooks.state."<hooks.json>:<event>:<group>:<hook>"]
    /// trusted_hash` in config.toml, the sha256 of the entry as it was then (`trustInput`), so a changed entry (another
    /// zagon path) is skipped until trusted again. Our entries that have no trust (`untrusted`) or whose trust is for
    /// another text (`changed`, only checked with sha256sum or shasum on PATH); nil without our entries.
    func codexTrust() -> (untrusted: [String], changed: [String], all: Int)? {
        guard let b = Sys.readFile(codexHooks), let doc = try? load(b) else { return nil }
        let cfg = Sys.readFile(codexConfig).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let files = [codexHooks] + (Sys.realPath(codexHooks).map { $0 == codexHooks ? [] : [$0] } ?? [])
        var untrusted: [String] = [], changed: [String] = [], all = 0
        for e in Self.codexEvents {
            for (gi, g) in (doc["hooks"]?[e]?.array ?? []).enumerated() {
                for (hi, h) in (g["hooks"]?.array ?? []).enumerated() {
                    guard let c = h["command"]?.string, isOurs(c, "hook codex \(e)") else { continue }
                    all += 1
                    let key = ":\(Self.snake(e)):\(gi):\(hi)"
                    guard let have = files.lazy.compactMap({ TOMLLite.string(in: cfg, section: "hooks.state.\"\($0 + key)\"", key: "trusted_hash") }).first else {
                        untrusted.append(e); continue
                    }
                    // Without an explicit timeout Codex hashes its default: 600 s, 1 s for Interrupt and SessionEnd (0.166).
                    let timeouts = h["timeout"]?.double.map { [Int($0)] } ?? [600, 1]
                    let want = timeouts.compactMap { sha256(Self.trustInput(event: e, command: c, timeout: $0, matcher: g["matcher"]?.string)) }
                    if !want.isEmpty && !want.contains(where: { "sha256:" + $0 == have }) { changed.append(e) }
                }
            }
        }
        return all == 0 ? nil : (untrusted, changed, all)
    }

    /// The text Codex hashes for a hook's trust: the event and the matcher group in canonical JSON (keys sorted).
    static func trustInput(event: String, command: String, timeout: Int, matcher: String?) -> String {
        var s = "{\"event_name\":"
        JValue.quote(snake(event), into: &s)
        s += ",\"hooks\":[{\"async\":false,\"command\":"
        JValue.quote(command, into: &s)
        s += ",\"timeout\":\(timeout),\"type\":\"command\"}]"
        if let matcher { s += ",\"matcher\":"; JValue.quote(matcher, into: &s) }
        return s + "}"
    }

    /// `PermissionRequest` → `permission_request`.
    static func snake(_ s: String) -> String {
        s.enumerated().map { i, c in c.isUppercase ? (i > 0 ? "_" : "") + c.lowercased() : String(c) }.joined()
    }

    /// Lowercase hex sha256 through sha256sum (or shasum -a 256) on PATH; nil without either.
    func sha256(_ text: String) -> String? {
        guard let argv = Sys.which("sha256sum", path: o.searchPath).map({ [$0] })
                ?? Sys.which("shasum", path: o.searchPath).map({ [$0, "-a", "256"] }) else { return nil }
        let r = Sys.capture(argv, stdin: Array(text.utf8), timeout: 10)
        guard r.status == 0, let h = String(decoding: r.out, as: UTF8.self).split(separator: " ").first, h.count == 64 else { return nil }
        return String(h)
    }

    /// The warning about trust, nil when Codex runs all of our hooks.
    func codexTrustWarning() -> String? {
        guard let t = codexTrust(), !(t.untrusted.isEmpty && t.changed.isEmpty) else { return nil }
        let some = t.untrusted.count + t.changed.count < t.all ? " (" + (t.untrusted + t.changed).joined(separator: ", ") + ")" : ""
        return "codex: hooks " + (t.untrusted.isEmpty ? "changed since they were trusted, Codex skips them" : "not trusted yet")
            + some + ": open /hooks in codex, press t"
    }

    func codexTrustCheck(_ add: (String, String) -> Void) {
        if let w = codexTrustWarning() { add("warn", w) }
        else if let t = codexTrust() { add("info", "codex: hooks trusted in /hooks (\(t.all))") }
    }

    // MARK: versions

    /// The versions of Claude Code and Codex that wrote the newest logs, against the tested ones: a newer major or
    /// minor version is a warning (formats change there), a newer patch version a fact.
    func versionChecks(_ codexMeta: JValue?, _ add: (String, String) -> Void) {
        func line(_ tool: String, _ v: String?, _ tested: String, _ from: String) {
            guard let v else { return }
            let newer = Self.newer(v, than: tested, parts: 2)
            add(newer ? "warn" : "info", "\(tool) \(v) (\(from)), tested up to \(tested)"
                + (newer ? ": if sessions, tokens or limits look wrong, report it with this output" : ""))
        }
        if o.claude { line("claude code", claudeVersion(), Self.testedClaude, "newest transcript") }
        if o.codex {
            line("codex", codexMeta?["payload"]?["cli_version"]?.string, Self.testedCodex, "newest rollout")
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

    // MARK: archive

    /// How long the archive keeps copies: bounded for Claude Code by an organization's `cleanupPeriodDays`.
    func archiveCheck(_ add: (String, String) -> Void) {
        let dir = o.paths.dir + "/archive"
        if [userUnit, systemUnit].contains(where: { Sys.readFile($0).map { String(decoding: $0, as: UTF8.self).contains("--no-archive") } ?? false }) {
            add("info", "archive: off (--no-archive in the service unit)")
            return
        }
        let r = Archive.retention(managedDir: o.managedSettingsDir, remoteSettings: o.claudeDir + "/remote-settings.json")
        guard let days = r.days, let src = r.source else {
            add("info", "archive: \(dir) keeps copies of Claude Code transcripts and Codex rollouts with no time limit "
                + "(no cleanupPeriodDays in Claude Code's managed settings; zagon daemon --no-archive turns it off)")
            return
        }
        add("info", "archive: \(dir) keeps " + (days == 0 ? "no copies of Claude Code transcripts" : "copies of Claude Code transcripts for \(days) days")
            + " (cleanupPeriodDays \(days) in \(src)), of Codex rollouts with no time limit")
    }

    /// Copies of the database `zagon update` kept before schema changes: there until the user removes them.
    func snapshotsCheck(_ add: (String, String) -> Void) {
        let s = SchemaCheck.snapshots(dataDir: o.paths.dir)
        guard !s.isEmpty else { return }
        add("info", "database copies kept by updates, for a rollback: "
            + s.map { "\($0.name) (\(SchemaCheck.mb(UInt64($0.bytes))) MB, \(Time.dayString($0.mtime)))" }.joined(separator: ", ")
            + "; remove them when no longer needed")
    }

    // MARK: files

    /// The first line of a file, from its first 4 MB (a rollout's `session_meta` holds the instructions: tens of KB).
    static func firstLine(_ path: String) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return Array(Sys.readAll(fd: fd, limit: 4 << 20).prefix { $0 != 0x0A })
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
