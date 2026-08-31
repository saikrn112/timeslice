import Charts
import SwiftUI
import TimesliceCore
import TimesliceUI

/// Metrics, in the Mac's order: range filter, tiles, **Budgets**, timeline-or-hours, Where time went,
/// then sessions-or-weekday.
///
/// Budgets is a section here rather than its own tab, matching the Mac. Every number comes from
/// `Aggregations` and `BudgetRows`, so the phone cannot disagree with the Mac over the same database.
///
/// Two Mac affordances are dropped, both pointer-dependent: the timeline's **drag-select** (a drag on
/// a 390pt chart fights the scroll view) and **hover highlighting** of a breakdown row. Tapping a
/// block to inspect it is the touch equivalent of the first; the second has no touch analogue worth
/// inventing, which is also why the "Dim others" setting is absent.
struct MetricsScreen: View {
    @ObservedObject private var model = TimerModel.shared
    @State private var range = DateRange.resolve(unit: .day, anchor: Date())
    @State private var earliest: Date?
    @State private var data = MetricsData()
    @State private var scope: BreakdownScope = .tasks
    @State private var inspected: DaySegment?

    /// Same three-way breakdown the Mac has.
    private enum BreakdownScope: String, CaseIterable, Identifiable {
        case tasks = "Tasks", projects = "Projects", tags = "Tags"
        var id: String { rawValue }
    }

    private struct MetricsData {
        var summary = RangeSummary(totalSeconds: 0, deepSeconds: 0, activeDays: 0, switches: 0,
                                   longestSessionSeconds: 0, bestDaySeconds: 0)
        var buckets: [Bucket] = []
        var segments: [DaySegment] = []
        var taskTotals: [ProjectTotal] = []
        var groupTotals: [TaskProjectTotal] = []
        var tagTotals: [TagTotal] = []
        var weekdays: [WeekdayAverage] = []
        var sessions: [Interval] = []
        var budgets: [BudgetRows.Row] = []
        /// The neighbouring periods, for the card strip that browses them.
        var strip: [PeriodCard] = []
    }

