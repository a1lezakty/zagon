import Foundation
import ZagonCore

/// Jira of this Mac, as the CLI inside Zagon.app reads it (the same as on a server):
///
///     [jira]
///     url = "https://your-team.atlassian.net"
///     email = "you@example.com"
///     token_file = "/Users/you/.zagon/jira-token"
///
/// Editing touches only these three keys of config.toml; the token goes to its own file, mode 0600, and is never read
/// back into the window.
public struct JiraSettings: Sendable, Equatable {
    public var url: String
    public var email: String
    public var tokenFile: String
    /// The CLI's client can start: the token file has a line, the address is https (else the CLI has no Jira).
    public var ready = true

    public init(url: String, email: String, tokenFile: String, ready: Bool = true) {
        self.url = url; self.email = email; self.tokenFile = tokenFile; self.ready = ready
    }

    /// `~/.zagon/jira-token`.
    public static var tokenPath: String { ZagonPaths().dir + "/jira-token" }

    /// nil: not connected.
    public static func load(_ configPath: String) -> JiraSettings? {
        guard let c = Sys.readFile(configPath).flatMap({ JiraConfig.load(configText: String(decoding: $0, as: UTF8.self)) }) else {
            return nil
        }
        // As the client reads it.
        let file = c.tokenFile.hasPrefix("~/") ? ZagonPaths().home + c.tokenFile.dropFirst() : c.tokenFile
        let token = Sys.readFile(file).map { String(decoding: $0, as: UTF8.self).contains { !$0.isWhitespace } } ?? false
        return JiraSettings(url: c.baseURL, email: c.email, tokenFile: c.tokenFile,
                            ready: token && c.baseURL.lowercased().hasPrefix("https://"))
    }

    /// The issue's page.
    public func browse(_ key: String) -> URL? { URL(string: url + "/browse/" + key) }

    /// Why the form cannot be checked or saved (a `Strings` key), nil = fine. `saved`: a token is kept already, so the
    /// field may stay empty.
    public static func problem(url: String, email: String, token: String, saved: Bool) -> String? {
        let u = url.lowercased()
        if !u.hasPrefix("https://") || u.count <= 8 || u.contains(where: \.isWhitespace) { return "settings.jira.bad.url" }
        if email.isEmpty || email.contains(where: \.isWhitespace) { return "settings.jira.bad.email" }
        // One line, and short enough for the pipe of `check`.
        if token.isEmpty ? !saved : token.utf8.count > 512 || token.contains(where: \.isNewline) { return "settings.jira.bad.token" }
        return nil
    }

    /// Writes `[jira] url, email, token_file` (every other line of config.toml stays) and a typed `token` to
    /// `tokenPath`; an empty `token` keeps the saved token file.
    public static func save(url: String, email: String, token: String, saved: JiraSettings?, configPath: String,
                            tokenPath: String) throws {
        try NotifySettings.edit(configPath) { text in
            // The token only once config.toml has been read: a file that cannot be is left alone with the old token.
            if !token.isEmpty { try writeSecret(tokenPath, token + "\n") }
            let file = token.isEmpty ? saved?.tokenFile ?? tokenPath : tokenPath
            // Each new key goes right under the header: this order reads url, email, token_file.
            return [("token_file", file), ("email", email), ("url", url)].reduce(text) {
                TOMLLite.setting($0, section: "jira", key: $1.0, to: $1.1)
            }
        }
    }

    /// Removes `url`, `email` and `token_file` from `[jira]` (the CLI then has no Jira; other keys stay) and deletes
    /// `tokenPath` (Zagon's own; a token file set by hand elsewhere stays).
    public static func disconnect(configPath: String, tokenPath: String) throws {
        try NotifySettings.edit(configPath) { text in
            var t = text
            for k in ["url", "email", "token_file"] {
                while TOMLLite.raw(in: t, section: "jira", key: k) != nil { t = TOMLLite.setting(t, section: "jira", key: k, to: nil) }
            }
            return t
        }
        unlink(tokenPath + ".zagon-tmp")  // left by an interrupted save
        if unlink(tokenPath) != 0, errno != ENOENT { throw CocoaError(.fileWriteNoPermission) }
    }

    /// `text` into `path` with mode 0600 from the first byte: a new file renamed over the old one, whose mode is not
    /// kept (Sys.writeFile keeps it).
    static func writeSecret(_ path: String, _ text: String) throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = Sys.realPath(path) ?? path, tmp = target + ".zagon-tmp"
        let fd = Sys.createExclusive(tmp)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let ok = Sys.writeAll(fd: fd, Array(text.utf8)) && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp, target) == 0 else { unlink(tmp); throw CocoaError(.fileWriteUnknown) }
    }

    /// A real request (`/myself`) with the form's values; an empty `token` uses the saved token file. A typed token
    /// reaches the client through a pipe (`/dev/fd/N`), never a file. Blocks for up to a minute.
    public static func check(url: String, email: String, token: String, saved: JiraSettings?, curl: String = "curl") throws {
        var c = JiraConfig(baseURL: url, email: email, tokenFile: saved?.tokenFile ?? tokenPath)
        c.curl = curl
        let client: JiraClient
        if token.isEmpty {
            client = try JiraClient(c)
        } else {
            var fds: [Int32] = [-1, -1]
            // Close-on-exec: a process spawned meanwhile must not hold either end.
            guard token.utf8.count <= 512, Sys.pipeCloexec(&fds) else { throw JiraError.token("cannot pass the token") }
            // At most 512 bytes: the pipe holds them all before anyone reads.
            let wrote = Sys.writeAll(fd: fds[1], Array(token.utf8))
            close(fds[1])
            defer { close(fds[0]) }
            guard wrote else { throw JiraError.token("cannot pass the token") }
            c.tokenFile = "/dev/fd/\(fds[0])"
            client = try JiraClient(c)
        }
        _ = try client.accountId()
    }

    /// The check's failure as one line: a refused login by name, else what Jira or curl said.
    public static func why(_ e: Error, _ f: Fmt) -> String {
        if case JiraError.http(let code, _) = e, code == 401 || code == 403 { return f.t("settings.jira.badLogin", String(code)) }
        return f.t("settings.jira.failed", String(Remote.scrubHomes(String(describing: e)).prefix(200)))
    }

    /// Jira of a server's zagon, as `task jira-projects` there answers.
    public enum Server: Sendable, Equatable { case on, off, failed(String) }

    public static func server(_ b: TaskBackend) -> Server {
        do {
            _ = try b.jiraProjects()
            return .on
        } catch {
            let why = String(describing: error)
            return why.contains("Jira is not connected") ? .off : .failed(String(Remote.scrubHomes(why).prefix(160)))
        }
    }
}
