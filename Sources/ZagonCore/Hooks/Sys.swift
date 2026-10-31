#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// libc-only file and process helpers for the hook / status-line / install paths (no Foundation: fast cold start).
/// Every function reports failure by return value and never traps.
public enum Sys {
    public static func env(_ key: String) -> String? { getenv(key).map { String(cString: $0) } }

    public static func now() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    /// `yyyy-mm-dd` of `t` in UTC.
    public static func utcDay(_ t: Double) -> String {
        var s = time_t(t), tmv = tm()
        gmtime_r(&s, &tmv)
        func p2(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(tmv.tm_year + 1900)-\(p2(tmv.tm_mon + 1))-\(p2(tmv.tm_mday))"
    }

    /// `yyyymmdd-HHMMSS` in UTC, for backup directory names.
    public static func stamp(_ t: Double) -> String {
        var s = time_t(t), tmv = tm()
        gmtime_r(&s, &tmv)
        func p2(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(tmv.tm_year + 1900)\(p2(tmv.tm_mon + 1))\(p2(tmv.tm_mday))-\(p2(tmv.tm_hour))\(p2(tmv.tm_min))\(p2(tmv.tm_sec))"
    }

    // MARK: files

    public static func readAll(fd: Int32, limit: Int = 64 << 20) -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        while out.count < limit {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    public static func readFile(_ path: String) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return readAll(fd: fd, limit: .max)
    }

    /// Bytes of `path` from `offset` to the end.
    public static func readFile(_ path: String, from offset: Int) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else { return nil }
        return readAll(fd: fd, limit: .max)
    }

    @discardableResult
    public static func writeAll(fd: Int32, _ b: [UInt8]) -> Bool {
        var done = 0
        while done < b.count {
            let n = b.withUnsafeBytes { write(fd, $0.baseAddress! + done, b.count - done) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            done += n
        }
        return true
    }

    /// One `write(2)` with O_APPEND (atomic for short lines on local filesystems). Creates the file 0600.
    @discardableResult
    public static func append(_ path: String, _ b: [UInt8]) -> Bool {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return writeAll(fd: fd, b)
    }

    /// Atomic replace: write `path.zagon-tmp`, fsync, rename. Follows a symlink at `path` (writes its target) and
    /// keeps the old file mode; the temporary file itself is never opened through a symlink (`createExclusive`).
    @discardableResult
    public static func writeFile(_ path: String, _ b: [UInt8], mode: mode_t = 0o644) -> Bool {
        let target = realPath(path) ?? path
        var st = stat()
        let m = stat(target, &st) == 0 ? st.st_mode & 0o7777 : mode
        let tmp = target + ".zagon-tmp"
        let fd = createExclusive(tmp)
        guard fd >= 0 else { return false }
        let ok = writeAll(fd: fd, b) && fchmod(fd, m) == 0 && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp, target) == 0 else { unlink(tmp); return false }
        return true
    }

    /// Creates `path` (mode 0600) for writing with O_EXCL | O_NOFOLLOW, so a symlink or someone else's file planted at
    /// that name is never written through. A leftover regular file of this user (an interrupted earlier write) is
    /// removed first; anything else there is an error. Returns the fd or -1.
    public static func createExclusive(_ path: String) -> Int32 {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let fd = open(path, flags, 0o600)
        guard fd < 0, errno == EEXIST else { return fd }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), unlink(path) == 0 else { return -1 }
        return open(path, flags, 0o600)
    }

