import Foundation
import ZagonCore

/// Limit notification settings in `~/.zagon/config.toml` (keys of the core's notifier):
///
///     [notify]
///     limit_reset = true
///     [notify.limits]
///     claude.five_hour = [80, 95]    # 50…100 in steps of 5, [] = off, missing = [80, 95]
///
/// Editing touches only these lines; everything else in the file stays as it is.
public struct NotifySettings: Sendable, Equatable {
    public static let categories = ["claude.five_hour", "claude.week", "codex.five_hour", "codex.week"]
    public static let steps = Array(stride(from: 50, through: 100, by: 5))
    public static let defaults = [80, 95]

    public var thresholds: [String: [Int]]
    public var limitReset: Bool

    public init(thresholds: [String: [Int]] = [:], limitReset: Bool = true) {
        self.thresholds = thresholds; self.limitReset = limitReset
    }

    public func thresholds(_ category: String) -> [Int] { thresholds[category] ?? Self.defaults }

    public mutating func toggle(_ category: String, _ value: Int) {
        set(category, value, on: !thresholds(category).contains(value))
    }

    /// Turns one threshold on or off (what the user saw and clicked, not a flip of the file's current state).
    public mutating func set(_ category: String, _ value: Int, on: Bool) {
        var t = Set(thresholds(category))
        if on { t.insert(value) } else { t.remove(value) }
        thresholds[category] = t.sorted()
    }

    /// `~/.zagon/config.toml`.
    public static var configPath: String { ZagonPaths().config }

    /// The settings in `path` (missing file = defaults); throws when the file exists but cannot be read.
    public static func load(_ path: String) throws -> NotifySettings {
        parse(try read(path, strict: false))
    }

    /// Writes these settings into the file, keeping every other line, its mode and a symlink (0600 when new). A file
    /// that cannot be read, or is not UTF-8, is left alone.
    public func save(_ path: String) throws {
        // A dangling symlink would be replaced by a plain file.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil, Sys.realPath(path) == nil {
            throw CocoaError(.fileNoSuchFile)
        }
        let text = try Self.read(path, strict: true)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard Sys.writeFile(path, Array(apply(to: text).utf8), mode: 0o600) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func read(_ path: String, strict: Bool) throws -> String {
        guard let bytes = Sys.readFile(path) else {
            if FileManager.default.fileExists(atPath: path) { throw CocoaError(.fileReadNoPermission) }
            return ""
        }
        if strict {
            guard let text = String(bytes: bytes, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return text
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "Claude · 5 hours"
    public static func title(_ category: String, _ f: Fmt) -> String {
        let parts = category.split(separator: ".")
        let tool = parts.first == "codex" ? "Codex" : "Claude"
        return tool + " · " + f.t(parts.last == "week" ? "limit.week" : "limit.five").lowercasedFirstIf(f.lang == .ru)
    }

    /// Read exactly as the notifier reads it (`NotifyConfig`).
    public static func parse(_ toml: String) -> NotifySettings {
        let c = NotifyConfig.parse(toml, home: "")
        var s = NotifySettings(limitReset: c.limitReset)
        for cat in categories {
            if let v = c.limits[cat] { s.thresholds[cat] = Set(v.map { Int($0) }.filter { steps.contains($0) }).sorted() }
        }
        return s
    }

    /// The file with these settings written in.
    /// Only settings that differ from what the file says are written.
    public func apply(to toml: String) -> String {
        let was = Self.parse(toml)
        var out = toml
        if limitReset != was.limitReset { out = TOMLLines.set(out, "notify", "limit_reset", limitReset ? "true" : "false") }
        for c in Self.categories where thresholds[c] != nil && thresholds(c) != was.thresholds(c) {
            out = TOMLLines.set(out, "notify.limits", c, "[" + thresholds(c).map(String.init).joined(separator: ", ") + "]")
        }
        return out
    }
}

/// Raw `key = value` lines inside `[section]` headers, matched as the core's TOMLLite / NotifyConfig read them: keys
/// literally, quotes stripped only in `notify.limits`; any other `[` line ends a section. Setting a key leaves one line
/// for it (the first, with its key spelling and trailing comment), so the notifier reads what was set. Multi-line arrays
/// are not supported.
enum TOMLLines {
    static func header(_ line: Substring) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") else { return nil }
        guard !t.hasPrefix("[["), let close = t.firstIndex(of: "]") else { return "\u{0}" }
        return t[t.index(after: t.startIndex)..<close].trimmingCharacters(in: .whitespaces)
    }

    static func find(_ lines: [Substring], _ section: String, _ key: String) -> [Int] {
        var current = "", found: [Int] = []
        for (i, line) in lines.enumerated() {
            if let h = header(line) { current = h; continue }
            guard current == section, let eq = line.firstIndex(of: "=") else { continue }
            var k = line[..<eq].trimmingCharacters(in: .whitespaces)
            if section == "notify.limits" { k = k.filter { $0 != "\"" && $0 != "'" } }
            if k == key { found.append(i) }
        }
        return found
    }

    /// Replaces the key's line, or adds it under the section header, or appends the section.
    static func set(_ text: String, _ section: String, _ key: String, _ raw: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let entry = Substring("\(key) = \(raw)")
        let found = find(lines, section, key)
        if let i = found.first, let eq = lines[i].firstIndex(of: "=") {
            let old = lines[i]
            let comment = old[eq...].firstIndex(of: "#").map { " " + old[$0...] } ?? ""
            lines[i] = Substring(old[..<eq].trimmingCharacters(in: .whitespaces) + " = " + raw + comment)
            for j in found.dropFirst().reversed() { lines.remove(at: j) }
        } else if let h = lines.firstIndex(where: { header($0) == section }) {
            lines.insert(entry, at: h + 1)
        } else {
            if let last = lines.last, last.isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += ["[\(section)]", entry, ""]
        }
        return lines.joined(separator: "\n")
    }
}
