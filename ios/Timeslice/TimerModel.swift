import Foundation
import SwiftUI
import TimesliceCore

/// The iOS app's single source of truth: wraps `IntervalStore` and keeps the Live Activity in step.
///
/// A singleton because the Action Button's App Intent runs in this same process and must mutate the
/// *same* store the UI is showing — two `IntervalStore` instances on one sqlite file would let the
/// UI display state the intent had already changed.
///
/// Deliberately thin. Every aggregation, ranking, budget calculation and colour derivation is called
/// out of `TimesliceCore` and shared verbatim with the Mac app. Nothing here recomputes any of it:
/// that's the only thing keeping the two platforms from silently disagreeing.
@MainActor
final class TimerModel: ObservableObject {
    static let shared = TimerModel()

    // MARK: - Published state

    /// Active (non-archived) tasks in display order.
    @Published private(set) var tasks: [Project] = []
    /// Groups above tasks. Inbox is implicit — a task with `taskProjectID == nil`.
    @Published private(set) var groups: [TaskProject] = []
    /// Archived tasks, for the Archived section.
    @Published private(set) var archivedTasks: [Project] = []
    /// Today's seconds from **CLOSED intervals only** — the committed base, matching the Mac's
    /// `AppState.recomputeTotals`. The running task's live time is added on top at display time, so
    /// a row can tick without re-querying, and so this value never goes stale.
    ///
    /// Including the open interval here (as this once did) is a trap: it bakes a snapshot of
    /// "elapsed as of the last reload" into the total, which then neither ticks nor matches the Mac.
    @Published private(set) var committedTodaySeconds: [Int64: TimeInterval] = [:]
    /// All-time seconds per task, also from closed intervals only.
    @Published private(set) var committedAllTimeSeconds: [Int64: TimeInterval] = [:]
    @Published private(set) var running: RunningInterval?
    /// The current task even while paused — what the Action Button toggles.
    @Published private(set) var currentTaskID: Int64?
    /// When the current task was paused; nil unless paused. Drives the "still paused?" nudge, the
    /// mirror of the long-session checkpoint. Same role as the Mac's `TimerEngine.pausedSince`.
    @Published private(set) var pausedSince: Date?
    @Published private(set) var loadError: String?
    /// Set by `OpenSwitcherIntent` so the root view can present the wheel. A published flag rather
    /// than the intent presenting anything itself: an AppIntent has no view hierarchy to present in.
    @Published var showingSwitcher = false
    @Published var showingSettings = false

    /// Shared with the Mac via Core, so the deep-block and nudge thresholds mean the same thing on
    /// both. The phone used to hardcode its own copies.
    let settings = AppSettings()

    /// Devices that have written into this database, for the Settings list and the timeline lanes.
    struct DeviceInfo: Identifiable { let id: String; let label: String }
    @Published private(set) var knownDevices: [DeviceInfo] = []
    /// device_id -> human label, for the day timeline's lane titles.
    @Published private(set) var deviceLabels: [String: String] = [:]

    var deviceID: String { store?.localDeviceID ?? TimeslicePaths.deviceID() }
    var deviceLabel: String {
        let id = deviceID
        return deviceLabels[id] ?? id
    }
    /// Tags per group, for the row chips. Cached rather than queried per row — a per-render DB query
    /// is the trap the Mac's metrics legend already documents.
    @Published private(set) var tagsByGroup: [Int64: [Tag]] = [:]
    @Published private(set) var allTags: [Tag] = []

    /// Last activity per task, for recency ordering and search ranking.
    private(set) var lastActivity: [Int64: Date] = [:]
    /// Includes archived tasks, because shades are positional: hiding an archived sibling would
    /// renumber the ones after it and silently recolour them.
    private(set) var allTasks: [Project] = []

    private var store: IntervalStore?

    private init() {}

    /// Exposed for screens that need to query Core directly (metrics, budgets) rather than have this
    /// class proxy every call.
    var storeIfLoaded: IntervalStore? { store }

    var isRunning: Bool { running != nil }

