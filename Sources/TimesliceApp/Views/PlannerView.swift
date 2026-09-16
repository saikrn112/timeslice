import SwiftUI
import TimesliceCore

/// Whether the week is possible.
///
/// Metrics is hindsight. This is foresight — and it is deliberately built around ONE question with a
/// one-sentence answer, then the two numbers that answer follows from. The first version tried to
/// show a proposed schedule as well, and that made it unreadable: an arbitrary "office: 16h on
/// Monday" is not a plan anyone would follow, and it buried the figure that actually reads at a
/// glance, which is how many hours each day is being asked for.
///
/// Every number here is computed by `Planner` in Core, so `swift run TimeslicePlan --db <path>`
/// prints the same figures and the page can be checked against arithmetic rather than by eye.
struct PlannerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: AppSettings

    @State private var targets: [Target] = []
    @State private var reservations: [Reservation] = []
    @State private var plan: Planner?
    @State private var replan: Replan?
    @State private var showReservations = false
    @State private var showAllocations = false

    /// Sunday-first, matching `Weekdays`' bit order and `Calendar`'s weekday numbering.
    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// The red used for over-capacity, matching the metrics selection overlay so one colour means one
    /// thing across both pages.
    static let overColor = Color(red: 0.90, green: 0.30, blue: 0.32)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let plan {
                    answer(plan)
                    if let replan { restOfWeek(replan) }
                    dayLoads(plan)
                    perAllocation(plan)
                    if !plan.unplaced.isEmpty { problems(plan) }
                    footnotes(plan)
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

    // MARK: - The answer

    /// One sentence, then the arithmetic behind it. Nothing else at the top of the page.
    @ViewBuilder
    private func answer(_ plan: Planner) -> some View {
        let free = max(0, plan.capacitySeconds - plan.reservedSeconds)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline(plan))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(verdictColor(plan.verdict))
                Spacer()
                Button("Reserve time…") { showReservations = true }
                    .buttonStyle(.link).font(.system(size: 11))
                Button("Allocations…") { showAllocations = true }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            Text(detail(plan))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The sum, spelled out as a sum. Three figures and one bar, in the order the sentence
            // above uses them.
            HStack(spacing: 18) {
                figure("Your allocations need", rangeText(plan), verdictColor(plan.verdict))
                figure("Reserved for life", hours(plan.reservedSeconds), .secondary)
                figure("Left to work with", hours(free), .accentColor)
            }
            RangeBar(lower: plan.requiredLowerSeconds, upper: plan.requiredUpperSeconds,
                     capacity: free, tint: verdictColor(plan.verdict))
                .frame(height: 14)
        }
    }

    private func headline(_ plan: Planner) -> String {
        switch plan.verdict {
        case .fits: return "This week fits."
        case .tight: return "This week fits, but only just."
        case .oversubscribed:
            return plan.overloadedDays.isEmpty
                ? "This week doesn't fit."
                : "This week doesn't fit — \(dayList(plan.overloadedDays)) "
                  + (plan.overloadedDays.count == 1 ? "is" : "are") + " over."
        case .uncertain: return "This week fits only if your allocations share work."
        }
    }

    private func detail(_ plan: Planner) -> String {
        let free = max(0, plan.capacitySeconds - plan.reservedSeconds)
        switch plan.verdict {
        case .fits:
            return "Everything fits even if none of your allocations overlap, with "
                 + "\(hours(free - plan.requiredUpperSeconds)) spare across the week."
        case .tight:
            return "There is \(hours(max(0, free - plan.requiredUpperSeconds))) spare across the whole "
                 + "week, so a single lost day puts you behind with nowhere to make it up."
        case .oversubscribed where !plan.overloadedDays.isEmpty:
            return "The week totals well enough, but weekday restrictions pile onto particular days: "
                 + "\(dayList(plan.overloadedDays)) "
                 + (plan.overloadedDays.count == 1 ? "is asked" : "are asked")
                 + " for more than \(hours(settings.wakingSeconds)) of waking hours. Widen those "
                 + "allocations' days, or ask for less on them."
        case .oversubscribed:
            return "Counting shared work only once, \(hours(plan.requiredLowerSeconds)) is certainly "
                 + "needed and \(hours(free)) is free. That is over by "
                 + "\(hours(plan.requiredLowerSeconds - free)) no matter how much your allocations "
                 + "overlap, so something has to give."
        case .uncertain:
            return "Between \(hours(plan.requiredLowerSeconds)) and \(hours(plan.requiredUpperSeconds)) "
                 + "is needed against \(hours(free)) free. The range exists because allocations "
                 + "overlap — the same hour can count for a tag and for a project inside it — so it "
                 + "fits only if that sharing is real."
        }
    }

    // MARK: - Rest of the week

    /// The backlog, and whether the days left can still absorb it.
    ///
    /// This is the block that earns the page a second visit. The plan above answers "was this week
    /// ever possible"; this answers the question that actually arrives on a Wednesday — a day went
    /// differently, so is it still recoverable and what does the rest of the week have to carry now.
    @ViewBuilder
    private func restOfWeek(_ replan: Replan) -> some View {
        block("Rest of the week", restSubtitle(replan)) {
            VStack(alignment: .leading, spacing: 6) {
                if replan.weekIsLost {
                    // Said plainly, and said NOW: on Wednesday this is a choice, on Sunday it's only a
                    // fact.
                    Text("What's left needs \(hours(replan.remainingNeedSeconds)) and the days "
                         + "remaining can hold \(hours(replan.remainingCapacitySeconds)). The week "
                         + "can't be finished as it stands — something has to be cut or moved.")
                        .font(.callout).foregroundStyle(Self.overColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(replan.items.filter { $0.standing != .met }.sorted {
                    standingRank($0.standing) < standingRank($1.standing)
                }, id: \.targetID) { item in
                    HStack(spacing: 8) {
                        Circle().fill(standingColor(item.standing)).frame(width: 8, height: 8)
                        Text(item.name).font(.callout).lineLimit(1).truncationMode(.tail)
                            .frame(width: 150, alignment: .leading).help(item.name)
                        Text("\(hours(item.doneSeconds)) of \(hours(item.targetSeconds))")
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            .frame(width: 96, alignment: .trailing)
                        if item.debtSeconds > 60 {
                            Text("behind \(hours(item.debtSeconds))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Self.overColor)
                                .frame(width: 90, alignment: .leading)
                        } else {
                            Text("on pace").font(.system(size: 10))
                                .foregroundStyle(.green)
                                .frame(width: 90, alignment: .leading)
                        }
                        if let per = item.requiredPerRemainingDay, item.remainingSeconds > 60 {
                            Text("needs \(hours(per))/day × \(item.remainingClaimedDays)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(item.standing == .unreachable ? Self.overColor
                                                                               : .primary)
                                .frame(width: 128, alignment: .leading)
                        } else {
                            Text("").frame(width: 128)
                        }
                        Text(item.standing == .unreachable ? item.adviceIfUnreachable : "")
                            .font(.system(size: 10)).foregroundStyle(Self.overColor.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func restSubtitle(_ replan: Replan) -> String {
        let lost = replan.unreachable.count
        if lost > 0 {
            return "\(lost) can no longer be finished this week"
        }
        if replan.totalDebtSeconds > 60 {
            return "behind by \(hours(replan.totalDebtSeconds)) in total, still recoverable"
        }
        return "nothing behind"
    }

    private func standingRank(_ s: Replan.Standing) -> Int {
        switch s {
        case .unreachable: return 0
        case .recoverable: return 1
        case .onTrack: return 2
        case .met: return 3
        }
    }

    private func standingColor(_ s: Replan.Standing) -> Color {
        switch s {
        case .unreachable: return Self.overColor
        case .recoverable: return .orange
        case .onTrack, .met: return .green
        }
    }

    // MARK: - Per day

    /// How many hours each day is being asked for, with each allocation spread evenly over the days it
    /// claims. Not a schedule: it doesn't say when, it says how much, which is the part that decides
    /// whether the day is possible.
    @ViewBuilder
    private func dayLoads(_ plan: Planner) -> some View {
        block("Each day", "hours asked for, against \(hours(settings.wakingSeconds)) awake") {
            VStack(spacing: 5) {
                ForEach(plan.days, id: \.weekday) { day in
                    HStack(spacing: 8) {
                        Text(Self.dayNames[day.weekday - 1])
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(day.isOverCapacity ? Self.overColor : .secondary)
                            .frame(width: 32, alignment: .leading)
                        Text(hours(day.reservedSeconds + day.committedSeconds))
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            .foregroundStyle(day.isOverCapacity ? Self.overColor : .primary)
                            .frame(width: 46, alignment: .trailing)
                        DayBar(day: day, colorFor: { colorHex(forTarget: $0) })
                            .frame(height: 14)
                        Text(day.isOverCapacity ? "over \(hours(-day.slackSeconds))"
                                                : "\(hours(day.freeSeconds)) free")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(day.isOverCapacity ? Self.overColor
                                                               : Color.secondary.opacity(0.7))
                            .frame(width: 74, alignment: .leading)
                    }
                    .help(dayTooltip(day))
                }
            }
        }
    }

    private func dayTooltip(_ day: Planner.DayPlan) -> String {
        var lines = ["\(Self.dayNames[day.weekday - 1]) — \(hours(day.capacitySeconds)) awake"]
        if day.reservedSeconds > 0 { lines.append("reserved  \(hours(day.reservedSeconds))") }
        for p in day.placements.sorted(by: { $0.seconds > $1.seconds }) {
            lines.append("\(p.name)  \(hours(p.seconds))")
        }
        lines.append(day.isOverCapacity ? "OVER by \(hours(-day.slackSeconds))"
                                        : "\(hours(day.freeSeconds)) free")
        return lines.joined(separator: "\n")
    }

    // MARK: - Per allocation

    /// What each allocation means as a daily figure — the translation from "7h a week" to "an hour a
    /// day", which is the thing you can't do in your head once weekday masks are involved.
    @ViewBuilder
    private func perAllocation(_ plan: Planner) -> some View {
        block("Each allocation", "what its weekly total works out to per day") {
            VStack(spacing: 3) {
                ForEach(rows(plan), id: \.id) { row in
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: row.colorHex)).frame(width: 8, height: 8)
                        Text(row.name).font(.callout).lineLimit(1).truncationMode(.tail)
                            .frame(width: 150, alignment: .leading).help(row.name)
                        Text(hours(row.weekly))
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                        Text("per week")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .frame(width: 56, alignment: .leading)
                        Text(row.dayList)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text("= \(hours(row.perDay))/day")
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            .foregroundStyle(.primary)
                            .frame(width: 84, alignment: .leading)
                        Text(row.note)
                            .font(.system(size: 10))
                            .foregroundStyle(row.isNested ? Color.secondary.opacity(0.7) : .secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private struct AllocationRow: Identifiable {
        let id: Int64
        let name: String
        let colorHex: String
        let weekly: TimeInterval
        let perDay: TimeInterval
        let dayList: String
        let isNested: Bool
        let note: String
    }

    private func rows(_ plan: Planner) -> [AllocationRow] {
        let nestedNames = Dictionary(plan.nestings.map { ($0.innerName, $0.outerName) },
                                    uniquingKeysWith: { a, _ in a })
        return targets.filter { $0.direction == .atLeast }.map { t in
            let name = self.name(for: t)
            let claimed = max(1, t.weekdays.effective.selectedCount)
            let nested = nestedNames[name]
            return AllocationRow(
                id: t.id, name: name,
                colorHex: BudgetRows.colorHex(for: t.subject, tasks: appState.projects,
                                              groups: appState.taskProjects, tags: appState.allTags),
                weekly: t.weeklySeconds,
                perDay: t.weeklySeconds / Double(claimed),
                dayList: dayList(t.weekdays),
                isNested: nested != nil,
                note: nested.map { "already inside \($0)" } ?? shapeNote(t))
        }
    }

    private func shapeNote(_ t: Target) -> String {
        switch t.shape {
        case .flexible: return ""
        case .everyDay(let m): return "wants ≥ \(hours(m)) every day"
        case .sessions(let n, let m): return "wants \(n) × \(hours(m)) blocks"
        }
    }

    // MARK: - Problems

    @ViewBuilder
    private func problems(_ plan: Planner) -> some View {
        block("What won't work", nil) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.unplaced.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Self.overColor).frame(width: 7, height: 7)
                        Text(item.name).font(.callout)
                            .frame(width: 150, alignment: .leading).help(item.name)
                        // The change to make, not just the complaint.
                        Text("Would fit if \(item.wouldFitIf).")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - Footnotes

    @ViewBuilder
    private func footnotes(_ plan: Planner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if reservations.isEmpty {
                // Without these the verdict is optimistic fiction, and saying so is more useful than a
                // confident number computed from nothing.
                Text("Nothing is reserved, so this assumes all \(hours(plan.capacitySeconds)) of your "
                     + "week is available for allocations. Only about a third of a waking day tends to "
                     + "get tracked — meals, commute and getting ready never become tasks — so until "
                     + "you reserve those, the answer above is the optimistic one.")
                    .font(.system(size: 10)).foregroundStyle(Self.overColor.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reserved: " + reservations.map {
                    "\($0.name) \(hours($0.secondsPerDay))/day on \(dayList($0.weekdays))"
                }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.ceilings.isEmpty {
                Text("Limits (not counted against the week): " + plan.ceilings.map {
                    "\(name(for: $0)) ≤ \(hours($0.seconds))/\($0.period.rawValue)"
                }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing to plan yet").font(.headline)
            Text("Set an allocation — how many hours a week something deserves — and this page will "
                 + "tell you whether all of them can coexist.")
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
        var names: [Int64: String] = [:]
        for t in targets { names[t.id] = name(for: t, tasks: tasks) }
        let membership = SubjectMembership(tasks: tasks, tagIDsByTask: tagIDsByTask)
        let input = Planner.Input(targets: targets, reservations: reservations,
                                  membership: membership, names: names,
                                  wakingSecondsPerDay: settings.wakingSeconds)
        let built = Planner.plan(input)
        plan = built

        // The backlog needs this week's actuals per allocation. Attribution goes through the same
        // `SubjectMembership` the planner uses, so "which hours count for this allocation" has one
        // answer rather than two that can drift.
        let cal = Calendar.current
        let now = Date()
        guard let week = cal.dateInterval(of: .weekOfYear, for: now) else { replan = nil; return }
        let intervals = (try? store.intervals(from: week.start, to: week.end)) ?? []
        var actuals: [Int64: TimeInterval] = [:]
        for target in targets where target.direction == .atLeast {
            let ids = membership.taskIDs(for: target.subject)
            actuals[target.id] = intervals
                .filter { ids.contains($0.projectID) }
                .reduce(0.0) { sum, interval in
                    let end = min(interval.end ?? now, week.end)
                    let start = max(interval.start, week.start)
                    return sum + max(0, end.timeIntervalSince(start))
                }
        }

        // Today counts as remaining — there are still hours in it — and the elapsed list is the days
        // strictly before it.
        let todayWeekday = cal.component(.weekday, from: now)
        let elapsed = (1..<todayWeekday).map { $0 }
        let remaining = (todayWeekday...7).map { $0 }
        // How much of today is left, so a replan at 9pm doesn't call the evening recoverable.
        let fractionLeft = Replan.fractionOfDayLeft(now: now, wakingSeconds: settings.wakingSeconds,
                                                   calendar: cal)
        replan = Replan.compute(plan: built, input: input, actuals: actuals,
                                elapsedWeekdays: elapsed, remainingWeekdays: remaining,
                                fractionOfTodayLeft: fractionLeft)
    }

    private func name(for target: Target, tasks: [Project]? = nil) -> String {
        BudgetRows.name(for: target.subject, tasks: tasks ?? appState.projects,
                        groups: appState.taskProjects, tags: appState.allTags) ?? "(deleted)"
    }

    private func colorHex(forTarget id: Int64) -> String {
        guard let target = targets.first(where: { $0.id == id }) else { return "#8E8E93" }
        return BudgetRows.colorHex(for: target.subject, tasks: appState.projects,
                                  groups: appState.taskProjects, tags: appState.allTags)
    }

    // MARK: - Chrome

    private func dayList(_ w: Weekdays) -> String {
        if w.effective.isAll { return "every day" }
        return (1...7).filter { w.effective.contains(weekday: $0) }
            .map { Self.dayNames[$0 - 1] }.joined(separator: " ")
    }

    private func dayList(_ weekdays: [Int]) -> String {
        weekdays.map { Self.dayNames[$0 - 1] }.joined(separator: ", ")
    }

    private func rangeText(_ plan: Planner) -> String {
        let lo = hours(plan.requiredLowerSeconds), hi = hours(plan.requiredUpperSeconds)
        return lo == hi ? lo : "\(lo)–\(hi)"
    }

    private func verdictColor(_ v: Planner.Verdict) -> Color {
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

    private func figure(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
        }
        // Fixed width so the row can't reflow as the figures change length.
        .frame(width: 130, alignment: .leading)
    }

    private func block<Content: View>(_ title: String, _ subtitle: String?,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.headline)
                // Always a line, so a block can't change height when its subtitle appears.
                Text(subtitle ?? " ").font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

/// One day as a horizontal bar: reserved, then each allocation, then any overflow in red.
///
/// Horizontal and one row per day, because seven vertical columns made the days hard to compare and
/// left no room for the figures that matter — the hours asked for and the hours left.
private struct DayBar: View {
    let day: Planner.DayPlan
    let colorFor: (Int64) -> String

    var body: some View {
        GeometryReader { geo in
            // Scaled by whichever is larger, so an overloaded day still shows how far over it goes
            // instead of being clipped to a full-looking bar.
            let span = max(day.capacitySeconds, day.reservedSeconds + day.committedSeconds)
            let scale = span > 0 ? geo.size.width / span : 0
            HStack(spacing: 0) {
                if day.reservedSeconds > 0 {
                    Rectangle().fill(Color.secondary.opacity(0.35))
                        .frame(width: day.reservedSeconds * scale)
                }
                ForEach(day.placements.sorted(by: { $0.seconds > $1.seconds }), id: \.targetID) { p in
                    Rectangle().fill(Color(hex: colorFor(p.targetID)))
                        .frame(width: p.seconds * scale)
                }
                if day.isOverCapacity {
                    Rectangle().fill(PlannerView.overColor)
                        .frame(width: -day.slackSeconds * scale)
                }
                Rectangle().fill(Color.secondary.opacity(0.10))
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .leading) {
                // Where the waking day ends, when the bar runs past it.
                if span > day.capacitySeconds {
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1.5)
                        .offset(x: day.capacitySeconds * scale)
                }
            }
        }
    }
}

/// The committed range against available hours: solid to the lower bound, translucent to the upper,
/// and a rule where the free hours run out.
///
/// Two ends rather than one number because allocations overlap, so the requirement genuinely is a
/// range — a single bar would claim a precision the data doesn't have.
private struct RangeBar: View {
    let lower: TimeInterval
    let upper: TimeInterval
    let capacity: TimeInterval
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let span = max(capacity, upper)
            let scale = span > 0 ? geo.size.width / span : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14))
                Capsule().fill(tint.opacity(0.35)).frame(width: max(2, upper * scale))
                Capsule().fill(tint).frame(width: max(2, lower * scale))
                if capacity > 0, capacity < span {
                    Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 1.5)
                        .offset(x: capacity * scale)
                }
            }
        }
    }
}
