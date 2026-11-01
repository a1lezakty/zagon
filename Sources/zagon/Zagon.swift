import ArgumentParser
import ZagonCore

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
            EditorPanelsCommand.self,
            DoctorCommand.self,
            NotifyCommand.self,
            SummaryCommand.self,
            MCPCommand.self,
            ArchiveCommand.self,
            HandoffCommand.self,
            TaskCommand.self,
            LogCommand.self,
            TzCommand.self,
            UpdateCommand.self,
            SetupCommand.self,
        ])

    /// `claude-wrap` hands its arguments to Claude Code untouched, so it runs before the parser sees them.
    static func main() {
        let a = CommandLine.arguments
        if a.count > 1 && a[1] == "claude-wrap" { ClaudeWrap.run(Array(a.dropFirst(2))) }
        main(nil)
    }
}
