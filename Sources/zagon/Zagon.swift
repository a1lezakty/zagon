import ArgumentParser

// Each subcommand lives in Commands/<Name>Command.swift; add yours here, one per line.
@main
struct Zagon: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tracker of Claude Code and Codex CLI sessions.",
        version: zagonVersion,
        subcommands: [
            ScanCommand.self,
            TodayCommand.self,
            DayCommand.self,
            WeekCommand.self,
            SessionsCommand.self,
            DaemonCommand.self,
            ExportCommand.self,
            HookCommand.self,
            StatusLineCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            DoctorCommand.self,
            NotifyCommand.self,
            SummaryCommand.self,
            MCPCommand.self,
            ArchiveCommand.self,
            HandoffCommand.self,
            TaskCommand.self,
            LogCommand.self,
            TzCommand.self,
        ])
}
