import SwiftUI
import TimesliceCore

/// Whether the week is possible — as a picture, not a report.
///
/// The first version explained itself in paragraphs and tables, and it was unreadable. A week is a
/// fixed number of hours and the only question is what claims them, so the page is one visual —
/// `PlannerGrid`, the week as hour-cells — with a headline above it and chips below. Anything that used
/// to be a sentence is now position, colour, or a tooltip.
///
/// Every figure comes from `Planner` and `Replan` in Core, so `swift run TimeslicePlan --db <path>`
/// prints the same numbers and the page can be checked against arithmetic rather than by eye — which
/// matters because macOS UI can't be screenshotted headlessly.
struct PlannerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: AppSettings

    @State private var targets: [Target] = []
    @State private var reservations: [Reservation] = []
    @State private var plan: Planner?
    @State private var replan: Replan?
    /// weekday → target id → seconds tracked this week, for the solid cells.
    @State private var actuals: [Int: [Int64: TimeInterval]] = [:]
    /// weekday → seconds tracked against something no allocation covers.
    @State private var unallocated: [Int: TimeInterval] = [:]
    @State private var today = 1
    @State private var showReservations = false
    @State private var showAllocations = false

    /// The red used for over-capacity, matching the metrics selection overlay so one colour means one
    /// thing across both pages.
    static let overColor = Color(red: 0.90, green: 0.30, blue: 0.32)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let plan {
                    headline(plan)
                    PlannerGrid(plan: plan, replan: replan, actuals: actuals,
                                unallocated: unallocated, today: today,
                                colorFor: colorHex(forTarget:), nameFor: name(forTarget:))
                    if let replan { lagging(replan) }
                    chips(plan)
                } else {
                    empty
                }
            }
            .padding(18)
        }
        .onAppear(perform: rebuild)
        .onReceive(NotificationCenter.default.publisher(for: TimesliceNotifications.dataDidChange)) { _ in
            rebuild()
        }
        .sheet(isPresented: $showReservations) {
            ReservationsSheet(store: appState.storeForEditing) {
                showReservations = false
                rebuild()
            }
        }
        .sheet(isPresented: $showAllocations) {
            TargetsSheet(appState: appState, store: appState.storeForEditing) {
                showAllocations = false
                rebuild()
            }
        }
    }

    // MARK: - Headline

    /// One line for the verdict, one row of numbers, two buttons. Nothing else above the grid.
    @ViewBuilder
    private func headline(_ plan: Planner) -> some View {
        let free = max(0, plan.capacitySeconds - plan.reservedSeconds)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(verdictColor(plan.verdict)).frame(width: 9, height: 9)
                Text(verdictLine(plan))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(verdictColor(plan.verdict))
                Spacer()
                Button("Reserve…") { showReservations = true }
                    .buttonStyle(.link).font(.system(size: 11))
                Button("Allocations…") { showAllocations = true }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            HStack(spacing: 0) {
                stat(rangeText(plan), "wanted", verdictColor(plan.verdict))
                divider
                stat(hours(plan.reservedSeconds), "reserved", .secondary)
                divider
                stat(hours(free), "free", .accentColor)
                if let replan, replan.remainingNeedSeconds > 60 {
                    divider
                    stat(hours(replan.remainingNeedSeconds), "left this week",
                         replan.weekIsLost ? Self.overColor : .primary)
                    divider
                    stat(hours(replan.remainingCapacitySeconds), "room left",
                         replan.weekIsLost ? Self.overColor : .secondary)
                }
                Spacer()
            }
        }
    }

    /// The verdict as one clause. The paragraph that used to follow it is gone: what it explained is
    /// visible in the grid, and the numbers beside it carry the arithmetic.
    private func verdictLine(_ plan: Planner) -> String {
        if let replan, replan.weekIsLost {
            return "Not finishable — \(hours(replan.remainingNeedSeconds)) left, "
                 + "room for \(hours(replan.remainingCapacitySeconds))"
        }
        switch plan.verdict {
        case .fits: return "The week fits"
        case .tight: return "Fits, only just"
        case .oversubscribed where !plan.overloadedDays.isEmpty:
            return "\(dayList(plan.overloadedDays)) over capacity"
        case .oversubscribed:
            let free = max(0, plan.capacitySeconds - plan.reservedSeconds)
            return "Over by \(hours(plan.requiredLowerSeconds - free))"
        case .uncertain: return "Fits only if allocations share work"
        }
    }

    // MARK: - What's lagging, and why

    /// One row per allocation that is behind or can't be finished, showing the two facts that explain
    /// it: how much is still needed, and how much room its remaining days actually have.
    ///
    /// The grid shows THAT the week is full. This shows WHY a particular thing won't happen, which is a
    /// different question and the one that leads to a decision. "Behind by 3h" is a symptom; "needs 10h,
    /// has 6h of room, and office wants 28h of the same days" is something to argue with.
    @ViewBuilder
    private func lagging(_ replan: Replan) -> some View {
        // Worst first: can't-finish above merely-behind, and within each, the biggest gap.
        let rows = replan.items
            .filter { $0.standing == .unreachable || $0.standing == .recoverable }
            .sorted {
                if ($0.standing == .unreachable) != ($1.standing == .unreachable) {
                    return $0.standing == .unreachable
                }
                return $0.shortfallOnRemainingDays > $1.shortfallOnRemainingDays
            }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(rows.contains { $0.standing == .unreachable }
                     ? "Can't finish" : "Falling behind")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(rows.contains { $0.standing == .unreachable }
                                     ? Self.overColor : .orange)
                ForEach(rows, id: \.targetID) { item in
                    laggingRow(item)
                }
            }
        }
    }

    private func laggingRow(_ item: Replan.Item) -> some View {
        let blocked = item.standing == .unreachable
        return HStack(spacing: 10) {
            Circle().fill(Color(hex: colorHex(forTarget: item.targetID)))
                .frame(width: 8, height: 8)
            Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                .frame(width: 140, alignment: .leading).help(item.name)

            // Done against target. The gap IS the lag, so it needs no number beside it.
            ProgressPair(done: item.doneSeconds, total: item.targetSeconds,
                         tint: Color(hex: colorHex(forTarget: item.targetID)))
                .frame(width: 110, height: 12)
            Text("\(hours(item.doneSeconds))/\(hours(item.targetSeconds))")
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)

            // The why, as two bars against one scale: what's still needed, and what room is left on the
            // days it's allowed to use. Needed longer than room is the whole explanation.
            NeedVersusRoom(need: item.remainingSeconds, room: item.availableOnRemainingDays,
                           blocked: blocked)
                .frame(width: 130, height: 22)
            Text("need \(hours(item.remainingSeconds)) · room \(hours(item.availableOnRemainingDays))")
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(blocked ? Self.overColor : .secondary)
                .frame(width: 150, alignment: .leading)

            // What is taking the room. Named, because "do more" is not advice.
            if blocked, let top = item.blockers.first {
                Text("\(top.name) wants \(hours(top.secondsOnThoseDays)) of those "
                     + "\(item.remainingClaimedDays) day(s)")
                    .font(.system(size: 10)).foregroundStyle(Self.overColor.opacity(0.9))
                    .lineLimit(1)
            } else if let per = item.requiredPerRemainingDay {
                Text("\(hours(per))/day for \(item.remainingClaimedDays) day(s)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .help(laggingTooltip(item))
    }

    private func laggingTooltip(_ item: Replan.Item) -> String {
        var lines = ["\(item.name): \(hours(item.doneSeconds)) of \(hours(item.targetSeconds)) done"]
        if item.debtSeconds > 60 {
            lines.append("behind by \(hours(item.debtSeconds)) against an even spread")
        }
        lines.append("\(hours(item.remainingSeconds)) still needed, across "
                     + "\(item.remainingClaimedDays) remaining day(s)")
        lines.append("those days have \(hours(item.availableOnRemainingDays)) free in total")
        if !item.blockers.isEmpty {
            lines.append("")
            lines.append("what's taking those days:")
            for b in item.blockers {
                lines.append("  \(b.name)  \(hours(b.secondsOnThoseDays))")
            }
        }
        if !item.adviceIfUnreachable.isEmpty {
            lines.append("")
            lines.append(item.adviceIfUnreachable)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Chips

    /// Problems and notes as chips with tooltips, not prose. Each is a thing to act on; the reasoning
    /// lives on hover, where it costs no page.
    @ViewBuilder
    private func chips(_ plan: Planner) -> some View {
        FlowRow(spacing: 6) {
            ForEach(Array(plan.unplaced.enumerated()), id: \.offset) { _, item in
                chip(item.name, "won't fit", Self.overColor,
                     tooltip: "\(item.name) won't fit.\nWould fit if \(item.wouldFitIf).")
            }
            ForEach(Array(plan.nestings.enumerated()), id: \.offset) { _, n in
                chip(n.innerName, "inside \(n.outerName)", .secondary,
                     tooltip: "\(n.innerName) (\(hours(n.innerSeconds))) sits inside "
                            + "\(n.outerName) (\(hours(n.outerSeconds))), so its hours are already "
                            + "counted there and it asks for nothing extra.")
            }
            if reservations.isEmpty {
                // The one warning worth keeping visible: without reservations the verdict is the
                // optimistic one, because only about a third of a waking day ever gets tracked.
                chip("nothing reserved", "verdict is optimistic", Self.overColor,
                     tooltip: "No non-negotiables are declared, so this assumes all "
                            + "\(hours(plan.capacitySeconds)) of the week is available. Meals, "
                            + "commute and getting ready never become tasks — declare them with "
                            + "Reserve… for a real answer.")
            }
            ForEach(plan.ceilings, id: \.id) { t in
                chip(name(for: t), "limit \(hours(t.seconds))/\(t.period.rawValue)", .secondary,
                     tooltip: "A ceiling — permission to stop, not work to do, so it isn't counted "
                            + "against the week.")
            }
        }
    }

    private func chip(_ title: String, _ detail: String, _ tint: Color,
                      tooltip: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium))
            Text(detail).font(.system(size: 10)).foregroundStyle(tint)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .help(tooltip)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing to plan yet").font(.headline)
            Text("Set an allocation and this page will show whether your week can hold all of them.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Allocations…") { showAllocations = true }
                .buttonStyle(.link).font(.system(size: 11))
        }
    }

    // MARK: - Data

    private func rebuild() {
        let store = appState.storeForEditing
        targets = (try? store.listTargets()) ?? []
        reservations = (try? store.listReservations()) ?? []
        guard !targets.isEmpty else { plan = nil; return }

        let tasks = (try? store.listProjects(includeArchived: true)) ?? []
        let tagIDsByTask = (try? store.effectiveTagIDsByTask()) ?? [:]
        let membership = SubjectMembership(tasks: tasks, tagIDsByTask: tagIDsByTask)
        var names: [Int64: String] = [:]
        for t in targets { names[t.id] = name(for: t, tasks: tasks) }
        let input = Planner.Input(targets: targets, reservations: reservations,
                                  membership: membership, names: names,
                                  wakingSecondsPerDay: settings.wakingSeconds)
        let built = Planner.plan(input)
        plan = built

        let cal = Calendar.current
        let now = Date()
        today = cal.component(.weekday, from: now)
        guard let week = cal.dateInterval(of: .weekOfYear, for: now) else { replan = nil; return }
        let intervals = (try? store.intervals(from: week.start, to: week.end)) ?? []

        // Per weekday and per allocation, so the grid's solid cells are real hours. Attribution goes
        // through the same `SubjectMembership` the planner uses, so "which hours count for this
        // allocation" has one answer rather than two that can drift.
        let floors = targets.filter { $0.direction == .atLeast }
        let idsBySubject = Dictionary(uniqueKeysWithValues:
            floors.map { ($0.id, membership.taskIDs(for: $0.subject)) })

        var byDay: [Int: [Int64: TimeInterval]] = [:]
        var otherByDay: [Int: TimeInterval] = [:]
        var weekTotals: [Int64: TimeInterval] = [:]
        for interval in intervals {
            let start = max(interval.start, week.start)
            let end = min(interval.end ?? now, week.end)
            guard end > start else { continue }
            let seconds = end.timeIntervalSince(start)
            let weekday = cal.component(.weekday, from: start)
            var claimed = false
            for (id, ids) in idsBySubject where ids.contains(interval.projectID) {
                byDay[weekday, default: [:]][id, default: 0] += seconds
                weekTotals[id, default: 0] += seconds
                claimed = true
            }
            // Hours on something no allocation covers. Shown in the grid because a day that went
            // somewhere unplanned is the commonest reason a plan didn't happen.
            if !claimed { otherByDay[weekday, default: 0] += seconds }
        }
        actuals = byDay
        unallocated = otherByDay

        replan = Replan.compute(plan: built, input: input, actuals: weekTotals,
                                elapsedWeekdays: Array(1..<today),
                                remainingWeekdays: Array(today...7),
                                fractionOfTodayLeft: Replan.fractionOfDayLeft(
                                    now: now, wakingSeconds: settings.wakingSeconds, calendar: cal))
    }

    private func name(for target: Target, tasks: [Project]? = nil) -> String {
        BudgetRows.name(for: target.subject, tasks: tasks ?? appState.projects,
                        groups: appState.taskProjects, tags: appState.allTags) ?? "(deleted)"
    }

    private func name(forTarget id: Int64) -> String {
        targets.first { $0.id == id }.map { name(for: $0) } ?? "?"
    }

    private func colorHex(forTarget id: Int64) -> String {
        guard let target = targets.first(where: { $0.id == id }) else { return "#8E8E93" }
        return BudgetRows.colorHex(for: target.subject, tasks: appState.projects,
                                  groups: appState.taskProjects, tags: appState.allTags)
    }

    // MARK: - Chrome

    private var divider: some View {
        Rectangle().fill(Color.secondary.opacity(0.25))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 12)
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        // A floor, not a fixed width, so a long figure isn't truncated — but wide enough that the row
        // doesn't reflow as the numbers change.
        .frame(minWidth: 62, alignment: .leading)
    }

    private func dayList(_ weekdays: [Int]) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return weekdays.map { names[$0 - 1] }.joined(separator: ", ")
    }

    private func rangeText(_ plan: Planner) -> String {
        let lo = hours(plan.requiredLowerSeconds), hi = hours(plan.requiredUpperSeconds)
        return lo == hi ? lo : "\(lo)–\(hi)"
    }

    private func verdictColor(_ v: Planner.Verdict) -> Color {
        if let replan, replan.weekIsLost { return Self.overColor }
        switch v {
        case .fits: return .green
        case .tight: return .orange
        case .oversubscribed: return Self.overColor
        case .uncertain: return .yellow
        }
    }

    private func hours(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        if h >= 100 { return "\(Int(h.rounded()))h" }
        if h >= 1 { return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h) }
        if seconds < 60 { return "0h" }
        return "\(Int((seconds / 60).rounded()))m"
    }
}

/// Chips that wrap onto the next line instead of running off the edge.
///
/// `HStack` would push them out of the window and `LazyVGrid` would force equal columns onto items
/// whose widths differ by a factor of three, so this lays them out itself.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
