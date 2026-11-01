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
                 + "will not open it afterwards: copy \(db) first to keep a way back"], false)
    }
}
