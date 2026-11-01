import ArgumentParser
import ZagonCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Questions on the terminal; a secret is typed without echo and never taken from arguments.
enum Prompt {
    /// The terminal as it was before a secret was asked (restored when a signal ends the command).
    nonisolated(unsafe) static var saved = termios()

    /// A line after the question; `fallback` (shown in brackets) when it is empty. End of input stops the command.
    static func ask(_ q: String, _ fallback: String? = nil) throws -> String {
        print(q + (fallback.map { $0.isEmpty ? "" : " [\($0)]" } ?? "") + ": ", terminator: "")
        fflush(nil)
        guard let l = readLine() else { print(); throw ExitCode(1) }
        var t = Substring(l)
        while t.first?.isWhitespace == true { t.removeFirst() }
        while t.last?.isWhitespace == true { t.removeLast() }
        return t.isEmpty ? fallback ?? "" : String(t)
    }

    static func yes(_ q: String) throws -> Bool { ["y", "yes"].contains(try ask(q + " [y/N]").lowercased()) }

    /// A line typed without echo on a terminal. A signal that ends the command puts the echo back first; Ctrl-Z is
    /// ignored meanwhile (the shell would bring the command back with echo on).
    static func secret(_ q: String) throws -> String {
        print(q + ": ", terminator: "")
        fflush(nil)
        var old = termios()
        let tty = isatty(0) == 1 && tcgetattr(0, &old) == 0
        let ends = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
        if tty { saved = old }
        // What was there before (e.g. HUP ignored under nohup) is put back after.
        let before = tty ? ends.map { signal($0) { s in _ = tcsetattr(0, TCSANOW, &Prompt.saved); _exit(128 + s) } } + [signal(SIGTSTP, SIG_IGN)] : []
        if tty {
            var t = old
            t.c_lflag &= ~tcflag_t(ECHO)
            _ = tcsetattr(0, TCSAFLUSH, &t)
        }
        let l = readLine()
        if tty {
            _ = tcsetattr(0, TCSAFLUSH, &old)
            for (s, h) in zip(ends + [SIGTSTP], before) { signal(s, h) }
            print()
        }
        guard let l else { throw ExitCode(1) }
        return l.filter { !$0.isWhitespace }
    }
}

/// Stops the command with a line on stderr.
func fail(_ s: String) -> ExitCode {
    fflush(nil)  // what was printed before comes first
    warn(s)
    return ExitCode(1)
}

/// `zagon setup jira`: Jira by questions, checked with Jira before anything is saved.
struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Connect Jira by answering a few questions.",
                                                    subcommands: [Jira.self])

    struct Jira: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Connect Jira Cloud: address, email and API token, checked with Jira, then saved to config.toml.",
            discussion: "The token is typed (not shown, never an argument) and kept in jira-token in the data directory, mode 0600. "
                + "Notifications: zagon notify setup.")
        @OptionGroup var common: Common

        func run() throws {
            let paths = ZagonPaths(dir: common.dataDir), saved = JiraConfig.load(configText: common.configText)
            print("Jira Cloud. An API token is made at id.atlassian.com → Security → API tokens.")
            let url = Setup.jiraURL(try Prompt.ask("Address, e.g. https://your-team.atlassian.net", saved?.baseURL))
            guard url.lowercased().hasPrefix("https://"), url.count > 8 else { throw fail("the address must be https://…") }
            let email = try Prompt.ask("Email of your Atlassian account", saved?.email)
            guard email.contains("@"), !email.contains(where: \.isWhitespace) else { throw fail("not an email: \(email)") }
            let typed = try Prompt.secret("API token (not shown" + (saved == nil ? ")" : "; Enter keeps the saved one)"))
            if typed.isEmpty && saved == nil { throw fail("no token: nothing saved") }
            let token = typed.isEmpty ? nil : typed
            print("Checking with Jira…")
            do { _ = try Setup.checkJira(url: url, email: email, token: token, saved: saved) } catch {
                throw fail(Setup.why(error) + "; nothing saved")
            }
            do { try Setup.saveJira(paths, url: url, email: email, token: token) } catch { throw fail("\(error)") }
            print("Jira connected: [jira] in \(paths.config)" + (token == nil ? "" : ", the token in \(paths.dir)/jira-token (only you can read it)"))
        }
    }
}

