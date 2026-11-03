import ArgumentParser
import ZagonCore

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "MCP server on stdio for Claude Code, Codex and Gemini.",
        discussion: "Register: claude mcp add --scope user zagon -- zagon mcp; codex mcp add zagon -- zagon mcp")
    @Option(help: "Database file (default: <data-dir>/zagon.db).") var db: String?
    @Flag(help: "Do not scan transcripts before answering.") var noScan = false
    @OptionGroup var common: Common

    func run() throws {
        common.applyTimezone()
        let store = try db.map { try Store(path: $0) } ?? common.open()
        let log: (String) -> Void = { _ = Sys.writeAll(fd: 2, Array(($0 + "\n").utf8)) }
        let refresh: (() throws -> Void)? = noScan ? nil : { try common.scan(store) }
        if let e = try common.worklog(store).jiraSetupError { log("mcp: jira: \(e)") }
        let tasks = TaskTools(store: store, worklog: { try common.worklog(store) }, suggester: { try common.suggester(store) },
                              refresh: refresh, exportDir: common.dataDir + "/exports", log: log)
        let handoff = HandoffTools(store: store, claudeDir: common.claudeDir, codexHome: common.codexDir,
                                   moreClaudeDirs: common.claudeRoots(store).dropFirst().map(\.root))
        let server = ZagonMCP.server(store: store, exportDir: common.dataDir + "/exports", refresh: refresh,
                                     handoff: handoff, tasks: tasks, paths: ZagonPaths(dir: common.dataDir), log: log)
        // stdout carries protocol lines only.
        server.run(readLine: { readLine() }, write: { _ = Sys.writeAll(fd: 1, Array(($0 + "\n").utf8)) })
    }
}
