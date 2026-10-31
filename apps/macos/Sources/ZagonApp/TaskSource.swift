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
            work(s, { try $0.plan(day) }) { $0.plans[day] = $1 }
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
        work(s, { try $0.plan(day) }) { cache, plan in
            cache.plans[day] = plan
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
            if case .success(.written) = r { return (r, try? b.plan(day)) }
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
