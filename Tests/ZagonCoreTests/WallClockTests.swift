import Foundation
import Testing
@testable import ZagonCore

/// "Sessions worked" is wall-clock everywhere (`SessionTime.wall`): parallel sessions count once; their sum is agent
/// time, a second number.
@Suite struct WallClockTests {
    let day = "2026-10-29"
    func h(_ x: Double) -> Double { D0 + x * H }

    /// MCP `day` / `week` text through the server, as a client calls it.
    func mcp(_ store: Store, _ tool: String, _ args: String) throws -> String {
        let server = ZagonMCP.server(store: store, exportDir: tempDir(), now: { D0 + 20 * H })
        let out = try #require(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(args)}}"#))
        return try #require(JValue.parse(out)?["result"]?["content"]?.array?.first?["text"]?.string)
    }

    /// Three sessions working the same two hours: two hours in every output, six hours of agent time.
    @Test func threeParallelSessionsAreTwoHours() throws {
        let f = try Fixture()
        for s in ["lead", "w1", "w2"] { try f.session("claude:" + s, title: "example-project " + s, working: [(h(9), h(11))]) }
        let r = try Reports(store: f.store).day(day)
        #expect(abs(r.workedSec - 2 * H) < 1e-6)
        let q = Query(store: f.store)
        let d = try q.day(day)
        #expect(abs(d.workedSec - 2 * H) < 1e-6 && abs(d.sessionSec - 6 * H) < 1e-6)
        let w = try q.week(from: day)
        #expect(abs(w.totals.workedSec - 2 * H) < 1e-6 && abs(w.totals.sessionSec - 6 * H) < 1e-6)
        #expect(try q.hours(from: day, count: 2) == [2, 0])

        let week = try Reports(store: f.store).week(ending: day)
        #expect(abs(week.workedSec - 2 * H) < 1e-6 && abs(week.days.last!.workedSec - 2 * H) < 1e-6)

        var facts = DaySummary.Facts(day: day)
        facts.workedSec = r.workedSec; facts.sessionSec = 6 * H
        let ru = DaySummary.headline(facts, Words(en: false)), en = DaySummary.headline(facts, Words(en: true))
        #expect(ru.contains("Сессии работали 2 ч (агентного времени 6 ч)"), "\(ru)")
        #expect(en.contains("Sessions worked 2 h (agent time 6 h)"), "\(en)")

        let md = try mcp(f.store, "day", #"{"date":"\#(day)"}"#)
        #expect(md.contains("time: sessions worked 2h 00m"), "\(md)")
        let mw = try mcp(f.store, "week", #"{"to":"\#(day)"}"#)
        #expect(mw.contains("time: sessions worked 2h 00m") && mw.contains("sessions worked 2h 00m, the user"), "\(mw)")
    }

    /// 10–12 and 11–13: three hours, not four; one session alone has no agent-time note.
    @Test func overlapIsUnion() throws {
        let f = try Fixture()
        try f.session("claude:a", working: [(h(10), h(12))])
        try f.session("claude:b", working: [(h(11), h(13))])
        #expect(abs(try Reports(store: f.store).day(day).workedSec - 3 * H) < 1e-6)
        let d = try Query(store: f.store).day(day)
        #expect(abs(d.workedSec - 3 * H) < 1e-6 && abs(d.sessionSec - 4 * H) < 1e-6)
        #expect(Txt.agent(3 * H, 4 * H) == " (agent time 4h 00m)" && Txt.agent(3 * H, 3 * H + 30) == "")
        #expect(Words(en: true).agent(2 * H, 2 * H) == "")
        // A stretch past midnight counts for each day only inside it.
        try f.session("claude:c", working: [(h(23), h(25))])
        #expect(try Query(store: f.store).hours(from: day, count: 2) == [4, 1])
    }
}
