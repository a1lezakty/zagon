import CSQLite

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "sqlite \(code): \(message)" }
}

/// A bound value. Ints are 64-bit, timestamps are REAL seconds.
public enum SQLValue: Sendable, Equatable {
    case int(Int64), real(Double), text(String), blob([UInt8]), null
}

extension SQLValue {
    public static func of(_ v: Int?) -> SQLValue { v.map { .int(Int64($0)) } ?? .null }
    public static func of(_ v: Double?) -> SQLValue { v.map { .real($0) } ?? .null }
    public static func of(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
}

/// One result row; columns by index.
public struct Row {
    let stmt: OpaquePointer
    public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    public func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func real(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    public func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    public func optReal(_ i: Int32) -> Double? { isNull(i) ? nil : real(i) }
    public func blob(_ i: Int32) -> [UInt8] {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return [] }
        return Array(UnsafeRawBufferPointer(start: p, count: n))
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin SQLite connection with a prepared-statement cache. Not thread-safe: one connection per thread.
public final class SQLite {
    public private(set) var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
                             : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let e = SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(handle); handle = nil
            throw e
        }
        sqlite3_busy_timeout(handle, 10_000)
    }

    deinit {
        for s in cache.values { sqlite3_finalize(s) }
        sqlite3_close(handle)
    }

    private func error(_ rc: Int32, _ sql: String) -> SQLiteError {
        SQLiteError(code: rc, message: "\(String(cString: sqlite3_errmsg(handle))) in: \(sql.prefix(120))")
    }

    /// Runs one or more statements without parameters.
    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: "\(m) in: \(sql.prefix(120))")
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer {
        let s: OpaquePointer
        if let c = cache[sql] {
            sqlite3_reset(c); sqlite3_clear_bindings(c); s = c
        } else {
            var p: OpaquePointer?
            let rc = sqlite3_prepare_v2(handle, sql, -1, &p, nil)
            guard rc == SQLITE_OK, let p else { throw error(rc, sql) }
            cache[sql] = p; s = p
        }
        for (k, v) in args.enumerated() {
            let i = Int32(k + 1)
            switch v {
            case .int(let n): sqlite3_bind_int64(s, i, n)
            case .real(let d): sqlite3_bind_double(s, i, d)
            case .text(let t): sqlite3_bind_text(s, i, t, -1, transient)
            case .blob(let b): b.withUnsafeBytes { _ = sqlite3_bind_blob(s, i, $0.baseAddress, Int32(b.count), transient) }
            case .null: sqlite3_bind_null(s, i)
            }
        }
        return s
    }

    /// Executes a statement; returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        let s = try prepare(sql, args)
        defer { sqlite3_reset(s) }
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
        return Int(sqlite3_changes(handle))
    }

    /// Iterates result rows.
    public func query(_ sql: String, _ args: [SQLValue] = [], _ row: (Row) throws -> Void) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_reset(s) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            try row(Row(stmt: s))
        }
    }

    /// First row mapped, or nil.
    public func one<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (Row) throws -> T) throws -> T? {
        var out: T?
        try query(sql, args) { r in if out == nil { out = try map(r) } }
        return out
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Frees the unused part of this connection's page cache (refilled from the OS page cache on demand).
    public func releaseMemory() { sqlite3_db_release_memory(handle) }

    /// BEGIN IMMEDIATE … COMMIT; rolls back on error. Immediate = the write lock is taken up front, so two
    /// processes ingesting the same file serialize instead of both reading the old offset.
    /// Inside an open transaction the body just joins it (an error then rolls back the outer one).
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if sqlite3_get_autocommit(handle) == 0 { return try body() }
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
