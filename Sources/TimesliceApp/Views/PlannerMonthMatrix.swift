import SwiftUI
import TimesliceCore
import TimesliceUI

/// The month as allocations down, weeks across.
///
/// It used to be thirty day-cells, which looked like a calendar and said almost nothing: a cell that size
/// holds neither a name nor a figure, so every day was an anonymous stack of stripes. The week view is
/// informative precisely because its blocks are labelled.
///
/// A month is a different question anyway, and it was asked for a specific reason: *"I want to plan future
/// weeks on how to play catch up if I miss the prior weeks."* That is answered by allocations against
/// weeks — read a row to see which weeks an allocation was missed in, read the bottom row to see which
/// week was thin overall, and the outlined columns on the right are the weeks left to make it up in.
///
/// Cells are the same two-tone bar the allocation rail uses, so a percentage means one thing on both
/// halves of the page.
struct PlannerMonthMatrix: View {
    struct WeekColumn: Identifiable {
        let start: Date
        let label: String            // "14 Sep"
        let isCurrent: Bool
        let isFuture: Bool
        /// How far through this week we are, 0…1. Only meaningful for the current one.
        let elapsedFraction: Double
        /// Every tracked second in the week, allocation or not.
        let trackedHours: Double
        /// Hours available to plan with across the week.
        let availableHours: Double
        var id: Date { start }
    }

    struct Row: Identifiable {
        let id: Int64
        let name: String
        let colorHex: String
        /// The weekly rate this allocation asks for.
        let targetHours: Double
        /// Week start → hours done in that week.
        let doneByWeek: [Date: Double]
    }

    let weeks: [WeekColumn]
    let rows: [Row]
    let highlight: Int64?
    var onPick: (Int64) -> Void = { _ in }

    private static let nameWidth: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            ForEach(rows) { row in
                rowView(row)
            }
            Divider().padding(.vertical, 3)
            loadRow
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: Self.nameWidth, height: 1)
            ForEach(weeks) { week in
                VStack(spacing: 0) {
                    Text(week.label)
                        .font(.system(size: 10, weight: week.isCurrent ? .semibold : .regular))
                        .foregroundStyle(week.isCurrent ? Color.accentColor
                                         : (week.isFuture ? Color.secondary.opacity(0.6) : .secondary))
                    Text(week.isCurrent ? "this week" : (week.isFuture ? "ahead" : ""))
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        let dim = highlight != nil && highlight != row.id
        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(Color(hex: row.colorHex)).frame(width: 7, height: 7)
                Text(row.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: Self.nameWidth, alignment: .leading)
            .help(rowTooltip(row))

            ForEach(weeks) { week in
                cell(row, week)
                    .frame(maxWidth: .infinity)
            }
        }
        .opacity(dim ? 0.25 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onPick(row.id) }
    }

    /// One allocation in one week.
    ///
    /// A future week gets an outline rather than a bar: nothing has happened in it, and a 0% bar reads as a
    /// failure instead of an opportunity — backwards for the weeks you still have.
    private func cell(_ row: Row, _ week: WeekColumn) -> some View {
        let done = row.doneByWeek[week.start] ?? 0
        let fraction = row.targetHours > 0 ? min(1, done / row.targetHours) : 0
        return Group {
            if week.isFuture {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.22),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(height: 14)
            } else {
                InlineBar(fraction: fraction,
                          label: row.targetHours > 0
                              ? "\(Int((fraction * 100).rounded()))%" : "—",
                          fill: Color(hex: row.colorHex),
                          height: 14,
                          // Only the week in progress has a pace to be behind; a finished week is a fact.
                          marker: week.isCurrent ? week.elapsedFraction : nil)
            }
        }
        .help(cellTooltip(row, week, done: done))
    }

    /// How much of each week got tracked at all — the row that says "that week was thin", which no single
    /// allocation's row can.
    private var loadRow: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("tracked").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("of hours available").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            .frame(width: Self.nameWidth, alignment: .leading)

            ForEach(weeks) { week in
                let fraction = week.availableHours > 0
                    ? min(1, week.trackedHours / week.availableHours) : 0
                Group {
                    if week.isFuture {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.22),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(height: 15)
                    } else {
                        InlineBar(fraction: fraction,
                                  label: short(week.trackedHours),
                                  fill: Color.accentColor,
                                  height: 15,
                                  marker: week.isCurrent ? week.elapsedFraction : nil)
                    }
                }
                .frame(maxWidth: .infinity)
                .help("Week of \(week.label)\n\(short(week.trackedHours)) tracked of "
                      + "\(short(week.availableHours)) available")
            }
        }
    }

    private func cellTooltip(_ row: Row, _ week: WeekColumn, done: Double) -> String {
        if week.isFuture {
            return "\(row.name) · week of \(week.label)\nnothing yet — \(short(row.targetHours)) wanted"
        }
        let short = short(done) + " of " + short(row.targetHours)
        return "\(row.name) · week of \(week.label)\n\(short)"
    }

    private func rowTooltip(_ row: Row) -> String {
        var lines = ["\(row.name) — \(short(row.targetHours)) a week"]
        let past = weeks.filter { !$0.isFuture }
        let owed = past.reduce(0.0) { $0 + max(0, row.targetHours - (row.doneByWeek[$1.start] ?? 0)) }
        if owed > 0.05 {
            lines.append("\(short(owed)) behind so far")
            let ahead = weeks.filter(\.isFuture).count
            if ahead > 0 {
                lines.append("\(short(owed / Double(ahead))) extra a week would catch it up")
            }
        } else {
            lines.append("on target every week so far")
        }
        return lines.joined(separator: "\n")
    }

    private func short(_ hours: Double) -> String {
        if hours >= 10 { return "\(Int(hours.rounded()))h" }
        if hours >= 1 {
            return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
        }
        return "\(Int((hours * 60).rounded()))m"
    }
}
