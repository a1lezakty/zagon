import CSQLite
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Cursor 3 keeps no transcripts on disk: what it lists of past conversations are the rows of `composerHeaders` in its
/// `globalStorage/state.vscdb`. `sync` opens that database read-only and reads only this table's ids, workspace, times
/// and `name` (never `ItemTable`, `cursorDiskKV`, keys or the text of a conversation), and copies the local
/// conversations to `<data-dir>/cursor/headers.ndjson` for `CursorHeadersParser`. Local = its workspace
/// (`workspaceStorage/<id>/workspace.json`) is a `file://` folder or workspace file; a Remote SSH one runs its agent and
/// hooks on the server, so the Zagon there counts it. Left out too: sub-agents, and conversations Zagon read a transcript
/// of (Cursor up to 2.x), counted from that.
public enum CursorHeaders {
    static let name = "headers.ndjson"
    static func dir(_ paths: ZagonPaths) -> String { paths.dir + "/cursor" }
    public static func file(_ paths: ZagonPaths) -> String { dir(paths) + "/" + name }

    /// Cursor's `User` folder.
    public static func userDir(home: String) -> String {
        #if os(macOS)
        home + "/Library/Application Support/Cursor/User"
        #else
        (Sys.env("XDG_CONFIG_HOME") ?? home + "/.config") + "/Cursor/User"
        #endif
    }

