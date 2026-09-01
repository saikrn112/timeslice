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

                        // THE SWITCHER, in the island. Expanding the island and tapping a task starts
                        // it without ever opening the app — the friction this app has most of is
                        // switching, and this is the shortest path to it that iOS allows.
                        //
                        // Buttons rather than the flashlight-style control you pointed at: that is a
                        // system control, and a third-party Live Activity gets intent-backed buttons
                        // only — no sliders, no drags, no gestures.
                        if !context.state.recents.isEmpty {
                            SwitcherRow(recents: context.state.recents)
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

/// A row of one-press task buttons — the switcher, living in the Live Activity.
///
/// Each button carries the task's **uid**, not its row id: a widget serialises the intent and its
/// parameters into the tap, the payload can outlive a sync, and `subject_id = 8` is a different task on
/// another device. An unrecognised uid resolves to nothing rather than starting the wrong timer.
///
/// The label is the task's colour put through `Theme.legibleText`, because most of the palette is
/// unreadable as text — the island is near-black, and a dark task colour on it disappears. The chip's
/// fill keeps the true colour, so identity still comes from the colour even though the text is adjusted.
private struct SwitcherRow: View {
    let recents: [TimerActivityAttributes.RecentTask]
    /// The island is always near-black; the Lock Screen card composites over wallpaper and is treated
    /// the same way, since its own background is a dark tint.
    var dark: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            // Three at most. Beyond that the labels truncate to the point of being unidentifiable,
            // which is worse than not offering the button.
            ForEach(recents.prefix(3)) { task in
                Button(intent: SwitchToTaskIntent(taskUID: task.uid)) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: task.colorHex))
                            .frame(width: 7, height: 7)
                        Text(task.name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.legibleText(task.colorHex, dark: dark))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(hex: task.colorHex).opacity(0.22)))
                }
                .buttonStyle(.plain)
            }
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
            // `showsHours` matched to the magnitude: `44:45` under an hour, `1:04:45` above it, rather
            // than a permanent `0:` prefix eating the island's scarcest resource. It's the only
            // precision knob the API has — see `TimerDisplay.showsHours`.
            Text(timerInterval: state.liveOrigin...Date.distantFuture,
                 pauseTime: nil, countsDown: false, showsHours: state.showsHours)
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
        VStack(alignment: .leading, spacing: 10) {
            header
            // NO switcher here, deliberately. The Lock Screen is a status surface — it should answer
            // "what am I on and for how long", and a row of OTHER tasks turned it into a menu of things
            // you aren't doing. Pause/resume and previous stay, because those act on the current task.
            // The switcher lives in the expanded island, which you open on purpose.
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var header: some View {
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
    }
}
