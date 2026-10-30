/// Just enough TOML to read and set one string key in a `[section]` of `config.toml` while leaving every other
/// line of the file as it is.
public enum TOMLLite {
    public static func string(at path: String, section: String, key: String) -> String? {
        guard let b = Sys.readFile(path) else { return nil }
        return string(in: String(decoding: b, as: UTF8.self), section: section, key: key)
    }

    public static func string(in text: String, section: String, key: String) -> String? {
        raw(in: text, section: section, key: key).flatMap(parseValue)
    }

    /// Value text after `=` (not decoded), e.g. `false` or `"a b"`.
    public static func raw(in text: String, section: String, key: String) -> Substring? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let i = find(lines, section: section, key: key) else { return nil }
        let line = lines[i]
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return line[line.index(after: eq)...].trimmingSpaces
    }

    /// Whether the file has a `[section]` header.
    public static func hasSection(_ text: String, _ section: String) -> Bool {
        text.split(separator: "\n").contains { header($0) == section }
    }

    /// Sets (or with nil removes) `key` in `[section]` (`""` = top level); appends the section if missing. Other
    /// lines are untouched.
    public static func setting(_ text: String, section: String, key: String, to value: String?) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let entry = value.map { "\(key) = " + quote($0) }
        if let i = find(lines.map { Substring($0) }, section: section, key: key) {
            if let entry { lines[i] = entry } else { lines.remove(at: i) }
            return lines.joined(separator: "\n")
        }
        guard let entry else { return text }
        if section.isEmpty {
            // Top-level keys go before the first `[section]`.
            if let h = lines.firstIndex(where: { header($0) != nil }) {
                lines.insert(contentsOf: [entry, ""], at: h)
                return lines.joined(separator: "\n")
            }
            return text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + entry + "\n"
        }
        if let h = lines.firstIndex(where: { header($0) == section }) {
            lines.insert(entry, at: h + 1)
            return lines.joined(separator: "\n")
        }
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        return out + "[\(section)]\n\(entry)\n"
    }

    static func header<S: StringProtocol>(_ line: S) -> String? {
        let t = line.trimmingSpaces
        guard t.hasPrefix("["), !t.hasPrefix("[["), let close = t.firstIndex(of: "]") else { return nil }
        return String(t[t.index(after: t.startIndex)..<close].trimmingSpaces)
    }

    static func find(_ lines: [Substring], section: String, key: String) -> Int? {
        var current = ""
        for (i, line) in lines.enumerated() {
            let t = line.trimmingSpaces
            if t.hasPrefix("[") { current = header(t) ?? "\u{0}"; continue }
            guard current == section, let eq = t.firstIndex(of: "=") else { continue }
            if t[..<eq].trimmingSpaces == key { return i }
        }
        return nil
    }

    static func parseValue(_ s: Substring) -> String? {
        if s.hasPrefix("'") {
            let body = s.dropFirst()
            return body.firstIndex(of: "'").map { String(body[..<$0]) }
        }
        guard s.hasPrefix("\"") else { return nil }
        var out = "", it = s.dropFirst().unicodeScalars.makeIterator()
        while let c = it.next() {
            switch c {
            case "\"": return out
            case "\\":
                guard let e = it.next() else { return nil }
                switch e {
                case "n": out += "\n"
                case "t": out += "\t"
                case "r": out += "\r"
                case "b": out += "\u{08}"
                case "f": out += "\u{0C}"
                case "\"", "\\": out.unicodeScalars.append(e)
                case "u", "U":
                    var hex = ""
                    for _ in 0..<(e == "u" ? 4 : 8) { guard let h = it.next() else { return nil }; hex.unicodeScalars.append(h) }
                    guard let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else { return nil }
                    out.unicodeScalars.append(u)
                default: return nil
                }
            default: out.unicodeScalars.append(c)
            }
        }
        return nil
    }

    /// TOML basic string.
    public static func quote(_ v: String) -> String {
        var s = "\""
        for u in v.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\t": s += "\\t"
            case "\r": s += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    let h = String(u.value, radix: 16)
                    s += "\\u" + String(repeating: "0", count: 4 - h.count) + h
                } else { s.unicodeScalars.append(u) }
            }
        }
        return s + "\""
    }
}

extension StringProtocol {
    var trimmingSpaces: Substring {
        let s = self[...].drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
        var e = s.endIndex
        while e > s.startIndex, " \t\r".contains(s[s.index(before: e)]) { e = s.index(before: e) }
        return Substring(s[s.startIndex..<e])
    }
}
