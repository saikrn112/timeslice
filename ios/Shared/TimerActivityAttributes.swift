import ActivityKit
import Foundation

/// The contract between the app and the Live Activity widget, compiled into BOTH targets.
///
/// Everything the Dynamic Island draws lives in `ContentState` rather than the static attributes,
/// including the task name and colour. That's deliberate: switching tasks then *updates* one
/// activity instead of ending one and requesting another, so the island doesn't flicker through an
/// empty state on every context switch — which is the single most common thing this app does.
///
/// Note what is NOT here: elapsed seconds. The widget is handed `startedAt` and renders
/// `Text(timerInterval:)`, which the **system** ticks — so the clock keeps counting while our
/// process is suspended or dead, with no background execution and no push updates. That works only
/// because a Timeslice interval already stores its start instead of accumulating elapsed time.
struct TimerActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// The task being timed, shown in the expanded island and on the Lock Screen.
        var taskName: String
        /// `#RRGGBB`, resolved by `Palette.displayColorHex` in the app so the phone paints a task
        /// the same colour the Mac does — the widget never re-derives it.
        var colorHex: String
        /// When the running interval began. The system counts up from this.
        var startedAt: Date
        /// Today's seconds for this task from **CLOSED intervals only** — the committed base, the
        /// same quantity the Mac's `AppState.recomputeTotals` produces.
        ///
        /// Excluding the open interval is what makes this stable: the widget adds the live portion
        /// by ticking from `startedAt`, so a base that already contained some elapsed time would
        /// double-count and drift. Named for what it *is*, because the previous name invited
        /// exactly that bug.
        var committedTodaySeconds: Double
        /// False while the task is paused but still current — the island stays up showing a frozen
        /// time, which mirrors how the Mac's menu bar keeps displaying a paused task.
        var isRunning: Bool
    }

    /// Stable identity of what's being timed. Only used to decide whether an existing activity can
    /// be updated rather than replaced.
    var taskID: Int64
}

extension TimerActivityAttributes.ContentState {
    /// The instant a system-ticked clock should count from so it reads as today's total.
    var liveOrigin: Date {
        TimerDisplay.liveOrigin(runStart: startedAt, committedToday: committedTodaySeconds)
    }

    /// Seconds elapsed in the current session alone (0 when paused).
    func sessionSeconds(now: Date = Date()) -> Double {
        isRunning ? max(0, now.timeIntervalSince(startedAt)) : 0
    }
}

/// Display maths shared by the app and the widget extension.
///
/// In `Shared/` precisely because those are two processes: the list row and the Dynamic Island must
/// agree to the second, and a second copy of this arithmetic is how they would quietly stop agreeing.
enum TimerDisplay {
    /// Backdate the run's start by whatever is already banked today, so ONE `Text(timerInterval:)`
    /// renders `committed + live` — today's running total — with no timer of our own. This is what
    /// lets the island keep counting while the app is suspended or terminated.
    ///
    /// Clamped to the start of today: a session begun before midnight must contribute only its
    /// post-midnight portion, otherwise today's figure opens hours too high.
    static func liveOrigin(runStart: Date, committedToday: Double,
                           now: Date = Date(), calendar: Calendar = .current) -> Date {
        let effectiveStart = max(runStart, calendar.startOfDay(for: now))
        return effectiveStart.addingTimeInterval(-committedToday)
    }
}