    func task(id: Int64) -> Project? { allTasks.first { $0.id == id } }
    func group(id: Int64?) -> TaskProject? { id.flatMap { gid in groups.first { $0.id == gid } } }

    /// Colour a task renders in, derived by the SAME Core function the Mac uses.
    func colorHex(for task: Project) -> String {
        Palette.displayColorHex(for: task, groups: groups, allTasks: allTasks)
    }

    // MARK: - Derived orderings (all from Core)

    /// Tasks most-recently-worked first. `TaskOrdering` is shared with the Mac's switcher.
    var recencyOrdered: [Project] {
        TaskOrdering.recencyOrdered(display: tasks, lastActivity: lastActivity, current: currentTaskID)
    }

    /// Fuzzy search results using the Mac's exact ranking, including `/project` filing tokens and
    /// matching on a task's project name at half weight.
    func searchResults(_ query: String, limit: Int = 50) -> [TaskMatch] {
        let parsed = TaskSearch.parse(query)
        var candidates = tasks
        // A `/token` narrows to a group, same as the Mac's palette.
        if let token = parsed.groupToken, !token.isEmpty {
            let matched = Set(TaskSearch.rankGroups(token: token, groups: groups).map(\.id))
            candidates = candidates.filter { $0.taskProjectID.map(matched.contains) ?? false }
        }
        return TaskSearch.rank(query: parsed.name, projects: candidates,
                               lastActivity: lastActivity, groupNames: groupNamesByTask,
                               limit: limit)
    }

    /// Group name per task id — shared with the Mac's palette via `TaskSearch.groupNames`.
    private var groupNamesByTask: [Int64: String] {
        TaskSearch.groupNames(tasks: tasks, groups: groups)
    }

    /// Tasks bucketed by group for the sectioned list; Inbox (nil group) last, matching the Mac.
    struct Section: Identifiable {
        let group: TaskProject?
        let tasks: [Project]
        var id: Int64 { group?.id ?? -1 }
        var name: String { group?.name ?? "Inbox" }
        var colorHex: String { group?.colorHex ?? "#8E8E93" }
    }

    var sections: [Section] {
        var out: [Section] = groups.compactMap { g in
            let members = tasks.filter { $0.taskProjectID == g.id }
            return members.isEmpty ? nil : Section(group: g, tasks: members)
        }
        let inbox = tasks.filter { $0.taskProjectID == nil }
        if !inbox.isEmpty { out.append(Section(group: nil, tasks: inbox)) }
        return out
    }

    // MARK: - Lifecycle

    func load() {
        do {
            if store == nil {
                let store = try IntervalStore()
                try store.migrateIfNeeded()
                self.store = store
            }
            reload()
            // Recover a run left open by a previous launch. Elapsed is recomputed from the
            // persisted start, so a suspended or terminated app loses no time.
            if let running {
                currentTaskID = running.projectID
                pausedSince = nil
                syncActivity(startedAt: running.start, isRunning: true)
            }
            // Re-arm after a cold launch: the pending notification survives termination, but the
            // threshold may have moved (a session recovered from a crash is already older).
            rearmNudges()
        } catch {
            loadError = "\(error)"
        }
    }

    func reload() {
        guard let store else { return }
        do {
            let now = Date()
            allTasks = try store.listProjects(includeArchived: true)
            // Today shows unfinished tasks plus anything finished TODAY (struck through) — a task
            // completed yesterday clears out of Today but stays in All Time. Same rule as the Mac.
            tasks = try store.listProjects().filter { $0.showsInToday(now: now) }
            archivedTasks = allTasks.filter { $0.archived }
            groups = try store.listTaskProjects()
            running = try store.openInterval()
            if let running { currentTaskID = running.projectID }
            lastActivity = try store.lastActivityByProject()

            // Closed intervals only — see `committedTodaySeconds`. Not windowed by day either:
            // `todayTotals` does the clipping, and an interval that began yesterday and ended today
            // must be counted for its post-midnight portion, which a `from: startOfDay` query drops.
            let closed = try store.intervals().filter { !$0.isRunning }
            committedTodaySeconds = Dictionary(uniqueKeysWithValues:
                Aggregations.todayTotals(projects: allTasks, intervals: closed, now: now)
                    .map { ($0.project.id, $0.seconds) })
            committedAllTimeSeconds = Dictionary(uniqueKeysWithValues:
                Aggregations.allTimeTotals(projects: allTasks, intervals: closed, now: now)
                    .map { ($0.project.id, $0.seconds) })

            reloadTags()

            // Device attribution: who recorded what. Needed by the timeline lanes and Settings.
            deviceLabels = (try? store.deviceLabels()) ?? [:]
            knownDevices = deviceLabels
                .map { DeviceInfo(id: $0.key, label: $0.value.isEmpty ? $0.key : $0.value) }
                .sorted { $0.label < $1.label }
        } catch {
            loadError = "\(error)"
        }
    }

