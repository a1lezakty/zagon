/// Order-preserving JSON value for editing user config files (`settings.json`, `hooks.json`) and for the small
/// spool lines. Numbers keep their source text, so a rewrite does not change `1.0` into `1`.
public enum JValue: Equatable, Sendable {
    case null, bool(Bool), number(String), string(String), array([JValue]), object([Member])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JValue
        public init(_ key: String, _ value: JValue) { self.key = key; self.value = value }
    }

    public subscript(key: String) -> JValue? {
        get { if case .object(let m) = self { return m.first { $0.key == key }?.value }; return nil }
        set {
            guard case .object(var m) = self else { return }
            if let i = m.firstIndex(where: { $0.key == key }) {
                if let newValue { m[i].value = newValue } else { m.remove(at: i) }
            } else if let newValue { m.append(Member(key, newValue)) }
            self = .object(m)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var array: [JValue]? { if case .array(let a) = self { return a }; return nil }
    public var double: Double? { if case .number(let n) = self { return Double(n) }; return nil }

    // MARK: parsing

    /// Parses a complete document; nil on any syntax error, trailing garbage or nesting deeper than `maxDepth`.
    public static func parse(_ bytes: [UInt8], maxDepth: Int = 256) -> JValue? {
        bytes.withUnsafeBufferPointer { b in
            var p = Parser(b: b, maxDepth: maxDepth)
            guard let v = p.value(0) else { return nil }
            p.ws()
            return p.i == b.count ? v : nil
        }
    }

    public static func parse(_ s: String) -> JValue? { parse(Array(s.utf8)) }

    /// Top-level string members of an object whose key is in `keys`. Other values (prompts, tool inputs) are skipped
    /// without being decoded. Nil if the input is not a JSON object.
    public static func topLevelStrings(_ bytes: [UInt8], keys: Set<String>, maxDepth: Int = 256) -> [String: String]? {
        bytes.withUnsafeBufferPointer { b in
            var p = Parser(b: b, maxDepth: maxDepth)
            p.ws()
            guard p.eat(0x7B) else { return nil }
            var out: [String: String] = [:]
            p.ws()
            if p.eat(0x7D) { return out }
            while true {
                p.ws()
                guard let k = p.str() else { return nil }
                p.ws()
                guard p.eat(0x3A) else { return nil }
                p.ws()
                if keys.contains(k), p.peek == 0x22 {
                    guard let v = p.str() else { return nil }
                    out[k] = v
                } else {
                    guard p.skip(1) else { return nil }
                }
                p.ws()
                if p.eat(0x2C) { continue }
                return p.eat(0x7D) ? out : nil
            }
        }
    }

    /// The keys of a top-level object, values skipped unparsed; nil if `bytes` is not one.
    public static func topLevelKeys(_ bytes: [UInt8], maxDepth: Int = 256) -> Set<String>? {
        bytes.withUnsafeBufferPointer { b in
            var p = Parser(b: b, maxDepth: maxDepth)
            p.ws()
            guard p.eat(0x7B) else { return nil }
            var out = Set<String>()
            p.ws()
            if p.eat(0x7D) { return out }
            while true {
                p.ws()
                guard let k = p.str() else { return nil }
                p.ws()
                guard p.eat(0x3A) else { return nil }
                p.ws()
                guard p.skip(1) else { return nil }
                out.insert(k)
                p.ws()
                if p.eat(0x2C) { continue }
                return p.eat(0x7D) ? out : nil
            }
        }
    }

    private struct Parser {
        let b: UnsafeBufferPointer<UInt8>
        let maxDepth: Int
        var i = 0
        init(b: UnsafeBufferPointer<UInt8>, maxDepth: Int) { self.b = b; self.maxDepth = maxDepth }

        var peek: UInt8? { i < b.count ? b[i] : nil }
        mutating func ws() { while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }
        mutating func eat(_ c: UInt8) -> Bool { if peek == c { i += 1; return true }; return false }
        mutating func lit(_ s: StaticString) -> Bool {
            let n = s.utf8CodeUnitCount
            guard i + n <= b.count else { return false }
            for k in 0..<n where b[i + k] != s.utf8Start[k] { return false }
            i += n
            return true
        }

        mutating func value(_ depth: Int) -> JValue? {
            guard depth < maxDepth else { return nil }
            ws()
            guard let c = peek else { return nil }
            switch c {
            case 0x7B:
                i += 1
                var m: [Member] = []
                ws()
                if eat(0x7D) { return .object(m) }
                while true {
                    ws()
                    guard let k = str() else { return nil }
                    ws()
                    guard eat(0x3A), let v = value(depth + 1) else { return nil }
                    m.append(Member(k, v))
                    ws()
                    if eat(0x2C) { continue }
                    return eat(0x7D) ? .object(m) : nil
                }
            case 0x5B:
                i += 1
                var a: [JValue] = []
                ws()
                if eat(0x5D) { return .array(a) }
                while true {
                    guard let v = value(depth + 1) else { return nil }
                    a.append(v)
                    ws()
                    if eat(0x2C) { continue }
                    return eat(0x5D) ? .array(a) : nil
                }
            case 0x22: return str().map(JValue.string)
            case 0x74: return lit("true") ? .bool(true) : nil
            case 0x66: return lit("false") ? .bool(false) : nil
            case 0x6E: return lit("null") ? .null : nil
            default:
                let s = i
                guard num() else { return nil }
                return .number(String(decoding: UnsafeBufferPointer(rebasing: b[s..<i]), as: UTF8.self))
            }
        }

        /// Skips one value without building it.
        mutating func skip(_ depth: Int) -> Bool {
            guard depth < maxDepth else { return false }
            ws()
            guard let c = peek else { return false }
            switch c {
            case 0x7B, 0x5B:
                let close: UInt8 = c == 0x7B ? 0x7D : 0x5D
                i += 1
                ws()
                if eat(close) { return true }
                while true {
                    ws()
                    if c == 0x7B {
                        guard skipStr() else { return false }
                        ws()
                        guard eat(0x3A) else { return false }
                    }
                    guard skip(depth + 1) else { return false }
                    ws()
                    if eat(0x2C) { continue }
                    return eat(close)
                }
            case 0x22: return skipStr()
            case 0x74: return lit("true")
            case 0x66: return lit("false")
            case 0x6E: return lit("null")
            default: return num()
            }
        }

        mutating func num() -> Bool {
            let s = i
            _ = eat(0x2D)
            while let c = peek, (c >= 0x30 && c <= 0x39) || c == 0x2E || c == 0x65 || c == 0x45 || c == 0x2B || c == 0x2D { i += 1 }
            return i > s && Double(String(decoding: UnsafeBufferPointer(rebasing: b[s..<i]), as: UTF8.self)) != nil
        }

        mutating func skipStr() -> Bool {
            guard eat(0x22) else { return false }
            while i < b.count {
                let c = b[i]
                if c == 0x22 { i += 1; return true }
                i += c == 0x5C ? 2 : 1
            }
            return false
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = b[i]
                let d: UInt8
                switch c {
                case 0x30...0x39: d = c - 0x30
                case 0x41...0x46: d = c - 0x37
                case 0x61...0x66: d = c - 0x57
                default: return nil
                }
                v = v << 4 | UInt32(d); i += 1
            }
            return v
        }

        mutating func str() -> String? {
            guard eat(0x22) else { return nil }
            var out: [UInt8] = []
            var start = i
            while i < b.count {
                let c = b[i]
                if c == 0x22 {
                    out.append(contentsOf: b[start..<i]); i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if c < 0x20 { return nil }
                guard c == 0x5C else { i += 1; continue }
                out.append(contentsOf: b[start..<i]); i += 1
                guard let e = peek else { return nil }
                i += 1
                switch e {
                case 0x22, 0x5C, 0x2F: out.append(e)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    guard var u = hex4() else { return nil }
                    if u >= 0xD800 && u < 0xDC00, i + 1 < b.count, b[i] == 0x5C, b[i + 1] == 0x75 {
                        i += 2
                        guard let lo = hex4() else { return nil }
                        u = lo >= 0xDC00 && lo < 0xE000 ? 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00) : 0xFFFD
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(u).map(Character.init) ?? "\u{FFFD}").utf8))
                default: return nil
                }
                start = i
            }
            return nil
        }
    }

    // MARK: printing

    /// Compact single-line form (spool lines).
    public var compact: String {
        var s = ""
        write(&s, indent: nil, level: 0)
        return s
    }

    /// Multi-line form like `JSON.stringify(v, null, indent)`.
    public func pretty(indent: String = "  ") -> String {
        var s = ""
        write(&s, indent: indent, level: 0)
        return s
    }

    private func write(_ s: inout String, indent: String?, level: Int) {
        switch self {
        case .null: s += "null"
        case .bool(let v): s += v ? "true" : "false"
        case .number(let n): s += n
        case .string(let v): JValue.quote(v, into: &s)
        case .array(let a):
            if a.isEmpty { s += "[]"; return }
            s += "["
            for (k, v) in a.enumerated() {
                if k > 0 { s += "," }
                newline(&s, indent, level + 1)
                v.write(&s, indent: indent, level: level + 1)
            }
            newline(&s, indent, level); s += "]"
        case .object(let m):
            if m.isEmpty { s += "{}"; return }
            s += "{"
            for (k, e) in m.enumerated() {
                if k > 0 { s += "," }
                newline(&s, indent, level + 1)
                JValue.quote(e.key, into: &s)
                s += indent == nil ? ":" : ": "
                e.value.write(&s, indent: indent, level: level + 1)
            }
            newline(&s, indent, level); s += "}"
        }
    }

    private func newline(_ s: inout String, _ indent: String?, _ level: Int) {
        guard let indent else { return }
        s += "\n"
        for _ in 0..<level { s += indent }
    }

    public static func quote(_ v: String, into s: inout String) {
        s += "\""
        for u in v.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            case "\u{08}": s += "\\b"
            case "\u{0C}": s += "\\f"
            default:
                if u.value < 0x20 {
                    let h = String(u.value, radix: 16)
                    s += "\\u" + String(repeating: "0", count: 4 - h.count) + h
                } else { s.unicodeScalars.append(u) }
            }
        }
        s += "\""
    }
}
