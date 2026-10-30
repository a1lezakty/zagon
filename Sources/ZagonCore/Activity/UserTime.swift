/// Which user actions are the human's. A message typed in session W at `t` (`user_action.kind = 'msg'`) was sent by
/// another session when one of them typed into a terminal (`relay`) in [t - relayBefore, t + relayAfter]: workers
/// driven over `tmux send-keys` look exactly like a human at the keyboard in their transcripts, and their messages land
/// 0–26 s after the driver's call. When W has a name (`claude --name`, `/rename`: a Claude title of rank >= agent
/// name) only a relay aimed at it counts (its `-t` target equals W's name or one is a prefix of the other, letters and
/// digits compared). Without a name, a relay counts unless its target is another session's name. A relay with no plain
/// target (`$s`, `%3`, none) counts for any session. Channel messages (Telegram…) are always the human's. The `read`
/// action before a relayed message goes with it.
enum UserTime {
    static let relayBefore = 30.0, relayAfter = 5.0

    /// Points that make your time (sorted), the number of human messages per session, and the sessions whose last
    /// typed message another session typed (`drivers`: session → that session), over this host's sessions.
    static func humanActions(_ db: SQLite, host: String)
        throws -> (points: [Timestamp], messages: [String: Int], drivers: [String: String]) {
        var relays: [(ts: Timestamp, session: String, target: String)] = []
        try db.query("""
            SELECT r.ts, r.session_id, r.target FROM relay r LEFT JOIN session s ON s.id = r.session_id
            WHERE coalesce(s.host, ?1) = ?1 ORDER BY r.ts
            """, [.text(host)]) { relays.append(($0.real(0), $0.text(1) ?? "", norm($0.text(2) ?? ""))) }
        var names: [String: String] = [:]
        if !relays.isEmpty {
            try db.query("SELECT id, title FROM session WHERE tool = 'claude' AND title_rank >= ?1 AND coalesce(host, ?2) = ?2",
                         [.int(Int64(TitleRank.agentName)), .text(host)]) {
                if let id = $0.text(0), let n = $0.text(1).map(norm), !n.isEmpty { names[id] = n }
            }
        }
        func same(_ name: String, _ target: String) -> Bool { name.hasPrefix(target) || target.hasPrefix(name) }
        /// The session that typed `session`'s message at `t`, nil = the human.
        func relayed(_ session: String, _ t: Timestamp) -> String? {
            var lo = 0, hi = relays.count
            while lo < hi { let m = (lo + hi) / 2; if relays[m].ts < t - relayBefore { lo = m + 1 } else { hi = m } }
            let name = names[session]
            while lo < relays.count, relays[lo].ts <= t + relayAfter {
                let r = relays[lo]; lo += 1
                guard r.session != session else { continue }
                guard !r.target.isEmpty else { return r.session }
                if let name { if same(name, r.target) { return r.session } else { continue } }
                if !names.contains(where: { $0.key != session && $0.value == r.target }) { return r.session }
            }
            return nil
        }
        var acts: [(session: String, ts: Timestamp, kind: String)] = []
        try db.query("""
            SELECT a.session_id, a.ts, a.kind FROM user_action a LEFT JOIN session s ON s.id = a.session_id
            WHERE coalesce(s.host, ?1) = ?1 ORDER BY a.session_id, a.ts
            """, [.text(host)]) { acts.append(($0.text(0) ?? "", $0.real(1), $0.text(2) ?? "")) }
        var points: [Timestamp] = [], messages: [String: Int] = [:], drivers: [String: String] = [:]
        var session = "", nextRelayed = false  // walking back: whether the session's next action was relayed
        var last = true  // walking back: no typed message of the session seen yet
        for a in acts.reversed() {
            if a.session != session { session = a.session; nextRelayed = false; last = true }
            switch a.kind {
            case "msg":
                let by = relayed(a.session, a.ts)
                nextRelayed = by != nil
                if let by, last { drivers[a.session] = by }
                last = false
                if !nextRelayed { points.append(a.ts); messages[a.session, default: 0] += 1 }
            case "channel":
                nextRelayed = false; last = false
                points.append(a.ts); messages[a.session, default: 0] += 1
            case "read":
                if !nextRelayed { points.append(a.ts) }
            default:
                points.append(a.ts)
            }
        }
        return (points.sorted(), messages, drivers)
    }

    /// SQL for the title of the session that typed the last typed message of session `s` (`session.driver`): NULL = the
    /// human, '' = a session without a title.
    static func driverSQL(_ s: String = "s") -> String {
        "CASE WHEN \(s).driver IS NULL THEN NULL ELSE coalesce((SELECT d.title FROM session d WHERE d.id = \(s).driver), '') END"
    }

    /// Lower-case letters and digits: `LB-web` and `lbweb` are one name.
    static func norm(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
}
