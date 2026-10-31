import Foundation
import ZagonCore

/// The design sample: Friday, October 30 2026, 11:42 in `timeZone`. Day, week and worklog detail exist for
/// October 29, the week of October 26 and October 30; other dates get totals only. Session titles and texts come in
/// the UI language so snapshots read like the mockups.
public struct MockDataProvider: ZagonDataProvider {
    public let now: Date
    let lang: Lang
    let cal: Calendar

    /// The last limit reading is from 05:12, before the 5-hour reset at 09:20: the snapshots' "no new reading" state.
    public var staleLimits = false
    /// Codex limits next to Claude's (both AIs in the menu bar and the panel).
    public var codexLimits = false
    /// Claude used where its status line does not run (an editor extension): sessions, no reading.
    public var claudeUnread = false

    public init(lang: Lang = .en, timeZone: TimeZone = .current) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        cal = c
        self.lang = lang
        now = c.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 11, minute: 42))!
    }

    func tr(_ en: String, _ ru: String) -> String { lang == .ru ? ru : en }

    /// A moment in October 2026 (day 32 = November 1, …), hour as a fraction.
    func at(_ day: Int, _ hour: Double) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day))!.addingTimeInterval(hour * 3600)
    }

    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    static let h = 3600.0
    static let octoberHours: [Double?] = [6.5, 5.0, 1.2, 0, 7.4, 8.1, 6.9, 9.2, 4.4, 0.8, 2.1, 8.8, 9.5, 10.2, 7.7, 6.1, 3.0, 0,
                                          7.9, 8.6, 9.9, 8.3, 5.2, 4.0, 1.5, 6.2, 9.1, 8.4, 9.7, 3.4, nil]

    // MARK: menu bar

    public func limits() -> Limits {
        if staleLimits {
            return Limits(fiveHour: LimitWindow(usedPct: 97, resetsAt: at(30, 9 + 20 / 60), tool: .claude, readAt: ago(390)),
                          week: LimitWindow(usedPct: 47, resetsAt: at(33, 9), tool: .claude, readAt: ago(390)))
        }
        // 62 % now, 100 % at 13:50 — 30 minutes before the 14:20 reset.
        var l = Limits(fiveHour: LimitWindow(usedPct: 62, resetsAt: at(30, 14 + 20 / 60), pctPerHour: 38 / (128 / 60),
                                             tool: .claude, readAt: ago(2)),
                       week: LimitWindow(usedPct: 41, resetsAt: at(33, 9), tool: .claude, readAt: ago(2)))
        if codexLimits {
            l.codex = AILimits(fiveHour: LimitWindow(usedPct: 18, resetsAt: at(30, 16 + 5 / 60), tool: .codex, readAt: ago(6)),
                               week: LimitWindow(usedPct: 71, resetsAt: at(34, 11), tool: .codex, readAt: ago(6)))
        }
        if claudeUnread {
            l.claude = AILimits()
            l.claudeSeen = ago(4)
        }
        return l
    }

    public func limitHistory(_ kind: LimitKind) -> [LimitPoint] {
        switch kind {
        case .fiveHour:
            return [(9.5, 3), (10, 10), (10.5, 20), (11, 39), (11.5, 57)].map { LimitPoint(at(30, $0.0), $0.1) }
        case .week:
            return [(26, 18.0, 7.0), (27, 18, 15), (28, 18, 24), (29, 23, 37)].map { LimitPoint(at($0.0, $0.1), $0.2) }
        }
    }

    public func liveSessions() -> [LiveSession] {
        [
            LiveSession(id: "claude:web", title: tr("web-app — demo video", "web-app — демо-видео"), host: "build-box",
                        model: "Opus 5.5", status: .waitingPermission, since: ago(12),
                        command: "ssh build-box -t tmux attach -t web"),
            LiveSession(id: "claude:api", title: "api-server — PROJ-12", host: "build-box", model: "Opus 5.5",
                        status: .waitingInput, since: ago(4), command: "ssh build-box -t tmux attach -t api"),
            LiveSession(id: "claude:zagon", title: tr("zagon — mockups", "zagon — макеты"), host: "build-box",
                        model: "Opus 5.5", status: .working, since: ago(41), command: "ssh build-box -t tmux attach -t zagon"),
            LiveSession(id: "claude:train", title: "ml-train — run 300", host: "gpu-box", model: "Opus 5.5", status: .working,
                        since: ago(65), command: "ssh gpu-box -t tmux attach -t train"),
            LiveSession(id: "claude:cli", title: "cli-tool — parser", host: "laptop", model: "Sonnet 5.5", status: .working,
                        since: ago(18), command: "claude --resume 5b1e09c4"),
            LiveSession(id: "claude:tracker", title: tr("tracker — worklogs", "tracker — ворклоги"), host: "build-box", model: "Haiku 4.5",
                        status: .idle, since: ago(180), command: "claude --resume 0c7d2e11"),
            LiveSession(id: "claude:worker", title: tr("web-app — worker", "web-app — воркер"), host: "build-box",
                        model: "Opus 5.5", status: .idle, since: ago(40), command: "ssh build-box -t tmux attach -t worker"),
            LiveSession(id: "claude:costs", title: "docs-site — PROJ-14", host: "build-box", model: "Opus 5.5", status: .idle,
                        since: ago(120), command: "claude --resume 3f9a6b20"),
            LiveSession(id: "codex:layout", title: tr("web-app — layout check", "web-app — проверка вёрстки"), host: "build-box",
                        tool: .codex, model: "GPT-5", status: .idle, since: ago(80), command: "codex resume 019a2f"),
        ]
    }

    public func todayTotals() -> Totals {
        Totals(sessionSec: 7 * Self.h + 20 * 60, userSec: 3 * Self.h, tokens: 18_400_000, cost: 212,
               costByTool: [.claude: 178, .codex: 34])
    }

    public func hosts() -> [Host] {
        [Host(name: "build-box", online: true), Host(name: "gpu-box", online: true), Host(name: "laptop", online: true)]
    }

    // MARK: day

    func hoursOn(_ day: Date) -> Double? {
        let c = cal.dateComponents([.year, .month, .day], from: day)
        guard c.year == 2026, c.month == 10, let d = c.day else { return day < now ? 0 : nil }
        return Self.octoberHours[d - 1]
    }

    func roughTotals(_ hours: Double) -> Totals {
        Totals(sessionSec: hours * Self.h, userSec: hours * Self.h / 4, tokens: Int(hours * 3_200_000), cost: hours * 36)
    }

    public func day(_ day: Date) -> DayData {
        let d = cal.startOfDay(for: day)
        guard cal.isDate(d, inSameDayAs: at(29, 0)) else { return DayData(day: d, totals: roughTotals(hoursOn(d) ?? 0)) }
        func lane(_ title: String, _ host: String, _ parts: [(Double, Double, Bool)]) -> Lane {
            Lane(title: title, host: host, intervals: parts.map { Interval(at(29, $0.0), at(29, $0.1), waiting: $0.2) })
        }
        let lanes = [
            lane(tr("tracker — worklogs", "tracker — ворклоги"), "build-box", [(8, 9, false)]),
            lane("api-server — PROJ-12", "build-box",
                 [(9, 11.5, false), (11.5, 12 + 10 / 60, true), (12 + 10 / 60, 13 + 40 / 60, false), (16, 16.5, true),
                  (16.5, 18.5, false)]),
            lane(tr("web-app — main", "web-app — основная"), "build-box",
                 [(9, 13, false), (13, 13 + 20 / 60, true), (22.5, 24, false)]),
            lane(tr("web-app — worker", "web-app — воркер"), "build-box", [(13 + 20 / 60, 19.5, false), (21, 24, false)]),
            lane("ml-train — run 300", "gpu-box", [(10, 17.5, false)]),
            lane("cli-tool — parser", "laptop", [(14, 15 + 10 / 60, false), (15 + 10 / 60, 17, true)]),
            lane("docs-site — PROJ-14", "build-box", [(18.5, 20, false), (21, 22.5, false)]),
        ]
        func rows(_ r: [(String, Int, Double)]) -> [UsageRow] { r.map { UsageRow($0.0, tokens: $0.1, cost: $0.2) } }
        let usage: [UsageDimension: [UsageRow]] = [
            .project: rows([("api-server", 10_600_000, 118), ("web-app", 8_400_000, 94), ("ml-train", 5_600_000, 63),
                            ("docs-site", 3_800_000, 42), ("", 2_800_000, 31)]),
            .model: rows([("Opus 5.5", 24_100_000, 290), ("Sonnet 5.5", 6_300_000, 52), ("Haiku 4.5", 800_000, 6)]),
            .agent: rows([("", 19_800_000, 221), ("Explore", 5_200_000, 58), ("engineer", 3_900_000, 44),
                          ("reviewer", 2_300_000, 25)]),
            .tool: rows([("Bash", 412, 0), ("Edit", 236, 0), ("Read", 198, 0), ("Agent", 41, 0), ("", 120, 0)]),
            .host: rows([("build-box", 22_300_000, 249), ("gpu-box", 5_600_000, 63), ("laptop", 3_300_000, 36)]),
        ]
        let projects = [
            DoneProject("api-server", sec: 6 * Self.h + 10 * 60, cost: 118, sessions: [
                DoneSession("PROJ-12", branch: "PROJ-12-webhook-retries", sec: 6 * Self.h + 10 * 60)]),
            DoneProject("web-app", sec: 14 * Self.h + 10 * 60, cost: 94, sessions: [
                DoneSession(tr("worker", "воркер"), branch: "settings-page", sec: 9 * Self.h + 10 * 60),
                DoneSession(tr("main", "основная"), branch: "main", sec: 5 * Self.h + 30 * 60)]),
            DoneProject("ml-train", sec: 7.5 * Self.h, cost: 63, sessions: [DoneSession("run 300", sec: 7.5 * Self.h)]),
        ]
        return DayData(day: d, totals: Totals(sessionSec: 9 * Self.h + 40 * 60, userSec: 2 * Self.h + 15 * 60,
                                              tokens: 31_200_000, cost: 348),
                       limitHits: [Interval(at(29, 13 + 40 / 60), at(29, 14 + 20 / 60))], weekPctStart: 24, weekPctEnd: 37,
                       lanes: lanes, usage: usage, doc: dayDoc, projects: projects,
                       summaryInfo: SummaryInfo(engine: "Claude Haiku", at: at(29, 23 + 59 / 60), weekPct: 0.2))
    }

    /// The written summary of October 29.
    var dayDoc: SummaryDoc {
        SummaryDoc(lang: lang.rawValue, from: "2026-10-29", to: "2026-10-29", overview: tr(
            "A long day on the payment webhook: the double charge is fixed and checked on dev. The settings page is ready, run 300 trained.",
            "Длинный день вокруг вебхука оплаты: двойное списание исправлено и проверено на деве. Страница настроек готова, run 300 обучен."),
            items: [
                .init(project: "api-server", key: "PROJ-12", title: tr("Check the payment webhook retries", "Проверить повторы вебхука оплаты"),
                      was: tr("A retry after a timeout charged twice.", "Повтор после таймаута списывал дважды."),
                      done: [tr("Reproduced the double charge with live runs", "Двойное списание воспроизведено живыми прогонами"),
                             tr("Idempotency key on retries", "Ключ идемпотентности на повторах"),
                             tr("Three defects fixed, final comment on the task", "Три дефекта исправлены, итоговый комментарий к задаче")],
                      left: tr("A load test with 3 retries.", "Нагрузочный тест с тремя повторами."), sec: 6 * Self.h + 10 * 60, cost: 118),
                .init(project: "web-app", title: tr("Settings page and dark theme", "Страница настроек и тёмная тема"),
                      was: tr("The settings were scattered over three dialogs.", "Настройки были разбросаны по трём диалогам."),
                      done: [tr("One settings page", "Одна страница настроек"), tr("Dark theme, chart tooltips", "Тёмная тема, подсказки на графиках"),
                             tr("The demo video rebuilt to be clearer", "Демо-видео пересобрано понятнее")],
                      sec: 14 * Self.h + 10 * 60, cost: 94),
                .init(project: "ml-train", title: "run 300",
                      done: [tr("Training on the GPU box", "Обучение на gpu-box"),
                             tr("Quality compared with the previous version", "Качество сравнено с прошлой версией")],
                      sec: 7.5 * Self.h, cost: 63),
            ])
    }

    public func summary(_ key: String) -> KeptSummary? {
        switch key {
        case "2026-10-29": return KeptSummary(doc: dayDoc, engine: "claude", at: at(29, 23 + 59 / 60))
        case "2026-10-26..2026-11-01":
            var doc = dayDoc
            doc.from = "2026-10-26"; doc.to = "2026-11-01"
            doc.overview = tr("The week went to the payment webhook and the new settings page; the model run 300 is trained.",
                              "Неделя ушла на вебхук оплаты и новую страницу настроек; модель run 300 обучена.")
            doc.main = [tr("PROJ-12: the double charge is fixed", "PROJ-12: двойное списание исправлено"),
                        tr("Settings page released on dev", "Страница настроек выкачена на дев")]
            return KeptSummary(doc: doc, engine: "claude", at: at(30, 9))
        default: return nil
        }
    }

    // MARK: week

    public func week(containing day: Date) -> WeekData {
        let start = cal.dateInterval(of: .weekOfYear, for: day)!.start
        let projects = ["api-server", "web-app", "ml-train", "docs-site", ""]
        guard start == at(26, 0) else {
            let days = (0..<7).map { i -> [Totals] in
                let h = hoursOn(cal.date(byAdding: .day, value: i, to: start)!)
                return h.map { [roughTotals($0)] } ?? []
            }
            return WeekData(start: start, projects: [""], days: days,
                            totals: Totals(sessionSec: 0, tokens: 0, cost: 0), previous: Totals(sessionSec: 0, tokens: 0, cost: 0),
                            projectRows: [], limitByDay: Array(repeating: nil, count: 7))
        }
        let hours: [[Double]] = [[2.4, 0, 2.8, 0, 1.0], [3.6, 1.8, 2.5, 0, 1.2], [2.9, 2.6, 1.9, 0, 1.0],
                                 [3.1, 2.7, 1.6, 1.4, 0.9], [0.6, 2.1, 0, 0, 0.7], [], []]
        let cur = Totals(sessionSec: 36 * Self.h + 50 * 60, userSec: 9 * Self.h + 10 * 60, tokens: 118_000_000, cost: 1600)
        let prev = Totals(sessionSec: cur.sessionSec / 1.12, userSec: cur.userSec / 1.04, tokens: Int(Double(cur.tokens) / 1.21),
                          cost: cur.cost / 1.19)
        func row(_ name: String, _ h: Double, _ m: Double, _ cost: Double, _ ratio: Double?) -> ProjectWeek {
            let sec = h * Self.h + m * 60
            return ProjectWeek(name, sec: sec, cost: cost, prevSec: ratio.map { sec / $0 })
        }
        return WeekData(
            start: start, projects: projects,
            days: hours.map { $0.map { Totals(sessionSec: $0 * Self.h, tokens: Int($0 * 3_200_000), cost: $0 * 43) } },
            totals: cur, previous: prev,
            projectRows: [row("api-server", 12, 36, 520, 1.18), row("web-app", 9, 12, 470, nil),
                          row("ml-train", 8, 48, 310, 0.78), row("docs-site", 1, 24, 160, nil), row("", 4, 48, 140, 0.95)],
            limitByDay: [7, 15, 24, 37, 41, nil, nil])
    }

    // MARK: calendar

    public func month(containing day: Date) -> MonthData {
        let start = cal.dateInterval(of: .month, for: day)!.start
        let n = cal.range(of: .day, in: .month, for: start)!.count
        let hours = (0..<n).map { hoursOn(cal.date(byAdding: .day, value: $0, to: start)!) }
        return MonthData(month: start, hours: hours, archiveSince: at(1, 0))
    }

    public func search(_ text: String) -> [SearchHit] {
        let all = [
            SearchHit(title: tr("web-app — main: demo video, settings, dark theme",
                                "web-app — основная: демо-видео, настройки, тёмная тема"),
                      host: "build-box", start: at(30, 4 + 10 / 60), end: at(30, 7 + 59 / 60), model: "Opus 5.5",
                      command: "ssh build-box -t tmux attach -t web"),
            SearchHit(title: tr("web-app — recording video v1", "web-app — запись видео v1"), host: "build-box",
                      start: at(29, 21 + 40 / 60), end: at(29, 22 + 31 / 60), model: "Opus 5.5", command: "claude --resume 790a5348"),
            SearchHit(title: tr("api-server — PROJ-12 state machine check", "api-server — PROJ-12, проверка стейт-машины"),
                      host: "build-box", start: at(29, 9), end: at(29, 18.5), model: "Opus 5.5",
                      command: "ssh build-box -t tmux attach -t api"),
        ]
        let words = text.lowercased().split(separator: " ").filter { $0.count >= 3 }
        return all.filter { hit in words.contains { hit.title.lowercased().contains($0) } }
    }

    // MARK: tasks

    public func tasks() -> [TaskItem] {
        let web = TaskItem(
            key: "PROJ-21",
            title: tr("Web app: settings page, dark theme, demo video",
                      "Веб-приложение: страница настроек, тёмная тема, демо-видео"),
            description: tr("Users change their settings in one place and can switch to a dark theme. "
                            + "A short demo video for people who see the app for the first time.",
                            "Пользователь меняет настройки в одном месте и может включить тёмную тему. "
                            + "Короткое демо-видео для тех, кто видит приложение впервые."),
            state: .active, jira: JiraInfo(status: tr("In Progress", "В работе"), statusMatches: true, loggedSec: 7.5 * Self.h),
            userSec: 9.5 * Self.h, sessionSec: 14 * Self.h + 20 * 60, tokens: 21_400_000, weekPct: 11,
            todo: [TodoItem(tr("Settings page and form validation", "Страница настроек и проверка формы"), done: true),
                   TodoItem(tr("Dark theme, chart tooltips", "Тёмная тема, подсказки на графиках"), done: true),
                   TodoItem(tr("Sign-in with a link by email", "Вход по ссылке из письма"), done: true),
                   TodoItem(tr("Demo video v3 (RU/EN)", "Демо-видео v3 (RU/EN)"), done: true),
                   TodoItem(tr("Publish the video on the site — waiting for an ok", "Выложить видео на сайт — ждёт ок"), done: false),
                   TodoItem(tr("Decide when to switch off the GPU box", "Решить, когда выключить gpu-box"), done: false)],
            doneByDay: [(at(29, 0), tr("Settings page, form validation, sign-in with a link by email, dark theme, chart tooltips.",
                                       "Страница настроек, проверка формы, вход по ссылке из письма, тёмная тема, подсказки на графиках.")),
                        (at(30, 0), tr("Empty states with a backdrop, video v3 rebuilt to be clearer, page captions, a restart script without hung processes.",
                                       "Пустые состояния с подложкой, видео v3 и пересборка понятнее, подписи страниц, скрипт перезапуска без зависших процессов."))],
            sessions: [TaskSession(tool: .claude, title: tr("web-app — main", "web-app — основная"), host: "build-box",
                                   model: "Opus 5.5", first: at(29, 9), last: at(30, 8), sec: 8 * Self.h + 10 * 60),
                       TaskSession(tool: .claude, title: tr("web-app — worker", "web-app — воркер"), host: "build-box",
                                   model: "Opus 5.5", first: at(29, 13), last: at(30, 6), sec: 5 * Self.h + 40 * 60),
                       TaskSession(tool: .codex, title: tr("web-app — layout check", "web-app — проверка вёрстки"), host: "build-box",
                                   model: "GPT-5", first: at(30, 7), last: at(30, 7.5), sec: 30 * 60)],
            sessionCount: 5,
            notes: [tr("The video goes to the site only after an ok.", "Видео на сайт — только после ок."),
                    tr("The GPU box is paid: decide when to switch it off.", "gpu-box платный — решить, когда выключить.")])
        return [
            web,
            TaskItem(key: "PROJ-12", title: tr("State machine: check on dev", "Стейт-машина: проверка на деве"), state: .review,
                     jira: JiraInfo(status: "Ready on dev", statusMatches: true, loggedSec: 7 * Self.h),
                     userSec: 7 * Self.h + 40 * 60, sessionSec: 12 * Self.h, tokens: 16_000_000, weekPct: 8, sessionCount: 3),
            TaskItem(key: "ZAG-1", title: tr("Zagon: features, mockups, plan", "Zagon: функционал, макеты, план"), state: .active,
                     userSec: 2 * Self.h + 10 * 60, sessionSec: 3 * Self.h, tokens: 4_100_000, weekPct: 2, sessionCount: 1),
            TaskItem(key: "PROJ-14", title: tr("Docs: API reference, getting-started guide", "Документация: справка по API, руководство для начала"),
                     state: .done, jira: JiraInfo(status: tr("Done", "Готово"), statusMatches: true, loggedSec: 3 * Self.h),
                     userSec: 3 * Self.h, sessionSec: 4 * Self.h, tokens: 6_000_000, weekPct: 3, sessionCount: 2),
            TaskItem(key: "ZAG-2", title: tr("Zagon: static Swift spike", "Zagon: спайк статического Swift"), state: .active,
                     userSec: 20 * 60, sessionSec: 1.5 * Self.h, tokens: 2_300_000, weekPct: 1, sessionCount: 1),
            TaskItem(key: "ZAG-3", title: tr("Zagon: menu bar app", "Zagon: приложение в строке меню"), state: .planned, userSec: 0),
            TaskItem(key: "PROJ-16", title: tr("Rate limits: who owns them", "Лимиты запросов: кто их ведёт"),
                     state: .planned, jira: JiraInfo(status: "To Do", statusMatches: true, loggedSec: 0), userSec: 0),
            TaskItem(key: "PROJ-23", title: tr("Web app: load test plan", "Веб-приложение: план нагрузочного теста"), state: .planned,
                     jira: JiraInfo(status: "To Do", statusMatches: true, loggedSec: 0), userSec: 0),
            TaskItem(key: "ZAG-4", title: tr("Zagon: Telegram bot", "Zagon: бот в Telegram"), state: .planned, userSec: 0),
        ]
    }

    // MARK: worklog

    public func worklog(_ day: Date) -> WorklogData {
        let d = cal.startOfDay(for: day)
        guard cal.isDate(d, inSameDayAs: now) else {
            return WorklogData(day: d, workStart: nil, workEnd: nil, userSec: 0, sessionSec: 0, rows: [], splits: [])
        }
        return WorklogData(
            day: d, workStart: at(30, 6), workEnd: at(30, 12.5), userSec: 6.5 * Self.h, sessionSec: 11 * Self.h + 10 * 60,
            rows: [WorklogRow(key: "PROJ-21", start: at(30, 6), end: at(30, 8),
                              text: tr("Reshooting the demo video, a backdrop for empty states.",
                                       "Пересъёмка демо-видео, подложка для пустых состояний."), destination: .alreadyLogged),
                   WorklogRow(key: "PROJ-21", start: at(30, 8), end: at(30, 8.5),
                              text: tr("Page captions, a restart script without hung processes.",
                                       "Подписи страниц, скрипт перезапуска без зависших процессов."), destination: .jira),
                   WorklogRow(key: "PROJ-12", start: at(30, 8.5), end: at(30, 9),
                              text: tr("Answer on rate limits: where they live in the code.",
                                       "Ответ по лимитам запросов: где они в коде."), destination: .jira),
                   WorklogRow(key: "ZAG-1", start: at(30, 9), end: at(30, 12.5),
                              text: tr("Research of alternatives and pain points, features, mockups, plan.",
                                       "Исследование аналогов и болей, функционал, макеты, план."), destination: .zagonOnly)],
            splits: [WorklogSplit(start: at(30, 8), end: at(30, 9),
                                  parts: [("web-app", 1800), (tr("API question", "вопрос по API"), 1800)])])
    }
}