    private func reloadTags() {
        guard let store else { return }
        allTags = (try? store.listTags()) ?? []
        let byID = Dictionary(uniqueKeysWithValues: allTags.map { ($0.id, $0) })
        var map: [Int64: [Tag]] = [:]
        for group in groups {
            let ids = (try? store.tagIDs(for: .project(group.id))) ?? []
            let tags = ids.compactMap { byID[$0] }
            if !tags.isEmpty { map[group.id] = tags.sorted { $0.sortOrder < $1.sortOrder } }
        }
        tagsByGroup = map
    }

    // MARK: - Timer mutations

    /// Start `task`, or pause it when it's already the running one — the same gesture the Mac
    /// binds to space, and what the Action Button triggers.
    func toggle(taskID: Int64) {
        guard let store else { return }
        do {
            if running?.projectID == taskID {
                try store.stopOpenInterval()
                currentTaskID = taskID          // stays current, mirroring the Mac's paused state
                pausedSince = Date()
                reload()
                if let task = task(id: taskID) {
                    syncActivity(startedAt: Date(), isRunning: false, task: task)
                }
                rearmNudges()
            } else {
                try store.switchTo(projectID: taskID)
                currentTaskID = taskID
                pausedSince = nil
                reload()
                if let running {
                    syncActivity(startedAt: running.start, isRunning: true)
                }
                rearmNudges()
            }
        } catch {
            loadError = "\(error)"
        }
    }

    /// What the Action Button runs: resume/pause whatever is current, or fall back to the most
    /// recently used task so a single press always does something useful.
    func toggleCurrent() {
        if let id = currentTaskID ?? running?.projectID {
            toggle(taskID: id)
            return
        }
        if let pick = recencyOrdered.first { toggle(taskID: pick.id) }
    }

    func stop() {
        guard let store else { return }
        try? store.stopOpenInterval()
        currentTaskID = nil
        pausedSince = nil
        reload()
        LiveActivityController.end()
        // Stopping is not pausing: nothing is outstanding, so both nudges are cancelled outright.
        NudgeScheduler.shared.cancelAll()
    }

    /// Ask the UI to present the switcher wheel. Called from `OpenSwitcherIntent`.
    func requestSwitcher() { showingSwitcher = true }

    /// Re-arm the nudges from current state. Public because the notification's "Still on it" action
    /// re-arms without changing the timer — a long session should keep checking in rather than going
    /// quiet after one dismissal.
    func rearmNudges() {
        NudgeScheduler.shared.rearm(runningSince: running?.start,
                                    pausedSince: pausedSince,
                                    taskName: currentTaskID.flatMap { task(id: $0)?.name })
        NudgeScheduler.shared.logPending()
    }

    // MARK: - Task CRUD (§3.8)

