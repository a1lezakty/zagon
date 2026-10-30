#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Recursive directory watch on inotify (no polling). Reports files that changed or appeared; for a directory that
/// appeared, every file already in it (it may have filled before its watch was added).
public final class DirWatcher {
    let fd: Int32
    var dirs: [Int32: String] = [:]
    var watched: Set<String> = []
    static let mask = UInt32(IN_MODIFY | IN_CLOSE_WRITE | IN_CREATE | IN_MOVED_TO | IN_MOVE_SELF)

    public init?() {
        fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        if fd < 0 { return nil }
    }
    deinit { close(fd) }

    public func isWatched(_ dir: String) -> Bool { watched.contains(dir) }

    /// Watches `dir` (and every directory below it if `recursive`; symlinked directories are not followed).
    /// Returns the regular files found, so the caller can catch up on them. Empty if `dir` is missing.
    @discardableResult
    public func add(_ dir: String, recursive: Bool = true) -> [String] {
        guard !watched.contains(dir) else { return [] }
        let wd = inotify_add_watch(fd, dir, Self.mask)
        guard wd >= 0 else { return [] }
        dirs[wd] = dir; watched.insert(dir)
        var files: [String] = []
        for name in Sys.listDir(dir) {
            let p = dir + "/" + name
            var sb = stat()
            guard lstat(p, &sb) == 0 else { continue }
            switch sb.st_mode & S_IFMT {
            case S_IFDIR: if recursive { files += add(p) }
            case S_IFREG: files.append(p)
            default: break
            }
        }
        return files
    }

    public struct Events {
        public var paths = Set<String>()
        /// Why events were lost (queue overflow, a watched directory moved): rescan everything.
        public var lost: String?
    }

    /// Waits up to `timeoutMs` for events and drains them.
    public func wait(timeoutMs: Int32) -> Events {
        var ev = Events()
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, timeoutMs) > 0 else { return ev }
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            var off = 0
            while off + 16 <= n {
                // struct inotify_event { int wd; uint32_t mask, cookie, len; char name[len]; }
                let (wd, mask, len) = buf.withUnsafeBytes { b in
                    (b.loadUnaligned(fromByteOffset: off, as: Int32.self), b.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self),
                     Int(b.loadUnaligned(fromByteOffset: off + 12, as: UInt32.self)))
                }
                let name = buf[(off + 16)..<min(n, off + 16 + len)].prefix { $0 != 0 }
                off += 16 + len
                if mask & UInt32(IN_Q_OVERFLOW) != 0 { ev.lost = "inotify queue overflow"; continue }
                if mask & UInt32(IN_IGNORED) != 0 {
                    if let d = dirs.removeValue(forKey: wd) { watched.remove(d) }
                    continue
                }
                guard let dir = dirs[wd] else { continue }
                if name.isEmpty {
                    // The watched directory itself moved: its path is stale.
                    if mask & UInt32(IN_MOVE_SELF) != 0 {
                        inotify_rm_watch(fd, wd); dirs[wd] = nil; watched.remove(dir); ev.lost = "watched directory moved: \(dir)"
                    }
                    continue
                }
                let path = dir + "/" + String(decoding: name, as: UTF8.self)
                if mask & UInt32(IN_ISDIR) != 0 {
                    if mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0 { ev.paths.formUnion(add(path)) }
                } else {
                    ev.paths.insert(path)
                }
            }
        }
        return ev
    }
}
#endif
