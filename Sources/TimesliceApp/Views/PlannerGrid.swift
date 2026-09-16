import SwiftUI
import TimesliceCore

/// The week as hour-cells: seven columns, one row per waking hour, one cell per hour.
///
/// The whole planner in one picture. A week is a fixed number of hours and the question is what claims
/// them, so the honest visual is that many cells, filling up. You can see the budget run out; you
/// don't have to read that it did.
///
/// It replaced a page of prose and tables. Everything a sentence used to say is here as position and
/// colour instead: what's spent, what's planned, what's left, what won't fit, and which days have
/// already gone.
///
/// One cell = one hour, reading upward from the bottom of each day so a column stacks like a bar:
///
/// * **grey** — reserved, the non-negotiables, at the bottom because they're the floor you build on
/// * **solid colour** — hours already tracked against an allocation
/// * **hatched colour** — hours the plan still wants, not done yet
/// * **empty outline** — free
/// * **red, above the line** — more claimed than the day holds, spilling out rather than being clipped
/// * **whole column dimmed** — a day that has gone
struct PlannerGrid: View {
    let plan: Planner
    let replan: Replan?
    /// weekday (1…7) → target id → seconds actually tracked this week.
    let actuals: [Int: [Int64: TimeInterval]]
    /// Tracked hours that no allocation claims — chores, commute, whatever. Shown, because a day that
    /// went somewhere unplanned is the most common reason a plan didn't happen.
    let unallocated: [Int: TimeInterval]
    let today: Int
    let colorFor: (Int64) -> String
    let nameFor: (Int64) -> String

    private static let dayNames = ["S", "M", "T", "W", "T", "F", "S"]
    private static let cell: CGFloat = 15
    private static let gap: CGFloat = 3

