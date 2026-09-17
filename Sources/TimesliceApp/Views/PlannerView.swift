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
    @State private var offset = Int(ProcessInfo.processInfo
        .environment["TIMESLICE_PLANNER_OFFSET"] ?? "") ?? 0
    /// Per allocation, seconds tracked inside the viewed period.
    @State private var periodActuals: [Int64: TimeInterval] = [:]
    /// Every second tracked inside the viewed period, allocation or not — the bar's "tracked" segment.
    @State private var periodTracked: TimeInterval = 0
    @State private var showReservations = false
    @State private var showAllocations = false
    /// Built once per rebuild rather than per redraw: the calendar needs every interval placed at its
    /// real clock position, and doing that inside `body` would re-query sqlite on every hover.
    @State private var calendarDays: [PlannerWeekGrid.DayInput] = []
    @State private var monthColumns: [PlannerMonthMatrix.WeekColumn] = []
    @State private var monthRows: [PlannerMonthMatrix.Row] = []
    /// Tap an allocation, in the rail or the grid, to dim everything else. The one interaction on the
    /// page, because "where does THIS one actually land" is the question a week of overlapping colours
    /// can't answer at a glance.
    @State private var highlight: Int64?
    /// Allocation id → the colour it is drawn in, made distinct.
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
                    // Cards, and the same ones Metrics is built from: a section on one page and a
                    // section on another should be the same object, not a near-miss.
                    section("Allocations",
                            subtitle: "click one to trace it through the "
                                      + unit.rawValue.lowercased(),
                            accessory: { EmptyView() }) {
                        railStrip(plan)
                    }
                    section(unit == .week ? "How full each day is" : "Week by week",
                            subtitle: calendarSubtitle,
                            accessory: { legend }) {
                        if unit == .week {
                            PlannerWeekGrid(days: calendarDays,
                                            capacityHours: settings.wakingSeconds / 3600,
                                            elapsedHoursToday: offset == 0 ? elapsedHoursToday : nil,
                                            highlight: highlight,
                                            onPick: { pick($0) },
                                            onOpen: { openInMetrics(targetID: $0, weekday: $1) })
                        } else {
                            PlannerMonthMatrix(weeks: monthColumns, rows: monthRows,
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
            ReservationsSheet(store: appState.storeForEditing,
                              wakingHours: settings.wakingSeconds / 3600) {
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
        // Adaptive columns: at the app's default 720pt this is two, and on a wide window three or four.
        // Fixed columns overflowed the window instead of reflowing.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 268), spacing: 18)],
                  alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.id) { row in
                railRow(row)
            }
        }
    }

    /// One allocation: what it wants, how far along it is, and what's left.
    ///
    /// A dot, not a coloured play button. Nine tinted play circles read as nine status lights — the row
    /// looked like an error list. Starting a task is what the Tasks page is for; clicking here traces the
    /// allocation through the grid, which is the thing only this page can do.
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

    /// Hand the day off to Metrics, with the allocation highlighted if there is one.
    ///
    /// The obvious next question after seeing a block is "what was that", and Metrics answers it for a day
    /// better than a planner ever should — so this doesn't try to answer it here.
    private func openInMetrics(targetID: Int64, weekday: Int) {
        guard let window = periodWindow() else { return }
        let cal = Calendar.current
        var day = cal.startOfDay(for: window.start)
        // The window starts on the week's first weekday, so walk forward to the one that was clicked.
        for _ in 0..<7 {
            if cal.component(.weekday, from: day) == weekday { break }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let subject = targets.first { $0.id == targetID }?.subject
        appState.metricsHandoff = AppState.MetricsHandoff(day: day, subject: subject)
    }

    private func pick(_ id: Int64) {
        highlight = (highlight == id) ? nil : id
    }

    /// What the two block styles mean, once, in nine words. The alternative is a tooltip nobody hovers
    /// or a paragraph nobody reads.
    private var legend: some View {
        HStack(spacing: 12) {
            // The month grid has no owed blobs and no hatching, so it doesn't get their keys. A legend
            // naming things that aren't on screen is worse than none.
            legendKey(filled: true, unit == .week ? "tracked" : "done")
            legendKey(filled: false, unit == .week ? "still to fit" : "weeks ahead")
            if unit == .week {
                HStack(spacing: 4) {
                    Hatch(color: .secondary).frame(width: 14, height: 9)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    Text("unavailable").font(.system(size: 9)).foregroundStyle(.secondary)
                }
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
                colorHex: colorHex(forTarget: target.id),
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
                    let selected = unit == candidate
                    Button {
                        unit = candidate
                        offset = 0
                        rebuild()
                    } label: {
                        Text(candidate.rawValue)
                            .font(.system(size: 11, weight: selected ? .bold : .medium,
                                          design: .rounded))
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                            .frame(minWidth: 44)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(selected ? Color.accentColor
                                                       : Color.secondary.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button { offset += 1; rebuild() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(periodLabel)
                    .font(.system(.subheadline, design: .rounded)).fontWeight(.medium)
                    .frame(minWidth: 150)
                    .multilineTextAlignment(.center)
                Button { offset = max(0, offset - 1); rebuild() } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(offset == 0)
                Button("Today") { offset = 0; rebuild() }
                    .buttonStyle(.link)
                    .disabled(offset == 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // The same pills, stepper and card as `RangeFilterBar` on the Metrics page. Two controls that
        // both mean "which period am I looking at" should not look like two different ideas.
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
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
        return "\(f.string(from: window.start)) – \(f.string(from: end))"
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

    /// The card + header the Metrics page is built from, copied in shape deliberately.
    private func section<Content: View, Accessory: View>(
        _ title: String, subtitle: String?,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                accessory()
            }
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var calendarSubtitle: String {
        unit == .week
            ? "each column is a waking day · solid is tracked, dashed is still owed"
            : "which weeks you missed, and the ones left to catch up in"
    }

    /// Waking hours already gone today: where the "now" rule sits in a column measured in hours.
    private var elapsedHoursToday: Double {
        let waking = settings.wakingSeconds
        let left = Replan.fractionOfDayLeft(now: Date(), wakingSeconds: waking) * waking
        return max(0, waking - left) / 3600
    }

    // MARK: - Headline

    /// The verdict, the arithmetic behind it, and what is actually at risk.
    ///
    /// The previous version of this card said "The week fits", restated the 55–65h range, and then listed
    /// four chips of permanent facts — nesting, a ceiling, a warning. None of it changed from day to day,
    /// none of it named a problem, and it managed to say "fits" on a week with a day 2.2h over capacity.
    ///
    /// What replaced it is the three things the grid below cannot say: which day is the binding one, the
    /// week's totals against one denominator, and which allocations are going to be missed and why.
    @ViewBuilder
    private func headline(_ plan: Planner) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(verdictColor(plan.verdict)).frame(width: 9, height: 9)
                Text(verdictLine(plan))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(verdictColor(plan.verdict))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Available hours…") { showReservations = true }
                    .buttonStyle(.link).font(.system(size: 11))
                Button("Allocations…") { showAllocations = true }
                    .buttonStyle(.link).font(.system(size: 11))
            }

            // Three numbers, one denominator. The old line mixed a weekly range with nothing to compare
            // it against, which is how "55h–65h" ended up meaning nothing.
            let budget = periodBudget()
            HStack(spacing: 14) {
                if offset > 0 {
                    // A finished period is a different question. "Still owed 42.2h · free left 0h ·
                    // short 42.2h" printed the same number twice and offered hours that no longer exist.
                    //
                    // All three figures are ALLOCATION hours: `budget.tracked` counts every tracked
                    // second including work no allocation covers, so adding it to what's owed produced a
                    // "wanted" of 73.6h for a week whose allocations only ask for 71h.
                    let wanted = targets.filter { $0.direction == .atLeast }
                        .reduce(0.0) { $0 + $1.weeklySeconds * unit.weeks }
                    let towards = periodActuals.values.reduce(0, +)
                    figure("goal", wanted, .secondary)
                    figure("done", towards, .accentColor)
                    figure("missed", max(0, wanted - towards),
                           wanted - towards > 60 ? Self.overColor : .green)
                    if budget.tracked - towards > 60 {
                        figure("other work", budget.tracked - towards, .secondary)
                    }
                } else {
                    // Plain words. "Still owed", "short" and "came up short" are the vocabulary of a
                    // ledger, and this is a page you glance at.
                    HStack(spacing: 5) {
                        Text("to do").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(hours(budget.stillToDo))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(budget.stillToDo > budget.freeLeft ? Self.overColor
                                                                                : .orange)
                        Text("of").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(hours(budget.freeLeft))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("left").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if budget.tracked > 60 { figure("done", budget.tracked, .accentColor) }
                }
            }

            atRisk
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func figure(_ label: String, _ seconds: TimeInterval, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(hours(seconds))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    /// What is going to be missed, and the reason — which is nearly always that the days it claims are
    /// gone, not that the week is full. Naming it is the difference between a number you can act on and
    /// one you can only feel bad about.
    @ViewBuilder
    private var atRisk: some View {
        if let replan, unit == .week, offset == 0 {
            let stuck = replan.items
                .filter { $0.standing == .unreachable || $0.shortfallOnRemainingDays > 60 }
                .sorted { $0.remainingSeconds > $1.remainingSeconds }
                .prefix(3)
            if !stuck.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("at risk").font(.system(size: 10)).foregroundStyle(.secondary)
                    FlowRow(spacing: 6) {
                        ForEach(Array(stuck), id: \.targetID) { item in
                            chip(item.name, riskReason(item), Self.overColor,
                                 tooltip: item.adviceIfUnreachable.isEmpty
                                     ? "\(hours(item.remainingSeconds)) left, and its remaining days "
                                       + "hold \(hours(item.availableOnRemainingDays))."
                                     : item.adviceIfUnreachable)
                        }
                    }
                }
            }
        }
    }

    private func riskReason(_ item: Replan.Item) -> String {
        if item.remainingClaimedDays == 0 { return "no days left" }
        if item.remainingClaimedDays == 1 { return "\(hours(item.remainingSeconds)) on one day" }
        return "\(hours(item.shortfallOnRemainingDays)) won't fit"
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
        // Month view gets a MONTH verdict. `Planner` and `Replan` are week-scoped, so showing their answer
        // under a month grid said "the week fits" about four weeks of days — answering a different
        // question than the page is asking.
        if offset > 0 {
            // What happened, in the plainest form available: two numbers and no verb nobody uses.
            let wanted = targets.filter { $0.direction == .atLeast }
                .reduce(0.0) { $0 + $1.weeklySeconds * unit.weeks }
            let towards = periodActuals.values.reduce(0, +)
            guard wanted > 60 else { return "Nothing was allocated then" }
            return "Did \(hours(towards)) of \(hours(wanted))"
        }
        if unit == .month {
            let budget = periodBudget()
            if budget.stillToDo > budget.freeLeft + 60 {
                return "\(hours(budget.stillToDo)) to do, only "
                     + "\(hours(budget.freeLeft)) free left this month"
            }
            if offset > 0 {
                return budget.stillToDo > 60
                    ? "That month came up \(hours(budget.stillToDo)) short"
                    : "That month held together"
            }
            return "The month still fits"
        }
        // Says what the comparison IS. "Not finishable" was a conclusion with its reasoning hidden,
        // which is exactly the kind of number nobody can argue with or trust.
        // Read the SAME numbers the figures below are drawn from. `Replan.weekIsLost` measures whole
        // remaining days while `periodBudget` discounts today to what's left of it, so the two disagreed
        // by a few hours — and the card said "The week fits" directly above "to do 43.1h of 42h left".
        let budget = periodBudget()
        if budget.stillToDo > budget.freeLeft + 60 {
            return "\(hours(budget.stillToDo)) to do, only \(hours(budget.freeLeft)) free left"
        }
        // A day over capacity outranks the weekly total: saying "the week fits" above a grid with a
        // 2.2h red cap on Friday is the page arguing with itself.
        if !plan.overloadedDays.isEmpty {
            let worst = plan.overloadedDays
                .compactMap { day in plan.days.first { $0.weekday == day } }
                .max { -$0.slackSeconds < -$1.slackSeconds }
            if let worst {
                return "\(dayList([worst.weekday])) is \(hours(-worst.slackSeconds)) over"
                     + (plan.overloadedDays.count > 1
                        ? ", and \(plan.overloadedDays.count - 1) other day(s)" : "")
            }
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
        // weekday → allocation id (or -2 for unallocated) → task name → seconds. Feeds the blob tooltips,
        // so hovering "unallocated 2.4h" can say which tasks that actually was.
        var breakdown: [Int: [Int64: [String: TimeInterval]]] = [:]
        let taskNamesByID = Dictionary(tasks.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for interval in intervals {
            let start = max(interval.start, week.start)
            let end = min(interval.end ?? now, week.end)
            guard end > start else { continue }
            let seconds = end.timeIntervalSince(start)
            let weekday = cal.component(.weekday, from: start)
            totalByDay[weekday, default: 0] += seconds
            let taskName = taskNamesByID[interval.projectID] ?? "?"
            var claimed = false
            for (id, ids) in idsBySubject where ids.contains(interval.projectID) {
                byDay[weekday, default: [:]][id, default: 0] += seconds
                weekTotals[id, default: 0] += seconds
                breakdown[weekday, default: [:]][id, default: [:]][taskName, default: 0] += seconds
                claimed = true
            }
            // Hours on something no allocation covers. Shown in the grid because a day that went
            // somewhere unplanned is the commonest reason a plan didn't happen.
            if !claimed {
                otherByDay[weekday, default: 0] += seconds
                breakdown[weekday, default: [:]][-2, default: [:]][taskName, default: 0] += seconds
            }
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

        // Allocations wholly inside another. Their hours are already in the parent's, so they must not
        // be drawn as blobs of their own.
        let nested = Set(built.nestings.compactMap { nesting in
            targets.first { name(for: $0, tasks: tasks) == nesting.innerName }?.id
        })

        if unit == .week {
            let viewed = periodWindow() ?? week
            // Per weekday, for the week being LOOKED AT. `actuals` above is always the current week, so
            // stepping back drew this week's blobs under last week's dates — the same numbers, the wrong
            // heading, which is worse than showing nothing.
            var viewedByDay: [Int: [Int64: TimeInterval]] = [:]
            var viewedOther: [Int: TimeInterval] = [:]
            var viewedBreakdown: [Int: [Int64: [String: TimeInterval]]] = [:]
            if offset == 0 {
                viewedByDay = byDay
                viewedOther = otherByDay
                viewedBreakdown = breakdown
            } else {
                for interval in (try? store.intervals(from: viewed.start, to: viewed.end)) ?? [] {
                    let start = max(interval.start, viewed.start)
                    let end = min(interval.end ?? now, viewed.end)
                    guard end > start else { continue }
                    let seconds = end.timeIntervalSince(start)
                    let weekday = cal.component(.weekday, from: start)
                    let taskName = taskNamesByID[interval.projectID] ?? "?"
                    var claimed = false
                    for (id, ids) in idsBySubject where ids.contains(interval.projectID) {
                        viewedByDay[weekday, default: [:]][id, default: 0] += seconds
                        viewedBreakdown[weekday, default: [:]][id, default: [:]][taskName,
                                                                                default: 0] += seconds
                        claimed = true
                    }
                    if !claimed {
                        viewedOther[weekday, default: 0] += seconds
                        viewedBreakdown[weekday, default: [:]][-2, default: [:]][taskName,
                                                                                default: 0] += seconds
                    }
                }
            }
            calendarDays = buildWeekColumns(week: viewed, replan: computed, nested: nested,
                                            dayActuals: viewedByDay, dayOther: viewedOther,
                                            breakdown: viewedBreakdown, calendar: cal)
            monthColumns = []
            monthRows = []
        } else {
            calendarDays = []
            buildMonthMatrix(store: store, owner: owner, nested: nested, calendar: cal)
        }
    }

    /// Seven day containers for the viewed week.
    ///
    /// Sums, not clock positions: one blob per allocation per day. Owed hours come from the replan, which
    /// has already spread each shortfall over the days that are actually left — so ten hours of office
    /// today shrinks the dashed office blobs on the days after it, without anything here knowing that.
    ///
    /// Nested allocations contribute no blob of their own. `deep technical creative` lives inside
    /// `recon paper`, so drawing both would count the same hours twice and inflate the day — it was
    /// adding 1.3h to every remaining day and pushing Friday over capacity on work already counted.
    private func buildWeekColumns(week: DateInterval, replan: Replan,
                                  nested: Set<Int64>,
                                  dayActuals: [Int: [Int64: TimeInterval]],
                                  dayOther: [Int: TimeInterval],
                                  breakdown: [Int: [Int64: [String: TimeInterval]]],
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
                blobs.append(PlannerWeekGrid.Blob(targetID: -1, name: "unavailable", hours: reserved,
                                                  colorHex: "#8E8E93", kind: .reserved))
            }

            // Then what was tracked, biggest first.
            for (id, seconds) in (dayActuals[weekday] ?? [:]).sorted(by: { $0.value > $1.value })
            where seconds > 60 && !nested.contains(id) {
                blobs.append(PlannerWeekGrid.Blob(targetID: id, name: name(forTarget: id),
                                                  hours: seconds / 3600,
                                                  colorHex: colorHex(forTarget: id), kind: .tracked,
                                                  detail: detailLines(breakdown[weekday]?[id])))
            }
            if let other = dayOther[weekday], other > 60 {
                blobs.append(PlannerWeekGrid.Blob(targetID: -2, name: "unallocated",
                                                  hours: other / 3600,
                                                  colorHex: "#8E8E93", kind: .unallocated,
                                                  detail: detailLines(breakdown[weekday]?[-2])))
            }

            // Then what is still owed — only on days still to come, and only in the current week. A past
            // week owes nothing; it is simply what happened.
            if dayStart >= startOfToday, offset == 0,
               let planned = replan.replannedDays.first(where: { $0.weekday == weekday }) {
                let byID = Dictionary(planned.placements.map { ($0.targetID, $0) },
                                      uniquingKeysWith: { a, _ in a })
                for id in owedOrder where !nested.contains(id) {
                    guard let placement = byID[id], placement.seconds > 60 else { continue }
                    let done = (dayActuals[weekday] ?? [:])[id] ?? 0
                    let left = max(0, placement.seconds - done) / 3600
                    guard left > 1.0 / 60 else { continue }
                    blobs.append(PlannerWeekGrid.Blob(targetID: id, name: name(forTarget: id),
                                                      hours: left,
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

    /// The tasks behind a blob, largest first and capped — a list of everything explains nothing.
    private func detailLines(_ byTask: [String: TimeInterval]?) -> [String] {
        guard let byTask, byTask.count > 1 || byTask.first.map({ $0.value > 60 }) == true else {
            return []
        }
        let sorted = byTask.sorted { $0.value > $1.value }.filter { $0.value > 30 }
        let shown = sorted.prefix(5).map { "  \($0.key)  \(hours($0.value))" }
        let rest = sorted.dropFirst(5)
        return rest.isEmpty ? shown
            : shown + ["  + \(rest.count) more  \(hours(rest.reduce(0) { $0 + $1.value }))"]
    }

    /// The month as weeks: one column per week it touches, one row per allocation.
    ///
    /// Thirty day-cells looked like a calendar and said nothing — at that size a cell holds neither a name
    /// nor a figure. Weeks are also the unit the allocations are stated in, so a cell can be compared
    /// against its own target instead of against a share of a day.
    private func buildMonthMatrix(store: IntervalStore, owner: (Int64) -> Int64?,
                                  nested: Set<Int64>,
                                  calendar cal: Calendar) {
        guard let month = periodWindow(),
              let firstWeek = cal.dateInterval(of: .weekOfYear, for: month.start),
              let lastWeek = cal.dateInterval(of: .weekOfYear,
                                              for: month.end.addingTimeInterval(-1))
        else { monthColumns = []; monthRows = []; return }

        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let waking = settings.wakingSeconds / 3600
        let intervals = (try? store.intervals(from: firstWeek.start, to: lastWeek.end)) ?? []

        // Week start → allocation id → hours, plus the week's total.
        var byWeek: [Date: [Int64: Double]] = [:]
        var trackedByWeek: [Date: Double] = [:]
        for interval in intervals {
            let end = interval.end ?? now
            guard end > interval.start,
                  let week = cal.dateInterval(of: .weekOfYear, for: interval.start) else { continue }
            let hours = end.timeIntervalSince(interval.start) / 3600
            trackedByWeek[week.start, default: 0] += hours
            if let id = owner(interval.projectID), !nested.contains(id) {
                byWeek[week.start, default: [:]][id, default: 0] += hours
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        var columns: [PlannerMonthMatrix.WeekColumn] = []
        var cursor = firstWeek.start
        while cursor < lastWeek.end {
            guard let week = cal.dateInterval(of: .weekOfYear, for: cursor) else { break }
            let isCurrent = week.contains(now)
            // Available hours across the week: the waking day, less whatever each weekday gives up.
            var available = 0.0
            for offsetDays in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: offsetDays, to: week.start),
                      date < week.end else { break }
                let weekday = cal.component(.weekday, from: date)
                let unavailable = reservations
                    .filter { $0.weekdays.effective.contains(weekday: weekday) }
                    .reduce(0.0) { $0 + $1.secondsPerDay } / 3600
                available += max(0, waking - unavailable)
            }
            columns.append(PlannerMonthMatrix.WeekColumn(
                start: week.start,
                label: formatter.string(from: week.start),
                isCurrent: isCurrent,
                isFuture: week.start > startOfToday,
                elapsedFraction: isCurrent
                    ? min(1, max(0, now.timeIntervalSince(week.start)
                                    / week.end.timeIntervalSince(week.start)))
                    : 1,
                trackedHours: trackedByWeek[week.start] ?? 0,
                availableHours: available))
            guard let next = cal.date(byAdding: .weekOfYear, value: 1, to: cursor) else { break }
            cursor = next
        }

        monthColumns = columns
        monthRows = targets
            .filter { $0.direction == .atLeast && !nested.contains($0.id) }
            .map { target in
                var done: [Date: Double] = [:]
                for column in columns {
                    done[column.start] = byWeek[column.start]?[target.id] ?? 0
                }
                return PlannerMonthMatrix.Row(id: target.id, name: name(for: target),
                                              colorHex: colorHex(forTarget: target.id),
                                              targetHours: target.weeklySeconds / 3600,
                                              doneByWeek: done)
            }
            // Worst first: the rows worth acting on are the ones with the most left across the month.
            .sorted { lhs, rhs in
                func owed(_ row: PlannerMonthMatrix.Row) -> Double {
                    columns.filter { !$0.isFuture }
                        .reduce(0.0) { $0 + max(0, row.targetHours - (row.doneByWeek[$1.start] ?? 0)) }
                }
                return owed(lhs) > owed(rhs)
            }
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

    /// Give each allocation a colour nothing else is using.
    ///
    /// `BudgetRows.colorHex` answers per subject, and three of the real allocations are tags sharing one
    /// colour — recon paper, deep technical creative and family all came out the same red, so on a grid of
    /// coloured blobs the colour carried no information. Duplicates take the next unused hue from
    /// `Palette`, which is what Tasks and Metrics colour by, rather than a lighter shade of the same red:
    /// two shades of one colour still read as one thing.
    private func assignColors() {
        var used: Set<String> = []
        var out: [Int64: String] = [:]
        for target in targets.sorted(by: { $0.id < $1.id }) {
            let base = BudgetRows.colorHex(for: target.subject, tasks: appState.projects,
                                           groups: appState.taskProjects, tags: appState.allTags)
            var candidate = base
            var step = 0
            while used.contains(candidate.lowercased()), step < Palette.colors.count + 6 {
                candidate = Palette.color(forIndex: step)
                step += 1
            }
            used.insert(candidate.lowercased())
            out[target.id] = candidate
        }
        targetColors = out
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
        // The dot has to agree with the sentence beside it. It was reading the week-scoped verdict, so a
        // finished week that came up 42h short got a green dot next to the words "came up 42.2h short".
        if offset > 0 || unit == .month {
            let budget = periodBudget()
            if budget.stillToDo <= 60 { return .green }
            if budget.stillToDo > budget.freeLeft + 60 { return Self.overColor }
            // Orange means TIGHT, not merely "has work left" — otherwise an amber dot sat beside the
            // words "still fits" for any month with anything to do in it, which is every month.
            let spare = budget.freeLeft - budget.stillToDo
            return spare < budget.freeLeft * 0.1 ? .orange : .green
        }
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
