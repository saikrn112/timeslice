import SwiftUI
import TimesliceUI

/// A time label that ticks live by observing the shared TickClock. Isolating clock observation
/// here means only this small text re-renders at the tick rate — not the enclosing list/charts.
struct LiveTimeText: View {
    @ObservedObject var clock: TickClock
    /// Committed base seconds (closed intervals). The live part is added when `isRunning`.
    let base: TimeInterval
    let isRunning: Bool
    /// Which live part. No default on purpose: `.session` on top of a closed total double-counts every
    /// block the session has rolled into, so each caller has to say what its base already includes.
    let live: Live
    enum Live { case session, today, unrecorded }
    let showMs: Bool
    var color: Color = .primary

    private var extra: TimeInterval {
        switch live {
        case .session: clock.elapsed
        case .today: clock.unrecordedToday
        case .unrecorded: clock.unrecorded
        }
    }

    var body: some View {
        let seconds = base + (isRunning ? extra : 0)
        Text(showMs ? Format.durationMs(seconds) : Format.duration(seconds))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}
