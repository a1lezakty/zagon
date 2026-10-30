import ArgumentParser
import ZagonCore

/// Options shared by install / uninstall / doctor.
struct InstallFlags: ParsableArguments {
    @Flag(inversion: .prefixedNo, help: "Claude Code hooks and status line.") var claude = true
    @Flag(inversion: .prefixedNo, help: "Codex hooks (default: if ~/.codex exists).") var codex: Bool?
    @Flag(inversion: .prefixedNo, help: "Wrap the Claude Code status line.") var statusline = true
    @Flag(inversion: .prefixedNo, help: "Register the zagon MCP server with the claude / codex CLIs.") var mcp = true
    @Option(name: [.customLong("bin"), .customLong("zagon-path")], help: "Path written into hooks, status line, MCP and the service (default: this binary), e.g. /Applications/Zagon.app/Contents/Helpers/zagon.") var zagonPath: String?

    @Option(help: "Account to install for (default: yours; under sudo, the user who ran sudo).") var user: String?

    func options() throws -> Installer.Options {
        let account: Account?
        do { account = try Account.target(explicit: user) } catch { throw ValidationError("\(error)") }
        var o = Installer.Options(user: account)
        if let zagonPath { o.zagon = zagonPath }
        o.claude = claude
        if let codex { o.codex = codex }
        o.statusLine = statusline
        o.mcp = mcp
        return o
    }
}

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Install hooks, status line wrapper, MCP server and (Linux) the service unit; idempotent. On macOS the app is the service.")

    @OptionGroup var flags: InstallFlags
    @Flag(help: "Enable and start the systemd --user service.") var enableService = false
    @Flag(help: "Also write a system unit (needs root: sudo), for hosts without a user systemd.") var systemService = false

    func run() throws {
        var o = try flags.options()
        o.enableService = enableService
        o.systemService = systemService
        do { try Installer(o).install() } catch { throw ValidationError("install: \(error)") }
    }
}
