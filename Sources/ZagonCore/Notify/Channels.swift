/// One notification. `text` is plain text; each channel escapes it for its own format.
public struct Message: Sendable, Equatable {
    public struct Button: Sendable, Equatable {
        public var text: String
        /// Telegram `callback_data` (≤ 64 bytes), routed to `Bot`.
        public var data: String
        public init(_ text: String, _ data: String) { self.text = text; self.data = data }
    }
    public var title: String
    public var text: String
    /// ntfy priority 1...5 (3 = default).
    public var priority = 3
    /// ntfy tags (emoji short codes).
    public var tags: [String] = []
    /// PNG sent with the message (Telegram `sendPhoto`).
    public var photo: [UInt8]?
    /// Telegram inline keyboard rows.
    public var buttons: [[Button]] = []
    public init(title: String, text: String, priority: Int = 3, tags: [String] = [], photo: [UInt8]? = nil,
                buttons: [[Button]] = []) {
        self.title = title; self.text = text; self.priority = priority; self.tags = tags; self.photo = photo
        self.buttons = buttons
    }
}

public protocol Channel {
    var name: String { get }
    /// True when the message was accepted.
    func send(_ m: Message) -> Bool
}

/// HTTP through a `curl` subprocess (no FoundationNetworking in the static binary). The request goes to curl as a
/// config on stdin, so URLs with tokens never show up in the process list.
public struct Curl: Sendable {
    public var path: String
    public var timeout: Double = 30

    public init?(searchPath: String? = Sys.env("PATH")) {
        guard let p = Sys.which("curl", path: searchPath) else { return nil }
        path = p
    }

    /// A curl config line `name = "value"` with the value escaped.
    public static func line(_ name: String, _ value: String) -> String {
        var s = name + " = \""
        for c in value.unicodeScalars {
            switch c {
            case "\\": s += "\\\\"
            case "\"": s += "\\\""
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            default: s.unicodeScalars.append(c)
            }
        }
        return s + "\"\n"
    }

    /// Runs one request; returns the response body, nil on a transport error.
    public func request(_ lines: [String], timeout: Double? = nil) -> [UInt8]? {
        let t = timeout ?? self.timeout
        let cfg = "silent\nshow-error\n" + Curl.line("max-time", String(Int(t))) + lines.joined()
        let r = Sys.capture([path, "-K", "-"], stdin: Array(cfg.utf8), timeout: t + 5)
        return r.status == 0 ? r.out : nil
    }
}

/// The user's own Telegram bot.
public struct Telegram: Channel {
    public let name = "telegram"
    var curl: Curl
    var api: String
    var token: String
    public var chatId: String
    /// Where photos are written for the multipart upload (deleted right after).
    var tmpDir: String

    public init?(_ c: NotifyConfig, curl: Curl?, tmpDir: String) {
        guard let curl, let file = c.telegramTokenFile, let chat = c.telegramChatId,
              let raw = Sys.readFile(file) else { return nil }
        let tok = String(decoding: raw, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard !tok.isEmpty else { return nil }
        self.curl = curl; api = c.telegramAPI; token = tok; chatId = chat; self.tmpDir = tmpDir
    }

    func url(_ method: String) -> String { "\(api)/bot\(token)/\(method)" }

    /// Numeric ids go as numbers, `@channel` names as strings.
    static func chat(_ id: String) -> JValue {
        id.allSatisfy({ $0.isNumber || $0 == "-" }) && !id.isEmpty ? .number(id) : .string(id)
    }

    /// Calls a Bot API method with a JSON body; returns `result` when `ok`.
    public func call(_ method: String, _ body: JValue, timeout: Double? = nil) -> JValue? {
        let out = curl.request([Curl.line("url", url(method)), Curl.line("header", "Content-Type: application/json"),
                                Curl.line("data-binary", body.compact)], timeout: timeout)
        guard let out, let v = JValue.parse(out), v["ok"] == .bool(true) else { return nil }
        return v["result"]
    }

    static func keyboard(_ rows: [[Message.Button]]) -> JValue {
        .object([.init("inline_keyboard", .array(rows.map { row in
            .array(row.map { .object([.init("text", .string($0.text)), .init("callback_data", .string($0.data))]) })
        }))])
    }

    /// `<b>title</b>` + text, HTML-escaped and cut to Telegram's limit.
    static func html(_ m: Message, limit: Int) -> String {
        let head = m.title.isEmpty ? "" : "<b>\(escape(m.title))</b>\n"
        var body = escape(m.text)
        if head.count + body.count > limit {
            body = String(body.prefix(max(0, limit - head.count - 1)))
            if let amp = body.lastIndex(of: "&"), !body[amp...].contains(";") { body = String(body[..<amp]) }  // no cut entity
            body += "…"
        }
        return head + body
    }

    public static func escape(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c { case "&": o += "&amp;"; case "<": o += "&lt;"; case ">": o += "&gt;"; default: o.append(c) }
        }
        return o
    }

