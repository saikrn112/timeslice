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
    }

    private var isDay: Bool { range.unit == .day }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rangeBar
                    tiles
                    budgets
                    if isDay { dayTimeline } else { hoursChart }
                    whereTimeWent
                    if isDay { sessionList } else { weekdayPattern }
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

    /// The Mac's range bar: capsule pills, a ‹ label › stepper, and "Today".
    ///
    /// The stepper is what makes any day but today reachable — without it the timeline could only
    /// ever show `now`'s day, which is also how a whole day of seeded data appeared to be missing
    /// during testing.
    private var rangeBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                ForEach(RangeUnit.allCases, id: \.self) { u in
                    let selected = range.unit == u
                    Button {
                        // Looking at the CURRENT period keeps you current when switching units;
                        // only a deliberately historical view carries its anchor over.
                        let anchor = range.isCurrent() ? Date() : min(range.start, Date())
                        range = DateRange.resolve(unit: u, anchor: anchor, earliest: earliest)
                    } label: {
                        Text(u.rawValue)
                            .font(.system(size: 11, weight: selected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                            .frame(minWidth: 24)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(
                                selected ? Color.accentColor : Color.secondary.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .disabled(range.unit == .all)
                Text(range.label())
                    .font(.system(size: 12, design: .rounded)).fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .disabled(range.unit == .all || atPresentEdge)
                Button("Today") {
                    range = DateRange.resolve(unit: range.unit, anchor: Date(), earliest: earliest)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(range.isCurrent() ? Color.secondary : Color.accentColor)
                .disabled(range.isCurrent())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
    }

    /// True when stepping forward would move past now — the future is never browsable.
    private var atPresentEdge: Bool {
        range.stepped(by: 1, earliest: earliest).start > Date()
    }

    private func step(_ delta: Int) {
        let next = range.stepped(by: delta, earliest: earliest)
        guard next.start <= Date() else { return }
        range = next
    }

    // MARK: - Tiles

    /// Four tiles, tinted per metric exactly as the Mac does — Focus purple, Switches orange,
    /// Longest teal, Best day blue. They were all `.primary` before, which is the main reason the
    /// screen read as a generic iOS list rather than as Timeslice.
    private var tiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                  spacing: 8) {
            trackedTile
            tile("Focus", percent(data.summary.focusRatio),
                 "≥\(model.settings.deepBlockMinutes)m blocks", .purple)
            if isDay {
                tile("Switches", "\(data.summary.switches)", "this day", .orange)
                tile("Longest", Format.compact(data.summary.longestSessionSeconds),
                     "session", .teal)
            } else {
                tile("Avg/day", hoursOnly(data.summary.avgPerActiveDay),
                     "active days only", .teal)
                tile("Best day", hoursOnly(data.summary.bestDaySeconds), "in range", .blue)
            }
        }
    }

    /// `7.8h / 16h` with a bar and the percentage beside it — the Mac's goal tile.
    ///
    /// The denominator counts every CALENDAR day in the range, including ones with nothing tracked:
    /// a day you recorded nothing is exactly when the gap should be widest, and counting only active
    /// days would hide that by shrinking the denominator to match.
    private var trackedTile: some View {
        let days = max(1, (range.end.timeIntervalSince(range.start) / 86_400).rounded())
        let awake = model.settings.wakingSeconds * days
        let ratio = awake > 0 ? data.summary.totalSeconds / awake : 0
        return VStack(alignment: .leading, spacing: 3) {
            Text("Tracked").font(Theme.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(hoursOnly(data.summary.totalSeconds)).font(Theme.tileValue)
                Text("/ \(hoursOnly(awake))").font(Theme.captionSmall).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(2, geo.size.width * min(1, ratio)))
                    }
                }
                .frame(height: 4)
                Text(percent(ratio)).font(Theme.captionSmall).foregroundStyle(.tertiary)
            }
            .frame(height: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
    }

    private func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }

    /// Hours, dropping the decimal once the number is big enough not to need it — the Mac's
    /// `hoursOnly`. Budgets and tiles are talked about in hours, never "1d 16h".
    private func hoursOnly(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        return h >= 10 ? String(format: "%.0fh", h) : String(format: "%.1fh", h)
    }

    private func tile(_ label: String, _ value: String, _ caption: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            Text(value).font(Theme.tileValue).foregroundStyle(tint)
            Text(caption).font(Theme.captionSmall).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
    }

    // MARK: - Budgets (a section here, as on the Mac)

    @ViewBuilder
    private var budgets: some View {
        if !data.budgets.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("Budgets").font(Theme.sectionHeader)
                    Text("each against its own period")
                        .font(Theme.captionSmall).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Edit") { model.showingSettings = true }
                        .font(Theme.captionSmall)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
                VStack(spacing: 5) {
                    ForEach(data.budgets) { row in budgetRow(row) }
                }
                .padding(Theme.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
            }
        }
    }

    /// Two bars per budget, as the Mac has:
    ///
    /// - **goal** — progress against the budget's OWN period. A weekly budget always reads "this
    ///   week", whatever the filter is set to, which is what makes the verdict meaningful.
    /// - **this &lt;range&gt;** — the same target pro-rated onto the range being VIEWED, so the row
    ///   re-reads at whatever zoom the filter is on. `TargetProgress.rangePercent` already computes
    ///   it; dropping this bar earlier lost the only figure that responds to the filter.
    ///
    /// Two lines rather than the Mac's one: at phone width a single line can't hold two bars plus
    /// both actual/target pairs. Each bar carries its own actual and percentage inside it, which is
    /// what `InlineBar` is for, so nothing is lost — only rearranged.
    private func budgetRow(_ row: BudgetRows.Row) -> some View {
        let p = row.progress
        let tint = Theme.verdict(kind(p.verdict))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(Color(hex: row.colorHex)).frame(width: 7, height: 7)
                Text(p.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
                // The period sits immediately after the name — it's part of reading "timeslice, at
                // least 60h, per month". Exiled to the far right it floated above the trend column
                // and read as unrelated.
                Text("\(p.target.direction.symbol) \(BudgetRows.duration(p.target.seconds))"
                     + " / \(shortPeriod(p.target.period))")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer(minLength: 2)
                Sparkline(values: row.sparkline, tint: Color(hex: row.colorHex))
                    .frame(width: 40, height: 10)
            }
            HStack(spacing: 5) {
                barCell("goal", actual: p.actualSeconds, fraction: p.percent / 100, tint: tint)
                barCell(rangeWord, actual: p.rangeSeconds, fraction: p.rangePercent / 100,
                        // The range bar is informational rather than a verdict — it answers "how much
                        // of this window", so it takes the subject's colour, not the pass/fail tint.
                        tint: Color(hex: row.colorHex))
            }
        }
    }

    /// Only the PERCENTAGE goes inside the bar; the actual figure rides on the caption line above it.
    ///
    /// Putting "42h 14m · 68%" inside a ~180pt bar overflowed it — the percentage spilled past the
    /// fill's right edge. The Mac keeps the bar's interior to the percentage alone for the same
    /// reason, with the durations outside it.
    private func barCell(_ caption: String, actual: TimeInterval, fraction: Double,
                         tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(caption).font(.system(size: 8)).foregroundStyle(.quaternary)
                Text(BudgetRows.duration(actual))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            InlineBar(fraction: min(max(fraction, 0), 1),
                      label: percent(fraction), fill: tint, height: 11)
        }
    }

    /// Names the second bar after the filter, so it's obvious which control re-scales it.
    private var rangeWord: String {
        switch range.unit {
        case .day: return "this day"
        case .week: return "this week"
        case .month: return "this month"
        case .sixMonths: return "6 months"
        case .year: return "this year"
        case .all: return "all time"
        }
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
                let lanes = max(1, Aggregations.laneCount(data.segments))
                let devices = Aggregations.orderedDevices(data.segments)
                HStack(alignment: .top, spacing: 5) {
                    // Device names down the left edge, one per lane — the Mac's arrangement. Only
                    // shown when more than one machine contributed, otherwise it's a column of one
                    // label restating the obvious.
                    if devices.count > 1 {
                        VStack(spacing: 2) {
                            ForEach(0..<lanes, id: \.self) { lane in
                                Text(deviceName(devices, lane))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    // Two lines rather than one: "MacBook Air" truncated to
                                    // "MacBoo…" at a single line, which defeats the point of
                                    // labelling the lane at all.
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                                    .minimumScaleFactor(0.8)
                                    .frame(height: laneHeight(lanes), alignment: .center)
                            }
                        }
                        .frame(width: 58, alignment: .trailing)
                    }
                    timelineStrip(lanes: lanes)
                }
                hourAxis
                timelineFooter(Aggregations.orderedDevices(data.segments))
                if let seg = inspected { inspector(seg) } else {
                    Text("Tap a block to inspect it.")
                        .font(Theme.captionSmall).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var timelineSubtitle: String? {
        let devices = Aggregations.orderedDevices(data.segments)
        guard devices.count > 1 else { return nil }
        return "\(devices.count) devices"
    }

    private func laneHeight(_ lanes: Int) -> CGFloat {
        lanes > 1 ? max(16, 74 / CGFloat(lanes)) : 40
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
            content()
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
        d.segments = Aggregations.assignLanes(
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
        data = d
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
