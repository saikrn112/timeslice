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

    // Drag-select on the day timeline: the anchor where the drag began and the live edge.
    // Both non-nil while dragging or while a completed selection is being shown.
    @State private var selectionAnchor: Double?
    @State private var selectionEdge: Double?
    /// True only between a drag's first movement and its end, so each new drag re-anchors
    /// instead of extending the previous selection.
    @State private var isDragging = false

    /// Project lookup + the timeline legend, both computed once per recompute so hovering can't
    /// trigger DB reads or reshuffle the labels.
    @State private var projectLookup: [Int64: Project] = [:]
    /// Session block awaiting delete confirmation. Deleting removes recorded time with no undo,
    /// so the ✕ arms a confirm step rather than destroying it on a single stray click.
    @State private var pendingDelete: DaySegment?

    /// device_id -> human label, for the timeline lane titles and the Sessions device column.
    /// Loaded with the other data so hovering never triggers a DB read.
    @State private var deviceLabels: [String: String] = [:]
    @State private var legendItems: [(String, Color)] = []

    /// Roll "Where time went" up to groups instead of listing every task.
    @State private var groupByProject = false

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
            // Clicking anywhere else in the view drops the timeline selection. Attached to the
            // background rather than the content, and as a *simultaneous* gesture, so it can't
            // swallow clicks on the range pills, the ✕, or any chart interaction.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { clearSelection() })
            )
        }
        .onAppear { syncToNowIfStale(); recompute() }
        // Changing day/range invalidates any timeline selection — the hours it referred to
        // belong to a different day's data.
        .onChange(of: range) { _, _ in clearSelection(); recompute() }
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
                tile("Longest", value: Format.compact(summary?.longestSessionSeconds ?? 0),
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
        // `ratio` is unclamped so the label can read past 100%; the bar itself still clamps.
        let ratio = target > 0 ? total / target : 0
        let frac = min(1, ratio)
        return VStack(alignment: .leading, spacing: 6) {
            Text(isDay ? "Tracked" : "Total").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hoursOnly(total)).font(.system(.title2, design: .rounded)).fontWeight(.semibold)
                Text("/ \(hoursOnly(target))").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ProgressView(value: frac).tint(frac >= 1 ? .green : .accentColor)
                Text(percent(ratio))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ratio >= 1 ? Color.green : Color.secondary)
            }
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
                let lanes = Aggregations.laneCount(daySegments)
                HStack(spacing: 6) {
                    // Vertical device names down the left edge, one per lane, so each row of the
                    // timeline says which machine it came from. Only shown when a day actually has
                    // more than one device — otherwise the label is noise.
                    if timelineDevices.count > 1 {
                        deviceLaneLabels(lanes: lanes)
                    }
                Chart(daySegments) { seg in
                    // One lane per device when several contributed; a single device keeps one full
                    // -height row, with internal overlaps fanned out so nothing is hidden.
                    BarMark(
                        xStart: .value("From", seg.startHour),
                        xEnd: .value("To", seg.endHour),
                        y: .value("Lane", lanes > 1 ? "\(seg.lane)" : ""),
                        height: .fixed(lanes > 1 ? max(24, 110 / Double(lanes)) : 110)
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
                            // Shaded band for a drag-selection, drawn under the cursor rule.
                            if let plot = geo[proxy.plotFrame!] as CGRect?,
                               let range = selectedRange {
                                let x1 = plot.minX + plot.width * CGFloat(range.lowerBound / 24)
                                let x2 = plot.minX + plot.width * CGFloat(range.upperBound / 24)
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.18))
                                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                                    .frame(width: max(1, x2 - x1), height: plot.height)
                                    .offset(x: x1, y: plot.minY)
                                    .allowsHitTesting(false)
                            }
                            // Cursor rule + block tooltip — suppressed during a drag, where the
                            // selection readout is the thing being read.
                            if let hour = hoverHour, selectionAnchor == nil,
                               let plot = geo[proxy.plotFrame!] as CGRect? {
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
                                // Drag across the timeline to measure a stretch of the day.
                                .gesture(
                                    DragGesture(minimumDistance: 3)
                                        .onChanged { value in
                                            guard let plot = geo[proxy.plotFrame!] as CGRect?,
                                                  plot.width > 0 else { return }
                                            // Re-anchor on every NEW drag. Keying this off
                                            // `selectionAnchor == nil` left the anchor stuck at
                                            // wherever the first-ever drag began, so later drags
                                            // could only move the right edge.
                                            if !isDragging {
                                                isDragging = true
                                                selectionAnchor = hour(at: value.startLocation.x, in: plot)
                                            }
                                            selectionEdge = hour(at: value.location.x, in: plot)
                                        }
                                        .onEnded { value in
                                            isDragging = false
                                            guard let plot = geo[proxy.plotFrame!] as CGRect?,
                                                  plot.width > 0 else { return }
                                            selectionEdge = hour(at: value.location.x, in: plot)
                                            // A stray micro-drag isn't a selection worth keeping.
                                            guard let r = selectedRange,
                                                  (r.upperBound - r.lowerBound) >= (1.0 / 60.0) else {
                                                clearSelection()
                                                return
                                            }
                                            // Tighten onto block boundaries once, on release —
                                            // snapping live would make the band jump under the
                                            // cursor while you're still choosing the edges.
                                            let snapped = Aggregations.snapToSegments(
                                                segments: daySegments,
                                                from: r.lowerBound, to: r.upperBound
                                            )
                                            withAnimation(.easeOut(duration: 0.12)) {
                                                selectionAnchor = snapped.from
                                                selectionEdge = snapped.to
                                            }
                                        }
                                )
                                // A plain click (no drag) dismisses the selection, the way
                                // clicking off a text selection clears it.
                                .onTapGesture { clearSelection() }
                        }
                    }
                }
                .frame(height: 150)
                }
                if let summary = windowSummary { selectionReadout(summary) }
                timelineLegend
            }
        }
    }

    /// Devices contributing to this day, in the same first-appearance order the lanes use.
    private var timelineDevices: [String?] { Aggregations.orderedDevices(daySegments) }

    /// Short display name for a device: its user-set label, else the raw id, else "unknown" for
    /// rows recorded before device attribution existed.
    private func deviceName(_ id: String?) -> String {
        guard let id else { return "unknown" }
        return deviceLabels[id] ?? id
    }

    /// Rotated device names down the left edge of the timeline, aligned to their lanes. Each lane
    /// gets an equal share of the plot height, matching the fixed BarMark heights above.
    private func deviceLaneLabels(lanes: Int) -> some View {
        // Lane -> device, taken from the segments themselves so a label can never drift from the
        // row it names (a device may span several lanes when its own blocks overlap).
        var owner: [Int: String?] = [:]
        for seg in daySegments where owner[seg.lane] == nil { owner[seg.lane] = seg.deviceID }
        return VStack(spacing: 0) {
            ForEach(0..<lanes, id: \.self) { lane in
                Text(deviceName(owner[lane] ?? nil))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(maxHeight: .infinity)
                    .help(deviceName(owner[lane] ?? nil))
            }
        }
        .frame(width: 14, height: 110)
        // Nudge down so the labels line up with the plot area rather than the axis strip.
        .padding(.bottom, 22)
    }

    // MARK: - Drag-selection on the day timeline

    /// Local hour (0–24) for a point in the plot.
    private func hour(at x: CGFloat, in plot: CGRect) -> Double {
        let frac = (x - plot.minX) / plot.width
        return Double(min(max(frac, 0), 1)) * 24
    }

    /// The current selection as an ordered range, or nil when nothing is selected.
    private var selectedRange: ClosedRange<Double>? {
        guard let a = selectionAnchor, let b = selectionEdge else { return nil }
        return min(a, b)...max(a, b)
    }

    private var windowSummary: WindowSummary? {
        guard let r = selectedRange, r.upperBound > r.lowerBound else { return nil }
        return Aggregations.windowSummary(segments: daySegments,
                                          from: r.lowerBound, to: r.upperBound)
    }

    private func clearSelection() {
        selectionAnchor = nil
        selectionEdge = nil
        isDragging = false
    }

    /// Segments clipped to the selection — the source for both the breakdown and the session
    /// list while a range is selected. Clipped, not merely filtered: a block straddling an edge
    /// should contribute only its overlapping part, matching the Working/Idle figures above.
    private var segmentsInSelection: [DaySegment] {
        guard let r = selectedRange, r.upperBound > r.lowerBound else { return daySegments }
        return daySegments.compactMap { seg in
            let s = max(seg.startHour, r.lowerBound)
            let e = min(seg.endHour, r.upperBound)
            guard e > s else { return nil }
            // Carry lane and deviceID: this rebuilds the segment, and dropping them showed every
            // clipped block as "unknown" and collapsed the per-device lanes inside a selection.
            return DaySegment(id: seg.id, projectID: seg.projectID, startHour: s, endHour: e,
                              lane: seg.lane, deviceID: seg.deviceID)
        }
    }

    /// Per-task totals for the selection, ranked — same shape as `rankedTotals` so the existing
    /// rows render unchanged.
    private var totalsInSelection: [ProjectTotal] {
        guard let summary = windowSummary else { return rankedTotals }
        return summary.byProject.compactMap { row in
            guard let project = projectLookup[row.projectID] else { return nil }
            return ProjectTotal(project: project, seconds: row.seconds)
        }
    }

    /// True while a selection is narrowing the sections below the timeline.
    private var hasSelection: Bool { isDay && windowSummary != nil }

    /// Section subtitle naming the active selection, so a filtered list can't be mistaken for
    /// the whole day's.
    private var selectionSubtitle: String? {
        guard let s = windowSummary, hasSelection else { return nil }
        return "\(spanLabel(from: s.startHour, to: s.endHour)) selected"
    }

    /// Tracked vs untracked for the selected stretch. The day-level "Tracked" tile can't answer
    /// this — you weren't working the whole day, so a day figure says nothing about one stretch.
    private func selectionReadout(_ s: WindowSummary) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(spanLabel(from: s.startHour, to: s.endHour))
                    .font(.system(size: 11, weight: .semibold))
                Text("\(Format.compact(s.totalSeconds)) selected")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            Divider().frame(height: 22)

            statPair("Working", Format.compact(s.trackedSeconds),
                     detail: "\(Int((s.trackedRatio * 100).rounded()))%", tint: .accentColor)
            statPair("Idle", Format.compact(s.idleSeconds),
                     detail: nil, tint: .secondary)

            Spacer()

            Button { clearSelection() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Clear selection")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.10))
        )
        .padding(.top, 2)
    }

    private func statPair(_ label: String, _ value: String, detail: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                if let detail {
                    Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
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
    /// True once the data involves more than one device, so the column earns its width.
    private var showDeviceColumn: Bool {
        deviceLabels.count > 1 || Set(daySegments.map(\.deviceID)).count > 1
    }

    private var sessionList: some View {
        let segs = hasSelection ? segmentsInSelection : daySegments
        return section("Sessions", subtitle: "\(segs.count) blocks\(hasSelection ? " in selection" : "")") {
            VStack(spacing: 4) {
                ForEach(segs) { seg in
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
                        // Which machine recorded the block. Only worth a column once more than
                        // one device has ever synced — on a single-device setup it's the same
                        // answer on every row.
                        if showDeviceColumn {
                            Text(deviceName(seg.deviceID))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: 74, alignment: .trailing)
                                .help(deviceName(seg.deviceID))
                        }
                        deleteControl(for: seg)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(hoveredSegment?.id == seg.id
                                  ? Color.accentColor.opacity(0.15)
                                  : Color(nsColor: .controlBackgroundColor))
                    )
                    .onHover { inside in
                        hoveredSegment = inside ? seg : nil
                        // Leaving the row cancels an armed delete, so a confirm can't sit waiting
                        // on a row you've moved away from.
                        if !inside, pendingDelete?.id == seg.id { pendingDelete = nil }
                    }
                }
            }
        }
    }

    /// ✕ to remove a session, shown on hover; a second click confirms.
    ///
    /// Two steps because this destroys recorded time and there is no undo. A selection clips
    /// segments to its edges, so deleting one there would remove the WHOLE underlying interval,
    /// not the visible slice — the control is disabled in that case rather than lying about scope.
    @ViewBuilder
    private func deleteControl(for seg: DaySegment) -> some View {
        let armed = pendingDelete?.id == seg.id
        let clipped = hasSelection
        if hoveredSegment?.id == seg.id || armed {
            Button {
                if clipped { return }
                if armed {
                    deleteSession(seg)
                } else {
                    pendingDelete = seg
                }
            } label: {
                Image(systemName: armed ? "trash.fill" : "xmark")
                    .font(.system(size: armed ? 9 : 8, weight: .semibold))
                    .foregroundStyle(clipped ? Color.secondary : (armed ? Color.red : Color.secondary))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.secondary.opacity(armed ? 0.28 : 0.16)))
            }
            .buttonStyle(.plain)
            .disabled(clipped)
            .help(clipped
                  ? "Clear the timeline selection to delete a session — a clipped block isn't the whole interval"
                  : (armed ? "Click again to delete this session permanently" : "Remove this session"))
        } else {
            // Reserve the width so rows don't shift horizontally as the cursor moves down the list.
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private func deleteSession(_ seg: DaySegment) {
        pendingDelete = nil
        // seg.id IS the source interval id (daySegments carries it through), so no lookup needed.
        if (try? appState.storeForEditing.deleteInterval(id: seg.id)) == true {
            hoveredSegment = nil
            appState.reload()      // totals, today's tiles and the task list all read this
            recompute()            // charts + this list
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
        // While a stretch of the timeline is selected, this narrows to it — so the breakdown
        // answers "what filled *that*", not "what filled the whole day".
        section("Where time went", subtitle: selectionSubtitle, accessory: { groupToggle }) {
            let totals = isDay && hasSelection ? totalsInSelection : rankedTotals
            if totals.isEmpty {
                placeholder(hasSelection ? "Nothing tracked in this selection"
                                         : "Nothing tracked in this range")
            } else if groupByProject {
                // Rollup runs on the SAME totals, so grouped and ungrouped views always agree.
                let rolled = Aggregations.rollUp(totals: totals, taskProjects: appState.taskProjects)
                let maxSeconds = rolled.map(\.seconds).max() ?? 1
                VStack(spacing: 8) {
                    ForEach(rolled) { row in
                        groupRow(row, fraction: maxSeconds > 0 ? row.seconds / maxSeconds : 0)
                    }
                }
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

    /// Tasks ⇄ Projects. Hidden until at least one group exists, so the control doesn't appear
    /// before it can do anything.
    @ViewBuilder
    private var groupToggle: some View {
        if !appState.taskProjects.isEmpty {
            HStack(spacing: 6) {
                ForEach([false, true], id: \.self) { grouped in
                    Button { groupByProject = grouped } label: {
                        Text(grouped ? "Projects" : "Tasks")
                            .font(.system(size: 11, weight: groupByProject == grouped ? .semibold : .regular))
                            .foregroundStyle(groupByProject == grouped ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    if !grouped { Text("·").font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    private func groupRow(_ row: TaskProjectTotal, fraction: Double) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: row.colorHex)).frame(width: 9, height: 9)
            HStack(spacing: 5) {
                Text(row.name).font(.callout).lineLimit(1)
                Text("\(row.taskCount)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(Color(hex: row.colorHex))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 14)
            Text(Format.compact(row.seconds))
                .font(.system(.caption, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
    }

    private func rankRow(_ total: ProjectTotal, fraction: Double) -> some View {
        HStack(spacing: 10) {
            let hex = appState.displayColorHex(for: total.project)
            Circle().fill(Color(hex: hex)).frame(width: 9, height: 9)
            Text(total.project.name).font(.callout).lineLimit(1).frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(Color(hex: hex))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 14)
            Text(Format.compact(total.seconds))
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
        section(title, subtitle: subtitle, accessory: { EmptyView() }, content)
    }

    /// Same, with a control on the right of the header row (e.g. the Tasks ⇄ Projects toggle).
    private func section<Content: View, Accessory: View>(
        _ title: String, subtitle: String?,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                accessory()
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

    /// A task draws in its GROUP's colour when it has one, else its own. With many tasks the
    /// generated per-task hues start to look alike; inheriting collapses the palette without
    /// losing detail (hover still names the individual task).
    private func colorForProject(_ id: Int64) -> Color {
        guard let task = projectsByID[id] else { return Color(hex: "#8E8E93") }
        return Color(hex: appState.displayColorHex(for: task))
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

    /// Tile/axis magnitudes. Decimal hours read fine up to a day ("6.2h"), but a month's total
    /// as "312.5h" is hard to size up — past 24h this switches to `13d 1h`.
    private func hours(_ seconds: TimeInterval) -> String {
        seconds >= 24 * 3600 ? Format.compact(seconds) : String(format: "%.1fh", seconds / 3600)
    }

    /// Always hours, never rolling into days. Used where two figures sit side by side and must
    /// share a unit — "23.6h / 1d 16h" forces you to do the conversion to compare them.
    private func hoursOnly(_ seconds: TimeInterval) -> String {
        String(format: "%.1fh", seconds / 3600)
    }
    private func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }

    // MARK: - Recompute

    private func recompute() {
        let store = appState.storeForEditing
        earliest = try? store.earliestIntervalStart()
        let all = (try? store.intervals()) ?? []
        let closed = all.filter { !$0.isRunning }
        let allProjects = (try? store.listProjects(includeArchived: true)) ?? []
        projectLookup = Dictionary(uniqueKeysWithValues: allProjects.map { ($0.id, $0) })
        deviceLabels = (try? store.deviceLabels()) ?? [:]

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
            // One entry per GROUP (or per Inbox task), in first-appearance order — a day with
            // 30 tasks across 5 groups gets 5 chips, not 30.
            var seenLabels = Set<String>()
            legendItems = daySegments.compactMap { seg in
                guard let task = projectLookup[seg.projectID] else { return nil }
                let group = task.taskProjectID.flatMap { gid in
                    appState.taskProjects.first { $0.id == gid }
                }
                let label = group?.name ?? task.name
                guard !seenLabels.contains(label) else { return nil }
                seenLabels.insert(label)
                return (label, Color(hex: group?.colorHex ?? task.colorHex))
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
