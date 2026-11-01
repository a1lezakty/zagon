import Foundation
import Testing
@testable import ZagonCore

@Suite struct SchemaCheckTests {
    let db = "/data/zagon.db", exe = "/opt/bin/zagon"

    @Test func notesFromTheNewBinarysAnswer() {
        #expect(SchemaCheck.notes(answer: "schema 6 7\n", db: db, exe: exe, old: "0.1.4", new: "0.1.5") == ([
            "database /data/zagon.db: schema v6 -> v7 when zagon 0.1.5 starts; zagon.prev (0.1.4) will not open it afterwards: "
                + "rolling back then needs a copy of /data/zagon.db made before this update"], false))
        #expect(SchemaCheck.notes(answer: "schema 8 7", db: db, exe: exe, old: "0.1.6", new: "0.1.5") == ([
            "zagon 0.1.5 cannot open /data/zagon.db: its schema v8 is newer than v7 that 0.1.5 reads; nothing replaced"], true))
        // The same schema, a fresh database, or no usable answer: nothing to say.
        for a in ["schema 7 7", "schema 0 7", "", "Error: Unknown option '--db-schema'", "schema x 7"] {
            #expect(SchemaCheck.notes(answer: a, db: db, exe: exe, old: "0.1.4", new: "0.1.5") == ([], false), "\(a)")
        }
    }

    /// The binary's hidden answer reads the version without migrating the database.
    @Test(.enabled(if: Sys.exists(zagonBin))) func theBinaryAnswersWithoutMigrating() throws {
        let dir = makeTempDir(), path = dir + "/zagon.db"
        #expect(SchemaCheck.version(dataDir: dir) == nil)
        try Store(path: path).db.exec("PRAGMA user_version=3")
        #expect(SchemaCheck.version(dataDir: dir) == 3)
        let (status, out) = try runZagon(["update", "--db-schema", dir], stdin: [], env: [:])
        #expect(status == 0 && String(decoding: out, as: UTF8.self) == "schema 3 \(Store.schemaVersion)\n")
        #expect(SchemaCheck.version(dataDir: dir) == 3)
        let (s2, none) = try runZagon(["update", "--db-schema", dir + "/none"], stdin: [], env: [:])
        #expect(s2 == 0 && none.isEmpty)
    }

    /// Before a migration: a consistent copy of the live database (WAL included), one per schema version, none when
    /// the disk is short.
    @Test func snapshotBeforeAMigration() throws {
        let dir = makeTempDir(), db = dir + "/zagon.db"
        let store = try Store(path: db)  // kept open: the row below may sit in the WAL only
        try store.db.exec("CREATE TABLE t(x); INSERT INTO t VALUES (42)")
        #expect(SchemaCheck.migrates(answer: "schema 7 8\n") == 7)
        for a in ["schema 8 8", "schema 9 8", "schema 0 8", "", "x"] { #expect(SchemaCheck.migrates(answer: a) == nil, "\(a)") }

        let s = SchemaCheck.snapshot(db: db, version: 7, free: { _ in 1 << 40 })
        #expect(s.path == db + ".v7" && s.problem == nil)
        let copy = try SQLite(path: db + ".v7", readOnly: true)
        #expect(try copy.one("SELECT x FROM t") { $0.int(0) } == 42)
        #expect(try copy.one("PRAGMA user_version") { $0.int(0) } == Store.schemaVersion)
        #expect(SchemaCheck.snapshotNote(s, db: db, exe: "/opt/zagon", old: "0.1.5") == "a copy of the database from before this update: "
            + "\(db).v7; to roll back to 0.1.5: stop the service, then mv /opt/zagon.prev /opt/zagon and mv \(db).v7 \(db), and start it again")

        // The same version again: the newer copy replaces it; another version's copy stays.
        try store.db.exec("INSERT INTO t VALUES (43)")
        Sys.writeFile(db + ".v6", [1])
        #expect(SchemaCheck.snapshot(db: db, version: 7, free: { _ in 1 << 40 }).path == db + ".v7")
        #expect(try SQLite(path: db + ".v7", readOnly: true).one("SELECT count(*) FROM t") { $0.int(0) } == 2)
        #expect(SchemaCheck.snapshots(dataDir: dir).map(\.name) == ["zagon.db.v6", "zagon.db.v7"])
        #expect(!Sys.listDir(dir).contains { $0.hasSuffix(".tmp") })

        // Less than twice the size free: no copy, a warning.
        let short = SchemaCheck.snapshot(db: db, version: 5, free: { _ in 10 })
        #expect(short.path == nil && !Sys.exists(db + ".v5"))
        #expect(SchemaCheck.snapshotNote(short, db: db, exe: "/opt/zagon", old: "0.1.5").hasPrefix("WARNING: no copy of \(db) was made ("))
        #expect(short.problem?.hasSuffix("MB database, 0 MB free; twice its size is needed") == true)
        #expect(SchemaCheck.freeBytes(dir).map { $0 > 0 } == true)
    }
}
