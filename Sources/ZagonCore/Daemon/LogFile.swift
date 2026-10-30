#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The daemon's own log, `~/.zagon/logs/daemon.log`: lines `<UTC time> <text>`, rotated by size into `.1` … `.<keep-1>`
/// (default 3 files of at most 5 MB). Only counts, ids, paths and error reasons go here, never conversation text.
/// Safe to call from several threads. Lines are copied to stderr when it is a terminal.
public final class LogFile: @unchecked Sendable {
    public let path: String
    let maxBytes: Int, keep: Int
    let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    var size: Int
    let tty = isatty(2) == 1

    public init(path: String, maxBytes: Int = 5 << 20, keep: Int = 3) {
        self.path = path; self.maxBytes = maxBytes; self.keep = keep
        pthread_mutex_init(lock, nil)
        Sys.mkdirs(Sys.dirname(path))
        size = Sys.fileSize(path) ?? 0
    }

    public func write(_ text: String) {
        let line = Array("\(LogFile.iso(Sys.now())) \(text)\n".utf8)
        pthread_mutex_lock(lock); defer { pthread_mutex_unlock(lock) }
        if size > 0, size + line.count > maxBytes { rotate() }
        if Sys.append(path, line) { size += line.count }
        if tty { _ = Sys.writeAll(fd: 2, line) }
    }

    /// daemon.log → .1 → .2 …; the oldest is overwritten by the rename.
    func rotate() {
        for i in stride(from: keep - 1, to: 0, by: -1) {
            let from = i == 1 ? path : "\(path).\(i - 1)"
            if Sys.exists(from) { rename(from, "\(path).\(i)") }
        }
        size = 0
    }

    /// `2026-10-30T11:04:05Z`.
    public static func iso(_ t: Double) -> String {
        var s = time_t(t), tmv = tm()
        gmtime_r(&s, &tmv)
        func p2(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(tmv.tm_year + 1900)-\(p2(tmv.tm_mon + 1))-\(p2(tmv.tm_mday))T\(p2(tmv.tm_hour)):\(p2(tmv.tm_min)):\(p2(tmv.tm_sec))Z"
    }

    /// The last `n` lines of the log (reads at most the last 256 KB).
    public static func tail(_ path: String, lines n: Int) -> [String] {
        guard let size = Sys.fileSize(path), let b = Sys.readFile(path, from: max(0, size - (256 << 10))) else { return [] }
        let all = String(decoding: b, as: UTF8.self).split(separator: "\n").map(String.init)
        return Array(all.suffix(n))
    }
}
