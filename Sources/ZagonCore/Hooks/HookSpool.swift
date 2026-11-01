#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Where Zagon keeps its files: `$ZAGON_DIR` or `~/.zagon`.
public struct ZagonPaths: Sendable {
    public var home: String
    public var dir: String
    public init(home: String? = nil, dir: String? = nil) {
        let h = home ?? Sys.env("HOME") ?? "/"
        self.home = h
        self.dir = dir ?? Sys.env("ZAGON_DIR") ?? h + "/.zagon"
    }
    public var spool: String { dir + "/spool" }
    public var config: String { dir + "/config.toml" }
    public var backup: String { dir + "/backup" }
    /// When the first Cursor hook came (epoch seconds): Cursor's transcripts count time only before it.
    public var cursorHooks: String { dir + "/cursor-hooks" }
}

/// `zagon hook <tool> <event>` and `zagon statusline` write one compact NDJSON line per call to
/// `spool/<yyyy-mm-dd>.ndjson` (UTC day; Cursor's agent: `<yyyy-mm-dd>.cursor.ndjson`). Only ids, paths, event names and numbers (Cursor's prompts: their task keys, `cursorLine`): never prompt text or tool input.
public enum HookSpool {
    /// Hook payload fields copied to the spool (everything else, e.g. `prompt`, `tool_input`, is dropped).
    static let hookKeys: Set<String> = ["session_id", "cwd", "hook_event_name", "notification_type", "tool_name",
                                        "permission_mode", "transcript_path", "source"]
    static let maxField = 4096

    /// Builds the spool line for a hook call; nil if the payload has no session id. `pid`: the client process
    /// (`Sys.clientPid`), read only by handoff to tell which conversation a `zagon mcp` belongs to; never stored.
    public static func hookLine(tool: String, event: String, payload: [UInt8], ts: Double, pid: Int32? = nil) -> String? {
        guard let f = JValue.topLevelStrings(payload, keys: hookKeys), let sid = f["session_id"], !sid.isEmpty else { return nil }
        var m: [JValue.Member] = [.init("kind", .string("hook")), .init("tool", .string(String(tool.prefix(32)))),
                                  .init("event", .string(String(event.prefix(64)))), .init("ts", .number(fmt(ts)))]
        if let pid { m.append(.init("pid", .number("\(pid)"))) }
        for k in ["session_id", "cwd", "hook_event_name", "notification_type", "tool_name", "permission_mode",
                  "transcript_path", "source"] {
            if let v = f[k] { m.append(.init(k, .string(String(v.prefix(maxField))))) }
        }
        return JValue.object(m).compact
    }

    /// Entry point of `zagon hook`: never throws, always returns normally. Writes to stdout (Claude and Codex add hook
    /// stdout to the model context) only on `claude SessionStart` when a handoff waits for that cwd. Missing
    /// directories are created; write errors are ignored.
    public static func handleHook(args: [String], stdinFD: Int32 = 0, paths: ZagonPaths = ZagonPaths()) {
        if isInternal { return }
        let tool = args.count > 0 ? args[0] : "unknown"
        let event = args.count > 1 ? args[1] : "unknown"
        let payload = isatty(stdinFD) == 1 ? [] : Sys.readAll(fd: stdinFD)
        let ts = Sys.now()
        if fromOtherAgent(payload) {
            let keys = event == "UserPromptSubmit" ? Settings.keyPattern(paths) : nil
            if let line = cursorLine(event: event, payload: payload, ts: ts, keyPattern: keys) {
                append(line, paths: paths, ts: ts, name: ".cursor")
                if !Sys.exists(paths.cursorHooks) { Sys.append(paths.cursorHooks, Array("\(fmt(ts))\n".utf8)) }
            }
            return
        }
        if tool == "claude", event == "SessionStart", let out = HandoffStore(paths: paths).sessionStart(payload: payload) {
            Sys.writeAll(fd: 1, Array((out + "\n").utf8))
        }
        guard let line = hookLine(tool: tool, event: event, payload: payload, ts: ts, pid: Sys.clientPid()) else { return }
        append(line, paths: paths, ts: ts)
    }

