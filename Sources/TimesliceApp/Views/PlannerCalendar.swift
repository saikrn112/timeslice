import SwiftUI
import TimesliceCore
import TimesliceUI

/// The week as a calendar: seven day columns against a real clock, with what actually happened drawn
/// solid and what still has to happen drawn hatched into the gaps between.
///
/// Every earlier version of this page asked you to *read* whether the week was possible — a verdict, a
/// budget bar, a grid of totals. A calendar answers it by construction. What was tracked sits at the
/// time it happened; what an allocation still owes has no time yet, so it gets packed into whatever
/// room is left (`CalendarLayout.pack`). If it fits, the column looks full. If it doesn't, the leftover
/// has nowhere to be drawn and the column says so in red. The geometry IS the argument, so no sentence
/// has to make it.
///
/// Two consequences worth naming, because they were the previous versions' hardest problems:
///
/// - **The clock is free.** At 23:00 today's column is almost entirely behind the now-line, so the
///   hatched hours left in it are visibly not going to happen. Nothing needed to be added for this.
/// - **Catch-up is visible.** Hours missed on Monday show up as hatching pushed into Thursday and
///   Friday, because the packer only has the remaining days to work with.
struct PlannerCalendar: View {
    /// One day, with what is known about it. Gaps and packing happen here rather than in the caller,
    /// so the drawing and the feasibility can't disagree.
    struct DayInput: Identifiable {
        let weekday: Int
        let label: String          // "Mon"
        let dayOfMonth: Int
        let isPast: Bool
        let isToday: Bool
        /// Declared non-negotiables for this weekday. No times exist for them, so they're drawn as a
        /// tray at the top of the column — the same convention a calendar's all-day row uses.
        let reservedHours: Double
        let tracked: [TrackedBlock]
        /// What each allocation still owes on this day, worst-lag first. Empty for days that have gone.
        let owed: [OwedItem]
        var id: Int { weekday }
    }

    struct TrackedBlock: Identifiable {
        let id: Int64
        let startHour: Double
        let endHour: Double
        let name: String
        let colorHex: String
        /// nil when no allocation covers it — real hours that count for nothing you planned.
        let targetID: Int64?
    }

    struct OwedItem: Identifiable {
        let id: Int64
        let name: String
        let hours: Double
        let colorHex: String
    }

    let days: [DayInput]
    /// Hours since midnight for the now-line. Only drawn on today's column.
    let nowHour: Double
    /// Dim everything that isn't this allocation. nil shows all.
    let highlight: Int64?
    var onPick: (Int64) -> Void = { _ in }

    /// The visible band, 08:00 → 02:00 next day.
    ///
    /// Chosen from the data rather than from taste: across the last two months every tracked hour but
    /// twelve falls inside it, and a 0–24 axis spends a fifth of its height on hours nothing ever
    /// happens in. Late-evening work crossing midnight lands at the bottom of the day it belongs to,
    /// which is where you'd look for it.
    static let bandStart: Double = 8
    static let bandEnd: Double = 26
    private static var bandHours: Double { bandEnd - bandStart }
    private static let hourHeight: CGFloat = 22
    private static let axisWidth: CGFloat = 34

    private var band: CalendarLayout.Span {
        CalendarLayout.Span(start: Self.bandStart, end: Self.bandEnd)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            axis
            ForEach(days) { day in
                column(day)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Axis

    private var axis: some View {
        VStack(spacing: 0) {
            // Aligns with the day headers opposite.
            Color.clear.frame(height: 22)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(hourMarks.enumerated()), id: \.offset) { _, hour in
                    Text(Self.hourLabel(hour))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .offset(x: 0, y: y(for: hour) - 5)
                }
            }
            .frame(height: CGFloat(Self.bandHours) * Self.hourHeight)
        }
        .frame(width: Self.axisWidth, alignment: .leading)
    }

    private var hourMarks: [Double] {
        stride(from: Self.bandStart, through: Self.bandEnd, by: 2).map { $0 }
    }

