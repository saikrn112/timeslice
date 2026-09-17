import SwiftUI
import TimesliceCore
import TimesliceUI

/// Whether the week is possible, drawn as a calendar.
///
/// Four earlier shapes were tried, and each one added a region: paragraphs, then a per-day list plus a
/// per-allocation table, then an hour grid plus a lagging list plus chips, then a verdict plus a budget
/// bar plus goal rows plus a today card plus a matrix. All of them asked you to READ whether the week
/// held together, from numbers in several different frames.
///
/// A calendar answers it by construction. `PlannerCalendar` draws what was tracked at the time it
/// happened and packs what an allocation still owes into the gaps that are left; if the owed hours have
/// nowhere to go, the column says so. Free time is free space. The now-line is where the past stops, so
/// the page reads differently at 9am and at 11pm without being told the time. Catch-up appears as
/// hatching pushed into the days that remain, because those are the only days the packer has.
///
/// The rail beside it is the allocation list — what you're chasing, with the % inside its own bar — and
/// doubles as the colour legend, so the two halves are one object instead of two summaries. Tapping an
/// allocation in either half dims the rest.
///
/// Month view is the same idea one zoom out: a real month grid whose cells fill up, for deciding how to
/// play catch-up across the weeks ahead.
///
/// Every figure still comes from `Planner`, `Replan` and `CalendarLayout` in Core, so
/// `swift run TimeslicePlan --db <path>` prints the same numbers and the page is checkable against
/// arithmetic rather than by eye — which matters because macOS UI can't be screenshotted headlessly.
struct PlannerView: View {
    @ObservedObject var appState: AppState
    /// The timer, because a plan you can't act on is a dashboard. Every other page in this app does
    /// something; this one could only be read, which is most of why it felt inert.
    @ObservedObject var engine: TimerEngine
    @ObservedObject var settings: AppSettings

    @State private var targets: [Target] = []
    @State private var reservations: [Reservation] = []
    @State private var plan: Planner?
    @State private var replan: Replan?
    /// weekday → target id → seconds tracked this week, for the solid cells.
    @State private var actuals: [Int: [Int64: TimeInterval]] = [:]
    /// weekday → seconds tracked against something no allocation covers.
    @State private var unallocated: [Int: TimeInterval] = [:]
    /// weekday → every tracked second. What a past day's load really was, rather than what it was
    /// meant to be.
    @State private var actualTotals: [Int: TimeInterval] = [:]
    @State private var today = 1
    /// Week or month. The allocation is a RATE, and the unit only changes the window it's read
    /// through — the same trick the metrics allocation rows use for their second column of bars. So
    /// "did I catch up on the weeks I missed" is a month-view question about the same numbers, not a
    /// second set of goals with their own bookkeeping.
    @State private var unit: PlanUnit = ProcessInfo.processInfo
        .environment["TIMESLICE_PLANNER_UNIT"]?.lowercased() == "month" ? .month : .week
    /// How many periods back from the current one. 0 is now; 1 is last week or last month.
    @State private var offset = 0
    /// Per allocation, seconds tracked inside the viewed period.
    @State private var periodActuals: [Int64: TimeInterval] = [:]
    /// Every second tracked inside the viewed period, allocation or not — the bar's "tracked" segment.
    @State private var periodTracked: TimeInterval = 0
    @State private var showReservations = false
    @State private var showAllocations = false
    /// Built once per rebuild rather than per redraw: the calendar needs every interval placed at its
    /// real clock position, and doing that inside `body` would re-query sqlite on every hover.
    @State private var calendarDays: [PlannerWeekGrid.DayInput] = []
    @State private var monthWeeks: [[PlannerMonthGrid.DayCell]] = []
    /// Tap an allocation, in the rail or the grid, to dim everything else. The one interaction on the
    /// page, because "where does THIS one actually land" is the question a week of overlapping colours
    /// can't answer at a glance.
    @State private var highlight: Int64?
    /// Allocation id → the colour it's drawn in, made distinct.
    ///
    /// `BudgetRows.colorHex` answers per subject, and three of the real allocations are tags that share
    /// one colour — recon paper, deep technical creative and family all came out the same red, which on a
    /// calendar of coloured blocks means the colours carry no information at all.
    @State private var targetColors: [Int64: String] = [:]