    public static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    public static func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }

    public static func isDir(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func fileSize(_ path: String) -> Int? {
        var st = stat()
        return stat(path, &st) == 0 ? Int(st.st_size) : nil
    }

    public static func mtime(_ path: String) -> Double? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        #if canImport(Darwin)
        return Double(st.st_mtimespec.tv_sec)
        #else
        return Double(st.st_mtim.tv_sec)
        #endif
    }

    /// `mkdir -p`; true if the directory exists afterwards.
    @discardableResult
    public static func mkdirs(_ path: String, mode: mode_t = 0o700) -> Bool {
        if isDir(path) { return true }
        let parent = dirname(path)
        if parent != path && !parent.isEmpty { mkdirs(parent, mode: mode) }
        return mkdir(path, mode) == 0 || isDir(path)
    }

    @discardableResult
    public static func remove(_ path: String) -> Bool { unlink(path) == 0 }

    public static func listDir(_ path: String) -> [String] {
        guard let d = opendir(path) else { return [] }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out.sorted()
    }

    public static func dirname(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "." }
        return i == path.startIndex ? "/" : String(path[..<i])
    }

    public static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    // MARK: processes

    /// The Claude Code / Codex process that started this one: the parent, or the shell's parent when the parent is a
    /// shell (Claude Code runs hook commands through `sh -c`, MCP servers directly). Hooks and `zagon mcp` of one
    /// session get the same pid. nil where /proc is missing.
    /// ponytail: Linux only; macOS would need sysctl(KERN_PROC_PID) for the shell's parent.
    public static func clientPid() -> Int32? {
        #if os(Linux)
        var p = getppid()
        for _ in 0..<3 {
            guard let comm = readFile("/proc/\(p)/comm").map({ String(decoding: $0.prefix { $0 != 0x0A }, as: UTF8.self) }),
                  ["sh", "bash", "dash", "zsh", "ksh", "fish"].contains(comm),
                  let stat = readFile("/proc/\(p)/stat").map({ String(decoding: $0, as: UTF8.self) }),
                  let close = stat.lastIndex(of: ")") else { break }
            // `pid (comm) state ppid …`; comm may hold spaces and parentheses, so split after the last ')'
            let fields = stat[stat.index(after: close)...].split(separator: " ")
            guard fields.count > 1, let pp = Int32(fields[1]), pp > 1 else { break }
            p = pp
        }
        return p
        #else
        return nil
        #endif
    }

    /// Absolute path of the running executable.
    public static func executablePath() -> String {
        #if os(Linux)
        if let p = realPath("/proc/self/exe") { return p }
        #endif
        let a0 = CommandLine.arguments.first ?? "zagon"
        if a0.contains("/") { return realPath(a0) ?? a0 }
        return which(a0) ?? a0
    }

    /// Looks `name` up in `path` (default `$PATH`).
    public static func which(_ name: String, path: String? = nil) -> String? {
        for dir in (path ?? env("PATH") ?? "/usr/bin:/bin").split(separator: ":") {
            let p = "\(dir)/\(name)"
            if access(p, X_OK) == 0 && !isDir(p) { return p }
        }
        return nil
    }

    /// pipe(2) with both ends close-on-exec: a child spawned meanwhile by another thread must not inherit them (it
    /// would hold a write end open, and a read here would not see EOF until that child exits). dup2 in our own child
    /// clears the flag on its fds 0 and 1.
    /// ponytail: pipe + fcntl leaves a tiny window; pipe2(O_CLOEXEC) needs a C shim (not visible from Glibc).
    public static func pipeCloexec(_ p: inout [Int32]) -> Bool {
        guard pipe(&p) == 0 else { return false }
        _ = fcntl(p[0], F_SETFD, FD_CLOEXEC); _ = fcntl(p[1], F_SETFD, FD_CLOEXEC)
        return true
    }

    /// Spawns `argv` (argv[0] must be a path), feeds `stdin` (if given) through a pipe and waits. stdout/stderr are
    /// inherited unless `quiet` (then /dev/null). Returns the exit status, 127 if it could not start, 128+n on signal.
    public static func run(_ argv: [String], stdin input: [UInt8]? = nil, quiet: Bool = false) -> Int32 {
        guard !argv.isEmpty else { return 127 }
        signal(SIGPIPE, SIG_IGN)
        var pfd: [Int32] = [-1, -1]
        if input != nil { guard pipeCloexec(&pfd) else { return 127 } }
        #if canImport(Darwin)
        var fa: posix_spawn_file_actions_t?
        #else
        var fa = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        if input != nil {
            posix_spawn_file_actions_adddup2(&fa, pfd[0], 0)
            posix_spawn_file_actions_addclose(&fa, pfd[0])
            posix_spawn_file_actions_addclose(&fa, pfd[1])
        }
        if quiet {
            posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        }
        let cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid = pid_t()
        let rc = posix_spawn(&pid, argv[0], &fa, nil, cargs, environ)
        if let input {
            close(pfd[0])
            if rc == 0 { writeAll(fd: pfd[1], input) }
            close(pfd[1])
        }
        guard rc == 0 else { return 127 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let sig = status & 0x7f
        return sig == 0 ? (status >> 8) & 0xff : 128 + sig
    }

    /// How much of a command's stderr `capture` keeps: its end, where errors are.
    public static let maxErr = 4096

    /// Spawns `argv` (argv[0] must be a path) in its own process group, writes `stdin`, collects stdout and the last
    /// `maxErr` bytes of stderr. The whole group is killed after `timeout` seconds (status 124). `cwd` runs it in that
    /// directory; `env` is added to (or replaces entries of) this process's environment.
    // ponytail: stdin is written in full before stdout is read; fine for inputs under the 64 KB pipe buffer
    // (curl configs, prompts), interleave the two if a caller ever passes more.
    public static func capture(_ argv: [String], stdin input: [UInt8] = [], cwd: String? = nil,
                               timeout: Double = 60, env: [String: String] = [:]) -> (status: Int32, out: [UInt8], err: [UInt8]) {
        guard !argv.isEmpty else { return (127, [], []) }
        signal(SIGPIPE, SIG_IGN)
        let args = cwd.map { ["/bin/sh", "-c", "cd \"$0\" && exec \"$@\"", $0] + argv } ?? argv
        var inP: [Int32] = [-1, -1], outP: [Int32] = [-1, -1]
        guard pipeCloexec(&inP) else { return (127, [], []) }
        guard pipeCloexec(&outP) else { close(inP[0]); close(inP[1]); return (127, [], []) }
        // stderr goes to a file deleted at once (read back after the exit): unlike a pipe it never blocks the child,
        // and a process left behind holding it open does not keep this waiting. /dev/null when none can be made.
        var name = Array(((Sys.env("TMPDIR") ?? "/tmp") + "/zagon-err-XXXXXX").utf8CString)
        let errFd = mkstemp(&name)
        if errFd >= 0 { unlink(name); _ = fcntl(errFd, F_SETFD, FD_CLOEXEC) }
        defer { if errFd >= 0 { close(errFd) } }
        #if canImport(Darwin)
        var fa: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        #else
        var fa = posix_spawn_file_actions_t(), attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&fa)
        posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        if errFd >= 0 { posix_spawn_file_actions_adddup2(&fa, errFd, 2) } else { posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0) }
        for fd in inP + outP { posix_spawn_file_actions_addclose(&fa, fd) }
        let cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = []
        var i = 0
        while let e = environ[i] {
            let s = String(cString: e)
            if !env.keys.contains(where: { s.hasPrefix($0 + "=") }) { envp.append(strdup(e)) }
            i += 1
        }
        envp += env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid = pid_t()
        let rc = posix_spawn(&pid, args[0], &fa, &attr, cargs, envp)
        close(inP[0]); close(outP[1])
        if rc == 0 { writeAll(fd: inP[1], input) }
        close(inP[1])
        guard rc == 0 else { close(outP[0]); return (127, [], []) }
        var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536), timedOut = false
        let deadline = now() + timeout
        while true {
            let left = deadline - now()
            if left <= 0 { timedOut = true; kill(-pid, SIGKILL); break }
            var p = pollfd(fd: outP[0], events: Int16(POLLIN), revents: 0)
            let n = poll(&p, 1, Int32(min(left, 1) * 1000) + 1)
            if n < 0 && errno == EINTR { continue }
            if n == 0 { continue }
            let r = buf.withUnsafeMutableBytes { read(outP[0], $0.baseAddress, $0.count) }
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { break }
            out.append(contentsOf: buf[0..<r])
        }
        close(outP[0])
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        var err = [UInt8](repeating: 0, count: maxErr)
        let size = errFd >= 0 ? Int(lseek(errFd, 0, SEEK_END)) : 0
        let n = size > 0 ? err.withUnsafeMutableBytes { pread(errFd, $0.baseAddress, maxErr, off_t(max(0, size - maxErr))) } : 0
        err.removeSubrange(max(0, n)...)
        if timedOut { return (124, out, err) }
        let sig = status & 0x7f
        return (sig == 0 ? (status >> 8) & 0xff : 128 + sig, out, err)
    }

    /// Single-quotes `s` for a POSIX shell when needed.
    public static func shellQuote(_ s: String) -> String {
        let safe = s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || "/._-+:@%=,".utf8.contains(c)
        }
        return safe && !s.isEmpty ? s : "'" + s.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "'\\''") + "'"
    }
}

