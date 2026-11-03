#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation  // macOS: Locale.preferredLanguages
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Short Russian wording for notifications and bot replies (local time zone).
enum Ru {
    static let weekdays = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]
    static let months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября",
                         "ноября", "декабря"]

    static func local(_ t: Double) -> tm {
        var s = time_t(t.rounded(.down)), v = tm()
        localtime_r(&s, &v)
        return v
    }

    static func p2(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }

    /// `14:20`
    static func clock(_ t: Double) -> String { let v = local(t); return "\(p2(v.tm_hour)):\(p2(v.tm_min))" }

    /// `в 14:20` today, `пн 09:00` within a week, else `3 ноября 09:00`.
    static func when(_ t: Double, now: Double) -> String {
        if Time.dayString(t) == Time.dayString(now) { return "в " + clock(t) }
        let v = local(t)
        if t > now && t - now < 6 * 86400 { return weekdays[Int(v.tm_wday)] + " " + clock(t) }
        return "\(v.tm_mday) \(months[Int(v.tm_mon)]) " + clock(t)
    }

    /// `Чт, 29 октября` for `YYYY-MM-DD`.
    static func date(_ day: String) -> String {
        guard let (s, _) = Time.dayBounds(day) else { return day }
        let v = local(s + 3600 * 12)
        let wd = weekdays[Int(v.tm_wday)]
        return wd.prefix(1).uppercased() + wd.dropFirst() + ", \(v.tm_mday) \(months[Int(v.tm_mon)])"
    }

    /// `12 мин`, `1 ч 50 м`, `40 ч`.
    static func dur(_ sec: Double) -> String {
        let m = max(0, Int((sec / 60).rounded()))
        if m < 60 { return "\(m) мин" }
        return m % 60 == 0 ? "\(m / 60) ч" : "\(m / 60) ч \(m % 60) м"
    }

    /// `62 %`
    static func pct(_ p: Double) -> String { "\(Int(p.rounded())) %" }

    /// `950`, `12 тыс.`, `31,2 млн`, `1,2 млрд`.
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return "\(n / 1000) тыс."
        case ..<1_000_000_000: return one(Double(n) / 1e6, ",") + " млн"
        default: return one(Double(n) / 1e9, ",") + " млрд"
        }
    }

    /// One decimal place unless whole or 100 and more: `31,2`, `12`.
    static func one(_ d: Double, _ point: String) -> String {
        let v = (d * 10).rounded() / 10
        return v >= 100 || v == v.rounded() ? "\(Int(v))" : "\(Int(v))\(point)\(Int((v * 10).rounded()) % 10)"
    }

    static func tool(_ t: ToolKind) -> String {
        switch t { case .claude: "Claude"; case .codex: "Codex"; case .cursor: "Cursor" }
    }
    static func tool(_ t: String) -> String { ToolKind(rawValue: t).map(tool) ?? t }

    /// `5 ч` / `неделя` / `N ч` from the window length.
    static func window(_ s: LimitSnapshot) -> String {
        let m = s.windowMinutes ?? Notifier.defaultMinutes(s.window)
        if m >= 10080 { return "неделя" }
        return m % 60 == 0 ? "\(m / 60) ч" : "\(m) мин"
    }

    /// `project — title`, either part optional.
    static func name(_ project: String?, _ title: String?, none: String = "сессия") -> String {
        let p = project.flatMap { $0.isEmpty ? nil : $0 }, t = title.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        switch (p, t) {
        case let (p?, t?): return "\(p) — \(t)"
        case let (p?, nil): return p
        case let (nil, t?): return t
        default: return none
        }
    }
}

/// Language of notifications, bot replies and the day summary (`[notify] lang`).
public enum NotifyLang: String, Sendable {
    case auto, ru, en

    /// `auto` follows the system's language (macOS: Locale.preferredLanguages; elsewhere LC_ALL, LC_MESSAGES, LANG):
    /// Russian for `ru…`, English for anything else.
    public func words(system: [String]? = nil) -> Words {
        switch self {
        case .ru: return Words(en: false)
        case .en: return Words(en: true)
        case .auto: return Words(en: !((system ?? NotifyLang.systemLanguages()).first?.hasPrefix("ru") ?? false))
        }
    }

