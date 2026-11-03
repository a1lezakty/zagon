import Foundation

public enum Lang: String, CaseIterable, Sendable {
    case en, ru

    /// First of the user's preferred languages we have a translation for (per-app language included).
    public static func preferred(_ languages: [String] = Locale.preferredLanguages) -> Lang {
        for l in languages {
            if let hit = Lang(rawValue: String(l.prefix { $0 != "-" && $0 != "_" }).lowercased()) { return hit }
        }
        return .en
    }
}

/// UI strings from `Strings`; a key missing in the language falls back to English, then to the key itself.
public struct L10n: Sendable {
    public let lang: Lang
    let table: [String: String]

    public init(_ lang: Lang) {
        self.lang = lang
        table = lang == .ru ? Strings.ru : Strings.en
    }

    public func callAsFunction(_ key: String, _ args: String...) -> String { format(key, args) }

    func format(_ key: String, _ args: [String]) -> String {
        var s = table[key] ?? Strings.en[key] ?? key
        for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "{\(i)}", with: a) }
        return s
    }

    /// Text around a single `{0}` that the view renders in bold.
    public func split(_ key: String, _ others: String...) -> (before: String, after: String) {
        var s = table[key] ?? Strings.en[key] ?? key
        for (i, a) in others.enumerated() { s = s.replacingOccurrences(of: "{\(i + 1)}", with: a) }
        guard let r = s.range(of: "{0}") else { return (s, "") }
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
    }

    /// `key.one` / `key.few` / `key.many` by the language's plural rule; `{0}` = n, then `args` as `{1}`, ….
    public func plural(_ key: String, _ n: Int, _ args: String...) -> String {
        let form: String
        switch lang {
        case .en: form = n == 1 ? "one" : "many"
        case .ru:
            let d = n % 10, h = n % 100
            form = d == 1 && h != 11 ? "one" : (2...4).contains(d) && !(12...14).contains(h) ? "few" : "many"
        }
        return format("\(key).\(form)", [String(n)] + args)
    }
}

/// Formatting context shared by all view models: language, calendar (Monday first) and the current time.
public struct Fmt: Sendable {
    public let t: L10n
    public let calendar: Calendar
    public let now: Date
    let locale: Locale

    public init(lang: Lang, timeZone: TimeZone = .current, now: Date) {
        t = L10n(lang)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        calendar = c
        locale = Locale(identifier: lang == .ru ? "ru_RU" : "en_US")
        self.now = now
    }

    public var lang: Lang { t.lang }

    // MARK: numbers

    func decimal(_ v: Double, digits: Int) -> String {
        let s = String(format: "%.\(digits)f", v)
        return lang == .ru ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    func grouped(_ n: Int) -> String {
        let sep = lang == .ru ? "\u{00A0}" : ","
        var digits = Array(String(abs(n))), out = ""
        while digits.count > 3 { out = sep + String(digits.suffix(3)) + out; digits.removeLast(3) }
        return (n < 0 ? "-" : "") + String(digits) + out
    }

    /// 940 · 640K · 18.4M · 118M · 1.2B (ru: тыс / млн / млрд).
    public func tokens(_ n: Int) -> String {
        let v = Double(n)
        func scaled(_ unit: Double, _ key: String) -> String {
            let x = v / unit
            return t(key, x >= 99.95 ? String(Int(x.rounded())) : decimal(x, digits: 1))
        }
        // Units switch where rounding would print "1000K" / "1000M".
        if v >= 999.5e6 { return scaled(1e9, "num.billion") }
        if v >= 999.5e3 { return scaled(1e6, "num.million") }
        if v >= 1e3 { return t("num.thousand", String(Int((v / 1e3).rounded()))) }
        return String(n)
    }

    /// Whole dollars at API prices: $212, $1,600 (ru $1 600); under a dollar "<$1".
    public func cost(_ usd: Double) -> String {
        if usd > 0 && usd < 1 { return "<$1" }
        return "$" + grouped(Int(usd.rounded()))
    }

    public func pct(_ v: Double) -> String { t("num.pct", String(Int(v.rounded()))) }

    /// "+12 %" / "−22 %" (true minus sign).
    public func delta(_ now: Double, _ before: Double) -> String {
        guard before > 0 else { return t("delta.new") }
        let d = Int(((now / before - 1) * 100).rounded())
        return (d > 0 ? "+" : d < 0 ? "\u{2212}" : "±") + pct(Double(abs(d)))
    }

    // MARK: durations

    /// "agent time X" under "sessions worked" when the sessions' summed time is a minute or more over the wall clock.
    public func agentTime(_ t: Totals) -> String? { t.agentSec - t.sessionSec < 60 ? nil : self.t("stat.agentTime", duration(t.agentSec)) }

    /// 41m · 1h 05m · 7h 20m · 2d 21h. Below a minute rounds up to 1m when positive.
    public func duration(_ sec: Double) -> String {
        let m = max(0, Int((sec / 60).rounded()))
        if m >= 48 * 60 { return t("dur.dh", String(m / 1440), String(m % 1440 / 60)) }
        if m >= 60 { return t("dur.hm", String(m / 60), pad2(m % 60)) }
        return t("dur.m", String(m == 0 && sec > 0 ? 1 : m))
    }

    /// Whole hours for compact cells: "6h", under an hour "<1h"; zero = "—".
    public func hours(_ h: Double) -> String { h <= 0 ? "—" : t("dur.h", h < 1 ? "<1" : String(Int(h))) }

    func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }

    // MARK: dates

    func formatted(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        var s = f.string(from: d)
        if lang == .ru { s = s.replacingOccurrences(of: ".", with: "") }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    public func time(_ d: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return pad2(c.hour ?? 0) + ":" + pad2(c.minute ?? 0)
    }

    /// 13:40–14:20; an end at the next midnight reads 24:00.
    public func timeSpan(_ a: Date, _ b: Date) -> String {
        time(a) + "–" + (b > a && calendar.startOfDay(for: b) == b ? "24:00" : time(b))
    }

    /// Thursday, October 29 / Четверг, 29 октября
    public func dayTitle(_ d: Date) -> String { formatted(d, lang == .ru ? "EEEE, d MMMM" : "EEEE, MMMM d") }
    /// Thu, October 29
    public func dayTitleShortWeekday(_ d: Date) -> String { formatted(d, lang == .ru ? "EEE, d MMMM" : "EEE, MMMM d") }
    /// October 2026
    public func monthTitle(_ d: Date) -> String { formatted(d, "LLLL yyyy") }
    /// October 1 / 1 октября
    public func dayMonth(_ d: Date) -> String { formatted(d, lang == .ru ? "d MMMM" : "MMMM d") }
    /// Oct 30 / 30 окт
    public func shortDay(_ d: Date) -> String { formatted(d, lang == .ru ? "d MMM" : "MMM d").lowercasedFirstIf(lang == .ru) }
    /// Oct 29 · Oct 29–30 · Oct 31–Nov 2 (ru: 29 окт · 29–30 окт · 31 окт–2 ноя).
    public func dayRange(_ a: Date, _ b: Date) -> String {
        if calendar.isDate(a, inSameDayAs: b) { return shortDay(a) }
        guard calendar.isDate(a, equalTo: b, toGranularity: .month) else { return shortDay(a) + "–" + shortDay(b) }
        let da = String(calendar.component(.day, from: a)), db = String(calendar.component(.day, from: b))
        return lang == .ru ? da + "–" + shortDay(b) : shortDay(a) + "–" + db
    }
    /// Mon 26
    public func weekdayDay(_ d: Date) -> String { formatted(d, "EEE d") }
    /// Mon
    public func weekday(_ d: Date) -> String { formatted(d, "EEE") }
    /// Thursday (ru: четверг) — used inside sentences.
    public func weekdayName(_ d: Date) -> String {
        let s = formatted(d, "EEEE")
        return lang == .ru ? s.lowercased() : s
    }
    /// October 26 – November 1 / 26 октября — 1 ноября
    public func weekTitle(_ start: Date) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start)!
        let p = lang == .ru ? "d MMMM" : "MMMM d"
        return formatted(start, p) + (lang == .ru ? " — " : " – ") + formatted(end, p).lowercasedFirstIf(lang == .ru)
    }

    /// "at 14:20" today, "Mon 09:00" on another day.
    public func resetMoment(_ d: Date) -> String {
        calendar.isDate(d, inSameDayAs: now) ? t("at.time", time(d)) : weekday(d).lowercasedFirstIf(lang == .ru) + " " + time(d)
    }

    public func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }
    public func addDays(_ n: Int, to d: Date) -> Date { calendar.date(byAdding: .day, value: n, to: d)! }
    public func startOfWeek(_ d: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: d)!.start
    }
    public func startOfMonth(_ d: Date) -> Date { calendar.dateInterval(of: .month, for: d)!.start }
    public func addMonths(_ n: Int, to d: Date) -> Date { calendar.date(byAdding: .month, value: n, to: d)! }
}

extension String {
    func lowercasedFirstIf(_ yes: Bool) -> String { yes ? prefix(1).lowercased() + dropFirst() : self }
}

/// Design palette (dark). 0xRRGGBB.
public enum Palette {
    public static let ground: UInt32 = 0x161618
    public static let sidebar: UInt32 = 0x1B1B1E
    public static let card: UInt32 = 0x1F1F22
    public static let popover: UInt32 = 0x222225
    public static let inset: UInt32 = 0x19191B
    public static let border: UInt32 = 0x2E2E33
    public static let control: UInt32 = 0x36363B
    public static let text: UInt32 = 0xF2F2F4
    public static let body: UInt32 = 0xC9C9CF
    public static let secondary: UInt32 = 0xA9A9B0
    public static let muted: UInt32 = 0x8E8E96
    public static let track: UInt32 = 0x34343A
    public static let fiveHour: UInt32 = 0xF5A524
    public static let week: UInt32 = 0x6EA8FE
    public static let working: UInt32 = 0x34C3A0
    public static let waiting: UInt32 = 0xFF6B5E
    public static let violet: UInt32 = 0xB48CFF
    public static let good: UInt32 = 0x5FD9B8
    public static let bad: UInt32 = 0xFF8C80
    public static let link: UInt32 = 0x9CC3FF
    public static let selection: UInt32 = 0x2D3A52
    /// Projects, models, tasks in display order; the fifth colour also serves "other".
    public static let series: [UInt32] = [week, fiveHour, working, violet, muted]
    public static func series(_ i: Int) -> UInt32 { series[min(i, series.count - 1)] }
    /// Calendar heat levels 0…5.
    public static let heat: [UInt32] = [0x232327, 0x1E2B40, 0x24406A, 0x2E5A9A, 0x4A7FD0, 0x6EA8FE]
}
