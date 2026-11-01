import SwiftUI
import ZagonUIModel

/// Tasks and the worklog plan come from the `zagon` of the chosen source (this Mac or a checked server), off the main
/// thread; each screen keeps what it got until reloaded.
extension AppState {
    var taskSources: [TaskBackend.Source] { (hasLocalCLI ? [.local] : []) + remoteHosts.map { .server($0) } }

    /// The chosen source while it is still there; else the first checked server (it owns the tasks), else this Mac.
    var currentTaskSource: TaskBackend.Source? {
        let all = taskSources
        if let s = taskSource, all.contains(s) { return s }
        return all.first { $0 != .local } ?? all.first
    }

    var tasksNow: TaskCache { currentTaskSource.flatMap { taskCache[$0] } ?? TaskCache() }

    func sourceName(_ s: TaskBackend.Source) -> String {
        if case .server(let h) = s { return h }
        return f.t("source.local")
    }

    enum TaskLoad { case list, card(String), plan(String), drafts, reconcile(String, String) }

    /// The issue type a new task gets in Jira project `project` of the current source (nil: not known).
    func jiraType(_ project: String) async -> String? {
        guard let s = currentTaskSource, let b = taskBackend?(s) else { return nil }
        return await Task.detached { try? b.jiraType(project) }.value
    }

    /// Loads what is not there yet (or again, with `force`).
    func loadTasks(_ what: TaskLoad, force: Bool = false) {
        guard let s = currentTaskSource else { return }
        let have = taskCache[s] ?? TaskCache(), provider = provider as? StoreDataProvider
        switch what {
        case .list:
            guard force || have.list == nil else { return }
            work(s, { try $0.list().map(TaskBackend.item) }) { $0.list = $1 }
        case .card(let key):
            guard force || have.cards[key] == nil else { return }
            let zone = self.zone
            work(s, { b -> TaskItem in
                let c = try b.card(key)
                return TaskBackend.item(c, sessions: provider?.taskSessions(c.sessions, source: s) ?? [], zone: zone)
            }) { $0.cards[key] = $1 }
        case .plan(let day):
            guard force || have.plans[day] == nil else { return }
            let comments = planComments(s, day), epoch = planEpoch
            work(s, { try $0.plan(day, comments: comments) }) { self.store(&$0, s, day, $1, epoch) { self.editPlan(day) { _ in } } }
        case .reconcile(let from, let to):
            let key = reconcileKey(from, to)
            guard force || have.reconciles[key] == nil else { return }
            // Keeps the last commit's outcome: the period reloads right after a write to show it.
            work(s, keepMessage: true, { try $0.reconcile(from: from, to: to) }) { $0.reconciles[key] = $1 }
        case .drafts:
            guard force || have.drafts == nil else { return }
            // With them, whether the source has the AI engine suggestions are made with.
            let now = self.provider.now, zone = self.zone
            work(s, { b in (try b.suggestions(), b.missingEngine(now: now, zone: zone)) }) {
                $0.drafts = $1.0.drafts; $0.jira = $1.0.jira; $0.draftNote = nil; $0.noCli = $1.1
            }
        }
    }

    /// A period's reconciliation is kept per day it was made on: tomorrow "counted to today" moves on.
    func reconcileKey(_ from: String, _ to: String) -> String { from + "|" + to + "|" + TaskBackend.day(f.now, zone) }

    /// The day's plan read again and stored, then handed to `done` with its source; a failed read only sets the
    /// source's error line.
    func reloadPlan(_ day: String, done: @escaping (TaskBackend.Source, WorklogPlan) -> Void) {
        guard let s = currentTaskSource else { return }
        let comments = planComments(s, day), epoch = planEpoch
        work(s, { try $0.plan(day, comments: comments) }) { cache, plan in
            guard self.store(&cache, s, day, plan, epoch, retry: { self.reloadPlan(day, done: done) }) else { return }
            DispatchQueue.main.async { done(s, plan) }
        }
    }

    /// Accepts or drops suggestion `id` through `act` (the CLI's answer line), then the suggestions and the list again.
    /// The answer, or the failure, goes under the suggestions; `done` gets the failure (nil: it worked).
    func decideDraft(_ id: String, done: @escaping (String?) -> Void = { _ in }, _ act: @escaping (TaskBackend) throws -> String) {
        guard let s = currentTaskSource else { return }
        work(s, { b in
            // A reload that fails keeps what is shown, less the answered suggestion.
            (Result<String, Error> { try act(b) }, try? b.suggestions(), try? b.list().map(TaskBackend.item))
        }) { cache, v in
            switch v.0 {
            case .success(let line):
                cache.draftNote = line
                cache.drafts?.removeAll { $0.id == id }
                done(nil)
            case .failure(let e):
                let why = Remote.scrubHomes(String(describing: e))
                cache.draftNote = why
                done(why)
            }
            if let d = v.1 { cache.drafts = d.drafts; cache.jira = d.jira }
            if let list = v.2 { cache.list = list }
        }
    }

