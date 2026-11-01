#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// What `zagon setup jira` and `zagon notify setup` check and write: a token goes to its own file (mode 0600), keys
/// to config.toml (every other line stays). Tokens never reach argv, output or errors.
public enum Setup {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ d: String) { description = d }
    }

    /// `text` into `path` with mode 0600 from the first byte: a new file renamed over the old one, whose mode is not
    /// kept (`Sys.writeFile` keeps it).
    public static func writeSecret(_ path: String, _ text: String) throws {
        Sys.mkdirs(Sys.dirname(path))
        let target = Sys.realPath(path) ?? path, tmp = target + ".zagon-tmp"
        let fd = Sys.createExclusive(tmp)
        guard fd >= 0 else { throw Failure("cannot write \(path)") }
        let ok = Sys.writeAll(fd: fd, Array(text.utf8)) && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp, target) == 0 else { unlink(tmp); throw Failure("cannot write \(path)") }
    }

    /// Sets keys of one `[section]` in config.toml in this order (nil removes a key); the file stays 0600. A config.toml
    /// that exists but cannot be read is left alone.
    public static func setConfig(_ paths: ZagonPaths, _ section: String, _ keys: [(String, String?)]) throws {
        let cur = Sys.readFile(paths.config).map { String(decoding: $0, as: UTF8.self) }
        if cur == nil, Sys.exists(paths.config) { throw Failure("cannot read \(paths.config)") }
        // A new key goes right under the header: put in reverse, they read in the given order.
        let new = keys.reversed().reduce(cur ?? "") { TOMLLite.setting($0, section: section, key: $1.0, to: $1.1) }
        guard new != cur else { return }
        Sys.mkdirs(paths.dir)
        guard Sys.writeFile(paths.config, Array(new.utf8), mode: 0o600) else { throw Failure("cannot write \(paths.config)") }
    }

    // MARK: Jira

    /// The address as `[jira] url` takes it: `https://` added when missing, no trailing `/`; an Atlassian Cloud link
    /// is cut to its site (a pasted board link works).
    public static func jiraURL(_ typed: String) -> String {
        var u = typed.trimmed(" \t\r\n")
        if !u.contains("://") { u = "https://" + u }
        if let host = u.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false).dropFirst(2).first,
           host.lowercased().hasSuffix(".atlassian.net") {
            return String(u.prefix { $0 != "/" }) + "//" + host
        }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    /// `/myself` with these values: Jira's account id of the token's user, else what Jira or curl said. A nil `token`
    /// uses the saved token file of `saved`.
    public static func checkJira(url: String, email: String, token: String?, saved: JiraConfig?, curl: String = "curl") throws -> String {
        var c = JiraConfig(baseURL: url, email: email, tokenFile: saved?.tokenFile ?? "")
        c.curl = curl
        return try (token.map { try JiraClient(c, token: $0) } ?? JiraClient(c)).accountId()
    }

    /// A failed check in one line: a refused login by name.
    public static func why(_ e: Error) -> String {
        if case JiraError.http(let code, _) = e, code == 401 || code == 403 {
            return "Jira refused the login (HTTP \(code)): check the email and the token"
        }
        return "\(e)"
    }

    /// `[jira] url, email, token_file`; a typed `token` goes to `<data dir>/jira-token` (the Mac app keeps it there
    /// too), nil keeps the saved token file.
    public static func saveJira(_ paths: ZagonPaths, url: String, email: String, token: String?) throws {
        let file = paths.dir + "/jira-token"
        if let token { try writeSecret(file, token + "\n") }
        var keys: [(String, String?)] = [("url", url), ("email", email)]
        if token != nil { keys.append(("token_file", file)) }
        try setConfig(paths, "jira", keys)
    }

    // MARK: Telegram and ntfy

    /// The user's bot during setup: the token is in hand, not yet in a file.
    public struct Bot {
        var curl: Curl, api: String, token: String
        public init(curl: Curl, api: String = "https://api.telegram.org", token: String) {
            self.curl = curl; self.api = api.hasSuffix("/") ? String(api.dropLast()) : api; self.token = token
        }

        /// A Bot API call; throws Telegram's `description` (never the URL: it holds the token).
        func call(_ method: String, _ body: JValue, timeout: Double = 30) throws -> JValue {
            let out = curl.request([Curl.line("url", "\(api)/bot\(token)/\(method)"), Curl.line("header", "Content-Type: application/json"),
                                    Curl.line("data-binary", body.compact)], timeout: timeout)
            guard let out else { throw Failure("Telegram did not answer (no connection?)") }
            guard let v = JValue.parse(out) else { throw Failure("Telegram gave no JSON") }
            guard v["ok"] == .bool(true), let r = v["result"] else {
                let code = v["error_code"]?.double.map { " \(Int($0))" } ?? ""
                throw Failure("Telegram\(code): " + (v["description"]?.string ?? "refused"))
            }
            return r
        }

        /// `@username` of the bot (getMe): the token works.
        public func name() throws -> String {
            let me = try call("getMe", .object([]))
            return "@" + (me["username"]?.string ?? "?")
        }

        public struct Chat: Equatable, Sendable {
            public var id: String, name: String
        }

        /// Waits for a message to the bot sent at `since` or later (getUpdates, long polls until `deadline`); nil when
        /// none came. Updates before it are confirmed (a fresh bot's backlog), the message itself is not.
        public func waitForChat(since: Double, deadline: Double, now: () -> Double = { Sys.now() }) throws -> Chat? {
            var offset: Int?
            while now() < deadline {
                // No `allowed_updates`: Telegram would keep that filter for the service's bot (its buttons need callbacks).
                var body: [JValue.Member] = [.init("timeout", .number(offset == nil ? "0" : String(Int(min(25, max(1, deadline - now()))))))]
                if let offset { body.append(.init("offset", .number(String(offset)))) }
                let r = try call("getUpdates", .object(body), timeout: 40)
                if let c = Bot.chat(r, since: since) { return c }
                for u in r.array ?? [] { if let id = u["update_id"]?.double { offset = max(offset ?? 0, Int(id) + 1) } }
                if offset == nil { offset = 0 }
            }
            return nil
        }

        /// The chat of the newest message (private chat, group or channel) sent at `since` or later.
        static func chat(_ updates: JValue, since: Double) -> Chat? {
            for u in (updates.array ?? []).reversed() {
                guard let m = u["message"] ?? u["channel_post"], (m["date"]?.double ?? 0) >= since - 5,
                      let c = m["chat"], case .number(let id)? = c["id"] else { continue }
                let first = c["first_name"]?.string ?? "", last = c["last_name"]?.string ?? ""
                let name = c["title"]?.string ?? c["username"].flatMap { $0.string.map { "@" + $0 } }
                    ?? (first + (last.isEmpty ? "" : " " + last))
                return Chat(id: id, name: name)
            }
            return nil
        }
    }

    /// `[telegram] token_file, chat_id`; a typed `token` goes to `<data dir>/telegram-token`, nil keeps the saved one.
    public static func saveTelegram(_ paths: ZagonPaths, token: String?, chatId: String) throws {
        let file = paths.dir + "/telegram-token"
        if let token { try writeSecret(file, token + "\n") }
        try setConfig(paths, "telegram", (token != nil ? [("token_file", file)] : []) + [("chat_id", chatId)])
    }

    /// A topic nobody guesses (anyone who knows a topic reads it): `zagon-` and 16 random letters and digits.
    public static func ntfyTopic() -> String {
        let a = Array("abcdefghijkmnopqrstuvwxyz23456789")
        return "zagon-" + String((0..<16).map { _ in a.randomElement()! })
    }

    public static func saveNtfy(_ paths: ZagonPaths, topic: String, url: String) throws {
        try setConfig(paths, "ntfy", [("topic", topic), ("url", url)])
    }
}
