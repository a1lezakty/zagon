/// The project a request or working interval counts for, from its directory. A directory inside a git checkout counts
/// for its repository (the name in `remote.origin`, else the main checkout's), one outside any checkout under a
/// temporary folder for `(temp)`, any other for its last component. A session counts every directory inside the folder
/// it started in for that folder's project (`cd src` stays in it), unless it started in the home directory or `/`.
/// That needs the directory on disk, so Ingest resolves each directory once, on the machine that recorded it, into
/// `dir_project` (exported: the Mac app counts a server's sessions the same way).
public enum Projects {
    /// The project of every directory outside a git checkout under a temporary folder.
    public static let temp = "(temp)"

    public struct Dir: Sendable, Equatable {
        public var project: String
        /// The home directory or `/`: a session started here takes no directory as its own.
        public var home: Bool
    }

    /// `cwd` as it is on this machine now; `home` = this user's home directory (also as its real path: transcripts
    /// carry physical paths), `tmp` = `$TMPDIR`. A gone directory: its last component (or `temp`).
    static func resolve(_ cwd: String, home: String, tmp: String? = Sys.env("TMPDIR")) -> Dir {
        let homes = Self.homes(home)
        let c = trimmed(cwd)
        let dir = Dir(project: temporary(c, homes: homes, tmp: tmp) ? temp : ClaudeParser.project(cwd),
                      home: c == "/" || homes.contains(c))
        #if os(macOS)
        if guarded(c, homes: homes) { return dir }
        #endif
        guard c.hasPrefix("/"), Sys.isDir(c) else { return dir }
        var d = c
        while d != "/", d != ".", !homes.contains(d) {  // a git checkout at home (dotfiles) is no project
            let git = d + "/.git"
            if Sys.isDir(git) { return Dir(project: repo(git) ?? Sys.basename(d), home: dir.home) }
            if let b = Sys.readFile(git), case let s = String(decoding: b, as: UTF8.self), s.hasPrefix("gitdir:") {
                let gitdir = absolute(String(s.dropFirst(7)), in: d)
                #if os(macOS)
                if guarded(gitdir, homes: homes) { return Dir(project: Sys.basename(d), home: dir.home) }
                #endif
                guard let cb = Sys.readFile(gitdir + "/commondir") else {  // a submodule: a checkout of its own
                    return Dir(project: repo(gitdir) ?? Sys.basename(d), home: dir.home)
                }
                // A worktree: `commondir` leads to the main checkout's .git (or a bare repository).
                let common = absolute(String(decoding: cb, as: UTF8.self), in: gitdir)
                let name = Sys.basename(common)
                return Dir(project: repo(common) ?? (name == ".git" ? Sys.basename(Sys.dirname(common))
                                    : name.hasSuffix(".git") ? String(name.dropLast(4)) : name), home: dir.home)
            }
            d = Sys.dirname(d)
        }
        return dir
    }

    /// The repository's name from `url` of `[remote "origin"]` in `<git dir>/config`: its last path segment without
    /// `.git` (`https://host/me/zagon.git`, `git@host:me/zagon`); nil without one.
    static func repo(_ gitDir: String) -> String? {
        guard let b = Sys.readFile(gitDir + "/config") else { return nil }
        var origin = false
        for raw in String(decoding: b, as: UTF8.self).split(separator: "\n") {
            let line = strip(raw)
            if line.hasPrefix("[") { origin = line == "[remote \"origin\"]"; continue }
            let kv = line.split(separator: "=", maxSplits: 1)
            guard origin, kv.count == 2, strip(kv[0]) == "url" else { continue }
            var u = strip(kv[1])
            while u.hasSuffix("/") { u.removeLast() }
            if let i = u.lastIndex(where: { $0 == "/" || $0 == ":" }) { u = u[u.index(after: i)...] }
            if u.hasSuffix(".git") { u = u.dropLast(4) }
            return u.isEmpty ? nil : String(u)
        }
        return nil
    }

    /// Temporary folders: `/tmp`, `/var/tmp`, `$TMPDIR`, macOS `/var/folders` (also under `/private`), `~/.claude`.
    /// A home directory inside one (containers, tests) is not.
    static func temporary(_ c: String, homes: Set<String>, tmp: String?) -> Bool {
        func under(_ r: String) -> Bool { c == r || c.hasPrefix(r + "/") }
        if homes.contains(where: { under($0 + "/.claude") }) { return true }
        if homes.contains(where: under) { return false }
        let roots = ["/tmp", "/var/tmp", "/var/folders", "/private/tmp", "/private/var/folders"] + [tmp.map(trimmed) ?? ""]
        return roots.contains { $0.count > 1 && under($0) }
    }

    /// `home`, also as its real path.
    static func homes(_ home: String) -> Set<String> { Set([home, Sys.realPath(home) ?? home].map(trimmed).filter { !$0.isEmpty }) }

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

    /// `cwd` nil or "" (not known) = the session's own project: that of the folder it `started` in, else `session`.
    /// `host`: the session's (directories are per machine).
    static func of(_ cwd: String?, session: String, started: String?, host: String?, dirs: [String: [String: Dir]]) -> String {
        let known = dirs[host ?? ""] ?? [:]
        let own = started.flatMap { known[$0]?.project } ?? session
        guard let cwd, !cwd.isEmpty else { return own }
        if let s = started, !s.isEmpty, !(known[s]?.home ?? (s == "/")) {
            if cwd == s || cwd.hasPrefix(s.hasSuffix("/") ? s : s + "/") { return own }
        }
        return known[cwd]?.project ?? ClaudeParser.project(cwd)
    }

    /// SQL for the project a session is listed under, as `of` counts it: that of the folder it started in
    /// (`dir_project`), else `session.project`. `s` = the name or alias of the `session` table in the query.
    static func sessionSQL(_ s: String = "s") -> String {
        "coalesce((SELECT d.project FROM dir_project d WHERE d.host = \(s).host AND d.cwd = \(s).cwd), \(s).project)"
    }

    static func trimmed(_ p: String) -> String {
        var p = Substring(p)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return String(p)
    }

    static func strip<S: StringProtocol>(_ s: S) -> Substring {
        var x = Substring(s)
        while let f = x.first, f == " " || f == "\t" || f == "\r" || f == "\n" { x.removeFirst() }
        while let l = x.last, l == " " || l == "\t" || l == "\r" || l == "\n" { x.removeLast() }
        return x
    }

    /// `p` (whitespace around it dropped) made absolute against `base`, with `.` and `..` resolved.
    static func absolute(_ p: String, in base: String) -> String {
        let s = String(strip(p))
        var parts: [Substring] = []
        for x in ((s.hasPrefix("/") ? "" : base + "/") + s).split(separator: "/") {
            if x == "." { continue }
            if x == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(x)
        }
        return "/" + parts.joined(separator: "/")
    }
}