    /// An edit through the CLI, then the card again (and the list, when the status changed); `done` only if it worked.
    // ponytail: answers apply in the order they come back, so a slow reload may briefly show a card from before an
    // edit; a per-card counter if that bites.
    func editTask(_ key: String, relist: Bool = false, done: @escaping () -> Void = {},
                  _ edit: @escaping (TaskBackend) throws -> Void) {
        guard let s = currentTaskSource else { return }
        let provider = provider as? StoreDataProvider, zone = self.zone
        work(s, { b -> (TaskItem, [TaskItem]?) in
            try edit(b)
            let c = try b.card(key, scan: false)
            return (TaskBackend.item(c, sessions: provider?.taskSessions(c.sessions, source: s) ?? [], zone: zone),
                    try relist ? b.list().map(TaskBackend.item) : nil)
        }) { cache, v in
            cache.cards[key] = v.0
            if let list = v.1 { cache.list = list }
            done()
        }
    }

    /// Writes the plan shown for `day` to Jira (after the confirmation on screen); a plan that changed meanwhile is
    /// shown instead and nothing is written. `then` runs after the answer (the period reloads its reconciliation).
    func commitPlan(_ day: String, then: @escaping () -> Void = {}) {
        guard let s = currentTaskSource, let shown = taskCache[s]?.plans[day] else { return }
        let f = self.f
        // Its failures go next to the button, not to the source's line.
        work(s, { b -> (Result<TaskBackend.Commit, Error>, WorklogPlan?) in
            let r = Result { try b.commit(day, shown: shown) }
            if case .success(.written) = r { return (r, try? b.plan(day, comments: shown.comments)) }
            return (r, nil)
        }) { cache, v in
            switch v.0 {
            case .success(.written(let logged, let failed, let problems)):
                cache.message = ([f.t("worklog.written", String(logged)) + (failed > 0 ? " " + f.t("worklog.notWritten", String(failed)) : "")]
                                 + problems).joined(separator: "\n")
            case .success(.changed(let fresh)): cache.plans[day] = fresh; cache.message = f.t("worklog.changed")
            case .success(.nothing): cache.message = f.t("worklog.nothing")
            case .failure(let e): cache.message = f.t("worklog.commitFailed", Remote.scrubHomes(String(describing: e)))
            }
            if let after = v.1 { cache.plans[day] = after }
            // After `work` has stored this cache: a load started from here bumps its own counter.
            DispatchQueue.main.async(execute: then)
        }
    }

    // MARK: what to log: texts, rebuilds, exclusions

    /// The worklog zone of the current source: its plans', else its `[worklog] tz`, else the app's.
    var worklogZone: TimeZone {
        guard let s = currentTaskSource else { return zone }
        let id = taskCache[s]?.plans.values.lazy.compactMap(\.zone).first ?? worklogConfig[s].flatMap { $0?.tz ?? $0?.machineTz }
        return id.flatMap(TimeZone.init(identifier:)) ?? zone
    }

    func planKey(_ s: TaskBackend.Source, _ day: String) -> String { s.saved + "|" + day }
    /// Tasks whose day summary goes to Jira as a comment: every plan of that day is asked with them (its digest counts them).
    func planComments(_ s: TaskBackend.Source, _ day: String) -> [String] { (summaryComments[planKey(s, day)] ?? []).sorted() }

    /// "What to log" opened on `day`: its plan, then a rebuild when sessions worked after its summary (Settings →
    /// Worklogs; once per summary).
    func openPlan(_ day: String) {
        guard let s = currentTaskSource else { return }
        if let p = taskCache[s]?.plans[day] { rebuildIfStale(s, day, p); return }
        let comments = planComments(s, day), epoch = planEpoch
        work(s, { try $0.plan(day, comments: comments) }) { cache, plan in
            guard self.store(&cache, s, day, plan, epoch, retry: { self.openPlan(day) }) else { return }
            // After `work` has stored this cache: a rebuild bumps its own counter.
            DispatchQueue.main.async { self.rebuildIfStale(s, day, plan) }
        }
    }

