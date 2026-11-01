/// `settings_timezone`: the zone days, reports and notifications use; setting it needs `confirm: true`.
enum SettingsTools {
    static func tools(_ paths: ZagonPaths, store: Store) -> [MCPTool] {
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
        },
        MCPTool(name: "worklog_exclude", title: "Never log a project, task or session",
                description: "Excludes the work of a project (folder or repository name), a task (key) or a session (id) "
                    + "from the worklogs: its time is in no plan row, not in \"no task\" and not in worklog_reconcile "
                    + "([worklog] exclude in config.toml; worklog_config lists them). undo: true counts it again. Only when "
                    + "the user asked; requires confirm: true. Writes nothing to Jira.",
                inputSchema: MCPSchema.object([
                    "kind": MCPSchema.string("What to exclude", enum: WorklogExclusion.kinds),
                    "name": MCPSchema.string("Its name, key or id"),
                    "undo": MCPSchema.boolean("Count it again instead"),
                    "confirm": ["type": "boolean", "const": true, "description": "Must be true: the user asked for this"],
                ], required: ["kind", "name", "confirm"]), readOnly: false) { a in
            guard try a.bool("confirm") == true else {
                throw MCPToolError("worklog_exclude needs confirm: true, and only when the user asked. Nothing was changed.")
            }
            let kind = try a.required("kind"), on = try a.bool("undo") != true
            var name = try a.required("name").trimmed(" \t\n\r")
            guard WorklogExclusion.kinds.contains(kind) else { throw MCPToolError("kind must be project, task or session") }
            if kind == "task" { name = name.uppercased() }
            if kind == "session", on || !WorklogConfig.load(paths).exclude.contains(WorklogExclusion(kind: kind, name: name)) {
                name = try session(store, name)
            }
            let x = WorklogExclusion(kind: kind, name: name)
            let changed: Bool
            do { changed = try WorklogConfig.setExcluded(paths, x, on) } catch { throw MCPToolError("\(error)") }
            guard changed else { return "Nothing to change: \(kind) \(x.name) is \(on ? "already" : "not") excluded." }
            return (on ? "Excluded \(kind) \(x.name): its time is in no plan row." : "\(kind) \(x.name) counts again.")
                + " The plans change: show worklog_plan again before worklog_commit. Nothing was written to Jira."
        }]
    }

    /// The full id of the one session whose id (with or without `claude:` / `codex:`) starts with `prefix`: the tools
    /// show 8 characters of it.
    static func session(_ store: Store, _ prefix: String) throws -> String {
        let like = prefix.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_") + "%"
        var ids: [String] = []
        try store.db.query("""
            SELECT id FROM session WHERE id = ?1 OR id LIKE ?2 ESCAPE '\\' OR id LIKE 'claude:' || ?2 ESCAPE '\\'
                OR id LIKE 'codex:' || ?2 ESCAPE '\\' LIMIT 2
            """, [.text(prefix), .text(like)]) { if let i = $0.text(0) { ids.append(i) } }
        guard ids.count == 1 else {
            throw MCPToolError((ids.isEmpty ? "No session \(prefix)" : "More than one session starts with \(prefix): give more of its id")
                               + "; nothing was changed. sessions shows the ids.")
        }
        return ids[0]
    }
}