    /// What one cell represents.
    private enum Fill: Equatable {
        case reserved
        case done(Int64)
        case planned(Int64)
        /// Tracked, but not against any allocation.
        case other
        case free
        case over
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: Self.gap * 2) {
                ForEach(plan.days, id: \.weekday) { day in
                    column(day)
                }
            }
            legend
        }
    }

    // MARK: - One day

    private func column(_ day: Planner.DayPlan) -> some View {
        let hours = Int((day.capacitySeconds / 3600).rounded())
        let cells = fills(for: day, capacity: hours)
        let isPast = day.weekday < today
        let isToday = day.weekday == today
        return VStack(spacing: Self.gap) {
            // Overflow sits ABOVE the day, so an impossible day looks impossible instead of looking
            // full. Clipping it to the top row would hide the entire problem.
            VStack(spacing: Self.gap) {
                ForEach(Array(cells.overflow.enumerated().reversed()), id: \.offset) { _, fill in
                    cellView(fill, dimmed: false)
                }
            }
            VStack(spacing: Self.gap) {
                ForEach(Array(cells.inside.enumerated().reversed()), id: \.offset) { _, fill in
                    cellView(fill, dimmed: isPast)
                }
            }
            Text(Self.dayNames[day.weekday - 1])
                .font(.system(size: 10, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor
                                         : (day.isOverCapacity ? PlannerView.overColor : .secondary))
            Text(footer(day))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(day.isOverCapacity ? PlannerView.overColor
                                                    : Color.secondary.opacity(0.55))
        }
        .help(tooltip(day))
        // Today gets a ring, so "where am I in the week" needs no reading.
        .overlay(alignment: .top) {
            if isToday {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                    .frame(width: Self.cell + 6,
                           height: CGFloat(Int((day.capacitySeconds / 3600).rounded()))
                                 * (Self.cell + Self.gap) + 4)
                    .offset(y: CGFloat(cells.overflow.count) * (Self.cell + Self.gap) - 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func cellView(_ fill: Fill, dimmed: Bool) -> some View {
        Group {
            switch fill {
            case .reserved:
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.30))
            case .done(let id):
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: colorFor(id)))
            case .planned(let id):
                // Hollow, not faded: "wanted but not done" is a different kind of thing from "done
                // less brightly", and a ring says so at a glance.
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(hex: colorFor(id)), lineWidth: 2)
            case .other:
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.55))
            case .free:
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06))
            case .over:
                RoundedRectangle(cornerRadius: 3).fill(PlannerView.overColor)
            }
        }
        .frame(width: Self.cell, height: Self.cell)
        .opacity(dimmed ? 0.4 : 1)
    }

    /// Which fill each hour of a day gets, bottom-up, plus anything that didn't fit.
    ///
    /// Rounded to whole hours because the grid's unit IS an hour — showing a 20-minute sliver as a cell
    /// would claim a precision the planner doesn't have, and dropping it would lose the hour it's part
    /// of. Half an hour and up takes a cell.
    private func fills(for day: Planner.DayPlan, capacity: Int)
        -> (inside: [Fill], overflow: [Fill]) {
        var cells: [Fill] = []
        let cellsFor = { (seconds: TimeInterval) in Int((seconds / 3600).rounded()) }

        cells += Array(repeating: .reserved, count: max(0, cellsFor(day.reservedSeconds)))

        let doneByTarget = actuals[day.weekday] ?? [:]
        // Biggest first, so the same allocation sits in the same part of every column and the week
        // reads as bands rather than as noise.
        for placement in day.placements.sorted(by: { $0.seconds > $1.seconds }) {
            let done = doneByTarget[placement.targetID] ?? 0
            cells += Array(repeating: .done(placement.targetID), count: cellsFor(done))
            // What the plan still wants beyond what's already been done today.
            let planned = max(0, placement.seconds - done)
            cells += Array(repeating: .planned(placement.targetID), count: cellsFor(planned))
        }
        // Tracked hours belonging to no allocation, plus anything tracked against an allocation that
        // wasn't planned for this day at all — otherwise a day's real hours can exceed its cells.
        var extra = unallocated[day.weekday] ?? 0
        for (id, seconds) in doneByTarget where !day.placements.contains(where: { $0.targetID == id }) {
            extra += seconds
            _ = id
        }
        cells += Array(repeating: .other, count: cellsFor(extra))

        if cells.count < capacity {
            cells += Array(repeating: .free, count: capacity - cells.count)
            return (cells, [])
        }
        let overflow = Array(repeating: Fill.over, count: cells.count - capacity)
        return (Array(cells.prefix(capacity)), overflow)
    }

    private func footer(_ day: Planner.DayPlan) -> String {
        if day.isOverCapacity { return "+\(short(-day.slackSeconds))" }
        return short(day.freeSeconds)
    }

    private func tooltip(_ day: Planner.DayPlan) -> String {
        var lines = ["\(fullDayName(day.weekday)) — \(short(day.capacitySeconds)) awake"]
        if day.reservedSeconds > 0 { lines.append("reserved  \(short(day.reservedSeconds))") }
        let done = actuals[day.weekday] ?? [:]
        for placement in day.placements.sorted(by: { $0.seconds > $1.seconds }) {
            let d = done[placement.targetID] ?? 0
            lines.append("\(placement.name)  planned \(short(placement.seconds))"
                         + (d > 60 ? ", done \(short(d))" : ""))
        }
        if let other = unallocated[day.weekday], other > 60 {
            lines.append("unplanned  \(short(other))")
        }
        lines.append(day.isOverCapacity ? "OVER by \(short(-day.slackSeconds))"
                                        : "\(short(day.freeSeconds)) free")
        return lines.joined(separator: "\n")
    }

    // MARK: - Legend

    /// The allocations, as colour chips with their weekly figures. This is the whole of what used to be
    /// a table: the grid already shows where the hours go, so the legend only has to name the colours.
    private var legend: some View {
        let ids = plan.days.flatMap { $0.placements.map(\.targetID) }
        var seen: Set<Int64> = []
        let ordered = ids.filter { seen.insert($0).inserted }
        return HStack(spacing: 10) {
            ForEach(ordered, id: \.self) { id in
                let item = replan?.items.first { $0.targetID == id }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: colorFor(id)))
                        .frame(width: 8, height: 8)
                    Text(nameFor(id)).font(.system(size: 10)).lineLimit(1)
                    if let item {
                        Text("\(short(item.doneSeconds))/\(short(item.targetSeconds))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(item.standing == .unreachable ? PlannerView.overColor
                                                                           : .secondary)
                    }
                }
                .help(item.map(legendTooltip) ?? nameFor(id))
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.30))
                    .frame(width: 8, height: 8)
                Text("reserved").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                Text("planned").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func legendTooltip(_ item: Replan.Item) -> String {
        var lines = ["\(item.name): \(short(item.doneSeconds)) of \(short(item.targetSeconds))"]
        if item.debtSeconds > 60 { lines.append("behind by \(short(item.debtSeconds))") }
        if let per = item.requiredPerRemainingDay, item.remainingSeconds > 60 {
            lines.append("needs \(short(per)) on each of \(item.remainingClaimedDays) remaining day(s)")
        }
        if !item.adviceIfUnreachable.isEmpty { lines.append(item.adviceIfUnreachable) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    private func short(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        if h >= 1 { return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h) }
        if seconds < 60 { return "0h" }
        return "\(Int((seconds / 60).rounded()))m"
    }

    private func fullDayName(_ weekday: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][
            max(0, min(6, weekday - 1))]
    }
}
