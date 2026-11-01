#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `HandoffService` for `zagon mcp`: handoff_create / handoff_get / handoff_list and the `resume` prompt. `latest`
/// never returns the calling conversation; `current` is that conversation. Its id comes from the SessionStart hook
/// spool (Claude Code and Codex fire it when the session, and this server with it, starts and after `/clear`); without
/// the hook, a log written in the last few seconds is taken for the caller's.
public final class HandoffTools: HandoffService {
    let store: Store?
    let claudeDir: String, codexHome: String, runDir: String, spoolDir: String
    let handoffs: HandoffStore
    let cwd: String?
    let startedAt: Timestamp
    /// The Claude Code / Codex process running this server (and the hooks of its conversation).
    let clientPid: Int32?
    let now: () -> Timestamp

    /// `store`: for task → sessions (`task_session`); `cwd`: where the client runs (`latest` prefers sessions there).
    public init(store: Store?, claudeDir: String, codexHome: String, paths: ZagonPaths = ZagonPaths(),
                cwd: String? = HandoffTools.currentDirectory(), startedAt: Timestamp = Time.now(),
                clientPid: Int32? = Sys.clientPid(), now: @escaping () -> Timestamp = Time.now) {
        self.store = store; self.claudeDir = claudeDir; self.codexHome = codexHome; self.runDir = paths.dir + "/run"
        self.spoolDir = paths.spool
        self.handoffs = HandoffStore(paths: paths); self.cwd = cwd; self.startedAt = startedAt; self.clientPid = clientPid
        self.now = now
    }

    public static func currentDirectory() -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard getcwd(&buf, buf.count) != nil else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func create(session: String, task: String?, compress: Bool, exclude: String?) throws -> String {
        var (doc, compressed) = try build(session: session, task: task, exclude: exclude)
        if compress {
            let tool = Sys.which("claude") != nil ? "claude" : "codex"
            if let s = Handoff.compress(doc.markdown, tool: tool, runDir: runDir) { doc.markdown = s; compressed = true }
        }
        guard let path = handoffs.save(doc) else { throw MCPToolError("cannot write \(handoffs.dir)") }
        return "Handoff \(doc.name) saved: \(path), \(doc.markdown.utf8.count) bytes "
            + "(~\(Handoff.estimatedTokens(doc.markdown)) tokens)" + (compress && !compressed ? ", not shortened (the AI call failed)" : "")
            + ". Read it with handoff_get, id \(doc.name)."
    }

    /// A saved handoff by id; for a session (`latest`, `current`, `claude:<id>`, …) its saved handoff if the log has
    /// not changed since, else a fresh one (not saved: this tool only reads).
    public func get(_ ref: String) throws -> String {
        if !["latest", "current"].contains(ref), let md = handoffs.get(ref) { return md }
        let target = try resolve(ref, exclude: nil)
        if let (tool, id, path) = Handoff.find(target.ref, claudeDir: claudeDir, codexHome: codexHome, cwd: cwd, caller: target.caller) {
            let name = "\(tool.rawValue)-\(Handoff.safeName(id))"
            if let saved = Sys.mtime(handoffs.path(name)), saved >= Sys.mtime(path) ?? .infinity, let md = handoffs.get(name) { return md }
        }
        return try build(session: ref, task: nil, exclude: nil).0.markdown
    }

    public func list(limit: Int) throws -> String {
        let all = handoffs.list()
        guard !all.isEmpty else { return "No handoffs yet; create one with handoff_create." }
        return all.prefix(limit).map { e in
            var l = "\(e.name) | \(Self.subject(e.path)) | \(Txt.when(e.modifiedAt, now: now())) | \(e.bytes) bytes"
            if let w = e.waitingIn { l += " | waits for the next Claude Code session in \(w)" }
            return l
        }.joined(separator: "\n")
    }

    /// `current` → this conversation's id; `latest` → with the caller excluded.
    func resolve(_ session: String, exclude: String?) throws -> (ref: String, caller: Handoff.Caller) {
        let own = callerSession()
        if session == "current" {
            guard let own else {
                throw MCPToolError("this conversation's session id is unknown: it comes from the SessionStart hook (zagon install)")
            }
            return (own, Handoff.Caller())
        }
        let ids = Set([exclude, own].compactMap { $0.map(Self.native) })
        // without the hook: a log written in the last seconds is the caller's (it has just written its tool call)
        return (session, Handoff.Caller(exclude: ids, writtenSince: own == nil && exclude == nil ? now() - 10 : nil))
    }

