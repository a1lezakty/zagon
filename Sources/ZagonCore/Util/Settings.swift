#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl  // `environ`
#elseif canImport(Darwin)
import Darwin
#endif

public struct SettingsError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// Settings every command shares, from `config.toml`.
public enum Settings {
    /// Top-level `timezone = "Europe/Moscow"` (the older `[notify] timezone` still works); nil = the system zone.
    public static func timezone(_ paths: ZagonPaths) -> String? {
        Sys.readFile(paths.config).flatMap { timezone(in: String(decoding: $0, as: UTF8.self)) }
    }

    public static func timezone(in text: String) -> String? {
        for section in ["", "notify"] {
            if let v = TOMLLite.string(in: text, section: section, key: "timezone"), !v.isEmpty { return v }
        }
        return nil
    }

    /// `TZ` this process was started with (nil = /etc/localtime); what "no zone in config.toml" goes back to.
    public static let startTZ: String? = Sys.env("TZ")

    /// Cuts days, reports and notifications in the configured zone, else in the zone the process started with.
    /// Idempotent. Call before other threads start (it sets `TZ` for the process): a running service restarts
    /// instead (`restart`), single-threaded loops may call it again to follow config.toml.
    public static func applyTimezone(_ paths: ZagonPaths) {
        let start = startTZ  // captured before the first change (`??` would read it only when the config has no zone)
        let want = timezone(paths) ?? start
        guard Sys.env("TZ") != want else { return }
        if let want { setenv("TZ", want, 1) } else { unsetenv("TZ") }
        tzset()
    }

    /// Whether this process already cuts days in the zone config.toml asks for.
    public static func timezoneApplied(_ paths: ZagonPaths) -> Bool { Sys.env("TZ") == (timezone(paths) ?? startTZ) }

    /// A zone name from the tz database (`Asia/Almaty`, `UTC`): a TZif file under one of the zoneinfo roots libc reads.
    public static func isZone(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.utf8.count <= 64, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              name.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "/_+-".unicodeScalars.contains($0)) })
        else { return false }
        let roots = [Sys.env("TZDIR"), "/usr/share/zoneinfo", "/share/zoneinfo", "/etc/zoneinfo"].compactMap { $0 }
        return roots.contains { Sys.readFile($0 + "/" + name).map { Array($0.prefix(4)) == Array("TZif".utf8) } ?? false }
    }

    /// Name of the zone in effect: `TZ`, else the tz name /etc/localtime points to, else UTC (libc's default).
    public static func zoneName() -> String {
        if let tz = Sys.env("TZ"), !tz.isEmpty { return tz.hasPrefix(":") ? String(tz.dropFirst()) : tz }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = buf.withUnsafeMutableBytes { readlink("/etc/localtime", $0.baseAddress!.assumingMemoryBound(to: CChar.self), 511) }
        let link = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
        if let r = link.firstRange(of: "zoneinfo/") { return String(link[r.upperBound...]) }
        return "UTC"
    }

    /// `Asia/Almaty (config.toml), now 2026-10-30 19:20` for the CLI and MCP.
    public static func timezoneStatus(_ paths: ZagonPaths, now: Double = Sys.now()) -> String {
        var t = time_t(now.rounded(.down)), v = tm()
        localtime_r(&t, &v)
        func p2(_ x: Int32) -> String { x < 10 ? "0\(x)" : "\(x)" }
        let source = timezone(paths) == nil ? "system zone" : "config.toml"
        return "\(zoneName()) (\(source)), now \(Time.dayString(now)) \(p2(v.tm_hour)):\(p2(v.tm_min))"
    }

    /// Writes the top-level `timezone` of config.toml (nil = remove it: the system zone), keeping every other line;
    /// the older `[notify] timezone` is removed so it cannot come back. Throws for an unknown zone.
    public static func setTimezone(_ paths: ZagonPaths, _ zone: String?) throws {
        if let zone, !isZone(zone) { throw SettingsError("unknown time zone: \(zone) (no such file in the tz database)") }
        let cur = Sys.readFile(paths.config).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var new = TOMLLite.setting(cur, section: "", key: "timezone", to: zone)
        new = TOMLLite.setting(new, section: "notify", key: "timezone", to: nil)
        guard new != cur else { return }
        Sys.mkdirs(paths.dir)
        guard Sys.writeFile(paths.config, Array(new.utf8), mode: 0o600) else { throw SettingsError("cannot write \(paths.config)") }
    }

    /// Writes `[summary] time` (nil = off), keeping every other line; the service reads it on its next tick.
    public static func setSummaryTime(_ paths: ZagonPaths, _ at: String?) throws {
        if let at, NotifyConfig.clock(at) == nil { throw SettingsError("the time must be HH:MM (00:00-23:59) or off") }
        let cur = Sys.readFile(paths.config).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let new = TOMLLite.setting(cur, section: "summary", key: "time", to: at ?? "")
        guard new != cur else { return }
        Sys.mkdirs(paths.dir)
        guard Sys.writeFile(paths.config, Array(new.utf8), mode: 0o600) else { throw SettingsError("cannot write \(paths.config)") }
    }

    /// Replaces this process with a fresh run of the same command (same pid), `TZ` as it was at start: a service
    /// that must follow a new zone, which cannot be switched under running threads. Returns only on failure.
    public static func restart() {
        var envp: [UnsafeMutablePointer<CChar>?] = []
        var i = 0
        while let e = environ[i] {
            if !String(cString: e).hasPrefix("TZ=") { envp.append(strdup(e)) }
            i += 1
        }
        if let tz = startTZ { envp.append(strdup("TZ=" + tz)) }
        envp.append(nil)
        let args: [String] = [Sys.executablePath()] + CommandLine.arguments.dropFirst()
        let argv = args.map { strdup($0) } + [nil]
        execve(args[0], argv, envp)
        argv.forEach { free($0) }; envp.forEach { free($0) }
    }

    /// Identity of the zone days are cut in now: `TZ`, else the system zone file.
    public static func timezoneID() -> String {
        if let tz = getenv("TZ") { return "TZ=" + String(cString: tz) }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = buf.withUnsafeMutableBytes { readlink("/etc/localtime", $0.baseAddress!.assumingMemoryBound(to: CChar.self), 511) }
        return n > 0 ? "localtime=" + String(decoding: buf[0..<n], as: UTF8.self) : "system"
    }

    /// `[limits] account = "work"`: names the subscription this machine's limit readings belong to, for a user with two
    /// (shown next to the rings when readings come from more than one source); nil = not set.
    public static func limitsAccount(_ paths: ZagonPaths) -> String? {
        TOMLLite.string(at: paths.config, section: "limits", key: "account").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `[tasks] key_pattern` (a regular expression), else the default; `""` turns task keys off.
    public static func keyPattern(_ paths: ZagonPaths) -> String? {
        let v = TOMLLite.string(at: paths.config, section: "tasks", key: "key_pattern")
        return v == "" ? nil : v ?? IngestOptions.defaultKeyPattern
    }
}