    /// Rewrites `file(paths)` when the conversations changed; true = changed (ingest it). At most once per `every`
    /// seconds (`meta` `cursor_headers_at`, shared by the app, the CLI and the service): Cursor writes this database all
    /// the time, and it is history, the hooks count what happens now. Never throws: no Cursor, a database it cannot open
    /// or read now (locked, another format) leaves the file as it was. A conversation gone from Cursor's list (Cursor
    /// cleans up), or whose workspace is no longer known, keeps its line, as a deleted transcript keeps its count; only
    /// new conversations at the end: they are appended, so Ingest reads just them, else the file is replaced (renamed)
    /// and counted again from the start.
    @discardableResult
    public static func sync(store: Store, paths: ZagonPaths = ZagonPaths(), user: String? = nil, every: Double = 300,
                            now: Double = Sys.now()) -> Bool {
        let user = user ?? userDir(home: paths.home), db = user + "/globalStorage/state.vscdb", out = file(paths)
        guard Sys.exists(db) else { return false }
        let last = (try? store.db.one("SELECT value FROM meta WHERE key = 'cursor_headers_at'") { $0.real(0) }) ?? nil
        if let last, now >= last, now - last < every { return false }
        _ = try? store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('cursor_headers_at', ?)", [.real(now)])
        guard let rows = (try? read(db)) ?? nil, let skip = try? transcripts(store) else { return false }
        let since = CursorSource.hooksSince(paths.cursorHooks)
        var lines: [String] = [], drop = Set<String>(), places: [String: Place] = [:]
        for r in rows {
            guard r.main, !skip.contains(r.id) else { drop.insert(r.id); continue }
            if places[r.ws] == nil { places[r.ws] = place(user: user, workspace: r.ws) }
            switch places[r.ws]! {
            case .unknown: continue  // an old line stays
            case .remote: drop.insert(r.id)
            case .local(let cwd):
                drop.insert(r.id)
                var m: [JValue.Member] = [.init("id", .string(String(r.id.prefix(256)))),
                                          .init("created", .number(HookSpool.fmt(r.created))),
                                          .init("updated", .number(HookSpool.fmt(min(r.updated, (since ?? .infinity) - 1))))]
                if let cwd { m.append(.init("cwd", .string(cwd))) }
                if let n = r.name?.trimmingSpaces, !n.isEmpty { m.append(.init("name", .string(String(n.prefix(80))))) }
                lines.append(JValue.object(m).compact)
            }
        }
        let old = Sys.readFile(out)
        let kept = old.map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init) }?.filter { l in
            JValue.parse(l)?["id"]?.string.map { !drop.contains($0) } ?? false
        } ?? []
        let new = Array((kept + lines).map { $0 + "\n" }.joined().utf8)
        if let old {
            if old == new { return false }
            if !old.isEmpty, new.starts(with: old) { return Sys.append(out, Array(new[old.count...])) }
        } else if new.isEmpty { return false }
        return Sys.mkdirs(dir(paths)) && Sys.writeFile(out, new, mode: 0o600)
    }

    /// Conversation ids whose transcript this database counts (also one Cursor has deleted since).
    static func transcripts(_ store: Store) throws -> Set<String> {
        var ids = Set<String>()
        try store.db.query("SELECT path FROM source_file WHERE tool = 'cursor' AND path LIKE '%/agent-transcripts/%'") {
            if let p = $0.text(0), p.hasSuffix(".jsonl") { ids.insert(String(Sys.basename(p).dropLast(6))) }
        }
        return ids
    }

    struct Row { var id: String, ws: String, created: Double, updated: Double, name: String?, main: Bool }

    /// Every conversation `composerHeaders` lists, oldest first (seconds); `main` = not a sub-agent. nil = no such table
    /// or columns (another format: keep what was counted). The connection waits at most 0.25 s for Cursor's writer and
    /// is closed before anything else is read.
    static func read(_ path: String) throws -> [Row]? {
        let db = try SQLite(path: CodexThreads.uri(path) + "?mode=ro", readOnly: true)
        sqlite3_busy_timeout(db.handle, 250)
        var cols = Set<String>()
        try db.query("PRAGMA table_info(composerHeaders)") { if let n = $0.text(1) { cols.insert(n) } }
        guard ["composerId", "workspaceId", "createdAt", "lastUpdatedAt"].allSatisfy(cols.contains) else { return nil }
        let sub = cols.contains("isSubagent") ? "coalesce(isSubagent, 0) = 0" : "1"
        // Only `name` of the JSON in `value`, inside SQLite.
        let name = cols.contains("value")
            ? "CASE WHEN json_valid(CAST(value AS TEXT)) THEN json_extract(CAST(value AS TEXT), '$.name') END" : "NULL"
        var out: [Row] = []
        try db.query("""
            SELECT composerId, coalesce(workspaceId, ''), createdAt, lastUpdatedAt, \(name), \(sub) FROM composerHeaders
            ORDER BY createdAt, composerId
            """) { r in
            guard let id = r.text(0), !id.isEmpty else { return }
            let created = seconds(r.real(2))
            out.append(Row(id: id, ws: r.text(1) ?? "", created: created, updated: max(created, seconds(r.real(3))),
                           name: r.text(4), main: r.int(5) == 1 && created > 0))
        }
        return out
    }

    /// JavaScript milliseconds (or seconds) → seconds.
    static func seconds(_ x: Double) -> Double { x > 1e11 ? x / 1000 : x }

    /// Where a workspace is: local (its folder; nil for a workspace file), remote, or not known (no `workspace.json`:
    /// an empty window, a cleaned-up workspace, or an id this layout does not know).
    enum Place: Equatable { case local(String?), remote, unknown }

    static func place(user: String, workspace ws: String) -> Place {
        guard !ws.isEmpty, !ws.contains("/"), ws != "..", let b = Sys.readFile(user + "/workspaceStorage/\(ws)/workspace.json"),
              let v = JValue.parse(b), let uri = (v["folder"] ?? v["workspace"])?.string else { return .unknown }
        guard uri.hasPrefix("file:///") else { return .remote }
        return .local(v["folder"] != nil ? percentDecoded(uri.dropFirst(7)) : nil)
    }

    /// `%XX` → the byte (URIs in `workspace.json`: `file:///Users/me/My%20App`).
    static func percentDecoded(_ s: Substring) -> String {
        let u = Array(s.utf8)
        var out: [UInt8] = [], i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "%"), i + 2 < u.count, let b = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(b); i += 3
            } else {
                out.append(u[i]); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// `<data-dir>/cursor/headers.ndjson` (`CursorHeaders.sync`): one conversation per line, `{"id", "created",
/// "updated", "cwd"?, "name"?}` (seconds; `updated` stops a second before the hooks began, so the file does not change
/// with each turn after that and a conversation also used later keeps its earlier turn). `name` is its title. Time,
/// rougher than the transcripts': the creation is a typed message, and its turn lasts until the last update by the
/// transcripts' rule (at most `CursorTranscriptParser.cap`, none when the two are over `gap` apart); only before the
/// hooks (a minute's margin, as the transcripts). The file is rewritten whole, so Ingest counts it again from the start.
struct CursorHeadersParser: LineParser {
    let since: Double?

    mutating func parse(line: UnsafeRawBufferPointer, into out: inout ParseOutput) {
        guard let v = JValue.parse(Array(line)), let id = v["id"]?.string, !id.isEmpty, let c = v["created"]?.double,
              let u = v["updated"]?.double else { out.badLines += 1; return }
        let sid = "cursor:" + id, cwd = v["cwd"]?.string, name = v["name"]?.string
        out.meta.append(SessionMeta(id: sid, tool: .cursor, project: cwd.map(ClaudeParser.project), cwd: cwd, title: name,
                                    titleRank: name == nil ? TitleRank.none : TitleRank.external))
        guard c < (since ?? .infinity) - 60 else { return }
        out.userMessages.append(UserMessage(sessionId: sid, ts: c, cwd: cwd))
        if u > c, u - c <= CursorTranscriptParser.gap, u < since ?? .infinity {
            out.events.append(ActivityEvent(sessionId: sid, ts: min(u, c + CursorTranscriptParser.cap), cwd: cwd))
        }
    }

    func saveState() -> String? { nil }
}
