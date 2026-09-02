import Foundation
import SwiftUI
import TimesliceCore
import TimesliceIntents

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
    /// The task palette. On the model rather than in `TasksView` so it can be opened from
    /// the root — which is what lets the headless `start-tab` hint screenshot it.
    @Published var showingAddTask = false
    /// Unresolved notes, for the Feedback tab's badge. Published (not computed per render) because a
    /// tab badge is evaluated on every layout pass and this is a sqlite query.
    @Published private(set) var openFeedbackCount = 0

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

    /// Search ARCHIVED tasks, ranked by the same Core function as the live list.
    ///
    /// Separate because `searchResults` deliberately ranks only active tasks — an archived task
    /// shouldn't compete with live ones for the top of the palette. But the archived SECTION still has
    /// to honour the query, or it lists tasks that plainly don't match.
    func searchArchived(_ query: String, limit: Int = 50) -> [Project] {
        guard !query.isEmpty else { return archivedTasks }
        return TaskSearch.rank(query: TaskSearch.parse(query).name, projects: archivedTasks,
                               lastActivity: lastActivity, groupNames: groupNamesByTask,
                               limit: limit).map(\.project)
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

    /// Recount open notes. Cheap, and called from `reload()` so the badge can't drift from the tab.
    func refreshFeedbackCount() {
        openFeedbackCount = ((try? store?.listFeedback(includeResolved: false)) ?? []).count
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
            // Sorted by device ID, not label. The timeline's band and legend index off
            // `Aggregations.orderedDevices`, which is id-ordered — sorting this list by label meant the
            // Settings list and the timeline disagreed about which device came first, so "device 1" was
            // a different machine depending on which screen you were looking at.
            knownDevices = deviceLabels
                .map { DeviceInfo(id: $0.key, label: $0.value.isEmpty ? $0.key : $0.value) }
                .sorted { $0.id < $1.id }
            refreshFeedbackCount()
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
    /// Toggle a task, updating the Live Activity BEFORE anything expensive.
    ///
    /// Pause/play on the Lock Screen took about a second. The cause was ordering, not the intent
    /// machinery: `reload()` ran first, and it loads EVERY interval ever recorded and aggregates it twice
    /// (today totals and all-time totals over the full history). Only after all that did the activity
    /// update — so the visible state change waited on months of rows.
    ///
    /// The write itself is one statement. So: write, refresh the island, then do the bookkeeping. The
    /// committed figure for the island comes from a today-bounded query rather than the full reload, which
    /// is the only number the activity actually needs.
    ///
    /// Nothing is lost by deferring `reload()` — it repaints the in-app list, which you aren't looking at
    /// when you press a button on your Lock Screen.
    func toggle(taskID: Int64) {
        guard let store else { return }
        let wasRunning = running != nil
        let isPausing = running?.projectID == taskID
        do {
            if isPausing {
                try store.stopOpenInterval()
                currentTaskID = taskID          // stays current, mirroring the Mac's paused state
                pausedSince = Date()
                // Island first, from a cheap read. `task(id:)` uses the in-memory list, which is already
                // correct — pausing changes no task, only an interval.
                if let task = task(id: taskID) {
                    syncActivity(startedAt: Date(), isRunning: false, task: task,
                                 committedOverride: committedTodayNow(for: taskID))
                }
                Haptics.paused()
            } else {
                try store.switchTo(projectID: taskID)
                currentTaskID = taskID
                pausedSince = nil
                // `running` isn't refreshed yet, so read the open interval directly — one indexed row.
                if let open = try? store.openInterval(), let task = task(id: taskID) {
                    running = open
                    syncActivity(startedAt: open.start, isRunning: true, task: task,
                                 committedOverride: committedTodayNow(for: taskID))
                }
                if wasRunning { Haptics.switched() } else { Haptics.started() }
            }
            // Everything below is bookkeeping the pressed button doesn't wait on.
            reload()
            rearmNudges()
            SyncController.shared.publishSoon()
        } catch {
            loadError = "\(error)"
        }
    }

    /// Stop tracking entirely: no current task, so the island ends rather than showing a paused one.
    ///
    /// End the activity FIRST, for the same reason `toggle` updates it first — the visible change shouldn't
    /// queue behind a full reload.
    func stop() {
        guard let store else { return }
        try? store.stopOpenInterval()
        currentTaskID = nil
        pausedSince = nil
        LiveActivityController.end()
        reload()
        // Stopping is not pausing: nothing is outstanding, so both nudges are cancelled outright.
        NudgeScheduler.shared.cancelAll()
        // Clears our running marker on the other devices, so nothing keeps thinking we hold the timer.
        SyncController.shared.publishSoon()
    }

    /// Pause the running task, or resume the current one. What the Action Button and the Live Activity's
    /// pause button call.
    func toggleCurrent() {
        if let id = currentTaskID ?? running?.projectID {
            toggle(taskID: id)
            return
        }
        if let pick = recencyOrdered.first { toggle(taskID: pick.id) }
    }

    /// Switch to the task worked before this one — index 1 of the shared recency order, exactly where one
    /// press of the Mac's `\` key lands. Index 0 is the current task, which is pinned.
    func switchToPrevious() {
        if let previous = recencyOrdered.dropFirst().first { toggle(taskID: previous.id) }
    }

    /// Ask the UI to present the switcher wheel. Called from `OpenSwitcherIntent`.
    func requestSwitcher() { showingSwitcher = true }

    /// Re-arm the nudges from current state. Public because the notification's "Still on it" action
    /// re-arms without changing the timer — a long session should keep checking in rather than going
    /// quiet after one dismissal.
    /// Split a long run into focus-length blocks, keeping the timer going.
    ///
    /// Replaces the phone's "still working?" auto-pause. You can't answer a prompt while driving, and an
    /// unanswered one threw away real time; chunking never interrupts and never loses any. Correcting an
    /// over-record is then two swipes in the sessions list.
    ///
    /// Called on foreground and after each sync rather than on a timer: elapsed time is derived from the
    /// persisted start, and `rollOpenInterval` loops, so however long the phone was suspended one call
    /// catches all of it up.
    func rollChunks() {
        guard let store else { return }
        let rolled = (try? store.rollOpenInterval(chunkSeconds: settings.deepBlockSeconds)) ?? 0
        if rolled > 0 { reload() }
    }

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

    /// One task's committed seconds today, read with a DATE-BOUNDED query.
    ///
    /// `reload()` gets this from `store.intervals()` — every interval ever recorded — then aggregates it
    /// twice. That's fine once per data change, and far too much to sit in front of a button press.
    /// Bounded to today, it's a few rows.
    ///
    /// Still `Aggregations.todayTotals`, not arithmetic here: the day boundary is DST-sensitive and that
    /// logic exists once, in Core.
    private func committedTodayNow(for taskID: Int64) -> TimeInterval {
        guard let store else { return committedTodaySeconds[taskID] ?? 0 }
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let todays = ((try? store.intervals(from: dayStart)) ?? []).filter { !$0.isRunning }
        return Aggregations.todayTotals(projects: allTasks, intervals: todays, now: now)
            .first { $0.project.id == taskID }?.seconds ?? 0
    }

    private func syncActivity(startedAt: Date, isRunning: Bool, task explicit: Project? = nil,
                              committedOverride: TimeInterval? = nil) {
        guard let id = currentTaskID, let task = explicit ?? self.task(id: id) else { return }
        // Passed straight through now that the base excludes the open interval. An earlier version
        // subtracted a freshly-computed `live` from a total that already contained an older one —
        // two different `now`s, so it drifted.
        LiveActivityController.sync(
            taskID: id,
            state: .init(taskName: task.name,
                         colorHex: colorHex(for: task),
                         startedAt: startedAt,
                         committedTodaySeconds: committedOverride ?? committedTodaySeconds[id] ?? 0,
                         isRunning: isRunning,
                         recents: switcherRecents(excluding: id)))
    }

    /// The tasks offered as one-press buttons in the island's switcher.
    ///
    /// Same `TaskOrdering.recencyOrdered` the app's own switcher and the Mac's `\` key use, so the
    /// island offers the same candidates in the same order rather than a second notion of "recent".
    /// The current task is dropped — it's already the subject of the activity.
    ///
    /// Resolved to **uids** here, in the app, because the widget cannot open the database to do it and
    /// a row id would mean a different task on another device.
    private func switcherRecents(excluding current: Int64) -> [TimerActivityAttributes.RecentTask] {
        guard let store else { return [] }
        return recencyOrdered
            .filter { $0.id != current && !$0.finished }
            .prefix(3)
            .compactMap { task in
                guard let uid = try? store.uid(table: "projects", id: task.id) else { return nil }
                return .init(uid: uid, name: task.name, colorHex: colorHex(for: task))
            }
    }
}

/// Supplies the shared Live Activity intents with behaviour.
///
/// The intents live in `TimesliceIntents`, which cannot reach this class — the app owns the store, and
/// pulling it into an extension process is what `0xdead10cc` punishes. So the app registers itself at
/// launch and the intents call through.
extension TimerModel: TimerActions {

    /// Start the task with this uid, from a Live Activity button.
    ///
    /// Resolves uid → row id, never the other way round: the island's payload can outlive a sync, and
    /// an id that arrived from another device points at a different task here. An unknown uid is a
    /// deliberate no-op — starting *some* timer would be worse than starting none.
    ///
    /// `load()` first because the intent can run in a freshly-launched process where nothing is open yet.
    func switchTo(uid: String) {
        load()
        // `localID` is the same resolver `SyncEngine` uses for every incoming fact, so the island and
        // the merge path agree on what a uid means.
        // `try?` on a throwing `Int64?` flattens to one optional, so this is a single binding.
        guard let store, let id = try? store.localID(table: "projects", uid: uid) else { return }
        toggle(taskID: id)
    }
}
