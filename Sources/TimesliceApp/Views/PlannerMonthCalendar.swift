import SwiftUI
import TimesliceCore
import TimesliceUI

/// The month as a month calendar, with every cell carrying a verdict.
///
/// A first version of this was thirty anonymous stacks of stripes — it looked like a calendar and said
/// almost nothing. A second version replaced it with an allocations × weeks matrix, which was informative
/// and didn't feel like a calendar at all.
///
/// So: the calendar, made to answer. Each cell is a day container filled from the floor exactly as the
/// week columns are, plus the two things that turn a picture into a judgement:
///
/// - a **target line** where the day's allocations wanted it to reach, so a short day is visibly short and
///   a day that went past its plan is visibly past it — no text needed, and it works at 95pt wide;
/// - the **biggest thing you did**, named, because "8.1h" says how much and nothing about what.
///
/// Reading down a column answers "Tuesdays are where it goes wrong". Reading across a row answers "that
/// week was thin". Both were the point of having a month view.
struct PlannerMonthCalendar: View {
    struct Slice: Identifiable {
        let id: Int64            // allocation id, or a negative sentinel for unallocated
        let name: String
        let hours: Double
        let colorHex: String
    }

    struct DayCell: Identifiable {
        let date: Date
        let dayOfMonth: Int
        /// False for the leading and trailing days that complete the first and last rows.
        let inMonth: Bool
        let isToday: Bool
        let isPast: Bool
        /// Hours not available to plan with on this weekday.
        let unavailableHours: Double
        /// Tracked hours by allocation, largest first.
        let tracked: [Slice]
        /// What this weekday's allocations add up to wanting.
        let wantedHours: Double
        var id: Date { date }
    }

    let weeks: [[DayCell]]
    let capacityHours: Double
    let highlight: Int64?
    var onPick: (Int64) -> Void = { _ in }
    var onOpen: (Date) -> Void = { _ in }

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let cubeGap: CGFloat = 2
    private static let headerHeight: CGFloat = 13
    private static let cellPadding: CGFloat = 5

    /// Hours in the longest day of the month, which is what the grid has to be able to hold.
    ///
    /// Taken from the data rather than assumed, because the waking day is a setting: at 5h a single row of
    /// cubes is right and two would be an empty half; at 24h three rows are needed. A fixed layout left a
    /// band of dead space under every cell at 14h and would have squashed the cubes at 24h.
    private var hoursInLongestDay: Int {
        let longest = weeks.flatMap { $0 }
            .map { capacityHours - $0.unavailableHours }
            .max() ?? capacityHours
        return Int(max(1, longest.rounded()))
    }

    /// Columns and rows for that many cubes: at most three rows, and never so many columns that a cube
    /// becomes a speck.
    private var shape: (columns: Int, rows: Int) {
        let hours = hoursInLongestDay
        let columns: Int
        switch hours {
        case ...6: columns = max(1, hours)          // one row, one cube per hour
        case ...12: columns = 6
        case ...16: columns = 8
        default: columns = 8
        }
        return (columns, max(1, Int((Double(hours) / Double(columns)).rounded(.up))))
    }

