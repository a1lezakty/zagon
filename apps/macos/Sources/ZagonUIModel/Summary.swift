import Foundation
import ZagonCore

// Written summaries of a day or a period as the screens show them (cards per line of work), and the `zagon summary`
// calls that write them on the chosen source.

public struct SummaryCardVM: Sendable, Equatable {
    /// "project · KEY Title — 1h 20m, $12"
    public var title: String
    public var was: String?
    public var done: [String]
    public var left: String?
    public var color: UInt32
}

/// A summary in the language it is written in (labels, time and $ too); only the note is in the UI's language.
public struct SummaryVM: Sendable, Equatable {
    public var overview: String
    public var main: [String]
    public var cards: [SummaryCardVM]
    public var mainLabel: String
    public var wasLabel: String
    public var doneLabel: String
    public var leftLabel: String
    /// "Summary written by Claude at 20:00."
    public var note: String
    public var markdown: String

    /// `period`: the note gives the day it was written too.
    public init(_ k: KeptSummary, period: Bool, _ f: Fmt) {
        let d = k.doc
        let w = Fmt(lang: Lang(rawValue: d.lang) ?? f.lang, timeZone: f.calendar.timeZone, now: f.now)
        overview = d.overview
        main = d.main
        var projects: [String] = []
        cards = d.items.map { i in
            if !projects.contains(i.project) { projects.append(i.project) }
            let numbers = [i.sec > 0 ? w.duration(i.sec) : nil, i.cost > 0 ? w.cost(i.cost) : nil].compactMap { $0 }
            let title = (i.project.isEmpty ? "" : i.project + " · ") + i.heading
                + (numbers.isEmpty ? "" : " — " + numbers.joined(separator: ", "))
            return SummaryCardVM(title: title, was: i.was, done: i.done, left: i.left,
                                 color: Palette.series(projects.firstIndex(of: i.project) ?? 0))
        }
        mainLabel = w.t("sum.main"); wasLabel = w.t("sum.was"); doneLabel = w.t("sum.done"); leftLabel = w.t("sum.left")
        let day = f.shortDay(k.at), time = f.time(k.at), name = Self.engineName(k.engine)
        note = k.engine == "none" ? f.t("sum.noteNone", period ? day + " " + time : time)
            : period ? f.t("sum.notePeriod", name, day, time) : f.t("day.summaryNote.short", name, time)
        markdown = d.text(markdown: true)
    }

    /// claude → Claude, codex → Codex; other names as they are.
    public static func engineName(_ e: String) -> String {
        ["claude", "codex"].contains(e) ? e.prefix(1).uppercased() + e.dropFirst() : e
    }
}

/// A project of a day without a written summary.
public struct DoneProjectVM: Sendable, Equatable {
    public var name: String
    /// "2h 10m · $14"
    public var numbers: String
    /// "Title — 1h 10m · branch"
    public var sessions: [String]
    public var color: UInt32

    public init(_ p: DoneProject, index: Int, _ f: Fmt) {
        name = f.t.nonEmpty(p.name, "other")
        numbers = [f.duration(p.sec), p.cost > 0 ? f.cost(p.cost) : nil].compactMap { $0 }.joined(separator: " · ")
        sessions = p.sessions.map { s in
            s.title + (s.sec >= 60 ? " — " + f.duration(s.sec) : "") + (s.branch.map { " · " + $0 } ?? "")
        }
        color = p.name.isEmpty ? Palette.muted : Palette.series(index)
    }
}

// MARK: - what the CLI answers

/// `zagon summary … --json`: the kept summary of a day or a period.
public struct SummaryAnswer: Decodable, Sendable {
    public var key: String
    public var engine: String
    public var created: Double
    public var doc: SummaryDoc
    public var kept: KeptSummary { KeptSummary(doc: doc, engine: engine, at: Date(timeIntervalSince1970: created)) }
}