    public func send(_ m: Message) -> Bool { send(m, to: chatId) }

    public func send(_ m: Message, to chat: String) -> Bool {
        if let photo = m.photo {
            if Telegram.html(m, limit: .max).count <= 1024 { return sendPhoto(m, photo, to: chat) }
            // Captions are short: the picture with the title, then the text with the buttons.
            var rest = m
            rest.photo = nil
            return sendPhoto(Message(title: m.title, text: ""), photo, to: chat) && send(rest, to: chat)
        }
        var body: [JValue.Member] = [.init("chat_id", Telegram.chat(chat)), .init("text", .string(Telegram.html(m, limit: 4096))),
                                     .init("parse_mode", .string("HTML")),
                                     .init("link_preview_options", .object([.init("is_disabled", .bool(true))]))]
        if !m.buttons.isEmpty { body.append(.init("reply_markup", Telegram.keyboard(m.buttons))) }
        return call("sendMessage", .object(body)) != nil
    }

    func sendPhoto(_ m: Message, _ png: [UInt8], to chat: String) -> Bool {
        Sys.mkdirs(tmpDir)
        let file = tmpDir + "/tg-\(Int(Sys.now() * 1000))-\(png.count).png"
        guard Sys.writeFile(file, png, mode: 0o600) else { return false }
        defer { Sys.remove(file) }
        var lines = [Curl.line("url", url("sendPhoto")), Curl.line("form-string", "chat_id=\(chat)"),
                     Curl.line("form-string", "caption=" + Telegram.html(m, limit: 1024)),
                     Curl.line("form-string", "parse_mode=HTML"), Curl.line("form", "photo=@\(file);type=image/png")]
        if !m.buttons.isEmpty { lines.append(Curl.line("form-string", "reply_markup=" + Telegram.keyboard(m.buttons).compact)) }
        guard let out = curl.request(lines, timeout: 60), let v = JValue.parse(out) else { return false }
        return v["ok"] == .bool(true)
    }
}

/// ntfy.sh (or a self-hosted server): POST <url>/<topic> with Title / Priority / Tags headers.
public struct Ntfy: Channel {
    public let name = "ntfy"
    var curl: Curl
    var url: String

    public init?(_ c: NotifyConfig, curl: Curl?) {
        guard let curl, let topic = c.ntfyTopic else { return nil }
        self.curl = curl
        url = (c.ntfyURL.hasSuffix("/") ? String(c.ntfyURL.dropLast()) : c.ntfyURL) + "/" + topic
    }

    public func send(_ m: Message) -> Bool {
        var lines = [Curl.line("url", url), Curl.line("data-binary", m.text),
                     Curl.line("header", "Priority: \(min(5, max(1, m.priority)))")]
        if !m.title.isEmpty { lines.append(Curl.line("header", "Title: " + Ntfy.header(m.title))) }
        if !m.tags.isEmpty { lines.append(Curl.line("header", "Tags: " + m.tags.joined(separator: ","))) }
        guard let out = curl.request(lines), let v = JValue.parse(out) else { return false }
        return v["id"] != nil
    }

    /// RFC 2047 base64 word for non-ASCII header values (ntfy decodes it).
    static func header(_ s: String) -> String {
        let clean = String(s.unicodeScalars.filter { $0.value >= 0x20 }.map(Character.init))
        return clean.utf8.allSatisfy({ $0 < 0x80 }) ? clean : "=?UTF-8?B?" + base64(Array(clean.utf8)) + "?="
    }

    static func base64(_ b: [UInt8]) -> String {
        let t = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var o: [UInt8] = []
        var i = 0
        while i < b.count {
            let n = min(3, b.count - i)
            let v = (UInt32(b[i]) << 16) | (n > 1 ? UInt32(b[i + 1]) << 8 : 0) | (n > 2 ? UInt32(b[i + 2]) : 0)
            o += [t[Int(v >> 18 & 63)], t[Int(v >> 12 & 63)], n > 1 ? t[Int(v >> 6 & 63)] : 61, n > 2 ? t[Int(v & 63)] : 61]
            i += 3
        }
        return String(decoding: o, as: UTF8.self)
    }
}
