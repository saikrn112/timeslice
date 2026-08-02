import SwiftUI
import Charts
import TimesliceCore

/// Metrics, driven by one global range filter at the top. Tiles and charts all read the same
/// resolved range, and the chart set adapts to it (a 0–24h timeline only makes sense for a day).
struct MetricsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var engine: TimerEngine
    @ObservedObject var settings: Settings

    // Screenshot runs open on last month so the ranged charts (hours-per-day, weekday pattern)
    // are in frame over a fully-seeded month; the day view is the useful default otherwise.
    @State private var range = DateRange.resolve(
        unit: DemoData.isScreenshotRun ? .month : .day,
        anchor: DemoData.isScreenshotRun
            ? Date().addingTimeInterval(-20 * 86_400) : Date())
    @State private var earliest: Date?

    // Derived data for the current range.
    @State private var summary: RangeSummary?
    @State private var buckets: [Bucket] = []
    @State private var daySegments: [DaySegment] = []
    @State private var rankedTotals: [ProjectTotal] = []
    @State private var weekdayAvgs: [WeekdayAverage] = []

    // Day-timeline hover: cursor position (hours 0–24) and the block it resolves to.
    @State private var hoverHour: Double?
    @State private var hoveredSegment: DaySegment?

    /// Project lookup + the timeline legend, both computed once per recompute so hovering can't
    /// trigger DB reads or reshuffle the labels.
    @State private var projectLookup: [Int64: Project] = [:]
    @State private var legendItems: [(String, Color)] = []

    /// Bucket under the cursor on the hours / focus charts.
    @State private var hoveredBucket: Bucket?
    /// Weekday index (0=Sun) under the cursor on the weekday-pattern chart.
    @State private var hoveredWeekday: Int?

    private var isDay: Bool { range.unit == .day }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                RangeFilterBar(range: $range, earliest: earliest)
                tiles
                if isDay {
                    // On a single day the hours chart would be one bar restating the tiles —
                    // the timeline says more.
                    dayTimeline
                } else {
                    // Hours is the primary "am I putting in the time" read.
                    hoursChart
                }
                whereTimeWent
                // Secondary detail below the breakdown.
                if isDay { sessionList } else { weekdayPattern }
            }
            .padding(18)
        }
        .onAppear { syncToNowIfStale(); recompute() }
        .onChange(of: range) { _, _ in recompute() }
        .onReceive(NotificationCenter.default.publisher(for: TimesliceNotifications.dataDidChange)) { _ in recompute() }
        .onReceive(settings.objectWillChange) { _ in DispatchQueue.main.async { recompute() } }
        // The app can run for days; re-anchor to the real "today" on wake so the range never
        // silently points at a stale date.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            syncToNowIfStale(); recompute()
        }
    }

    /// If the range was "current" but the clock has since rolled past it, re-anchor to now.
    private func syncToNowIfStale() {
        // A screenshot run deliberately sits on a past month; don't drag it back to today.
        if DemoData.isScreenshotRun { return }
        if !range.isCurrent() && range.stepped(by: 1, earliest: earliest).start <= Date() {
            // Only auto-advance when we're sitting at what *was* the present edge.
            let advanced = DateRange.resolve(unit: range.unit, anchor: Date(), earliest: earliest)
            if advanced.start > range.start { range = advanced }
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        HStack(spacing: 12) {
            goalTile
            tile("Focus", value: percent(summary?.focusRatio ?? 0),
                 caption: "≥\(settings.deepBlockMinutes)m blocks", tint: .purple)
            if isDay {
                tile("Switches", value: "\(summary?.switches ?? 0)", caption: "this day", tint: .orange)
                tile("Longest", value: Format.duration(summary?.longestSessionSeconds ?? 0),
                     caption: "session", tint: .teal)
            } else {
                tile("On goal", value: "\(summary?.daysOnGoal ?? 0)/\(summary?.activeDays ?? 0)",
                     caption: "active days", tint: .green)
                tile("Avg/day", value: hours(summary?.avgPerActiveDay ?? 0),
                     caption: "active days only", tint: .teal)
                tile("Best day", value: hours(summary?.bestDaySeconds ?? 0), caption: "in range", tint: .blue)
            }
        }
    }

    private var goalTile: some View {
        // For a single day, compare against the daily goal; for longer ranges, against goal×active days.
        let total = (summary?.totalSeconds ?? 0) + liveExtra
        let target = isDay
            ? settings.dailyGoalSeconds
            : settings.dailyGoalSeconds * Double(max(1, summary?.activeDays ?? 1))
        let frac = target > 0 ? min(1, total / target) : 0
        return VStack(alignment: .leading, spacing: 6) {
            Text(isDay ? "Tracked" : "Total").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hours(total)).font(.system(.title2, design: .rounded)).fontWeight(.semibold)
                Text("/ \(hours(target))").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: frac).tint(frac >= 1 ? .green : .accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// Live seconds for a running task, but only when the range covers now.
    private var liveExtra: TimeInterval {
        range.isCurrent() ? engine.clock.elapsed : 0
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

    // MARK: - Day timeline (day range only)

    private var dayTimeline: some View {
        section("Day timeline", subtitle: nil) {
            if daySegments.isEmpty {
                placeholder("Nothing tracked on this day")
            } else {
                Chart(daySegments) { seg in
                    BarMark(
                        xStart: .value("From", seg.startHour),
                        xEnd: .value("To", seg.endHour),
                        y: .value("Day", ""),
                        height: .fixed(110)
                    )
                    .foregroundStyle(colorForProject(seg.projectID))
                    .opacity(hoveredSegment == nil || hoveredSegment?.id == seg.id ? 1 : 0.35)
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
                // Dotted rule at the cursor + a tooltip for whatever block is under (or nearest) it.
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            if let hour = hoverHour, let plot = geo[proxy.plotFrame!] as CGRect? {
                                let x = plot.minX + (plot.width * CGFloat(hour / 24))
                                Path { p in
                                    p.move(to: CGPoint(x: x, y: plot.minY))
                                    p.addLine(to: CGPoint(x: x, y: plot.maxY))
                                }
                                .stroke(Color.white.opacity(0.55),
                                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                if let seg = hoveredSegment {
                                    // Sits just right of the cursor, nudged left near the edge.
                                    timelineTooltip(seg)
                                        .offset(x: min(x + 8, max(0, plot.maxX - 150)),
                                                y: max(0, plot.minY + 4))
                                }
                            }
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let point):
                                        guard let plot = geo[proxy.plotFrame!] as CGRect?,
                                              plot.width > 0 else { return }
                                        let frac = (point.x - plot.minX) / plot.width
                                        let h = Double(min(max(frac, 0), 1)) * 24
                                        hoverHour = h
                                        hoveredSegment = nearestSegment(toHour: h)
                                    case .ended:
                                        hoverHour = nil
                                        hoveredSegment = nil
                                    }
                                }
                        }
                    }
                }
                .frame(height: 150)
                timelineLegend
            }
        }
    }

    /// Segment under the cursor, else the closest one *if it's genuinely near* — so a thin
    /// micro-switch is still inspectable without pixel-perfect aim, but hovering an empty stretch
    /// shows nothing rather than a neighbour's times (which reads as wrong data).
    private func nearestSegment(toHour h: Double) -> DaySegment? {
        if let hit = daySegments.first(where: { h >= $0.startHour && h <= $0.endHour }) { return hit }
        // ~4 minutes of slack: enough to grab a sliver, not enough to claim an idle gap.
        let slack = 4.0 / 60.0
        return daySegments
            .map { ($0, min(abs($0.startHour - h), abs($0.endHour - h))) }
            .filter { $0.1 <= slack }
            .min { $0.1 < $1.1 }?.0
    }

    private func timelineTooltip(_ seg: DaySegment) -> some View {
        let name = projectsByID[seg.projectID]?.name ?? "task"
        let mins = (seg.endHour - seg.startHour) * 60
        // Compact single line: swatch · name · duration, with the span underneath in tiny text.
        return HStack(spacing: 5) {
            Circle().fill(colorForProject(seg.projectID)).frame(width: 6, height: 6)
            Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            Text(durationLabel(mins)).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(spanLabel(from: seg.startHour, to: seg.endHour))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(.regularMaterial)   // translucent — the block underneath stays readable
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        )
        .fixedSize()
        .allowsHitTesting(false)
    }

    /// "9:30–10:55 AM" when both ends share a meridiem, else "11:40 AM–1:05 PM".
    private func spanLabel(from start: Double, to end: Double) -> String {
        let sameMeridiem = (Int(start) < 12) == (Int(end) < 12)
        if sameMeridiem {
            return "\(clockLabel(start, showMeridiem: false))–\(clockLabel(end))"
        }
        return "\(clockLabel(start))–\(clockLabel(end))"
    }

    /// 9.5 → "9:30 AM"
    private func clockLabel(_ hour: Double, showMeridiem: Bool = true) -> String {
        let total = Int((hour * 60).rounded())
        let h24 = (total / 60) % 24, m = total % 60
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        guard showMeridiem else { return String(format: "%d:%02d", h12, m) }
        return String(format: "%d:%02d %@", h12, m, h24 < 12 ? "AM" : "PM")
    }

    private func durationLabel(_ minutes: Double) -> String {
        if minutes < 1 { return "\(Int((minutes * 60).rounded()))s" }
        if minutes < 60 { return "\(Int(minutes.rounded()))m" }
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private var timelineLegend: some View {
        FlowLegend(items: legendItems)
    }

    // MARK: - Session list (day range)

    /// The day's blocks in order — the detail the single-bar charts couldn't give.
    private var sessionList: some View {
        section("Sessions", subtitle: "\(daySegments.count) blocks") {
            VStack(spacing: 4) {
                ForEach(daySegments) { seg in
                    let mins = (seg.endHour - seg.startHour) * 60
                    HStack(spacing: 9) {
                        Circle().fill(colorForProject(seg.projectID)).frame(width: 8, height: 8)
                        Text(projectLookup[seg.projectID]?.name ?? "task")
                            .font(.callout).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(spanLabel(from: seg.startHour, to: seg.endHour))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                        Text(durationLabel(mins))
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .trailing)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(hoveredSegment?.id == seg.id
                                  ? Color.accentColor.opacity(0.15)
                                  : Color(nsColor: .controlBackgroundColor))
                    )
                    .onHover { inside in hoveredSegment = inside ? seg : nil }
                }
            }
        }
    }

    // MARK: - Weekday pattern (multi-day ranges)

    private var weekdayPattern: some View {
        section("Weekday pattern", subtitle: "average tracked per weekday in this range") {
            if weekdayAvgs.allSatisfy({ $0.averageSeconds == 0 }) {
                placeholder("Nothing tracked in this range")
            } else {
                Chart(weekdayAvgs) { wd in
                    BarMark(
                        x: .value("Day", weekdayName(wd.weekday)),
                        y: .value("Hours", wd.averageSeconds / 3600),
                        width: .fixed(28)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .opacity(hoveredWeekday == nil || hoveredWeekday == wd.weekday ? 1 : 0.4)
                    .cornerRadius(3)
                }
                .frame(height: 130)
                .chartYAxisLabel("avg hours")
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            if let wd = hoveredWeekday,
                               let item = weekdayAvgs.first(where: { $0.weekday == wd }),
                               let plot = geo[proxy.plotFrame!] as CGRect?,
                               let x = proxy.position(forX: weekdayName(wd)) {
                                let px = plot.minX + x
                                Path { p in
                                    p.move(to: CGPoint(x: px, y: plot.minY))
                                    p.addLine(to: CGPoint(x: px, y: plot.maxY))
                                }
                                .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                HStack(spacing: 5) {
                                    Text(fullWeekdayName(wd)).font(.system(size: 10, weight: .semibold))
                                    Text("avg \(hours(item.averageSeconds))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(.regularMaterial)
                                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                                )
                                .fixedSize()
                                .position(x: min(max(px + 60, plot.minX + 60), plot.maxX - 60), y: plot.minY + 12)
                                .allowsHitTesting(false)
                            }
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let point):
                                        guard let plot = geo[proxy.plotFrame!] as CGRect?, plot.width > 0
                                        else { return }
                                        // 7 equal bands across the plot → weekday index. Skip
                                        // weekdays with no data so empty bands don't pop a tooltip.
                                        let frac = (point.x - plot.minX) / plot.width
                                        let idx = Int((Double(min(max(frac, 0), 0.999)) * 7).rounded(.down))
                                        let wd = min(max(idx, 0), 6)
                                        let hasData = weekdayAvgs.first { $0.weekday == wd }?.averageSeconds ?? 0 > 0
                                        hoveredWeekday = hasData ? wd : nil
                                    case .ended:
                                        hoveredWeekday = nil
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Hours chart

    private var hoursChart: some View {
        section("Hours \(bucketNoun)",
                subtitle: "goal \(hours(bucketGoal))/\(bucketUnitWord) · solid = focused (≥\(settings.deepBlockMinutes)m blocks)") {
            if buckets.isEmpty {
                placeholder("Nothing tracked in this range")
            } else {
                Chart {
                    ForEach(buckets) { b in
                        let onGoal = b.totalSeconds >= bucketGoal
                        let base = onGoal ? Color.green : Color.accentColor
                        let dim = hoveredBucket == nil || hoveredBucket?.id == b.id ? 1.0 : 0.4
                        // Total hours, drawn faint…
                        BarMark(
                            x: .value(bucketUnitWord.capitalized, b.start, unit: bucketComponent),
                            y: .value("Hours", b.totalSeconds / 3600),
                            width: barWidth,
                            stacking: .unstacked
                        )
                        .foregroundStyle(base.opacity(0.32))
                        .opacity(dim)
                        .cornerRadius(2)
                        // …with the focused portion overlaid solid inside it. Deep time is a
                        // subset of total by definition, so it nests cleanly — but only with
                        // `.unstacked`: two BarMarks at the same x stack by default, which drew
                        // each bar at total + focused (a 7.1h day at 100% focus read as 14.2h).
                        BarMark(
                            x: .value(bucketUnitWord.capitalized, b.start, unit: bucketComponent),
                            y: .value("Focused", b.deepSeconds / 3600),
                            width: barWidth,
                            stacking: .unstacked
                        )
                        .foregroundStyle(base)
                        .opacity(dim)
                        .cornerRadius(2)
                    }
                    RuleMark(y: .value("Goal", bucketGoal / 3600))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("goal").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .frame(height: 190)
                .chartYAxisLabel("hours")
                // Gridline on every bucket, but only label every Nth so a month's worth of ticks
                // stays legible instead of colliding into mush.
                .chartXAxis {
                    AxisMarks(values: buckets.map(\.start)) { value in
                        AxisGridLine(centered: true)
                        if let d = value.as(Date.self),
                           let idx = buckets.firstIndex(where: { $0.start == d }),
                           idx % axisLabelStride == 0 {
                            // `centered` aligns the label with the middle of the bucket, matching
                            // where BarMark(x:unit:) actually draws the bar.
                            AxisValueLabel(centered: true) {
                                Text(axisLabel(d)).font(.system(size: 10))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        bucketHoverOverlay(proxy: proxy, geo: geo) { b in
                            "\(hours(b.totalSeconds)) · \(hours(b.deepSeconds)) focused (\(percent(b.focusRatio)))"
                        }
                    }
                }
            }
        }
    }

    // MARK: - Where time went

    private var whereTimeWent: some View {
        section("Where time went", subtitle: nil) {
            let totals = rankedTotals
            if totals.isEmpty {
                placeholder("Nothing tracked in this range")
            } else {
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
            Text(total.project.name).font(.callout).lineLimit(1).frame(width: 130, alignment: .leading)
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
                .foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
    }

    // MARK: - Bucket hover

    /// Dotted rule + tooltip for the bar charts. `valueText` renders the metric for a bucket, so
    /// the hours and focus charts can share the same interaction.
    private func bucketHoverOverlay(
        proxy: ChartProxy, geo: GeometryProxy, valueText: @escaping (Bucket) -> String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if let b = hoveredBucket, let plot = geo[proxy.plotFrame!] as CGRect?,
               let x = proxy.position(forX: b.start) {
                // BarMark(x:unit:) centers each bar within its bucket, but position(forX:) returns
                // the bucket's leading edge — shift by half a bucket so the rule lands on the bar.
                let px = plot.minX + x + bucketPixelWidth(proxy: proxy) / 2
                Path { p in
                    p.move(to: CGPoint(x: px, y: plot.minY))
                    p.addLine(to: CGPoint(x: px, y: plot.maxY))
                }
                .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                HStack(spacing: 5) {
                    Text(bucketLabel(b.start)).font(.system(size: 10, weight: .semibold))
                    Text(valueText(b)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                )
                .fixedSize()
                .position(x: min(max(px + 70, plot.minX + 70), plot.maxX - 70), y: plot.minY + 12)
                .allowsHitTesting(false)
            }
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        guard let plot = geo[proxy.plotFrame!] as CGRect?, plot.width > 0 else { return }
                        // Resolve by pixel distance to each bar's center and only accept a hit
                        // within half a bucket — otherwise hovering the gaps/empty space would
                        // still latch onto the nearest bar.
                        let half = max(bucketPixelWidth(proxy: proxy) / 2, 6)
                        let cursorX = point.x - plot.minX
                        var best: (Bucket, CGFloat)?
                        for b in buckets {
                            guard let bx = proxy.position(forX: b.start) else { continue }
                            let center = bx + bucketPixelWidth(proxy: proxy) / 2
                            let d = abs(center - cursorX)
                            if best == nil || d < best!.1 { best = (b, d) }
                        }
                        hoveredBucket = (best?.1 ?? .greatestFiniteMagnitude) <= half ? best?.0 : nil
                    case .ended:
                        hoveredBucket = nil
                    }
                }
        }
    }

    /// Width of one bucket in points, from the first two bucket positions.
    private func bucketPixelWidth(proxy: ChartProxy) -> CGFloat {
        guard buckets.count > 1,
              let a = proxy.position(forX: buckets[0].start),
              let b = proxy.position(forX: buckets[1].start) else { return 0 }
        return abs(b - a)
    }

    /// Label every bucket when there's room; thin out as the count grows so ticks never collide.
    private var axisLabelStride: Int {
        let n = buckets.count
        if n <= 10 { return 1 }
        if n <= 16 { return 2 }
        if n <= 24 { return 3 }
        return 5          // a full month of days
    }

    /// Compact x-axis tick label per granularity: "31" (day) · "Jul 27" (week) · "Jul" (month).
    private func axisLabel(_ date: Date) -> String {
        let f = DateFormatter()
        switch bucketComponent {
        case .weekOfYear: f.dateFormat = "MMM d"
        case .month: f.dateFormat = "MMM"
        default: f.dateFormat = "d"
        }
        return f.string(from: date)
    }

    /// Bucket label matched to its granularity: "Thu Jul 31" · "wk of Jul 27" · "Jul 2026".
    private func bucketLabel(_ date: Date) -> String {
        let f = DateFormatter()
        switch bucketComponent {
        case .weekOfYear: f.dateFormat = "'wk of' MMM d"
        case .month: f.dateFormat = "MMM yyyy"
        default: f.dateFormat = "EEE MMM d"
        }
        return f.string(from: date)
    }

    // MARK: - Bucket presentation helpers

    private var bucketComponent: Calendar.Component {
        switch range.unit {
        case .day, .week, .month: return .day
        case .sixMonths: return .weekOfYear
        case .year, .all: return .month
        }
    }
    private var bucketUnitWord: String {
        switch bucketComponent {
        case .weekOfYear: return "week"
        case .month: return "month"
        default: return "day"
        }
    }
    private var bucketNoun: String { "per \(bucketUnitWord)" }
    /// Goal scaled to the bucket size (daily goal × days in bucket).
    private var bucketGoal: TimeInterval {
        switch bucketComponent {
        case .weekOfYear: return settings.dailyGoalSeconds * 5    // a 5-day work week
        case .month: return settings.dailyGoalSeconds * 22        // ~22 working days
        default: return settings.dailyGoalSeconds
        }
    }
    private var barWidth: MarkDimension {
        switch range.unit {
        case .day, .week: return .fixed(26)
        case .month: return .fixed(16)
        case .sixMonths: return .fixed(14)
        case .year, .all: return .fixed(22)
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, subtitle: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
    }

    /// Cached in state and refreshed in `recompute()` — do NOT hit the DB from a computed
    /// property, or every hover re-queries and the legend visibly re-renders.
    private var projectsByID: [Int64: Project] { projectLookup }

    private func colorForProject(_ id: Int64) -> Color {
        Color(hex: projectsByID[id]?.colorHex ?? "#8E8E93")
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return symbols[weekday % symbols.count]
    }

    private func fullWeekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols[weekday % symbols.count]
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

    private func hours(_ seconds: TimeInterval) -> String { String(format: "%.1fh", seconds / 3600) }
    private func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }

    // MARK: - Recompute

    private func recompute() {
        let store = appState.storeForEditing
        earliest = try? store.earliestIntervalStart()
        let all = (try? store.intervals()) ?? []
        let closed = all.filter { !$0.isRunning }
        let allProjects = (try? store.listProjects(includeArchived: true)) ?? []
        projectLookup = Dictionary(uniqueKeysWithValues: allProjects.map { ($0.id, $0) })

        summary = Aggregations.summary(
            intervals: all, range: range,
            deepThreshold: settings.deepBlockSeconds,
            dailyGoalSeconds: settings.dailyGoalSeconds
        )
        buckets = Aggregations.buckets(
            intervals: all, range: range, deepThreshold: settings.deepBlockSeconds
        )
        rankedTotals = Aggregations.totals(projects: allProjects, intervals: all, range: range)
            .filter { $0.seconds > 0 }
            .sorted { $0.seconds > $1.seconds }
        if isDay {
            daySegments = Aggregations.daySegments(intervals: all, day: range.start)
            // Stable legend: first appearance order along the day, computed once here.
            var seen = Set<Int64>()
            legendItems = daySegments.compactMap { seg in
                guard !seen.contains(seg.projectID), let p = projectLookup[seg.projectID] else { return nil }
                seen.insert(seg.projectID)
                return (p.name, Color(hex: p.colorHex))
            }
        } else {
            weekdayAvgs = Aggregations.weekdayAverages(intervals: closed, range: range)
            legendItems = []
        }
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
