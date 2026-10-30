import ArgumentParser
import ZagonCore

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Show what is installed and what is missing (exit 1 if anything is missing).")

    @OptionGroup var flags: InstallFlags
    @Option(help: "Lines of the daemon log to show.") var logLines = 10

    func run() throws {
        let o = try flags.options()
        let checks = Installer(o).doctor()
        for c in checks { print((c.ok ? "ok       " : "MISSING  ") + c.text) }
        let logPath = o.paths.dir + "/logs/daemon.log"
        let tail = LogFile.tail(logPath, lines: 2000)
        if tail.isEmpty {
            print("daemon log: none at \(logPath)")
        } else {
            print("daemon log: \(logPath)")
            print("last health: " + (tail.last { $0.contains(" health: ") } ?? "none yet"))
            for l in tail.suffix(logLines) { print("  " + l) }
        }
        if checks.contains(where: { !$0.ok }) { throw ExitCode(1) }
    }
}
