#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Day ribbon for the evening summary: one row per session (working / waiting bars) plus your time, hour grid on
/// top. A plain raster written as a 4-bit palette PNG with stored (uncompressed) deflate blocks: no zlib needed and
/// still small, since a 720 px wide image costs 361 bytes per row.
public enum Timeline {
    public enum Kind: UInt8, Sendable { case working = 3, waiting = 4, user = 5 }
    public struct Span: Sendable, Equatable {
        public var start: Double, end: Double, kind: Kind
        public init(_ start: Double, _ end: Double, _ kind: Kind) { self.start = start; self.end = end; self.kind = kind }
    }

    static let palette: [(UInt8, UInt8, UInt8)] = [
        (255, 255, 255), (226, 228, 233), (90, 96, 108), (59, 130, 246), (245, 158, 11), (16, 185, 129), (246, 247, 249),
    ]
    public static let maxRows = 14
    static let left = 34, right = 14, top = 22, rowH = 22, barH = 12

    /// `rows` top to bottom (at most `maxRows`), `from`/`to` on whole hours; `hourLabel` gives the label of a grid hour.
    public static func png(rows: [[Span]], from: Double, to: Double, width: Int = 720,
                           hourLabel: ((Double) -> Int)? = nil) -> [UInt8] {
        let rows = Array(rows.prefix(maxRows))
        let w = max(width, left + right + 48), h = top + max(1, rows.count) * rowH + 6
        var px = [UInt8](repeating: 0, count: w * h)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: UInt8) {
            for y in max(0, y0)..<min(h, y1) { for x in max(0, x0)..<min(w, x1) { px[y * w + x] = c } }
        }
        let plotW = w - left - right, span = max(3600, to - from)
        func x(_ t: Double) -> Int { left + Int(((t - from) / span * Double(plotW)).rounded()) }

        for (i, _) in rows.enumerated() where i % 2 == 1 { fill(left, top + i * rowH, w - right, top + (i + 1) * rowH, 6) }
        let hours = Int((span / 3600).rounded())
        let step = hours <= 12 ? 2 : 4
        for k in 0...hours {
            let gx = x(from + Double(k) * 3600)
            fill(gx, top - 4, gx + 1, h - 4, 1)
            if k % step == 0 {
                let t = from + Double(k) * 3600
                var label = hourLabel?(t) ?? Int(Ru.local(t).tm_hour)
                if k > 0 && label == 0 { label = 24 }
                let text = label < 10 ? "0\(label)" : "\(label)"
                digits(text, x: gx - text.count * 4 + 1, y: 4, into: &px, w: w)
            }
        }
        for (i, row) in rows.enumerated() {
            let y = top + i * rowH + (rowH - barH) / 2
            let label = row.contains { $0.kind == .user } ? "" : "\(i + 1)"
            digits(label, x: left - 8 - label.count * 8, y: y + 1, into: &px, w: w)
            if label.isEmpty { fill(left - 18, y + 2, left - 8, y + barH - 2, Kind.user.rawValue) }
            for s in row.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) where s.end > from && s.start < to {
                let x0 = x(max(s.start, from)), x1 = max(x0 + 1, x(min(s.end, to)))
                fill(x0, y, x1, y + barH, s.kind.rawValue)
            }
        }
        return encode(px, width: w, height: h)
    }

    // 3×5 digit glyphs, drawn at 2× scale.
    static let glyphs: [UInt16] = [0x7B6F, 0x2C97, 0x73E7, 0x73CF, 0x5BC9, 0x79CF, 0x79EF, 0x7249, 0x7BEF, 0x7BCF]

    static func digits(_ s: String, x: Int, y: Int, into px: inout [UInt8], w: Int) {
        for (k, ch) in s.utf8.enumerated() where ch >= 0x30 && ch <= 0x39 {
            let g = glyphs[Int(ch - 0x30)]
            for r in 0..<5 { for c in 0..<3 where g >> (14 - r * 3 - c) & 1 == 1 {
                for dy in 0..<2 { for dx in 0..<2 {
                    let px0 = x + k * 8 + c * 2 + dx, py = y + r * 2 + dy
                    if px0 >= 0 && px0 < w && py >= 0 && py * w + px0 < px.count { px[py * w + px0] = 2 }
                } }
            } }
        }
    }

    // MARK: PNG

    static func encode(_ px: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        let stride = (w + 1) / 2
        var raw = [UInt8](); raw.reserveCapacity(h * (stride + 1))
        for y in 0..<h {
            raw.append(0)
            for x in Swift.stride(from: 0, to: w, by: 2) {
                raw.append(px[y * w + x] << 4 | (x + 1 < w ? px[y * w + x + 1] : 0))
            }
        }
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, raw.count - i)
            z.append(i + n == raw.count ? 1 : 0)
            z += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            z += raw[i..<(i + n)]
            i += n
        } while i < raw.count
        z += be32(adler32(raw))
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        chunk("IHDR", be32(UInt32(w)) + be32(UInt32(h)) + [4, 3, 0, 0, 0], into: &out)
        chunk("PLTE", palette.flatMap { [$0.0, $0.1, $0.2] }, into: &out)
        chunk("IDAT", z, into: &out)
        chunk("IEND", [], into: &out)
        return out
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func chunk(_ type: String, _ data: [UInt8], into out: inout [UInt8]) {
        let td = Array(type.utf8) + data
        out += be32(UInt32(data.count)) + td + be32(crc32(td))
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in b { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ b: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, s: UInt32 = 0
        for x in b { a = (a + UInt32(x)) % 65521; s = (s + a) % 65521 }
        return s << 16 | a
    }
}