extension NotifyCommand {
    /// `zagon notify setup [telegram|ntfy]`.
    struct Wizard: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup", abstract: "Set up Telegram (your own bot) or ntfy by answering a few questions; sends a test message.",
            discussion: "Telegram: a bot token from @BotFather (typed, not shown, kept in telegram-token in the data directory, mode 0600); "
                + "the chat is found when you write /start to the bot. ntfy: a topic, a hard-to-guess one is offered.")
        @Argument(help: "telegram | ntfy (default: asks about both).") var channel: String?
        @OptionGroup var common: Common

        func validate() throws {
            if let channel, !["telegram", "ntfy"].contains(channel) { throw ValidationError("telegram or ntfy") }
        }

        func run() throws {
            let paths = ZagonPaths(dir: common.dataDir)
            guard let curl = Curl() else { throw fail("curl is not installed: Zagon sends notifications with it") }
            // Each saved channel's test message: sent or not.
            var sent: [Bool] = []
            if try channel == "telegram" || channel == nil && Prompt.yes("Set up Telegram?") { sent.append(try telegram(paths, curl)) }
            if try channel == "ntfy" || channel == nil && Prompt.yes("Set up ntfy?") { sent.append(try ntfy(paths)) }
            if !sent.isEmpty {
                print("The service reads this when it starts: restart it (systemctl --user restart zagon; a system service: "
                      + "sudo systemctl restart zagon-\(getpwuid(getuid()).map { String(cString: $0.pointee.pw_name) } ?? "<user>")).")
            }
            if sent.contains(false) { throw ExitCode(1) }
        }

        /// The test message through the channel as configured now; whether it was sent.
        func test(_ paths: ZagonPaths, _ name: String) -> Bool {
            let c = NotifyConfig.load(paths), w = c.lang.words()
            let m = Message(title: w.t("[тест Zagon]", "[Zagon test]"), text: w.t("Проверка связи: уведомления Zagon работают.", "Connection check: Zagon notifications work."))
            let ok = c.channels(paths).first { $0.name == name }?.send(m) ?? false
            print("Test message: " + (ok ? "sent" : "FAILED"))
            if !c.enabled { print("Notifications are off on this host ([notify] enabled = false): only the bot answers.") }
            return ok
        }

        func telegram(_ paths: ZagonPaths, _ curl: Curl) throws -> Bool {
            let saved = NotifyConfig.load(paths)
            print("Telegram: your own bot. Make one with @BotFather (/newbot) and paste its token here.")
            let typed = try Prompt.secret("Bot token (not shown" + (saved.telegramTokenFile == nil ? ")" : "; Enter keeps the saved one)"))
            var token = typed.isEmpty ? nil : typed
            if token == nil {
                // The saved token, read as the channel reads it.
                guard let f = saved.telegramTokenFile, let raw = Sys.readFile(f),
                      let t = String(decoding: raw, as: UTF8.self).split(whereSeparator: \.isWhitespace).first else { throw fail("no token: nothing saved") }
                token = String(t)
            }
            let bot = ZagonCore.Setup.Bot(curl: curl, api: saved.telegramAPI, token: token!)
            let name: String
            do { name = try bot.name() } catch { throw fail("\(error); nothing saved") }
            if typed.isEmpty { print("If the Zagon service runs with this bot, stop it meanwhile: two programs cannot read one bot.") }
            print("Bot \(name). Now write /start to \(name) in Telegram (in a group: /start@\(name.dropFirst())). Waiting up to 3 minutes…")
            var chat: String?
            do {
                if let c = try bot.waitForChat(deadline: Sys.now() + 180) {
                    print("Message from \(c.name) (chat \(c.id)).")
                    if try Prompt.yes("Send notifications to this chat?") { chat = c.id }
                } else { print("No message came.") }
            } catch {
                // 409: another program reads this bot's updates (a running `zagon notify run`, a webhook).
                print("\(error)" + ("\(error)".contains("409") ? " (another program reads this bot: stop it, or type the chat id)" : ""))
            }
            if chat == nil {
                let typedChat = try Prompt.ask("Chat id (a number, or @channel)", saved.telegramChatId)
                guard typedChat.hasPrefix("@") ? typedChat.count > 1 : Int64(typedChat) != nil else { throw fail("no chat id: nothing saved") }
                chat = typedChat
            }
            do { try ZagonCore.Setup.saveTelegram(paths, token: typed.isEmpty ? nil : typed, chatId: chat!) } catch { throw fail("\(error)") }
            print("Saved: [telegram] in \(paths.config)" + (typed.isEmpty ? "" : ", the token in \(paths.dir)/telegram-token (only you can read it)"))
            return test(paths, "telegram")
        }

        func ntfy(_ paths: ZagonPaths) throws -> Bool {
            let saved = NotifyConfig.load(paths)
            print("ntfy: pushes to the ntfy app, no account. Anyone who knows the topic can read it: keep it hard to guess.")
            let topic = try Prompt.ask("Topic", saved.ntfyTopic ?? ZagonCore.Setup.ntfyTopic())
            guard !topic.isEmpty, topic.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                throw fail("a topic is letters, digits, - and _")
            }
            let url = try Prompt.ask("Server", saved.ntfyURL)
            guard url.hasPrefix("https://") || url.hasPrefix("http://") else { throw fail("the server is https://… (http:// sends in clear)") }
            do { try ZagonCore.Setup.saveNtfy(paths, topic: topic, url: url) } catch { throw fail("\(error)") }
            print("Saved: [ntfy] in \(paths.config). Subscribe to \(topic) in the ntfy app (server \(url)).")
            return test(paths, "ntfy")
        }
    }
}
