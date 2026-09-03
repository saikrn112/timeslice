import SwiftUI
import TimesliceCore
import TimesliceUI

/// The day's blocks against a 0–24 axis.
///
/// Positioned by hour fraction rather than drawn with Swift Charts: the blocks, the device band and the axis
/// all have to line up to the pixel, and three charts sharing a scale is more fragile than three views sharing
/// one width.
struct TimelineStrip: View {
    let segments: [DaySegment]
    let lanes: Int
    let colorHex: (Int64) -> String
    let onTap: (DaySegment) -> Void

    /// A lane exists only where blocks genuinely OVERLAP. One lane per device looked like concurrency that
    /// never happened — only one timer runs across all devices, so overlap means a sync race, not parallel
    /// work.
    private var laneHeight: CGFloat { lanes > 1 ? max(18, 72 / CGFloat(lanes)) : 36 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach([6, 12, 18], id: \.self) { hour in
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(width: 0.5, height: geo.size.height)
                        .offset(x: w * CGFloat(hour) / 24)
                }
                ForEach(segments) { seg in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: colorHex(seg.projectID)))
                        .frame(width: max(2, w * CGFloat((seg.endHour - seg.startHour) / 24)),
                               height: max(4, laneHeight - 2))
                        .offset(x: w * CGFloat(seg.startHour / 24),
                                y: CGFloat(seg.lane) * (laneHeight + 2))
                        .onTapGesture { onTap(seg) }
                }
            }
        }
        .frame(height: CGFloat(lanes) * (laneHeight + 2))
    }
}

/// Which device recorded what, as a thin band on the same axis.
///
/// A band rather than a pie or a ring: attribution is a second dimension of the same timeline, so the strip
/// stays "what I did" and this row is "where", read against each other. A circular chart throws away the time
/// axis, which is the only thing that makes this legible.
struct DeviceBand: View {
    let segments: [DaySegment]
    let devices: [String?]

    var body: some View {
        let index = Dictionary(uniqueKeysWithValues: devices.enumerated().map { ($1 ?? "", $0) })
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.metricTrack).frame(height: 6)
                ForEach(segments) { seg in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.deviceColor(index[seg.deviceID ?? ""] ?? 0))
                        .frame(width: max(2, w * CGFloat((seg.endHour - seg.startHour) / 24)),
                               height: 6)
                        .offset(x: w * CGFloat(seg.startHour / 24))
                }
            }
        }
        .frame(height: 6)
    }
}

/// Names the band's colours and totals each device.
///
/// Indexed off the same `orderedDevices` array the band uses, which is id-sorted — a label order that differed
/// from the band's would make "device 1" a different machine on each.
struct DeviceLegend: View {
    let segments: [DaySegment]
    let devices: [String?]
    let labels: [String: String]

    var body: some View {
        let byDevice = Dictionary(grouping: segments, by: { $0.deviceID })
        FlowRow(spacing: 10) {
            ForEach(Array(devices.enumerated()), id: \.offset) { index, device in
                let secs = (byDevice[device] ?? []).reduce(0.0) {
                    $0 + ($1.endHour - $1.startHour) * 3600
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.deviceColor(index))
                        .frame(width: 10, height: 6)
                    Text(device.flatMap { labels[$0] } ?? device ?? "unattributed")
                        .font(Theme.metricCaption).foregroundStyle(.secondary)
                    Text(Format.compact(secs))
                        .font(Theme.metricCaption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// `12a 3a 6a 9a 12p 3p 6p 9p`. Bare 0/6/12/18 read as an index rather than a time of day.
struct HourAxis: View {
    var body: some View {
        HStack(spacing: 0) {
            ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { h in
                Text(label(h))
                    .font(Theme.metricCaption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: h == 0 ? .leading : .center)
            }
        }
    }

    private func label(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case ..<12: return "\(hour)a"
        default: return "\(hour - 12)p"
        }
    }
}

/// A wrapping row, for the device legend — a plain `HStack` clips once there are more than a few entries, and
/// `LazyVGrid` would force a column grid onto labels of very different widths.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
