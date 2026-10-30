#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Child processes without a shell (git, curl). stdin is written in full first, so it must be small
/// (a curl config, a JSON body); stdout is collected, stderr is inherited.
/// ponytail: overlaps `Sys.run` (Hooks/Sys.swift), which does not capture stdout; fold into one when it gains capture.
enum Exec {
    struct Result { var status: Int32; var out: [UInt8] }

    /// `argv[0]` is looked up in PATH. nil if it could not start. `quiet` sends stderr to /dev/null.
    static func run(_ argv: [String], stdin input: [UInt8] = [], quiet: Bool = false) -> Result? {
        guard !argv.isEmpty else { return nil }
        signal(SIGPIPE, SIG_IGN)
        var inp: [Int32] = [-1, -1], outp: [Int32] = [-1, -1]
        guard Sys.pipeCloexec(&inp) else { return nil }
        guard Sys.pipeCloexec(&outp) else { close(inp[0]); close(inp[1]); return nil }
        #if canImport(Darwin)
        var fa: posix_spawn_file_actions_t?
        #else
        var fa = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, inp[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outp[1], 1)
        for fd in inp + outp { posix_spawn_file_actions_addclose(&fa, fd) }
        if quiet { posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0) }
        let cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid = pid_t()
        let rc = posix_spawnp(&pid, argv[0], &fa, nil, cargs, environ)
        close(inp[0]); close(outp[1])
        if rc == 0 {
            var off = 0
            input.withUnsafeBytes { b in
                while off < b.count {
                    let n = write(inp[1], b.baseAddress! + off, b.count - off)
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
                }
            }
        }
        close(inp[1])
        var out: [UInt8] = []
        if rc == 0 {
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = buf.withUnsafeMutableBytes { read(outp[0], $0.baseAddress, $0.count) }
                if n > 0 { out.append(contentsOf: buf[0..<n]) } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
        close(outp[0])
        guard rc == 0 else { return nil }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let sig = status & 0x7f
        return Result(status: sig == 0 ? (status >> 8) & 0xff : 128 + sig, out: out)
    }
}

extension StringProtocol {
    func trimmed(_ set: String) -> String {
        let s = Substring(self)
        let a = s.drop { set.contains($0) }
        return String(a.reversed().drop { set.contains($0) }.reversed())
    }
}
