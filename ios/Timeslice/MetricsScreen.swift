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
            .onAppear(perform: rebuild)
            .onChange(of: range) { _, _ in rebuild() }
            .onChange(of: model.running?.projectID) { _, _ in rebuild() }
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

    private var tiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                  spacing: 8) {
            tile("Tracked", Format.compact(data.summary.totalSeconds),
                 "\(Int((usedRatio * 100).rounded()))% of \(Int(model.settings.wakingHours))h awake",
                 .primary)
            tile("Focus", "\(Int((data.summary.focusRatio * 100).rounded()))%",
                 "\(Format.compact(data.summary.deepSeconds)) in blocks ≥\(model.settings.deepBlockMinutes)m",
                 .primary)
            tile("Switches", "\(data.summary.switches)", switchesCaption, .primary)
            tile("Longest", Format.compact(data.summary.longestSessionSeconds),
                 "avg/day \(Format.compact(data.summary.avgPerActiveDay))", .primary)
        }
    }

    /// Tracked against waking hours — the Mac's "used" figure, which is why Awake hours is a setting.
    private var usedRatio: Double {
        let days = max(1, Double(data.summary.activeDays))
        let available = model.settings.wakingSeconds * days
        return available > 0 ? min(1, data.summary.totalSeconds / available) : 0
    }

    private var switchesCaption: String {
        guard data.summary.activeDays > 0 else { return "—" }
        return String(format: "%.1f/day", Double(data.summary.switches) / Double(data.summary.activeDays))
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
            section("Budgets", subtitle: "each against its own period") {
                VStack(spacing: 8) {
                    ForEach(data.budgets) { row in budgetRow(row) }
                }
            }
        }
    }

    private func budgetRow(_ row: BudgetRows.Row) -> some View {
        let p = row.progress
        let tint = Theme.verdict(kind(p.verdict))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: row.colorHex)).frame(width: 7, height: 7)
                Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Text("\(p.target.direction.symbol) \(BudgetRows.duration(p.target.seconds)) / \(p.target.period.rawValue)")
                    .font(Theme.captionSmall).foregroundStyle(.secondary)
            }
            // The bar carries the percentage inside it; no verdict icon. The arrows were mine, not
            // the Mac's — colour plus the number already says whether it's in trouble.
            InlineBar(fraction: min(max(p.percent / 100, 0), 1),
                      label: "\(BudgetRows.duration(p.actualSeconds)) · \(Int(p.percent.rounded()))%",
                      fill: tint, height: 12)
            HStack(spacing: 6) {
                Text(verdictText(p)).font(Theme.captionSmall).foregroundStyle(tint)
                Spacer()
                Sparkline(values: row.sparkline, tint: Color(hex: row.colorHex))
                    .frame(width: 68, height: 13)
            }
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

    private func verdictText(_ p: TargetProgress) -> String {
        switch p.verdict {
        case .over: return "over by \(BudgetRows.duration(abs(p.deltaSeconds)))"
        case .behind:
            if let need = p.requiredPerDaySeconds, need > 0 {
                return "behind · needs \(BudgetRows.duration(need))/day"
            }
            return "behind"
        case .onPace: return "on pace"
        case .met: return "met"
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

    private var hourAxis: some View {
        HStack(spacing: 0) {
            ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                Text("\(h)")
                    .font(Theme.captionSmall).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: h == 0 ? .leading : (h == 24 ? .trailing : .center))
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

    private var whereTimeWent: some View {
        section("Where time went", subtitle: scope == .tags ? "tags overlap; these don't sum" : nil) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(BreakdownScope.allCases) { s in
                        Button { scope = s } label: {
                            Text(s.rawValue)
                                .font(.system(size: 11, weight: scope == s ? .semibold : .regular))
                                .foregroundStyle(scope == s ? Color.accentColor : Color.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(scope == s ? Theme.selection : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                if whereRows.isEmpty {
                    placeholder("Nothing tracked in this range")
                } else {
                    ForEach(whereRows) { row in
                        HStack(spacing: 7) {
                            Circle().fill(Color(hex: row.colorHex)).frame(width: 7, height: 7)
                            Text(row.name).font(Theme.caption).lineLimit(1)
                            Spacer()
                            Text(Format.compact(row.seconds))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
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
        section("Sessions", subtitle: "swipe to delete") {
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