    /// Keeps a plan unless it was asked before a `[worklog]` write or with another comment choice than the one now:
    /// then `retry` asks again (the same source still shown). false: dropped.
    @discardableResult
    private func store(_ cache: inout TaskCache, _ s: TaskBackend.Source, _ day: String, _ plan: WorklogPlan, _ epoch: Int,
                       retry: @escaping () -> Void) -> Bool {
        guard epoch == planEpoch, plan.comments == planComments(s, day) else {
            if s == currentTaskSource { DispatchQueue.main.async(execute: retry) }
            return false
        }
        cache.plans[day] = plan
        return true
    }

    /// One rebuild at a time per source, and only by `staleOnOpen` (today or yesterday, once per summary).
    private func rebuildIfStale(_ s: TaskBackend.Source, _ day: String, _ p: WorklogPlan) {
        let now = provider.now, zone = worklogZone
        guard rebuildOnOpen, s == currentTaskSource, !planRebuilding.contains(where: { $0.hasPrefix(s.saved + "|") }),
              p.staleOnOpen(day: day, today: TaskBackend.day(now, zone), yesterday: TaskBackend.day(now.addingTimeInterval(-86400), zone),
                            now: now),
              rebuildTried.insert(planKey(s, day) + "|" + String(p.summaryBuiltAt ?? 0)).inserted else { return }
        rebuildPlan(day)
    }

    /// `log plan --refresh`: the day summary and the texts made anew (AI calls, minutes); hand-typed texts stay.
    func rebuildPlan(_ day: String) {
        guard let s = currentTaskSource, taskBackend != nil else { return }
        let k = planKey(s, day), comments = planComments(s, day), f = self.f, epoch = planEpoch
        guard planRebuilding.insert(k).inserted else { return }
        work(s, { b in Result { try b.plan(day, refresh: true, comments: comments) } }) { cache, r in
            self.planRebuilding.remove(k)
            switch r {
            case .success(let plan): self.store(&cache, s, day, plan, epoch) { self.editPlan(day) { _ in } }
            case .failure(let e): cache.message = f.t("worklog.rebuildFailed", Remote.scrubHomes(String(describing: e)))
            }
        }
    }

    /// A change through the CLI (a text, an exclusion), then the day's plan again without a scan; `done` gets whether
    /// it worked (a failure is the source's grey line). `others`: the other days' plans changed too and load anew.
    func editPlan(_ day: String, others: Bool = false, done: @escaping (Bool) -> Void = { _ in },
                  _ edit: @escaping (TaskBackend) throws -> Void) {
        guard let s = currentTaskSource else { return }
        let comments = planComments(s, day), epoch = planEpoch
        work(s, { b in
            Result { () throws -> WorklogPlan in
                try edit(b)
                return try b.plan(day, scan: false, comments: comments)
            }
        }) { cache, r in
            switch r {
            case .success(let plan):
                if others { cache.plans = [:]; cache.reconciles = [:] }
                self.store(&cache, s, day, plan, epoch) { self.editPlan(day) { _ in } }
                done(true)
            case .failure(let e):
                cache.error = Remote.scrubHomes(String(describing: e))
                done(false)
            }
        }
    }

    /// The task's day summary in its worklog or as a separate comment on the task; the plan is asked again with it.
    func setSummaryComment(_ day: String, task: String, _ on: Bool) {
        guard let s = currentTaskSource else { return }
        let k = planKey(s, day)
        if on { summaryComments[k, default: []].insert(task) } else { summaryComments[k]?.remove(task) }
        editPlan(day) { _ in }
    }

    /// `[worklog]` of the current source (Settings → Worklogs); a failure is a line under the card.
    func loadWorklogConfig() {
        guard let s = currentTaskSource, let b = taskBackend?(s) else { return }
        let name = sourceName(s), f = self.f
        Task.detached {
            let r = Result { try b.worklogConfig() }
            await MainActor.run {
                switch r {
                case .success(let c): self.worklogConfig[s] = .some(c)
                case .failure(let e): self.worklogConfigMessage = f.t("source.failed", name, Remote.scrubHomes(String(describing: e)))
                }
            }
        }
    }

    /// One `[worklog]` key on this Mac and every checked server (`log config`), shown at once through `change`; the
    /// plans are cut by these keys, so they load anew.
    func setWorklog(_ key: String, _ value: String, _ change: (inout TaskBackend.WorklogConfig) -> Void) {
        guard let make = taskBackend else { return }
        for (s, c) in worklogConfig { if var c { change(&c); worklogConfig[s] = c } }
        writeWorklog(taskSources.map { (sourceName($0), make($0)) }, all: true) { try $0.setWorklogConfig(key, value) }
    }

