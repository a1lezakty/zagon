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
}
