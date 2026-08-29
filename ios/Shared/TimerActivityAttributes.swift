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
        /// Today's total for this task at the moment of the last update, EXCLUDING the live run.
        /// Kept separate so the widget can show "today" without the app having to push a tick:
        /// the live portion is `now - startedAt`, which the system already knows how to draw.
        var todaySecondsBeforeRun: Double
        /// False while the task is paused but still current — the island stays up showing a frozen
        /// time, which mirrors how the Mac's menu bar keeps displaying a paused task.
        var isRunning: Bool
    }

    /// Stable identity of what's being timed. Only used to decide whether an existing activity can
    /// be updated rather than replaced.
    var taskID: Int64
}
