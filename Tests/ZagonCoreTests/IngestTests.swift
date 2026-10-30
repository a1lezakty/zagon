import Foundation
import Testing
@testable import ZagonCore

/// A temp Claude projects dir, an in-memory store and an Ingest over it.
final class ClaudeEnv {
    let root = tempDir()
    let store: Store
    let ingest: Ingest

    init(_ configure: (inout IngestOptions) -> Void = { _ in }) {
        var o = IngestOptions()
        o.host = "test"
        o.dedupDays = 1e6  // fixed dates in the past must stay in the dedup ledger
        configure(&o)
        store = try! Store(path: ":memory:")
        ingest = Ingest(store: store, sources: [ClaudeSource.spec(root: root)], options: o)
    }
    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ rel: String) -> String { root + "/" + rel }

    /// Replaces the file in place (same inode).
    func write(_ rel: String, _ text: String) {
        try! FileManager.default.createDirectory(atPath: (path(rel) as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: path(rel)) {
            h.truncateFile(atOffset: 0); h.write(text.data(using: .utf8)!); h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path(rel), contents: text.data(using: .utf8)!)
        }
    }
    func write(_ rel: String, lines: [String]) { write(rel, lines.map { $0 + "\n" }.joined()) }

    func append(_ rel: String, _ text: String) {
        let h = FileHandle(forWritingAtPath: path(rel))!
        h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); h.closeFile()
    }

    /// A new file renamed over the old path (new inode), like an atomic rewrite or log rotation.
    func replace(_ rel: String, lines: [String]) {
        let tmp = path(rel) + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: lines.map { $0 + "\n" }.joined().data(using: .utf8)!)
        #expect(rename(tmp, path(rel)) == 0)
    }

    @discardableResult func scan() -> IngestStats { try! ingest.scan() }

    func inode(_ rel: String) -> Int { var sb = stat(); stat(path(rel), &sb); return Int(sb.st_ino) }

    func int(_ sql: String, _ args: [SQLValue] = []) -> Int { try! store.db.one(sql, args) { $0.int(0) } ?? 0 }
    func real(_ sql: String, _ args: [SQLValue] = []) -> Double { try! store.db.one(sql, args) { $0.real(0) } ?? 0 }
    func tokens() -> (input: Int, output: Int, requests: Int) { try! totals(store) }
    func toolCalls() -> Int { int("SELECT coalesce(sum(n),0) FROM tool_use") }
}

let mainFile = "-w-alpha/S.jsonl"

@Suite struct IngestTests {
    @Test func partialLastLineWaitsForItsNewline() {
        let env = ClaudeEnv()
        let a = assistantLine(T0, id: "m1", input: 10, output: 1), b = assistantLine(T0 + 60, id: "m2", input: 20, output: 2)
        let cut = b.index(b.startIndex, offsetBy: b.count / 2)
        env.write(mainFile, a + "\n" + b[..<cut])
        var st = env.scan()
        #expect(env.tokens() == (10, 1, 1) && st.lines == 1)
        #expect(env.int("SELECT offset FROM source_file") == a.utf8.count + 1)
        st = env.scan()  // still no newline
        #expect(env.tokens() == (10, 1, 1) && st.lines == 0 && st.badLines == 0)
        env.append(mainFile, String(b[cut...]))
        env.scan()
        #expect(env.tokens() == (10, 1, 1))
        env.append(mainFile, "\n")
        st = env.scan()
        #expect(env.tokens() == (30, 3, 2) && st.lines == 1 && st.badLines == 0)
        st = env.scan()
        #expect(env.tokens() == (30, 3, 2) && st.filesRead == 0)
    }

    @Test func truncationRetractsAndRecounts() {
        let env = ClaudeEnv()
        let lines = [typed(T0), assistantLine(T0 + 60, id: "m1", input: 10, output: 1, tools: [("toolu_1", "Bash")]),
                     toolResult(T0 + 120), assistantLine(T0 + 180, id: "m2", input: 20, output: 2, tools: [("toolu_2", "Read")])]
        env.write(mainFile, lines: lines)
        env.scan()
        #expect(env.tokens() == (30, 3, 2) && env.toolCalls() == 2)
        let ino = env.inode(mainFile)
        env.write(mainFile, lines: Array(lines.prefix(2)))
        #expect(env.inode(mainFile) == ino)
        let st = env.scan()
        #expect(st.resets == 1)
        #expect(env.tokens() == (10, 1, 1) && env.toolCalls() == 1)
        #expect(env.int("SELECT count(*) FROM user_action WHERE kind='msg'") == 1)
        #expect(env.real("SELECT \"end\" - start FROM activity") == 60)
        #expect(env.int("SELECT resets FROM source_file") == 1)
        // Growing again after the reset tails normally.
        env.append(mainFile, lines[3] + "\n")
        #expect(env.scan().resets == 0)
        #expect(env.tokens() == (30, 3, 2) && env.toolCalls() == 2)
    }

