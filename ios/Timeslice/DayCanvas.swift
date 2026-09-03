import SwiftUI
import TimesliceCore
import TimesliceUI

/// The day, down the phone's long axis: blocks and the gaps between them, in order.
///
/// ## Why vertical
///
/// The Mac draws a day as a 0–24 strip across the window. Squeezed into 390pt each block gets a few pixels of
/// width — which is exactly why the Mac page needs a colour LEGEND: the blocks are too small to hold their own
/// labels, so the names live elsewhere and your eye does the join.
///
/// Turned vertical, a block is as tall as it is long and carries its own name, times and duration. No legend, no
/// colour matching, nothing a tap away — the full day, labelled, in one view. That's the Mac's "everything at
/// once" translated rather than shrunk. Gaps read as gaps too, where a horizontal strip renders untracked time as
/// indistinguishable background.
///
/// ## Why a stack rather than a coordinate grid
///
/// The first attempt placed blocks by absolute offset against an hour gutter, like a calendar. It cost two bugs
/// in a row — every block pushed off-canvas by a sign error, then a screen of blank space — because each block's
/// position depended on the grid origin, the visible hour range and the flow adjustment all agreeing.
///
/// A stack has no coordinates to get wrong. Time proportionality lives in the HEIGHTS: a block is as tall as its
/// duration (floored, so a two-minute block is still legible) and a gap is as tall as the time it represents. The
/// hour gutter is gone, and it was redundant — every block prints its own clock span, so the gutter was a second,
/// weaker copy of what's already on screen.
struct DayCanvas: View {
    let segments: [DaySegment]
    let day: Date
    /// Resolved by the caller through `Palette.displayColorHex`, so the phone paints a task exactly as the Mac
    /// does and this view never derives a colour.
    let colorHex: (Int64) -> String
    let name: (Int64) -> String
    let deviceLabel: (String?) -> String?
    /// The open interval's id, so the growing block can say so. `DaySegment` carries no running flag — it's a
    /// projection of an interval onto a day, and whether that interval is open is the store's business.
    let runningIntervalID: Int64?
    let onDelete: (MergedBlock) -> Void
    let onInspect: (MergedBlock) -> Void

    /// Points per hour, for turning a duration into a height.
    private static let hourHeight: Double = 150
    /// Floor for a block, so a short one still fits a name and a duration.
    ///
    /// Real data forced this: 35 blocks in a day, many under 15 minutes, which at any honest scale are a few
    /// points tall and collapse into unreadable mush.
    private static let minBlockHeight: Double = 34
    /// Floor and ceiling for a gap — enough to read as a break, not enough for an eight-hour night to own the
    /// screen.
    private static let minGapHeight: Double = 22
    private static let maxGapHeight: Double = 56

    /// Merged, in time order.
    ///
    /// Merging matters because `rollOpenInterval` deliberately splits a long run into focus-length chunks, and
    /// returning to a task produces neighbours. Rendered separately, two hours of work becomes thirty slivers —
    /// accurate about the storage, wrong about the activity.
    private var blocks: [MergedBlock] {
        Aggregations.mergeAdjacent(segments).sorted { $0.startHour < $1.startHour }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                switch row.kind {
                case .gap(let hours):
                    GapRow(hours: hours, height: gapHeight(hours))
                case .block(let block):
                    DayBlock(block: block,
                             height: blockHeight(block),
                             colorHex: colorHex(block.projectID),
                             name: name(block.projectID),
                             device: deviceLabel(block.deviceID),
                             isRunning: block.intervalIDs.contains { $0 == runningIntervalID },
                             onDelete: { onDelete(block) },
                             onInspect: { onInspect(block) })
                }
            }
        }
    }

    /// A row is either a block or the untracked stretch before it.
    private struct Row: Identifiable {
        enum Kind {
            case gap(hours: Double)
            case block(MergedBlock)
        }
        let id: String
        let kind: Kind
    }

    /// Blocks, with gaps interleaved.
    ///
    /// Gaps below the threshold are dropped rather than drawn: every task switch leaves a second or two, and
    /// "untracked 3s" between every pair would bury the real holes. Twelve minutes is long enough to be a break
    /// rather than the cost of switching.
    private var rows: [Row] {
        var out: [Row] = []
        var cursor: Double?
        for block in blocks {
            if let cursor, block.startHour - cursor >= 12.0 / 60 {
                out.append(Row(id: "gap-\(block.id)", kind: .gap(hours: block.startHour - cursor)))
            }
            out.append(Row(id: "block-\(block.id)", kind: .block(block)))
            cursor = max(cursor ?? block.endHour, block.endHour)
        }
        return out
    }

    private func blockHeight(_ block: MergedBlock) -> Double {
        max(Self.minBlockHeight, (block.endHour - block.startHour) * Self.hourHeight)
    }

    private func gapHeight(_ hours: Double) -> Double {
        min(Self.maxGapHeight, max(Self.minGapHeight, hours * Self.hourHeight))
    }
}

/// Untracked time, named.
///
/// A labelled break rather than empty space, because untracked time is what you came to find — a hole you can see
/// and measure is what tells you a timer was never started.
private struct GapRow: View {
    let hours: Double
    let height: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("untracked \(Format.compact(hours * 3600))")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1)
        }
        .frame(height: height)
    }
}

/// One tracked block, carrying its own label.
///
/// The label lives INSIDE the block, which is why this design needs no legend. Text sits on a tinted card beside a
/// full-strength colour spine rather than on the colour itself: most of the palette fails contrast as text, and
/// the spine carries identity so the label doesn't have to.
private struct DayBlock: View {
    let block: MergedBlock
    let height: Double
    let colorHex: String
    let name: String
    let device: String?
    let isRunning: Bool
    let onDelete: () -> Void
    let onInspect: () -> Void

    /// Below this there's no room for a second line.
    private var isTight: Bool { height < 46 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: colorHex))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    if isRunning {
                        // Named rather than implied: a block still growing is the one you must not mistake for a
                        // finished one when deciding what to delete.
                        Text("running")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 4)
                    Text(Format.compact(block.seconds))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !isTight {
                    HStack(spacing: 5) {
                        Text(clockSpan)
                        // Says when a block is several chunks of one run, so merging isn't a silent rewrite of
                        // the database — and deleting it removes all of them.
                        if block.chunkCount > 1 { Text("· \(block.chunkCount) chunks") }
                        if let device { Text("· \(device)") }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, isTight ? 6 : 8)
            .padding(.trailing, 10)
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                // A tint, not the colour: a saturated fill behind text is where legibility dies, and the spine
                // already carries identity at full strength.
                .fill(Color(hex: colorHex).opacity(0.18))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onInspect)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label(block.chunkCount > 1 ? "Delete all \(block.chunkCount) chunks" : "Delete block",
                      systemImage: "trash")
            }
        }
    }

    /// `9:18–10:04`. The times, not just the duration — which is also what makes an hour gutter unnecessary.
    private var clockSpan: String {
        func hm(_ hour: Double) -> String {
            let h = Int(hour), m = Int((hour - Double(h)) * 60)
            return String(format: "%d:%02d", h, m)
        }
        return "\(hm(block.startHour))–\(hm(block.endHour))"
    }
}