    /// The red used for over-capacity, matching the metrics selection overlay so one colour means one
    /// thing across both pages.
    static let overColor = Color(red: 0.90, green: 0.30, blue: 0.32)

    enum PlanUnit: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month"
        var id: String { rawValue }
        /// Nominal length, used to pro-rate a weekly allocation onto the window. A month is four weeks
        /// here for the same reason `Target.Period` calls it 30 days: an allocation is an intention,
        /// and a calendar-exact month would make the same one read differently in February.
        var weeks: Double { self == .week ? 1 : 4 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let plan {
                    periodBar
                    headline(plan)
                    section("Allocations",
                            subtitle: "click one to trace it through the "
                                      + unit.rawValue.lowercased(),
                            accessory: { EmptyView() }) {
                        railStrip(plan)
                    }
                    section(unit == .week ? "How full each day is" : "This month, day by day",
                            subtitle: calendarSubtitle,
                            accessory: { legend }) {
                        if unit == .week {
                            PlannerWeekGrid(days: calendarDays,
                                            capacityHours: settings.wakingSeconds / 3600,
                                            elapsedHoursToday: offset == 0 ? elapsedHoursToday : nil,
                                            highlight: highlight) { pick($0) }
                        } else {
                            PlannerMonthGrid(weeks: monthWeeks,
                                             wakingHours: settings.wakingSeconds / 3600,
                                             highlight: highlight) { pick($0) }
                        }
                    }
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

    // MARK: - Goals

    /// One row per allocation, read through the viewed window, worst lag first.
    ///
    /// This is the part that gets looked at constantly, so it's the part that has to answer in one
    /// glance: how far through this allocation am I, and how far through should I be. The bar carries
    /// its own percentage in the same two-tone way the metrics allocation bars do — the figure sits
    /// inside the fill, so a row needs no second column to be readable.
    ///
    /// The window is the whole trick. An allocation is a RATE, so month view reads the same 35h/week
    /// office as 140h and a skipped week shows up as being behind on the month. No separate monthly
    /// goals, no debt bookkeeping.
    @ViewBuilder
    private func railStrip(_ plan: Planner) -> some View {
        let rows = goalRowData(plan)
        // A fixed two-column grid, because a FlowRow of chips wrapped into a ragged shape whose bars
        // were squeezed to fifty points — narrow enough that "0%" spilled out of its own pill. Two
        // columns of aligned rows costs the same vertical space and reads as a table instead of debris.
        let columns = [GridItem(.adaptive(minimum: 268), spacing: 18)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.id) { row in
                railRow(row)
            }
        }
    }

    private func railRow(_ row: GoalRow) -> some View {
        let selected = highlight == row.id
        return HStack(spacing: 7) {
            Circle().fill(Color(hex: row.colorHex)).frame(width: 7, height: 7)
            Text(row.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                .frame(width: 96, alignment: .leading)
            InlineBar(fraction: min(1, row.fraction),
                      label: "\(Int((row.fraction * 100).rounded()))%",
                      fill: Color(hex: row.colorHex),
                      height: 13,
                      marker: row.paceFraction)
                .frame(maxWidth: .infinity)
            // What's left, not what's behind: on a planning page the actionable figure is the one you
            // still have to find room for.
            Text(hours(max(0, row.target - row.done)))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(row.lagging ? Color.orange : Color.secondary.opacity(0.75))
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.vertical, 2).padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? Color.accentColor.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { pick(row.id) }
        .help(row.tooltip)
    }

    private func pick(_ id: Int64) {
        highlight = (highlight == id) ? nil : id
    }

    /// What the two block styles mean, once, in nine words. The alternative is a tooltip nobody hovers
    /// or a paragraph nobody reads.
    private var legend: some View {
        HStack(spacing: 12) {
            legendKey(filled: true, "tracked")
            legendKey(filled: false, "still to fit")
            HStack(spacing: 4) {
                Hatch(color: .secondary).frame(width: 14, height: 9)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("reserved").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if highlight != nil {
                Button("show all") { highlight = nil }
                    .buttonStyle(.link).font(.system(size: 9))
            }
            Spacer()
        }
    }

    private func legendKey(filled: Bool, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(filled ? 0.85 : 0.16))
                .overlay {
                    if !filled {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.accentColor.opacity(0.75),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .frame(width: 14, height: 9)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var calendarSubtitle: String {
        unit == .week
            ? "each column is a waking day · solid is tracked, dashed is still owed"
            : "each cell fills toward a waking day"
    }

    /// Waking hours already gone today: where the "now" rule sits in a column measured in hours.
    private var elapsedHoursToday: Double {
        let waking = settings.wakingSeconds
        let left = Replan.fractionOfDayLeft(now: Date(), wakingSeconds: waking) * waking
        return max(0, waking - left) / 3600
    }

    /// The task the play button should start for an allocation.
    ///
    /// An allocation can point at a tag covering fifty tasks, so this picks the one you most recently
    /// worked on — the same recency order the switcher's cycle uses, so the planner's guess and the
    /// switcher's first suggestion agree instead of being two different opinions.
    private func startableTask(for targetID: Int64) -> Project? {
        guard let target = targets.first(where: { $0.id == targetID }) else { return nil }
        let tasks = (try? appState.storeForEditing.listProjects(includeArchived: true)) ?? []
        let ids = SubjectMembership(tasks: tasks,
                                   tagIDsByTask: (try? appState.storeForEditing
                                       .effectiveTagIDsByTask()) ?? [:])
            .taskIDs(for: target.subject)
        return appState.recencyOrderedProjects.first { ids.contains($0.id) }
    }

    // MARK: - Chips

    /// The few things the matrix genuinely can't say: allocations that never fit at all, nesting, and
    /// the warning that no reservations are declared. Everything else the chips used to repeat is now
    /// a row or a column.
    @ViewBuilder
    private func warnings(_ plan: Planner) -> some View {
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
        assignColors()
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
        let intervals = (try? store.intervals(from: week.start,
                                              to: week.end.addingTimeInterval(7200))) ?? []

        // Per weekday and per allocation, so the grid's solid cells are real hours. Attribution goes
        // through the same `SubjectMembership` the planner uses, so "which hours count for this
        // allocation" has one answer rather than two that can drift.
        let floors = targets.filter { $0.direction == .atLeast }
        let idsBySubject = Dictionary(uniqueKeysWithValues:
            floors.map { ($0.id, membership.taskIDs(for: $0.subject)) })

        var byDay: [Int: [Int64: TimeInterval]] = [:]
        var otherByDay: [Int: TimeInterval] = [:]
        var totalByDay: [Int: TimeInterval] = [:]
        var weekTotals: [Int64: TimeInterval] = [:]
        for interval in intervals {
            let start = max(interval.start, week.start)
            let end = min(interval.end ?? now, week.end)
            guard end > start else { continue }
            let seconds = end.timeIntervalSince(start)
            let weekday = cal.component(.weekday, from: start)
            totalByDay[weekday, default: 0] += seconds
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
        actualTotals = totalByDay

        // The viewed window's own totals, which is what the goal rows read. Separate from the weekly
        // figures above because the window can be a month, or a week that has already gone.
        if let window = periodWindow() {
            let inWindow = (try? store.intervals(from: window.start, to: window.end)) ?? []
            var scoped: [Int64: TimeInterval] = [:]
            var total: TimeInterval = 0
            for interval in inWindow {
                let start = max(interval.start, window.start)
                let end = min(interval.end ?? now, window.end)
                guard end > start else { continue }
                let seconds = end.timeIntervalSince(start)
                total += seconds
                for (id, ids) in idsBySubject where ids.contains(interval.projectID) {
                    scoped[id, default: 0] += seconds
                }
            }
            periodActuals = scoped
            periodTracked = total
        }

        let computed = Replan.compute(plan: built, input: input, actuals: weekTotals,
                                      elapsedWeekdays: Array(1..<today),
                                      remainingWeekdays: Array(today...7),
                                      fractionOfTodayLeft: Replan.fractionOfDayLeft(
                                          now: now, wakingSeconds: settings.wakingSeconds,
                                          calendar: cal))
        replan = computed

        // The most specific allocation wins an interval's colour: a task inside both `office` and
        // `presentation for KT` belongs, visually, to the narrower of the two. Sorting by set size once
        // makes that a lookup rather than a search per block.
        let bySize = idsBySubject.sorted { $0.value.count < $1.value.count }
        func owner(_ projectID: Int64) -> Int64? {
            bySize.first { $0.value.contains(projectID) }?.key
        }
        let taskNames = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.name) })

        if unit == .week {
            calendarDays = buildWeekColumns(week: periodWindow() ?? week, replan: computed,
                                            calendar: cal)
            monthWeeks = []
        } else {
            calendarDays = []
            monthWeeks = buildMonthCells(store: store, owner: owner, calendar: cal)
        }
    }

    /// Seven day containers for the viewed week.
    ///
    /// Sums, not positions: one blob per allocation per day. That is the whole simplification — the
    /// clock version had to place 150 intervals a week and then explain the resulting mess.
    ///
    /// Owed hours come from the replan, which has already spread each shortfall across the days that are
    /// actually left, so a Monday that went wrong shows up as taller dashed blobs later in the week
    /// rather than as a sentence about Monday.
    private func buildWeekColumns(week: DateInterval, replan: Replan,
                                  calendar cal: Calendar) -> [PlannerWeekGrid.DayInput] {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let startOfToday = cal.startOfDay(for: Date())
        let owedOrder = replan.items.sorted { $0.debtSeconds > $1.debtSeconds }.map(\.targetID)

        var out: [PlannerWeekGrid.DayInput] = []
        for offsetDays in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: offsetDays, to: week.start) else { break }
            let weekday = cal.component(.weekday, from: date)
            let dayStart = cal.startOfDay(for: date)
            var blobs: [PlannerWeekGrid.Blob] = []

            // Bottom of the column: hours that were never available to anything.
            let reserved = reservations
                .filter { $0.weekdays.effective.contains(weekday: weekday) }
                .reduce(0.0) { $0 + $1.secondsPerDay } / 3600
            if reserved > 0.02 {
                blobs.append(PlannerWeekGrid.Blob(targetID: -1, name: "reserved", hours: reserved,
                                                  colorHex: "#8E8E93", kind: .reserved))
            }

            // Then what was tracked, biggest first so the day reads top-down by size.
            for (id, seconds) in (actuals[weekday] ?? [:]).sorted(by: { $0.value > $1.value })
            where seconds > 60 {
                blobs.append(PlannerWeekGrid.Blob(targetID: id, name: name(forTarget: id),
                                                  hours: seconds / 3600,
                                                  colorHex: colorHex(forTarget: id), kind: .tracked))
            }
            if let other = unallocated[weekday], other > 60 {
                blobs.append(PlannerWeekGrid.Blob(targetID: -2, name: "unallocated", hours: other / 3600,
                                                  colorHex: "#8E8E93", kind: .unallocated))
            }

            // Then what is still owed — only on days that are still to come, and only in the week that
            // is actually current. A past week owes nothing; it is simply what happened.
            if dayStart >= startOfToday, offset == 0,
               let planned = replan.replannedDays.first(where: { $0.weekday == weekday }) {
                let byID = Dictionary(planned.placements.map { ($0.targetID, $0) },
                                      uniquingKeysWith: { a, _ in a })
                for id in owedOrder {
                    guard let placement = byID[id], placement.seconds > 60 else { continue }
                    let done = (actuals[weekday] ?? [:])[id] ?? 0
                    let left = max(0, placement.seconds - done) / 3600
                    guard left > 1.0 / 60 else { continue }
                    blobs.append(PlannerWeekGrid.Blob(targetID: id, name: name(forTarget: id), hours: left,
                                                      colorHex: colorHex(forTarget: id), kind: .owed))
                }
            }

            out.append(PlannerWeekGrid.DayInput(
                weekday: weekday, label: names[weekday - 1],
                dayOfMonth: cal.component(.day, from: date),
                isPast: dayStart < startOfToday, isToday: dayStart == startOfToday,
                blobs: blobs))
        }
        return out
    }

    /// The month as full weeks, including the leading and trailing days that complete the first and last
    /// rows — a month grid that stopped at the 1st and the 31st wouldn't be a calendar.
    private func buildMonthCells(store: IntervalStore, owner: (Int64) -> Int64?,
                                 calendar cal: Calendar) -> [[PlannerMonthGrid.DayCell]] {
        guard let month = periodWindow(),
              let firstRow = cal.dateInterval(of: .weekOfYear, for: month.start),
              let lastRow = cal.dateInterval(of: .weekOfYear,
                                             for: month.end.addingTimeInterval(-1))
        else { return [] }

        let intervals = (try? store.intervals(from: firstRow.start, to: lastRow.end)) ?? []
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let waking = settings.wakingSeconds

        // Per date, per allocation, seconds tracked.
        var byDate: [Date: [Int64: TimeInterval]] = [:]
        for interval in intervals {
            let end = interval.end ?? now
            guard end > interval.start else { continue }
            let day = cal.startOfDay(for: interval.start)
            let id = owner(interval.projectID) ?? -1
            byDate[day, default: [:]][id, default: 0] += end.timeIntervalSince(interval.start)
        }

        let floors = targets.filter { $0.direction == .atLeast }
        var rows: [[PlannerMonthGrid.DayCell]] = []
        var cursor = firstRow.start
        while cursor < lastRow.end {
            var row: [PlannerMonthGrid.DayCell] = []
            for _ in 0..<7 {
                let weekday = cal.component(.weekday, from: cursor)
                let tracked = (byDate[cursor] ?? [:])
                    .sorted { $0.value > $1.value }
                    .map { PlannerMonthGrid.Slice(
                        id: $0.key, hours: $0.value / 3600,
                        colorHex: $0.key < 0 ? "#8E8E93" : colorHex(forTarget: $0.key)) }

                // What the allocations want of this weekday, evenly across the days they claim. For a
                // day that has gone, nothing: the cell shows what happened, not what was meant to.
                var planned: Double = 0
                if cursor >= startOfToday {
                    for target in floors {
                        let claimed = target.weekdays.effective
                        guard claimed.contains(weekday: weekday) else { continue }
                        planned += target.weeklySeconds / Double(max(1, claimed.selectedCount)) / 3600
                    }
                }
                let reserved = reservations
                    .filter { $0.weekdays.effective.contains(weekday: weekday) }
                    .reduce(0.0) { $0 + $1.secondsPerDay } / 3600

                row.append(PlannerMonthGrid.DayCell(
                    date: cursor, dayOfMonth: cal.component(.day, from: cursor),
                    inMonth: cursor >= month.start && cursor < month.end,
                    isToday: cursor == startOfToday, isPast: cursor < startOfToday,
                    reservedHours: min(waking / 3600, reserved),
                    tracked: tracked, plannedHours: planned))
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            rows.append(row)
        }
        return rows
    }

    private func name(for target: Target, tasks: [Project]? = nil) -> String {
        BudgetRows.name(for: target.subject, tasks: tasks ?? appState.projects,
                        groups: appState.taskProjects, tags: appState.allTags) ?? "(deleted)"
    }

    private func name(forTarget id: Int64) -> String {
        targets.first { $0.id == id }.map { name(for: $0) } ?? "?"
    }

    private func colorHex(forTarget id: Int64) -> String {
        if let assigned = targetColors[id] { return assigned }
        guard let target = targets.first(where: { $0.id == id }) else { return "#8E8E93" }
        return BudgetRows.colorHex(for: target.subject, tasks: appState.projects,
                                  groups: appState.taskProjects, tags: appState.allTags)
    }

    /// Assign each allocation a colour that isn't already taken, by shading the duplicates.
    ///
    /// Deterministic and stable: it walks the allocations in id order, so a colour doesn't move around
    /// as the sort order of the rows changes.
    private func assignColors() {
        var used: Set<String> = []
        var out: [Int64: String] = [:]
        for target in targets.sorted(by: { $0.id < $1.id }) {
            let base = BudgetRows.colorHex(for: target.subject, tasks: appState.projects,
                                           groups: appState.taskProjects, tags: appState.allTags)
            var candidate = base
            var step = 0
            // A different HUE from the shared palette, not a lighter version of the same one. Two shades
            // of the same red still read as "the same thing" on a grid of coloured blocks, which is the
            // problem being solved. Palette is what Tasks and Metrics colour by, so the page stays in
            // the app's own vocabulary.
            while used.contains(candidate.lowercased()), step < Palette.colors.count + 6 {
                candidate = Palette.color(forIndex: step)
                step += 1
            }
            used.insert(candidate.lowercased())
            out[target.id] = candidate
        }
        targetColors = out
    }

    /// Scale a hex colour's channels, clamped. Cheap, and enough to tell two reds apart.
    private static func shade(_ hex: String, by factor: Double) -> String {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return hex }
        let channels = [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
            .map { Int((Double($0) * factor).rounded()) }
            .map { max(24, min(235, $0)) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }

    // MARK: - Chrome

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
