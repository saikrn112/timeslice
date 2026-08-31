import ActivityKit
import SwiftUI
import TimesliceIntents
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
                        .foregroundStyle(clockColor(context.state))
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
                        // Buttons, not gestures: a Live Activity hosts App Intents only, so this is
                        // the entire available vocabulary. The types come from `TimesliceIntents`,
                        // which the app links too — an earlier version compiled a copy into each
                        // target and shipped two conflicting AppIntents metadata bundles.
                        HStack(spacing: 8) {
                            Button(intent: ToggleFromActivityIntent()) {
                                Label(context.state.isRunning ? "Pause" : "Resume",
                                      systemImage: context.state.isRunning ? "pause.fill" : "play.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(context.state.isRunning ? .orange : .green)
                            Button(intent: PreviousTaskIntent()) {
                                Label("Previous", systemImage: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Circle().fill(color).frame(width: 9, height: 9)
            } compactTrailing: {
                ClockText(state: context.state)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(clockColor(context.state))
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

/// Colour for the clock digits.
///
/// **Green while running**, not the task's colour. A pale task colour — a light blue, a pale yellow —
/// is barely legible against the island's black, and green is the established system convention for
/// "actively recording" that every timer and voice-memo app uses. The task's own colour still carries
/// identity, on the swatch and the keyline, where legibility doesn't depend on it.
///
/// Paused digits go secondary, so a frozen number doesn't read as live.
private func clockColor(_ state: TimerActivityAttributes.ContentState) -> Color {
    state.isRunning ? .green : .secondary
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

/// Lock Screen / banner presentation, with controls.
///
/// The buttons are the point: pausing from the Lock Screen means never unlocking the phone to stop a
/// timer, which is the whole reason a Live Activity beats a notification. A Live Activity can host
/// App Intents only — no gestures, no scroll views — so buttons are the entire available vocabulary.
private struct LockScreenView: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: state.colorHex))
                .frame(width: 5, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.taskName)
                    .font(.headline)
                    .lineLimit(1)
                SessionText(state: state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            ClockText(state: state)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(clockColor(state))

            // Pause/resume, then "previous task" — the two things worth doing without unlocking.
            Button(intent: ToggleFromActivityIntent()) {
                Image(systemName: state.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(state.isRunning ? Color.orange : Color.green))
            .foregroundStyle(.white)
            .clipShape(Circle())

            Button(intent: PreviousTaskIntent()) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(Color.secondary.opacity(0.25)))
            .clipShape(Circle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
