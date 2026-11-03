import ArgumentParser
import ZagonCore

struct TodayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "today", abstract: "Today's usage and time.")
    @OptionGroup var common: Common
    @OptionGroup var report: ReportOptions
    func run() throws {
        let store = try prepare(common, report)
        let r = try Reports(store: store).day(Time.dayString(Time.now()))
        if report.json { try emit(r); return }
        Fmt.day(r)
        for (i, l) in try ZagonMCP.limitsText(store: store, localAccount: Settings.limitsAccount(ZagonPaths(dir: common.dataDir))).split(separator: "\n").enumerated() {
            print((i == 0 ? "limits     " : "           ") + l)
        }
    }
}
