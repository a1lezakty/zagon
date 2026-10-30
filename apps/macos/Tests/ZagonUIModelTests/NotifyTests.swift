import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// The core's notifier on the app's store, delivered through the app's hook.
final class NotifyTests: XCTestCase {
    final class Sent: @unchecked Sendable {
        let lock = NSLock()
        var titles: [String] = []
        var accept = true
        var on = true
    }

    /// `lang`: `[notify] lang` of the config (nil: no config, the system's language).
    func provider(_ sent: Sent, lang: String? = nil) throws -> StoreDataProvider {
        var config = "/nonexistent/config.toml"
        if let lang {
            config = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-notify-\(UUID().uuidString).toml").path
            try "[notify]\nlang = \"\(lang)\"\n".write(toFile: config, atomically: true, encoding: .utf8)
        }
        let store = try StoreDataProvider.fixtureStore(StoreDataProviderTests.fixtures)
        let p = StoreDataProvider(store: store, writer: store, now: StoreDataProvider.fixtureNow, host: "laptop")
        p.notifications(NotifyHook(deliver: { title, _, _ in
            sent.lock.withLock {
                if sent.accept { sent.titles.append(title) }
                return sent.accept
            }
        }, enabled: { sent.lock.withLock { sent.on } }, remote: { false }, configPath: config))
        return p
    }

    func testSentOnceByTheCoreRules() throws {
        let sent = Sent()
        let p = try provider(sent, lang: "ru")
        p.writeQueue.sync { p.notify() }
        // At 11:42: "demo video" asks for permission since 11:30 (over 10 minutes); api-server finished 38 minutes of work.
        XCTAssertEqual(sent.titles, ["Готово: api-server", "Ждёт тебя 12 мин"])
        p.writeQueue.sync { p.notify() }
        XCTAssertEqual(sent.titles.count, 2)  // remembered in the database
        // The language comes from `[notify] lang` (the core's texts; auto follows the system).
        let en = Sent()
        let q = try provider(en, lang: "en")
        q.writeQueue.sync { q.notify() }
        XCTAssertEqual(en.titles, ["Done: api-server", "Waiting for you 12 min"])
    }

    func testOffAndRetry() throws {
        let sent = Sent()
        sent.on = false
        let p = try provider(sent)
        p.writeQueue.sync { p.notify() }
        XCTAssertEqual(sent.titles, [])
        sent.on = true
        sent.accept = false  // e.g. permission not granted yet
        p.writeQueue.sync { p.notify() }
        XCTAssertEqual(sent.titles, [])
        sent.accept = true
        p.writeQueue.sync { p.notify() }
        XCTAssertEqual(sent.titles.count, 2)
    }
}
