import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

final class RemoteTests: XCTestCase {
    func testSshHosts() {
        let config = "Host build-box gpu-box\n  HostName 10.0.0.2\nHost *\n  User me\nhost=laptop\nHost !bad b?x\n"
        XCTAssertEqual(Remote.sshHosts(config), ["build-box", "gpu-box", "laptop"])
    }

    /// The fixture store exported as a server would, imported under an ssh alias: same totals, lanes, agents and
    /// tools; the server's host name maps to the alias.
    func testExportImportKeepsTotals() throws {
        let server = try StoreDataProvider.fixtureStore(StoreDataProviderTests.fixtures)
        func export(since: Int) throws -> Data {
            var out = ""
            try Export.run(store: server, since: since) { out += $0 + "\n" }
            return Data(out.utf8)
        }
        let client = try Store(path: ":memory:")
        let first = try Remote.apply(try export(since: 0), alias: "build-box", store: client)
        XCTAssertEqual(first.sessions, 47)
        XCTAssertGreaterThan(first.days, 25)
        XCTAssertEqual(first.hosts, ["laptop"])
        XCTAssertEqual(try Remote.aliases(db: client.db), ["laptop": "build-box"])
        let seq = try Remote.cursor("build-box", db: client.db)
        XCTAssertGreaterThan(seq, 0)

        func same() throws {
            for day in ["2026-10-01", "2026-10-29", "2026-10-30"] {
                let a = try Query(store: server).day(day), b = try Query(store: client).day(day)
                XCTAssertEqual(a.tokens.total, b.tokens.total, day)
                XCTAssertEqual(a.cost, b.cost, accuracy: 1e-9, day)
                XCTAssertEqual(a.sessionSec, b.sessionSec, accuracy: 1e-6, day)
                XCTAssertEqual(a.userSec, b.userSec, accuracy: 1e-6, day)
                XCTAssertEqual(a.byHost, b.byHost, day)
                XCTAssertEqual(a.byAgent, b.byAgent, day)
                XCTAssertEqual(a.byTool.map { "\($0.name) \($0.count)" }, b.byTool.map { "\($0.name) \($0.count)" }, day)
                XCTAssertEqual(a.lanes, b.lanes, day)
            }
        }
        try same()
        let now = StoreDataProvider.fixtureNow.timeIntervalSince1970
        XCTAssertEqual(try Query(store: client).limits(now: now).map(\.usedPct), try Query(store: server).limits(now: now).map(\.usedPct))

        // Nothing new on the server: only the limit lines come again, totals stay.
        XCTAssertEqual(try Remote.apply(try export(since: seq), alias: "build-box", store: client),
                       Remote.Imported(sessions: 0, days: 0, limits: first.limits))
        try same()

        // A rebuilt server (its counter went back) is pulled from zero next time.
        try Remote.apply(Data("{\"type\":\"export\",\"schema\":3,\"since\":0,\"seq\":1}\n".utf8), alias: "build-box", store: client)
        XCTAssertEqual(try Remote.cursor("build-box", db: client.db), 0)
        XCTAssertThrowsError(try Remote.apply(Data("{\"type\":\"session\"}\n".utf8), alias: "build-box", store: client))
    }

