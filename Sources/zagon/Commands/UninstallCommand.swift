import ArgumentParser
import ZagonCore

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Remove what install added; untouched files are restored from the backup byte for byte.")

    @OptionGroup var flags: InstallFlags

    func run() throws {
        do { try Installer(flags.options()).uninstall() } catch { throw ValidationError("uninstall: \(error)") }
    }
}
