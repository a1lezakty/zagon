#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Session titles and metadata from Codex's own index `<CODEX_HOME>/state_<N>.sqlite`, table `threads`.
/// Read-only; `first_user_message` never leaves SQLite (only compared with `title`); rollouts feed search.
public enum CodexThreads {
    /// The highest-numbered `state_<N>.sqlite` in `codexHome`, or nil.
    public static func stateFile(codexHome: String) -> String? {
        let best = Sys.listDir(codexHome).compactMap { n -> (Int, String)? in
            guard n.hasPrefix("state_"), n.hasSuffix(".sqlite"), let v = Int(n.dropFirst(6).dropLast(7)) else { return nil }
            return (v, n)
        }.max { $0.0 < $1.0 }
        return best.map { codexHome + "/" + $0.1 }
    }

    /// Merges every main thread into `session` (title rank `external`) when it would change something there:
    /// Codex does not bump `updated_at` on every change (archiving only sets `archived_at`), so all rows are compared
    /// with the stored sessions instead of following a watermark. Sub-agent threads are skipped: their rollouts are
    /// counted under the parent session. Returns the number of merged sessions.
    @discardableResult
    public static func sync(store: Store, codexHome: String = CodexSource.defaultHome(), host: String? = nil) throws -> Int {
        guard let path = stateFile(codexHome: codexHome) else { return 0 }
        var stored: [String: SessionMeta] = [:]
        try store.db.query("""
            SELECT id, project, cwd, git_branch, title, title_rank, model, archived FROM session WHERE tool = 'codex'
            """) { r in
            guard let id = r.text(0) else { return }
            stored[id] = SessionMeta(id: id, tool: .codex, project: r.text(1), cwd: r.text(2), gitBranch: r.text(3),
                                     title: r.text(4), titleRank: r.int(5), model: r.text(6),
                                     archived: r.optInt(7).map { $0 != 0 })
        }
        // ponytail: reads every thread per sync (Codex keeps hundreds); add a watermark if that ever shows up.
        let rows = try read(path).filter { m in stored[m.id].map { changes(m, $0) } ?? true }
        try store.db.transaction { for m in rows { try store.mergeSession(m, host: host) } }
        return rows.count
    }

    /// Whether `mergeSession(m)` would change the stored session `s` (nil fields keep the stored value).
    static func changes(_ m: SessionMeta, _ s: SessionMeta) -> Bool {
        func d<T: Equatable>(_ a: T?, _ b: T?) -> Bool { a != nil && a != b }
        return d(m.project, s.project) || d(m.cwd, s.cwd) || d(m.gitBranch, s.gitBranch) || d(m.model, s.model)
            || d(m.archived, s.archived) || (d(m.title, s.title) && m.titleRank >= s.titleRank)
    }

    /// Opens `mode=ro`; if that fails (e.g. WAL without a writable `-shm`), reads a temporary copy.
    static func read(_ path: String) throws -> [SessionMeta] {
        do {
            return try query(SQLite(path: uri(path) + "?mode=ro", readOnly: true))
        } catch {
            // The copy holds every thread's first message: files 0600, removed right after the read.
            let copy = (Sys.env("TMPDIR") ?? "/tmp") + "/zagon-codex-\(UInt64.random(in: 0...UInt64.max)).sqlite"
            defer { for suffix in ["", "-wal", "-shm", "-journal"] { Sys.remove(copy + suffix) } }
            for suffix in ["", "-wal"] {
                guard let b = Sys.readFile(path + suffix) else { continue }
                guard Sys.writeFile(copy + suffix, b, mode: 0o600) else { throw error }
            }
            return try query(SQLite(path: copy))
        }
    }

    static func uri(_ path: String) -> String {
        var s = "file:"
        for c in path.unicodeScalars {
            switch c {
            case "%", "?", "#": s += "%" + String(c.value, radix: 16, uppercase: true)
            default: s.unicodeScalars.append(c)
            }
        }
        return s
    }

    static func query(_ db: SQLite) throws -> [SessionMeta] {
        var cols = Set<String>()
        try db.query("PRAGMA table_info(threads)") { r in if let n = r.text(1) { cols.insert(n) } }
        guard cols.contains("id") else { return [] }
        func c(_ n: String) -> String { cols.contains(n) ? n : "NULL" }
        // `title` defaults to the first typed message (Codex may cut it with "…"): never store that as a title, and
        // do not trust it when the first message is unknown. Renames live in `name`.
        let titleIsPrompt = cols.contains("first_user_message") && cols.contains("title")
            ? "coalesce(first_user_message, '') = '' OR instr(first_user_message, rtrim(title, '…')) = 1"
              + " OR instr(title, first_user_message) = 1"
            : "1"
        var out: [SessionMeta] = []
        try db.query("""
            SELECT id, \(c("cwd")), \(c("name")), \(c("title")), \(c("model")), \(c("git_branch")), \(c("source")),
                   \(c("thread_source")), \(c("archived")), \(titleIsPrompt)
            FROM threads
            """) { r in
            guard let id = r.text(0) else { return }
            if r.text(7) == "subagent" || (r.text(6) ?? "").hasPrefix("{\"subagent\"") { return }
            let title = nonEmpty(r.text(2)) ?? (r.int(9) == 1 ? nil : nonEmpty(r.text(3)))
            let cwd = nonEmpty(r.text(1))
            out.append(SessionMeta(id: "codex:" + id, tool: .codex, project: cwd.map(ClaudeParser.project), cwd: cwd,
                                   gitBranch: nonEmpty(r.text(5)),
                                   title: title, titleRank: title == nil ? TitleRank.none : TitleRank.external,
                                   model: nonEmpty(r.text(4)), archived: r.optInt(8).map { $0 != 0 }))
        }
        return out
    }

    static func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
}
