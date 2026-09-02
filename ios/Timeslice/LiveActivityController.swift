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
        guard let existing = current else { return }
        Task { await existing.end(nil, dismissalPolicy: .immediate) }
    }

}
