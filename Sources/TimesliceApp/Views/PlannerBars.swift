import SwiftUI
import TimesliceCore

/// Done against a target: a filled portion, and the shortfall left hollow.
///
/// Used by both the today card and every matrix row, so progress reads the same wherever it appears.
///
/// The gap is the lag, drawn rather than described — a number beside it would be saying the same thing
/// twice.
struct ProgressPair: View {
    let done: TimeInterval
    let total: TimeInterval
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(1, done / total) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                Capsule().fill(tint).frame(width: max(2, geo.size.width * fraction))
            }
        }
    }
}
