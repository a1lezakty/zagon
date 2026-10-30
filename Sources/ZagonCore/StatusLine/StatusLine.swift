#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `zagon statusline`: Claude Code status-line wrapper. Saves `rate_limits` to the spool, then runs the user's
/// original status-line command (`[statusline] original_command` in config.toml) with the same stdin; its stdout
/// is the inherited fd, so the output passes through byte for byte.
public enum StatusLine {
    public static let configSection = "statusline", configKey = "original_command"
    static let loopMark = "ZAGON_STATUSLINE"

    /// Spool line with the limit readings, nil if the input has none.
    public static func limitsLine(_ input: [UInt8], ts: Double) -> (line: String, text: String)? {
        guard let v = JValue.parse(input), let rl = v["rate_limits"] else { return nil }
        var m: [JValue.Member] = [.init("kind", .string("limits")), .init("tool", .string("claude")),
                                  .init("ts", .number(HookSpool.fmt(ts)))]
        if let sid = v["session_id"]?.string { m.append(.init("session_id", .string(sid))) }
        var parts: [String] = []
        for (w, label) in [("five_hour", "5h"), ("seven_day", "wk")] {
            guard case .number(let pct)? = rl[w]?["used_percentage"], let p = Double(pct), p.isFinite, abs(p) < 1e9 else { continue }
            m.append(.init(w + "_pct", .number(pct)))
            if case .number(let r)? = rl[w]?["resets_at"] { m.append(.init(w + "_resets_at", .number(r))) }
            parts.append("\(label) \(Int(p.rounded()))%")
        }
        guard !parts.isEmpty else { return nil }
        return (JValue.object(m).compact, parts.joined(separator: " · "))
    }

    /// A reading is spooled only when it changed or `refresh` seconds passed for this session: Claude Code redraws
    /// the status line every few seconds, and each spool line wakes the daemon. The last reading of a session lives in
    /// `spool/.limits-<session>` ("<ts> <reading>"); SpoolIngest removes old ones.
    static let refresh = 60.0

    static func shouldSpool(_ input: [UInt8], ts: Double, paths: ZagonPaths) -> Bool {
        guard let reading = limitsLine(input, ts: 0)?.line else { return false }
        let sid = JValue.parse(input)?["session_id"]?.string ?? ""
        let safe = String(sid.unicodeScalars.filter { $0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-" }
            .prefix(64).map(Character.init))
        let state = paths.spool + "/.limits-" + (safe.isEmpty ? "none" : safe)
        if let b = Sys.readFile(state) {
            let s = String(decoding: b, as: UTF8.self)
            if let sp = s.firstIndex(of: " "), let at = Double(s[..<sp]), s[s.index(after: sp)...] == reading,
               ts - at < refresh, ts >= at { return false }
        }
        Sys.mkdirs(paths.spool)
        _ = Sys.writeFile(state, Array("\(HookSpool.fmt(ts)) \(reading)".utf8), mode: 0o600)
        return true
    }

    /// Runs the wrapper; returns the process exit status (the original command's, or 0).
    public static func run(stdinFD: Int32 = 0, paths: ZagonPaths = ZagonPaths()) -> Int32 {
        if HookSpool.isInternal { return 0 }
        let input = isatty(stdinFD) == 1 ? [] : Sys.readAll(fd: stdinFD)
        let ts = Sys.now()
        let limits = limitsLine(input, ts: ts)
        if let limits, shouldSpool(input, ts: ts, paths: paths) { HookSpool.append(limits.line, paths: paths, ts: ts) }
        // The env mark stops a loop when the saved command is (or calls) this wrapper again.
        if Sys.env(loopMark) == nil, let cmd = TOMLLite.string(at: paths.config, section: configSection, key: configKey),
           !cmd.isEmpty {
            setenv(loopMark, "1", 1)
            return Sys.run(["/bin/sh", "-c", cmd], stdin: input)
        }
        // Own short line: model and limits; never empty (limits are missing on the first render).
        let own = [JValue.parse(input)?["model"]?["display_name"]?.string, limits?.text].compactMap { $0 }
        Sys.writeAll(fd: 1, Array(((own.isEmpty ? "zagon" : own.joined(separator: " · ")) + "\n").utf8))
        return 0
    }
}
