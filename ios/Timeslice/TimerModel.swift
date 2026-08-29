import Foundation
import SwiftUI
import TimesliceCore

/// The iOS app's single source of truth: wraps `IntervalStore` and keeps the Live Activity in step.
///
/// A singleton because the Action Button's App Intent runs in this same process and must mutate the
/// *same* store the UI is showing — two `IntervalStore` instances on one sqlite file would let the
/// UI display state the intent had already changed.
///
/// Deliberately thin. All the real logic (one-running-interval enforcement, day bucketing, colour
/// derivation) is in `TimesliceCore`, shared verbatim with the Mac app, so the phone cannot drift
/// from it.
@MainActor
final class TimerModel: ObservableObject {
    static let shared = TimerModel()

    @Published private(set) var tasks: [Project] = []
    /// Today's seconds from **CLOSED intervals only** — the committed base, matching the Mac's
    /// `AppState.recomputeTotals`. The running task's live time is added on top at display time, so
    /// a row can tick without re-querying, and so this value never goes stale.
    ///
    /// Including the open interval here (as this once did) is a trap: it bakes a snapshot of
    /// "elapsed as of the last reload" into the total, which then neither ticks nor matches the Mac.
    @Published private(set) var committedTodaySeconds: [Int64: TimeInterval] = [:]
    @Published private(set) var running: RunningInterval?
    @Published private(set) var loadError: String?

    /// Includes archived tasks, because shades are positional: hiding an archived sibling would
    /// renumber the ones after it and silently recolour them.
    private var allTasks: [Project] = []
    private var groups: [TaskProject] = []

    private var store: IntervalStore?

    private init() {}

    /// The current task even while paused — what the Action Button toggles.
    @Published private(set) var currentTaskID: Int64?

    var isRunning: Bool { running != nil }

    func task(id: Int64) -> Project? { allTasks.first { $0.id == id } }

    /// Colour a task renders in, derived by the SAME Core function the Mac uses.
    func colorHex(for task: Project) -> String {
        Palette.displayColorHex(for: task, groups: groups, allTasks: allTasks)
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
                syncActivity(startedAt: running.start, isRunning: true)
            }
        } catch {
            loadError = "\(error)"
        }
    }

    func reload() {
        guard let store else { return }
        do {
            tasks = try store.listProjects()
            allTasks = try store.listProjects(includeArchived: true)
            groups = try store.listTaskProjects()
            running = try store.openInterval()
            if let running { currentTaskID = running.projectID }

            // Closed intervals only — see `committedTodaySeconds`. Not windowed by day either:
            // `todayTotals` does the clipping, and an interval that began yesterday and ended today
            // must be counted for its post-midnight portion, which a `from: startOfDay` query drops.
            let closed = try store.intervals().filter { !$0.isRunning }
            let totals = Aggregations.todayTotals(projects: allTasks, intervals: closed)
            committedTodaySeconds = Dictionary(
                uniqueKeysWithValues: totals.map { ($0.project.id, $0.seconds) })
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Mutations

    /// Start `task`, or pause it when it's already the running one — the same gesture the Mac
    /// binds to space, and what the Action Button triggers.
    func toggle(taskID: Int64) {
        guard let store else { return }
        do {
            if running?.projectID == taskID {
                try store.stopOpenInterval()
                currentTaskID = taskID          // stays current, mirroring the Mac's paused state
                reload()
                if let task = task(id: taskID) {
                    syncActivity(startedAt: Date(), isRunning: false, task: task)
                }
            } else {
                try store.switchTo(projectID: taskID)
                currentTaskID = taskID
                reload()
                if let running {
                    syncActivity(startedAt: running.start, isRunning: true)
                }
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
        guard let store else { return }
        // No current task: pick the most recently active, else the first in the list.
        let recent = (try? store.lastActivityByProject()) ?? [:]
        let pick = tasks.max { (recent[$0.id] ?? .distantPast) < (recent[$1.id] ?? .distantPast) }
            ?? tasks.first
        if let pick { toggle(taskID: pick.id) }
    }

    func stop() {
        guard let store else { return }
        try? store.stopOpenInterval()
        currentTaskID = nil
        reload()
        LiveActivityController.end()
    }

    @discardableResult
    func addTask(named name: String) -> Int64? {
        guard let store else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            // Colour by position, exactly as the Mac does, so a task created on the phone gets a
            // colour the Mac would have chosen too.
            let id = try store.createProject(
                name: trimmed, colorHex: Palette.color(forIndex: allTasks.count))
            reload()
            return id
        } catch {
            loadError = "\(error)"
            return nil
        }
    }

    // MARK: - Live Activity

    private func syncActivity(startedAt: Date, isRunning: Bool, task explicit: Project? = nil) {
        guard let id = currentTaskID, let task = explicit ?? self.task(id: id) else { return }
        // Passed straight through now that the base excludes the open interval. The previous version
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

    /// Where a running row's live clock should count from, so the list and the Dynamic Island show
    /// the same number. Delegates to `TimerDisplay` in `Shared/` — the widget uses it too.
    func liveOrigin(for taskID: Int64) -> Date? {
        guard let running, running.projectID == taskID else { return nil }
        return TimerDisplay.liveOrigin(runStart: running.start,
                                       committedToday: committedTodaySeconds[taskID] ?? 0)
    }
}
