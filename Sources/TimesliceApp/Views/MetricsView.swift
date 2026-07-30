import SwiftUI
import Charts
import TimesliceCore

/// Metrics built around the user's goals: hit ~10h/day, and work in deep focused blocks.
/// - Headline tiles: today vs goal, focus %, switches, longest session.
/// - Daily hours vs the goal line (the centerpiece).
/// - Focus % trend over the same window.
/// - Time-per-task ranking (Today / Week / All).
struct MetricsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var engine: TimerEngine
    @ObservedObject var settings: Settings

    @State private var dayStats: [DayStat] = []
    @State private var switchesToday: Int = 0
    @State private var longestTodaySeconds: TimeInterval = 0
    @State private var rankScope: RankScope = .today
    @State private var timelineDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var daySegments: [DaySegment] = []
    @State private var month: Date = Calendar.current.startOfDay(for: Date())
    @State private var monthStats: [DayStat] = []

    enum RankScope: String, CaseIterable, Identifiable {
        case today = "Today", week = "Week", all = "All"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                tiles
                // The two metrics the user cares about most, featured first.
                dayTimeline
                dailyHoursChart
                focusTrendChart
                perTaskRanking
            }
            .padding(18)
        }
        .onAppear(perform: recompute)
        .onReceive(NotificationCenter.default.publisher(for: TimesliceNotifications.dataDidChange)) { _ in recompute() }
        .onReceive(settings.objectWillChange) { _ in DispatchQueue.main.async { recompute() } }
    }

    // MARK: - Derived values

    private var todayStat: DayStat? {
        let today = Calendar.current.startOfDay(for: Date())
        return dayStats.first { Calendar.current.isDate($0.day, inSameDayAs: today) }
    }
    private var todaySeconds: TimeInterval {
        (todayStat?.totalSeconds ?? 0) + engine.elapsed
    }
    private var weekStats: [DayStat] { Array(dayStats.suffix(7)) }
    private var weekTotalSeconds: TimeInterval { weekStats.reduce(0) { $0 + $1.totalSeconds } }

    // MARK: - Tiles

    private var tiles: some View {
        HStack(spacing: 12) {
            goalTile
            tile("Focus", value: percent(todayStat?.focusRatio ?? 0),
                 caption: "≥\(settings.deepBlockMinutes)m blocks", tint: .purple)
            tile("Switches", value: "\(switchesToday)", caption: "today", tint: .orange)
            tile("Longest", value: Format.duration(longestTodaySeconds), caption: "session today", tint: .teal)
            tile("This week", value: hours(weekTotalSeconds),
                 caption: "avg \(hours(weekTotalSeconds / 7))/day", tint: .blue)
        }
    }

    private var goalTile: some View {
        let goal = settings.dailyGoalSeconds
        let frac = goal > 0 ? min(1, todaySeconds / goal) : 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("Today").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hours(todaySeconds)).font(.system(.title2, design: .rounded)).fontWeight(.semibold)
                Text("/ \(hours(goal))").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: frac)
                .tint(frac >= 1 ? .green : .accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func tile(_ label: String, value: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded)).fontWeight(.semibold).foregroundStyle(tint)
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Day timeline (0–24h)

    private var dayTimeline: some View {
        section("Day timeline", subtitle: timelineDayLabel, trailing: {
            HStack(spacing: 6) {
                Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Button("Today") { timelineDay = Calendar.current.startOfDay(for: Date()); recompute() }
                    .buttonStyle(.link)
                    .disabled(Calendar.current.isDateInToday(timelineDay))
                Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(Calendar.current.isDateInToday(timelineDay))
            }
        }) {
            if daySegments.isEmpty {
                placeholder("Nothing tracked on this day")
            } else {
                Chart(daySegments) { seg in
                    BarMark(
                        xStart: .value("From", seg.startHour),
                        xEnd: .value("To", seg.endHour),
                        y: .value("Day", ""),
                        height: .fixed(64)
                    )
                    .foregroundStyle(colorForProject(seg.projectID))
                    .cornerRadius(3)
                }
                .chartXScale(domain: 0...24)
                .chartXAxis {
                    AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21, 24]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(hourLabel(value.as(Int.self) ?? 0)) }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 96)

                timelineLegend
            }
        }
    }

    private var timelineLegend: some View {
        // Only the tasks that actually appear on this day.
        let ids = Array(Set(daySegments.map(\.projectID)))
        let projects = ids.compactMap { id in appState.projects.first { $0.id == id }
            ?? (try? appState.storeForEditing.listProjects(includeArchived: true))?.first { $0.id == id } }
        return FlowLegend(items: projects.map { ($0.name, Color(hex: $0.colorHex)) })
    }

    private func colorForProject(_ id: Int64) -> Color {
        if let p = appState.projects.first(where: { $0.id == id }) { return Color(hex: p.colorHex) }
        let all = (try? appState.storeForEditing.listProjects(includeArchived: true)) ?? []
        return Color(hex: all.first { $0.id == id }?.colorHex ?? "#8E8E93")
    }

    private var timelineDayLabel: String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        return Calendar.current.isDateInToday(timelineDay) ? "Today" : f.string(from: timelineDay)
    }

    private func hourLabel(_ h: Int) -> String {
        switch h {
        case 0: return "12a"
        case 12: return "12p"
        case 24: return ""
        case let x where x < 12: return "\(x)a"
        case let x: return "\(x - 12)p"
        }
    }

    private func shiftDay(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: delta, to: timelineDay) {
            let today = Calendar.current.startOfDay(for: Date())
            timelineDay = min(d, today)
            recompute()
        }
    }

    // MARK: - Hours per day (full month, past + future)

    private var dailyHoursChart: some View {
        section("Hours per day", subtitle: "goal \(hours(settings.dailyGoalSeconds))/day", trailing: {
            HStack(spacing: 6) {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(monthLabel).font(.subheadline).frame(minWidth: 92)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
            }
        }) {
            Chart {
                ForEach(monthStats) { stat in
                    BarMark(
                        x: .value("Day", stat.day, unit: .day),
                        y: .value("Hours", stat.totalSeconds / 3600),
                        width: .fixed(16)
                    )
                    .foregroundStyle(stat.totalSeconds >= settings.dailyGoalSeconds ? Color.green : Color.accentColor)
                    .cornerRadius(2)
                }
                RuleMark(y: .value("Goal", settings.dailyGoalHours))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("goal \(Int(settings.dailyGoalHours))h").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .frame(height: 180)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { value in
                    AxisValueLabel(format: .dateTime.day(), centered: true)
                        .font(.system(size: 8))
                }
            }
            .chartYAxisLabel("hours")
        }
    }

    private var monthLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"
        return f.string(from: month)
    }

    private func shiftMonth(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: delta, to: month) {
            month = d
            recompute()
        }
    }

    // MARK: - Focus trend

    private var focusTrendChart: some View {
        section("Focus %", subtitle: "share of each day in ≥\(settings.deepBlockMinutes)m blocks", trailing: {
            Text(monthLabel).font(.subheadline).foregroundStyle(.secondary)
        }) {
            Chart(monthStats) { stat in
                BarMark(
                    x: .value("Day", stat.day, unit: .day),
                    y: .value("Focus", stat.focusRatio * 100),
                    width: .fixed(16)
                )
                .foregroundStyle(Color.purple.gradient)
                .cornerRadius(2)
            }
            .frame(height: 150)
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisValueLabel("\($0.as(Int.self) ?? 0)%") } }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { _ in
                    AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                }
            }
        }
    }

    // MARK: - Per-task ranking

    private var perTaskRanking: some View {
        section("Where time went", subtitle: nil, trailing: {
            Picker("", selection: $rankScope) {
                ForEach(RankScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }) {
            let totals = rankedTotals()
            if totals.isEmpty {
                placeholder("No time tracked in this range yet")
            } else {
                // Simple labeled rows with proportional fill bars — reads cleaner than a
                // Swift Chart when there are only a few tasks (no giant auto-sized bar).
                let maxSeconds = totals.map(\.seconds).max() ?? 1
                VStack(spacing: 8) {
                    ForEach(totals) { total in
                        rankRow(total, fraction: maxSeconds > 0 ? total.seconds / maxSeconds : 0)
                    }
                }
            }
        }
    }

    private func rankRow(_ total: ProjectTotal, fraction: Double) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: total.project.colorHex)).frame(width: 9, height: 9)
            Text(total.project.name).font(.callout).lineLimit(1).frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(Color(hex: total.project.colorHex))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 14)
            Text(Format.duration(total.seconds))
                .font(.system(.caption, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
        }
    }

    private func rankedTotals() -> [ProjectTotal] {
        let store = appState.storeForEditing
        // Include archived tasks: they were active historically and their time still counts here.
        let allProjects = (try? store.listProjects(includeArchived: true)) ?? []
        let now = Date()
        let base: [ProjectTotal]
        switch rankScope {
        case .today:
            let intervals = (try? store.intervals())?.filter { !$0.isRunning } ?? []
            base = Aggregations.todayTotals(projects: allProjects, intervals: intervals, now: now)
        case .all:
            let intervals = (try? store.intervals())?.filter { !$0.isRunning } ?? []
            base = Aggregations.allTimeTotals(projects: allProjects, intervals: intervals, now: now)
        case .week:
            let from = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now))
            let intervals = (try? store.intervals(from: from))?.filter { !$0.isRunning } ?? []
            base = Aggregations.allTimeTotals(projects: allProjects, intervals: intervals, now: now)
        }
        return base.filter { $0.seconds > 0 }.sorted { $0.seconds > $1.seconds }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, subtitle: String?, @ViewBuilder _ content: () -> Content) -> some View {
        section(title, subtitle: subtitle, trailing: { EmptyView() }, content)
    }

    private func section<Trailing: View, Content: View>(
        _ title: String, subtitle: String?,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
    }

    // MARK: - Formatting helpers

    private func hours(_ seconds: TimeInterval) -> String {
        String(format: "%.1fh", seconds / 3600)
    }
    private func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    private func recompute() {
        let store = appState.storeForEditing
        let all = (try? store.intervals()) ?? []
        // Recent days — feeds the Today and This-week tiles (charts use monthStats instead).
        dayStats = Aggregations.dayStats(
            intervals: all, days: 14,
            deepThreshold: settings.deepBlockSeconds
        )
        daySegments = Aggregations.daySegments(intervals: all, day: timelineDay)
        monthStats = Aggregations.monthStats(intervals: all, month: month, deepThreshold: settings.deepBlockSeconds)
        let switches = Aggregations.switchesPerDay(intervals: all.filter { !$0.isRunning })
        switchesToday = switches.first { Calendar.current.isDateInToday($0.day) }?.switches ?? 0
        // Longest single session today.
        let today = Calendar.current.startOfDay(for: Date())
        longestTodaySeconds = all
            .filter { !$0.isRunning && Calendar.current.isDate($0.start, inSameDayAs: today) }
            .map { $0.seconds() }
            .max() ?? 0
    }
}

/// A simple wrapping legend: colored swatch + label chips that flow onto multiple lines.
struct FlowLegend: View {
    let items: [(String, Color)]

    var body: some View {
        FlexibleWrap(items.map { $0.0 }, spacing: 10, rowSpacing: 6) { name in
            let color = items.first { $0.0 == name }?.1 ?? .gray
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Minimal flow layout that wraps its children to the next line when they run out of width.
struct FlexibleWrap<Item: Hashable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let rowSpacing: CGFloat
    let content: (Item) -> Content

    init(_ items: [Item], spacing: CGFloat = 8, rowSpacing: CGFloat = 6, @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing, rowSpacing: rowSpacing) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

/// A basic Layout that arranges subviews left-to-right, wrapping to new rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + rowSpacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + rowSpacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