    static func hourLabel(_ hour: Double) -> String {
        let h = Int(hour.rounded()) % 24
        if h == 0 { return "12a" }
        if h == 12 { return "12p" }
        return h < 12 ? "\(h)a" : "\(h - 12)p"
    }

    private func y(for hour: Double) -> CGFloat {
        CGFloat(hour - Self.bandStart) * Self.hourHeight
    }

    private func height(_ hours: Double) -> CGFloat {
        max(1, CGFloat(hours) * Self.hourHeight)
    }

    // MARK: - One day

    private func column(_ day: DayInput) -> some View {
        let layout = self.layout(day)
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                Text(day.label)
                    .font(.system(size: 10, weight: day.isToday ? .bold : .regular))
                Text("\(day.dayOfMonth)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(day.isToday ? Color.accentColor
                             : (day.isPast ? Color.secondary.opacity(0.6) : .secondary))
            .frame(height: 22)

            ZStack(alignment: .topLeading) {
                background(day)
                blocks(day, layout)
                // What had nowhere to go. The one thing a calendar can't draw in place, so it's drawn
                // at the bottom edge as an overflow — the visual equivalent of a column that spills.
                if layout.overflow > 0.02 {
                    overflowMarker(layout.overflow)
                }
                if day.isToday, nowHour >= Self.bandStart, nowHour <= Self.bandEnd {
                    nowLine
                }
            }
            .frame(height: CGFloat(Self.bandHours) * Self.hourHeight)
            .clipped()
        }
        .padding(.horizontal, 1)
    }

    private struct DayLayout {
        var reserved: CalendarLayout.Span?
        var ghosts: [(item: OwedItem, span: CalendarLayout.Span)] = []
        var overflow: Double = 0
    }

    /// Reserved first, then what was tracked, then the owed hours into whatever is left.
    ///
    /// That order is the whole model: non-negotiables are gone before anything competes, the past is
    /// not negotiable either, and allocations get the remainder. For today, everything before the
    /// now-line is treated as busy whether or not it was tracked — an hour that has passed is not a
    /// place you can still put something, and pretending otherwise is what made the old page read the
    /// same at 9am and at 11pm.
    private func layout(_ day: DayInput) -> DayLayout {
        var out = DayLayout()
        var busy: [CalendarLayout.Span] = []

        if day.reservedHours > 0.02 {
            let span = CalendarLayout.Span(start: Self.bandStart,
                                           end: Self.bandStart + day.reservedHours)
            out.reserved = span
            busy.append(span)
        }
        busy += day.tracked.map { CalendarLayout.Span(start: $0.startHour, end: $0.endHour) }
        if day.isToday {
            busy.append(CalendarLayout.Span(start: Self.bandStart, end: max(Self.bandStart, nowHour)))
        }

        guard !day.owed.isEmpty else { return out }
        let gaps = CalendarLayout.gaps(band: band, busy: busy)
        let packed = CalendarLayout.pack(day.owed.map { CalendarLayout.Item(id: $0.id, hours: $0.hours) },
                                         into: gaps)
        let byID = Dictionary(uniqueKeysWithValues: day.owed.map { ($0.id, $0) })
        out.ghosts = packed.pieces.compactMap { piece in
            byID[piece.id].map { ($0, piece.span) }
        }
        out.overflow = packed.unplaced.values.reduce(0, +)
        return out
    }

    private func background(_ day: DayInput) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(day.isToday ? Color.accentColor.opacity(0.05)
                      : Color.primary.opacity(day.isPast ? 0.02 : 0.035))
            // Two-hourly rules, so a block's position is readable without tracing to the axis.
            ForEach(Array(hourMarks.enumerated()), id: \.offset) { _, hour in
                Rectangle().fill(Color.primary.opacity(hour == 24 ? 0.16 : 0.06))
                    .frame(height: hour == 24 ? 1 : 0.5)
                    .offset(y: y(for: hour))
            }
        }
    }

    @ViewBuilder
    private func blocks(_ day: DayInput, _ layout: DayLayout) -> some View {
        // Reserved: a tray, not an event. Hatched so it never reads as something you did.
        if let reserved = layout.reserved {
            Hatch(color: .secondary)
                .frame(height: height(reserved.hours))
                .overlay(alignment: .topLeading) {
                    Text("reserved").font(.system(size: 8))
                        .foregroundStyle(.secondary).padding(2)
                }
                .offset(y: y(for: reserved.start))
        }

        // What actually happened, where it happened.
        ForEach(day.tracked) { block in
            trackedBlock(block)
        }

        // What still has to fit, in the room that's left.
        ForEach(Array(layout.ghosts.enumerated()), id: \.offset) { _, ghost in
            ghostBlock(ghost.item, ghost.span)
        }
    }

    /// An owed hour with a place to be, but no commitment behind it — hence dashed rather than filled.
    /// Extracted because the type-checker gave up on it inside the ForEach.
    private func ghostBlock(_ item: OwedItem, _ span: CalendarLayout.Span) -> some View {
        let tint = Color(hex: item.colorHex)
        let dimmed: Bool = highlight != nil && highlight != item.id
        return RoundedRectangle(cornerRadius: 3)
            .fill(tint.opacity(0.16))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(tint.opacity(0.75),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .frame(height: height(span.hours))
            .overlay(alignment: .topLeading) {
                if span.hours > 0.55 {
                    Text(item.name)
                        .font(.system(size: 9))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .padding(.horizontal, 3).padding(.top, 1)
                }
            }
            .opacity(dimmed ? 0.15 : 1)
            .offset(y: y(for: span.start))
            .help("\(item.name) — still to fit here")
            .onTapGesture { onPick(item.id) }
    }

    /// An hour that really happened, at the time it happened. Solid, because it is not a proposal.
    private func trackedBlock(_ block: TrackedBlock) -> some View {
        let tint = Color(hex: block.colorHex)
        let unallocated: Bool = block.targetID == nil
        let dimmed: Bool = highlight != nil && highlight != block.targetID
        let hours: Double = block.endHour - block.startHour
        return RoundedRectangle(cornerRadius: 3)
            .fill(tint.opacity(unallocated ? 0.30 : 0.92))
            .frame(height: height(hours))
            .overlay(alignment: .topLeading) {
                if hours > 0.55 {
                    Text(block.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(unallocated ? Color.secondary : Color.white)
                        .lineLimit(1)
                        .padding(.horizontal, 3).padding(.top, 1)
                }
            }
            .opacity(dimmed ? 0.18 : 1)
            .offset(y: y(for: block.startHour))
            .help(blockTooltip(block))
            .onTapGesture { if let id = block.targetID { onPick(id) } }
    }

    private func blockTooltip(_ block: TrackedBlock) -> String {
        let span = "\(Self.hourLabel(block.startHour))–\(Self.hourLabel(block.endHour))"
        let length = Self.short(block.endHour - block.startHour)
        return "\(block.name)\n\(span) · \(length)"
            + (block.targetID == nil ? "\nnot covered by any allocation" : "")
    }

    private func overflowMarker(_ hours: Double) -> some View {
        VStack {
            Spacer(minLength: 0)
            Text("+\(Self.short(hours)) no room")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .frame(maxWidth: .infinity)
                .background(PlannerView.overColor)
        }
        .help("\(Self.short(hours)) of what these allocations want has nowhere to go on this day.")
    }

    private var nowLine: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(PlannerView.overColor).frame(height: 1.5)
            Circle().fill(PlannerView.overColor).frame(width: 5, height: 5).offset(x: -2)
        }
        .offset(y: y(for: nowHour))
    }

    static func short(_ hours: Double) -> String {
        if hours >= 1 { return hours == hours.rounded() ? "\(Int(hours))h"
                               : String(format: "%.1fh", hours) }
        return "\(Int((hours * 60).rounded()))m"
    }
}

/// Diagonal hatching. Used for reserved time, which is neither something you did nor something you can
/// still choose to do, and so should look like neither.
struct Hatch: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                var path = Path()
                let step: CGFloat = 5
                var x = -size.height
                while x < size.width + size.height {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += step
                }
                context.stroke(path, with: .color(color.opacity(0.30)), lineWidth: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(color.opacity(0.06))
    }
}
