import Foundation

/// Time zones for the picker: names with their UTC offset, and a search over the known ones.
public enum Zones {
    /// "UTC+5", "UTC+5:30", "UTC−3:30", "UTC" at `d` (true minus sign).
    public static func offset(_ z: TimeZone, at d: Date) -> String {
        let s = z.secondsFromGMT(for: d), m = abs(s) / 60
        guard s != 0 else { return "UTC" }
        return "UTC" + (s < 0 ? "−" : "+") + "\(m / 60)" + (m % 60 == 0 ? "" : ":" + (m % 60 < 10 ? "0" : "") + "\(m % 60)")
    }

    /// "Asia/Kolkata · UTC+5:30"; UTC itself is just "UTC".
    public static func label(_ z: TimeZone, at d: Date) -> String {
        ["UTC", "GMT"].contains(z.identifier) ? offset(z, at: d) : z.identifier.replacingOccurrences(of: "_", with: " ") + " · " + offset(z, at: d)
    }

    /// Tokens are kept by UTC hour: days line up with them only when the offset is whole hours.
    public static func wholeHours(_ z: TimeZone, at d: Date) -> Bool { z.secondsFromGMT(for: d) % 3600 == 0 }

    static func plain(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "−", with: "-")
    }

    /// Searchable names of each known zone: the id and its English and Russian names ("Moscow Time", "Москва").
    static let names: [(id: String, zone: TimeZone, text: String)] = TimeZone.knownTimeZoneIdentifiers.compactMap { id in
        guard let z = TimeZone(identifier: id) else { return nil }
        let names = [Locale(identifier: "en"), Locale(identifier: "ru")].flatMap { l in
            [z.localizedName(for: .generic, locale: l), z.localizedName(for: .standard, locale: l)].compactMap { $0 }
        }
        return (id, z, plain(([id] + names).joined(separator: " ")))
    }

    /// Known zones whose names hold every word of `text` (case, "_" and the minus sign ignored), west to east. A word
    /// like "UTC+5" is an offset: it finds +5 and +5:30, not +15.
    public static func search(_ text: String, at d: Date) -> [String] {
        let words = plain(text).split(separator: " ").map { ["utc+0", "utc-0", "gmt+0"].contains($0) ? "utc" : String($0) }
        return names.compactMap { n -> (Int, String)? in
            let off = plain(offset(n.zone, at: d))
            return words.allSatisfy { matches($0, text: n.text, offset: off) } ? (n.zone.secondsFromGMT(for: d), n.id) : nil
        }.sorted { $0 < $1 }.map(\.1)
    }

    /// An offset word ("utc+5") is the offset itself or its hours ("utc+5:30"); any other word is part of a name.
    static func matches(_ w: String, text: String, offset: String) -> Bool {
        guard w.hasPrefix("utc") else { return text.contains(w) }
        return offset == w || offset.hasPrefix(w + ":")
    }
}
