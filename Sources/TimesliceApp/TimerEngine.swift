import Foundation
import Combine
import TimesliceCore

/// Owns the live timer and the write path. Decoupled from all UI: it writes intervals to the
/// store regardless of whether any window is visible, so timers keep running while the screen
/// is shared and the UI is blanked/redacted.
///
/// Distinguishes three states:
///  • running  — a task is being actively timed (open interval in the DB, ticking).
///  • paused   — a task is "current" but not counting; its open interval is closed, but it
///    stays the selected/current task so the menu bar keeps showing its time statically.
///  • idle     — no current task (nothing shown).
/// A tiny, separately-observable clock holding only the fast-ticking elapsed value. Kept apart
/// from TimerEngine so that 30fps updates re-render ONLY the small time labels that observe it —
/// not whole charts/lists (which observe TimerEngine, whose task-state changes rarely). This is
/// what keeps CPU low and stops the metrics legend from oscillating.
@MainActor
final class TickClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

@MainActor
final class TimerEngine: ObservableObject {
    private let store: IntervalStore

    /// Fast elapsed clock — observe this (not the engine) for live ms displays.
    let clock = TickClock()

    /// The task actively being timed right now, or nil if not running (paused or idle).
    @Published private(set) var runningProjectID: Int64?
    /// The "current" task — persists through pause. nil only when idle (stopped/finished/switched away).
    @Published private(set) var currentProjectID: Int64?
    /// Start time of the current running interval (nil while paused).
    @Published private(set) var runningSince: Date?
    /// When the current task was paused (nil unless `isPaused`). Drives the "still paused?"
    /// nudge — the mirror of the long-session checkpoint, for when you forget to un-pause.
    @Published private(set) var pausedSince: Date?

    /// Live elapsed seconds of the current running interval; 0 while paused. Non-reactive read;
    /// for reactive UI, observe `clock`.
    var elapsed: TimeInterval { clock.elapsed }

    private var ticker: AnyCancellable?
    /// Keeps macOS from throttling our timers (App Nap / timer coalescing) while a timer runs —
    /// otherwise the menu-bar clock lags by seconds when Timeslice isn't the front app.
    private var activity: NSObjectProtocol?

    init(store: IntervalStore) {
        self.store = store
    }

    var isRunning: Bool { runningProjectID != nil }
    /// True when a task is current but not actively timing.
    var isPaused: Bool { runningProjectID == nil && currentProjectID != nil }

    /// Restore any open interval left over from a previous run (e.g. after a crash or quit
    /// while a timer was running). Elapsed is recomputed from the persisted start.
    func restore() {
        if let open = try? store.openInterval() {
            runningProjectID = open.projectID
            currentProjectID = open.projectID
            runningSince = open.start
            pausedSince = nil
            startTicking()
        }
    }

    /// Toggle the timer for `projectID`:
    ///  • if it's actively running → pause it (stays current)
    ///  • otherwise → start/resume timing it (becomes the running + current task)
    func toggle(projectID: Int64) {
        if runningProjectID == projectID {
            pause()
        } else {
            switchTo(projectID: projectID)
        }
    }

    /// Context switch: atomically close any open interval and open a new one for `projectID`.
    func switchTo(projectID: Int64) {
        let now = Date()
        do {
            try store.switchTo(projectID: projectID, at: now)
            runningProjectID = projectID
            currentProjectID = projectID
            runningSince = now
            pausedSince = nil          // running again — nothing to nudge about
            clock.elapsed = 0
            startTicking()
            notifyChanged()
        } catch {
            NSLog("TimerEngine.switchTo failed: \(error.localizedDescription)")
        }
    }

    /// Pause the running task: close its open interval but keep it as the current task, so its
    /// accumulated time stays visible (statically) in the menu bar and list.
    ///
    /// `at` lets the close be back-dated — e.g. to when the machine went to sleep or when a
    /// long-session checkpoint fired — so idle/asleep time isn't counted. Clamped to not predate
    /// the interval's start.
    func pause(at cutoff: Date = Date()) {
        let end = max(cutoff, runningSince ?? cutoff)
        do {
            try store.stopOpenInterval(at: end)
            runningProjectID = nil
            runningSince = nil
            pausedSince = end
            clock.elapsed = 0
            stopTicking()
            notifyChanged()
        } catch {
            NSLog("TimerEngine.pause failed: \(error.localizedDescription)")
        }
    }

    /// Fully stop and clear the current task (nothing shown afterward). Used when a task is
    /// finished or explicitly cleared.
    func stop() {
        do {
            try store.stopOpenInterval(at: Date())
        } catch {
            NSLog("TimerEngine.stop failed: \(error.localizedDescription)")
        }
        runningProjectID = nil
        currentProjectID = nil
        runningSince = nil
        pausedSince = nil              // idle, not paused — nothing to resume
        clock.elapsed = 0
        stopTicking()
        notifyChanged()
    }

    /// Clear `projectID` as the current task if it is (e.g. when it's archived/finished/deleted).
    func clearIfCurrent(projectID: Int64) {
        if runningProjectID == projectID { pause() }
        if currentProjectID == projectID { currentProjectID = nil }
    }

    private func startTicking() {
        ticker?.cancel()
        // Prevent App Nap from throttling the tick while a timer is running.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Timeslice timer running"
            )
        }
        tick()
        // 10fps: smooth enough for a ms display, but a third of the CPU of 30fps. Only updates
        // the lightweight TickClock; it performs no DB writes and doesn't touch chart/list state.
        ticker = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    private func tick() {
        guard let since = runningSince else { return }
        clock.elapsed = Date().timeIntervalSince(since)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)
    }
}