    var body: some View {
        // One GeometryReader for the whole grid, so a cube's size — and therefore the cell's height — is
        // known before the cells are laid out. Sizing per-cell left leftover height that showed as a band.
        GeometryReader { geo in
            let shape = self.shape
            let cellWidth = (geo.size.width - Self.cubeGap * 6) / 7
            let content = cellWidth - Self.cellPadding * 2
            let side = max(4, min(11, (content - Self.cubeGap * CGFloat(shape.columns - 1))
                                       / CGFloat(shape.columns)))
            let cellHeight = Self.headerHeight + 3 + side * CGFloat(shape.rows)
                + Self.cubeGap * CGFloat(shape.rows - 1) + Self.cellPadding * 2

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(Self.dayNames, id: \.self) { name in
                        Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 4) {
                        ForEach(week) { day in
                            cell(day, shape: shape, side: side, height: cellHeight)
                        }
                    }
                }
            }
        }
        .frame(height: gridHeight)
    }

    /// The height the whole grid needs, so the enclosing card doesn't have to guess.
    private var gridHeight: CGFloat {
        // Recomputed from a nominal cube size; the GeometryReader above refines the cubes, and the rows are
        // what the height depends on.
        let shape = self.shape
        let side: CGFloat = 11
        let cellHeight = Self.headerHeight + 3 + side * CGFloat(shape.rows)
            + Self.cubeGap * CGFloat(shape.rows - 1) + Self.cellPadding * 2
        return 18 + CGFloat(weeks.count) * (cellHeight + 4)
    }

    private func cell(_ day: DayCell, shape: (columns: Int, rows: Int), side: CGFloat,
                      height: CGFloat) -> some View {
        let tracked = day.tracked.reduce(0) { $0 + $1.hours }
        let towards = day.tracked.filter { $0.id >= 0 }.reduce(0) { $0 + $1.hours }
        let short = day.wantedHours - towards
        let missed = day.isPast && short > 0.25
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(day.dayOfMonth)")
                    .font(.system(size: 10, weight: day.isToday ? .semibold : .regular,
                                  design: .rounded))
                    .foregroundStyle(day.isToday ? Color.white
                                     : Color.secondary.opacity(day.inMonth ? 1 : 0.5))
                    .padding(.horizontal, day.isToday ? 4 : 0)
                    .padding(.vertical, day.isToday ? 1 : 0)
                    .background { if day.isToday { Capsule().fill(Color.accentColor) } }
                Spacer(minLength: 0)
                // Done against wanted, which is the day's whole verdict as two numbers. The cubes show
                // what it was made of; this says whether it was enough.
                if day.wantedHours > 0.02 {
                    HStack(spacing: 0) {
                        Text(Self.short(towards))
                            .foregroundStyle(missed ? PlannerPalette.over
                                             : (towards > 0.02 ? Color.primary : .secondary))
                        Text("/\(Self.short(day.wantedHours))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 9, design: .monospaced))
                } else if tracked > 0.02 {
                    Text(Self.short(tracked))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // ONE bar, not a band per allocation. At 95pt wide a stack of full-width rows spends the whole
            // cell on three colours and leaves no room for a number or a name; a single segmented bar says
            // the same thing in nine points and leaves the cell legible.
            //
            // Its LENGTH is how full the day got, its SEGMENTS are what filled it, and the notch is what
            // the day's allocations wanted — so short, met and overshot are all one glance.
            cubes(day, shape: shape, side: side)

            Spacer(minLength: 0)
        }
        .padding(Self.cellPadding)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(day.isToday ? Color.accentColor.opacity(0.07)
                      : Color.primary.opacity(day.inMonth ? 0.035 : 0.012))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(day.isToday ? Color.accentColor.opacity(0.5)
                                      : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .opacity(day.inMonth ? 1 : 0.4)
        .help(tooltip(day, tracked: tracked, towards: towards))
        .onTapGesture(count: 2) { onOpen(day.date) }
    }

    /// One day as a grid of hour-cubes.
    ///
    /// A single thin bar wasted the cell: a 95×58pt box spent nine points on the only thing in it that
    /// carried information. Cubes use the whole area, and being countable they answer a question a bar
    /// can't — *how many hours*, without reading a number.
    ///
    /// One cube is one available hour, filled in order by what you actually did, faint for the hours that
    /// went nowhere. The bracket marks where the day's allocations wanted to reach, so short and met are
    /// visible without a figure.
    private func cubes(_ day: DayCell, shape: (columns: Int, rows: Int),
                       side: CGFloat) -> some View {
        let available = Int(max(1, (capacityHours - day.unavailableHours).rounded()))
        let filled = cubeCounts(day, total: available)
        let wanted = min(available, Int(day.wantedHours.rounded()))
        return VStack(alignment: .leading, spacing: Self.cubeGap) {
            ForEach(0..<shape.rows, id: \.self) { row in
                HStack(spacing: Self.cubeGap) {
                    ForEach(0..<shape.columns, id: \.self) { column in
                        let index = row * shape.columns + column
                        if index < available {
                            cube(index: index, filled: filled, wanted: wanted, side: side)
                        } else {
                            // A shorter day than the longest one: the cube simply isn't there.
                            Color.clear.frame(width: side, height: side)
                        }
                    }
                }
            }
        }
    }

    /// Cube index → the allocation that owns it, or nil for an hour nothing was tracked in.
    ///
    /// Largest-remainder rounding: three allocations of 40 minutes each in a day must not silently become
    /// zero cubes, and the counts have to sum to the hours actually tracked.
    private func cubeCounts(_ day: DayCell, total: Int) -> [Int64?] {
        var counts: [(id: Int64, whole: Int, remainder: Double)] = day.tracked.map {
            (id: $0.id, whole: Int($0.hours), remainder: $0.hours - Double(Int($0.hours)))
        }
        var used = counts.reduce(0) { $0 + $1.whole }
        // Hand out the leftover cubes to the biggest remainders first.
        for index in counts.indices.sorted(by: { counts[$0].remainder > counts[$1].remainder })
        where used < total {
            if counts[index].remainder > 0.15 {
                counts[index].whole += 1
                used += 1
            }
        }
        var out: [Int64?] = []
        for entry in counts {
            out.append(contentsOf: Array(repeating: entry.id, count: min(entry.whole, total - out.count)))
            if out.count >= total { break }
        }
        while out.count < total { out.append(nil) }
        return out
    }

    private func cube(index: Int, filled: [Int64?], wanted: Int, side: CGFloat) -> some View {
        let owner = index < filled.count ? filled[index] : nil
        let dim = owner != nil && highlight != nil && highlight != owner
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(fill(for: owner).opacity(dim ? 0.12 : 1))
            .frame(width: side, height: side)
            .overlay {
                // The target boundary, drawn on the last cube the allocations wanted — a hair of a line, so
                // it reads as a mark on the grid rather than another object in it.
                if wanted > 0, index == wanted - 1 {
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                }
            }
            .onTapGesture { if let owner { onPick(owner) } }
    }

    private func fill(for owner: Int64?) -> Color {
        guard let owner else { return Color.primary.opacity(0.07) }
        if owner < 0 { return Color.secondary.opacity(0.34) }
        let hex = colorFor(owner)
        return Color(hex: hex).opacity(0.92)
    }

    /// Colour lookup for a cube, from the slices this cell already carries.
    private func colorFor(_ id: Int64) -> String {
        colors[id] ?? "#8E8E93"
    }

    private var colors: [Int64: String] {
        var out: [Int64: String] = [:]
        for week in weeks {
            for day in week {
                for slice in day.tracked { out[slice.id] = slice.colorHex }
            }
        }
        return out
    }

    private func tooltip(_ day: DayCell, tracked: Double, towards: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMM"
        var lines = [formatter.string(from: day.date)]
        for slice in day.tracked where slice.hours > 0.02 {
            lines.append("  \(slice.name)  \(Self.short(slice.hours))")
        }
        if day.wantedHours > 0.02 {
            let short = day.wantedHours - towards
            lines.append(short > 0.25
                         ? "\(Self.short(short)) short of the \(Self.short(day.wantedHours)) wanted"
                         : "met the \(Self.short(day.wantedHours)) wanted")
        }
        if tracked > 0.02 { lines.append("double-click to see this day in Metrics") }
        return lines.joined(separator: "\n")
    }

    static func short(_ hours: Double) -> String {
        if hours >= 10 { return "\(Int(hours.rounded()))h" }
        if hours >= 1 {
            return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
        }
        return "\(Int((hours * 60).rounded()))m"
    }
}
