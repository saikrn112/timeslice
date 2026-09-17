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
    @State private var unit: PlanUnit = .week
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
    @State private var calendarDays: [PlannerCalendar.DayInput] = []
    @State private var monthWeeks: [[PlannerMonthGrid.DayCell]] = []
    /// Tap an allocation, in the rail or the grid, to dim everything else. The one interaction on the
    /// page, because "where does THIS one actually land" is the question a week of overlapping colours
    /// can't answer at a glance.
    @State private var highlight: Int64?

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
                    // The allocation strip sits ABOVE the grid, not beside it. As a left-hand rail it
                    // took a fifth of the width from the thing the page is for, which made a calendar
                    // of narrow columns feel cluttered by something that isn't even the calendar.
                    railStrip(plan)
                    if unit == .week {
                        PlannerCalendar(days: calendarDays, nowHour: nowHour,
                                        highlight: highlight) { pick($0) }
                    } else {
                        PlannerMonthGrid(weeks: monthWeeks,
                                         wakingHours: settings.wakingSeconds / 3600,
                                         highlight: highlight) { pick($0) }
                    }
                    legend
                    warnings(plan)
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
        FlowRow(spacing: 8) {
            ForEach(rows, id: \.id) { row in
                railRow(row).frame(width: 196)
            }
        }
    }

    private func railRow(_ row: GoalRow) -> some View {
        let task = startableTask(for: row.id)
        let isRunning = task != nil && engine.runningProjectID == task?.id
        let selected = highlight == row.id
        return HStack(spacing: 5) {
            // The page's only action. A plan you can't act on is a dashboard, and the planner already
            // knows which task it means.
            Button {
                if let task { engine.switchTo(projectID: task.id) }
            } label: {
                Image(systemName: isRunning ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isRunning ? Color.orange : Color(hex: row.colorHex))
            }
            .buttonStyle(.plain)
            .disabled(task == nil)
            .help(task.map { isRunning ? "Running “\($0.name)”" : "Start “\($0.name)”" }
                  ?? "No task to start — this allocation covers nothing trackable")

            Text(row.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                .frame(width: 84, alignment: .leading)

            // The two-tone bar from the metrics allocation rows: the % inside the fill, and a notch for
            // where the fill should be by now. The gap between them is the lag, undescribed.
            InlineBar(fraction: min(1, row.fraction),
                      label: "\(Int((row.fraction * 100).rounded()))%",
                      fill: Color(hex: row.colorHex),
                      height: 14,
                      marker: row.paceFraction)
                .frame(maxWidth: .infinity)

            Text(hours(row.target - min(row.target, row.done)))
                .font(.system(size: 9, design: .monospaced)).monospacedDigit()
                .foregroundStyle(row.lagging ? Self.overColor : Color.secondary.opacity(0.7))
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4)
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

    /// Hours since midnight, for the calendar's now-line.
    private var nowHour: Double {
        let cal = Calendar.current
        let now = Date()
        return now.timeIntervalSince(cal.startOfDay(for: now)) / 3600
    }

    private struct GoalRow: Identifiable {
        let id: Int64
        let name: String
        let colorHex: String
        let done: TimeInterval
        let target: TimeInterval
        /// Where the pace notch goes: how far through the window we are.
        let paceFraction: Double
        let trailing: String
        let lagging: Bool
        let tooltip: String
        var fraction: Double { target > 0 ? done / target : 0 }
    }

    private func goalRowData(_ plan: Planner) -> [GoalRow] {
        let floors = targets.filter { $0.direction == .atLeast }
        let elapsed = elapsedFractionOfPeriod()
        return floors.map { target -> GoalRow in
            // The allocation's weekly rate, pro-rated onto the window. Four weeks in month view, so a
            // 35h/week office reads as 140h and a missed week is visible as month-level lag.
            let scaled = target.weeklySeconds * unit.weeks
            let done = periodActuals[target.id] ?? 0
            let shouldBe = scaled * elapsed
            let behind = max(0, shouldBe - done)
            return GoalRow(
                id: target.id, name: name(for: target),
                colorHex: BudgetRows.colorHex(for: target.subject, tasks: appState.projects,
                                              groups: appState.taskProjects, tags: appState.allTags),
                done: done, target: scaled, paceFraction: elapsed,
                trailing: behind > 60 ? "behind \(hours(behind))"
                          : (done >= scaled ? "met" : "on pace"),
                lagging: behind > 60,
                tooltip: "\(name(for: target)): \(hours(done)) of \(hours(scaled)) this "
                       + "\(unit.rawValue.lowercased())\n"
                       + "should be at \(hours(shouldBe)) by now "
                       + "(\(Int((elapsed * 100).rounded()))% through)\n"
                       + (behind > 60 ? "behind by \(hours(behind))" : "on pace"))
        }
        // Worst first: this page exists to say where you're lagging.
        .sorted {
            if $0.lagging != $1.lagging { return $0.lagging }
            return ($0.paceFraction - $0.fraction) > ($1.paceFraction - $1.fraction)
        }
    }

    /// How far through the viewed window we are, by waking hours rather than by wall clock — being
    /// three days into a week is 43% of the calendar but not necessarily 43% of the hours you had.
    private func elapsedFractionOfPeriod() -> Double {
        guard let window = periodWindow() else { return 1 }
        if offset > 0 { return 1 }              // a window in the past is fully elapsed
        let total = window.end.timeIntervalSince(window.start)
        guard total > 0 else { return 1 }
        return min(1, max(0, Date().timeIntervalSince(window.start) / total))
    }

    // MARK: - Period

    /// Week or month, and which one. Deliberately the same shape as the metrics range pills, because
    /// it means the same thing.
    private var periodBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(PlanUnit.allCases) { candidate in
                    Button {
                        unit = candidate
                        offset = 0
                        rebuild()
                    } label: {
                        Text(candidate.rawValue)
                            .font(.system(size: 12, weight: unit == candidate ? .semibold : .regular))
                            .foregroundStyle(unit == candidate ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().frame(height: 12)
            Button {
                offset += 1
                rebuild()
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Text(periodLabel).font(.system(size: 12, weight: .medium))
                .frame(minWidth: 150, alignment: .leading)
            Button {
                offset = max(0, offset - 1)
                rebuild()
            } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .foregroundStyle(offset == 0 ? Color.secondary.opacity(0.3) : .secondary)
                .disabled(offset == 0)
            Spacer()
        }
    }

    private var periodLabel: String {
        guard let window = periodWindow() else { return "" }
        let f = DateFormatter()
        if unit == .month {
            f.dateFormat = "MMMM yyyy"
            return f.string(from: window.start)
        }
        f.dateFormat = "d MMM"
        let end = window.end.addingTimeInterval(-1)
        return offset == 0 ? "This week · \(f.string(from: window.start))"
                           : "\(f.string(from: window.start)) – \(f.string(from: end))"
    }

    /// The viewed window. Weeks and months both come from `Calendar`, so they line up with what the
    /// metrics page calls a week.
    private func periodWindow() -> DateInterval? {
        let cal = Calendar.current
        let component: Calendar.Component = unit == .week ? .weekOfYear : .month
        guard let anchor = cal.date(byAdding: component, value: -offset, to: Date()),
              let interval = cal.dateInterval(of: component, for: anchor) else { return nil }
        return interval
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
            // Month only. In week view the calendar already shows free time as free space, and a bar
            // saying the same thing in a second visual language is exactly the duplication that made
            // this page tiring. A month cell is too small to read whitespace from, so there the bar
            // earns its place. It reads the VIEWED window either way.
            if unit == .month {
                let budget = periodBudget()
                WeekBudgetBar(capacity: budget.capacity,
                              elapsed: budget.elapsed,
                              tracked: budget.tracked,
                              stillToDo: budget.stillToDo,
                              freeLeft: budget.freeLeft,
                              reservedLeft: budget.reservedLeft,
                              over: budget.stillToDo > budget.freeLeft + 60)
            }

            // The one figure the bar can't hold, because it isn't a slice of the week: what the
            // allocations ADD UP to, which is a range when they overlap.
            Text("allocations want \(rangeText(plan)) a week"
                 + (plan.requiredLowerSeconds == plan.requiredUpperSeconds ? ""
                    : " — a range because some of them cover the same work"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private struct PeriodBudget {
        var capacity: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var tracked: TimeInterval = 0
        var stillToDo: TimeInterval = 0
        var freeLeft: TimeInterval = 0
        var reservedLeft: TimeInterval = 0
    }

    /// The viewed window's hours: the bar's whole length and every segment in it.
    ///
    /// Walks the window's actual dates instead of assuming seven days, so a month works — and a 28-day
    /// one too. Reservations are counted per weekday as it walks, which is the only way to keep "no
    /// commute on Sundays" right over a window longer than a week.
    private func periodBudget() -> PeriodBudget {
        var out = PeriodBudget()
        guard let window = periodWindow() else { return out }
        let cal = Calendar.current
        let now = Date()
        let waking = settings.wakingSeconds
        let startOfToday = cal.startOfDay(for: now)
        let fractionLeftToday = Replan.fractionOfDayLeft(now: now, wakingSeconds: waking,
                                                         calendar: cal)

        var cursor = cal.startOfDay(for: window.start)
        while cursor < window.end {
            let weekday = cal.component(.weekday, from: cursor)
            let reserved = min(waking, reservations
                .filter { $0.weekdays.effective.contains(weekday: weekday) }
                .reduce(0.0) { $0 + $1.secondsPerDay })
            out.capacity += waking

            if cursor < startOfToday {
                out.elapsed += waking            // gone entirely
            } else if cursor == startOfToday {
                out.elapsed += waking * (1 - fractionLeftToday)
                out.freeLeft += max(0, waking - reserved) * fractionLeftToday
                out.reservedLeft += reserved * fractionLeftToday
            } else {
                out.freeLeft += max(0, waking - reserved)
                out.reservedLeft += reserved
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        out.tracked = periodTracked
        // What the allocations still want inside this window, at the window's own scale.
        out.stillToDo = targets.filter { $0.direction == .atLeast }.reduce(0.0) { sum, target in
            sum + max(0, target.weeklySeconds * unit.weeks - (periodActuals[target.id] ?? 0))
        }
        return out
    }

    /// The verdict as one clause. The paragraph that used to follow it is gone: what it explained is
    /// visible in the grid, and the numbers beside it carry the arithmetic.
    private func verdictLine(_ plan: Planner) -> String {
        // Says what the comparison IS. "Not finishable" was a conclusion with its reasoning hidden,
        // which is exactly the kind of number nobody can argue with or trust.
        if let replan, replan.weekIsLost {
            return "\(hours(replan.remainingNeedSeconds)) still to do, only "
                 + "\(hours(replan.remainingCapacitySeconds)) of free hours left in the week"
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
            // The VIEWED week, which is only today's week at offset 0. Stepping back has to redraw the
            // grid from that week's own intervals; reusing the current week's would show last week's
            // header above this week's blocks.
            let viewed = periodWindow() ?? week
            let viewedIntervals = offset == 0 ? intervals
                : ((try? store.intervals(from: viewed.start,
                                         to: viewed.end.addingTimeInterval(7200))) ?? [])
            calendarDays = buildWeekColumns(week: viewed, intervals: viewedIntervals,
                                            replan: computed, owner: owner, taskNames: taskNames,
                                            calendar: cal)
            monthWeeks = []
        } else {
            calendarDays = []
            monthWeeks = buildMonthCells(store: store, owner: owner, calendar: cal)
        }
    }

    /// Seven day columns for the viewed week.
    ///
    /// Tracked blocks come from `Aggregations.daySegments`, the same source the metrics day timeline
    /// draws, so a block sits in the same place on both pages. Owed hours come from the replan, which
    /// has already spread each shortfall over the days that are actually left — so a Monday that went
    /// wrong shows up as extra hatching later in the week rather than as a sentence about Monday.
    private func buildWeekColumns(week: DateInterval, intervals: [Interval], replan: Replan,
                                  owner: (Int64) -> Int64?, taskNames: [Int64: String],
                                  calendar cal: Calendar) -> [PlannerCalendar.DayInput] {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let startOfToday = cal.startOfDay(for: Date())
        // Worst lag first, because the packer gives the earliest gaps to whatever comes first.
        let owedOrder = replan.items.sorted { $0.debtSeconds > $1.debtSeconds }.map(\.targetID)

        var out: [PlannerCalendar.DayInput] = []
        for offsetDays in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: offsetDays, to: week.start) else { break }
            let weekday = cal.component(.weekday, from: date)
            let dayStart = cal.startOfDay(for: date)

            // Grouped by ALLOCATION, then merged across gaps under ten minutes. A week is ~150 raw
            // intervals because every task switch and every short pause starts a new row; drawn
            // literally that's confetti, and a planner made of confetti hides the shape of the week.
            // Blocks are named after the allocation for the same reason: this page is about goals, and
            // the task name is a level of detail the tooltip can carry.
            var keyed: [CalendarLayout.Keyed] = []
            for seg in Aggregations.daySegments(intervals: intervals, day: date, calendar: cal) {
                keyed.append(CalendarLayout.Keyed(key: owner(seg.projectID) ?? -1,
                                                  span: CalendarLayout.Span(start: seg.startHour,
                                                                            end: seg.endHour)))
            }
            // Work that ran past midnight belongs to the evening it started in, so the small hours of
            // the NEXT day are drawn at the bottom of this column at +24. Without this a session from
            // 22:00 to 01:00 lost its last hour off the bottom of one column and the top of another.
            if let next = cal.date(byAdding: .day, value: 1, to: date) {
                for seg in Aggregations.daySegments(intervals: intervals, day: next, calendar: cal)
                where seg.startHour < PlannerCalendar.bandEnd - 24 {
                    keyed.append(CalendarLayout.Keyed(
                        key: owner(seg.projectID) ?? -1,
                        span: CalendarLayout.Span(start: seg.startHour + 24,
                                                  end: min(PlannerCalendar.bandEnd,
                                                           seg.endHour + 24))))
                }
            }
            var blocks: [PlannerCalendar.TrackedBlock] = []
            for (index, run) in CalendarLayout.runs(keyed, maxGapHours: 10.0 / 60).enumerated() {
                let allocated = run.key >= 0
                blocks.append(PlannerCalendar.TrackedBlock(
                    id: Int64(weekday * 1000 + index),
                    startHour: run.span.start, endHour: run.span.end,
                    name: allocated ? name(forTarget: run.key) : "other",
                    colorHex: allocated ? colorHex(forTarget: run.key) : "#8E8E93",
                    targetID: allocated ? run.key : nil))
            }

            let reserved = reservations
                .filter { $0.weekdays.effective.contains(weekday: weekday) }
                .reduce(0.0) { $0 + $1.secondsPerDay } / 3600

            // Only days that are still to come can owe anything. A past day is a fact.
            var owed: [PlannerCalendar.OwedItem] = []
            if dayStart >= startOfToday, offset == 0,
               let planned = replan.replannedDays.first(where: { $0.weekday == weekday }) {
                let byID = Dictionary(planned.placements.map { ($0.targetID, $0) },
                                      uniquingKeysWith: { a, _ in a })
                for id in owedOrder {
                    guard let placement = byID[id], placement.seconds > 60 else { continue }
                    let done = (actuals[weekday] ?? [:])[id] ?? 0
                    let left = max(0, placement.seconds - done) / 3600
                    guard left > 1.0 / 60 else { continue }
                    owed.append(PlannerCalendar.OwedItem(id: id, name: name(forTarget: id),
                                                         hours: left,
                                                         colorHex: colorHex(forTarget: id)))
                }
            }

            out.append(PlannerCalendar.DayInput(
                weekday: weekday, label: names[weekday - 1],
                dayOfMonth: cal.component(.day, from: date),
                isPast: dayStart < startOfToday, isToday: dayStart == startOfToday,
                reservedHours: min(settings.wakingSeconds / 3600, reserved),
                tracked: blocks, owed: owed))
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
        guard let target = targets.first(where: { $0.id == id }) else { return "#8E8E93" }
        return BudgetRows.colorHex(for: target.subject, tasks: appState.projects,
                                  groups: appState.taskProjects, tags: appState.allTags)
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
