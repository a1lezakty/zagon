import ArgumentParser
import ZagonCore

/// Claude Code status-line wrapper: records rate limits, then runs the original status-line command.
struct StatusLineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statusline", abstract: "Claude Code status line wrapper (reads the status JSON on stdin).",
        shouldDisplay: false)

    @Argument(parsing: .allUnrecognized) var args: [String] = []

    func run() throws {
        let rc = StatusLine.run()
        if rc != 0 { throw ExitCode(rc) }
    }
}
