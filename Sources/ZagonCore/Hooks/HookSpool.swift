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
}

/// `zagon hook <tool> <event>` and `zagon statusline` write one compact NDJSON line per call to
/// `spool/<yyyy-mm-dd>.ndjson` (UTC day). Only ids, paths, event names and numbers: never prompt text or tool input.
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
        if fromCursor(payload) { return }
        let ts = Sys.now()
        if tool == "claude", event == "SessionStart", let out = HandoffStore(paths: paths).sessionStart(payload: payload) {
            Sys.writeAll(fd: 1, Array((out + "\n").utf8))
        }
        guard let line = hookLine(tool: tool, event: event, payload: payload, ts: ts, pid: Sys.clientPid()) else { return }
        append(line, paths: paths, ts: ts)
    }

    /// A call from Cursor's own agent: Cursor runs the hooks of `~/.claude/settings.json` too ("third-party hooks", on
    /// by default) for its conversations, which are not Claude Code sessions. Every hook input from Cursor has
    /// `cursor_version` (cursor.com/docs/hooks, common schema); Claude Code and Codex never send it. Not the
    /// `CURSOR_*` environment: `claude` started in Cursor's terminal may inherit it.
    static func fromCursor(_ payload: [UInt8]) -> Bool {
        JValue.topLevelStrings(payload, keys: ["cursor_version"])?["cursor_version"] != nil
    }

    /// Set (`ZAGON_INTERNAL=1`) for the `claude -p` / `codex exec` runs Zagon starts itself (day summary): their hooks
    /// and status line must not record anything, or they show up as sessions of the user.
    public static let internalEnv = ["ZAGON_INTERNAL": "1"]
    static var isInternal: Bool { Sys.env("ZAGON_INTERNAL") == "1" }

    public static func append(_ line: String, paths: ZagonPaths, ts: Double) {
        let file = paths.spool + "/" + Sys.utcDay(ts) + ".ndjson"
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
