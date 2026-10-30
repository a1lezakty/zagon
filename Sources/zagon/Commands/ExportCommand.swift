import ArgumentParser
import ZagonCore

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Totals changed after a change counter, as NDJSON (read by the Mac app over SSH).")
    @Option(help: "Change counter from the previous export's first line (0 = everything).") var since: Int = 0
    @OptionGroup var common: Common

    func run() throws {
        let store = try common.open()
        try Export.run(store: store, since: since, version: zagonVersion) { print($0) }
    }
}
