import SwiftUI
import TimesliceUI

/// A time label that ticks live by observing the shared TickClock. Isolating clock observation
/// here means only this small text re-renders at the tick rate — not the enclosing list/charts.
struct LiveTimeText: View {
    @ObservedObject var clock: TickClock
    /// Committed base seconds (closed intervals). The live session is added when `isRunning`.
    let base: TimeInterval
    let isRunning: Bool
    let showMs: Bool
    var color: Color = .primary

    var body: some View {
        let seconds = base + (isRunning ? clock.elapsed : 0)
        Text(showMs ? Format.durationMs(seconds) : Format.duration(seconds))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}