    /// One project key added to or removed from each machine's own list.
    func editProjects(add: String? = nil, remove: String? = nil) {
        guard let make = taskBackend else { return }
        for (s, c) in worklogConfig { if var c { c.projects = TaskBackend.edited(c.projects ?? [], add: add, remove: remove); worklogConfig[s] = c } }
        writeWorklog(taskSources.map { (sourceName($0), make($0)) }, all: true) { try $0.editProjects(add: add, remove: remove) }
    }

    /// Lets an excluded project, task or session back into the plans of the current source.
    func removeExclusion(_ e: TaskBackend.WorklogConfig.Exclusion) {
        guard let s = currentTaskSource, let b = taskBackend?(s) else { return }
        if var c = worklogConfig[s] ?? nil { c.exclude?.removeAll { $0 == e }; worklogConfig[s] = c }
        writeWorklog([(sourceName(s), b)]) { try $0.exclude(e.kind, e.name, add: false) }
    }

    /// Runs `write` on each backend after the writes before it; what failed goes under the card until the card opens
    /// again or a write to every source (`all`) works, then the current source's `[worklog]` is read again.
    private func writeWorklog(_ backends: [(String, TaskBackend)], all: Bool = false,
                              _ write: @escaping @Sendable (TaskBackend) throws -> Void) {
        let f = self.f, before = worklogWrite
        worklogWrite = Task.detached {
            await before?.value
            var failed: [String] = []
            for (name, b) in backends {
                do { try write(b) } catch { failed.append(f.t("settings.wl.notSaved", name, Remote.scrubHomes(String(describing: error)))) }
            }
            await MainActor.run {
                if !failed.isEmpty { self.worklogConfigMessage = failed.joined(separator: "\n") } else if all { self.worklogConfigMessage = nil }
                for s in self.taskCache.keys { self.taskCache[s]?.plans = [:]; self.taskCache[s]?.reconciles = [:] }
                self.planEpoch += 1
                self.loadWorklogConfig()
            }
        }
    }

    /// Runs `job` off the main thread; its result, or a grey error line, lands in the source's cache.
    private func work<T>(_ s: TaskBackend.Source, keepMessage: Bool = false, _ job: @escaping (TaskBackend) throws -> T,
                         then apply: @escaping (inout TaskCache, T) -> Void) {
        guard let backend = taskBackend?(s) else { return }
        taskCache[s, default: TaskCache()].loading += 1
        if !keepMessage { taskCache[s]?.message = nil }
        Task.detached {
            let r = Result { try job(backend) }
            await MainActor.run {
                var c = self.taskCache[s] ?? TaskCache()
                c.loading -= 1
                switch r {
                case .success(let v):
                    c.error = nil
                    apply(&c, v)
                case .failure(let e):
                    c.error = Remote.scrubHomes(String(describing: e))
                    Log.shared.write("tasks from \(s.saved.isEmpty ? "this Mac" : s.saved): \(c.error ?? "")")
                }
                self.taskCache[s] = c
            }
        }
    }

    /// Everything the task screens show, right away (snapshots).
    func loadTasksNow(day: String) {
        guard let s = currentTaskSource, let b = taskBackend?(s) else { return }
        let provider = provider as? StoreDataProvider
        var c = TaskCache()
        c.list = (try? b.list())?.map(TaskBackend.item)
        for t in c.list ?? [] {
            if let card = try? b.card(t.key) {
                c.cards[t.key] = TaskBackend.item(card, sessions: provider?.taskSessions(card.sessions, source: s) ?? [], zone: zone)
            }
        }
        c.plans[day] = try? b.plan(day)
        c.drafts = (try? b.drafts()) ?? []
        taskCache[s] = c
    }
}

/// The source switcher on top of the task screens, with the reload button and a grey line when the source failed.
struct SourceBar: View {
    @EnvironmentObject private var app: AppState
    let reload: () -> Void

    var body: some View {
        let f = app.f
        if app.taskBackend != nil, let current = app.currentTaskSource {
            let c = app.tasksNow
            VStack(alignment: .leading, spacing: 6) {
                Flow(spacing: 6) {
                    ForEach(app.taskSources, id: \.self) { s in
                        Chip(title: app.sourceName(s), selected: s == current, height: 26) { app.taskSource = s }
                    }
                    Button(action: reload) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(Z.secondary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(f.t("source.reload"))
                    if c.loading > 0 {
                        Text(f.t("source.loading")).font(.system(size: 12)).foregroundColor(Z.muted).frame(height: 26)
                    }
                }
                if let e = c.error {
                    Text(f.t("source.failed", app.sourceName(current), e)).font(.system(size: 12)).foregroundColor(Z.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