    /// A call from another editor's own agent: Cursor (on by default), Devin / ex-Windsurf (on by default), Trae and
    /// VS Code's agent (each when allowed) run the hooks of `~/.claude/settings.json` too, for conversations that are
    /// not Claude Code sessions (Cursor's are kept as tool `cursor`, see `cursorLine`). Told by the keys of their hook input, as their docs give it: `cursor_version` (Cursor),
    /// `workspace_roots` (Cursor, Trae), `timestamp` (VS Code), neither `cwd` nor `transcript_path` (Devin). Claude Code
    /// always sends both and none of the others, Codex too (its `transcript_path` may be null); `CLAUDE_CONFIG_DIR`
    /// changes values only. Not the environment (`CURSOR_*`…): `claude` started in such an editor's terminal may
    /// inherit it.
    /// ponytail: keys from the editors' docs; should Claude Code ever send one of them, its live statuses stop: match
    /// on values then.
    static func fromOtherAgent(_ payload: [UInt8]) -> Bool {
        guard let keys = JValue.topLevelKeys(payload) else { return false }
        return !keys.isDisjoint(with: ["cursor_version", "workspace_roots", "timestamp"])
            || (!keys.contains("cwd") && !keys.contains("transcript_path"))
    }

    /// Cursor's agent runs these hooks too (Third-Party Imports, on by default; cursor.com/docs/hooks) with its own
    /// input: `conversation_id`, `workspace_roots`, `model`, `cursor_version`. Kept as tool `cursor`: the event is the
    /// Claude name the hook was installed for (Cursor maps `Stop` → `stop`, `UserPromptSubmit` → `beforeSubmitPrompt`…).
    /// Only ids, the first workspace root (else `cwd`), the model, the tool name and the task keys of the prompt
    /// (`keyPattern`, as Ingest finds them; Cursor's transcript is read only for the time before its hooks); never
    /// `prompt`, `user_email` or tool input / output. nil = not Cursor (no `cursor_version`) or no conversation id.
    /// ponytail: field names from Cursor's docs, unconfirmed on a live Cursor; unknown fields are ignored, missing ones
    /// only leave the line without them.
    static func cursorLine(event: String, payload: [UInt8], ts: Double, keyPattern: String? = nil) -> String? {
        guard let v = JValue.parse(payload), v["cursor_version"] != nil,
              let sid = [v["conversation_id"], v["session_id"]].lazy.compactMap({ $0?.string }).first(where: { !$0.isEmpty })
        else { return nil }
        var m: [JValue.Member] = [.init("kind", .string("hook")), .init("tool", .string("cursor")),
                                  .init("event", .string(String(event.prefix(64)))), .init("ts", .number(fmt(ts))),
                                  .init("session_id", .string(String(sid.prefix(maxField))))]
        let roots = v["workspace_roots"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
        let fields = [("cwd", roots.first ?? v["cwd"]?.string), ("model", v["model"]?.string), ("tool_name", v["tool_name"]?.string),
                      ("transcript_path", v["transcript_path"]?.string)]
        for (k, val) in fields { if let val, !val.isEmpty { m.append(.init(k, .string(String(val.prefix(maxField))))) } }
        if let p = v["prompt"]?.string, let re = keyPattern.flatMap({ try? Regex($0) }) {
            let keys = Ingest.taskKeys(Ingest.typedText(p), re).prefix(32).joined(separator: " ")
            if !keys.isEmpty { m.append(.init("keys", .string(String(keys.prefix(maxField))))) }
        }
        return JValue.object(m).compact
    }

    /// Set (`ZAGON_INTERNAL=1`) for the `claude -p` / `codex exec` runs Zagon starts itself (day summary): their hooks
    /// and status line must not record anything, or they show up as sessions of the user.
    public static let internalEnv = ["ZAGON_INTERNAL": "1"]
    static var isInternal: Bool { Sys.env("ZAGON_INTERNAL") == "1" }

    /// `name` goes between the day and `.ndjson` (`.cursor`: Cursor's lines, also read by `CursorSource.hooks`).
    public static func append(_ line: String, paths: ZagonPaths, ts: Double, name: String = "") {
        let file = paths.spool + "/" + Sys.utcDay(ts) + name + ".ndjson"
        let bytes = Array((line + "\n").utf8)
        if Sys.append(file, bytes) { return }
        if Sys.mkdirs(paths.spool) { Sys.append(file, bytes) }
    }

    /// Timestamp with millisecond precision, as JSON number text.
    static func fmt(_ t: Double) -> String {
        let ms = Int64((t * 1000).rounded())
        let r = ms % 1000
        return "\(ms / 1000)." + String(repeating: "0", count: 3 - String(r).count) + String(r)
    }
}
