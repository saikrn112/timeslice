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
    /// How many periods back from the current one. 0 is now, 1 is last week. Never negative: a week that
    /// hasn't happened has nothing tracked in it, so browsing to one could only show the plan — which the
    /// "intended" toggle already does, for whichever week you're looking at.
    @State private var offset = Int(ProcessInfo.processInfo
        .environment["TIMESLICE_PLANNER_OFFSET"] ?? "") ?? 0
    /// Per allocation, seconds tracked inside the viewed period.
    @State private var periodActuals: [Int64: TimeInterval] = [:]
    /// weekday → the tasks that no allocation covers. Feeds the double-click into Metrics, which can only
    /// highlight "unallocated" by naming those tasks one by one.
    @State private var unallocatedTaskIDs: [Int: [Int64]] = [:]
    /// Allocations wholly inside another. Their hours are already counted in the parent's, so every total
    /// on this page has to leave them out — the headline did and the figures beside it didn't, which is how
    /// "the plan fits, 33h spare" ended up above "spare 27.5h".
    @State private var nestedIDs: Set<Int64> = []
    /// Tasks, groups and tags as of the last rebuild.
    ///
    /// Read from the store rather than `AppState`, because AppState reloads from the same `dataDidChange`
    /// notification this page subscribes to and subscriber order isn't defined — so a rename could land in
    /// the columns one refresh late, or not until you left the tab and came back.
    @State private var world: (tasks: [Project], groups: [TaskProject], tags: [Tag]) = ([], [], [])
    /// What each remaining day is asked to do: its own share, and anything moved onto it.
    @State private var dailyPlan = Replan.DailyPlan(byDay: [:], unplaced: [:])
    /// Per-day method only: weekday → allocation → hours that day never got.
    @State private var missedByDay: [Int: [Int64: TimeInterval]] = [:]
    /// Every second tracked inside the viewed period, allocation or not — the bar's "tracked" segment.
    @State private var periodTracked: TimeInterval = 0
    /// Show the plan as designed rather than what happened.
    ///
    /// Two things asked for the same view: "can I see next week" and "can I see how the intended plan
    /// looked". A week ahead has nothing tracked in it, so it can only ever show the intention — and once
    /// that exists, being able to see it for THIS week is the same code with the actuals ignored.
    @State private var showIntended = ProcessInfo.processInfo
        .environment["TIMESLICE_PLANNER_INTENDED"] == "1"
    /// Whether unfinished hours move into the days you have left, or stay under the day that missed them.
    ///
    /// Two questions, not a better and a worse answer — see `Replan.Method`. Remembered across launches
    /// because it's a way of reading the week, not a thing you toggle while comparing.
    @AppStorage("plannerMethod") private var methodRaw = Replan.Method.catchUp.rawValue
    private var method: Replan.Method {
        // A capture run can force one, so both readings are reviewable without changing your setting.
        if let forced = ProcessInfo.processInfo.environment["TIMESLICE_PLANNER_METHOD"],
           let parsed = Replan.Method(rawValue: forced.replacingOccurrences(of: "-", with: " ")) {
            return parsed
        }
        return Replan.Method(rawValue: methodRaw) ?? .catchUp
    }
    @State private var showAllocations = false
    /// Built once per rebuild rather than per redraw: the calendar needs every interval placed at its
    /// real clock position, and doing that inside `body` would re-query sqlite on every hover.
    @State private var calendarDays: [PlannerWeekGrid.DayInput] = []
    /// The month's weeks as filling containers — the same reading as the week view, one level up.
    @State private var monthWeekColumns: [PlannerWeekGrid.DayInput] = []
    /// Their spans, so a double-click can say which week it meant.
    @State private var monthSpans: [PlannerMonth.WeekSpan] = []
    /// The tallest span, which is the axis for all of them: a five-day week has to look shorter than a
    /// seven-day one, and it can only do that against a shared scale.
    @State private var monthWeekCapacity: Double = 0
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
        // A capture run can ask to start scrolled to the foot of the page. The window can't grow past the
        // screen, so the leftover pool at the bottom of a tall week was unreviewable by screenshot — and
        // reviewing by screenshot is the only way this page gets checked.
        ScrollViewReader { scroller in
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
                    // The month gets the week-by-week containers FIRST, with the day grid under them:
                    // "is this month behind" is a question about weeks, and the day cells answer a
                    // different one (which days went well) at a resolution that can't add up to a verdict.
                    if unit == .month, !monthWeekColumns.isEmpty {
                        section("How full each week is", subtitle: monthWeekSubtitle,
                                accessory: {
                                    HStack(spacing: 10) {
                                        methodToggle
                                        intendedToggle
                                    }
                                }) {
                            weekSpanLegend
                            PlannerWeekGrid(days: monthWeekColumns,
                                            capacityHours: monthWeekCapacity,
                                            elapsedHoursToday: nil,
                                            highlight: highlight,
                                            leftoverCaption: monthLeftoverCaption,
                                            onPick: { pick($0) },
                                            onOpen: { openWeekInMetrics(targetID: $0, spanIndex: $1) })
                        }
                    }
                    // The month used to carry a second grid of hour cubes, one per day. It looked good and
                    // said nothing the week columns don't: a day's cubes answer "did this day go well", which
                    // is the week view's question at a resolution too fine to add up to a verdict about a
                    // month. Removed rather than kept for decoration.
                    if unit == .week {
                        section("How full each day is", subtitle: calendarSubtitle,
                                // Only the toggles here. Four legend keys in a section header wrapped
                                // mid-word — "track / ed", "unava / ilable" — because a header row has no
                                // room to reflow. They get their own line below.
                                accessory: {
                                    HStack(spacing: 10) {
                                        methodToggle
                                        intendedToggle
                                    }
                                }) {
                            legend
                            PlannerWeekGrid(days: calendarDays,
                                            capacityHours: settings.wakingSeconds / 3600,
                                            elapsedHoursToday: offset == 0 && !showIntended
                                                ? elapsedHoursToday : nil,
                                            highlight: highlight,
                                            leftoverCaption: leftoverCaption,
                                            onPick: { pick($0) },
                                            onOpen: { openInMetrics(targetID: $0, weekday: $1) })
                        }
                    }
                } else {
                    empty
                }
                Color.clear.frame(height: 1).id("planner-foot")
            }
            .padding(18)
        }
        .onAppear {
            adoptSharedFilter()
            rebuild()
            publishWindow()
            if ProcessInfo.processInfo.environment["TIMESLICE_SCROLL"] == "bottom" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.none) { scroller.scrollTo("planner-foot", anchor: .bottom) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TimesliceNotifications.dataDidChange)) { _ in
            rebuild()
        }
        // Everything below is a way this page could go stale while you are looking at it. The page derives
        // a lot ONCE — the plan, the daily shares, every column — while reading a few things live from
        // settings and the clock. When only half of that updates, the numbers stop agreeing with each other,
        // which is what "I have to go back and forth to refresh it" actually was.
        //
        // A change to the waking day: it resizes every column, rescales the capacity axis and changes what
        // each day can be asked for, and none of that is recomputed by a redraw.
        .onChange(of: settings.wakingHours) { _, _ in rebuild() }
        // The clock. `today`, the hours left of it, the untracked band, and how much today can still be
        // asked for all move on their own — so at midnight the page was pointing at yesterday, and at 23:00
        // it was still offering an afternoon's worth of room.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            let weekday = Calendar.current.component(.weekday, from: Date())
            if weekday != today || unit == .week { rebuild() }
        }
        // Coming back to the app after a while — the tab may already have been showing, so `onAppear` never
        // fires and the page can be hours out of date.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            rebuild()
        }
        .sheet(isPresented: $showAllocations) {
            TargetsSheet(appState: appState, store: appState.storeForEditing) {
                showAllocations = false
                rebuild()
            }
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 18)],
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
                .frame(width: 84, alignment: .leading)
            // Hours done, left of the bar, exactly as the metrics allocation rows read — the percentage
            // says how far along, and this says how far along in hours.
            Text(hours(row.done))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(row.done > 60 ? Color.primary.opacity(0.8) : .secondary)
                .frame(width: 40, alignment: .trailing)
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
        // "Unallocated" isn't a subject, so it hands over the tasks themselves — the only way Metrics can
        // highlight exactly the sessions that made up that grey block.
        let subjects: [TargetSubject]
        if targetID == -2 {
            subjects = (unallocatedTaskIDs[weekday] ?? []).map { .task($0) }
        } else if let subject = targets.first(where: { $0.id == targetID })?.subject {
            subjects = [subject]
        } else {
            subjects = []
        }
        appState.metricsHandoff = AppState.MetricsHandoff(day: day, subjects: subjects)
    }

    private func pick(_ id: Int64) {
        highlight = (highlight == id) ? nil : id
        // Publish it, so Metrics is already filtered when you switch tabs.
        appState.sharedFilter.subject = highlight.flatMap { picked in
            targets.first { $0.id == picked }?.subject
        }
    }

    /// Take up the shared selection and period. Called on appear, so arriving from Metrics lands on the
    /// same allocation and the same week you were looking at there.
    private func adoptSharedFilter() {
        let filter = appState.sharedFilter
        if let subject = filter.subject,
           let match = targets.first(where: { $0.subject == subject }) {
            highlight = match.id
        } else if filter.subject == nil {
            highlight = nil
        }
        // Metrics has units this page doesn't. Up to a week reads as a week; longer reads as a month.
        if let theirs = filter.unit {
            switch theirs {
            case .day, .week: unit = .week
            case .month, .sixMonths, .year, .all: unit = .month
            }
        }
        if let day = filter.day, let cal = Optional(Calendar.current) {
            let component: Calendar.Component = unit == .week ? .weekOfYear : .month
            let now = Date()
            if let currentStart = cal.dateInterval(of: component, for: now)?.start,
               let targetStart = cal.dateInterval(of: component, for: day)?.start,
               let steps = cal.dateComponents([component == .weekOfYear ? .weekOfYear : .month],
                                              from: targetStart, to: currentStart)
                   .value(for: component == .weekOfYear ? .weekOfYear : .month) {
                offset = max(0, steps)
            }
        }
    }

    /// Publish the window being viewed, so Metrics follows both the arrows and the granularity.
    private func publishWindow() {
        appState.sharedFilter.day = periodWindow()?.start
        appState.sharedFilter.unit = unit == .week ? .week : .month
    }

    /// The week columns' own keys. `legend` describes whichever grid the unit implies, and in month view
    /// that's the hour cubes below — "done / hour it wanted to reach" says nothing about these blocks.
    private var weekSpanLegend: some View {
        FlowRow(spacing: 12) {
            // The intended view draws no tracked blocks at all, so naming them would describe something
            // that isn't on screen.
            if !showIntended {
                legendKey(filled: true, "tracked")
            }
            legendKey(filled: false, showIntended ? "planned" : "this week wants")
            // No key for the cross-hatched cap: `legendKey` has only filled and dashed swatches, and a
            // dashed one would claim those hours are planned. The cap writes its own label instead.

        }
    }

    /// What the two block styles mean, once, in nine words. The alternative is a tooltip nobody hovers
    /// or a paragraph nobody reads.
    private var legend: some View {
        FlowRow(spacing: 12) {
            // The intended view draws no tracked blocks, so naming them would describe something that isn't
            // on screen.
            if !(showIntended || isFuture) {
                legendKey(filled: true, "tracked")
            }
            legendKey(filled: false, showIntended || isFuture ? "planned"
                                 : (offset > 0 ? "never happened" : "this day wants"))
            if highlight != nil {
                // Clears it on BOTH pages: it set the shared filter, so it has to unset it, or Metrics
                // would still be filtered by an allocation this page says it isn't showing.
                Button("clear filter") {
                    highlight = nil
                    appState.sharedFilter.subject = nil
                }
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
            let scaled = goalSeconds(for: target)
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
                        publishWindow()
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
                Button { offset += 1; rebuild(); publishWindow() } label: {
                    Image(systemName: "chevron.left")
                }
                    .buttonStyle(.borderless)
                Text(periodLabel)
                    .font(.system(.subheadline, design: .rounded)).fontWeight(.medium)
                    .frame(minWidth: 150)
                    .multilineTextAlignment(.center)
                // Stops at the current period. A future week has nothing tracked in it, so it could only
                // ever show the plan — and "intended" already shows the plan, for any week, without
                // pretending to be a week you can browse to.
                Button { offset = max(0, offset - 1); rebuild(); publishWindow() } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(offset == 0)
                Button("Today") { offset = 0; rebuild(); publishWindow() }
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
    /// metrics page calls a week. A negative offset is ahead of now.
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
        guard unit == .week else { return monthWeekSubtitle }
        if isFuture { return "nothing tracked yet — this is the plan as designed" }
        if method == .perDay, !showIntended {
            return "every day keeps its own share · what a day missed stays under it"
        }
        if offset > 0, method == .catchUp, !showIntended {
            return "what that week did · what it never did is below"
        }
        return showIntended
            ? "the plan as designed, ignoring what actually happened"
            : "every column adds up to a whole day"
    }

    /// Never true now that browsing forward is gone — kept as one named place to change if it comes back.
    private var isFuture: Bool { false }

    /// The same two methods, named for the unit they act on: a month reallocates between WEEKS, so calling
    /// the alternative "per day" there would describe a rule the month grid doesn't apply.
    private func methodLabel(_ candidate: Replan.Method) -> String {
        switch candidate {
        case .catchUp: return "catch up"
        case .perDay: return unit == .week ? "per day" : "per week"
        }
    }

    private func methodHelp(_ candidate: Replan.Method) -> String {
        let noun = unit == .week ? "day" : "week"
        let window = unit == .week ? "week" : "month"
        if candidate == .catchUp {
            return "Unfinished hours move into the \(noun)s you have left, so the \(window) is shown as it "
                 + "could still be finished. Nothing moves outside the \(window)."
        }
        return "Every \(noun) keeps its own share. What you missed in a \(noun) stays under that \(noun), "
             + "and nothing moves."
    }

    /// Which of the two readings of the window to show. Hidden in the intended view, where there is nothing
    /// to reallocate — the plan as designed is the same under either method.
    @ViewBuilder
    private var methodToggle: some View {
        if !showIntended {
            HStack(spacing: 3) {
                ForEach(Replan.Method.allCases, id: \.rawValue) { candidate in
                    let selected = method == candidate
                    Button {
                        methodRaw = candidate.rawValue
                        rebuild()
                    } label: {
                        Text(methodLabel(candidate))
                            .font(.system(size: 9, weight: selected ? .bold : .regular,
                                          design: .rounded))
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(selected ? Color.accentColor
                                                       : Color.secondary.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help(methodHelp(candidate))
                }
            }
        }
    }

    /// Actual against intended. Hidden for a future week, which has only one answer.
    @ViewBuilder
    private var intendedToggle: some View {
        if !isFuture {
            HStack(spacing: 3) {
                ForEach([false, true], id: \.self) { intended in
                    let selected = showIntended == intended
                    Button {
                        showIntended = intended
                        rebuild()
                    } label: {
                        Text(intended ? "intended" : "actual")
                            .font(.system(size: 9, weight: selected ? .bold : .regular,
                                          design: .rounded))
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(selected ? Color.accentColor
                                                       : Color.secondary.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
                Button("Allocations…") { showAllocations = true }
                    .buttonStyle(.link).font(.system(size: 11))
            }

            // Three numbers, one denominator. The old line mixed a weekly range with nothing to compare
            // it against, which is how "55h–65h" ended up meaning nothing.
            let budget = periodBudget()
            HStack(spacing: 14) {
                if isFuture || (showIntended && unit == .week) {
                    figure("goal", goalSeconds, .secondary)
                    figure("available", max(0, budget.capacity - unavailableInWindow()), .secondary)
                    let available = max(0, budget.capacity - unavailableInWindow())
                    figure("unclaimed", max(0, available - goalSeconds),
                           available >= goalSeconds ? .green : Self.overColor)
                } else if offset > 0 {
                    // A finished period is a different question. "Still owed 42.2h · free left 0h ·
                    // short 42.2h" printed the same number twice and offered hours that no longer exist.
                    //
                    // All three figures are ALLOCATION hours: `budget.tracked` counts every tracked
                    // second including work no allocation covers, so adding it to what's owed produced a
                    // "wanted" of 73.6h for a week whose allocations only ask for 71h.
                    let towards = periodActuals.values.reduce(0, +)
                    figure("goal", goalSeconds, .secondary)
                    // The room that week had, so the goal has a denominator. Without it "missed 11.7h"
                    // can't be read as either "the week was overbooked" or "the hours were there".
                    // Same position as in the intended view, which reads goal then available.
                    figure("available", max(0, budget.capacity - unavailableInWindow()), .secondary)
                        .help("Awake hours across the whole week — \(Int(settings.wakingHours))h a day, "
                              + "set in Settings. Every hour of it was gone by the end of the week, so "
                              + "this is what the goal had to fit inside, not what's left.")
                    figure("done", towards, .accentColor)
                    figure("missed", max(0, goalSeconds - towards),
                           goalSeconds - towards > 60 ? Self.overColor : .green)
                    if budget.tracked - towards > 60 {
                        figure("other work", budget.tracked - towards, .secondary)
                    }
                } else {
                    // A progression rather than six equal facts: what the week wants, how much is done,
                    // how much is left, and the room there is for it. Six undifferentiated numbers in one
                    // row meant reading all of them to find the one you were after.
                    figure("done", periodActuals.values.reduce(0, +), .accentColor)
                    Text("of").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(hours(goalSeconds))
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Divider().frame(height: 12)
                    figure("to do", budget.stillToDo,
                           budget.stillToDo > budget.freeLeft ? Self.overColor : .orange)
                    figure("free", budget.freeLeft, .secondary)
                        .help("Available hours on the days still to come, with today counted only from "
                              + "now.\nNothing is held back for work outside your allocations — that "
                              + "would be a guess about what you're going to do.")
                }
            }

            problems
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// What the pool is, in this combination of week and method. Three different facts, so three phrasings:
    /// hours with nowhere left to put them, hours that never happened, and hours that couldn't have fitted
    /// even given the whole week back.
    private var leftoverCaption: String {
        if method == .perDay { return "missed on the day" }
        return offset > 0 ? "never happened" : "no room for these"
    }

    /// Hours that don't fit — on their own line, and only when there are any.
    ///
    /// Below the figures rather than among them: those state what the week is, these state what is going to
    /// go wrong, and mixing the two made a row of six numbers where four were routine.
    @ViewBuilder
    private var problems: some View {
        let noRoom = dailyPlan.unplaced.values.reduce(0, +)
        if unit == .week, offset == 0, !showIntended, noRoom > 60 {
            HStack(spacing: 14) {
                if noRoom > 60 {
                    problem(hours(noRoom), "won't fit in the days left",
                            tooltip: noRoomExplanation())
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// weekday → the blocks that day couldn't hold, for the basement under its column.
    ///
    /// An unplaceable allocation is filed under the LAST day it could have used: for something that ran out
    /// of room, the last remaining day it claims (where it finally failed to fit); for something whose
    /// weekdays have gone, the last of those days. That puts the block where the decision would have to be
    /// made rather than in a pool of its own.
    private func leftoversByDay() -> [Int: [PlannerWeekGrid.Blob]] {
        guard unit == .week, !showIntended else { return [:] }
        let dayNamesShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        if method == .perDay {
            // One entry per day that fell short, under that day — the whole point of the method. On a
            // finished week every claimed day is a candidate, because none of them are still to come.
            var out: [Int: [PlannerWeekGrid.Blob]] = [:]
            for (weekday, shorts) in missedByDay {
                for (id, seconds) in shorts where seconds > 60 {
                    out[weekday, default: []].append(PlannerWeekGrid.Blob(
                        targetID: id, name: name(forTarget: id), hours: seconds / 3600,
                        colorHex: colorHex(forTarget: id), kind: .owed,
                        detail: ["  \(dayNamesShort[weekday - 1]) wanted "
                                 + "\(hours((dailyPlan.byDay[weekday]?[id]?.intended ?? 0) + seconds))"
                                 + " and didn't get this part",
                                 "  nothing was moved to another day — that's the catch up method"]))
                }
            }
            return out.mapValues { $0.sorted { $0.hours > $1.hours } }
        }
        // A finished week's pool IS the week's answer: the columns show what happened, this shows what
        // didn't. No scheduling — `PlannerWeek.neverHappened` is arithmetic on wanted against credited.
        if offset > 0 {
            let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            var out: [Int: [PlannerWeekGrid.Blob]] = [:]
            for miss in PlannerWeek.neverHappened(floors: targets, credited: periodActuals,
                                                  nested: nestedIDs, weeks: unit.weeks) {
                out[miss.lastDay, default: []].append(PlannerWeekGrid.Blob(
                    targetID: miss.id, name: name(forTarget: miss.id), hours: miss.missed / 3600,
                    colorHex: colorHex(forTarget: miss.id), kind: .owed,
                    detail: ["  \(hours(periodActuals[miss.id] ?? 0)) of "
                             + "\(hours(targets.first { $0.id == miss.id }.map { goalSeconds(for: $0) } ?? 0))"
                             + " done",
                             "  \(dayNames[miss.lastDay - 1]) was its last day that week"]))
            }
            return out.mapValues { $0.sorted { $0.hours > $1.hours } }
        }
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var out: [Int: [PlannerWeekGrid.Blob]] = [:]

        let spare = dailyPlan.leftoverRoom.filter { $0.value > 60 }.sorted { $0.key < $1.key }
        let spareText = spare.isEmpty ? nil
            : spare.map { "\(dayNames[$0.key - 1]) \(hours($0.value))" }.joined(separator: ", ")

        for (id, seconds) in dailyPlan.unplaced where seconds > 60 {
            let claimed = dailyPlan.claimedDays[id] ?? []
            guard let day = claimed.last else { continue }
            var detail = ["  \(dayNames[day - 1]) was the last day it could use, and it's full",
                          "  nothing outranks anything: the days are shared in half-hour turns, and only "
                          + "an allocation with fewer days left goes first"]
            if let spareText {
                detail.append("  free hours remain on \(spareText) — days this doesn't claim")
                detail.append("  more weekdays would reach them; more hours a day would not")
            } else {
                detail.append("  every remaining day is full — more hours a day would help")
            }
            out[day, default: []].append(PlannerWeekGrid.Blob(
                targetID: id, name: name(forTarget: id), hours: seconds / 3600,
                colorHex: colorHex(forTarget: id), kind: .owed, detail: detail))
        }

        for (id, seconds) in dailyPlan.outOfDays where seconds > 60 {
            guard let target = targets.first(where: { $0.id == id }) else { continue }
            let claimed = (1...7).filter { target.weekdays.effective.contains(weekday: $0) }
            guard let day = claimed.last else { continue }
            out[day, default: []].append(PlannerWeekGrid.Blob(
                targetID: id, name: name(forTarget: id), hours: seconds / 3600,
                colorHex: colorHex(forTarget: id), kind: .owed,
                detail: ["  \(dayNames[day - 1]) was its last day this week, and it has passed",
                         "  more weekdays would help; more hours a day would not"]))
        }
        return out.mapValues { $0.sorted { $0.hours > $1.hours } }
    }

    /// Why these hours don't fit, naming the days that are full — and the spare hours they can't reach.
    ///
    /// The situation that looks like a contradiction otherwise: the week reports 1.9h unclaimed while
    /// Saturday shows 3.4h free. Both are true. What's short is office and gym, neither of which claims
    /// Saturday, so Saturday's spare is unreachable by exactly the things that need it — and telling you
    /// "more available hours would help" was wrong, because more hours on SATURDAY wouldn't.
    private func noRoomExplanation() -> String {
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var lines = ["These hours don't fit in the days that remain."]
        for (id, seconds) in dailyPlan.unplaced.sorted(by: { $0.value > $1.value }) {
            let days = (dailyPlan.claimedDays[id] ?? []).map { dayNames[$0 - 1] }
            lines.append("  \(name(forTarget: id))  \(hours(seconds))"
                         + (days.isEmpty ? "" : " — only \(days.joined(separator: ", ")) left, and full"))
        }
        let spare = dailyPlan.leftoverRoom
            .filter { $0.value > 60 }
            .sorted { $0.key < $1.key }
        if !spare.isEmpty {
            lines.append("")
            let described = spare.map { "\(dayNames[$0.key - 1]) \(hours($0.value))" }
            lines.append("Free hours do remain — " + described.joined(separator: ", ")
                         + " — but on days these allocations don't claim. Giving them those weekdays "
                         + "would reach it; more available hours would not.")
        } else {
            lines.append("")
            lines.append("Every remaining day is full, so more available hours would help.")
        }
        return lines.joined(separator: "\n")
    }

    private func problem(_ amount: String, _ text: String, tooltip: String) -> some View {
        HStack(spacing: 4) {
            Text(amount)
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Self.overColor)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .help(tooltip)
    }

    /// What ONE allocation asks of the viewed window.
    ///
    /// A week asks its weekly hours. A month asks what its own days add up to — `PlannerMonth.goal` — not the
    /// weekly rate times four: September holds 22 weekdays, so a 35h/week Mon–Fri allocation asks 154h of it,
    /// and that is the figure its week columns sum to. With `× 4` the rail said 140h while the grid on the same
    /// page showed 154h spread across the weeks.
    private func goalSeconds(for target: Target) -> TimeInterval {
        guard unit == .month, let month = periodWindow() else { return target.weeklySeconds }
        return PlannerMonth.goal(for: target, month: month, calendar: Calendar.current)
    }

    /// What the allocations ask for over the viewed window, with nested ones left out because their hours
    /// are already inside their parent's.
    private var goalSeconds: TimeInterval {
        targets
            .filter { $0.direction == .atLeast && !nestedIDs.contains($0.id) }
            .reduce(0.0) { $0 + goalSeconds(for: $1) }
    }

    /// Hours the viewed window never has, whatever day it is — the per-weekday shortfalls added up.
    ///
    /// `PeriodBudget.reservedLeft` only counts the days still to come, which is right for "what can I still
    /// do" and wrong for "how big is this week", the question a future or intended week asks.
    private func unavailableInWindow() -> TimeInterval { 0 }

    /// Which allocations were left short, and by how much.
    private func droppedExplanation(_ hoursByTarget: [Int64: TimeInterval],
                                    heading: String, footer: String) -> String {
        var lines = [heading]
        for (id, seconds) in hoursByTarget.sorted(by: { $0.value > $1.value }) {
            lines.append("  \(name(forTarget: id))  \(hours(seconds))")
        }
        lines.append("")
        lines.append(footer)
        return lines.joined(separator: "\n")
    }

    private func figure(_ label: String, _ seconds: TimeInterval, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(hours(seconds))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint)
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
            let reserved = 0.0
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
        out.stillToDo = targets
            .filter { $0.direction == .atLeast && !nestedIDs.contains($0.id) }
            .reduce(0.0) { sum, target in
                sum + max(0, goalSeconds(for: target) - (periodActuals[target.id] ?? 0))
            }
        return out
    }

    /// The verdict as one clause. The paragraph that used to follow it is gone: what it explained is
    /// visible in the grid, and the numbers beside it carry the arithmetic.
    private func verdictLine(_ plan: Planner) -> String {
        // Month view gets a MONTH verdict. `Planner` and `Replan` are week-scoped, so showing their answer
        // under a month grid said "the week fits" about four weeks of days — answering a different
        // question than the page is asking.
        if isFuture || (showIntended && unit == .week) {
            // A week that hasn't happened has no progress to report; the only question is whether the plan
            // it would start from is possible at all.
            if !plan.overloadedDays.isEmpty {
                let worst = plan.overloadedDays
                    .compactMap { day in plan.days.first { $0.weekday == day } }
                    .max { -$0.slackSeconds < -$1.slackSeconds }
                if let worst {
                    return "\(dayList([worst.weekday])) would be "
                         + "\(hours(-worst.slackSeconds)) over"
                }
            }
            let free = max(0, plan.capacitySeconds - plan.reservedSeconds)
            let spare = free - plan.requiredUpperSeconds
            return spare > 3600 ? "The plan fits, \(hours(spare)) unclaimed"
                                : "The plan barely fits"
        }
        if offset > 0 {
            // What happened, in the plainest form available: two numbers and no verb nobody uses.
            let towards = periodActuals.values.reduce(0, +)
            guard goalSeconds > 60 else { return "Nothing was allocated then" }
            return "Did \(hours(towards)) of \(hours(goalSeconds))"
        }
        if unit == .month {
            let budget = periodBudget()
            if budget.stillToDo > budget.freeLeft + 60 {
                return "Over by \(hours(budget.stillToDo - budget.freeLeft)) this month"
            }
            if offset > 0 {
                return budget.stillToDo > 60
                    ? "That month came up \(hours(budget.stillToDo)) short"
                    : "That month held together"
            }
            let spare = budget.freeLeft - budget.stillToDo
            return spare > 3600 ? "Fits, \(hours(spare)) unclaimed this month"
                                : "Fits, only just"
        }
        // Says what the comparison IS. "Not finishable" was a conclusion with its reasoning hidden,
        // which is exactly the kind of number nobody can argue with or trust.
        // Read the SAME numbers the figures below are drawn from. `Replan.weekIsLost` measures whole
        // remaining days while `periodBudget` discounts today to what's left of it, so the two disagreed
        // by a few hours — and the card said "The week fits" directly above "to do 43.1h of 42h left".
        let budget = periodBudget()
        if budget.stillToDo > budget.freeLeft + 60 {
            return "Over by \(hours(budget.stillToDo - budget.freeLeft))"
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
        case .fits:
            let spare = budget.freeLeft - budget.stillToDo
            return spare > 3600 ? "Fits, \(hours(spare)) unclaimed" : "Fits, only just"
        case .tight: return "Fits, only just"
        case .oversubscribed where !plan.overloadedDays.isEmpty:
            return "\(dayList(plan.overloadedDays)) over capacity"
        case .oversubscribed:
            let free = max(0, plan.capacitySeconds - plan.reservedSeconds)
            return "Over by \(hours(plan.requiredLowerSeconds - free))"
        case .uncertain: return "Fits only if allocations share work"
        }
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
        world = ((try? store.listProjects(includeArchived: true)) ?? [],
                 (try? store.listTaskProjects()) ?? [],
                 (try? store.listTags()) ?? [])
        assignColors()
        guard !targets.isEmpty else { plan = nil; return }

        let tasks = (try? store.listProjects(includeArchived: true)) ?? []
        let tagIDsByTask = (try? store.effectiveTagIDsByTask()) ?? [:]
        let membership = SubjectMembership(tasks: tasks, tagIDsByTask: tagIDsByTask)
        var names: [Int64: String] = [:]
        for t in targets { names[t.id] = name(for: t, tasks: tasks) }
        // No per-weekday reservations: the feature is withdrawn for now, so every day is the waking day.
        // The store still keeps and syncs the table, so bringing it back is a UI change rather than a
        // migration — but nothing reads it, and a planner that half-reads a setting is worse than one that
        // doesn't offer it.
        let input = Planner.Input(targets: targets, reservations: [],
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

        // Allocations wholly inside another. Their hours are already in the parent's, so they are not
        // drawn as blobs of their own — which means they must not OWN an hour either. When they did, the
        // hour was counted in the day's total and drawn nowhere, leaving a gap at the top of the column.
        let nested = Set(built.nestings.compactMap { nesting in
            targets.first { name(for: $0, tasks: tasks) == nesting.innerName }?.id
        })
        nestedIDs = nested

        // Who owns an hour when several allocations cover it. `SubjectMembership.primaryOwner` decides —
        // most specific wins — and it lives in Core because this rule was written inline here twice and was
        // wrong both times: once letting every covering allocation draw the hour, so days summed past a day;
        // once excluding nested allocations from owning anything, which made a nested allocation you HAD
        // worked invisible, so clicking `presentation for KT` on a Monday lit nothing up.
        //
        // Nested allocations own their hours like anyone else. What they're excluded from is the PLAN, where
        // the parent's share already covers them.
        let subjectsByTarget = Dictionary(uniqueKeysWithValues: floors.map { ($0.id, $0.subject) })
        var ownerCache: [Int64: Int64?] = [:]
        func owner(_ projectID: Int64) -> Int64? {
            if let cached = ownerCache[projectID] { return cached }
            let resolved = membership.primaryOwner(of: projectID, among: subjectsByTarget)
            ownerCache[projectID] = resolved
            return resolved
        }


        let taskNamesByID = Dictionary(tasks.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        // The current week, through the same Core function the viewed week uses. This loop used to be
        // written out here AND again below for the browsed week, and the copies drifted.
        let weekFacts = PlannerWeek.facts(intervals: intervals, window: week, floors: floors,
                                          membership: membership, nested: nested,
                                          taskNames: taskNamesByID, now: now, calendar: cal)
        actuals = weekFacts.mapValues { $0.primary }
        unallocated = weekFacts.mapValues { $0.unallocated }
        unallocatedTaskIDs = weekFacts.mapValues { Array($0.uncoveredTaskIDs) }
        actualTotals = weekFacts.mapValues { $0.total }
        let creditByDay = PlannerWeek.creditedByWeekday(weekFacts)
        let weekTotals = PlannerWeek.creditedTotals(weekFacts)

        // The viewed window's own totals, which is what the goal rows read. Separate from the weekly figures
        // above because the window can be a month, or a week that has already gone.
        if let window = periodWindow() {
            let inWindow = (try? store.intervals(from: window.start, to: window.end)) ?? []
            let windowFacts = PlannerWeek.facts(intervals: inWindow, window: window, floors: floors,
                                                membership: membership, taskNames: taskNamesByID,
                                                now: now, calendar: cal)
            periodActuals = PlannerWeek.creditedTotals(windowFacts)
            periodTracked = windowFacts.values.reduce(0) { $0 + $1.total }
        }

        let computed = Replan.compute(plan: built, input: input, actuals: weekTotals,
                                      elapsedWeekdays: Array(1..<today),
                                      remainingWeekdays: Array(today...7),
                                      fractionOfTodayLeft: Replan.fractionOfDayLeft(
                                          now: now, wakingSeconds: settings.wakingSeconds,
                                          calendar: cal))
        replan = computed

        // Who else counts an allocation's hours. With the grid attributing an hour to the most specific
        // allocation, `vllm` work no longer appears under `office` in the columns — while office's progress
        // bar still counts it, because it genuinely is office work. Saying so in the tooltip is the
        // difference between a considered model and an apparent contradiction.
        var alsoCounts: [Int64: [String]] = [:]
        for target in targets where target.direction == .atLeast {
            let mine = membership.taskIDs(for: target.subject)
            guard !mine.isEmpty else { continue }
            for other in targets
            where other.id != target.id && other.direction == .atLeast {
                let theirs = membership.taskIDs(for: other.subject)
                if !theirs.isEmpty, mine.isSubset(of: theirs) || !mine.isDisjoint(with: theirs),
                   theirs.count > mine.count {
                    alsoCounts[target.id, default: []].append(name(for: other, tasks: tasks))
                }
            }
        }

        if unit == .week {
            let viewed = periodWindow() ?? week
            // One assembly step, from Core, for whichever week is on screen — see `PlannerWeek.facts`. Two
            // copies of this loop is what let a finished week be scheduled from the CURRENT week's hours.
            let viewedFacts: [Int: PlannerWeek.DayFacts]
            if offset == 0 {
                viewedFacts = weekFacts
            } else {
                let past = (try? store.intervals(from: viewed.start, to: viewed.end)) ?? []
                viewedFacts = PlannerWeek.facts(intervals: past, window: viewed, floors: floors,
                                                membership: membership, nested: nested,
                                                taskNames: taskNamesByID, now: now, calendar: cal)
            }
            // And the plan for that week is built from that week's own credited hours.
            let viewedCredits = PlannerWeek.creditedByWeekday(viewedFacts)
            let schedulable = offset == 0 ? Array(today...7) : Array(1...7)
            switch method {
            case .catchUp:
                dailyPlan = Replan.dailyPlan(input: input, plan: built,
                                             creditedByWeekday: viewedCredits,
                                             remainingWeekdays: schedulable,
                                             fractionOfTodayLeft: offset == 0
                                                 ? Replan.fractionOfDayLeft(
                                                     now: now, wakingSeconds: settings.wakingSeconds,
                                                     calendar: cal)
                                                 : 1,
                                             skipping: nested)
                missedByDay = [:]
            case .perDay:
                let simple = Replan.perDayPlan(input: input, creditedByWeekday: viewedCredits,
                                               remainingWeekdays: offset == 0 ? Array(today...7) : [],
                                               skipping: nested)
                dailyPlan = Replan.DailyPlan(byDay: simple.byDay, unplaced: [:])
                missedByDay = simple.missedByDay
            }

            calendarDays = buildWeekColumns(week: viewed, replan: computed, nested: nested,
                                            dayActuals: viewedFacts.mapValues { $0.primary },
                                            dayOther: viewedFacts.mapValues { $0.unallocated },
                                            dayCredit: viewedCredits,
                                            breakdown: viewedFacts.mapValues { $0.breakdown },
                                            alsoCounts: alsoCounts,
                                            calendar: cal)
            monthWeekColumns = []
            monthSpans = []
        } else {
            calendarDays = []
            let built = buildMonthWeekColumns(store: store, floors: floors, nested: nested,
                                              membership: membership, calendar: cal)
            monthWeekColumns = built.columns
            monthSpans = built.spans
            monthWeekCapacity = built.capacity
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
                                  dayCredit: [Int: [Int64: TimeInterval]],
                                  breakdown: [Int: [Int64: [String: TimeInterval]]],
                                  alsoCounts: [Int64: [String]],
                                  calendar cal: Calendar) -> [PlannerWeekGrid.DayInput] {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let startOfToday = cal.startOfDay(for: Date())
        let owedOrder = replan.items.sorted { $0.debtSeconds > $1.debtSeconds }.map(\.targetID)

        func intendedDay(_ weekday: Int) -> Planner.DayPlan? {
            plan?.days.first { $0.weekday == weekday }
        }
        let leftovers = leftoversByDay()

        var out: [PlannerWeekGrid.DayInput] = []
        for offsetDays in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: offsetDays, to: week.start) else { break }
            let weekday = cal.component(.weekday, from: date)
            let dayStart = cal.startOfDay(for: date)
            var blobs: [PlannerWeekGrid.Blob] = []

            // Bottom of the column: hours that were never available to anything.

            // Then, per allocation, what was done and what is still owed of THIS DAY'S OWN intention —
            // adjacent, as one visual unit.
            //
            // Listing all the solids and then all the dashes put today's "office 1.4h done" at the bottom of
            // the column and its "office 5.6h to go" at the top, with four other blobs in between. The two
            // halves of one fact should touch.
            let intendedByID = Dictionary(
                (intendedDay(weekday)?.placements ?? []).map { ($0.targetID, $0.seconds) },
                uniquingKeysWith: { a, _ in a })
            let doneByID = (dayActuals[weekday] ?? [:]).filter { $0.value > 60 }
            let owes = PlannerWeek.drawsPlanBlocks(offset: offset,
                                                   dayIsBeforeToday: dayStart < startOfToday,
                                                   showIntended: showIntended)
            // NOT filtered by nesting: a nested allocation's tracked hours are its own and have to be
            // visible, or clicking it highlights nothing on a day you actually worked it. Only the PLAN
            // half of the loop below skips nested, because the parent's share already covers those hours.
            let ids = Set(doneByID.keys)
                .union(owes ? Array((dailyPlan.byDay[weekday] ?? [:]).keys) : [])
                .sorted { lhs, rhs in
                    // The day's biggest commitment sits at the bottom in both views, so switching between
                    // them doesn't rearrange the column.
                    let li = intendedByID[lhs] ?? 0, ri = intendedByID[rhs] ?? 0
                    if li != ri { return li > ri }
                    return (doneByID[lhs] ?? 0) > (doneByID[rhs] ?? 0)
                }

            for id in ids {
                if let done = doneByID[id], done > 60 {
                    // The block is EXCLUSIVE — each hour is drawn once, under the narrowest allocation
                    // covering it — while the rail's progress bar is inclusive. Both are right, and without
                    // saying so a day of 6.1h office beside 40m of presentation invites the question of
                    // whether the 6.1h contains the 40m.
                    let credited = (dayCredit[weekday] ?? [:])[id] ?? done
                    var notes = detailLines(breakdown[weekday]?[id])
                    if credited - done > 60 {
                        notes.append("+\(hours(credited - done)) more counts toward this, drawn under a "
                                     + "narrower allocation")
                    }
                    if let also = alsoCounts[id], !also.isEmpty {
                        notes.append("also counts toward " + also.joined(separator: ", "))
                    }
                    blobs.append(PlannerWeekGrid.Blob(
                        targetID: id, name: name(forTarget: id), hours: done / 3600,
                        colorHex: colorHex(forTarget: id), kind: .tracked, detail: notes))
                }
            }

            // Work no allocation covers: real hours, so they sit with the other real hours.
            if let other = dayOther[weekday], other > 60 {
                blobs.append(PlannerWeekGrid.Blob(targetID: -2, name: "off-plan",
                                                  hours: other / 3600,
                                                  colorHex: "#8E8E93", kind: .unallocated,
                                                  detail: detailLines(breakdown[weekday]?[-2])))
            }

            // The hours that went by with nothing recorded — today's elapsed part, or the whole of a day
            // that has gone. Above the work, closing off the part of the day that is over — so everything
            // higher in the column is still to come. Drawing it at all is what makes a column add up to a
            // whole day rather than trailing off into ambiguous empty space.
            if !showIntended, !isFuture, dayStart <= startOfToday {
                let trackedToday = (dayActuals[weekday] ?? [:]).values.reduce(0, +)
                    + (dayOther[weekday] ?? 0)
                let elapsed = dayStart < startOfToday
                    ? settings.wakingSeconds
                    : elapsedHoursToday * 3600
                let missing = max(0, elapsed - trackedToday)
                if missing > 60 {
                    blobs.append(PlannerWeekGrid.Blob(targetID: -3, name: "untracked",
                                                      hours: missing / 3600,
                                                      colorHex: "#8E8E93", kind: .untracked))
                }
            }

            // Above the line drawn by what has gone: what the days still to come are being asked for. Its
            // own share dashed, anything moved onto it dotted.
            if owes {
                for id in ids where !nested.contains(id) {
                    // Nested allocations get no PLAN block: the parent's share already covers those hours.
                    // Their tracked hours are still drawn above, which is what makes them traceable.
                    guard let share = dailyPlan.byDay[weekday]?[id], share.total > 60 else { continue }
                    // ONE block per allocation, not its own share plus a "+1h moved here" stacked on top.
                    // Two adjacent blocks of the same colour and name read as a duplicate, and the split is
                    // detail: what the day is being asked for is one number. The tooltip has the breakdown.
                    var detail: [String] = []
                    if share.carried > 60, share.intended > 60 {
                        detail = ["  \(hours(share.intended)) this day's own share",
                                  "  \(hours(share.carried)) moved here from another day"]
                    } else if share.carried > 60 {
                        detail = ["  all of it moved here from another day"]
                    }
                    blobs.append(PlannerWeekGrid.Blob(
                        targetID: id, name: name(forTarget: id), hours: share.total / 3600,
                        colorHex: colorHex(forTarget: id), kind: .owed, detail: detail))
                }
            }


            // The plan as designed: the even spread over each allocation's own claimed days, with no
            // reference to what happened. This is the whole of a future week, and the "intended" view of
            // any other one — the same numbers `Planner` used to decide whether the week fits at all.
            if showIntended || isFuture {
                blobs = blobs.filter { $0.kind == .reserved }
                for placement in intendedDay(weekday)?.placements
                    .sorted(by: { $0.seconds > $1.seconds }) ?? []
                where placement.seconds > 60 && !nested.contains(placement.targetID) {
                    blobs.append(PlannerWeekGrid.Blob(
                        targetID: placement.targetID, name: name(forTarget: placement.targetID),
                        hours: placement.seconds / 3600,
                        colorHex: colorHex(forTarget: placement.targetID), kind: .owed))
                }
            }

            // Slivers collapse. With fifteen allocations a day becomes a stack of unlabelled two-pixel
            // bands — the arithmetic stays right and the column stops being readable, which is its own
            // kind of wrong. Anything under twenty minutes joins one block per kind, named for how many
            // it stands for, with the detail in its tooltip.
            blobs = Self.collapsingSlivers(blobs)

            out.append(PlannerWeekGrid.DayInput(
                weekday: weekday, label: names[weekday - 1],
                dayOfMonth: dayStart == startOfToday || !(showIntended || isFuture)
                    ? cal.component(.day, from: date) : cal.component(.day, from: date),
                isPast: dayStart < startOfToday && !isFuture,
                isToday: dayStart == startOfToday && !isFuture,
                blobs: blobs, leftovers: leftovers[weekday] ?? []))
        }
        return out
    }

    /// Merge blobs too small to label into one per kind, preserving their order and total.
    ///
    /// The threshold is twenty minutes: below that a block can't hold its own name at any window width, and
    /// a column of anonymous slivers says less than a single block that admits there are six of them.
    static func collapsingSlivers(_ blobs: [PlannerWeekGrid.Blob]) -> [PlannerWeekGrid.Blob] {
        let floorHours = 20.0 / 60
        var out: [PlannerWeekGrid.Blob] = []
        var pending: [PlannerWeekGrid.Kind: [PlannerWeekGrid.Blob]] = [:]

        func flush(_ kind: PlannerWeekGrid.Kind) {
            guard let group = pending[kind], !group.isEmpty else { return }
            pending[kind] = nil
            if group.count == 1 {
                out.append(group[0])
                return
            }
            let total = group.reduce(0.0) { $0 + $1.hours }
            out.append(PlannerWeekGrid.Blob(
                targetID: -4, name: "\(group.count) small",
                hours: total, colorHex: "#8E8E93", kind: kind,
                detail: group.sorted { $0.hours > $1.hours }.map {
                    "  \($0.name)  " + (($0.hours * 60) >= 1
                                       ? "\(Int(($0.hours * 60).rounded()))m" : "<1m")
                }))
        }

        for blob in blobs {
            if blob.hours < floorHours, blob.kind != .reserved, blob.kind != .untracked {
                pending[blob.kind, default: []].append(blob)
                continue
            }
            // Any block big enough to stand alone closes EVERY pending group, not just its own kind.
            // Closing only its own kind left a lone sliver waiting until the end of the loop, which put it
            // at the top of the column — a stray 1.3h-coloured band above everything, miles from the block
            // it belongs beside.
            for kind in [PlannerWeekGrid.Kind.tracked, .unallocated, .owed] { flush(kind) }
            out.append(blob)
        }
        for kind in [PlannerWeekGrid.Kind.tracked, .unallocated, .owed] { flush(kind) }
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

    private var monthWeekSubtitle: String {
        if showIntended {
            return "the plan as designed, ignoring what actually happened"
        }
        if method == .perDay {
            return "every week keeps its own share · what a week missed stays under it"
        }
        return offset > 0
            ? "where that month's shortfall would have had to go · nothing leaves the month"
            : "a week that fell short pushes into the weeks this month has left · nothing leaves the month"
    }

    /// What the pool under a week means, in this combination of month and method.
    private var monthLeftoverCaption: String {
        if method == .perDay { return "missed that week" }
        return offset > 0 ? "never happened" : "no room left in the month"
    }

    /// Open the week a column stands for in Metrics, with the clicked allocation pinned.
    ///
    /// The span's first day, not the week's: a column only represents the part of the week inside the month,
    /// and landing on a day in the previous month would answer about hours this column never counted.
    private func openWeekInMetrics(targetID: Int64, spanIndex: Int) {
        guard let span = monthSpans.first(where: { $0.index == spanIndex }) else { return }
        let subjects = targets.first { $0.id == targetID }.map { [$0.subject] } ?? []
        appState.metricsHandoff = AppState.MetricsHandoff(day: span.inMonth.start, subjects: subjects)
    }

    /// The month's weeks as filling containers, with the pool of what the month couldn't absorb.
    ///
    /// All of the arithmetic is `PlannerMonth.rollups`; this turns it into blocks. The stacking order matches
    /// the week view exactly — tracked, off-plan, untracked, then what's still owed — because the two grids
    /// are the same statement at two scales and a different order would make them look like different ideas.
    private func buildMonthWeekColumns(store: IntervalStore, floors: [Target], nested: Set<Int64>,
                                       membership: SubjectMembership, calendar cal: Calendar)
    -> (columns: [PlannerWeekGrid.DayInput], spans: [PlannerMonth.WeekSpan], capacity: Double) {
        guard let month = periodWindow() else { return ([], [], 0) }
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let intervals = (try? store.intervals(from: month.start, to: month.end)) ?? []
        let rollups = PlannerMonth.rollups(
            month: month, intervals: intervals, floors: floors, membership: membership,
            nested: nested, wakingSeconds: settings.wakingSeconds,
            method: method,
            fractionOfTodayLeft: Replan.fractionOfDayLeft(now: now,
                                                          wakingSeconds: settings.wakingSeconds,
                                                          calendar: cal),
            now: now, calendar: cal)
        guard !rollups.isEmpty else { return ([], [], 0) }

        // A finished month draws no plan blocks, for the same reason a finished week doesn't: there is
        // nowhere left to reallocate into, so dashed hours would claim work landed somewhere it demonstrably
        // didn't. What it owed goes to the pool instead — accumulated at the end under catch up, left under
        // the week that missed it under per week, which is the week view's rule one unit up.
        let draws = PlannerWeek.drawsPlanBlocks(offset: offset, dayIsBeforeToday: false,
                                                showIntended: showIntended)
        let hindsight: [Int: [Int64: TimeInterval]] = {
            guard offset > 0, method == .catchUp, !showIntended else { return [:] }
            var out: [Int: [Int64: TimeInterval]] = [:]
            for miss in PlannerMonth.neverHappened(floors: floors, month: month,
                                                   credited: periodActuals, nested: nested,
                                                   calendar: cal) {
                out[miss.lastWeek, default: [:]][miss.id] = miss.missed
            }
            return out
        }()

        var columns: [PlannerWeekGrid.DayInput] = []
        for rollup in rollups {
            var blobs: [PlannerWeekGrid.Blob] = []
            if !showIntended {
                blobs += trackedBlobs(rollup)
            }
            if draws || showIntended {
                blobs += owedBlobs(rollup)
            }
            let pool = hindsight[rollup.span.index] ?? (showIntended ? [:] : rollup.leftover)
            columns.append(PlannerWeekGrid.DayInput(
                weekday: rollup.span.index,
                label: "\(rollup.span.firstDay)–\(rollup.span.lastDay)",
                dayOfMonth: nil,
                isPast: rollup.span.inMonth.end <= startOfToday,
                isToday: rollup.span.inMonth.start <= startOfToday
                         && startOfToday < rollup.span.inMonth.end,
                blobs: Self.collapsingSlivers(blobs),
                leftovers: leftoverBlobs(pool),
                capacityHours: (rollup.capacity + rollup.outsideCapacity) / 3600,
                countedHours: rollup.capacity / 3600,
                cap: outsideCap(rollup)))
        }
        // Every column is a whole calendar week, so they all share one ceiling and comparing their fill is
        // just comparing heights.
        let capacity = rollups.map { ($0.capacity + $0.outsideCapacity) / 3600 }.max() ?? 0
        return (columns, rollups.map(\.span), capacity)
    }

    /// What a week actually did: one solid block per allocation, then work no allocation covers, then the
    /// hours that went by unrecorded. Same order as the week view's days.
    private func trackedBlobs(_ rollup: PlannerMonth.WeekRollup) -> [PlannerWeekGrid.Blob] {
        var out: [PlannerWeekGrid.Blob] = []
        for (id, seconds) in rollup.tracked.sorted(by: { $0.value > $1.value }) where seconds > 60 {
            let creditedHere: TimeInterval = rollup.credited[id] ?? seconds
            var detail: [String] = []
            if creditedHere - seconds > 60 {
                detail.append("+\(hours(creditedHere - seconds)) more counts toward this, drawn under a "
                              + "narrower allocation")
            }
            out.append(PlannerWeekGrid.Blob(
                targetID: id, name: name(forTarget: id), hours: seconds / 3600,
                colorHex: colorHex(forTarget: id), kind: .tracked, detail: detail))
        }
        if rollup.unallocated > 60 {
            out.append(PlannerWeekGrid.Blob(targetID: -2, name: "off-plan",
                                            hours: rollup.unallocated / 3600,
                                            colorHex: "#8E8E93", kind: .unallocated))
        }
        if rollup.untracked > 60 {
            out.append(PlannerWeekGrid.Blob(targetID: -3, name: "untracked",
                                            hours: rollup.untracked / 3600,
                                            colorHex: "#8E8E93", kind: .untracked))
        }
        return out
    }

    /// What a week is asked for. In the intended view that's its own share with no reference to what happened;
    /// otherwise it's what the plan put there, including anything moved in from a week that fell short.
    private func owedBlobs(_ rollup: PlannerMonth.WeekRollup) -> [PlannerWeekGrid.Blob] {
        if showIntended {
            return rollup.want.sorted { $0.value > $1.value }
                .filter { $0.value > 60 }
                .map { pair in
                    PlannerWeekGrid.Blob(targetID: pair.key, name: name(forTarget: pair.key),
                                         hours: pair.value / 3600,
                                         colorHex: colorHex(forTarget: pair.key), kind: .owed)
                }
        }
        var out: [PlannerWeekGrid.Blob] = []
        for (id, share) in rollup.owed.sorted(by: { $0.value.total > $1.value.total })
        where share.total > 60 {
            var detail: [String] = []
            if share.carried > 60, share.intended > 60 {
                detail = ["  \(hours(share.intended)) this week's own share",
                          "  \(hours(share.carried)) moved here from an earlier week"]
            } else if share.carried > 60 {
                detail = ["  all of it moved here from an earlier week"]
            } else if method == .perDay {
                detail = ["  this week's own share — per week moves nothing between weeks"]
            }
            out.append(PlannerWeekGrid.Blob(
                targetID: id, name: name(forTarget: id), hours: share.total / 3600,
                colorHex: colorHex(forTarget: id), kind: .owed, detail: detail))
        }
        return out
    }

    private func leftoverBlobs(_ pool: [Int64: TimeInterval]) -> [PlannerWeekGrid.Blob] {
        let why: [String] = method == .perDay
            ? ["  wanted in this week and never done",
               "  nothing was moved to another week — that's the per week method"]
            : ["  wanted in this week and never done",
               "  no week left in the month could take it either"]
        return pool.sorted { $0.value > $1.value }
            .filter { $0.value > 60 }
            .map { pair in
                PlannerWeekGrid.Blob(targetID: pair.key, name: name(forTarget: pair.key),
                                     hours: pair.value / 3600,
                                     colorHex: colorHex(forTarget: pair.key), kind: .owed, detail: why)
            }
    }

    /// The days of a neighbouring month this calendar week also holds, capping the column.
    ///
    /// Their tracked hours are named but deliberately not counted: this week appears in two months' views, and
    /// adding them here would make the column disagree with the month's own totals.
    private func outsideCap(_ rollup: PlannerMonth.WeekRollup) -> PlannerWeekGrid.Blob? {
        guard rollup.span.outsideDays > 0 else { return nil }
        let tracked = rollup.outsideTracked > 60
            ? "\(hours(rollup.outsideTracked)) tracked then, counted in that month"
            : "nothing tracked on them"
        return PlannerWeekGrid.Blob(
            targetID: -4,
            name: "\(rollup.span.outsideDays)d other month",
            hours: rollup.outsideCapacity / 3600,
            colorHex: "#8E8E93", kind: .otherMonth,
            detail: ["  this calendar week reaches outside the month",
                     "  " + tracked])
    }

    private func name(for target: Target, tasks: [Project]? = nil) -> String {
        BudgetRows.name(for: target.subject, tasks: tasks ?? world.tasks,
                        groups: world.groups, tags: world.tags) ?? "(deleted)"
    }

    private func name(forTarget id: Int64) -> String {
        targets.first { $0.id == id }.map { name(for: $0) } ?? "?"
    }

    private func colorHex(forTarget id: Int64) -> String {
        if let assigned = targetColors[id] { return assigned }
        guard let target = targets.first(where: { $0.id == id }) else { return "#8E8E93" }
        return BudgetRows.colorHex(for: target.subject, tasks: world.tasks,
                                  groups: world.groups, tags: world.tags)
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
            let base = BudgetRows.colorHex(for: target.subject, tasks: world.tasks,
                                           groups: world.groups, tags: world.tags)
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

    /// The dot, from the same numbers as the sentence beside it — in every mode.
    ///
    /// It used to read the week-scoped `Planner.Verdict` for the current week and `periodBudget` otherwise,
    /// which is how a green dot ended up next to "43.1h to do, only 42h free left". Orange means TIGHT,
    /// not merely "has work left", or every period with anything in it would be amber.
    private func verdictColor(_ v: Planner.Verdict) -> Color {
        // An intended or future week is judged on whether the PLAN is possible; it has no progress yet, so
        // reading this week's shortfall gave an amber dot beside "the plan fits, 33h unclaimed".
        if isFuture || (showIntended && unit == .week) {
            guard let plan else { return .secondary }
            if !plan.overloadedDays.isEmpty { return Self.overColor }
            let free = max(0, plan.capacitySeconds - plan.reservedSeconds)
            return plan.requiredUpperSeconds <= free ? .green : .orange
        }
        let budget = periodBudget()
        if let plan, !plan.overloadedDays.isEmpty, unit == .week, offset == 0 {
            return Self.overColor
        }
        if budget.stillToDo <= 60 { return .green }
        if budget.stillToDo > budget.freeLeft + 60 { return Self.overColor }
        let spare = budget.freeLeft - budget.stillToDo
        return spare < budget.freeLeft * 0.12 ? .orange : .green
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