    func build(session: String, task: String?, exclude: String?) throws -> (Handoff.Document, Bool) {
        let target = try resolve(session, exclude: exclude)
        var sessions = [target.ref], key = task
        if let task {
            let (canonical, linked) = try sessionsOf(task)
            // the task's sessions whose logs are still here, without the caller's own
            sessions = linked.filter { s in
                !target.caller.exclude.contains(Self.native(s)) && Handoff.find(s, claudeDir: claudeDir, codexHome: codexHome) != nil
            }
            guard !sessions.isEmpty else { throw MCPToolError("no log of a session of task \(canonical) is on this machine") }
            key = canonical
        }
        do {
            let doc = try Handoff.create(sessions, task: key, claudeDir: claudeDir, codexHome: codexHome, cwd: cwd,
                                         caller: target.caller)
            return (doc, false)
        } catch let e as Handoff.Failure {
            throw MCPToolError(e.description + (task == nil && session == "latest" ? " (this conversation is skipped)" : ""))
        }
    }

    /// This conversation: the newest SessionStart hook since a minute before the server started that came from this
    /// server's client process (`pid`; `/clear` starts a new session in the same process). Lines without a pid (an
    /// older zagon, no /proc) fall back to the newest SessionStart in this cwd; a line with another pid is another
    /// conversation. The time window also rules out a pid reused by an earlier process.
    func callerSession() -> String? {
        let here = cwd.map(HandoffStore.norm)
        let from = startedAt - 60, firstDay = Sys.utcDay(from)
        var byPid: (Double, String)?, byCwd: (Double, String)?
        // Cursor's lines (`.cursor.ndjson`) have no pid: in the same folder they would pass for this conversation.
        for f in Sys.listDir(spoolDir) where f.hasSuffix(".ndjson") && !f.hasSuffix(".cursor.ndjson")
            && String(f.dropLast(7)) >= firstDay {
            let text = Sys.readFile(spoolDir + "/" + f).map { String(decoding: $0, as: UTF8.self) } ?? ""
            for line in text.split(separator: "\n") where line.contains("\"SessionStart\"") {
                guard let j = JValue.parse(String(line)), j["event"]?.string == "SessionStart",
                      let ts = j["ts"]?.double, ts >= from, let id = j["session_id"]?.string else { continue }
                let s = (ts, (j["tool"]?.string ?? "claude") + ":" + id)
                if let pid = j["pid"]?.double {
                    if let clientPid, pid == Double(clientPid), ts > byPid?.0 ?? -1 { byPid = s }
                } else if j["cwd"]?.string.map(HandoffStore.norm) == here, ts > byCwd?.0 ?? -1 {
                    byCwd = s
                }
            }
        }
        return (byPid ?? byCwd)?.1
    }

    /// Session ids linked to a task (own key, Jira key or id) in the task registry, with the task's key.
    func sessionsOf(_ task: String) throws -> (String, [String]) {
        guard let store else { throw MCPToolError("the task registry is not available") }
        var key: String?, ids: [String] = []
        try store.db.query("""
            SELECT DISTINCT coalesce(t.key, t.jira_key, CAST(t.id AS TEXT)), s.session_id FROM task t
            LEFT JOIN task_session s ON s.task_id = t.id AND s.how NOT IN ('unlinked', 'suggested')
            WHERE t.id = (SELECT id FROM task WHERE key = ?1 OR jira_key = ?1 OR CAST(id AS TEXT) = ?1
                          ORDER BY key = ?1 DESC, id LIMIT 1)
            ORDER BY s.session_id
            """, [.text(task)]) { r in
            key = r.text(0)
            if let s = r.text(1) { ids.append(s) }
        }
        guard let key else { throw MCPToolError("no task \(task)") }
        guard !ids.isEmpty else { throw MCPToolError("task \(key) has no linked sessions") }
        return (key, ids)
    }

    static func native(_ id: String) -> String {
        for p in ["claude:", "codex:"] where id.hasPrefix(p) { return String(id.dropFirst(p.count)) }
        return id
    }

    /// The title, else the first goal line of a saved handoff.
    static func subject(_ path: String) -> String {
        let lines = Sys.readFile(path).map { String(decoding: $0, as: UTF8.self) }?.split(separator: "\n") ?? []
        let s = lines.first { $0.hasPrefix("Title: ") }.map { $0.dropFirst(7) }
            ?? lines.drop { !$0.hasPrefix("## Goal") }.dropFirst().first { $0.hasPrefix("- ") }.map { $0.dropFirst(2) }
        guard let s else { return "-" }
        return s.count > 80 ? String(s.prefix(80)) + "…" : String(s)
    }
}
