import ArgumentParser
import ZagonCore

/// Called by Claude Code / Codex hooks. Always exits 0 and prints nothing (see `HookSpool.handleHook`).
struct HookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook", abstract: "Record a hook event (called by Claude Code and Codex): zagon hook <claude|codex> <event>",
        shouldDisplay: false)

    @Argument(parsing: .allUnrecognized) var args: [String] = []

    func run() { HookSpool.handleHook(args: args) }
}
