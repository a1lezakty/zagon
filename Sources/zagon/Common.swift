import ArgumentParser
import ZagonCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

struct Common: ParsableArguments {
    @Option(help: "Zagon data directory ($ZAGON_DIR or ~/.zagon).") var dataDir: String = ZagonPaths().dir
    @Option(help: "Claude Code projects directory.") var claudeDir: String = home() + "/.claude/projects"
    @Option(help: "Codex home ($CODEX_HOME or ~/.codex).") var codexDir: String = CodexSource.defaultHome()
    @Option(help: "Minutes between your actions that still count as one stretch of work.") var idleGap: Double = 20
    @Option(help: "Minutes of agent silence that end a session's working interval.") var sessionGap: Double = 30
    @Flag(help: "Do not index typed messages for search.") var noIndexPrompts = false

    static func home() -> String { getenv("HOME").map { String(cString: $0) } ?? "." }

    /// Days of every report follow `[notify] timezone` in config.toml, as in the daemon: a scan from the CLI or MCP
    /// rebuilds the same day rows, so it must cut them at the same midnight.
    func applyTimezone() { Settings.applyTimezone(ZagonPaths(dir: dataDir)) }

    func open() throws -> Store {
        applyTimezone()
        mkdir(dataDir, 0o700)
        return try Store(path: dataDir + "/zagon.db")
    }

    func ingest(_ store: Store, roots: [(root: String, account: String)]? = nil) -> Ingest {
        var o = IngestOptions()
        o.idleGap = idleGap * 60; o.sessionGap = sessionGap * 60; o.indexPrompts = !noIndexPrompts
        o.keyPattern = Settings.keyPattern(ZagonPaths(dir: dataDir))
        return Ingest(store: store, sources: (roots ?? claudeRoots(store)).map {
            ClaudeSource.spec(root: $0.root, indexPrompts: !noIndexPrompts, account: $0.account)
        } + CodexSource.specs(codexHome: codexDir) + CursorSource.specs(paths: ZagonPaths(dir: dataDir)), options: o)
    }

    /// `--claude-dir` (the default account) and the `projects` folders of the other Claude Code accounts
    /// (`Accounts.claudeRoots`: `[accounts]` in config.toml and the folders hooks reported).
    func claudeRoots(_ store: Store?) -> [(root: String, account: String)] {
        Accounts.claudeRoots(defaultRoot: claudeDir, paths: ZagonPaths(dir: dataDir), db: store?.db)
    }

    /// One incremental pass: transcripts and rollouts, Cursor's conversation list, then Codex's own thread index (titles,
    /// archived).
    @discardableResult
    func scan(_ store: Store) throws -> IngestStats {
        let ingest = ingest(store), paths = ZagonPaths(dir: dataDir)
        let stats = try ingest.scan()
        if CursorHeaders.sync(store: store, paths: paths) { try ingest.update(paths: [CursorHeaders.file(paths)]) }
        try CodexThreads.sync(store: store, codexHome: codexDir, host: ingest.host)
        return stats
    }
}

/// Options of the report commands.
struct ReportOptions: ParsableArguments {
    @Flag(help: "Print JSON.") var json = false
    @Flag(help: "Skip the incremental scan before reporting.") var noScan = false
}

func emit<T: Encodable>(_ v: T) throws {
    let e = JSONEncoder()
    e.keyEncodingStrategy = .convertToSnakeCase
    e.outputFormatting = [.sortedKeys]
    print(String(decoding: try e.encode(v), as: UTF8.self))
}

func prepare(_ c: Common, _ r: ReportOptions) throws -> Store {
    let store = try c.open()
    if !r.noScan { try c.scan(store) }
    return store
}
