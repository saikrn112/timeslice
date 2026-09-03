import SwiftUI
import TimesliceCore
import TimesliceUI

/// Elapsed time from `origin`, ticking, with hundredths — the in-app clock.
///
/// ## Why this exists rather than `Text(timerInterval:)`
///
/// `Text(timerInterval:pauseTime:countsDown:showsHours:)` is drawn and advanced by the SYSTEM, which is
/// exactly right for the Dynamic Island and Lock Screen: it keeps counting while this process is suspended
/// or dead. But its only formatting knob is `showsHours`, and there is no sub-second option — confirmed from
/// the SDK's own module interface. The smallest unit it will ever show is one whole second, and that's by
/// design: a text that updates without your process running can't tick at 100 Hz.
///
/// So sub-second display is possible ONLY where the app is on screen, which is here and nowhere else. The
/// island and the Lock Screen cannot have it, and pushing `Activity.update` faster doesn't help — those are
/// rate-limited, and an app that spent its update budget on hundredths would drain the battery it exists to
/// respect.
///
/// ## Why `TimelineView` rather than our own timer
///
/// This used a shared `Timer` at 10fps. `TimelineView(.animation)` produces the same output and is strictly
/// better: the system owns the cadence, and it **stops on its own** when the view scrolls off screen or the
/// app is backgrounded. A `Timer` runs until something explicitly cancels it, and `onDisappear` is not
/// guaranteed on backgrounding — so the old version could keep waking a suspended app to redraw a clock
/// nobody was looking at. In an app whose whole goal is to barely register, that's the wrong default.
///
/// 30 Hz, not 100: hundredths change faster than the eye resolves them, and the digit is equally legible at
/// a third of the wakeups.
struct LiveClockText: View {
    let origin: Date
    /// Off for figures that are read rather than watched, so they don't churn at 30 Hz.
    var showsHundredths = true

    var body: some View {
        TimelineView(.animation(minimumInterval: showsHundredths ? 1.0 / 30 : 1.0)) { context in
            // Always DERIVED from `context.date` minus the origin, never accumulated. A coalesced or missed
            // frame then costs nothing, where an incremented counter would drift permanently.
            let elapsed = max(0, context.date.timeIntervalSince(origin))
            Text(showsHundredths ? Format.durationHundredths(elapsed) : Format.duration(elapsed))
                .monospacedDigit()
        }
    }
}
