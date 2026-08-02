import Foundation
import Combine
import TimesliceCore

enum TimeScope: String, CaseIterable, Identifiable {
    case today = "Today"
    case allTime = "All Time"
    var id: String { rawValue }
}

/// Displayable state derived from the store. Re-runs queries on `dataDidChange`.
@MainActor
final class AppState: ObservableObject {
    private let store: IntervalStore
    let engine: TimerEngine

    /// Exposed for views that perform task CRUD, then call `reload()`.
    var storeForEditing: IntervalStore { store }

    /// Active (non-archived) tasks only — used for selection/navigation.
    @Published var projects: [Project] = []
    /// Active-task totals for the Today and All-Time scopes.
    @Published var todayTotals: [ProjectTotal] = []
    @Published var allTimeTotals: [ProjectTotal] = []
    /// Archived (finished) tasks with their all-time totals.
    @Published var archivedTotals: [ProjectTotal] = []
    @Published var scope: TimeScope = .today
    @Published var selectedProjectID: Int64?

    private var cancellables: Set<AnyCancellable> = []

    init(store: IntervalStore, engine: TimerEngine) {
        self.store = store
        self.engine = engine

        // Reload synchronously — the notification is posted on the main thread (engine is
        // @MainActor), and an async hop here leaves a stale window where totals lag the timer
        // (e.g. pausing briefly shows the pre-session total).
        NotificationCenter.default.publisher(for: TimesliceNotifications.dataDidChange)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    /// The active-task totals to display for the current scope.
    var visibleTotals: [ProjectTotal] {
        scope == .today ? todayTotals : allTimeTotals
    }

    func reload() {
        projects = (try? store.listProjects(includeArchived: false)) ?? []
        recomputeTotals()
        // Keep selection on an existing active task.
        if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = projects.first?.id
        }
    }

    private func recomputeTotals() {
        let now = Date()
        // Totals are computed over CLOSED intervals only. The currently-running task's live
        // time is added on top via `liveSeconds(base:projectID:)` in the view, so the running
        // row can tick at display framerate without re-querying the DB every frame.
        let closed = ((try? store.intervals()) ?? []).filter { !$0.isRunning }
        let active = projects
        let archived = (try? store.listProjects(includeArchived: true))?.filter { $0.archived } ?? []
        // Unfinished tasks first (in sort order); finished tasks sink to the end of the list.
        let byFinished: (ProjectTotal, ProjectTotal) -> Bool = { a, b in
            if a.project.finished != b.project.finished { return !a.project.finished }
            return a.project.sortOrder < b.project.sortOrder
        }
        allTimeTotals = Aggregations.allTimeTotals(projects: active, intervals: closed, now: now).sorted(by: byFinished)
        // Today shows unfinished tasks plus anything finished *today* (struck through) — so a task
        // you completed yesterday clears out of Today but stays in All Time.
        let todayVisible = active.filter { $0.showsInToday(now: now) }
        todayTotals = Aggregations.todayTotals(projects: todayVisible, intervals: closed, now: now).sorted(by: byFinished)
        archivedTotals = Aggregations.allTimeTotals(projects: archived, intervals: closed, now: now)
    }

    /// Live displayed seconds for a total row: the committed (closed) base plus the running
    /// task's elapsed if this row is the one currently timing.
    func liveSeconds(base: TimeInterval, projectID: Int64) -> TimeInterval {
        guard engine.runningProjectID == projectID else { return base }
        return base + engine.elapsed
    }

    // MARK: - Task lifecycle
    //
    // Three independent states:
    //  • finished — done, but STILL counts in Today/All-Time; renders struck-through at the end
    //    of the active list (like Apple's completed reminders). Toggle back with `unfinish`.
    //  • archived — removed from Today/All-Time entirely; lives in the Archived section.
    //  • running — the live timer (handled by TimerEngine).

    /// Mark a task finished: stop its timer and clear it as current. Stays visible + counted, struck.
    func finish(projectID: Int64) {
        engine.clearIfCurrent(projectID: projectID)
        try? store.setProjectFinished(id: projectID, finished: true)
        reload()
    }

    /// Un-finish (resume) a task back to an active, un-struck state.
    func unfinish(projectID: Int64) {
        try? store.setProjectFinished(id: projectID, finished: false)
        reload()
    }

