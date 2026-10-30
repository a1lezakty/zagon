#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Time helpers on libc only (no ICU): ISO-8601 parsing and local-day arithmetic via localtime_r/mktime,
/// so days follow `TZ` or /etc/localtime on every platform.
public enum Time {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)`; returns UTC epoch seconds.
    public static func parseISO(_ b: UnsafeRawBufferPointer) -> Timestamp? {
        let u = b.bindMemory(to: UInt8.self)
        guard u.count >= 19, u[4] == 0x2D, u[7] == 0x2D, u[13] == 0x3A, u[16] == 0x3A else { return nil }
        func num(_ a: Int, _ e: Int) -> Int? {
            var v = 0
            for k in a..<e { let d = Int(u[k]) - 48; guard d >= 0 && d <= 9 else { return nil }; v = v * 10 + d }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10), let h = num(11, 13), let mi = num(14, 16),
              let s = num(17, 19), (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var k = 19, frac = 0.0
        if k < u.count, u[k] == 0x2E {
            k += 1
            var scale = 0.1
            while k < u.count, u[k] >= 0x30, u[k] <= 0x39 { frac += Double(u[k] - 0x30) * scale; scale /= 10; k += 1 }
        }
        var offset = 0
        if k < u.count, u[k] == 0x2B || u[k] == 0x2D, k + 6 <= u.count, let oh = num(k + 1, k + 3), let om = num(k + 4, k + 6) {
            offset = (oh * 3600 + om * 60) * (u[k] == 0x2D ? -1 : 1)
        }
        return Double(daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset) + frac
    }

    public static func parseISO(_ s: String) -> Timestamp? {
        var s = s
        return s.withUTF8 { parseISO(UnsafeRawBufferPointer($0)) }
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    nonisolated(unsafe) private static var tzReady = false
    private static func ensureTZ() { if !tzReady { tzset(); tzReady = true } }

    /// Local calendar date of an instant.
    public static func localDate(_ ts: Timestamp) -> (year: Int, month: Int, day: Int) {
        ensureTZ()
        var t = time_t(ts.rounded(.down)), tmv = tm()
        localtime_r(&t, &tmv)
        return (Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1, Int(tmv.tm_mday))
    }

    /// Local midnight of a calendar date (day may overflow: mktime normalizes, so day+1 is the next day).
    public static func localMidnight(_ y: Int, _ m: Int, _ d: Int) -> Timestamp {
        ensureTZ()
        var tmv = tm()
        tmv.tm_year = Int32(y - 1900); tmv.tm_mon = Int32(m - 1); tmv.tm_mday = Int32(d); tmv.tm_isdst = -1
        return Double(mktime(&tmv))
    }

    /// `YYYY-MM-DD` of the local day containing `ts`.
    public static func dayString(_ ts: Timestamp) -> String {
        let (y, m, d) = localDate(ts)
        return format(y, m, d)
    }

    static func format(_ y: Int, _ m: Int, _ d: Int) -> String {
        func p2(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(y)-\(p2(m))-\(p2(d))"
    }

    /// Parses `YYYY-MM-DD`. Years outside 1000…9999 are refused: they trap in `Int32(y - 1900)` and break the
    /// string order of day keys.
    public static func parseDay(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1000...9999).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        return (y, m, d)
    }

    /// [start, end) of a local day.
    public static func dayBounds(_ day: String) -> (start: Timestamp, end: Timestamp)? {
        guard let (y, m, d) = parseDay(day) else { return nil }
        return (localMidnight(y, m, d), localMidnight(y, m, d + 1))
    }

    /// The local day `delta` days from `day`.
    public static func addDays(_ day: String, _ delta: Int) -> String? {
        guard let (y, m, d) = parseDay(day) else { return nil }
        return dayString(localMidnight(y, m, d + delta) + 3600 * 12)
    }

    public static func now() -> Timestamp {
        var t = timespec()
        clock_gettime(CLOCK_REALTIME, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    public static func monotonic() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_MONOTONIC, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    /// UTC hour bucket start.
    @inline(__always) public static func hour(_ ts: Timestamp) -> Int { Int((ts / 3600).rounded(.down)) * 3600 }
}
