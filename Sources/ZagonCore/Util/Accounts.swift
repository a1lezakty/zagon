/// Claude Code accounts on one machine. Each `CLAUDE_CONFIG_DIR` is an account with its own login, transcripts
/// (`<dir>/projects`) and subscription limits; `~/.claude` (no `CLAUDE_CONFIG_DIR`) is the default one.
///
/// Names: `[accounts]` in config.toml maps a folder to a name (`"/root/.claude-corp" = "corp"`); without an entry the
/// name is the folder's own: its basename without leading dots and a `claude-` / `claude_` prefix (`.claude-corp` →
/// `corp`). The default account is `default`; `[limits] account` labels it where several accounts are shown.
///
/// Folders: the default one, every folder named in `[accounts]`, and every folder a hook or the status line reported
/// (`CLAUDE_CONFIG_DIR`, else the folder of `transcript_path`), remembered in `meta` (`claude_dir:<folder>`), so a
/// second account needs no setting.
public enum Accounts {
    public static let defaultName = "default"

    /// `[accounts]`: folder (`~/` expanded, no trailing `/`) → name.
    public static func map(_ paths: ZagonPaths) -> [String: String] {
        map(Sys.readFile(paths.config).map { String(decoding: $0, as: UTF8.self) } ?? "", home: paths.home)
    }

    static func map(_ text: String, home: String) -> [String: String] {
        var out: [String: String] = [:]
        for k in TOMLLite.keys(in: text, section: "accounts") {
            let dir = k.hasPrefix("\"") || k.hasPrefix("'") ? TOMLLite.string(in: "x = " + k, section: "", key: "x") : k
            guard let dir, let name = TOMLLite.string(in: text, section: "accounts", key: k), !name.isEmpty else { continue }
            out[normalize(dir, home: home)] = name
        }
        return out
    }

    static func normalize(_ dir: String, home: String) -> String {
        var d = dir.hasPrefix("~/") ? home + dir.dropFirst() : dir
        while d.count > 1, d.hasSuffix("/") { d.removeLast() }
        return d
    }

    /// The account of a Claude Code config folder; nil or empty = the default one. A link is named as the folder it
    /// points to.
    public static func name(configDir: String?, home: String, map: [String: String]) -> String {
        guard let raw = configDir, !raw.isEmpty else { return defaultName }
        let given = normalize(raw, home: home), main = normalize(home, home: home) + "/.claude"
        let dir = Sys.realPath(given) ?? given
        if given == main || dir == main || dir == Sys.realPath(main) { return defaultName }  // named by `[limits] account`
        if let n = map[given] ?? map[dir] ?? map.first(where: { Sys.realPath($0.key) == dir })?.value { return n }
        var base = Substring(Sys.basename(dir))
        while base.hasPrefix(".") { base = base.dropFirst() }
        for p in ["claude-", "claude_"] where base.count > p.count && base.lowercased().hasPrefix(p) {
            base = base.dropFirst(p.count)
        }
        return base.isEmpty ? dir : String(base)
    }

    /// The config folder of a Claude Code transcript `<dir>/projects/<project>/<session>.jsonl`; nil for any other path.
    public static func configDir(transcript path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[parts.count - 3] == "projects", path.hasPrefix("/"), parts.last?.hasSuffix(".jsonl") == true
        else { return nil }
        let dir = parts.dropLast(3).joined(separator: "/")
        return dir.isEmpty ? nil : dir
    }

    /// Remembers a config folder a hook or the status line reported, once it holds a `projects` folder (a one-off
    /// `CLAUDE_CONFIG_DIR` without transcripts never becomes a root); true when it is new.
    @discardableResult
    /// The folder is kept as its real path (one folder under two spellings or through a link is one root).
    public static func learn(_ dir: String, store: Store, home: String) throws -> Bool {
        let n = normalize(dir, home: home), main = normalize(home, home: home) + "/.claude"
        guard n.hasPrefix("/"), n != main, Sys.isDir(n + "/projects"), let d = Sys.realPath(n),
              d != main, d != Sys.realPath(main) else { return false }
        return try store.db.run("INSERT OR IGNORE INTO meta(key, value) VALUES(?, 1)", [.text("claude_dir:" + d)]) > 0
    }

    /// The transcript folders to read, with their accounts: `defaultRoot` (`--claude-dir`, the default account's
    /// `projects`), then `<dir>/projects` of the folders in `[accounts]` and those learned from hooks, by path.
    public static func claudeRoots(defaultRoot: String, paths: ZagonPaths, db: SQLite?) -> [(root: String, account: String)] {
        let m = map(paths)
        var dirs = Set(m.keys)
        // A learned folder whose `projects` is gone (a one-off `CLAUDE_CONFIG_DIR` removed) is no root any more.
        try? db?.query("SELECT substr(key, 12) FROM meta WHERE key LIKE 'claude\\_dir:%' ESCAPE '\\'") { r in
            if let d = r.text(0), Sys.isDir(d + "/projects") { dirs.insert(d) }
        }
        let root = normalize(defaultRoot, home: paths.home)
        var out = [(root: root, account: defaultName)]
        for d in dirs.sorted() where d + "/projects" != root && d != normalize(paths.home, home: paths.home) + "/.claude" {
            out.append((d + "/projects", name(configDir: d, home: paths.home, map: m)))
        }
        return out
    }

    /// ` (corp)` after a session of an account other than the default one; "" for the default one and unknown.
    public static func tag(_ account: String?) -> String {
        guard let a = account, a != defaultName, !a.isEmpty else { return "" }
        return " (\(a))"
    }

    /// How an account is named where several are shown: its own name, the default one by `[limits] account` when set.
    public static func label(_ account: String, localAccount: String?) -> String {
        account == defaultName ? localAccount ?? defaultName : account
    }

    /// Current limit readings (`Store.latestLimits`) to show, each with the label of its account: nil while the tool has
    /// readings of the default account only. Another account's readings older than 8 days (the week and a day: no
    /// window of it is left) are left out; the default account's stay, as before accounts.
    public static func labeled(_ readings: [LimitSnapshot], now: Double, localAccount: String?) -> [(LimitSnapshot, String?)] {
        let shown = readings.filter { $0.account == defaultName || now - $0.ts <= 8 * 86400 }
        let several = Set(shown.filter { $0.account != defaultName }.map(\.tool))
        return shown.map { ($0, several.contains($0.tool) ? label($0.account, localAccount: localAccount) : nil) }
    }
}