    /// Archive: remove from Today/All-Time into the Archived section. Stops its timer if running.
    func archive(projectID: Int64) {
        engine.clearIfCurrent(projectID: projectID)
        try? store.setProjectArchived(id: projectID, archived: true)
        reload()
    }

    /// Unarchive: bring an archived task back to the active list.
    func unarchive(projectID: Int64) {
        try? store.setProjectArchived(id: projectID, archived: false)
        reload()
    }

    /// Palette rows for `query` — active and finished tasks ranked for resuming. Archived ones
    /// are excluded: archiving is how you get a task *out* of the way, so resurfacing it in the
    /// quick-switch palette defeats the point.
    /// The palette's list scrolls, so the cap only exists to keep ranking cheap — 8 was tight
    /// enough that finished tasks fell off the end for anyone with a handful of active ones.
    func searchTasks(_ query: String, limit: Int = 40) -> [TaskMatch] {
        let all = (try? store.listProjects(includeArchived: false)) ?? []
        let activity = (try? store.lastActivityByProject()) ?? [:]
        return TaskSearch.rank(query: query, projects: all, lastActivity: activity, limit: limit)
    }

    /// Time shown on a palette row: today's tracked seconds (live for the running task), falling
    /// back to the all-time total so tasks you last touched on an earlier day still show a number
    /// instead of a bare 0:00.
    func todaySeconds(for projectID: Int64) -> TimeInterval {
        let today = liveSeconds(
            base: todayTotals.first { $0.project.id == projectID }?.seconds ?? 0,
            projectID: projectID
        )
        if today > 0 { return today }
        // Fall back to the all-time total from the store — allTimeTotals only covers active
        // tasks, and the palette also lists finished/archived ones.
        let intervals = (try? store.intervals())?.filter { $0.projectID == projectID } ?? []
        return intervals.reduce(0) { $0 + $1.seconds() }
    }

    /// Resume an existing task from the palette: clear finished/archived as needed, then start it.
    /// This is what makes "mark done now, pick it back up later" frictionless — no duplicates.
    func resumeAndStart(projectID: Int64) {
        if let p = (try? store.listProjects(includeArchived: true))?.first(where: { $0.id == projectID }) {
            if p.archived { try? store.setProjectArchived(id: projectID, archived: false) }
            if p.finished { try? store.setProjectFinished(id: projectID, finished: false) }
        }
        reload()
        selectedProjectID = projectID
        engine.switchTo(projectID: projectID)
    }

    /// Create a new task and immediately start timing it. Returns the new task id.
    @discardableResult
    func addAndStart(name: String) -> Int64? {
        guard let id = try? store.createProject(name: name, colorHex: Palette.color(forIndex: projects.count)) else { return nil }
        reload()
        selectedProjectID = id
        engine.switchTo(projectID: id)
        return id
    }

    /// Reset a task's tracked time to zero (keeps the task). Stops its timer if running.
    func reset(projectID: Int64) {
        engine.clearIfCurrent(projectID: projectID)
        try? store.resetProjectIntervals(id: projectID)
        reload()
    }

    /// Permanently delete a task and all its time.
    func delete(projectID: Int64) {
        engine.clearIfCurrent(projectID: projectID)
        try? store.deleteProject(id: projectID)
        reload()
    }

    // MARK: - Selection movement (for ↑/↓ and the global switcher)

    /// Active, not-yet-finished tasks — the ones you can cycle to and start timing.
    var selectableProjects: [Project] {
        projects.filter { !$0.finished }
    }

    /// Today's tracked seconds per task id (live for the running task), for the switcher HUD.
    var todaySecondsByID: [Int64: TimeInterval] {
        var map: [Int64: TimeInterval] = [:]
        for total in todayTotals {
            map[total.project.id] = liveSeconds(base: total.seconds, projectID: total.project.id)
        }
        return map
    }

    func moveSelection(by delta: Int) {
        let ids = selectableProjects.map(\.id)
        guard !ids.isEmpty else { return }
        let currentIndex = selectedProjectID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = (currentIndex + delta + ids.count) % ids.count
        selectedProjectID = ids[next]
    }

    func toggleSelected() {
        guard let id = selectedProjectID else { return }
        engine.toggle(projectID: id)
    }
}
