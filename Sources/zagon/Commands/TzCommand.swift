import ArgumentParser
import ZagonCore

/// `zagon tz [zone]`: the zone days, reports and notifications use; with a zone, writes it to config.toml.
struct TzCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tz", abstract: "Show the time zone, or set it in config.toml: zagon tz Asia/Almaty (zagon tz system = the machine's).",
        discussion: "The service picks a new zone up within 10 s and rebuilds the days in it.")
    @Argument(help: "A tz database name, e.g. Europe/Moscow; `system` removes the setting.") var zone: String?
    @OptionGroup var common: Common

    func run() throws {
        let paths = ZagonPaths(dir: common.dataDir)
        if let zone {
            do { try Settings.setTimezone(paths, zone == "system" ? nil : zone) } catch { throw ValidationError("\(error)") }
        }
        Settings.applyTimezone(paths)
        print(Settings.timezoneStatus(paths))
    }
}
