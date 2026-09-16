import SwiftUI
import TimesliceCore

/// The plan as one object: allocations down, days across.
///
/// This replaced three separate visuals — an hour-cell grid, a "falling behind" list and a row of
/// chips — each of which answered part of the question. Three partial answers stacked vertically is
/// worse than one that answers all of it, and the page kept growing instead of getting clearer.
///
/// A matrix works here because both axes already mean something. Reading **across** a row says how one
/// allocation is spread and where it still owes time. Reading **down** a column says whether that day
/// can take any more. So "why can't I finish gym?" is answered by looking under gym's remaining cell
/// and seeing the column already full — the collision is spatial and needs no sentence.
///
/// Rows are worst-first, so "what am I behind on" is just the top row.
struct PlannerMatrix: View {
    let plan: Planner
    let replan: Replan?
    /// weekday → target id → seconds actually tracked this week.
    let actuals: [Int: [Int64: TimeInterval]]
    /// weekday → every tracked second, allocation or not. Used for the load of days that have gone,
    /// where what actually happened is the fact and the plan is only a memory of an intention.
    let actualTotals: [Int: TimeInterval]
    let today: Int
    let colorFor: (Int64) -> String
    let nameFor: (Int64) -> String

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    /// Width of one day column. Wide enough for "12.5h" in the load row underneath.
    private static let dayWidth: CGFloat = 46
    private static let nameWidth: CGFloat = 118
    private static let progressWidth: CGFloat = 74

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(rows, id: \.targetID) { row in
                rowView(row)
            }
            Divider().padding(.vertical, 5)
            loadRow
        }
    }

    // MARK: - Rows

    /// One allocation, with what it has done and what it still owes on each day.
    private struct Row {
        let targetID: Int64
        let name: String
        let done: TimeInterval
        let target: TimeInterval
        /// weekday → what happened and what's still wanted there.
        let cells: [Int: Cell]
        let item: Replan.Item?
        /// Sort key: trouble first.
        let rank: Int
    }

    private struct Cell {
        let done: TimeInterval
        let planned: TimeInterval
        /// True when work landed on a day this allocation doesn't claim.
        ///
        /// It still counts — weekdays change the DENOMINATOR, not the numerator, so an hour of office
        /// work on a Sunday goes towards the weekly total exactly as a Monday hour does. Building the
        /// cells from the plan alone hid 3.5h of real Sunday work behind a "not one of its days" dot,
        /// which is the plan overruling the facts.
        let isExtra: Bool
    }

    private var rows: [Row] {
        let items = Dictionary(uniqueKeysWithValues: (replan?.items ?? []).map { ($0.targetID, $0) })
        var built: [Row] = []
        var seen: Set<Int64> = []
        // Every allocation the plan places, PLUS any with tracked time this week. The second half
        // matters for an allocation whose claimed days have all gone: it has no placements left, and
        // building only from the plan would drop it off the page just when its backlog matters most.
        let withWork = actuals.values.flatMap { $0.filter { $0.value > 60 }.keys }
        let ids = plan.days.flatMap { $0.placements.map(\.targetID) } + withWork
        for id in ids where seen.insert(id).inserted {
            var cells: [Int: Cell] = [:]
            for day in plan.days {
                let done = actuals[day.weekday]?[id] ?? 0
                if let mine = day.placements.first(where: { $0.targetID == id }) {
                    cells[day.weekday] = Cell(done: done,
                                              planned: max(0, mine.seconds - done),
                                              isExtra: false)
                } else if done > 60 {
                    // Work on a day the allocation never claimed. Shown, and marked as extra.
                    cells[day.weekday] = Cell(done: done, planned: 0, isExtra: true)
                }
            }
            let item = items[id]
            built.append(Row(targetID: id, name: nameFor(id),
                             done: item?.doneSeconds ?? 0,
                             target: item?.targetSeconds ?? 0,
                             cells: cells, item: item,
                             rank: rank(item)))
        }
        // Worst first, then biggest shortfall, then by name so the order never wobbles.
        return built.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            let a = $0.item?.shortfallOnRemainingDays ?? 0
            let b = $1.item?.shortfallOnRemainingDays ?? 0
            if a != b { return a > b }
            return $0.name < $1.name
        }
    }

    private func rank(_ item: Replan.Item?) -> Int {
        switch item?.standing {
        case .unreachable: return 0
        case .recoverable: return 1
        case .onTrack: return 2
        default: return 3
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 0) {
            // Name and progress. The gap in the bar IS the lag, so it isn't also written out.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: colorFor(row.targetID))).frame(width: 7, height: 7)
                    Text(row.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                }
                Text("\(short(row.done))/\(short(row.target))")
                    .font(.system(size: 9, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .frame(width: Self.nameWidth, alignment: .leading)

            ProgressPair(done: row.done, total: row.target,
                         tint: Color(hex: colorFor(row.targetID)))
                .frame(width: Self.progressWidth, height: 7)
                .padding(.trailing, 10)

            ForEach(plan.days, id: \.weekday) { day in
                cell(row: row, day: day)
                    .frame(width: Self.dayWidth)
            }

            // What each remaining day has to carry, or the reason there's nowhere to put it.
            Text(trailing(row))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(row.item?.standing == .unreachable ? PlannerView.overColor
                                                                    : .secondary)
                .frame(width: 130, alignment: .leading)
                .padding(.leading, 10)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .background(row.item?.standing == .unreachable
                    ? PlannerView.overColor.opacity(0.07) : Color.clear)
        .help(tooltip(row))
    }

    /// One allocation on one day. Filled for hours done, hollow for hours still wanted, and red when
    /// the day has no room for them.
    private func cell(row: Row, day: Planner.DayPlan) -> some View {
        let entry = row.cells[day.weekday]
        let isPast = day.weekday < today
        return Group {
            if let entry, entry.done + entry.planned > 60 {
                // Two segments in one pill: done then planned, so a partly-done day reads as partly
                // done rather than as one state or the other.
                GeometryReader { geo in
                    let total = entry.done + entry.planned
                    let doneFraction = total > 0 ? entry.done / total : 0
                    let blocked = day.isOverCapacity && entry.planned > 60
                    HStack(spacing: 0) {
                        Rectangle().fill(Color(hex: colorFor(row.targetID)))
                            .frame(width: geo.size.width * doneFraction)
                        Rectangle()
                            .fill(blocked ? PlannerView.overColor.opacity(0.55)
                                          : Color(hex: colorFor(row.targetID)).opacity(0.22))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay {
                        // Dashed for work on a day this allocation doesn't claim: it counts, but it
                        // wasn't the plan, and those are different facts.
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color(hex: colorFor(row.targetID)).opacity(0.8),
                                          style: StrokeStyle(
                                            lineWidth: entry.isExtra ? 1.5
                                                       : (entry.planned > 60 ? 1 : 0),
                                            dash: entry.isExtra ? [2, 2] : []))
                    }
                }
                .frame(height: 14)
                .padding(.horizontal, 3)
                .opacity(isPast ? 0.45 : 1)
                .overlay(alignment: .center) {
                    // The figure, once the cell is wide enough to hold it. Small, because the length
                    // already carries the comparison.
                    Text(short(entry.done + entry.planned))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                // Not one of this allocation's days. A dot, not an empty box: an empty box reads as
                // "nothing done here", which is a different statement.
                Circle().fill(Color.secondary.opacity(0.20)).frame(width: 3, height: 3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func trailing(_ row: Row) -> String {
        guard let item = row.item else { return "" }
        switch item.standing {
        case .met: return "done"
        case .unreachable:
            // Why, in the row itself. "Unreachable" now means this allocation's OWN days can't hold
            // what's left of it, so the reason is always one of these two — not "something else won".
            if item.remainingClaimedDays == 0 { return "✗ no days left" }
            return "✗ needs \(short(item.remainingSeconds)) in \(short(item.availableOnRemainingDays))"
        case .recoverable, .onTrack:
            guard let per = item.requiredPerRemainingDay, item.remainingSeconds > 60 else {
                return "done"
            }
            return "\(short(per))/day × \(item.remainingClaimedDays)"
        }
    }

    private func tooltip(_ row: Row) -> String {
        guard let item = row.item else { return row.name }
        var lines = ["\(row.name): \(short(item.doneSeconds)) of \(short(item.targetSeconds))"]
        if item.debtSeconds > 60 {
            lines.append("behind by \(short(item.debtSeconds)) against an even spread")
        }
        lines.append("\(short(item.remainingSeconds)) left, \(item.remainingClaimedDays) day(s) to do it")
        lines.append("those days have \(short(item.availableOnRemainingDays)) free between them "
                     + "(waking hours minus what's reserved)")
        lines.append("catch-up can use any of those hours — being behind earlier doesn't cost you "
                     + "later ones")
        if !item.blockers.isEmpty {
            lines.append("")
            lines.append("competing for those days:")
            for b in item.blockers { lines.append("  \(b.name)  \(short(b.secondsOnThoseDays))") }
        }
        if !item.adviceIfUnreachable.isEmpty {
            lines.append("")
            lines.append(item.adviceIfUnreachable)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Header and the load row

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.nameWidth + Self.progressWidth + 10, height: 1)
            ForEach(plan.days, id: \.weekday) { day in
                Text(Self.dayNames[day.weekday - 1])
                    .font(.system(size: 10, weight: day.weekday == today ? .bold : .regular))
                    .foregroundStyle(day.weekday == today ? Color.accentColor
                                     : (day.weekday < today ? Color.secondary.opacity(0.5)
                                                            : .secondary))
                    .frame(width: Self.dayWidth)
            }
            Color.clear.frame(width: 130, height: 1)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    /// How full each day is. The bottom axis of the matrix: read down a column to a bar that says
    /// whether there's any room left in it.
    private var loadRow: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("day load").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("of \(short(plan.capacitySeconds / 7))")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .frame(width: Self.nameWidth + Self.progressWidth + 10, alignment: .leading)

            ForEach(plan.days, id: \.weekday) { day in
                VStack(spacing: 2) {
                    // Vertical, so a full day is a tall bar — the same "filling up" reading the
                    // hour-cell version had, at a fraction of the space.
                    GeometryReader { geo in
                        let capacity = max(day.capacitySeconds, 1)
                        let used = load(day)
                        let fraction = min(1.4, used / capacity)
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .fill(day.isOverCapacity ? PlannerView.overColor
                                      : (fraction > 0.85 ? Color.orange : Color.accentColor))
                                .frame(height: geo.size.height * min(1, fraction))
                        }
                        // The capacity line, so an over-full day visibly passes it.
                        .overlay(alignment: .top) {
                            if fraction > 1 {
                                Rectangle().fill(Color.primary.opacity(0.5))
                                    .frame(height: 1)
                                    .offset(y: geo.size.height * (1 - 1 / fraction))
                            }
                        }
                    }
                    .frame(height: 26)
                    .frame(maxWidth: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    Text(short(load(day)))
                        .font(.system(size: 9, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(day.isOverCapacity ? PlannerView.overColor : .secondary)
                }
                .frame(width: Self.dayWidth)
                .opacity(day.weekday < today ? 0.5 : 1)
                .help(dayTooltip(day))
            }
            Color.clear.frame(width: 130, height: 1)
            Spacer(minLength: 0)
        }
    }

    /// A day's load: what HAPPENED for days that have gone, what's planned for the ones still coming.
    ///
    /// A past Sunday showing its plan is a lie about a day you already lived — and it was showing a
    /// nearly-empty column for a Sunday with 3.5h of real work in it, because office doesn't claim
    /// Sundays. Today takes whichever is larger: the day isn't over, so the plan is still a claim on it.
    private func load(_ day: Planner.DayPlan) -> TimeInterval {
        let actual = (actualTotals[day.weekday] ?? 0) + day.reservedSeconds
        let planned = day.reservedSeconds + day.committedSeconds
        if day.weekday < today { return actual }
        if day.weekday == today { return max(actual, planned) }
        return planned
    }

    private func dayTooltip(_ day: Planner.DayPlan) -> String {
        var lines = ["\(Self.dayNames[day.weekday - 1]) — \(short(day.capacitySeconds)) awake"]
        if day.reservedSeconds > 0 { lines.append("reserved  \(short(day.reservedSeconds))") }
        for p in day.placements.sorted(by: { $0.seconds > $1.seconds }) {
            let done = actuals[day.weekday]?[p.targetID] ?? 0
            lines.append("\(p.name)  \(short(p.seconds))" + (done > 60 ? " (\(short(done)) done)" : ""))
        }
        if let actual = actualTotals[day.weekday], actual > 60 {
            lines.append("actually tracked  \(short(actual))")
        }
        lines.append(day.isOverCapacity ? "OVER by \(short(-day.slackSeconds))"
                                        : "\(short(day.freeSeconds)) free")
        return lines.joined(separator: "\n")
    }

    private func short(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        if h >= 10 { return "\(Int(h.rounded()))h" }
        if h >= 1 { return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h) }
        if seconds < 60 { return "0" }
        return "\(Int((seconds / 60).rounded()))m"
    }
}
