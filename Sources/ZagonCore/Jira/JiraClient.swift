#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Optional Jira module: Atlassian Cloud REST, Basic auth with an API token read from a file. HTTP goes through a
/// `curl` subprocess; the credentials travel in curl's config on stdin, never in argv or output.
public struct JiraConfig: Sendable {
    public var baseURL: String
    public var email: String
    /// The token is the last non-empty line of this file.
    public var tokenFile: String
    public var curl = "curl"
    public init(baseURL: String, email: String, tokenFile: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.email = email; self.tokenFile = tokenFile
    }

    /// `[jira] url, email, token_file` from config.toml; nil when the module is not configured.
    public static func load(configText: String) -> JiraConfig? {
        guard let u = TOMLLite.string(in: configText, section: "jira", key: "url"),
              let e = TOMLLite.string(in: configText, section: "jira", key: "email"),
              let f = TOMLLite.string(in: configText, section: "jira", key: "token_file") else { return nil }
        return JiraConfig(baseURL: u, email: e, tokenFile: f)
    }
}

public struct JiraIssue: Codable, Sendable, Equatable {
    public var key: String
    public var summary: String
    public var status: String
    /// `new` | `indeterminate` | `done`.
    public var statusCategory: String
}

public struct JiraWorklog: Codable, Sendable, Equatable {
    public var id: String
    public var issueKey: String
    public var accountId: String
    public var started: Timestamp
    public var seconds: Int
    /// The worklog's text (API v2: plain text).
    public var comment: String? = nil
    public var interval: Interval { Interval(started, started + Double(seconds)) }
}

public enum JiraError: Error, CustomStringConvertible {
    /// `notSent`: the request never left (no curl, no host, no connection); `transport`: it may have reached Jira
    /// (a timeout or a lost reply after it was sent).
    case token(String), notSent(String), transport(String), http(Int, String)
    public var description: String {
        switch self {
        case .token(let m): "jira token: \(m)"
        case .notSent(let m), .transport(let m): "jira: \(m)"
        case .http(let c, let b): "jira HTTP \(c): \(b)"
        }
    }
    /// Whether a write that failed this way may still have been done by Jira: only a 4xx answer or a request that
    /// never left says it was not.
    public var mayHaveArrived: Bool {
        switch self {
        case .token, .notSent: false
        case .http(let c, _): !(400..<500).contains(c)
        case .transport: true
        }
    }
}

public final class JiraClient {
    public let config: JiraConfig
    private let token: String
    private var me: String?

    public init(_ config: JiraConfig) throws {
        self.config = config
        // Basic auth over plain HTTP would send the token in clear text; only a local mock may use http.
        guard Self.allowed(config.baseURL) else { throw JiraError.notSent("url must be https") }
        let path = config.tokenFile.hasPrefix("~/") ? (getenv("HOME").map { String(cString: $0) } ?? "") + config.tokenFile.dropFirst() : config.tokenFile
        guard let text = Sys.readFile(path).map({ String(decoding: $0, as: UTF8.self) }) else { throw JiraError.token("cannot read \(path)") }
        guard let t = text.split(separator: "\n").map({ $0.trimmed(" \t\r") }).last(where: { !$0.isEmpty }) else {
            throw JiraError.token("empty file")
        }
        token = t
    }

