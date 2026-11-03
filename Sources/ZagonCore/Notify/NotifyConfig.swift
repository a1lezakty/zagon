#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Notification, bot and day-summary settings from `~/.zagon/config.toml`. Every key is optional:
///
///     [notify]
///     enabled = true              # this host sends notifications (keep it on one host only)
///     limit_reset = true          # "limit reset" after a window that reached its first threshold
///     waiting_minutes = 10        # a session waits for you longer than this (0 = off)
///     waiting_background_minutes = 60  # the same while its background tasks still run (0 = never)
///     long_work_minutes = 15      # a turn that worked longer than this has finished (0 = off)
///     summary_at = "20:00"        # day summary ("" = off)
///     worklog_at = "19:00"        # worklog plan (the tasks package provides it; "" = off)
///     quiet = "23:00-08:00"       # nothing is sent inside ("" = off)
///     timezone = ""               # e.g. "Europe/Moscow"; empty = system zone
///     lang = "auto"               # auto | ru | en: notifications, bot replies, day summary; auto = the system's language
///
///     [notify.limits]             # thresholds per limit category: 50...100 in steps of 5, [] = off
///     claude.five_hour = [80, 95]
///     claude.week = [80, 95]
///     codex.five_hour = [80, 95]
///     codex.week = [80, 95]
///     codex.<limit_id> = [80, 95] # Codex premium limits (both of their windows)
///
///     [notify.limits.<account>]   # the same keys for one Claude Code account (`Accounts`, e.g. `corp`); a key
///     claude.week = [90]          # missing here comes from [notify.limits]
///
///     [telegram]
///     token_file = "~/.config/zagon/tg-bot-token"
///     chat_id = "123456789"       # the only chat the bot writes to and answers
///     commands = true             # answer /limits /sessions /today /week /day here (one host per bot)
///     api = "https://api.telegram.org"
///
///     [ntfy]
///     topic = ""                  # on = a topic is set
///     url = "https://ntfy.sh"
///
///     [summary]
///     engine = "claude"           # claude | codex | none
///     model = "haiku"
///     timeout = 120               # seconds; on failure or timeout the summary falls back to "none"
///     time = "20:00"              # when the service writes the day summary ("" = off; wins over [notify] summary_at)
public struct NotifyConfig: Sendable, Equatable {
    public var enabled = true
    /// Thresholds per limit category (`claude.five_hour`, `codex.week`, `codex.<limit_id>`…); missing = `defaultLimits`.
    public var limits: [String: [Double]] = [:]
    public static let defaultLimits: [Double] = [80, 95]
    public var limitReset = true
    /// `[limits] account`: the label of the default account where several accounts' limits are shown; nil = not set.
    public var limitsAccount: String?
    public var waitingMinutes = 10.0
    /// The wait before "waiting for you" when the session's background tasks still run (`Background`); 0 = never.
    public var waitingBackgroundMinutes = 60.0
    public var longWorkMinutes = 15.0
    /// Minutes after local midnight; nil = off.
    public var summaryAt: Int? = 20 * 60
    public var worklogAt: Int? = 19 * 60
    /// [start, end) in minutes after midnight, may wrap past midnight; nil = off.
    public var quiet: ClockRange? = ClockRange(start: 23 * 60, end: 8 * 60)
    public var timezone: String?
    public var lang = NotifyLang.auto

    public var telegramTokenFile: String?
    public var telegramChatId: String?
    public var telegramCommands = true
    public var telegramAPI = "https://api.telegram.org"

    public var ntfyURL = "https://ntfy.sh"
    public var ntfyTopic: String?

    public var summaryEngine = "claude"
    public var summaryModel = "haiku"
    public var summaryTimeout = 120.0

    public init() {}

    public static func load(_ paths: ZagonPaths) -> NotifyConfig {
        parse(Sys.readFile(paths.config).map { String(decoding: $0, as: UTF8.self) } ?? "", home: paths.home)
    }

