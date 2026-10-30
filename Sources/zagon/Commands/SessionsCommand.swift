import ArgumentParser
import ZagonCore

struct SessionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sessions", abstract: "Recent sessions.")
    @Option(help: "Only sessions active on this day, YYYY-MM-DD.") var day: String?
    @Option(help: "How many.") var limit: Int = 20
    @OptionGroup var common: Common
    @OptionGroup var report: ReportOptions
    func run() throws {
        let store = try prepare(common, report)
        let reports = Reports(store: store)
        let list: [SessionLine]
        if let day, let (s, e) = Time.dayBounds(day) { list = try reports.sessions(from: s, to: e, limit: limit) }
        else { list = try reports.sessions(limit: limit) }
        if report.json { try emit(list) } else { Fmt.sessions(list) }
    }
}
