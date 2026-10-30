/// `settings_timezone`: the zone days, reports and notifications use; setting it needs `confirm: true`.
enum SettingsTools {
    static func tools(_ paths: ZagonPaths) -> [MCPTool] {
        [MCPTool(name: "settings_timezone", title: "Time zone",
                 description: "The time zone days, reports and notifications are cut in (from config.toml, else the "
                    + "system's), with the local time. With `zone` (a tz database name such as Asia/Almaty, or `system`) "
                    + "it is written to config.toml; the service follows within 10 s and rebuilds the days. Change it "
                    + "only when the user asked to; requires confirm: true.",
                 inputSchema: MCPSchema.object([
                    "zone": MCPSchema.string("New zone, e.g. Europe/Moscow; `system` = the machine's zone. Omit to read."),
                    "confirm": MCPSchema.boolean("true to write the new zone (only when the user asked for it)"),
                 ]), readOnly: false) { a in
            if let zone = try a.string("zone") {
                guard try a.bool("confirm") == true else {
                    throw MCPToolError("settings_timezone with `zone` needs confirm: true, and only when the user asked to change the zone.")
                }
                do { try Settings.setTimezone(paths, zone == "system" ? nil : zone) } catch { throw MCPToolError("\(error)") }
                Settings.applyTimezone(paths)  // this server answers on one thread: later reports use the new zone
            }
            return Settings.timezoneStatus(paths)
        }]
    }
}
