#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Work left out of the worklog plan, the "no task" time and the reconciliation: a project (folder or repository
/// name), a task (key or `#id`) or one session (its id).
public struct WorklogExclusion: Codable, Sendable, Hashable {
    public var kind: String
    public var name: String
    public static let kinds = ["project", "task", "session"]
    public init(kind: String, name: String) { self.kind = kind; self.name = name }
}

/// `[worklog]` of config.toml. Lists are strings (TOMLLite reads strings only): `projects = "PROJ, OPS"`,
/// `exclude = "project:example-project, task:PROJ-1, session:claude:…"`.
public struct WorklogConfig: Sendable, Equatable {
    /// The zone worklog days are cut in (IANA name); nil = the zone of the database (`timezone`).
    public var tz: String?
    /// Jira projects whose keys count, besides those Jira lists.
    public var projects: [String] = []
    /// The longest row of a task carries the day's summary (else only the short texts).
    public var daySummary = true
    /// The day's texts are rebuilt at 23:55 in `tz` by the service.
    public var rebuildAtEnd = true
    public var exclude: [WorklogExclusion] = []
    public init() {}

    public static let keys = ["tz", "projects", "day_summary", "rebuild_at_end"]

    public static func load(configText t: String) -> WorklogConfig {
        var c = WorklogConfig()
        func s(_ k: String) -> String? { TOMLLite.string(in: t, section: "worklog", key: k) ?? TOMLLite.raw(in: t, section: "worklog", key: k).map(String.init) }
        if let v = s("tz"), !v.isEmpty, Settings.isZone(v) { c.tz = v }  // a zone libc does not know would be UTC
        c.projects = list(s("projects")).map { $0.uppercased() }
        if let v = s("day_summary") { c.daySummary = v != "false" }
        if let v = s("rebuild_at_end") { c.rebuildAtEnd = v != "false" }
        c.exclude = list(s("exclude")).compactMap { x -> WorklogExclusion? in
            guard let colon = x.firstIndex(of: ":") else { return nil }
            let kind = String(x[..<colon]), name = String(x[x.index(after: colon)...]).trimmed(" ")
            return WorklogExclusion.kinds.contains(kind) && !name.isEmpty ? WorklogExclusion(kind: kind, name: name) : nil
        }
        return c
    }

    public static func load(_ paths: ZagonPaths) -> WorklogConfig {
        load(configText: Sys.readFile(paths.config).map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    static func list(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { String($0).trimmed(" \t") }.filter { !$0.isEmpty }
    }

    /// Sets one `[worklog]` key in config.toml (`tz`, `projects`, `day_summary`, `rebuild_at_end`), every other line kept.
    /// `tz` "" or "system" removes it; `projects` is a comma list ("" removes it). Throws for a bad value.
    public static func set(_ paths: ZagonPaths, _ key: String, _ value: String) throws {
        var raw: String?, quoted: String?
        switch key {
        case "tz":
            if value.isEmpty || value == "system" { break }
            guard Settings.isZone(value) else { throw SettingsError("unknown time zone: \(value) (no such file in the tz database)") }
            quoted = value
        case "projects":
            let ps = list(value).map { $0.uppercased() }
            guard ps.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }) else {
                throw SettingsError("projects: Jira project keys separated by commas, e.g. PROJ, OPS")
            }
            if !ps.isEmpty { quoted = ps.joined(separator: ", ") }
        case "day_summary", "rebuild_at_end":
            guard ["true", "false"].contains(value) else { throw SettingsError("\(key) must be true or false") }
            raw = value
        default: throw SettingsError("unknown key \(key): one of \(keys.joined(separator: ", "))")
        }
        try write(paths) { TOMLLite.setting($0, section: "worklog", key: key, to: quoted, raw: raw) }
    }

    /// Adds or removes one exclusion; returns false when there was nothing to change.
    @discardableResult
    public static func setExcluded(_ paths: ZagonPaths, _ x: WorklogExclusion, _ on: Bool) throws -> Bool {
        guard WorklogExclusion.kinds.contains(x.kind), !x.name.isEmpty, !x.name.contains(",") else {
            throw SettingsError("exclude: project|task|session and a name without commas")
        }
        var all = load(paths).exclude
        if on { guard !all.contains(x) else { return false }; all.append(x) }
        else { guard all.contains(x) else { return false }; all.removeAll { $0 == x } }
        let v = all.map { "\($0.kind):\($0.name)" }.joined(separator: ", ")
        try write(paths) { TOMLLite.setting($0, section: "worklog", key: "exclude", to: v.isEmpty ? nil : v) }
        return true
    }

    static func write(_ paths: ZagonPaths, _ change: (String) -> String) throws {
        let cur = Sys.readFile(paths.config).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let new = change(cur)
        guard new != cur else { return }
        Sys.mkdirs(paths.dir)
        guard Sys.writeFile(paths.config, Array(new.utf8), mode: 0o600) else { throw SettingsError("cannot write \(paths.config)") }
    }
}

/// `zagon log config --json`.
public struct WorklogSettings: Encodable, Sendable {
    public var tz: String?
    public var machineTz: String
    public var projects: [String]
    /// From the last Jira read (`JiraCache`), read-only here.
    public var jiraProjects: [String]
    public var daySummary: Bool
    public var rebuildAtEnd: Bool
    public var exclude: [WorklogExclusion]

    public init(_ c: WorklogConfig, jiraProjects: [String]) {
        tz = c.tz; machineTz = Settings.zoneName(); projects = c.projects; self.jiraProjects = jiraProjects
        daySummary = c.daySummary; rebuildAtEnd = c.rebuildAtEnd; exclude = c.exclude
    }

    // nil `tz` is sent as null (the mac reads "no zone set" from it).
    enum CodingKeys: String, CodingKey { case tz, machineTz, projects, jiraProjects, daySummary, rebuildAtEnd, exclude }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(tz, forKey: .tz)
        try c.encode(machineTz, forKey: .machineTz); try c.encode(projects, forKey: .projects)
        try c.encode(jiraProjects, forKey: .jiraProjects); try c.encode(daySummary, forKey: .daySummary)
        try c.encode(rebuildAtEnd, forKey: .rebuildAtEnd); try c.encode(exclude, forKey: .exclude)
    }
}

extension Settings {
    /// Runs `body` with days cut in `zone` (nil or the current one: as is) and puts `TZ` back. It sets `TZ` for the
    /// whole process: only for single-threaded work (a CLI command, an MCP call), and after any scan (a scan in another
    /// zone would rebuild the days).
    public static func inZone<T>(_ zone: String?, _ body: () throws -> T) rethrows -> T {
        guard let zone, Sys.env("TZ") != zone else { return try body() }
        let old = Sys.env("TZ")
        setenv("TZ", zone, 1); tzset()
        defer { if let old { setenv("TZ", old, 1) } else { unsetenv("TZ") }; tzset() }
        return try body()
    }
}
