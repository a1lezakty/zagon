import ArgumentParser
import ZagonCore

struct WeekCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "week", abstract: "Seven days ending today (or --end), vs the seven before.")
    @Option(help: "Last day, YYYY-MM-DD.") var end: String?
    @OptionGroup var common: Common
    @OptionGroup var report: ReportOptions
    func run() throws {
        let store = try prepare(common, report)
        let r = try Reports(store: store).week(ending: end ?? Time.dayString(Time.now()))
        if report.json { try emit(r) } else { Fmt.week(r) }
    }
}