/// `zagon summary <period> --plan --json`: the days with sessions, those without a summary, the AI calls it takes.
public struct SummaryPlan: Decodable, Sendable, Equatable {
    public var key: String
    public var from: String
    public var to: String
    public var worked: [String]
    public var missing: [String]
    public var calls: Int
    public init(key: String, from: String, to: String, worked: [String], missing: [String], calls: Int) {
        self.key = key; self.from = from; self.to = to; self.worked = worked; self.missing = missing; self.calls = calls
    }
    /// Ask before the AI calls; without an AI engine (`calls` 0) nothing is asked.
    public var needsConfirm: Bool { !missing.isEmpty && calls > 0 }
}

/// One summary being written (by its key), and what came back.
public struct SummaryJob: Sendable {
    public var running = false
    public var progress: String?
    public var error: String?
    /// A period's plan waiting for the yes.
    public var confirm: SummaryPlan?
    /// The last answer, shown until the store holds one as new (the next pull brings it).
    public var result: KeptSummary?
    public init() {}

    /// The key of a day (`from == to`) or a period, as summaries are kept and jobs are named.
    public static func key(_ from: String, _ to: String) -> String { SummaryDoc.key(from, to) }

    /// The newer of the store's and the last answer.
    public static func newest(_ a: KeptSummary?, _ b: KeptSummary?) -> KeptSummary? {
        guard let a, let b else { return a ?? b }
        return b.at > a.at ? b : a
    }
}

/// The summary jobs of the screens and the outcome of the last "summary time" sent to the servers.
public struct SummaryState: Sendable {
    public var jobs: [String: SummaryJob] = [:]
    public var atMessage: String?
    public init() {}
}

extension TaskBackend {
    public enum SummaryStep: Sendable, Equatable { case day(Int, of: Int), period }

    func summaryAnswer(_ args: [String], timeout: Double) throws -> SummaryAnswer {
        let (out, _) = try call(args, timeout: timeout)
        // A login banner may come first: the JSON is the last line.
        return try Self.parse(out.split(separator: UInt8(ascii: "\n")).last.map { Data($0) } ?? out, args)
    }

    /// The day's kept summary; written first when there is none (an AI call, up to a couple of minutes), or again
    /// with `refresh`.
    public func summary(day: String, refresh: Bool) throws -> KeptSummary {
        try summaryAnswer(["summary", day, "--json"] + (refresh ? ["--refresh"] : []), timeout: 300).kept
    }

    public func summaryPlan(from: String, to: String) throws -> SummaryPlan {
        try decode(["summary", "--from", from, "--to", to, "--plan", "--json"]).0
    }

    /// The period written again from its days, after the days without a summary are written one by one.
    public func writePeriod(_ plan: SummaryPlan, progress: @Sendable (SummaryStep) async -> Void = { _ in }) async throws -> KeptSummary {
        for (i, d) in plan.missing.enumerated() {
            await progress(.day(i + 1, of: plan.missing.count))
            // A day kept without AI is in `missing` when an AI engine is set: written again.
            _ = try summary(day: d, refresh: true)
        }
        await progress(.period)
        return try summaryAnswer(["summary", "--from", plan.from, "--to", plan.to, "--json", "--refresh", "--yes"], timeout: 300).kept
    }

    /// `[summary] time` of the source's config.toml: "HH:MM", nil = off.
    public func setSummaryTime(_ at: String?) throws {
        _ = try call(["summary", "--at", at ?? "off", "--json"], timeout: 60)
    }
}

extension NotifySettings {
    /// "20:00" of minutes after midnight.
    public static func clock(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return (h < 10 ? "0" : "") + "\(h):" + (m < 10 ? "0" : "") + "\(m)"
    }

    /// Minutes after midnight of "H:MM" / "HH:MM"; nil when it is not a time of day.
    public static func minutes(_ s: String) -> Int? {
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, (1...2).contains(p[0].count), p[1].count == 2, p.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}
