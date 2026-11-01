import CSys
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// What a new binary will do to a database, asked before `zagon update` replaces the old one: the new binary runs
/// `update --db-schema <data dir>` and prints `answer` (its own schema and the database's); the old one turns that
/// into `notes`. A release without the option answers nothing usable, and the update goes on as before.
public enum SchemaCheck {
    /// The schema version of `<dataDir>/zagon.db`, read through a read-only connection (nothing migrated or written);
    /// nil when there is no database or it cannot be read.
    public static func version(dataDir: String) -> Int? {
        let path = dataDir + "/zagon.db"
        guard Sys.exists(path), let db = try? SQLite(path: path, readOnly: true) else { return nil }
        return try? db.one("PRAGMA user_version") { $0.int(0) }
    }

    /// `schema <database's> <this binary's>`, nil without a database.
    public static func answer(dataDir: String) -> String? {
        version(dataDir: dataDir).map { "schema \($0) \(Store.schemaVersion)" }
    }

    /// The old binary's lines about `db` from the new one's `answer`: none when the new one uses it as it is (or the
    /// answer is not one); a migration note; or, with `stop`, that the new one cannot open it (a service on it would
    /// fail at every start).
    public static func notes(answer: String, db: String, exe: String, old: String, new: String) -> (lines: [String], stop: Bool) {
        let f = answer.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard f.count == 3, f[0] == "schema", let have = Int(f[1]), let reads = Int(f[2]), have > 0 else { return ([], false) }
        if have > reads {
            return (["zagon \(new) cannot open \(db): its schema v\(have) is newer than v\(reads) that \(new) reads; nothing replaced"], true)
        }
        guard have < reads else { return ([], false) }
        return (["database \(db): schema v\(have) -> v\(reads) when zagon \(new) starts; \(Sys.basename(exe)).prev (\(old)) "
                 + "will not open it afterwards: rolling back then needs a copy of \(db) made before this update"], false)
    }

    /// The database's schema when the new binary will migrate it (from its `answer`), else nil.
    public static func migrates(answer: String) -> Int? {
        let f = answer.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard f.count == 3, f[0] == "schema", let have = Int(f[1]), let reads = Int(f[2]), have > 0, have < reads else { return nil }
        return have
    }

    /// Before a migration: a copy of `db` as `<db>.v<version>` (VACUUM INTO: a consistent snapshot of the live database,
    /// its WAL included), made with the file identity of the database's owner (root updating for another account
    /// writes nothing as root in that account's folder) and with the database's mode. One per schema version: a later
    /// update from the same version replaces it, copies of other versions are left alone. Not made (`problem` says why)
    /// when the disk has less than twice the database's size free, or, for root, the database is a symbolic link.
    public static func snapshot(db: String, version: Int, free: (String) -> UInt64? = freeBytes) -> (path: String?, problem: String?) {
        let root = geteuid() == 0
        var st = stat(), dir = stat()
        guard (root ? lstat(db, &st) : stat(db, &st)) == 0, lstat(Sys.dirname(db), &dir) == 0 else { return (nil, "cannot read \(db)") }
        guard st.st_mode & S_IFMT == S_IFREG else { return (nil, "\(db) is not a plain file") }
        let size = UInt64((Sys.fileSize(db) ?? 0) + (Sys.fileSize(db + "-wal") ?? 0))
        let avail = free(Sys.dirname(db))
        guard let avail, avail >= 2 * size else {
            return (nil, "\(mb(size)) MB database, " + (avail.map { "\(mb($0)) MB free" } ?? "free space unknown") + "; twice its size is needed")
        }
        // The folder's owner: a file in it owned by root (an older root run) must not make root write there.
        let other = root && dir.st_uid != 0
        guard !other || z_as_user(UInt32(dir.st_uid), UInt32(dir.st_gid)) == 0 else { return (nil, "cannot act as the owner of \(Sys.dirname(db))") }
        defer { if other { z_as_root() } }
        let path = db + ".v\(version)", tmp = path + ".tmp"
        Sys.remove(tmp)
        do {
            let c = try SQLite(path: db, readOnly: true)
            try c.exec("VACUUM INTO '" + tmp.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "''") + "'")
        } catch {
            Sys.remove(tmp)
            return (nil, "\(error)")
        }
        chmod(tmp, st.st_mode & 0o777)
        guard rename(tmp, path) == 0 else { Sys.remove(tmp); return (nil, "cannot write \(path) (errno \(errno))") }
        return (path, nil)
    }

    /// What `snapshot` gives the user: how to roll back, or a warning that there is no way back. Every connection must
    /// be closed first (the service and the `zagon mcp` of open Claude Code / Codex sessions): a WAL left by the new
    /// version would be applied to the old copy.
    public static func snapshotNote(_ s: (path: String?, problem: String?), db: String, exe: String, old: String) -> String {
        if let p = s.path {
            let q = Sys.shellQuote
            return "a copy of the database from before this update: \(p); to roll back to \(old): stop the service and quit the "
                + "Claude Code / Codex sessions (their zagon mcp), then mv \(q(exe + ".prev")) \(q(exe)); rm -f \(q(db + "-wal")) "
                + "\(q(db + "-shm")); mv \(q(p)) \(q(db)); and start the service"
        }
        return "WARNING: no copy of \(db) was made (\(s.problem ?? "?")): after this update there is no way back to \(old) "
            + "with this database"
    }

    /// The copies `snapshot` left in `dataDir`, oldest version first: name, bytes, mtime.
    public static func snapshots(dataDir: String) -> [(name: String, bytes: Int, mtime: Double)] {
        Sys.listDir(dataDir).filter { n in n.hasPrefix("zagon.db.v") && Int(n.dropFirst("zagon.db.v".count)) != nil }
            .sorted { Int($0.dropFirst(10))! < Int($1.dropFirst(10))! }
            .map { ($0, Sys.fileSize(dataDir + "/" + $0) ?? 0, Sys.mtime(dataDir + "/" + $0) ?? 0) }
    }

    /// Bytes free for this user on the file system of `dir`.
    public static func freeBytes(_ dir: String) -> UInt64? {
        var st = statvfs()
        guard statvfs(dir, &st) == 0 else { return nil }
        return UInt64(st.f_bavail) * UInt64(st.f_frsize)
    }

    static func mb(_ b: UInt64) -> UInt64 { (b + (1 << 19)) >> 20 }
}
