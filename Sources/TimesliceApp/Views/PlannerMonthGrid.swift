import SwiftUI
import TimesliceCore
import TimesliceUI

/// The month as a month calendar: real weeks in real rows, each day a cell that fills up.
///
/// Same idea as the week view one zoom out. A day has no room for blocks at this size, so a cell is
/// just how full it got — tracked hours stacked by allocation, planned hours hatched above them, the
/// cell's height being the waking day. Reading down a column says "Tuesdays are where it goes wrong";
/// reading across a row says which week was lost.
///
/// Which is the point the month view exists for: deciding how to play catch-up over the weeks ahead
/// needs the weeks behind you visible in the same picture.
struct PlannerMonthGrid: View {
    struct Slice: Identifiable {
        let id: Int64          // target id, or a negative sentinel for unallocated
        let hours: Double
        let colorHex: String
    }

    struct DayCell: Identifiable {
        let date: Date
        let dayOfMonth: Int
        /// False for the leading/trailing days that fill the first and last rows.
        let inMonth: Bool
        let isToday: Bool
        let isPast: Bool
        let reservedHours: Double
        /// Tracked hours by allocation, largest first.
        let tracked: [Slice]
        /// What the plan still wants on this day. Zero for days that have gone.
        let plannedHours: Double
        var id: Date { date }
    }

    let weeks: [[DayCell]]
    let wakingHours: Double
    let highlight: Int64?
    var onPick: (Int64) -> Void = { _ in }

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let cellHeight: CGFloat = 62

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                ForEach(Self.dayNames, id: \.self) { name in
                    Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 3) {
                    ForEach(week) { cell($0) }
                }
            }
        }
    }

    private func cell(_ day: DayCell) -> some View {
        let tracked = day.tracked.reduce(0) { $0 + $1.hours }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(day.isToday ? Color.accentColor.opacity(0.07)
                      : Color.primary.opacity(day.inMonth ? 0.035 : 0.012))

            // The fill, from the bottom up: what happened, then what's still wanted. The cell is a
            // waking day, so a cell that fills to the top is a day with nothing spare in it.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if day.plannedHours > 0.02 {
                    Hatch(color: .accentColor)
                        .frame(height: barHeight(day.plannedHours))
                }
                ForEach(day.tracked) { slice in
                    Rectangle()
                        .fill(Color(hex: slice.colorHex)
                              .opacity(highlight == nil || highlight == slice.id ? 0.85 : 0.15))
                        .frame(height: barHeight(slice.hours))
                        .onTapGesture { onPick(slice.id) }
                }
                if day.reservedHours > 0.02 {
                    Hatch(color: .secondary).frame(height: barHeight(day.reservedHours))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 3) {
                Text("\(day.dayOfMonth)")
                    .font(.system(size: 10, weight: day.isToday ? .bold : .regular))
                    .foregroundStyle(day.isToday ? Color.accentColor
                                     : Color.secondary.opacity(day.inMonth ? 1 : 0.55))
                if tracked > 0.02 {
                    Text(PlannerCalendar.short(tracked))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(3)
        }
        .frame(height: Self.cellHeight)
        .frame(maxWidth: .infinity)
        .opacity(day.inMonth ? 1 : 0.45)
        .help(tooltip(day, tracked: tracked))
    }

    private func barHeight(_ hours: Double) -> CGFloat {
        max(1, Self.cellHeight * CGFloat(min(1, hours / max(1, wakingHours))))
    }

    private func tooltip(_ day: DayCell, tracked: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM"
        var lines = [f.string(from: day.date)]
        for slice in day.tracked where slice.hours > 0.02 {
            lines.append("  \(PlannerCalendar.short(slice.hours))")
        }
        lines.append("tracked \(PlannerCalendar.short(tracked)) of \(Int(wakingHours))h awake")
        if day.reservedHours > 0.02 {
            lines.append("reserved \(PlannerCalendar.short(day.reservedHours))")
        }
        if day.plannedHours > 0.02 {
            lines.append("still wanted \(PlannerCalendar.short(day.plannedHours))")
        }
        return lines.joined(separator: "\n")
    }
}
