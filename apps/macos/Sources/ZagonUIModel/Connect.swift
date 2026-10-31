import Foundation
import ZagonCore

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

    /// `install`, `uninstall`, `editor-panels on|off` (words split on spaces); nil = done, else why not (the CLI's error
    /// line, home folder as ~).
    public static func change(_ bin: String, _ command: String, path: String) -> String? {
        let args = command.split(separator: " ").map(String.init) + ["--bin", bin]
        guard let r = (try? Proc.run(bin, args, env: ["PATH": path], timeout: 120)) ?? nil else {
            return "no answer in 120 s"
        }
        guard r.status != 0 else { return nil }
        return Remote.scrubHomes(Log.scrub(r.errLastLine.isEmpty ? "exit \(r.status)" : r.errLastLine))
    }
}

/// Settings → Claude limits from the IDE panel: where `claudeCode.claudeProcessWrapper` stands in the editors found
/// (`Installer.editorState`), editors named from their settings paths.
public struct EditorPanelsVM: Sendable, Equatable {
    /// Each with a dot: green when on.
    public struct Line: Sendable, Equatable {
        public var on: Bool
        public var text: String
    }
    public var lines: [Line]
    /// Files left alone (another wrapper, not JSON), home folder as ~.
    public var notes: [String]
    /// `editor-panels on` has something to add to / `off` something to remove.
    public var canEnable: Bool
    public var canDisable: Bool

    public init(_ s: Installer.EditorPanels, _ f: Fmt) {
        let names = { (paths: [String]) in paths.map { Self.name($0, f) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
        lines = (s.on.isEmpty ? [] : [Line(on: true, text: f.t("editors.on", names(s.on).joined(separator: ", ")))])
            + (s.off.isEmpty ? [] : [Line(on: false, text: f.t("editors.off", names(s.off).joined(separator: ", ")))])
        if lines.isEmpty && s.other.isEmpty { lines = [Line(on: false, text: f.t("editors.none"))] }
        notes = s.other.map(Remote.scrubHomes)
        canEnable = !s.off.isEmpty
        canDisable = !s.on.isEmpty
    }

    /// This Mac's editors now.
    public static func local(_ f: Fmt) -> EditorPanelsVM { EditorPanelsVM(Installer(Installer.Options()).editorState(), f) }

    /// `…/Cursor/User/settings.json` → Cursor, `…/Code/User/profiles/<id>/settings.json` → Code (profile),
    /// `~/.cursor-server/data/Machine/settings.json` → cursor-server (Remote-SSH).
    static func name(_ path: String, _ f: Fmt) -> String {
        let c = path.split(separator: "/").map(String.init)
        if let u = c.lastIndex(of: "User"), u > 0 {
            return c[u - 1] + (c.count > u + 1 && c[u + 1] == "profiles" ? " (" + f.t("editors.profile") + ")" : "")
        }
        if let d = c.lastIndex(of: "data"), d > 0 { return String(c[d - 1].drop { $0 == "." }) + " (Remote-SSH)" }
        return Remote.scrubHomes(path)
    }
}
