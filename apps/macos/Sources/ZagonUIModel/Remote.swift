import Foundation
import ZagonCore

/// Servers: `zagon export --since <seq>` over ssh (`docs/dev/contracts.md`, Export), imported into the local database
/// by `ExportImport`. The cursor per ssh alias lives in `meta` (`remote_seq:<alias>`), the alias of each server host
/// name in `remote_alias:<host>`.
public enum Remote {
    /// Host aliases from `~/.ssh/config` (patterns with `*`, `?` or `!` skipped), in file order.
    public static func sshHosts(_ config: String) -> [String] {
        var out: [String] = []
        for line in config.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard words.count > 1, words[0].lowercased() == "host" else { continue }
            for w in words.dropFirst() where !w.contains(where: { "*?!".contains($0) }) && !out.contains(String(w)) {
                out.append(String(w))
            }
        }
        return out
    }

    /// `/usr/bin/ssh` arguments: never prompts, shares one connection for 10 minutes (a dead one ends within 45 s,
    /// e.g. after the Mac slept); `zagon` from ~/.local/bin.
    public static func sshArguments(host: String, since: Int, controlDir: String) -> [String] {
        sshArguments(host: host, zagon: ["export", "--since", String(since)], controlDir: controlDir)
    }

    /// `zagon <args>` on the host (each argument quoted for the remote shell); `stoppable`: under `stopScript`.
    public static func sshArguments(host: String, zagon args: [String], controlDir: String, stoppable: Bool = false) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
         "-o", "ControlMaster=auto", "-o", "ControlPersist=10m", "-o", "ControlPath=\(controlDir)/%C", host,
         "PATH=\"$HOME/.local/bin:$PATH\" " + (stoppable ? "sh -c \(shellWord(stopScript)) sh " : "") + "zagon "
            + args.map(shellWord).joined(separator: " ")]
    }

    /// `sh -c stopScript sh <command…>` on a server: runs the command and stops it, with the processes it started (an AI
    /// CLI), when stdin closes: the Mac cancelled (`Proc.Stop.closeInput`; a killed ssh client alone would leave the
    /// remote command running). The exit status is the command's; the watcher, a subshell waiting in `read`, goes with
    /// it. zagon is held still while its children are listed, then killed, then each child with its process group (zagon
    /// starts an AI CLI in its own). SIGKILL: zagon has no handler for SIGTERM anyway, and SQLite rolls an interrupted
    /// write back. Made for sshd's children: started from a Mac's worker thread, `wait` may never see the exit (SIGCHLD
    /// blocked).
    /// ponytail: its own children only, and only where `pgrep` is (Linux with procps, macOS); a process group if deeper.
    public static let stopScript = #"exec 3<&0; "$@" </dev/null 3<&- & z=$!; { while read -r _ <&3; do :; done; kill -STOP $z; c=$(pgrep -P $z); kill -9 $z; for p in $c; do kill -9 -$p $p; done; } >/dev/null 2>&1 & w=$!; exec 3<&-; wait $z; s=$?; kill -9 $w 2>/dev/null; exit $s"#

    /// One word for a POSIX shell: as is when plain, else single-quoted.
    public static func shellWord(_ s: String) -> String {
        !s.isEmpty && s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/@=,+".contains($0)) }) ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The error of a server whose zagon predates usage in its export (shown translated, logged as is).
    public static let oldZagon = "zagon there is older than this app (no usage in its export): reinstall it (install.sh); its days stay empty until then"

    /// The error of a server where ssh works but zagon is not found (shown translated, with `installCommand`).
    public static let noZagon = "zagon not found there (not installed, or not on the PATH of ssh commands)"
    /// install.sh as README gives it, with the service.
    public static let installCommand = "curl -fsSL https://raw.githubusercontent.com/a1lezakty/zagon/main/install.sh | sh -s -- --enable-service"

    /// This app's version; nil outside Zagon.app.
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// The strings key of the advice for a server by the `version` of its export: older than the app → `zagon update`;
    /// none at all → it predates releases and `zagon update`, so install.sh again. "dev" builds get no advice.
    public static func hint(server: String?, app: String?) -> String? {
        func parts(_ v: String) -> [Int]? {
            let p = v.split(separator: ".").compactMap { Int($0) }
            return p.count == 3 && p.map(String.init).joined(separator: ".") == v ? p : nil
        }
        guard let a = app.flatMap(parts) else { return nil }
        guard let server else { return "servers.reinstall" }
        return parts(server).map { $0.lexicographicallyPrecedes(a) } == true ? "servers.update" : nil
    }

    /// Where ssh keeps the connections it shares (`~/.zagon/ssh`, created).
    public static func controlDir() -> String {
        let dir = ZagonPaths().dir + "/ssh"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    public static func cursor(_ host: String, db: SQLite) throws -> Int {
        try db.one("SELECT value FROM meta WHERE key = ?", [.text("remote_seq:" + host)]) { $0.int(0) } ?? 0
    }

    public struct Imported: Sendable, Equatable {
        public var sessions = 0, days = 0, limits = 0
        /// Host names the server's database uses (shown and resumed as the alias).
        public var hosts: [String] = []
        /// The server's zagon predates usage and your time in its export: its days stay empty here until it is updated.
        public var old = false
        /// `version` of the server's zagon (`zagon --version`); nil from one older than the releases.
        public var version: String?
    }

    /// Applies one export through the core's reference client (`ExportImport`: rows under `export:<alias>`, untouched
    /// by local ingest), remembers which server host names belong to the alias and moves the cursor. A server whose
    /// counter went back (its database was rebuilt) is pulled from zero next time.
    ///
    /// One server under two checked aliases would be counted twice, and this Mac's own host name would replace its
    /// local days: both are refused. A host that moved from an alias no longer checked drops that alias's rows first.
    @discardableResult
    public static func apply(_ ndjson: Data, alias: String, store: Store, localHost: String = "",
                             checked: [String] = []) throws -> Imported {
        let lines = ndjson.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
        guard !lines.isEmpty else { throw RemoteError(host: alias, status: 0, message: "empty export") }
        var n = Imported(), hosts = Set<String>(), withUsage = 0
        for (i, l) in lines.enumerated() {
            let v = JValue.topLevelStrings(Array(l.utf8), keys: ["type", "host", "version"])
            guard i > 0 || v?["type"] == "export" else { throw RemoteError(host: alias, status: 0, message: "not an export") }
            if i == 0 { n.version = v?["version"] }
            switch v?["type"] {
            case "session": n.sessions += 1
            case "day":
                n.days += 1
                if l.contains("\"usage\":") { withUsage += 1 }
            case "limit": n.limits += 1
            default: break
            }
            // A `limit` line's `host` (0.1.5) is the store's own name, not a host of its rows: as before, rows only.
            if v?["type"] != "limit", let h = v?["host"] { hosts.insert(h) }
        }
        // This Mac's own database host (pinned at its first open), or the name it goes by now.
        if hosts.contains(store.host) || hosts.contains(localHost) {
            throw RemoteError(host: alias, status: 0, message: "this is this Mac")
        }
        // One transaction: a failed import after a rename keeps the old alias's rows.
        try store.db.transaction {
            let known = try aliases(db: store.db)
            for h in hosts.sorted() {
                guard let other = known[h], other != alias else { continue }
                if checked.contains(other) { throw RemoteError(host: alias, status: 0, message: "same server as \(other)") }
                try forget(other, db: store.db)
            }
            let since = try cursor(alias, db: store.db)
            let imp = try ExportImport(store: store, source: alias)
            try imp.apply(lines)
            try set("remote_seq:" + alias, .int(Int64(imp.seq < since ? 0 : imp.seq)), store.db)
            for h in hosts { try set("remote_alias:" + h, .text(alias), store.db) }
            // Days without usage came from a zagon before export2; once it is updated, everything is pulled again.
            let wasOld = try store.db.one("SELECT 1 FROM meta WHERE key = ?", [.text("remote_old:" + alias)]) { _ in true } ?? false
            if n.days > 0 && withUsage == 0 {
                try set("remote_old:" + alias, .int(1), store.db)
                n.old = true
            } else if wasOld && withUsage > 0 {
                try store.db.run("DELETE FROM meta WHERE key = ?", [.text("remote_old:" + alias)])
                try set("remote_seq:" + alias, .int(0), store.db)
            } else {
                n.old = wasOld
            }
        }
        n.hosts = hosts.sorted()
        return n
    }

    /// Drops the per-session rows imported under `alias` and its cursor (sessions and day totals are replaced by the
    /// alias that imports the server next).
    static func forget(_ alias: String, db: SQLite) throws {
        try db.transaction {
            if let file = try db.one("SELECT id FROM source_file WHERE path = ?", [.text("export:" + alias)], { $0.int64(0) }) {
                for t in ["usage_hour", "tool_use", "activity"] { try db.run("DELETE FROM \(t) WHERE file_id = ?", [.int(file)]) }
            }
            try db.run("DELETE FROM meta WHERE key IN (?, ?)", [.text("remote_seq:" + alias), .text("remote_old:" + alias)])
            // Its limit source (`Store.addLimitSnapshot`): an alias gone must not keep the rings labelled.
            try db.run("""
                DELETE FROM meta WHERE key = 'limit_account:' || ?1
                  OR key LIKE 'limit\\_src:%' ESCAPE '\\' AND substr(key, -length(?1) - 1) = ':' || ?1
                """, [.text(alias)])
        }
    }

    /// A server unchecked: everything imported under its alias leaves this Mac's numbers (its sessions, days, usage
    /// and host names); checking it again pulls it from the start.
    public static func drop(_ alias: String, db: SQLite) throws {
        try db.transaction {
            let hosts = try aliases(db: db).filter { $0.value == alias }.map(\.key)
            try forget(alias, db: db)
            for h in hosts {
                try db.run("DELETE FROM day_agg WHERE host = ?", [.text(h)])
                try db.run("DELETE FROM session WHERE host = ?", [.text(h)])
                try db.run("DELETE FROM meta WHERE key = ?", [.text("remote_alias:" + h)])
            }
        }
    }

    /// An error as it may go into the log and the diagnostics: no export line content, home folders as `~`.
    public static func brief(_ error: Error) -> String {
        switch error {
        // The remote shell found no zagon (127): ssh itself fails with 255.
        case let e as RemoteError where e.status == 127: return noZagon
        case let e as RemoteError: return (e.status == 0 ? "" : "exit \(e.status): ") + scrubHomes(e.message)
        case is ExportImportError: return "a line of the export could not be read"
        default: return scrubHomes(String(describing: error))
        }
    }

    /// `/home/<user>`, `/Users/<user>` and `/root` (of any machine) as `~`.
    public static func scrubHomes(_ s: String) -> String {
        s.replacing(/\/(?:home|Users)\/[^\/\s:'"]+|\/root(?=[\/\s:'"]|$)/, with: "~")
    }

    static func set(_ key: String, _ value: SQLValue, _ db: SQLite) throws {
        try db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2", [.text(key), value])
    }

    /// Server host name → ssh alias, for every server imported so far.
    public static func aliases(db: SQLite) throws -> [String: String] {
        var out: [String: String] = [:]
        try db.query("SELECT substr(key, 14), value FROM meta WHERE key LIKE 'remote\\_alias:%' ESCAPE '\\'") { r in
            if let h = r.text(0), let a = r.text(1) { out[h] = a }
        }
        return out
    }

    /// Runs ssh and returns its stdout; throws with the exit status and the last line of stderr. Both pipes are read
    /// at once (a full stderr pipe would block ssh), and the call gives up after `timeout` even if a shared ssh
    /// connection still holds the pipes open (`Proc`).
    public static func pull(host: String, since: Int, controlDir: String, timeout: Double? = nil,
                            executable: String = "/usr/bin/ssh", arguments: [String]? = nil) throws -> Data {
        // The first pull carries the whole history (2.5 MB in 0.3 s on a busy server; the link is the slow part).
        let timeout = timeout ?? (since == 0 ? 300 : 60)
        guard let r = try Proc.run(executable, arguments ?? sshArguments(host: host, since: since, controlDir: controlDir),
                                   timeout: timeout) else {
            throw RemoteError(host: host, status: -1, message: "no answer in \(Int(timeout)) s")
        }
        guard r.status == 0 else { throw RemoteError(host: host, status: r.status, message: r.errLastLine) }
        return r.out
    }
}

public struct RemoteError: Error, CustomStringConvertible, Sendable {
    public var host: String, status: Int32, message: String
    public var description: String { "ssh \(host): exit \(status) \(message)" }
}