    static func systemLanguages(_ env: (String) -> String? = Sys.env) -> [String] {
        #if os(macOS)
        return Locale.preferredLanguages
        #else
        return ["LC_ALL", "LC_MESSAGES", "LANG"].compactMap(env).filter { !$0.isEmpty }.prefix(1).map { $0 }
        #endif
    }
}

/// The wording of one language: `Ru`, or English with the same numbers and formats; `t(ru, en)` picks a text.
public struct Words: Sendable, Equatable {
    public var en: Bool
    public static let ru = Words(en: false), english = Words(en: true)

    public func t(_ ru: String, _ en: String) -> String { self.en ? en : ru }

    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                         "November", "December"]

    func clock(_ t: Double) -> String { Ru.clock(t) }

    /// `at 14:20` today, `Mon 09:00` within a week, else `November 3 09:00`.
    func when(_ t: Double, now: Double) -> String {
        guard en else { return Ru.when(t, now: now) }
        if Time.dayString(t) == Time.dayString(now) { return "at " + Ru.clock(t) }
        let v = Ru.local(t)
        if t > now && t - now < 6 * 86400 { return Self.weekdays[Int(v.tm_wday)] + " " + Ru.clock(t) }
        return "\(Self.months[Int(v.tm_mon)]) \(v.tm_mday) " + Ru.clock(t)
    }

    /// `Thu, October 29` for `YYYY-MM-DD`.
    func date(_ day: String) -> String {
        guard en else { return Ru.date(day) }
        guard let (s, _) = Time.dayBounds(day) else { return day }
        let v = Ru.local(s + 3600 * 12)
        return "\(Self.weekdays[Int(v.tm_wday)]), \(Self.months[Int(v.tm_mon)]) \(v.tm_mday)"
    }

    /// `чт` / `Thu`.
    func weekday(_ day: String) -> String { en ? String(date(day).prefix(3)) : Ru.date(day).prefix(2).lowercased() }

    /// " (агентного времени X)" when the sessions' summed time is a minute or more over the wall-clock time they worked.
    func agent(_ worked: Double, _ sum: Double) -> String {
        sum - worked < 60 ? "" : t(" (агентного времени \(dur(sum)))", " (agent time \(dur(sum)))")
    }

    /// `12 min`, `1 h 50 min`, `40 h`.
    func dur(_ sec: Double) -> String {
        guard en else { return Ru.dur(sec) }
        let m = max(0, Int((sec / 60).rounded()))
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// `62%`.
    func pct(_ p: Double) -> String { en ? "\(Int(p.rounded()))%" : Ru.pct(p) }

    /// `950`, `12K`, `31.2M`, `1.2B`.
    func tokens(_ n: Int) -> String {
        guard en else { return Ru.tokens(n) }
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return "\(n / 1000)K"
        case ..<1_000_000_000: return Ru.one(Double(n) / 1e6, ".") + "M"
        default: return Ru.one(Double(n) / 1e9, ".") + "B"
        }
    }

    func tool(_ t: ToolKind) -> String { Ru.tool(t) }
    /// `Claude (corp)`: the tool and the label of the account (`Accounts.labeled`), nil = the tool alone.
    func tool(_ t: ToolKind, account: String?) -> String { Ru.tool(t) + (account.map { " (\($0))" } ?? "") }
    func tool(_ t: String) -> String { Ru.tool(t) }

    /// `5 h` / `weekly` / `N min` from the window length.
    func window(_ s: LimitSnapshot) -> String {
        guard en else { return Ru.window(s) }
        let m = s.windowMinutes ?? Notifier.defaultMinutes(s.window)
        if m >= 10080 { return "weekly" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m) min"
    }

    func name(_ project: String?, _ title: String?) -> String { Ru.name(project, title, none: t("сессия", "session")) }
}
