/// The project a request or working interval counts for, from its directory. A session counts every directory inside
/// the folder it started in for its own project (`cd src` stays in it). Any other directory, and every directory of a
/// session started in the home directory or `/`, counts for the top of its git checkout (a worktree: its main
/// checkout), else its last component. That needs the directory on disk, so Ingest resolves each directory once, on the
/// machine that recorded it, into `dir_project` (exported: the Mac app counts a server's sessions the same way).
public enum Projects {
    public struct Dir: Sendable, Equatable {
        public var project: String
        /// The home directory or `/`: a session started here takes no directory as its own.
        public var home: Bool
    }

    /// `cwd` as it is on this machine now; `home` = this user's home directory (also as its real path: transcripts
    /// carry physical paths). A gone directory: its last component.
    static func resolve(_ cwd: String, home: String) -> Dir {
        let homes = Set([home, Sys.realPath(home) ?? home].map(trimmed).filter { !$0.isEmpty })
        let c = trimmed(cwd)
        let dir = Dir(project: ClaudeParser.project(cwd), home: c == "/" || homes.contains(c))
        #if os(macOS)
        if guarded(c, homes: homes) { return dir }
        #endif
        guard c.hasPrefix("/"), Sys.isDir(c) else { return dir }
        var d = c
        while d != "/", d != ".", !homes.contains(d) {  // a git checkout at home (dotfiles) is no project
            let git = d + "/.git"
            if Sys.isDir(git) { return Dir(project: Sys.basename(d), home: dir.home) }
            if let b = Sys.readFile(git), case let s = String(decoding: b, as: UTF8.self), s.hasPrefix("gitdir:") {
                let gitdir = absolute(String(s.dropFirst(7)), in: d)
                #if os(macOS)
                if guarded(gitdir, homes: homes) { return Dir(project: Sys.basename(d), home: dir.home) }
                #endif
                guard let cb = Sys.readFile(gitdir + "/commondir") else {  // a submodule: a checkout of its own
                    return Dir(project: Sys.basename(d), home: dir.home)
                }
                // A worktree: `commondir` leads to the main checkout's .git (or a bare repository).
                let common = absolute(String(decoding: cb, as: UTF8.self), in: gitdir)
                let name = Sys.basename(common)
                return Dir(project: name == ".git" ? Sys.basename(Sys.dirname(common))
                                    : name.hasSuffix(".git") ? String(name.dropLast(4)) : name, home: dir.home)
            }
            d = Sys.dirname(d)
        }
        return dir
    }

    /// Folders macOS guards with a consent prompt (Desktop, Documents, Downloads, iCloud and cloud drives, removable and
    /// network volumes): looking for `.git` in them would ask the user for access, so they count by name only.
    static func guarded(_ c: String, homes: Set<String>) -> Bool {
        let roots = homes.flatMap { h in
            ["/Desktop", "/Documents", "/Downloads", "/Library/Mobile Documents", "/Library/CloudStorage"].map { h + $0 }
        } + ["/Volumes", "/Network"]
        return roots.contains { c == $0 || c.hasPrefix($0 + "/") }
    }

    /// Every directory Ingest has resolved (`dir_project`, this machine's and imported ones), by host, then directory.
    static func load(_ db: SQLite) throws -> [String: [String: Dir]] {
        var out: [String: [String: Dir]] = [:]
        try db.query("SELECT host, cwd, project, home FROM dir_project") { r in
            if let h = r.text(0), let c = r.text(1) { out[h, default: [:]][c] = Dir(project: r.text(2) ?? "", home: r.int(3) != 0) }
        }
        return out
    }

    /// `cwd` nil or "" (not known) = the session's project. `host`: the session's (directories are per machine).
    static func of(_ cwd: String?, session: String, started: String?, host: String?, dirs: [String: [String: Dir]]) -> String {
        guard let cwd, !cwd.isEmpty else { return session }
        let known = dirs[host ?? ""] ?? [:]
        if let s = started, !s.isEmpty, !(known[s]?.home ?? (s == "/")) {
            if cwd == s || cwd.hasPrefix(s.hasSuffix("/") ? s : s + "/") { return session }
        }
        return known[cwd]?.project ?? ClaudeParser.project(cwd)
    }

    static func trimmed(_ p: String) -> String {
        var p = Substring(p)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return String(p)
    }

    /// `p` (whitespace around it dropped) made absolute against `base`, with `.` and `..` resolved.
    static func absolute(_ p: String, in base: String) -> String {
        let t = p.drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        let s = String(t.reversed().drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }.reversed())
        var parts: [Substring] = []
        for x in ((s.hasPrefix("/") ? "" : base + "/") + s).split(separator: "/") {
            if x == "." { continue }
            if x == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(x)
        }
        return "/" + parts.joined(separator: "/")
    }
}
