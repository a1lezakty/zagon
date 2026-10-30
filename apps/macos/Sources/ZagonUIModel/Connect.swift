import Foundation

/// Connecting Claude Code / Codex through the CLI bundled in Zagon.app (`Contents/Helpers/zagon`):
/// `install` / `uninstall` / `doctor --bin <its path>` (hooks, status line, MCP).
public enum Connect {
    /// What `doctor` found: its `ok …` and `MISSING …` lines; `notes` are the ok lines saying something was skipped
    /// (no claude / codex CLI on this Mac): nothing Connect can change.
    public struct Status: Sendable, Equatable {
        public var ok: [String] = []
        public var missing: [String] = []
        public var notes: [String] = []
        public var connected: Bool { missing.isEmpty && !ok.isEmpty }
        public init(ok: [String] = [], missing: [String] = [], notes: [String] = []) {
            self.ok = ok; self.missing = missing; self.notes = notes
        }
    }

    /// PATH for the CLI. A GUI app gets /usr/bin:/bin:/usr/sbin:/sbin, and without `claude` / `codex` on PATH the CLI
    /// skips the MCP registration silently: the login shell's PATH first, then the usual tool folders.
    public static func path(loginShell: String?, home: String) -> String {
        var out: [String] = []
        let all = (loginShell ?? "").split(separator: ":").map(String.init)
            + [home + "/.local/bin", home + "/.claude/local", home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin",
               "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for p in all where !p.isEmpty && !out.contains(p) { out.append(p) }
        return out.joined(separator: ":")
    }

    static let marker = "__ZAGON_PATH__"

    /// PATH of the user's shell as a terminal sets it up (interactive login shell: .zprofile and .zshrc, where nvm,
    /// bun and the like add theirs), else of a plain login shell (an rc file that execs tmux or another shell); nil
    /// when neither answers. Whatever rc files print around it is skipped by the marker.
    public static func loginShellPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> String? {
        for flags in [["-i", "-l"], ["-l"]] {
            guard let r = (try? Proc.run(shell, flags + ["-c", "printf '\\n\(marker)%s\\n' \"$PATH\""], timeout: 10)) ?? nil
            else { continue }
            if let line = String(decoding: r.out, as: UTF8.self).split(separator: "\n").first(where: { $0.hasPrefix(marker) }) {
                return String(line.dropFirst(marker.count))
            }
        }
        return nil
    }

    /// `ok …` / `MISSING …` lines; an `ok` that says something was skipped goes to `notes`.
    static func parseDoctor(_ out: String) -> Status {
        var s = Status()
        for line in out.split(separator: "\n") {
            if line.hasPrefix("ok ") {
                let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if text.contains("skipped") { s.notes.append(text) } else { s.ok.append(text) }
            }
            if line.hasPrefix("MISSING ") { s.missing.append(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) }
        }
        return s
    }

    /// An app run from the DMG or a quarantined download runs from a temporary copy (App Translocation): a path
    /// written into Claude's settings from there breaks after a restart.
    /// (A disk image is mounted under /Volumes; an Applications folder on an external disk is fine.)
    public static func temporaryLocation(_ bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/") || (bundlePath.hasPrefix("/Volumes/") && !bundlePath.contains("/Applications/"))
    }

    /// nil when the CLI could not be run.
    public static func doctor(_ bin: String, path: String) -> Status? {
        guard let r = (try? Proc.run(bin, ["doctor", "--bin", bin], env: ["PATH": path], timeout: 30)) ?? nil,
              r.status == 0 || r.status == 1 else { return nil }
        return parseDoctor(String(decoding: r.out, as: UTF8.self))
    }

    /// `install` or `uninstall`; nil = done, else why not (the CLI's error line, home folder as ~).
    public static func change(_ bin: String, _ command: String, path: String) -> String? {
        guard let r = (try? Proc.run(bin, [command, "--bin", bin], env: ["PATH": path], timeout: 120)) ?? nil else {
            return "no answer in 120 s"
        }
        guard r.status != 0 else { return nil }
        return Remote.scrubHomes(Log.scrub(r.errLastLine.isEmpty ? "exit \(r.status)" : r.errLastLine))
    }
}
