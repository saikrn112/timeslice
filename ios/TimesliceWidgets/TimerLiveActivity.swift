import ActivityKit
import SwiftUI
import TimesliceUI
import WidgetKit

/// The Dynamic Island + Lock Screen presence for the running timer.
///
/// Runs in a **separate process** from the app, which is why the colour it paints comes from
/// `TimesliceUI`/`TimesliceCore` (linked into this extension) rather than anything app-local: the
/// app resolves a task's `#RRGGBB` with `Palette.displayColorHex` and passes it in the content
/// state, and this target turns it into a `Color` with the same `Color(hex:)` the Mac app uses.
/// One implementation, three processes.
///
/// Every clock here is `Text(timerInterval:)`, drawn by the system from `startedAt`. Nothing in this
/// file needs the app to be alive, and no timer, push, or background task updates it.
struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                // Tinted background rather than a coloured card: the Lock Screen composites this
                // over arbitrary wallpaper, so a saturated fill fights the system's own styling.
                .activityBackgroundTint(Color(hex: context.state.colorHex).opacity(0.18))
                .activitySystemActionForegroundColor(Color(hex: context.state.colorHex))
        } dynamicIsland: { context in
            let color = Color(hex: context.state.colorHex)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 10, height: 10)
                        Text(context.state.taskName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ClockText(state: context.state)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(color)
                        // Monospaced digits still reflow as the hour rolls over; a fixed width
                        // stops the whole region shifting once a session passes an hour.
                        .frame(minWidth: 82, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(context.state.isRunning ? "Tracking" : "Paused",
                              systemImage: context.state.isRunning ? "record.circle" : "pause.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        // The day's figure is what makes the island worth glancing at; the live
                        // clock alone doesn't answer "how much today".
                        TodayText(state: context.state)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Circle().fill(color).frame(width: 9, height: 9)
            } compactTrailing: {
                ClockText(state: context.state)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(color)
                    // The compact slot is width-constrained; without this an hours-long session
                    // gets truncated to an unreadable stub.
                    .frame(maxWidth: 54)
            } minimal: {
                // Minimal is a ~16pt circle — a ring reads as "a timer is going" at that size,
                // where any text would not.
                Circle()
                    .stroke(color, lineWidth: 2.5)
                    .frame(width: 14, height: 14)
            }
            .keylineTint(color)
        }
    }
}

/// The live clock. Counts up from the interval's start when running; freezes at the accumulated
/// figure when paused, since `timerInterval` has no notion of "stopped".
private struct ClockText: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        if state.isRunning {
            Text(timerInterval: state.startedAt...Date.distantFuture,
                 pauseTime: nil, countsDown: false)
        } else {
            Text(Format.duration(state.todaySecondsBeforeRun))
        }
    }
}

/// Today's total for this task. While running, the system ticks it from a start point pushed back
/// by whatever was already banked today — so the figure stays correct without the app updating it.
private struct TodayText: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        if state.isRunning {
            // Backdate the start by what's already banked today, so one system-ticked clock shows
            // the day's running total without the app pushing updates.
            let dayStart = state.startedAt.addingTimeInterval(-state.todaySecondsBeforeRun)
            HStack(spacing: 3) {
                Text("today")
                Text(timerInterval: dayStart...Date.distantFuture,
                     pauseTime: nil, countsDown: false)
                    .monospacedDigit()
            }
        } else {
            Text("today \(Format.compact(state.todaySecondsBeforeRun))")
        }
    }
}

/// Lock Screen / banner presentation. Wider than the island, so it can afford the task name and the
/// day total on one row.
private struct LockScreenView: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: state.colorHex))
                .frame(width: 5, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.taskName)
                    .font(.headline)
                    .lineLimit(1)
                TodayText(state: state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ClockText(state: state)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(Color(hex: state.colorHex))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