    @discardableResult
    func addTask(named name: String, inGroup groupID: Int64? = nil) -> Int64? {
        guard let store else { return nil }
        // `/project` in the name files it on create, exactly as the Mac's palette does.
        let parsed = TaskSearch.parse(name)
        let trimmed = parsed.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            var target = groupID
            if target == nil, let token = parsed.groupToken, !token.isEmpty {
                target = try store.upsertTaskProject(
                    name: token, colorHex: Palette.color(forIndex: groups.count))
            }
            // Colour by position, exactly as the Mac does, so a task created on the phone gets a
            // colour the Mac would have chosen too.
            let id = try store.createProject(
                name: trimmed, colorHex: Palette.color(forIndex: allTasks.count), inGroup: target)
            reload()
            return id
        } catch {
            loadError = "\(error)"
            return nil
        }
    }

    func rename(taskID: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform { try $0.renameProject(id: taskID, name: trimmed) }
    }

    func setColor(taskID: Int64, hex: String) { perform { try $0.setProjectColor(id: taskID, colorHex: hex) } }

    func setGroup(taskID: Int64, groupID: Int64?) {
        perform { try $0.setTaskProject(taskID: taskID, taskProjectID: groupID) }
    }

    /// Finished = done but STILL counted in Today/All-Time, struck through. Distinct from archived.
    func setFinished(taskID: Int64, _ finished: Bool) {
        if finished, running?.projectID == taskID { try? store?.stopOpenInterval() }
        if finished, currentTaskID == taskID { currentTaskID = nil; LiveActivityController.end() }
        perform { try $0.setProjectFinished(id: taskID, finished: finished) }
    }

    /// Archived = out of Today/All-Time entirely.
    func setArchived(taskID: Int64, _ archived: Bool) {
        if archived, running?.projectID == taskID { try? store?.stopOpenInterval() }
        if archived, currentTaskID == taskID { currentTaskID = nil; LiveActivityController.end() }
        perform { try $0.setProjectArchived(id: taskID, archived: archived) }
    }

    func delete(taskID: Int64) {
        if running?.projectID == taskID { try? store?.stopOpenInterval() }
        if currentTaskID == taskID { currentTaskID = nil; LiveActivityController.end() }
        perform { try $0.deleteProject(id: taskID) }
    }

    func reorder(taskIDs: [Int64]) {
        perform { store in
            for (index, id) in taskIDs.enumerated() {
                try store.setProjectOrder(id: id, sortOrder: index)
            }
        }
    }

    // MARK: - Groups

    @discardableResult
    func addGroup(named name: String) -> Int64? {
        guard let store else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = try? store.upsertTaskProject(
            name: trimmed, colorHex: Palette.color(forIndex: groups.count))
        reload()
        return id
    }

    func renameGroup(id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform { try $0.renameTaskProject(id: id, name: trimmed) }
    }

    func setGroupColor(id: Int64, hex: String) { perform { try $0.setTaskProjectColor(id: id, colorHex: hex) } }
    func deleteGroup(id: Int64) { perform { try $0.deleteTaskProject(id: id) } }

    private func perform(_ body: (IntervalStore) throws -> Void) {
        guard let store else { return }
        do {
            try body(store)
            reload()
            // Keep the island's name/colour honest after a rename or recolour of the running task.
            if let running, let task = task(id: running.projectID) {
                syncActivity(startedAt: running.start, isRunning: true, task: task)
            }
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Live Activity

    /// Where a running row's live clock should count from, so the list and the Dynamic Island show
    /// the same number. Delegates to `TimerDisplay` in `Shared/` — the widget uses it too.
    func liveOrigin(for taskID: Int64) -> Date? {
        guard let running, running.projectID == taskID else { return nil }
        return TimerDisplay.liveOrigin(runStart: running.start,
                                       committedToday: committedTodaySeconds[taskID] ?? 0)
    }

    private func syncActivity(startedAt: Date, isRunning: Bool, task explicit: Project? = nil) {
        guard let id = currentTaskID, let task = explicit ?? self.task(id: id) else { return }
        // Passed straight through now that the base excludes the open interval. An earlier version
        // subtracted a freshly-computed `live` from a total that already contained an older one —
        // two different `now`s, so it drifted.
        LiveActivityController.sync(
            taskID: id,
            state: .init(taskName: task.name,
                         colorHex: colorHex(for: task),
                         startedAt: startedAt,
                         committedTodaySeconds: committedTodaySeconds[id] ?? 0,
                         isRunning: isRunning))
    }
}