    func testRefusedExports() throws {
        let server = try StoreDataProvider.fixtureStore(StoreDataProviderTests.fixtures)
        var text = ""
        try Export.run(store: server, since: 0) { text += $0 + "\n" }
        let export = Data(text.utf8)
        let client = try Store(path: ":memory:")
        XCTAssertThrowsError(try Remote.apply(Data(), alias: "build-box", store: client))
        XCTAssertThrowsError(try Remote.apply(export, alias: "self", store: client, localHost: "laptop"))
        // A Mac whose database was pinned to "laptop" (it may be called otherwise on this network now).
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-pin-\(UUID().uuidString).db").path
        defer { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + x) } }
        try Store(path: path).db.run("UPDATE meta SET value = 'laptop' WHERE key = 'host'")
        let pinned = try Store(path: path)
        XCTAssertEqual(pinned.host, "laptop")
        XCTAssertThrowsError(try Remote.apply(export, alias: "self", store: pinned)) { XCTAssertEqual(Remote.brief($0), "this is this Mac") }
        XCTAssertEqual(try Remote.cursor("self", db: client.db), 0)

        try Remote.apply(export, alias: "build-box", store: client, checked: ["build-box", "build-ip"])
        // The same server under a second checked alias would be counted twice.
        XCTAssertThrowsError(try Remote.apply(export, alias: "build-ip", store: client, checked: ["build-box", "build-ip"])) {
            XCTAssertEqual(Remote.brief($0), "same server as build-box")
        }
        // A rename whose import fails keeps the old alias's rows and cursor.
        let seq = try Remote.cursor("build-box", db: client.db)
        let broken = Data("{\"type\":\"export\",\"seq\":1}\n{\"type\":\"day\",\"host\":\"laptop\"}\n{\"type\":\"session\", \"t".utf8)
        XCTAssertThrowsError(try Remote.apply(broken, alias: "build-ip", store: client, checked: ["build-ip"]))
        XCTAssertEqual(try Remote.cursor("build-box", db: client.db), seq)
        XCTAssertEqual(try Remote.aliases(db: client.db), ["laptop": "build-box"])
        // Renamed: the old alias is unchecked, its rows go and the new one imports the server once.
        try Remote.apply(export, alias: "build-ip", store: client, checked: ["build-ip"])
        XCTAssertEqual(try Remote.aliases(db: client.db), ["laptop": "build-ip"])
        XCTAssertEqual(try Remote.cursor("build-box", db: client.db), 0)
        let a = try Query(store: server).day("2026-10-29"), b = try Query(store: client).day("2026-10-29")
        XCTAssertEqual(a.byAgent, b.byAgent)
        XCTAssertEqual(a.lanes, b.lanes)

        let bad = Data("{\"type\":\"export\",\"seq\":1}\n{\"type\":\"session\", \"title\": \"secret".utf8)
        XCTAssertThrowsError(try Remote.apply(bad, alias: "build-ip", store: client, checked: ["build-ip"])) {
            XCTAssertEqual(Remote.brief($0), "a line of the export could not be read")
        }
        XCTAssertEqual(Remote.scrubHomes("open /home/alex/.zagon/zagon.db, /Users/al/x and /root: no"), "open ~/.zagon/zagon.db, ~/x and ~: no")
    }

    /// Unchecking a server takes its rows out of the numbers; a zagon from before export2 is told apart, and once it
    /// is updated the server is pulled again from the start.
    func testDropAndOldServer() throws {
        let server = try StoreDataProvider.fixtureStore(StoreDataProviderTests.fixtures)
        var text = ""
        try Export.run(store: server, since: 0) { text += $0 + "\n" }
        let client = try Store(path: ":memory:")
        let n = try Remote.apply(Data(text.utf8), alias: "build-box", store: client, checked: ["build-box"])
        XCTAssertFalse(n.old)
        XCTAssertGreaterThan(try Query(store: client).day("2026-10-29").tokens.total, 0)
        try Remote.drop("build-box", db: client.db)
        let gone = try Query(store: client).day("2026-10-29")
        XCTAssertEqual(gone.tokens.total, 0)
        XCTAssertEqual(gone.sessionSec, 0)
        XCTAssertEqual(try client.db.one("SELECT count(*) FROM session") { $0.int(0) }, 0)
        XCTAssertEqual(try client.db.one("SELECT count(*) FROM day_agg") { $0.int(0) }, 0)
        XCTAssertEqual(try Remote.aliases(db: client.db), [:])
        XCTAssertEqual(try Remote.cursor("build-box", db: client.db), 0)

        let old = Data("""
            {"type":"export","schema":3,"since":0,"seq":7}
            {"type":"day","day":"2026-10-29","host":"srv","seq":7,"start":1793232000,"end":1793318400,"rows":[]}

            """.utf8)
        XCTAssertTrue(try Remote.apply(old, alias: "srv", store: client).old)
        XCTAssertEqual(try Remote.cursor("srv", db: client.db), 7)
        // An incremental pull with no days says nothing new: the server is still the old one.
        XCTAssertTrue(try Remote.apply(Data("{\"type\":\"export\",\"seq\":8}\n".utf8), alias: "srv", store: client).old)
        let updated = Data("""
            {"type":"export","schema":4,"since":8,"seq":9}
            {"type":"day","day":"2026-10-30","host":"srv","seq":9,"start":1793318400,"end":1793404800,"rows":[],"usage":[],"tools":[],"user":[]}

            """.utf8)
        XCTAssertFalse(try Remote.apply(updated, alias: "srv", store: client).old)
        XCTAssertEqual(try Remote.cursor("srv", db: client.db), 0, "the days it sent without usage are pulled again")
    }

    /// The advice under a server comes from the `version` in the first line of its export.
    func testVersionHint() throws {
        let client = try Store(path: ":memory:")
        let header = { (v: String) in Data("{\"type\":\"export\",\"schema\":4,\"since\":0,\"seq\":1\(v)}\n".utf8) }
        XCTAssertEqual(try Remote.apply(header(",\"version\":\"0.1.0\""), alias: "srv", store: client).version, "0.1.0")
        XCTAssertNil(try Remote.apply(header(""), alias: "srv", store: client).version)
        XCTAssertEqual(Remote.hint(server: "0.1.0", app: "0.2.0"), "servers.update")
        XCTAssertEqual(Remote.hint(server: "0.9.9", app: "0.10.0"), "servers.update")
        XCTAssertNil(Remote.hint(server: "0.2.0", app: "0.2.0"))
        XCTAssertNil(Remote.hint(server: "1.0.0", app: "0.2.0"))
        XCTAssertNil(Remote.hint(server: "dev", app: "0.2.0"))
        XCTAssertEqual(Remote.hint(server: nil, app: "0.2.0"), "servers.reinstall")
        XCTAssertNil(Remote.hint(server: nil, app: nil), "swift run: no version to compare")
        XCTAssertNil(Remote.hint(server: "0.1.0", app: "dev"))
    }

    func testPullReadsBothPipesAndTimesOut() throws {
        // 200 KB of stderr before stdout would block a reader that drains stdout first.
        let loud = try Remote.pull(host: "x", since: 0, controlDir: "", timeout: 20, executable: "/bin/sh",
                                   arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo ok"])
        XCTAssertEqual(String(decoding: loud, as: UTF8.self), "ok\n")
        XCTAssertThrowsError(try Remote.pull(host: "x", since: 0, controlDir: "", executable: "/bin/sh",
                                             arguments: ["-c", "echo nope /home/al/.ssh >&2; exit 255"])) {
            XCTAssertEqual(Remote.brief($0), "exit 255: nope ~/.ssh")
        }
        let started = Date()
        XCTAssertThrowsError(try Remote.pull(host: "x", since: 0, controlDir: "", timeout: 1, executable: "/bin/sh",
                                             arguments: ["-c", "sleep 5"]))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testSshArguments() {
        let a = Remote.sshArguments(host: "build-box", since: 42, controlDir: "/tmp/z")
        XCTAssertEqual(a.prefix(2), ["-o", "BatchMode=yes"])
        XCTAssertTrue(a.contains("ControlPath=/tmp/z/%C"))
        XCTAssertEqual(a.suffix(2), ["build-box", "PATH=\"$HOME/.local/bin:$PATH\" zagon export --since 42"])
    }
}

final class DiagTests: XCTestCase {
    func testLogRotatesAndScrubsHome() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-log-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = Log(maxBytes: 200, keep: 2)
        log.write("dropped before start")
        log.start(dir: dir)
        for i in 0..<20 { log.write("line \(i) in \(NSHomeDirectory())/.zagon/zagon.db") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        XCTAssertEqual(files, ["zagon.1.log", "zagon.2.log", "zagon.log"])
        let all = try files.map { try String(contentsOfFile: dir + "/" + $0, encoding: .utf8) }.joined()
        XCTAssertFalse(all.contains(NSHomeDirectory()))
        XCTAssertTrue(all.contains("line 19 in ~/.zagon/zagon.db"))
        XCTAssertFalse(all.contains("dropped"))
        for f in files { XCTAssertLessThanOrEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/" + f)).count, 200) }

        let info = Diagnostics.info(version: "0.1 (5)", system: "macOS 15.1", counters: [("session", 47)], dbBytes: 2_500_000,
                                    hostErrors: ["gpu-box": "ssh gpu-box: exit 255 \(NSHomeDirectory())/.ssh/config: bad"],
                                    servers: ["build-box", "gpu-box"], at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(info.contains("  session: 47\n"))
        XCTAssertTrue(info.contains("  build-box: ok\n  gpu-box: error: ssh gpu-box: exit 255 ~/.ssh/config: bad\n"))
        let out = try Diagnostics.folder(logs: dir, info: info, in: dir, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out).sorted(),
                       ["info.txt", "zagon.1.log", "zagon.2.log", "zagon.log"])
        XCTAssertEqual(Diagnostics.health(rss: 48_200_000, cpuPct: 0.42, dbBytes: 12_500_000, scanErrors: 0, servers: 2, offline: 1),
                       "health rss=48.2MB cpu=0.4% db=12.5MB scanErrors=0 servers=1/2")
    }
}