    private var isDay: Bool { range.unit == .day }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rangeBar
                    // Browse by tapping a card, not by stepping one period at a time.
                    if !data.strip.isEmpty {
                        PeriodStrip(cards: data.strip, selected: range) { range = $0 }
                    }
                    // Everything below the strip is *about* the selected period, so a swipe anywhere in
                    // here moves it. `.gesture` on a `Group` attaches to each child rather than to one
                    // combined area, which is what's wanted: the strip above keeps its own horizontal
                    // scrolling, and a parent gesture spanning it would fight that.
                    Group {
                        heroCard
                        budgets
                        if isDay { dayTimeline } else { hoursChart }
                        whereTimeWent
                        if isDay { sessionList } else { weekdayPattern }
                    }
                    .gesture(periodSwipe())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            }
            .background(Theme.page)
            .navigationTitle("Metrics")
            .toolbar { gearButton }
            .onAppear {
                // `load()` FIRST, and again here rather than relying on RootView: tab children get
                // `onAppear` in an unspecified order relative to their parent, so `rebuild()` could
                // run against an empty `allTasks` — which rendered every row as "(deleted task)"
                // and every block grey after a fresh install. It only ever looked fine because a
                // previous launch had left data in memory.
                model.load()
                rebuild()
            }
            .onChange(of: range) { _, _ in rebuild() }
            .onChange(of: model.running?.projectID) { _, _ in rebuild() }
            // Rebuild when the underlying data changes at all — a reseed, a sync merge, or an edit
            // on the other tab. Without this, metrics silently kept showing the previous dataset.
            .onChange(of: model.tasks) { _, _ in rebuild() }
            .onChange(of: model.groups) { _, _ in rebuild() }
        }
    }

    private var gearButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }
        }
    }

    // MARK: - Range

    /// Just the unit pills, centred — which period LENGTH you're looking at.
    ///
    /// The `‹ Yesterday ›` stepper is gone. Once the card strip browses dates and a swipe moves between
    /// them, the stepper was a third control for a job two already did, and it was the cluttered half of
    /// the bar. Nothing is lost with it: the strip shows which period is selected, and the hero card
    /// spells it out ("tracked yesterday").
    ///
    /// Changing the unit rebuilds the strip into that unit's periods, so this control and the strip below
    /// it are one mechanism — pick a granularity here, pick a position there.
    ///
    /// Pills are sized for a thumb now that they own the row: 13pt in a 30pt-tall capsule, against 10pt
    /// crammed beside the stepper.
    private var rangeBar: some View {
        HStack(spacing: 6) {
            ForEach(RangeUnit.allCases, id: \.self) { u in
                let selected = range.unit == u
                Button {
                    // Keep your position in time when changing granularity: the week containing the day
                    // you were on, not the current week.
                    let anchor = range.isCurrent() ? Date() : min(range.start, Date())
                    range = DateRange.resolve(unit: u, anchor: anchor, earliest: earliest)
                } label: {
                    Text(u.rawValue)
                        .font(.system(size: 13, weight: selected ? .bold : .medium, design: .rounded))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .frame(minWidth: 30, minHeight: 30)
                        .background(Capsule().fill(
                            selected ? Color.accentColor : Color.secondary.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Move by whole periods. Returns false when the move was refused, so a swipe can decline to buzz.
    @discardableResult
    private func step(_ delta: Int) -> Bool {
        let next = range.stepped(by: delta, earliest: earliest)
        guard next.start <= Date(), next != range else { return false }
        range = next
        return true
    }

    /// Swipe horizontally to change period.
    ///
    /// Tapping a card in the strip was the only way to change the date, which meant the one gesture a
    /// phone makes you reach for wasn't wired to anything: the strip scrolls under your finger but
    /// scrolling it selects nothing, so sliding felt like it should work and didn't.
    ///
    /// Content follows the finger — dragging LEFT moves forward in time, as in every calendar app.
    ///
    /// Attached to individual cards rather than to the scroll view, and gated on the drag being
    /// predominantly horizontal, because a gesture that fires on a mostly-vertical drag steals the
    /// page's own scrolling. `step` refuses to cross into the future, and declining to move also
    /// declines the haptic, so the edge of the range feels like an edge.
    private func periodSwipe() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                // Direction and the vertical-drag veto live in `DateRange.swipeDelta`, which is pure and
                // self-tested — the gesture can't be exercised headlessly, so the decision it makes is
                // the part worth pinning down.
                guard let delta = DateRange.swipeDelta(dx: value.translation.width,
                                                       dy: value.translation.height) else { return }
                if step(delta) { Haptics.switched() }
            }
    }

    // MARK: - The selected period, as one card

    /// ONE card for the selected period: focus ring, the total beside it, and the supporting figures
    /// underneath.
    ///
    /// Replaces a 2×2 grid of four flat tiles. The tiles each held one number with a caption, which is
    /// the shape of a table — four of them stacked above three more sections is what made the screen
    /// read as a page of data rather than as a summary. Grouping them puts the headline (how long) and
    /// the quality (how focused) in one glance, with the rest as detail where it belongs.
    ///
    /// Every figure still comes from `Aggregations.summary`; nothing is recomputed here.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                LabelledRing(fraction: data.summary.focusRatio, tint: .purple, lineWidth: 8) {
                    VStack(spacing: 0) {
                        Text(percent(data.summary.focusRatio))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text("focus")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 74, height: 74)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hoursOnly(data.summary.totalSeconds))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("tracked \(range.label().lowercased())")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(hoursOnly(data.summary.deepSeconds)) in blocks of "
                         + "\(model.settings.deepBlockMinutes)m or more")
                        .font(Theme.captionSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            Divider()

            // The supporting figures, as a single row of stats rather than as separate cards. Same
            // numbers the tiles carried; a third of the vertical space.
            HStack(alignment: .top, spacing: 0) {
                if isDay {
                    stat("Switches", "\(data.summary.switches)", .orange)
                    stat("Longest", Format.compact(data.summary.longestSessionSeconds), .teal)
                    stat("Waking", percent(wakingRatio), .blue)
                } else {
                    stat("Avg/day", hoursOnly(data.summary.avgPerActiveDay), .teal)
                    stat("Best day", hoursOnly(data.summary.bestDaySeconds), .blue)
                    stat("Active", "\(data.summary.activeDays)d", .orange)
                }
            }
        }
        .padding(Theme.cardPadding + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius + 4).fill(Theme.card))
    }

    /// Share of waking hours in the range that got tracked at all.
    ///
    /// The denominator counts every CALENDAR day in the range, including ones with nothing recorded: a
    /// day you tracked nothing is exactly when the gap should be widest, and using only active days
    /// would hide that by shrinking the denominator to match.
    private var wakingRatio: Double {
        let days = max(1, (range.end.timeIntervalSince(range.start) / 86_400).rounded())
        let awake = model.settings.wakingSeconds * days
        return awake > 0 ? data.summary.totalSeconds / awake : 0
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label)
                .font(Theme.captionSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }

    /// Hours, dropping the decimal once the number is big enough not to need it — the Mac's
    /// `hoursOnly`. Budgets and tiles are talked about in hours, never "1d 16h".
    private func hoursOnly(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        return h >= 10 ? String(format: "%.0fh", h) : String(format: "%.1fh", h)
    }

    // MARK: - Budgets (a section here, as on the Mac)

    @ViewBuilder
    private var budgets: some View {
        if !data.budgets.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("Budgets").font(Theme.sectionHeader)
                    // Says which ring is which. Two nested rings are only concise if you know what
                    // they mean, and there's nowhere on a 60pt ring to label them.
                    Text("outer: period · inner: today")
                        .font(Theme.captionSmall).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Edit") { model.showingSettings = true }
                        .font(Theme.captionSmall)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                          spacing: 8) {
                    ForEach(data.budgets) { row in budgetCard(row) }
                }
            }
        }
    }

    /// One budget as a card with BOTH goals as circles: outer the period, inner today.
    ///
    /// Was a ring plus a labelled `today` bar plus four durations. Two goals, expressed two different
    /// ways, is what made the grid cluttered — the bar row cost a whole row per card and three of its
    /// numbers restated what a second ring says at a glance. Both goals are now the same kind of object,
    /// so the card is read once rather than parsed twice.
    ///
    /// What's left is the irreducible set: which budget, how much so far, and what the budget is.
    /// Everything else is in the rings.
    ///
    /// Percentages, pace and verdicts are all `TargetProgress`'s, unchanged.
    private func budgetCard(_ row: BudgetRows.Row) -> some View {
        let p = row.progress
        let tint = Theme.verdict(kind(p.verdict))
        // Today against the period target divided by its nominal days, so a 30h/week floor reads as
        // "4h 17m a day". This is the figure that says what to do *today*, which a weekly percentage
        // cannot.
        let perDay = p.target.seconds / max(p.target.period.nominalDays, 1)
        let dailyFraction = perDay > 0 ? p.todaySeconds / perDay : 0
        return HStack(alignment: .center, spacing: 10) {
            NestedRings(outerFraction: p.percent / 100,
                        // A pace mark only means something for a floor: a ceiling has no "you should
                        // be here by now".
                        outerPace: p.target.direction == .atLeast ? p.elapsedFraction : nil,
                        outerTint: tint,
                        innerFraction: dailyFraction,
                        innerTint: Color(hex: row.colorHex),
                        lineWidth: 6) {
                Text(percent(p.percent / 100))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: row.colorHex)).frame(width: 7, height: 7)
                    Text(p.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(BudgetRows.duration(p.actualSeconds))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("\(p.target.direction.symbol) \(BudgetRows.duration(p.target.seconds))"
                     + " / \(shortPeriod(p.target.period))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
    }

    private func shortPeriod(_ p: Target.Period) -> String {
        switch p {
        case .day: return "d"
        case .week: return "wk"
        case .month: return "mo"
        }
    }

    private func kind(_ v: TargetProgress.Verdict) -> TargetVerdictKind {
        switch v {
        case .over: return .over
        case .behind: return .behind
        case .onPace: return .onPace
        case .met: return .met
        }
    }

    // MARK: - Day timeline, with one lane per device

    private var dayTimeline: some View {
        section("Day timeline", subtitle: timelineSubtitle) {
            if data.segments.isEmpty {
                placeholder("Nothing tracked on this day")
            } else {
                // A lane now exists only where blocks genuinely overlap, so there is no device
                // column to label; the strip takes the full width.
                timelineStrip(lanes: max(1, Aggregations.laneCount(data.segments)))
                hourAxis
                timelineFooter(Aggregations.orderedDevices(data.segments))
                if let seg = inspected { inspector(seg) } else {
                    Text("Tap a block to inspect it.")
                        .font(Theme.captionSmall).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Flags OVERLAP, not devices.
    ///
    /// It used to read "3 devices" beside a strip whose rows were one-per-device. Now that a row
    /// exists only where blocks genuinely collide, a device count next to it implies rows map to
    /// devices when they don't — and the per-device totals under the strip already name them.
    ///
    /// A second row is now an anomaly worth pointing at: only one timer runs across all devices, so
    /// overlap means a sync race left two intervals covering the same minutes.
    private var timelineSubtitle: String? {
        let lanes = Aggregations.laneCount(data.segments)
        guard lanes > 1 else { return nil }
        return "overlapping blocks"
    }

    private func laneHeight(_ lanes: Int) -> CGFloat {
        lanes > 1 ? max(14, 58 / CGFloat(lanes)) : 30
    }

    private func deviceName(_ devices: [String?], _ lane: Int) -> String {
        guard lane < devices.count, let id = devices[lane] else { return "—" }
        return model.deviceLabels[id] ?? id
    }

    private func timelineStrip(lanes: Int) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lh = laneHeight(lanes)
            ZStack(alignment: .topLeading) {
                ForEach([6, 12, 18], id: \.self) { hour in
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(width: 0.5, height: geo.size.height)
                        .offset(x: w * CGFloat(hour) / 24)
                }
                ForEach(data.segments) { seg in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: colorHex(for: seg.projectID)))
                        .frame(width: max(1.5, w * CGFloat((seg.endHour - seg.startHour) / 24)),
                               height: max(3, lh - 2))
                        .offset(x: w * CGFloat(seg.startHour / 24),
                                y: CGFloat(seg.lane) * (lh + 2))
                        .onTapGesture { inspected = seg }
                }
            }
        }
        .frame(height: CGFloat(lanes) * (laneHeight(lanes) + 2))
    }

    /// `12a 3a 6a 9a 12p 3p 6p 9p` — the Mac's labels. Bare 0/6/12/18/24 read as an index rather
    /// than a time of day.
    private var hourAxis: some View {
        HStack(spacing: 0) {
            ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { h in
                Text(clockLabel(h))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: h == 0 ? .leading : .center)
            }
        }
    }

    private func clockLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case ..<12: return "\(hour)a"
        default: return "\(hour - 12)p"
        }
    }

    /// Per-lane totals plus a colour legend, both of which the Mac prints under the timeline. Without
    /// them the strip says *when* but not *how much* or *what*.
    @ViewBuilder
    private func timelineFooter(_ devices: [String?]) -> some View {
        let byDevice = Dictionary(grouping: data.segments, by: { $0.deviceID })
        if devices.count > 1 {
            HStack(spacing: 10) {
                ForEach(devices.compactMap { $0 }, id: \.self) { id in
                    let secs = (byDevice[id] ?? []).reduce(0.0) {
                        $0 + ($1.endHour - $1.startHour) * 3600
                    }
                    HStack(spacing: 3) {
                        Text(model.deviceLabels[id] ?? id)
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(Format.compact(secs))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        // Legend: every task that appears on the strip, so a colour can be named.
        let taskIDs = Array(Set(data.segments.map(\.projectID)))
        let named = taskIDs.compactMap { id -> (String, String)? in
            guard let t = model.task(id: id) else { return nil }
            return (t.name, model.colorHex(for: t))
        }.sorted { $0.0 < $1.0 }
        if !named.isEmpty {
            FlowRow(spacing: 6) {
                ForEach(named, id: \.0) { name, hex in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(hex: hex))
                            .frame(width: 7, height: 7)
                        Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func inspector(_ seg: DaySegment) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: colorHex(for: seg.projectID))).frame(width: 7, height: 7)
            Text(model.task(id: seg.projectID)?.name ?? "(deleted)").font(Theme.caption)
            if let id = seg.deviceID, let label = model.deviceLabels[id] {
                Text(label).font(Theme.captionSmall).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(hourLabel(seg.startHour))–\(hourLabel(seg.endHour))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Text(Format.compact((seg.endHour - seg.startHour) * 3600))
                .font(.system(size: 10, design: .monospaced))
        }
    }

    // MARK: - Charts

    private var hoursChart: some View {
        section(range.unit == .year || range.unit == .all ? "Hours per month" : "Hours per day", subtitle: nil) {
            if data.buckets.allSatisfy({ $0.totalSeconds == 0 }) {
                placeholder("Nothing tracked in this range")
            } else {
                Chart(data.buckets) { b in
                    BarMark(x: .value("Bucket", b.start, unit: chartUnit),
                            y: .value("Hours", b.totalSeconds / 3600))
                        .foregroundStyle(Color.accentColor)
                }
                .chartYAxis { AxisMarks(position: .trailing) }
                .frame(height: 108)
            }
        }
    }

    private var chartUnit: Calendar.Component {
        switch range.unit {
        case .day: return .hour
        case .week, .month: return .day
        case .sixMonths: return .weekOfYear
        case .year, .all: return .month
        }
    }

    private var weekdayPattern: some View {
        section("Weekday pattern", subtitle: nil) {
            if data.weekdays.allSatisfy({ $0.averageSeconds == 0 }) {
                placeholder("Not enough data yet")
            } else {
                Chart(data.weekdays) { d in
                    BarMark(x: .value("Day", weekdayName(d.weekday)),
                            y: .value("Avg h", d.averageSeconds / 3600))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                }
                .chartYAxis { AxisMarks(position: .trailing) }
                .frame(height: 92)
            }
        }
    }

    // MARK: - Where time went

    /// Rows are BARS, proportional to the largest in the range — the Mac's breakdown is a bar chart,
    /// and dot + name + number alone made the same data much harder to compare at a glance.
    ///
    /// Scope reads as three text links on the header row, as on the Mac, rather than a segmented
    /// control taking a line of its own.
    private var whereTimeWent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Where time went").font(Theme.sectionHeader)
                Spacer()
                ForEach(Array(BreakdownScope.allCases.enumerated()), id: \.element.id) { i, sc in
                    if i > 0 { Text("·").font(Theme.captionSmall).foregroundStyle(.tertiary) }
                    Button { scope = sc } label: {
                        Text(sc.rawValue)
                            .font(.system(size: 11, weight: scope == sc ? .semibold : .regular))
                            .foregroundStyle(scope == sc ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(spacing: 4) {
                if whereRows.isEmpty {
                    placeholder("Nothing tracked in this range")
                } else {
                    let maxSeconds = whereRows.map(\.seconds).max() ?? 1
                    ForEach(whereRows) { row in
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: row.colorHex)).frame(width: 7, height: 7)
                            Text(row.name)
                                .font(.system(size: 11)).lineLimit(1)
                                .frame(width: 92, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.track)
                                    Capsule().fill(Color(hex: row.colorHex))
                                        .frame(width: max(2, geo.size.width
                                                          * CGFloat(row.seconds / maxSeconds)))
                                }
                            }
                            .frame(height: 9)
                            Text(Format.compact(row.seconds))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                    if scope == .tags {
                        Text("tags overlap, so these don't sum to the total")
                            .font(Theme.captionSmall).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
        }
    }

    private struct WhereRow: Identifiable {
        let id: Int64; let name: String; let colorHex: String; let seconds: TimeInterval
    }

    private var whereRows: [WhereRow] {
        switch scope {
        case .tasks:
            return data.taskTotals.filter { $0.seconds > 0 }.sorted { $0.seconds > $1.seconds }
                .map { WhereRow(id: $0.project.id, name: $0.project.name,
                                colorHex: model.colorHex(for: $0.project), seconds: $0.seconds) }
        case .projects:
            return data.groupTotals.filter { $0.seconds > 0 }.sorted { $0.seconds > $1.seconds }
                .map { WhereRow(id: $0.project?.id ?? -1, name: $0.project?.name ?? "Inbox",
                                colorHex: $0.project?.colorHex ?? "#8E8E93", seconds: $0.seconds) }
        case .tags:
            return data.tagTotals.filter { $0.seconds > 0 }.sorted { $0.seconds > $1.seconds }
                .map { WhereRow(id: $0.tag?.id ?? -1, name: $0.name,
                                colorHex: $0.colorHex, seconds: $0.seconds) }
        }
    }

    // MARK: - Sessions

    private var sessionList: some View {
        section("Sessions", subtitle: "\(data.sessions.count) blocks") {
            if data.sessions.isEmpty {
                placeholder("No sessions on this day")
            } else {
                VStack(spacing: 0) {
                    ForEach(data.sessions, id: \.id) { s in
                        HStack(spacing: 7) {
                            Circle().fill(Color(hex: colorHex(for: s.projectID)))
                                .frame(width: 7, height: 7)
                            Text(model.task(id: s.projectID)?.name ?? "(deleted task)")
                                .font(Theme.caption).lineLimit(1)
                            if let id = s.deviceID, let label = model.deviceLabels[id],
                               model.knownDevices.count > 1 {
                                Text(label).font(Theme.captionSmall).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            // WHEN it happened, not just how long — a list of durations can't be
                            // matched up against the timeline above it.
                            Text(sessionClock(s))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(Format.compact(s.seconds()))
                                .font(.system(size: 11, design: .monospaced))
                            Button {
                                delete(s)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                        if s.id != data.sessions.last?.id { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - Shell

    private func section<C: View>(_ title: String, subtitle: String?,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title).font(Theme.sectionHeader)
                if let subtitle {
                    Text(subtitle).font(Theme.captionSmall).foregroundStyle(.tertiary)
                }
            }
            // The VStack is load-bearing. Applying `.background` straight to `content()` applies it
            // to a TupleView, and SwiftUI distributes such modifiers across EACH child — so the Day
            // timeline rendered as five separate cards (strip, axis, totals, legend, hint) instead of
            // one. Wrapping first makes it a single view to decorate.
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(Theme.caption).foregroundStyle(.secondary)
    }

    private func colorHex(for taskID: Int64) -> String {
        model.task(id: taskID).map(model.colorHex(for:)) ?? "#8E8E93"
    }

    private func hourLabel(_ hour: Double) -> String {
        String(format: "%02d:%02d", Int(hour), Int((hour - Double(Int(hour))) * 60))
    }

    private func weekdayName(_ weekday: Int) -> String {
        let s = Calendar.current.veryShortWeekdaySymbols
        return s[max(0, min(s.count - 1, weekday - 1))]
    }

    private func delete(_ session: Interval) {
        guard let store = model.storeIfLoaded else { return }
        _ = try? store.deleteInterval(id: session.id)
        model.reload()
        rebuild()
    }

    // MARK: - Data

    private func rebuild() {
        guard let store = model.storeIfLoaded else { return }
        let now = Date()
        earliest = try? store.earliestIntervalStart()
        let all = (try? store.intervals()) ?? []
        // The threshold now comes from the SHARED settings, so Focus % agrees with the Mac.
        let deep = model.settings.deepBlockSeconds

        var d = MetricsData()
        d.summary = Aggregations.summary(intervals: all, range: range, deepThreshold: deep, now: now)
        d.buckets = Aggregations.buckets(intervals: all, range: range, deepThreshold: deep, now: now)
        // Anchored to the RANGE's day, not `now`, so the ‹ › stepper actually moves the timeline.
        // Overlap-only lanes: `assignLanes` gives each of three devices its own row even when their
        // blocks never overlap in time, which reads as concurrency that didn't happen and spends three
        // rows saying what one says. Attribution still shows in the per-device totals and the tap
        // inspector.
        d.segments = Aggregations.assignLanesByOverlap(
            Aggregations.daySegments(intervals: all, day: range.start, now: now))
        d.taskTotals = Aggregations.rangeTotals(projects: model.allTasks, intervals: all,
                                                range: range, now: now)
        d.groupTotals = Aggregations.rollUp(totals: d.taskTotals, taskProjects: model.groups)
        let tagIDsByTask = (try? store.effectiveTagIDsByTask()) ?? [:]
        d.tagTotals = Aggregations.tagTotals(tags: model.allTags, intervals: all,
                                             tagIDsByTask: tagIDsByTask, range: range, now: now)
        d.weekdays = Aggregations.weekdayAverages(intervals: all, range: range, now: now)
        d.sessions = all
            .filter { ($0.end ?? now) > range.start && $0.start < range.end }
            .sorted { $0.start > $1.start }
            .prefix(40).map { $0 }
        d.budgets = BudgetRows.build(
            targets: (try? store.listTargets()) ?? [], tasks: model.allTasks,
            groups: model.groups, tags: model.allTags, tagIDsByTask: tagIDsByTask,
            intervals: all, viewedRange: range, now: now)
        d.strip = buildStrip(intervals: all, deep: deep, now: now)
        data = d
    }

    /// The card strip: this period and the ones before it.
    ///
    /// Built with `DateRange.stepped`, so week and month boundaries come from `Calendar` rather than
    /// from multiplying by 7 or 30 — the strip has to agree with the range the rest of the screen uses,
    /// and calendar periods are not fixed lengths.
    ///
    /// Anchored at the PRESENT period rather than at the selection, so the strip doesn't slide out from
    /// under you when you tap; the window then extends backwards far enough to keep an older selection
    /// visible, capped so browsing a year back doesn't build hundreds of cards.
    private func buildStrip(intervals: [Interval], deep: TimeInterval, now: Date) -> [PeriodCard] {
        guard range.unit != .all else { return [] }
        let present = DateRange.resolve(unit: range.unit, anchor: now, earliest: earliest)

        var windows: [DateRange] = []
        var cursor = present
        // 14 covers a fortnight of days or a year of months on screen; the cap bounds the walk back to
        // an old selection.
        for step in 0..<60 {
            windows.append(cursor)
            let reachedSelection = cursor.start <= range.start
            if step >= 13 && reachedSelection { break }
            if let earliest, cursor.start <= earliest, step >= 13 { break }
            let next = cursor.stepped(by: -1, earliest: earliest)
            // `stepped` clamps rather than throwing, so an unmoving cursor is the end of the road.
            guard next.start < cursor.start else { break }
            cursor = next
        }

        // Oldest first: the strip reads left-to-right into the present, and scrolls to the right end.
        var cards = windows.reversed().map { window in
            let s = Aggregations.summary(intervals: intervals, range: window,
                                         deepThreshold: deep, now: now)
            return PeriodCard(range: window, totalSeconds: s.totalSeconds,
                              deepSeconds: s.deepSeconds)
        }
        // Scale the rings to the busiest period on the strip, so the ring and the number inside it
        // agree. Done after the fact because it's the one figure that depends on the other cards.
        let busiest = cards.map(\.totalSeconds).max() ?? 0
        if busiest > 0 {
            for i in cards.indices { cards[i].fraction = cards[i].totalSeconds / busiest }
        }
        return cards
    }
}

/// A wrapping row, for the timeline legend — a plain `HStack` clips once there are more than a few
/// tasks in a day, and `LazyVGrid` would force a column grid onto labels of very different widths.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension MetricsScreen {
    /// `9:05–10:20` for a closed session, `14:32–now` for the running one.
    ///
    /// A `DateFormatter` per row would be wasteful; one static formatter is reused.
    fileprivate func sessionClock(_ session: Interval) -> String {
        let f = MetricsScreen.clockFormatter
        let start = f.string(from: session.start)
        guard let end = session.end else { return "\(start)–now" }
        return "\(start)–\(f.string(from: end))"
    }

    fileprivate static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
