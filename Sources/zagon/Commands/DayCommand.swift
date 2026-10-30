import ArgumentParser
import ZagonCore

struct DayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "day", abstract: "Usage and time of one day.")
    @Argument(help: "YYYY-MM-DD") var date: String
    @OptionGroup var common: Common
    @OptionGroup var report: ReportOptions
    func validate() throws { guard Time.parseDay(date) != nil else { throw ValidationError("date must be YYYY-MM-DD") } }
    func run() throws {
        let store = try prepare(common, report)
        let r = try Reports(store: store).day(date)
        if report.json { try emit(r) } else { Fmt.day(r) }
    }
}
