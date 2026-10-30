import CSys
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Minimal forward-only JSON reader over raw bytes, for the hot path (Foundation's JSONDecoder is several times
/// slower in the static Linux SDK). It reads only what the caller asks for and skips everything else.
/// Every method returns nil/false on malformed input; callers then fall back to JSONDecoder.
public struct ByteScanner {
    @usableFromInline let p: UnsafePointer<UInt8>
    @usableFromInline let n: Int
    public private(set) var i = 0

    public init(_ buf: UnsafeRawBufferPointer) {
        // A zero-length buffer may have a nil base; point at a static byte so `p` is always valid.
        p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? ByteScanner.empty
        n = buf.count
    }
    nonisolated(unsafe) private static let empty: UnsafePointer<UInt8> = {
        let b = UnsafeMutablePointer<UInt8>.allocate(capacity: 1); b.initialize(to: 0); return UnsafePointer(b)
    }()

    public var atEnd: Bool { var c = self; c.ws(); return c.i >= c.n }

    @inline(__always) mutating func ws() {
        while i < n, p[i] == 0x20 || p[i] == 0x0A || p[i] == 0x0D || p[i] == 0x09 { i += 1 }
    }

    /// At an opening quote; leaves `i` after the closing quote.
    mutating func skipString() -> Bool {
        i += 1
        while i < n {
            guard let q = memchr(p + i, 0x22, n - i) else { return false }
            let j = UnsafeRawPointer(p).distance(to: UnsafeRawPointer(q))
            var k = j - 1, bs = 0
            while k >= i && p[k] == 0x5C { bs += 1; k -= 1 }
            i = j + 1
            if bs % 2 == 0 { return true }
        }
        return false
    }

    /// Skips any value (string, number, literal, object, array).
    public mutating func skipValue() -> Bool {
        ws()
        guard i < n else { return false }
        switch p[i] {
        case 0x22: return skipString()
        case 0x7B, 0x5B:
            var depth = 0
            while i < n {
                switch p[i] {
                case 0x22: if !skipString() { return false }; continue
                case 0x7B, 0x5B: depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 { i += 1; return true }
                default: break
                }
                i += 1
            }
            return false
        default:
            let s = i
            while i < n, p[i] != 0x2C, p[i] != 0x7D, p[i] != 0x5D, p[i] > 0x20 { i += 1 }
            return i > s
        }
    }

    /// Raw bytes of a string value without quotes (escapes not decoded). Nil if the value is not a string.
    public mutating func rawString() -> UnsafeRawBufferPointer? {
        ws()
        guard i < n, p[i] == 0x22 else { _ = skipValue(); return nil }
        let s = i
        guard skipString() else { return nil }
        return UnsafeRawBufferPointer(start: p + s + 1, count: i - s - 2)
    }

    /// A string value with escapes decoded. `limit` truncates long values (in bytes, on a character boundary).
    public mutating func string(limit: Int = .max) -> String? {
        guard let raw = rawString() else { return nil }
        if memchr(raw.baseAddress!, 0x5C, raw.count) == nil {
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[0..<ByteScanner.boundary(raw, limit)]), as: UTF8.self)
        }
        return ByteScanner.unescape(raw, limit: limit)
    }

    /// Length of the longest prefix of `b` not longer than `limit` that ends on a UTF-8 character boundary.
    static func boundary(_ b: UnsafeRawBufferPointer, _ limit: Int) -> Int {
        guard limit < b.count else { return b.count }
        var k = max(limit, 0)
        while k > 0, b[k] & 0xC0 == 0x80 { k -= 1 }
        return k
    }

    /// Integer value; fractions and exponents are truncated; `null` gives nil.
    public mutating func int() -> Int? {
        ws()
        var v = 0, neg = false, any = false
        if i < n, p[i] == 0x2D { neg = true; i += 1 }
        while i < n, p[i] >= 0x30, p[i] <= 0x39 { v = v &* 10 &+ Int(p[i] - 0x30); i += 1; any = true }
        if !any { _ = skipValue(); return nil }
        if i < n, p[i] == 0x2E || p[i] == 0x65 || p[i] == 0x45 { _ = skipValue() }
        return neg ? -v : v
    }

    /// Number as Double (strtod: decimal and exponent forms).
    public mutating func double() -> Double? {
        ws()
        let s = i
        guard skipValue(), i > s else { return nil }
        var buf = [CChar](repeating: 0, count: min(i - s, 63) + 1)
        for k in 0..<(buf.count - 1) { buf[k] = CChar(bitPattern: p[s + k]) }
        return buf.withUnsafeBufferPointer { b in
            var end: UnsafeMutablePointer<CChar>?
            let d = strtod(b.baseAddress!, &end)
            return end.map { UnsafePointer($0) != b.baseAddress } == true ? d : nil
        }
    }

    public mutating func bool() -> Bool? {
        ws()
        guard i < n else { return nil }
        let c = p[i]
        _ = skipValue()
        return c == 0x74 ? true : c == 0x66 ? false : nil
    }

    /// Iterates an object. `body` gets the raw key and must either consume the value and return true,
    /// or return false to have the value skipped. Returns false on malformed input.
    public mutating func object(_ body: (inout ByteScanner, UnsafeRawBufferPointer) -> Bool) -> Bool {
        ws()
        guard i < n, p[i] == 0x7B else { _ = skipValue(); return false }
        i += 1
        while true {
            ws()
            guard i < n else { return false }
            if p[i] == 0x7D { i += 1; return true }
            if p[i] == 0x2C { i += 1; continue }
            guard p[i] == 0x22 else { return false }
            let ks = i + 1
            guard skipString() else { return false }
            let key = UnsafeRawBufferPointer(start: p + ks, count: i - 1 - ks)
            ws()
            guard i < n, p[i] == 0x3A else { return false }
            i += 1
            let before = i
            if !body(&self, key) {
                i = before
                guard skipValue() else { return false }
            }
        }
    }

    /// Iterates an array; `body` must consume one element and return false on failure.
    public mutating func array(_ body: (inout ByteScanner) -> Bool) -> Bool {
        ws()
        guard i < n, p[i] == 0x5B else { _ = skipValue(); return false }
        i += 1
        while true {
            ws()
            guard i < n else { return false }
            if p[i] == 0x5D { i += 1; return true }
            if p[i] == 0x2C { i += 1; continue }
            if !body(&self) { return false }
        }
    }

    /// Type of the next value without consuming it: `"`, `{`, `[`, or other.
    public var peek: UInt8? { var c = self; c.ws(); return c.i < c.n ? c.p[c.i] : nil }

    static func unescape(_ raw: UnsafeRawBufferPointer, limit: Int) -> String? {
        var out: [UInt8] = []
        out.reserveCapacity(min(raw.count, limit))
        var k = 0
        let b = raw.bindMemory(to: UInt8.self)
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= b.count else { return nil }
            var v: UInt32 = 0
            for j in at..<(at + 4) {
                let c = b[j]
                let d: UInt8
                switch c {
                case 0x30...0x39: d = c - 0x30
                case 0x61...0x66: d = c - 0x61 + 10
                case 0x41...0x46: d = c - 0x41 + 10
                default: return nil
                }
                v = v << 4 | UInt32(d)
            }
            return v
        }
        while k < b.count, out.count <= limit { // one byte past `limit` tells whether the cut splits a character
            let c = b[k]
            if c != 0x5C { out.append(c); k += 1; continue }
            guard k + 1 < b.count else { return nil }
            let e = b[k + 1]
            k += 2
            switch e {
            case 0x22, 0x5C, 0x2F: out.append(e)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard var u = hex4(k) else { return nil }
                k += 4
                if u >= 0xD800 && u < 0xDC00, k + 6 <= b.count, b[k] == 0x5C, b[k + 1] == 0x75, let lo = hex4(k + 2),
                   lo >= 0xDC00 && lo < 0xE000 {
                    u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                    k += 6
                }
                let scalar = Unicode.Scalar(u) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: return nil
            }
        }
        return out.withUnsafeBytes { String(decoding: $0[0..<boundary($0, limit)], as: UTF8.self) }
    }
}

/// Byte-wise equality of a raw key with a literal.
@inline(__always)
public func keyIs(_ k: UnsafeRawBufferPointer, _ s: StaticString) -> Bool {
    k.count == s.utf8CodeUnitCount && memcmp(k.baseAddress!, s.utf8Start, k.count) == 0
}

/// Substring test on raw bytes (memmem).
@inline(__always)
public func contains(_ b: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
    guard let base = b.baseAddress else { return false }
    return z_memmem(base, b.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
}

/// 64-bit FNV-1a, stored as Int64 (SQLite INTEGER PRIMARY KEY).
public func fnv1a64(_ s: String) -> Int64 {
    var h: UInt64 = 0xcbf29ce484222325
    for c in s.utf8 { h = (h ^ UInt64(c)) &* 0x100000001b3 }
    return Int64(bitPattern: h)
}
