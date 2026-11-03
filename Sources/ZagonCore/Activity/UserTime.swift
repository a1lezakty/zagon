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
    /// typed message another session typed (`drivers`: session → that session), over this host's sessions. A driver
    /// takes a relay aimed at the session's own name, or any relay when the session has no human messages at all: a
    /// looser match there would hide a session that waits for you.
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
        /// The session that typed `session`'s message at `t` (nil = the human); `named`: its relay was aimed at exactly
        /// `session`'s name.
        func relayed(_ session: String, _ t: Timestamp) -> (by: String, named: Bool)? {
            var lo = 0, hi = relays.count
            while lo < hi { let m = (lo + hi) / 2; if relays[m].ts < t - relayBefore { lo = m + 1 } else { hi = m } }
            let name = names[session]
            var loose: String?
            while lo < relays.count, relays[lo].ts <= t + relayAfter {
                let r = relays[lo]; lo += 1
                guard r.session != session else { continue }
                if let name, name == r.target { return (r.session, true) }
                guard !r.target.isEmpty else { loose = loose ?? r.session; continue }
                if let name { if same(name, r.target) { loose = loose ?? r.session }; continue }
                if !names.contains(where: { $0.key != session && $0.value == r.target }) { loose = loose ?? r.session }
            }
            return loose.map { ($0, false) }
        }
        var acts: [(session: String, ts: Timestamp, kind: String)] = []
        try db.query("""
            SELECT DISTINCT a.session_id, a.ts, a.kind FROM user_action a LEFT JOIN session s ON s.id = a.session_id
            WHERE coalesce(s.host, ?1) = ?1 ORDER BY a.session_id, a.ts
            """, [.text(host)]) { acts.append(($0.text(0) ?? "", $0.real(1), $0.text(2) ?? "")) }
        var points: [Timestamp] = [], messages: [String: Int] = [:], drivers: [String: (by: String, named: Bool)] = [:]
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
        return (points.sorted(), messages,
                drivers.filter { $0.value.named || messages[$0.key, default: 0] == 0 }.mapValues(\.by))
    }

    /// A driver silent for this long (killed without its `SessionEnd`) drives no more. Long: a leader waits for its
    /// workers on background watchers that write nothing to its transcript.
    static let driverIdle: Double = 12 * 3600

    /// SQL for the name of the session that typed the last typed message of session `s` (`session.driver`): its title,
    /// else its project, '' = neither. NULL = the human, also when that session has ended, is archived or has been
    /// silent for `driverIdle` before `now` (no one else will answer).
    static func driverSQL(_ s: String = "s", now: Timestamp) -> String {
        """
        (SELECT coalesce(d.title, \(Projects.sessionSQL("d")), '') FROM session d
         WHERE d.id = \(s).driver AND coalesce(d.status, '') <> 'ended' AND coalesce(d.archived, 0) = 0
           AND max(coalesce(d.last_at, 0), coalesce(d.status_at, 0)) > \(now - driverIdle))
        """
    }

    /// Lower-case letters and digits: `my-web` and `myweb` are one name.
    static func norm(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
}
