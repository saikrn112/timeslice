import ActivityKit
import Foundation

/// Owns the one Live Activity Timeslice ever shows.
///
/// There is at most one, because the app's core invariant is that at most one timer runs anywhere.
/// So a task switch updates the existing activity rather than stacking a second island.
enum LiveActivityController {

    /// The activity we're driving, if any. Recovered from `Activity.activities` rather than kept
    /// only in memory, because the app can be relaunched while an activity is still on screen.
    private static var current: Activity<TimerActivityAttributes>? {
        Activity<TimerActivityAttributes>.activities.first
    }

    /// Push `state` to the island: update in place when possible, otherwise request a new activity.
    ///
    /// Replacing (rather than updating) when the task changes is necessary because `taskID` lives in
    /// the *static* attributes, which ActivityKit will not let us mutate.
    static func sync(taskID: Int64, state: TimerActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        scheduleHourBoundaryRefresh(for: state)

        if let existing = current {
            if existing.attributes.taskID == taskID {
                Task { await existing.update(ActivityContent(state: state, staleDate: nil)) }
                return
            }
            // Different task — end the old island before opening the new one, so the two never
            // coexist and contradict the one-timer invariant on screen.
            Task {
                await existing.end(nil, dismissalPolicy: .immediate)
                request(taskID: taskID, state: state)
            }
            return
        }
        request(taskID: taskID, state: state)
    }

    private static func request(taskID: Int64, state: TimerActivityAttributes.ContentState) {
        do {
            _ = try Activity.request(
                attributes: TimerActivityAttributes(taskID: taskID),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
        } catch {
            // Most often `.visibility` — iOS refuses to start an activity from the background.
            // Not fatal: tracking is already recorded in sqlite, the island is a display of it.
            NSLog("[timeslice] Live Activity request failed: \(error.localizedDescription)")
        }
    }

    static func end() {
        boundaryTask?.cancel()
        boundaryTask = nil
        guard let existing = current else { return }
        Task { await existing.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Crossing the hour

    private static var boundaryTask: Task<Void, Never>?

    /// Re-push the state exactly when the clock crosses one hour.
    ///
    /// The island's clock drops its hours field below an hour (`44:45` rather than `0:44:45`), but
    /// `showsHours` is baked into the snapshot at render time — the system ticks the digits, not the
    /// format. Without this, a session that starts at 50 minutes and runs on keeps a minutes-only label
    /// with no field to carry the overflow.
    ///
    /// One update per hour per session, which is negligible against the activity update budget. Only
    /// ever *arms* while the clock is below an hour: `hourBoundary` returns nil once hours are showing,
    /// so this cannot become a repeating timer.
    ///
    /// This is a foreground convenience, not a guarantee — a suspended app doesn't get to run, and if
    /// the update is missed the label is briefly ugly rather than wrong-by-arithmetic. The elapsed value
    /// itself is always derived from `startedAt` by the system.
    private static func scheduleHourBoundaryRefresh(for state: TimerActivityAttributes.ContentState) {
        boundaryTask?.cancel()
        boundaryTask = nil
        guard let boundary = state.hourBoundary() else { return }
        let delay = boundary.timeIntervalSinceNow
        guard delay > 0 else { return }

        boundaryTask = Task {
            try? await Task.sleep(for: .seconds(delay + 1))
            guard !Task.isCancelled, let existing = current else { return }
            // Re-send the SAME state. `showsHours` is computed from it at render time, so an unchanged
            // payload now renders with the hours field.
            await existing.update(ActivityContent(state: state, staleDate: nil))
        }
    }
}