    public static func parse(_ text: String, home: String) -> NotifyConfig {
        var c = NotifyConfig()
        func s(_ sec: String, _ k: String) -> String? { TOMLLite.string(in: text, section: sec, key: k) }
        func n(_ sec: String, _ k: String) -> Double? { TOMLLite.number(in: text, section: sec, key: k) }
        func b(_ sec: String, _ k: String) -> Bool? { TOMLLite.bool(in: text, section: sec, key: k) }
        func path(_ p: String?) -> String? {
            guard let p, !p.isEmpty else { return nil }
            return p.hasPrefix("~/") ? home + p.dropFirst() : p
        }
        if let v = b("notify", "enabled") { c.enabled = v }
        // `[notify.limits]` keys as they are, `[notify.limits.<account>]` ones as `<account>/<key>`.
        let sections = ["notify.limits"] + text.split(separator: "\n").compactMap { TOMLLite.header($0) }
            .filter { $0.hasPrefix("notify.limits.") && $0.count > 14 }
        for sec in sections {
            let prefix = sec == "notify.limits" ? "" : String(sec.dropFirst(14).filter { $0 != "\"" && $0 != "'" }) + "/"
            for k in TOMLLite.keys(in: text, section: sec) {
                guard let v = TOMLLite.numbers(in: text, section: sec, key: k) else { continue }
                c.limits[prefix + String(k.filter { $0 != "\"" && $0 != "'" })] =
                    Array(Set(v.filter { $0 >= 50 && $0 <= 100 && $0.truncatingRemainder(dividingBy: 5) == 0 })).sorted()
            }
        }
        if let v = s("limits", "account"), !v.isEmpty { c.limitsAccount = v }
        if let v = b("notify", "limit_reset") { c.limitReset = v }
        if let v = n("notify", "waiting_minutes") { c.waitingMinutes = v }
        if let v = n("notify", "waiting_background_minutes") { c.waitingBackgroundMinutes = v }
        if let v = n("notify", "long_work_minutes") { c.longWorkMinutes = v }
        if let v = s("notify", "summary_at") { c.summaryAt = clock(v) }
        if let v = s("notify", "worklog_at") { c.worklogAt = clock(v) }
        if let v = s("notify", "quiet") {
            let p = v.split(separator: "-").map { clock(String($0)) }
            c.quiet = p.count == 2 && p[0] != nil && p[1] != nil && p[0] != p[1] ? ClockRange(start: p[0]!, end: p[1]!) : nil
        }
        if let v = s("notify", "lang").flatMap(NotifyLang.init(rawValue:)) { c.lang = v }
        c.timezone = Settings.timezone(in: text)  // top-level `timezone`, or the older `[notify] timezone`
        c.telegramTokenFile = path(s("telegram", "token_file"))
        if let v = s("telegram", "chat_id") ?? n("telegram", "chat_id").map({ String(Int64($0)) }), !v.isEmpty { c.telegramChatId = v }
        if let v = b("telegram", "commands") { c.telegramCommands = v }
        if let v = s("telegram", "api"), !v.isEmpty { c.telegramAPI = v }
        if let v = s("ntfy", "url"), !v.isEmpty { c.ntfyURL = v }
        if let v = s("ntfy", "topic"), !v.isEmpty { c.ntfyTopic = v }
        if let v = s("summary", "engine") { c.summaryEngine = v }
        if let v = s("summary", "model"), !v.isEmpty { c.summaryModel = v }
        if let v = n("summary", "timeout"), v > 0 { c.summaryTimeout = v }
        if let v = s("summary", "time") { c.summaryAt = clock(v) }
        return c
    }

    /// Thresholds of a limit category, ascending; empty = no notifications for it. An account other than the default one
    /// takes its own `[notify.limits.<account>]` key first.
    public func thresholds(_ category: String, account: String = Accounts.defaultName) -> [Double] {
        (account == Accounts.defaultName ? nil : limits[account + "/" + category]) ?? limits[category] ?? NotifyConfig.defaultLimits
    }

    /// Category of a stored limit window: `claude.five_hour`, `claude.week`, `codex.five_hour`, `codex.week`,
    /// `codex.<limit_id>` (Codex stores premium windows as `<limit_id>:primary|secondary`).
    public static func limitCategory(_ tool: ToolKind, _ window: String) -> String {
        switch window {
        case "five_hour", "primary": return "\(tool.rawValue).five_hour"
        case "seven_day", "secondary": return "\(tool.rawValue).week"
        default: return "\(tool.rawValue)." + (window.split(separator: ":").first.map(String.init) ?? window)
        }
    }

    /// `HH:MM` → minutes after midnight.
    static func clock(_ s: String) -> Int? {
        let p = s.trimmingSpaces.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    /// The configured channels (Telegram needs the token file and chat id, ntfy a topic; both need curl).
    public func channels(_ paths: ZagonPaths, searchPath: String? = Sys.env("PATH")) -> [any Channel] {
        let curl = Curl(searchPath: searchPath)
        let all: [(any Channel)?] = [Telegram(self, curl: curl, tmpDir: paths.dir + "/run"), Ntfy(self, curl: curl)]
        return all.compactMap { $0 }
    }

}

public struct ClockRange: Sendable, Equatable {
    public var start: Int, end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
    public func contains(_ minute: Int) -> Bool { start < end ? minute >= start && minute < end : minute >= start || minute < end }
}

extension TOMLLite {
    /// Value text without a trailing `# comment` (strings are left to `parseValue`).
    static func bare(_ text: String, _ section: String, _ key: String) -> Substring? {
        guard let r = raw(in: text, section: section, key: key) else { return nil }
        return (r.firstIndex(of: "#").map { r[..<$0] } ?? r).trimmingSpaces
    }

    public static func number(in text: String, section: String, key: String) -> Double? {
        bare(text, section, key).flatMap { Double($0.replacingUnderscores) }
    }

    public static func bool(in text: String, section: String, key: String) -> Bool? {
        switch bare(text, section, key) { case "true": return true; case "false": return false; default: return nil }
    }

    /// Keys of `[section]` in file order (quotes kept as written).
    public static func keys(in text: String, section: String) -> [String] {
        var current = "", out: [String] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingSpaces
            if t.hasPrefix("[") { current = header(t) ?? "\u{0}"; continue }
            guard current == section, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            out.append(String(t[..<eq].trimmingSpaces))
        }
        return out
    }

    /// One-line array of numbers, e.g. `[80, 95]`.
    public static func numbers(in text: String, section: String, key: String) -> [Double]? {
        guard let v = bare(text, section, key), v.hasPrefix("["), v.hasSuffix("]") else { return nil }
        let items = v.dropFirst().dropLast().split(separator: ",").map { $0.trimmingSpaces }.filter { !$0.isEmpty }
        let nums = items.compactMap { Double($0.replacingUnderscores) }
        return nums.count == items.count ? nums : nil
    }
}

extension Substring {
    var replacingUnderscores: String { String(filter { $0 != "_" }) }
}
