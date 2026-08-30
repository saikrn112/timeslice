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
                    VStack(spacing: 6) {
                        HStack {
                            Label(context.state.isRunning ? "Tracking" : "Paused",
                                  systemImage: context.state.isRunning ? "record.circle" : "pause.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            // The session, since the big clock is already today's total — the two
                            // together answer "how long on this?" and "how much today?".
                            SessionText(state: context.state)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        // NOTE: the pause/previous buttons were removed here on purpose.
                        //
                        // `Button(intent:)` needs the intent TYPE visible to this extension, which
                        // meant compiling the intents into both targets. That shipped TWO AppIntents
                        // metadata bundles declaring the same identifiers — the app's (with an
                        // AppShortcutsProvider) and the extension's (without one) — and shortcut
                        // resolution could bind to the extension, failing with
                        // "Couldn't find AppShortcutsProvider." That broke the ACTION BUTTON, which
                        // matters more than buttons inside the island.
                        //
                        // Restoring them properly means hoisting the intent types into a library both
                        // targets link (one type, one registration) with the app supplying the
                        // behaviour — not duplicating them per target.
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

/// The clock: **today's total for this task**, ticking — matching what the Mac's menu bar and task
/// list show, which is `committed base + live elapsed` rather than the current session alone.
///
/// Showing only the session was the original bug: switching tasks made the number visibly collapse
/// to zero instead of continuing the day's total, which reads as the timer having been reset.
///
/// Frozen at the committed figure when paused, since `timerInterval` has no notion of "stopped".
private struct ClockText: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        if state.isRunning {
            Text(timerInterval: state.liveOrigin...Date.distantFuture,
                 pauseTime: nil, countsDown: false)
        } else {
            Text(Format.duration(state.committedTodaySeconds))
        }
    }
}

/// The CURRENT SESSION, as the secondary figure — the main clock is already today's total, so
/// repeating it here would waste the island's most limited resource. Together they answer both
/// "how long have I been on this?" and "how much today?", which is the pair the Mac shows too.
private struct SessionText: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        if state.isRunning {
            HStack(spacing: 3) {
                Text("session")
                Text(timerInterval: state.startedAt...Date.distantFuture,
                     pauseTime: nil, countsDown: false)
                    .monospacedDigit()
            }
        } else {
            Text("paused · today \(Format.compact(state.committedTodaySeconds))")
        }
    }
}

/// Lock Screen / banner presentation. Wider than the island, so it can afford the task name, the
/// day total, and the session all on one row.
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
                SessionText(state: state)
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
