#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `zagon claude-wrap <claude> <args…>`, run by the script `zagon install` writes for the editor setting
/// `claudeCode.claudeProcessWrapper`. The Claude Code extension of VS Code and its forks runs its bundled `claude`
/// headless, where the status line never runs; with the setting it runs `<wrapper> <bundled claude> <args>` instead.
/// A stream-json run (the panel's chat) becomes a child whose stdout is copied byte for byte, and each
/// `rate_limit_event` line in it is spooled as a status-line reading. Anything else (auth status, model lists…) is
/// exec'd untouched, and so is everything when something fails here: the panel must get its Claude in any case.
public enum ClaudeWrap {
    /// How a stream line with a rate-limit event starts: the CLI writes SDK messages with `type` first.
    static let marker = Array(#"{"type":"rate_limit_event""#.utf8)
    /// Longer lines are never one and are not kept.
    static let maxLine = 1 << 16

    public static func run(_ args: [String], paths: ZagonPaths = ZagonPaths()) -> Never {
        if args == ["--probe"] { exit(0) }  // the script asks first: a zagon from before claude-wrap would fail every call
        var argv = args
        if argv.first.map({ $0.hasPrefix("-") }) ?? true {  // the extension found no bundled binary for this platform
            guard let claude = Sys.which("claude") else { fail("no claude to run") }
            argv.insert(claude, at: 0)
        }
        if isStream(argv) && !HookSpool.isInternal {
            mark(runMark, paths: paths, ts: Sys.now())
            if let rc = stream(argv, paths: paths) { exit(rc) }
        }
        let cargs = argv.map { strdup($0) } + [nil]
        execv(argv[0], cargs)
        fail("cannot run \(argv[0]) (errno \(errno))")
    }

    /// What Zagon.app's "Check the panel" reads: `spool/.panel-run` is rewritten each time the panel starts a chat
    /// through Zagon, `spool/.panel-reading` each time a limits reading from it is spooled.
    static let runMark = ".panel-run", readingMark = ".panel-reading"

    static func mark(_ name: String, paths: ZagonPaths, ts: Double) {
        Sys.mkdirs(paths.spool)
        _ = Sys.writeFile(paths.spool + "/" + name, Array(HookSpool.fmt(ts).utf8), mode: 0o600)
    }

    /// When the panel last started Claude through Zagon, and last gave a limits reading; nil = not seen.
    public static func panelSeen(paths: ZagonPaths = ZagonPaths()) -> (run: Double?, reading: Double?) {
        (Sys.mtime(paths.spool + "/" + runMark), Sys.mtime(paths.spool + "/" + readingMark))
    }

    static func fail(_ s: String) -> Never {
        Sys.writeAll(fd: 2, Array("zagon claude-wrap: \(s)\n".utf8))
        exit(127)
    }

    static func isStream(_ argv: [String]) -> Bool {
        argv.indices.contains { i in
            argv[i] == "--output-format=stream-json"
                || argv[i] == "--output-format" && i + 1 < argv.count && argv[i + 1] == "stream-json"
        }
    }

    /// Status-line input (`rate_limits.<window>.used_percentage`, `resets_at`, `session_id`) for a stream line, nil
    /// unless it is a rate-limit event with a window. The stream gives the share used (0–1); the status line shows
    /// it as Claude Code rounds it there: one decimal, at most 100.
    static func statusInput(_ line: [UInt8]) -> [UInt8]? {
        guard let v = JValue.parse(line), v["type"]?.string == "rate_limit_event",
              let w = v["rate_limit_info"]?["unifiedWindows"] else { return nil }
        var rl: [JValue.Member] = []
        for k in ["five_hour", "seven_day"] {
            guard case .number(let u)? = w[k]?["utilization"], let f = Double(u), f.isFinite else { continue }
            var m: [JValue.Member] = [.init("used_percentage", .number("\(min(max((f * 1000).rounded() / 10, 0), 100))"))]
            if case .number(let r)? = w[k]?["resetsAt"] { m.append(.init("resets_at", .number(r))) }
            rl.append(.init(k, .object(m)))
        }
        guard !rl.isEmpty else { return nil }
        var doc: [JValue.Member] = [.init("rate_limits", .object(rl))]
        if let sid = v["session_id"]?.string { doc.append(.init("session_id", .string(sid))) }
        return Array(JValue.object(doc).compact.utf8)
    }

    static func record(_ line: [UInt8], paths: ZagonPaths) {
        guard let input = statusInput(line) else { return }
        let ts = Sys.now()
        if let l = StatusLine.limitsLine(input, ts: ts), StatusLine.shouldSpool(input, ts: ts, paths: paths) {
            HookSpool.append(l.line, paths: paths, ts: ts)
            mark(readingMark, paths: paths, ts: ts)
        }
    }

    /// The running child, read by the signal handlers; 0 once it is reaped (its pid may be reused then).
    nonisolated(unsafe) static var child: pid_t = 0

    /// Runs `argv` with its stdout through a pipe; returns its exit status (128+n on a signal, after this process got
    /// the same signal). nil when it could not start: the caller execs instead.
    static func stream(_ argv: [String], paths: ZagonPaths) -> Int32? {
        var p: [Int32] = [-1, -1]
        guard Sys.pipeCloexec(&p) else { return nil }
        #if canImport(Darwin)
        var fa: posix_spawn_file_actions_t?
        #else
        var fa = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, p[1], 1)
        let cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid = pid_t()
        guard posix_spawn(&pid, argv[0], &fa, nil, cargs, environ) == 0 else { close(p[0]); close(p[1]); return nil }
        close(p[1])
        // Partial writes are retried; a non-blocking stdout would turn a slow editor into a stopped Claude.
        _ = fcntl(1, F_SETFL, fcntl(1, F_GETFL) & ~O_NONBLOCK)
        // The editor stops Claude with SIGTERM: pass it on and die of what the child dies of.
        // ponytail: a SIGKILL (the editor's after 5 s) or a SIGTERM before this point cannot be passed on: a Claude
        // that hangs then is left running. Exec Claude and copy from a helper process if that ever shows up.
        child = pid
        for s in [SIGTERM, SIGINT, SIGHUP] {
            signal(s) { if ClaudeWrap.child > 0 { kill(ClaudeWrap.child, $0) } else { _exit(128 + $0) } }
        }
        signal(SIGPIPE, SIG_IGN)
        // A parent may have started us with signals blocked; the child keeps the mask it would have had.
        var none = sigset_t()
        sigprocmask(SIG_SETMASK, &none, nil)

        var buf = [UInt8](repeating: 0, count: 65536), line: [UInt8] = [], skip = false
        var status: Int32 = 0, exited = false
        while true {
            // After the child exits, only what is already in the pipe is read: a process it left behind may hold the
            // pipe open for a long time.
            var pf = pollfd(fd: p[0], events: Int16(POLLIN), revents: 0)
            let r = poll(&pf, 1, exited ? 0 : 500)
            if r < 0 && errno == EINTR { continue }
            if r == 0 && !exited {
                let w = waitpid(pid, &status, WNOHANG)
                exited = w == pid || (w < 0 && errno == ECHILD)
                if exited { child = 0 }
                continue
            }
            if r <= 0 { break }
            let n = buf.withUnsafeMutableBytes { read(p[0], $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            // The editor stopped reading: the pipe is closed below, so Claude's next write fails as it would without us.
            if !Sys.writeAll(fd: 1, Array(buf[..<n])) { break }
            for b in buf[..<n] {
                if b == 0x0A {
                    if !skip && line.count > marker.count { record(line, paths: paths) }
                    line.removeAll(keepingCapacity: true); skip = false
                } else if !skip {
                    if line.count < marker.count ? b != marker[line.count] : line.count >= maxLine {
                        skip = true; line.removeAll(keepingCapacity: true)
                    } else { line.append(b) }
                }
            }
        }
        close(p[0])
        if !exited { while waitpid(pid, &status, 0) < 0 && errno == EINTR {}; child = 0 }
        let sig = status & 0x7f
        guard sig != 0 else { return (status >> 8) & 0xff }
        // A crash of Claude (SIGSEGV, SIGABRT…) is not re-raised: its crash report would name zagon.
        if [SIGTERM, SIGINT, SIGHUP, SIGKILL, SIGPIPE].contains(sig) {
            signal(sig, SIG_DFL)
            raise(sig)
        }
        return 128 + sig
    }
}
