import ArgumentParser
import ZagonCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Darwin)
import Darwin
#endif

enum HandoffTarget: String, ExpressibleByArgument, CaseIterable {
    case claude, codex, gemini, cursor, clipboard, file
}

/// `zagon handoff`: a summary of a session built from its log and git (no AI unless `--ai`, secrets removed), sent
/// where the work continues. Only the result goes to stdout (paths, the command to run, or the summary itself).
struct HandoffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "handoff", abstract: "Summary of a session (or of a task's sessions) to continue it in a new session.")

    @Argument(help: "Session: latest, claude:<id>, codex:<id> or a bare id; several together with --task.")
    var sessions: [String] = ["latest"]
    @Option(help: "Task key: one handoff for all the given sessions.") var task: String?
    @Option(help: "Where to: claude | codex | gemini | cursor | clipboard | file.") var to: HandoffTarget = .file
    @Flag(help: "Shorten it with an AI model (spends a little of your subscription limit).") var ai = false
    @Option(help: "Model CLI for --ai: claude (haiku) or codex.") var aiTool = "claude"
    @Flag(name: .customLong("run"), help: "--to codex: start codex with the handoff instead of printing the command.")
    var start = false
    @Flag(help: "--to codex: also put a pointer to the handoff into the project's AGENTS.md.") var agentsMd = false
    @Flag(help: "--to clipboard on Linux: also send it to the terminal clipboard (OSC 52, works over ssh).") var osc52 = false
    @Option(help: "--to file: write here instead of ~/.zagon/handoffs/<name>.md.") var out: String?
    @Option(help: "Directory the work continues in (default: the session's cwd).") var cwd: String?
    @Option(help: "Claude Code projects directory.") var claudeDir = Common.home() + "/.claude/projects"
    @Option(help: "Codex home ($CODEX_HOME or ~/.codex).") var codexDir = CodexSource.defaultHome()

    struct Fail: Error, CustomStringConvertible { let description: String }

    func validate() throws {
        if task == nil && sessions.count > 1 { throw ValidationError("several sessions need --task <key>") }
        if !["claude", "codex"].contains(aiTool) { throw ValidationError("--ai-tool must be claude or codex") }
    }

    func note(_ s: String) { Sys.writeAll(fd: 2, Array((s + "\n").utf8)) }

    func run() throws {
        var doc = try Handoff.create(sessions, task: task, claudeDir: claudeDir, codexHome: codexDir,
                                     cwd: HandoffTools.currentDirectory())
        let paths = ZagonPaths()
        if ai {
            if let s = Handoff.compress(doc.markdown, tool: aiTool, runDir: paths.dir + "/run") { doc.markdown = s }
            else { note("--ai: \(aiTool) gave no usable result; using the summary built without AI") }
        }
        let store = HandoffStore(paths: paths), md = doc.markdown
        let dir = cwd ?? doc.cwd ?? "."
        note("handoff \(doc.name): \(md.utf8.count) bytes, ~\(Handoff.estimatedTokens(md)) tokens")
        func save() throws -> String {
            guard let p = store.save(doc) else { throw Fail(description: "cannot write \(store.dir)") }
            return p
        }
        switch to {
        case .file:
            if let out {
                guard Sys.writeFile(out, Array(md.utf8), mode: 0o600) else { throw Fail(description: "cannot write \(out)") }
                print(out)
            } else { print(try save()) }
        case .claude:
            let p = try save()
            guard store.markPending(doc.name, cwd: dir) else { throw Fail(description: "cannot write \(store.dir)/pending") }
            print(p)
            note("it is added to the next Claude Code session started in \(dir) (SessionStart hook from `zagon install`)")
        case .codex:
            let p = try save()
            if agentsMd && !Handoff.agentsPointer(cwd: dir, handoffPath: p) { note("cannot update \(dir)/AGENTS.md") }
            if start {
                guard let codex = Sys.which("codex") else { throw Fail(description: "codex is not in PATH") }
                guard chdir(dir) == 0 else { throw Fail(description: "cannot cd to \(dir)") }
                let args: [String] = [codex, Handoff.agentPrompt(md)]
                let argv = args.map { strdup($0) } + [nil]
                execv(codex, argv)
                throw Fail(description: "cannot start \(codex)")
            }
            print("cd \(Sys.shellQuote(dir)) && codex \(Sys.shellQuote(Handoff.agentPrompt(md)))")
        case .gemini:
            print("cd \(Sys.shellQuote(dir)) && gemini -i \(Sys.shellQuote(Handoff.agentPrompt(md)))")
        case .cursor:
            guard let p = Handoff.cursorRule(md, cwd: dir) else { throw Fail(description: "cannot write \(dir)/.cursor/rules") }
            print(p)
            note("Cursor adds it to every chat in this project until you delete it")
        case .clipboard:
            #if os(macOS)
            guard Sys.run(["/usr/bin/pbcopy"], stdin: Array(md.utf8)) == 0 else { throw Fail(description: "pbcopy failed") }
            note("copied to the clipboard")
            #else
            print(md, terminator: "")
            if osc52 { print(Handoff.osc52(md), terminator: "") }
            #endif
        }
    }
}