    /// `https://` anywhere; `http://` only to this machine: the host exactly `localhost`, `127.0.0.1` or `[::1]`
    /// (not `localhost.example.com`, not `user@host`).
    static func allowed(_ url: String) -> Bool {
        let u = url.lowercased()
        if u.hasPrefix("https://") { return true }
        guard u.hasPrefix("http://") else { return false }
        let authority = u.dropFirst(7).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.contains("@") else { return false }
        var host = Substring(authority), port: Substring = ""
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            port = host[host.index(after: close)...]; host = host[...close]
        } else if let colon = host.firstIndex(of: ":") {
            port = host[colon...]; host = host[..<colon]
        }
        guard port.isEmpty || (port.hasPrefix(":") && port.count > 1 && port.dropFirst().allSatisfy(\.isNumber)) else { return false }
        return ["localhost", "127.0.0.1", "[::1]"].contains(String(host))
    }

    // MARK: transport

    /// curl config syntax: double-quoted, backslash escapes.
    static func quoted(_ s: String) -> String {
        var o = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\\": o += "\\\\"
            case "\"": o += "\\\""
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default: o.unicodeScalars.append(c)
            }
        }
        return o + "\""
    }

    func request(_ method: String, _ path: String, json body: [UInt8]? = nil) throws -> [UInt8] {
        var cfg = """
            url = \(Self.quoted(config.baseURL + path))
            user = \(Self.quoted(config.email + ":" + token))
            request = "\(method)"
            header = "Accept: application/json"
            max-time = 60
            silent
            show-error
            write-out = "\\n%{http_code}"

            """
        if let body {
            cfg += "header = \"Content-Type: application/json\"\ndata-binary = \(Self.quoted(String(decoding: body, as: UTF8.self)))\n"
        }
        // Plain http goes only to this machine: never through an http_proxy (it would see the token).
        if config.baseURL.lowercased().hasPrefix("http://") { cfg += "noproxy = \"*\"\n" }
        guard let r = Exec.run([config.curl, "-q", "-K", "-"], stdin: Array(cfg.utf8)) else {
            throw JiraError.notSent("cannot run \(config.curl)")
        }
        // curl 6: host not resolved, 7: no connection: nothing was sent.
        if r.status == 6 || r.status == 7 { throw JiraError.notSent("curl exit \(r.status)") }
        guard r.status == 0, let nl = r.out.lastIndex(of: 0x0A) else { throw JiraError.transport("curl exit \(r.status)") }
        let code = Int(String(decoding: r.out[(nl + 1)...], as: UTF8.self)) ?? 0
        let data = Array(r.out[..<nl])
        guard (200..<300).contains(code) else {
            throw JiraError.http(code, String(String(decoding: data, as: UTF8.self).prefix(300)))
        }
        return data
    }

    func get<T: Decodable>(_ path: String, _ t: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(try request("GET", path)))
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for b in s.utf8 {
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || "-._~".utf8.contains(b) {
                o.unicodeScalars.append(UnicodeScalar(b))
            } else {
                let h = Array("0123456789ABCDEF".utf8)
                o += "%" + String(decoding: [h[Int(b >> 4)], h[Int(b & 15)]], as: UTF8.self)
            }
        }
        return o
    }

    // MARK: reading

    struct Myself: Decodable { var accountId: String }
    struct Status: Decodable { struct Cat: Decodable { var key: String? }; var name: String?; var statusCategory: Cat? }
    struct Fields: Decodable { var summary: String?; var status: Status? }
    struct IssueBean: Decodable {
        var key: String; var fields: Fields?
        var issue: JiraIssue {
            JiraIssue(key: key, summary: fields?.summary ?? "", status: fields?.status?.name ?? "",
                      statusCategory: fields?.status?.statusCategory?.key ?? "")
        }
    }
    struct SearchPage: Decodable { var issues: [IssueBean]; var nextPageToken: String?; var isLast: Bool? }
    struct WorklogBean: Decodable {
        struct Author: Decodable { var accountId: String? }
        var id: String; var author: Author?; var started: String?; var timeSpentSeconds: Int?; var comment: String?
    }
    struct ContextBean: Decodable {
        struct Comment: Decodable { var body: String? }
        struct Comments: Decodable { var comments: [Comment]? }
        struct F: Decodable { var description: String?; var comment: Comments? }
        var fields: F?
    }
    struct WorklogPage: Decodable { var startAt: Int?; var total: Int?; var worklogs: [WorklogBean] }

    /// Account id of the token's user.
    public func accountId() throws -> String {
        if let me { return me }
        let id = try get("/rest/api/2/myself", Myself.self).accountId
        me = id
        return id
    }

    /// Enhanced JQL search (`/rest/api/3/search/jql`), all pages.
    public func search(_ jql: String, limit: Int = 500) throws -> [JiraIssue] {
        var out: [JiraIssue] = [], token: String?
        repeat {
            var body: [String: JSONValue] = ["jql": .s(jql), "fields": .a([.s("summary"), .s("status")]), "maxResults": .n(100)]
            if let token { body["nextPageToken"] = .s(token) }
            let page = try JSONDecoder().decode(SearchPage.self, from: Data(try request("POST", "/rest/api/3/search/jql",
                                                                                          json: Array(try JSONEncoder().encode(body)))))
            out += page.issues.map(\.issue)
            token = page.issues.isEmpty || page.isLast == true ? nil : page.nextPageToken
        } while token != nil && out.count < limit
        return out
    }

    /// One issue, nil if it does not exist (or is not visible).
    public func issue(_ key: String) throws -> JiraIssue? {
        do { return try get("/rest/api/2/issue/\(Self.escape(key))?fields=summary,status", IssueBean.self).issue }
        catch JiraError.http(404, _) { return nil }
    }

    /// An issue's description and comments, oldest first (API v2: plain text); nil if the issue is not visible.
    public func context(_ key: String) throws -> (description: String?, comments: [String])? {
        do {
            let f = try get("/rest/api/2/issue/\(Self.escape(key))?fields=description,comment", ContextBean.self).fields
            return (f?.description, f?.comment?.comments?.compactMap(\.body) ?? [])
        } catch JiraError.http(404, _) { return nil }
    }

    /// All worklogs of an issue started after `after` (any author).
    public func worklogs(issue key: String, startedAfter after: Timestamp) throws -> [JiraWorklog] {
        var out: [JiraWorklog] = [], at = 0
        while true {
            let p = try get("/rest/api/2/issue/\(Self.escape(key))/worklog?startedAfter=\(Int64(after * 1000))&startAt=\(at)&maxResults=1000",
                            WorklogPage.self)
            for w in p.worklogs {
                // Jira Cloud may ignore startedAfter here (seen 30.10: an issue returned its whole history).
                guard let s = w.started.flatMap(Self.parseTime), s >= after else { continue }
                out.append(JiraWorklog(id: w.id, issueKey: key, accountId: w.author?.accountId ?? "", started: s,
                                       seconds: w.timeSpentSeconds ?? 0, comment: w.comment))
            }
            at += p.worklogs.count
            if p.worklogs.isEmpty || at >= (p.total ?? 0) { return out }
        }
    }

    /// Your worklogs that overlap [from, to), on any issue.
    public func myWorklogs(from: Timestamp, to: Timestamp) throws -> [JiraWorklog] {
        let me = try accountId()
        // worklogDate is in the profile's time zone: ask a day wider, then filter by real overlap.
        let jql = "worklogAuthor = currentUser() AND worklogDate >= \"\(Self.utcDay(from - 86400))\" AND worklogDate <= \"\(Self.utcDay(to + 86400))\""
        var out: [JiraWorklog] = []
        for i in try search(jql) {
            out += try worklogs(issue: i.key, startedAfter: from - 86400).filter {
                $0.accountId == me && $0.interval.start < to && $0.interval.end > from
            }
        }
        return out.sorted { $0.started < $1.started }
    }

    // MARK: writing — only on an explicit command (CLI with confirmation, MCP with confirm: true, bot button)

    /// Adds a worklog; returns its id.
    public func addWorklog(issue key: String, started: Timestamp, seconds: Int, comment: String) throws -> String {
        let body: [String: JSONValue] = ["started": .s(Self.jiraTime(started)), "timeSpentSeconds": .n(seconds), "comment": .s(comment)]
        let data = try request("POST", "/rest/api/2/issue/\(Self.escape(key))/worklog", json: Array(try JSONEncoder().encode(body)))
        return try JSONDecoder().decode(WorklogBean.self, from: Data(data)).id
    }

    // MARK: time formats

    /// Jira writes `2026-10-29T10:00:00.000+0300`; Time.parseISO wants `+03:00`.
    static func parseTime(_ s: String) -> Timestamp? {
        var s = s
        let u = Array(s.utf8)
        if u.count >= 5, u[u.count - 5] == 0x2B || u[u.count - 5] == 0x2D, u.suffix(4).allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
            s = String(s.dropLast(2)) + ":" + String(s.suffix(2))
        }
        return Time.parseISO(s)
    }

    static func civil(_ ts: Timestamp) -> tm {
        var t = time_t(ts.rounded(.down)), v = tm()
        gmtime_r(&t, &v)
        return v
    }

    static func p2(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }

    static func utcDay(_ ts: Timestamp) -> String {
        let v = civil(ts)
        return "\(v.tm_year + 1900)-\(p2(v.tm_mon + 1))-\(p2(v.tm_mday))"
    }

    static func jiraTime(_ ts: Timestamp) -> String {
        let v = civil(ts)
        return utcDay(ts) + "T\(p2(v.tm_hour)):\(p2(v.tm_min)):\(p2(v.tm_sec)).000+0000"
    }
}

/// Minimal JSON value for request bodies.
enum JSONValue: Encodable {
    case s(String), n(Int), a([JSONValue])
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .s(let v): try c.encode(v)
        case .n(let v): try c.encode(v)
        case .a(let v): try c.encode(v)
        }
    }
}
