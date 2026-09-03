import SwiftUI
import TimesliceCore
import TimesliceUI

/// Week and month: one row per day, same idiom zoomed out.
///
/// The vertical calendar doesn't scale past a day — 31 of them is 31 screens. So zooming out changes the
/// GRANULARITY rather than the shape: still one row per unit of time, still carrying its own label, still
/// tappable to go deeper. A day row shows its total, its shape, and the task it mostly went into, which is the
/// same three facts a block carries.
///
/// Tapping a row drops into that day's canvas, so the only thing that ever changes is the zoom level. That's
/// what keeps this from being a second design bolted onto the first.
struct DayList: View {
    let digests: [DayDigest]
    let name: (Int64) -> String
    let colorHex: (Int64) -> String
    let onSelect: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(digests) { digest in
                Button { onSelect(digest.day) } label: {
                    DayListRow(digest: digest,
                               taskName: digest.topTaskID.map(name),
                               taskColor: digest.topTaskID.map(colorHex))
                }
                .buttonStyle(.plain)
                .disabled(digest.totalSeconds <= 0)
                if digest.id != digests.last?.id { Divider() }
            }
        }
    }
}

private struct DayListRow: View {
    let digest: DayDigest
    let taskName: String?
    let taskColor: String?

    private var isEmpty: Bool { digest.totalSeconds <= 0 }

    var body: some View {
        HStack(spacing: 12) {
            // Weekday above date: scanning a month you look for "which Tuesday", not for the number.
            VStack(alignment: .leading, spacing: 0) {
                Text(digest.day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isEmpty ? .tertiary : .secondary)
                Text(digest.day.formatted(.dateTime.day()))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isEmpty ? .tertiary : .primary)
            }
            .frame(width: 34, alignment: .leading)

            Text(isEmpty ? "—" : Format.compact(digest.totalSeconds))
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(isEmpty ? .tertiary : .primary)
                .frame(width: 62, alignment: .leading)

            DayShape(hourFill: digest.hourFill, tint: taskColor.map { Color(hex: $0) })
                .frame(height: 18)

            if let taskName {
                Text(taskName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)
            } else {
                Spacer().frame(width: 96)
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// The day's shape: 24 columns, each as tall as that hour was full.
///
/// Not a single bar of total time. Two days can both total six hours with one worked in a block and the other
/// scattered across twelve, and the shape is the only thing that distinguishes them — which is precisely what a
/// day row is for. A total is already in the column beside it.
struct DayShape: View {
    let hourFill: [Double]
    /// The day's dominant task colour, so the row reads as belonging to something. Grey when the day is empty.
    let tint: Color?

    var body: some View {
        GeometryReader { geo in
            let columnWidth = geo.size.width / 24
            HStack(alignment: .bottom, spacing: 0.5) {
                ForEach(Array(hourFill.enumerated()), id: \.offset) { _, fill in
                    Rectangle()
                        .fill(fill > 0 ? (tint ?? Theme.metricNeutralFill) : Theme.metricTrack)
                        // A worked hour never renders as nothing: below about 8% the bar would round away and
                        // a real hour would look untracked.
                        .frame(width: max(1, columnWidth - 0.5),
                               height: fill > 0 ? max(3, geo.size.height * fill) : 2)
                }
            }
            .frame(height: geo.size.height, alignment: .bottom)
        }
    }
}

/// A name, a duration and a proportional bar — for the breakdown detail.
///
/// Lives here beside `DayShape` because both answer "how does this compare to its peers", and both take the
/// subject's own colour as the only saturated thing in the row.
struct BreakdownBar: View {
    let name: String
    let seconds: TimeInterval
    let fraction: Double
    let colorHex: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: colorHex)).frame(width: 10, height: 10)
            Text(name).font(Theme.metricLabel).lineLimit(1)
            Spacer(minLength: 8)
            Text(Format.compact(seconds))
                .font(Theme.metricTime)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.metricTrack)
                    Capsule().fill(Color(hex: colorHex))
                        .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(width: 60, height: 8)
        }
    }
}
