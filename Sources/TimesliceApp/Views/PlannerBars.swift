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

/// The week as one bar, split at now: what's gone on the left, what's left on the right.
///
/// This replaced five detached figures — wanted, reserved, free, still to do, free hours left — which
/// were unreadable for a reason that had nothing to do with typography: they silently mixed two
/// different frames. "Free 112h" is the whole week; "free hours left 49.8h" is only the part still
/// coming. Two frames side by side, unlabelled, with no visual relationship, so the obvious question
/// was "free from what?".
///
/// One bar answers it. Its length is the week's waking hours, a line marks now, and each segment is
/// named underneath with its own figure — so every number on the page is visibly a piece of the same
/// whole rather than a fact from somewhere else.
struct WeekBudgetBar: View {
    /// Waking hours in the week: the bar's full length.
    let capacity: TimeInterval
    /// Waking hours that have already passed, tracked or not.
    let elapsed: TimeInterval
    /// Of the elapsed part, how much was actually recorded.
    let tracked: TimeInterval
    /// Still owed by the allocations.
    let stillToDo: TimeInterval
    /// Free hours on the days that remain — what catch-up can draw on.
    let freeLeft: TimeInterval
    /// Reserved hours in the remaining days, which are not available to anything.
    let reservedLeft: TimeInterval
    let over: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let scale = capacity > 0 ? geo.size.width / capacity : 0
                // Untracked elapsed time is real and unrecoverable, so it gets width like everything
                // else. Hiding it would make the bar shorter than the week.
                let untracked = max(0, elapsed - tracked)
                let claimed = min(stillToDo, freeLeft)
                let spare = max(0, freeLeft - stillToDo)
                HStack(spacing: 0) {
                    segment(tracked * scale, Color.accentColor, "tracked")
                    segment(untracked * scale, Color.secondary.opacity(0.22), "untracked")
                    segment(reservedLeft * scale, Color.secondary.opacity(0.38), "reserved")
                    segment(claimed * scale, over ? PlannerView.overColor : Color.orange, "to do")
                    segment(spare * scale, Color.primary.opacity(0.07), "spare")
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                // Now, as a hard line. Everything to its left is spent whatever the plan says.
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.75))
                        .frame(width: 1.5)
                        .offset(x: elapsed * scale)
                }
            }
            .frame(height: 18)

            // The same segments, named, in the same order. This is the breakdown the five loose
            // figures never showed.
            HStack(spacing: 14) {
                key(Color.accentColor, "tracked", tracked)
                key(Color.secondary.opacity(0.22), "untracked", max(0, elapsed - tracked))
                if reservedLeft > 60 { key(Color.secondary.opacity(0.38), "reserved", reservedLeft) }
                key(over ? PlannerView.overColor : Color.orange, "still to do", stillToDo)
                key(Color.primary.opacity(0.10), "spare", max(0, freeLeft - stillToDo))
                Spacer(minLength: 0)
            }
        }
    }

    private func segment(_ width: CGFloat, _ color: Color, _ id: String) -> some View {
        Rectangle().fill(color).frame(width: max(0, width))
    }

    private func key(_ color: Color, _ label: String, _ seconds: TimeInterval) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(hours(seconds))
                .font(.system(size: 10, weight: .medium, design: .monospaced)).monospacedDigit()
        }
    }

    private func hours(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        if h >= 10 { return "\(Int(h.rounded()))h" }
        if h >= 1 { return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h) }
        if seconds < 60 { return "0h" }
        return "\(Int((seconds / 60).rounded()))m"
    }
}
