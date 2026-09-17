import SwiftUI
import TimesliceCore
import TimesliceUI

/// Whether the week is possible, and what to do about it today.
///
/// Three shapes were tried before this one, and the lesson from each was the same: every round ADDED a
/// section, so the page grew instead of getting clearer. Paragraphs, then a per-day list plus a
/// per-allocation table, then an hour-cell grid plus a lagging list plus chips. Three visuals that each
/// answer part of a question are worse than one that answers all of it.
///
/// So the page is two things. A **today card** — what to do now, which is what most visits are actually
/// asking and what every earlier version answered last or not at all. And `PlannerMatrix` — allocations
/// down, days across — where reading a row says what you're behind on and reading down the column under
/// its unfinished cells says why: the day is already full. The collision is spatial, so it costs no
/// prose.
///
/// Every figure comes from `Planner` and `Replan` in Core, so `swift run TimeslicePlan --db <path>`
/// prints the same numbers and the page can be checked against arithmetic rather than by eye — which
/// matters because macOS UI can't be screenshotted headlessly.
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
    /// Every second tracked inside the viewed period, allocation or not.
    @State private var periodTracked: TimeInterval = 0
    @State private var showReservations = false
    @State private var showAllocations = false

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
                    // Week and month are different questions, so they get different bodies rather than
                    // one body plus a second copy of it. Days only exist in week view; month view is
                    // the same allocations read through a four-week window, which is exactly the goal
                    // rows and nothing else. Showing both was the duplication that made the page feel
                    // like more than it is.
                    if unit == .week {
                        if let replan { todayCard(plan, replan) }
                        PlannerMatrix(plan: plan, replan: replan, actuals: actuals,
                                      actualTotals: actualTotals, today: today,
                                      paceFraction: elapsedFractionOfPeriod(),
                                      nestedIn: nestedIn(plan),
                                      colorFor: colorHex(forTarget:), nameFor: name(forTarget:))
                    } else {
                        goalRows(plan)
                    }
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
    private func goalRows(_ plan: Planner) -> some View {
        let rows = goalRowData(plan)
        VStack(spacing: 3) {
            ForEach(rows, id: \.id) { row in
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: row.colorHex)).frame(width: 8, height: 8)
                    Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        .frame(width: 140, alignment: .leading).help(row.name)

                    InlineBar(fraction: min(1, row.fraction),
                              label: "\(Int((row.fraction * 100).rounded()))%",
                              fill: Color(hex: row.colorHex),
                              height: 15,
                              // Where you SHOULD be by now, as a notch. The gap between the fill and
                              // the notch is the lag, without a number for it.
                              marker: row.paceFraction)
                        .frame(maxWidth: .infinity)

                    Text("\(hours(row.done)) of \(hours(row.target))")
                        .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                        .frame(width: 104, alignment: .trailing)
                    Text(row.trailing)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(row.lagging ? Self.overColor : Color.secondary)
                        .frame(width: 96, alignment: .leading)
                }
                .help(row.tooltip)
            }
        }
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
        let brief = self.brief(plan)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(brief.tint).frame(width: 9, height: 9)
                // An instruction, not a diagnosis. "Sat over capacity" is a fact you then have to think
                // about; "do research next, 1.1h of today left" is the thinking already done. This page
                // is supposed to hand back a decision, not another thing to read.
                Text(brief.text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(brief.tint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reserve…") { showReservations = true }
                    .buttonStyle(.link).font(.system(size: 11))
                Button("Allocations…") { showAllocations = true }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            // Follows the Week/Month switch and the back arrows. It was pinned to the current week,
            // so browsing to last month left a bar describing a week nobody was looking at.
            let budget = periodBudget()
            WeekBudgetBar(capacity: budget.capacity,
                          elapsed: budget.elapsed,
                          tracked: budget.tracked,
                          stillToDo: budget.stillToDo,
                          freeLeft: budget.freeLeft,
                          reservedLeft: budget.reservedLeft,
                          over: budget.stillToDo > budget.freeLeft + 60)
                // What the allocations add up to lives here rather than as a line of its own. It's
                // context for the bar, and a sentence explaining why a total is a range is exactly the
                // kind of paragraph this page kept accumulating.
                .help("Allocations want \(rangeText(plan)) a week"
                      + (plan.requiredLowerSeconds == plan.requiredUpperSeconds ? "."
                         : " — a range, because some of them cover the same work.")
                      + "\nThe bar is the \(unit.rawValue.lowercased())'s waking hours; the line is now.")
        }
    }

    /// The single most useful sentence the page can produce, and its colour.
    ///
    /// Deliberately one thing: the worst problem, phrased as what to do about it. Everything below is
    /// the evidence, for the times you want to argue with it.
    private func brief(_ plan: Planner) -> (text: String, tint: Color) {
        // Month view is about catch-up across weeks, so it answers with the biggest arrears.
        if unit == .month {
            let rows = goalRowData(plan).filter { $0.lagging }
            guard let worst = rows.first else {
                return (offset == 0 ? "On pace for the month." : "Nothing was behind that month.",
                        .green)
            }
            let total = rows.reduce(0.0) { $0 + max(0, $1.target * $1.paceFraction - $1.done) }
            return ("Behind on \(worst.name)"
                    + (rows.count > 1 ? " and \(rows.count - 1) more" : "")
                    + " — \(hours(total)) to make up this month.", .orange)
        }
        if offset > 0 {
            let rows = goalRowData(plan).filter { $0.lagging }
            guard let worst = rows.first else { return ("That week held together.", .green) }
            return ("That week missed \(worst.name)"
                    + (rows.count > 1 ? " and \(rows.count - 1) more." : "."), .secondary)
        }
        guard let replan else { return (verdictLine(plan), verdictColor(plan.verdict)) }

        let dayLeft = hoursLeftToday()
        // Ranked by how far behind it is, full stop — NOT by category. Ranking unreachable first put
        // "presentation for KT can't finish, needs 50m" above "vllm is 3.7h behind", which is the page
        // choosing the most dramatic sentence over the most useful one. Whether it's out of reach is
        // then part of how that one item is phrased.
        if let worst = replan.items.filter({ $0.standing != .met })
            .max(by: { $0.debtSeconds < $1.debtSeconds }), worst.debtSeconds > 60 {
            if worst.standing == .unreachable {
                return ("\(worst.name) can't finish this week — needs "
                        + "\(hours(worst.remainingSeconds)) and its remaining days hold "
                        + "\(hours(worst.availableOnRemainingDays)).", Self.overColor)
            }
            let fits = (worst.requiredPerRemainingDay ?? 0) <= dayLeft
            return ("Do \(worst.name) next — \(hours(worst.debtSeconds)) behind, "
                    + (dayLeft < 1800
                       ? "and today is gone."
                       : "\(hours(dayLeft)) of today left"
                         + (fits ? "." : ", less than a day's share of it.")),
                    dayLeft < 1800 ? Self.overColor : .orange)
        }
        if replan.weekIsLost {
            return ("\(hours(replan.remainingNeedSeconds)) still to do against "
                    + "\(hours(replan.remainingCapacitySeconds)) of free hours left.", Self.overColor)
        }
        return (dayLeft < 1800 ? "On pace, and today is done."
                : "On pace — \(hours(dayLeft)) of today left.", .green)
    }

    /// Allocation → the allocation it sits inside. Feeds the matrix tooltips.
    private func nestedIn(_ plan: Planner) -> [Int64: String] {
        var out: [Int64: String] = [:]
        for n in plan.nestings {
            if let inner = targets.first(where: { name(for: $0) == n.innerName }) {
                out[inner.id] = n.outerName
            }
        }
        return out
    }

    private struct PeriodBudget {
        var capacity: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var tracked: TimeInterval = 0
        var stillToDo: TimeInterval = 0
        var freeLeft: TimeInterval = 0
        var reservedLeft: TimeInterval = 0
    }

    /// The viewed window's hours, whatever the window is.
    ///
    /// Walks the actual dates rather than assuming seven days, so a month works and so does a month
    /// with 28 days in it. Reservations are counted per weekday as the walk goes, which is the only way
    /// to get "no commute on Sundays" right over a window longer than a week.
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
                .filter { $0.claims(weekday: weekday) }
                .reduce(0.0) { $0 + $1.secondsPerDay })
            out.capacity += waking

            if cursor < startOfToday {
                // Gone entirely.
                out.elapsed += waking
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
            let scaled = target.weeklySeconds * unit.weeks
            return sum + max(0, scaled - (periodActuals[target.id] ?? 0))
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

    // MARK: - Today

    /// What to do now.
    ///
    /// The question most visits to this page are actually asking, and the one every previous version
    /// answered last or not at all. It sits above the matrix because "am I over-committed" is a
    /// question you ask once a month and "what should I be doing" is one you ask daily.
    @ViewBuilder
    private func todayCard(_ plan: Planner, _ replan: Replan) -> some View {
        // Explicit types, and the row extracted below. Left inline, the type-checker gave up on
        // this closure and silently tried the `ForEach($binding)` overload instead, whose error
        // ("cannot convert [Placement] to Binding<C>") points nowhere near the actual problem.
        let day: Planner.DayPlan? = plan.days.first { $0.weekday == today }
        let wanted: [Planner.Placement] = (day?.placements ?? []).sorted { $0.seconds > $1.seconds }
        let left = hoursLeftToday()
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Today").font(.system(size: 12, weight: .semibold))
                // The clock, and what's left of the day by it. Without this the card read the same at
                // 9am and at 11pm — "1.7h to go" is a plan in the morning and a fiction at night, and
                // the page had no way to tell you which one you were looking at.
                Text(clockText())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(left < 1800 ? "· the day is done"
                                 : "· \(hours(left)) of waking hours left")
                    .font(.system(size: 11))
                    .foregroundStyle(left < 1800 ? Self.overColor : .secondary)
                Spacer()
                if replan.totalDebtSeconds > 60 {
                    Text("\(hours(replan.totalDebtSeconds)) behind overall")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            // A bar for the day itself, so "how much of today is gone" is visible rather than implied.
            DayClockBar(elapsedFraction: 1 - left / max(1, settings.wakingSeconds),
                        trackedFraction: min(1, (actualTotals[today] ?? 0)
                                             / max(1, settings.wakingSeconds)))
                .frame(height: 6)
            if wanted.isEmpty {
                Text("Nothing allocated to today.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(wanted, id: \.targetID) { placement in
                    todayRow(placement)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.08)))
    }

    /// One thing today wants: how much, how much of it is already done, and what's left.
    ///
    /// Doubles as "how is today going", which is why the card doesn't need a second section for it.
    private func todayRow(_ placement: Planner.Placement) -> some View {
        let already = (actuals[today] ?? [:])[placement.targetID] ?? 0
        let left = max(0, placement.seconds - already)
        let dayLeft = hoursLeftToday()
        let task = startableTask(for: placement.targetID)
        let isRunning = task != nil && engine.runningProjectID == task?.id
        return HStack(spacing: 8) {
            // Start it from here. The planner knows what you should be doing and, until now, made you
            // go to another page and find it yourself.
            Button {
                if let task { engine.switchTo(projectID: task.id) }
            } label: {
                Image(systemName: isRunning ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isRunning ? Color.orange
                                     : Color(hex: colorHex(forTarget: placement.targetID)))
            }
            .buttonStyle(.plain)
            .disabled(task == nil)
            .help(task.map { isRunning ? "Running “\($0.name)”" : "Start “\($0.name)”" }
                  ?? "No task to start — this allocation covers nothing trackable")

            Text(placement.name).font(.system(size: 11)).lineLimit(1)
                .frame(width: 124, alignment: .leading)
            ProgressPair(done: already, total: placement.seconds,
                         tint: Color(hex: colorHex(forTarget: placement.targetID)))
                .frame(width: 120, height: 8)
            // "to go" only while there is time to go. Past that it's missed, and calling it pending
            // at 11pm is the page lying to you about a day that has ended.
            Text(left <= 60 ? "done"
                 : (left > dayLeft ? "won't fit today" : "\(hours(left)) to go"))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(left <= 60 ? Color.green
                                 : (left > dayLeft ? Self.overColor : Color.primary))
                .frame(width: 88, alignment: .leading)
            // Which task the button would start, so a tag allocation isn't a mystery box.
            if let task {
                Text(task.name).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Waking hours still available today, by the clock.
    ///
    /// Hours to midnight, capped at a waking day — the same measure `Replan` uses, so the card and the
    /// backlog can't disagree about how much of today is left.
    private func hoursLeftToday() -> TimeInterval {
        Replan.fractionOfDayLeft(now: Date(), wakingSeconds: settings.wakingSeconds)
            * settings.wakingSeconds
    }

    private func clockText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
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

    // MARK: - Warnings

    /// Only what the page can't otherwise say, and only when it's true.
    ///
    /// This used to carry a chip for every allocation that didn't fit, every nesting and every ceiling —
    /// a second summary of the grid, in a different visual language, always present. Nesting is now a
    /// row tooltip and ceilings aren't work, so both are gone. What's left are two things you'd want
    /// interrupting you.
    @ViewBuilder
    private func warnings(_ plan: Planner) -> some View {
        FlowRow(spacing: 6) {
            ForEach(Array(plan.unplaced.enumerated()), id: \.offset) { _, item in
                chip(item.name, "won't fit", Self.overColor,
                     tooltip: "\(item.name) won't fit.\nWould fit if \(item.wouldFitIf).")
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