    @Test func replacementWithNewInodeRecounts() {
        let env = ClaudeEnv()
        let lines = [typed(T0), assistantLine(T0 + 60, id: "m1", input: 10, output: 1, tools: [("toolu_1", "Bash")])]
        env.write(mainFile, lines: lines)
        env.scan()
        let ino = env.inode(mainFile)
        // Same bytes plus one more record, but a new file: everything is recounted once.
        env.replace(mainFile, lines: lines + [assistantLine(T0 + 120, id: "m2", input: 5, output: 5, tools: [("toolu_2", "Bash")])])
        #expect(env.inode(mainFile) != ino)
        let st = env.scan()
        #expect(st.resets == 1 && st.moves == 0)
        #expect(env.tokens() == (15, 6, 2) && env.toolCalls() == 2)
        #expect(env.int("SELECT count(*) FROM user_action") == 1)
        #expect(env.int("SELECT count(*) FROM source_file") == 1)
        // A shorter replacement.
        env.replace(mainFile, lines: [assistantLine(T0, id: "m9", input: 1, output: 1)])
        #expect(env.scan().resets == 1)
        #expect(env.tokens() == (1, 1, 1) && env.toolCalls() == 0 && env.int("SELECT count(*) FROM user_action") == 0)
    }

    @Test func inPlaceRewriteWithDifferentBytesRecounts() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [assistantLine(T0, id: "m1", input: 10, output: 1),
                                    assistantLine(T0 + 60, id: "m2", input: 20, output: 2)])
        env.scan()
        let ino = env.inode(mainFile)
        // Longer than before, the old part changed: the tail before the stored offset does not match.
        env.write(mainFile, lines: [assistantLine(T0, id: "m1", input: 100, output: 10),
                                    assistantLine(T0 + 60, id: "m2", input: 200, output: 20),
                                    assistantLine(T0 + 120, id: "m3", input: 300, output: 30)])
        #expect(env.inode(mainFile) == ino)
        #expect(env.scan().resets == 1)
        #expect(env.tokens() == (600, 60, 3))
        // Rewritten with the same old bytes and a new record: plain tailing, no reset.
        env.write(mainFile, lines: [assistantLine(T0, id: "m1", input: 100, output: 10),
                                    assistantLine(T0 + 60, id: "m2", input: 200, output: 20),
                                    assistantLine(T0 + 120, id: "m3", input: 300, output: 30),
                                    assistantLine(T0 + 180, id: "m4", input: 1, output: 1)])
        #expect(env.scan().resets == 0)
        #expect(env.tokens() == (601, 61, 4))
    }

    @Test func deletedFileKeepsItsContribution() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + 60, id: "m1", input: 10, output: 1)])
        env.write("-w-alpha/S2.jsonl", lines: [typed(T0, session: "S2"), assistantLine(T0 + 120, id: "m2", input: 5, output: 5, session: "S2")])
        env.scan()
        let day = Time.dayString(T0)
        func dayRow() -> [Double] {
            try! env.store.db.one("SELECT input, output, session_sec, user_sec FROM day_agg WHERE day=? AND tool='' AND project='' AND model=''", [.text(day)]) {
                [$0.real(0), $0.real(1), $0.real(2), $0.real(3)]
            } ?? []
        }
        let before = dayRow()
        #expect(before == [15, 6, 180, 0])
        try! FileManager.default.removeItem(atPath: env.path(mainFile))
        env.scan()
        #expect(env.tokens() == (15, 6, 2) && dayRow() == before)
        #expect(env.int("SELECT count(*) FROM source_file") == 2)
    }

    @Test func lastRecordOfAMessageIdWins() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [assistantLine(T0, id: "m1", input: 7, output: 5, cacheRead: 100, cacheWrite: 50),
                                    assistantLine(T0 + 1, id: "m1", input: 7, output: 10, cacheRead: 100, cacheWrite: 50),
                                    assistantLine(T0 + 2, id: "m1", input: 7, output: 20, cacheRead: 100, cacheWrite: 50),
                                    assistantLine(T0 + 3, id: "m2", input: 1, output: 1)])
        env.scan()
        #expect(env.tokens() == (8, 21, 2))
        #expect(env.int("SELECT sum(cache_read + cache_write) FROM usage_hour") == 150)
    }

    @Test func lastRecordWinsAcrossScans() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [assistantLine(T0 + 59 * minute, id: "m1", input: 7, output: 5)])
        env.scan()
        #expect(env.tokens() == (7, 5, 1))
        // The final record of the same request lands in the next hour: the old hour row goes away.
        env.append(mainFile, assistantLine(T0 + 61 * minute, id: "m1", input: 7, output: 20) + "\n")
        env.scan()
        #expect(env.tokens() == (7, 20, 1))
        #expect(env.int("SELECT count(*) FROM usage_hour") == 1)
        #expect(env.int("SELECT hour FROM usage_hour") == Time.hour(T0 + hour))
    }

    @Test func lastRecordWinsAcrossApplyChunks() {
        let env = ClaudeEnv { $0.applyBytes = 1 }
        // More than the 1 MiB read buffer between the two records: they are parsed and applied in different chunks.
        let filler = (0..<300).map { #"{"type":"progress","data":"\#(String(repeating: "x", count: 4000))","n":\#($0)}"# }
        env.write(mainFile, lines: [assistantLine(T0, id: "m1", input: 7, output: 5, tools: [("toolu_1", "Bash")])] + filler +
                  [assistantLine(T0 + 2 * hour, id: "m1", input: 7, output: 20, tools: [("toolu_1", "Bash")]),
                   assistantLine(T0 + 2 * hour, id: "m2", input: 1, output: 1)])
        let st = env.scan()
        #expect(st.bytes > 1 << 20 && st.badLines == 0)
        #expect(env.tokens() == (8, 21, 2) && env.toolCalls() == 1)
        #expect(env.int("SELECT count(*) FROM usage_hour") == 1)
    }

    @Test func copiedMessageIdInAnotherFileIsIgnored() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + 60, id: "m1", input: 10, output: 1, tools: [("toolu_1", "Bash")])])
        env.scan()
        // A resumed session copies the history (same message and tool ids) into a new file, then goes on.
        env.write("-w-alpha/R.jsonl", lines: [
            typed(T0, session: "R"),
            assistantLine(T0 + 60, id: "m1", input: 10, output: 99, tools: [("toolu_1", "Bash")], session: "R"),
            assistantLine(T0 + 300, id: "m3", input: 2, output: 2, tools: [("toolu_3", "Bash")], session: "R"),
        ])
        env.scan()
        #expect(env.tokens() == (12, 3, 2) && env.toolCalls() == 2)
        #expect(env.int("SELECT sum(input) FROM usage_hour WHERE session_id='claude:R'") == 2)
        // The original file grows: still counted under its own session.
        env.append(mainFile, assistantLine(T0 + 60, id: "m1", input: 10, output: 4) + "\n")
        env.scan()
        #expect(env.tokens() == (12, 6, 2))
    }

    @Test func repeatedToolCallIdsCountOnce() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [assistantLine(T0, id: "m1", tools: [("toolu_1", "Bash")]),
                                    assistantLine(T0 + 1, id: "m1", tools: [("toolu_1", "Bash"), ("toolu_2", "Edit")]),
                                    assistantLine(T0 + 2, id: "m2", tools: [("toolu_2", "Edit")])])
        env.scan()
        env.append(mainFile, assistantLine(T0 + 3, id: "m3", tools: [("toolu_1", "Bash")]) + "\n")
        env.scan()
        #expect(env.toolCalls() == 2)
        #expect(env.int("SELECT n FROM tool_use WHERE name='Bash'") == 1 && env.int("SELECT n FROM tool_use WHERE name='Edit'") == 1)
    }

    @Test func subAgentFilesCountUnderTheParentSession() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + 60, id: "m1", input: 1, output: 1, tools: [("toolu_t", "Task")])])
        env.write("-w-alpha/S/subagents/agent-a1.jsonl", lines: [
            typed(T0 + 61, "do part one"), assistantLine(T0 + 120, id: "s1", input: 100, output: 10)])
        env.write("-w-alpha/S/subagents/workflows/wf_1/agent-b2.jsonl", lines: [
            typed(T0 + 61, "do part two"), assistantLine(T0 + 180, id: "s2", input: 200, output: 20)])
        env.write("-w-alpha/S/subagents/workflows/wf_1/journal.jsonl", lines: [assistantLine(T0, id: "j", input: 9999)])
        env.write("-w-alpha/S/subagents/agent-a1.meta.json", "{}")
        let st = env.scan()
        #expect(st.filesSeen == 3)
        #expect(env.tokens() == (301, 31, 3))
        var rows: [String] = []
        try! env.store.db.query("SELECT session_id, agent, input FROM usage_hour ORDER BY input") {
            rows.append("\($0.text(0)!) \($0.text(1)!) \($0.int(2))")
        }
        #expect(rows == ["claude:S  1", "claude:S agent-a1 100", "claude:S agent-b2 200"])
        #expect(env.int("SELECT count(*) FROM session") == 1)
        #expect(env.int("SELECT user_msgs FROM session") == 1)
        #expect(try! env.store.db.one("SELECT project FROM session") { $0.text(0) } == "alpha")
    }

    @Test func badLinesAreCountedPerFile() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [#"{"type":"assistant","message":"#, assistantLine(T0, id: "m1", input: 1), "garbage", ""])
        let st = env.scan()
        #expect(st.badLines == 1 && st.lines == 3)
        #expect(env.int("SELECT bad_lines FROM source_file") == 1 && env.tokens() == (1, 0, 1))
    }
}
