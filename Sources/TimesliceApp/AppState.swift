import Foundation
import Combine
import TimesliceCore

/// Displayable state derived from the store. Re-runs queries on `dataDidChange`.
@MainActor
final class AppState: ObservableObject {
    private let store: IntervalStore
    let engine: TimerEngine

    /// Exposed for views that perform task CRUD, then call `reload()`.
    var storeForEditing: IntervalStore { store }

    /// Active (non-archived) tasks only — used for selection/navigation.
    @Published var projects: [Project] = []
    /// Groups above tasks (Inbox is implicit — a task with `taskProjectID == nil`).
    @Published var taskProjects: [TaskProject] = []
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
        allProjectsCache = (try? store.listProjects(includeArchived: true)) ?? []
        taskProjects = (try? store.listTaskProjects()) ?? []
        reloadTags()
        recomputeTotals()
        // Keep selection on an existing active task.
        if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = projects.first?.id
        }
    }

    /// Tags a project carries, for display on its header row.
    ///
    /// Cached here rather than queried from the view: a row-level lookup would issue a DB query per
    /// project per render, which is the same trap the metrics legend already documents.
    @Published private(set) var tagsByProject: [Int64: [Tag]] = [:]
    @Published private(set) var allTags: [Tag] = []

    private func reloadTags() {
        allTags = (try? store.listTags()) ?? []
        let byID = Dictionary(uniqueKeysWithValues: allTags.map { ($0.id, $0) })
        var map: [Int64: [Tag]] = [:]
        for group in taskProjects {
            let ids = (try? store.tagIDs(for: .project(group.id))) ?? []
            let tags = ids.compactMap { byID[$0] }
            if !tags.isEmpty { map[group.id] = tags.sorted { $0.sortOrder < $1.sortOrder } }
        }
        tagsByProject = map
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

    /// `todayTotals` in recency order — most recently worked first, finished tasks last.
    ///
    /// Reads the FROZEN switcher order rather than recomputing recency, so this stays a cheap
    /// re-render: `recencyOrderedProjects` queries the DB, and a computed property feeding a list
    /// would do that on every frame. The popover opens a session, so the order is stable while it's
    /// on screen and only re-ranks the next time you open it.
    var recencyOrderedTodayTotals: [ProjectTotal] {
        let rank = Dictionary(uniqueKeysWithValues:
            switcherProjects.enumerated().map { ($1.id, $0) })
        return todayTotals.sorted { a, b in
            if a.project.finished != b.project.finished { return !a.project.finished }
            let ra = rank[a.project.id] ?? Int.max, rb = rank[b.project.id] ?? Int.max
            if ra != rb { return ra < rb }
            return a.project.id < b.project.id
        }
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
        // Also match a task by its PROJECT's name — typing "inference" should surface the tasks
        // in that project, not just tasks literally called that. Built in Core so the phone's
        // search field uses the identical mapping.
        let groupNames = TaskSearch.groupNames(tasks: all, groups: taskProjects)
        return TaskSearch.rank(query: query, projects: all, lastActivity: activity,
                               groupNames: groupNames, limit: limit)
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
    ///
    /// `groupName` comes from a `/project` token in the palette; the group is created if it
    /// doesn't exist yet, so "assign" and "create" are the same action.
    @discardableResult
    func addAndStart(name: String, groupName: String? = nil) -> Int64? {
        // Resolve the group FIRST: reuse-by-name is scoped to a group, so creating the task before
        // knowing its group would match it against Inbox and could reuse the wrong task.
        var groupID: Int64?
        if let groupName, !groupName.isEmpty {
            groupID = try? store.upsertTaskProject(
                name: groupName, colorHex: Palette.color(forIndex: taskProjects.count))
        }
        guard let id = try? store.createProject(name: name,
                                                colorHex: Palette.color(forIndex: projects.count),
                                                inGroup: groupID) else { return nil }
        // No follow-up `setTaskProject` needed: `createProject(inGroup:)` now actually files the
        // task. The old call was compensating for the parameter being ignored.
        reload()
        selectedProjectID = id
        engine.switchTo(projectID: id)
        return id
    }

    // MARK: - Grouping

    /// Colour a task should render in: its group's, or its own when in Inbox.
    ///
    /// This is the whole point of the feature — with 35 tasks the timeline was painting 35
    /// generated hues that started to look alike. Inheriting the group's colour collapses that
    /// to a handful without losing per-task detail (hover still names the task).
    /// The derivation itself lives in `Palette` (Core) so the iOS app and the Live Activity render
    /// the identical colour; this is just the binding to the state it needs. A SHADE of the project
    /// colour, not the flat colour: same hue so the group reads as one family, but distinct enough
    /// that adjacent blocks from two tasks in the same project don't merge into an indistinguishable
    /// band on the timeline.
    func displayColorHex(for task: Project) -> String {
        Palette.displayColorHex(for: task, groups: taskProjects, allTasks: allProjectsCache)
    }

    /// All tasks incl. archived — shades must stay stable even when a sibling is archived, so this
    /// can't just use the visible list. Refreshed in `reload()`.
    ///
    /// Must be @Published: `displayColorHex` reads it, so as a plain `var` a re-assignment
    /// changed colours in the store but never told SwiftUI to redraw.
    @Published private var allProjectsCache: [Project] = []

    func displayColorHex(forTaskID id: Int64) -> String {
        guard let task = projects.first(where: { $0.id == id })
            ?? (try? store.listProjects(includeArchived: true))?.first(where: { $0.id == id })
        else { return "#8E8E93" }
        return displayColorHex(for: task)
    }

    /// Move tasks into a group (creating it by name if needed), or to Inbox with `nil`.
    func assign(taskIDs: [Int64], toGroupNamed name: String?) {
        var groupID: Int64?
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            groupID = try? store.upsertTaskProject(
                name: name, colorHex: Palette.color(forIndex: taskProjects.count))
        }
        for id in taskIDs {
            try? store.setTaskProject(taskID: id, taskProjectID: groupID)
        }
        reload()
        NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)
    }

    /// Move a project up or down in the display order. Also reorders the task list, the
    /// switcher and the palette, since all three read `orderedProjects`.
    func moveTaskProject(id: Int64, by delta: Int) {
        var ids = taskProjects.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        let to = from + delta
        guard to >= 0, to < ids.count else { return }
        ids.swapAt(from, to)
        try? store.setTaskProjectOrder(ids)
        reload()
        NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)
    }

    /// Move `movedID` to where `targetID` currently sits, shifting the rest — the drag-and-drop
    /// equivalent of the old up/down buttons.
    func reorderTaskProject(_ movedID: Int64, toPositionOf targetID: Int64) {
        var ids = taskProjects.map(\.id)
        guard let from = ids.firstIndex(of: movedID),
              let to = ids.firstIndex(of: targetID), from != to else { return }
        ids.remove(at: from)
        ids.insert(movedID, at: to)
        try? store.setTaskProjectOrder(ids)
        reload()
        NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)
    }

    /// Bulk lifecycle actions for every task in a group — the group-level equivalents of the
    /// per-row finish/archive buttons.
    func finishAll(taskIDs: [Int64]) {
        for id in taskIDs {
            engine.clearIfCurrent(projectID: id)
            try? store.setProjectFinished(id: id, finished: true)
        }
        reload()
        NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)
    }

    func archiveAll(taskIDs: [Int64]) {
        for id in taskIDs {
            engine.clearIfCurrent(projectID: id)
            try? store.setProjectArchived(id: id, archived: true)
        }
        reload()
        NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)
    }

    func unfinishAll(taskIDs: [Int64]) {
        for id in taskIDs { try? store.setProjectFinished(id: id, finished: false) }
        reload()
        NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)
    }

    /// Short project label for compact rows (palette, switcher HUD) — nil for Inbox, so
    /// uncategorised tasks add no visual noise. Truncated to keep rows from growing.
    func shortGroupName(forTaskID id: Int64, max: Int = 12) -> String? {
        guard let task = allProjectsCache.first(where: { $0.id == id }),
              let groupID = task.taskProjectID,
              let group = taskProjects.first(where: { $0.id == groupID }) else { return nil }
        let name = group.name
        guard name.count > max else { return name }
        return String(name.prefix(max - 1)) + "…"
    }

    /// Per-group totals for the current scope, Inbox included.
    var visibleGroupTotals: [TaskProjectTotal] {
        Aggregations.rollUp(totals: visibleTotals, taskProjects: taskProjects)
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
        orderedProjects.filter { !$0.finished }
    }

    /// Tasks in the order they're DISPLAYED: grouped by project (in project sort order), Inbox
    /// last, and within each group unfinished before finished.
    ///
    /// Arrow keys, the switcher and the palette all read this. They used to walk raw `projects`
    /// order, so once the list rendered grouped, ↑/↓ jumped around instead of moving to the
    /// visually adjacent row.
    var orderedProjects: [Project] {
        let groupRank: (Int64?) -> Int = { [taskProjects] gid in
            guard let gid else { return Int.max }        // Inbox always last
            return taskProjects.firstIndex { $0.id == gid } ?? Int.max - 1
        }
        return projects.sorted { a, b in
            let ra = groupRank(a.taskProjectID), rb = groupRank(b.taskProjectID)
            if ra != rb { return ra < rb }
            // Finished tasks sink within their group, mirroring the list.
            if a.finished != b.finished { return !a.finished }
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.id < b.id
        }
    }

    /// Today's tracked seconds per task id (live for the running task), for the switcher HUD.
    var todaySecondsByID: [Int64: TimeInterval] {
        var map: [Int64: TimeInterval] = [:]
        for total in todayTotals {
            map[total.project.id] = liveSeconds(base: total.seconds, projectID: total.project.id)
        }
        return map
    }

    // MARK: - Switcher session (recency order)

    /// Task order frozen for the duration of one switcher hold, nil when the switcher is closed.
    ///
    /// Frozen deliberately: recency is recomputed per session, so the row under the cursor can't
    /// shift while you're still cycling. And it's a *session* override rather than a change to
    /// `moveSelection` in general, because ↑/↓ inside the window must keep following the DISPLAYED
    /// (grouped) order — walking a different order there is what made the arrows jump around.
    private var switcherOrder: [Int64]?

    /// Tasks most-recently-worked first — the switcher's order.
    ///
    /// The rules live in `TaskOrdering.recencyOrdered` (Core) because the phone's task list and
    /// Action Button wheel need the identical ordering; see that function for why the current task
    /// is pinned and why untracked tasks form a stable tail.
    var recencyOrderedProjects: [Project] {
        TaskOrdering.recencyOrdered(
            display: selectableProjects,
            lastActivity: (try? store.lastActivityByProject()) ?? [:],
            current: engine.runningProjectID ?? engine.currentProjectID)
    }

    /// Freeze the switcher's order and return it, so the HUD and the cycling agree.
    func beginSwitcherSession() -> [Project] {
        let ordered = recencyOrderedProjects
        switcherOrder = ordered.map(\.id)
        return ordered
    }

    /// The frozen order (for redrawing the HUD mid-cycle), or plain recency if no session is open.
    var switcherProjects: [Project] {
        guard let ids = switcherOrder else { return recencyOrderedProjects }
        let byID = Dictionary(uniqueKeysWithValues: selectableProjects.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    func endSwitcherSession() { switcherOrder = nil }

    func moveSelection(by delta: Int) {
        // A switcher hold cycles the frozen recency order; everything else (↑/↓ in the list)
        // walks the displayed order.
        let ids = switcherOrder ?? selectableProjects.map(\.id)
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
