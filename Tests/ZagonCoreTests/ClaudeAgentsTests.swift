import Testing
@testable import ZagonCore

@Suite struct ClaudeAgentsTests {
    let a = "0f6c2d4e-1111-4a2b-9c3d-000000000001", b = "0f6c2d4e-2222-4a2b-9c3d-000000000002"
    let t0 = 1_761_800_000.0

    func status(_ s: Store, _ id: String) throws -> (String?, Double?) {
        try s.db.one("SELECT status, status_at FROM session WHERE id = ?", [.text(id)]) { ($0.text(0), $0.optReal(1)) } ?? (nil, nil)
    }

    @Test func mapping() {
        typealias E = ClaudeAgents.Entry
        let m: [(E, String?)] = [
            (E(sessionId: a, status: "busy"), "working"),
            (E(sessionId: a, status: "waiting", waitingFor: "permission prompt"), "waiting_permission"),
            (E(sessionId: a, status: "waiting", waitingFor: "sandbox request"), "waiting_permission"),
            (E(sessionId: a, status: "waiting", waitingFor: "worker request"), "waiting_permission"),
            (E(sessionId: a, status: "waiting", waitingFor: "input needed"), "waiting_permission"),
            (E(sessionId: a, status: "waiting", waitingFor: "dialog open"), "waiting_input"),
            (E(sessionId: a, status: "waiting", waitingFor: "something new"), "waiting_input"),
            (E(sessionId: a, status: "waiting"), "waiting_input"),
            (E(sessionId: a, status: "idle"), "waiting_input"),
            (E(sessionId: a, status: "idle", state: "done"), "waiting_input"),
            (E(sessionId: a, status: "idle", state: "blocked"), "waiting_permission"),
            (E(sessionId: a, status: "idle", state: "working"), nil),
            (E(sessionId: a, status: "busy", state: "working"), "working"),
            (E(sessionId: a, status: "napping"), nil),
            (E(sessionId: a, state: "done"), "waiting_input"),
            (E(sessionId: a, state: "blocked"), "waiting_permission"),
            (E(sessionId: a, state: "failed"), "ended"),
            (E(sessionId: a, state: "stopped"), "ended"),
            (E(sessionId: a, state: "working"), nil),
            (E(sessionId: a), nil),
        ]
        for (e, want) in m { #expect(ClaudeAgents.status(e) == want, "\(e)") }
    }

    @Test func parse() {
        let out = """
            [{"cwd":"/work/example-project","kind":"interactive","startedAt":1761800000000,"sessionId":"\(a)",
              "name":"example","pid":4242,"status":"waiting","waitingFor":"permission prompt"},
             {"cwd":"/work/example-project","kind":"interactive","startedAt":1761800000000},
             {"cwd":"/work/example-project","kind":"background","startedAt":1761800000000,"id":"bg1","sessionId":"\(b)",
              "state":"done"}, 7]
            """
        #expect(ClaudeAgents.parse(Array(out.utf8)) == [
            .init(sessionId: a, cwd: "/work/example-project", status: "waiting", waitingFor: "permission prompt"),
            .init(sessionId: b, cwd: "/work/example-project", state: "done"),
        ])
        #expect(ClaudeAgents.parse(Array("[]".utf8)) == [])
        // An older Claude Code: help text or an error instead of JSON, or an object.
        for bad in ["Usage: claude [options] [command] [prompt]\n", "error: unknown option '--json'", "{\"error\":1}", ""] {
            #expect(ClaudeAgents.parse(Array(bad.utf8)) == nil)
        }
    }

    @Test func orderingWithHooks() throws {
        let store = try Store(path: ":memory:"), id = "claude:" + a
        try store.mergeSession(SessionMeta(id: id, tool: .claude, cwd: "/work/example-project"))
        _ = try SpoolIngest.setStatus(store: store, id: id, tool: .claude, status: "working", at: t0, cwd: nil)

        // The same status: status_at stays when the state began.
        #expect(try ClaudeAgents.apply([.init(sessionId: a, status: "busy")], store: store, at: t0 + 60) == 0)
        #expect(try status(store, id) == ("working", t0))
        // A newer one wins, dated `lag` before the call.
        #expect(try ClaudeAgents.apply([.init(sessionId: a, status: "idle")], store: store, at: t0 + 90) == 1)
        #expect(try status(store, id) == ("waiting_input", t0 + 90 - ClaudeAgents.lag))
        // A hook after it wins; one from before it (still on its way) does not.
        _ = try SpoolIngest.setStatus(store: store, id: id, tool: .claude, status: "working", at: t0 + 80, cwd: nil)
        #expect(try status(store, id) == ("waiting_input", t0 + 90 - ClaudeAgents.lag))
        _ = try SpoolIngest.setStatus(store: store, id: id, tool: .claude, status: "working", at: t0 + 100, cwd: nil)
        #expect(try status(store, id) == ("working", t0 + 100))
        // A hook just before the call that the database has already seen is not overridden by it.
        #expect(try ClaudeAgents.apply([.init(sessionId: a, status: "idle")], store: store, at: t0 + 102) == 0)
        #expect(try status(store, id) == ("working", t0 + 100))
        // The waiting interval it opened was closed by the hook.
        let waits = try store.db.one("SELECT count(*) FROM activity WHERE session_id = ? AND kind = 'waiting'", [.text(id)]) { $0.int(0) }
        #expect(waits == 1)
    }

    @Test func leavesAbsentUnknownAndEndedAlone() throws {
        let store = try Store(path: ":memory:"), ida = "claude:" + a, idb = "claude:" + b
        for id in [ida, idb] { try store.mergeSession(SessionMeta(id: id, tool: .claude, cwd: "/work/example-project")) }
        _ = try SpoolIngest.setStatus(store: store, id: ida, tool: .claude, status: "ended", at: t0, cwd: nil)
        _ = try SpoolIngest.setStatus(store: store, id: idb, tool: .claude, status: "working", at: t0, cwd: nil)
        let unknown = "0f6c2d4e-3333-4a2b-9c3d-000000000003"
        // An exited background session does not reopen an ended one; an unknown session is not created; b, absent from
        // the list, keeps its status.
        #expect(try ClaudeAgents.apply([.init(sessionId: a, state: "done"), .init(sessionId: unknown, status: "busy")],
                                       store: store, at: t0 + 60) == 0)
        #expect(try status(store, ida) == ("ended", t0) && status(store, idb) == ("working", t0))
        #expect(try store.db.one("SELECT count(*) FROM session") { $0.int(0) } == 2)
        // A live process does (a resumed session).
        #expect(try ClaudeAgents.apply([.init(sessionId: a, status: "busy")], store: store, at: t0 + 60) == 1)
        #expect(try status(store, ida).0 == "working")
    }

    @Test func unsupportedOutputAppliesNothing() throws {
        let store = try Store(path: ":memory:"), id = "claude:" + a
        try store.mergeSession(SessionMeta(id: id, tool: .claude, cwd: "/work/example-project"))
        _ = try SpoolIngest.setStatus(store: store, id: id, tool: .claude, status: "working", at: t0, cwd: nil)
        let entries = ClaudeAgents.parse(Array("error: unknown command 'agents'\n".utf8))
        #expect(entries == nil)
        #expect(try ClaudeAgents.apply(entries ?? [], store: store, at: t0 + 60) == 0)
        #expect(try status(store, id) == ("working", t0))
    }

    @Test func pollsOnlyWhileASessionIsActive() throws {
        let store = try Store(path: ":memory:"), id = "claude:" + a
        #expect(try !ClaudeAgents.active(store: store, host: store.host, now: t0))
        try store.mergeSession(SessionMeta(id: id, tool: .claude, cwd: "/work/example-project"))
        try store.db.run("UPDATE session SET last_at = ?", [.real(t0 - 600)])
        #expect(try ClaudeAgents.active(store: store, host: store.host, now: t0))
        #expect(try !ClaudeAgents.active(store: store, host: store.host, now: t0 + 1800))
        // A session of another machine (an import) does not count; one without a host (made by a hook) does.
        try store.db.run("UPDATE session SET host = 'build-box'")
        #expect(try ClaudeAgents.active(store: store, host: "build-box", now: t0) && !ClaudeAgents.active(store: store, host: "other-box", now: t0))
        _ = try SpoolIngest.setStatus(store: store, id: id, tool: .claude, status: "ended", at: t0 - 60, cwd: nil)
        #expect(try !ClaudeAgents.active(store: store, host: store.host, now: t0))
        try store.db.run("UPDATE session SET tool = 'codex', status = 'working'")
        #expect(try !ClaudeAgents.active(store: store, host: store.host, now: t0))
    }
}
