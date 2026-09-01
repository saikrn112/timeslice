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

    /// A "Where time went" row being hovered, which lights up every matching block on the day
    /// timeline. Answers "when did that actually happen?" — the breakdown gives a total, but not
    /// how it was spread across the day.
    private enum TimelineFocus: Equatable {
        case task(Int64)
        case group(Int64?)      // nil = Inbox, matching a task's own nil taskProjectID
        case tag(Int64?)        // nil = the untagged bucket
    }
    @State private var focus: TimelineFocus?
    /// Clicking a breakdown row PINS its highlight so it survives the mouse leaving. Hover still
    /// takes precedence, so you can peek at another row and fall back to the pinned one.
    @State private var pinnedFocus: TimelineFocus?

    /// The highlight actually in effect. A PIN wins over hover: once you've clicked something you're
    /// reading it, and having the page re-highlight under the pointer as it moves defeats the point
    /// of pinning. Hover only applies when nothing is pinned.
    private var activeFocus: TimelineFocus? { pinnedFocus ?? focus }

    /// Whether the active highlight actually picks anything out of what's on screen.
    ///
    /// A pin survives changing the day or the scope, and can end up referring to something not in
    /// view — at which point dimming "everything that doesn't match" dims EVERYTHING, with no clue
    /// as to why. A highlight that matches nothing is treated as no highlight.
    private var focusMatchesAnything: Bool {
        guard activeFocus != nil else { return false }
        return daySegments.contains { matchesFocus($0) }
    }

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
    /// Which grouping "Where time went" shows. Was a Bool for Tasks/Projects; tags make it three-way.
    enum BreakdownScope: String, CaseIterable, Identifiable {
        case tasks = "Tasks"
        case projects = "Projects"
        case tags = "Tags"
        var id: String { rawValue }
    }
    @State private var scope: BreakdownScope = .tasks

    // Tag data for the breakdown, loaded with everything else so hovering never queries.
    @State private var tags: [Tag] = []
    @State private var tagIDsByTask: [Int64: Set<Int64>] = [:]
    @State private var rangeIntervals: [Interval] = []
    @State private var targets: [Target] = []
    @State private var showTargetsSheet = false
    /// Budget row under the pointer, purely so the row shows it can be clicked.
    @State private var hoveredTargetID: Int64?


    /// Bucket under the cursor on the hours / focus charts.
    @State private var hoveredBucket: Bucket?
    /// Weekday index (0=Sun) under the cursor on the weekday-pattern chart.
    @State private var hoveredWeekday: Int?

    private var isDay: Bool { range.unit == .day }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // The range bar stays the page header — it frames everything under it, and moving a
                // section above it cost more in coherence than it bought in precision.
                RangeFilterBar(range: $range, earliest: earliest)
                tiles
                // Budgets report against their OWN period (a weekly one always shows this week), so
                // each row states its period. That per-row label is what keeps them from reading as
                // filtered, without a disclaimer under the heading.
                targetsSection
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
                    .simultaneousGesture(TapGesture().onEnded { clearSelection(); pinnedFocus = nil })
            )
        }
        .sheet(isPresented: $showTargetsSheet) {
            TargetsSheet(appState: appState, store: appState.storeForEditing) {
                showTargetsSheet = false
                // Tags/targets changed underneath every section, so pull it all again.
                appState.reload()
                recompute()
            }
        }
        .onAppear { syncToNowIfStale(); recompute() }
        // Changing day/range invalidates any timeline selection — the hours it referred to
        // belong to a different day's data.
        .onChange(of: range) { _, _ in
            // The pin points at a task/tag in the range being left; carrying it over is what left
            // every row dimmed with nothing highlighted.
            pinnedFocus = nil
            clearSelection(); recompute()
        }
        .onChange(of: scope) { _, _ in pinnedFocus = nil }
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
                tile("Avg/day", value: hours(summary?.avgPerActiveDay ?? 0),
                     caption: "active days only", tint: .teal)
                tile("Best day", value: hours(summary?.bestDaySeconds ?? 0), caption: "in range", tint: .blue)
            }
        }
    }

    private var goalTile: some View {
        // Measured against the hours you're AWAKE, not a work target. Now that everything gets
        // tracked, "4.0h / 8.0h" said nothing about the remaining twelve hours — and the gap is the
        // number that actually answers "did I use today or lose it".
        let total = (summary?.totalSeconds ?? 0) + liveExtra
        // Every CALENDAR day in the range counts, including ones with nothing tracked: a day you
        // recorded nothing is exactly when the gap should be widest. Counting only active days would
        // hide that by shrinking the denominator to match.
        let days = max(1, (range.end.timeIntervalSince(range.start) / 86_400).rounded())
        let awake = settings.wakingSeconds * days
        // No "Xh left" figure here on purpose: awake-hours minus tracked ignores how much of the day
        // has actually elapsed, so at 5pm it claimed 10h left when only 6 remained. Making it honest
        // needs to know when your day starts, which the app doesn't. The denominator alone carries
        // the point.
        // Unclamped so the label can read past 100%; the bar clamps.
        let ratio = awake > 0 ? total / awake : 0
        let frac = min(1, ratio)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tracked").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hoursOnly(total)).font(.system(.title2, design: .rounded)).fontWeight(.semibold)
                Text("/ \(hoursOnly(awake))").font(.caption).foregroundStyle(.secondary)
            }
            // Shrink rather than wrap: a second line here resizes the whole tile row.
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // The gap shares the progress row rather than taking a line of its own — an extra line
            // made this tile taller than the three beside it, which read as a layout bug.
            // A fixed-height capsule, not ProgressView: the latter's intrinsic height is larger
            // than a caption line, which made this tile taller than the three beside it. Same bar
            // shape the breakdown rows already use.
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(frac >= 1 ? Color.green : Color.accentColor)
                            .frame(width: max(3, geo.size.width * frac))
                    }
                }
                .frame(height: 5)
                Text(percent(ratio))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ratio >= 1 ? Color.green : Color.secondary)
            }
            .frame(height: 13)

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
                    // Device names down the left edge, one per lane, so each row says which machine
                    // it came from. Names only — the times live on their own line below, where
                    // there's room to read them.
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
                        height: .fixed(laneHeight(lanes: lanes))
                    )
                    .foregroundStyle(colorForProject(seg.projectID))
                    .opacity(segmentOpacity(seg))
                    .cornerRadius(3)
                }
                .chartXScale(domain: 0...24)
                // Pin the lane order. The y value is a STRING category, so Swift Charts otherwise
                // orders lanes by FIRST APPEARANCE in the data — and the day's first block belongs
                // to whichever device started earliest, not to lane 0. That put the lanes in a
                // different order than the label column beside them, which reads 0,1,2 downwards,
                // so the two devices' names appeared swapped.
                //
                // First element renders at the top, matching `ForEach(0..<lanes)` in the labels.
                .chartYScale(domain: lanes > 1 ? (0..<lanes).map(String.init) : [""])
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
                .frame(height: plotHeight(lanes: lanes) + 40)
                }
                deviceTotals
                if let summary = windowSummary { selectionReadout(summary) }
                timelineLegend
            }
        }
    }

    /// How prominent a timeline block should be.
    ///
    /// A hovered breakdown row wins over the cursor's own block: you're asking "where is this task",
    /// so every instance of it should read at full strength and everything else recede. Dimmed
    /// harder than the plain cursor case (0.12 vs 0.35) because the matches can be thin slivers that
    /// otherwise don't stand out.
    private func segmentOpacity(_ seg: DaySegment) -> Double {
        if activeFocus != nil, focusMatchesAnything {
            return matchesFocus(seg) ? 1 : settings.highlightDimOpacity
        }
        return hoveredSegment == nil || hoveredSegment?.id == seg.id ? 1 : 0.35
    }

    /// The tasks the active highlight covers.
    ///
    /// Reduced to task ids so a highlight can cross between scopes: pinning the `office` BUDGET has
    /// to light up office's rows in the Tasks breakdown too, not only when the breakdown happens to
    /// be showing Tags. Comparing focus kinds directly could never do that.
    private var focusedTaskIDs: Set<Int64>? {
        guard let activeFocus else { return nil }
        switch activeFocus {
        case .task(let id):
            return [id]
        case .group(let gid):
            return Set(projectLookup.values.filter { $0.taskProjectID == gid }.map(\.id))
        case .tag(let tid):
            guard let tid else {
                // The untagged bucket: tasks carrying no tags at all.
                return Set(projectLookup.keys.filter { (tagIDsByTask[$0] ?? []).isEmpty })
            }
            return Set(projectLookup.keys.filter { (tagIDsByTask[$0] ?? []).contains(tid) })
        }
    }

    /// Whether a breakdown row overlaps the highlight. Intersection, not equality, so a group row
    /// lights up when one of its tasks is pinned and vice versa.
    private func rowHighlighted(taskIDs: Set<Int64>) -> Bool {
        guard let focusedTaskIDs, !focusedTaskIDs.isEmpty else { return false }
        return !focusedTaskIDs.isDisjoint(with: taskIDs)
    }

    private func matchesFocus(_ seg: DaySegment) -> Bool {
        switch activeFocus {
        case .task(let id):
            return seg.projectID == id
        case .group(let groupID):
            // Compare the OPTIONALS directly so Inbox (nil) matches only Inbox tasks.
            return projectLookup[seg.projectID]?.taskProjectID == groupID
        case .tag(let tagID):
            let ids = tagIDsByTask[seg.projectID] ?? []
            // nil focus == untagged, which is "carries no tags at all".
            guard let tagID else { return ids.isEmpty }
            return ids.contains(tagID)
        case nil:
            return true
        }
    }

    /// Height of the plot area, and of one lane within it.
    ///
    /// Grows with the number of lanes instead of dividing a fixed 110pt: with three devices each lane
    /// was 36pt, which is too short for a rotated name to fit beside it. A floor of 110 keeps the
    /// single-device case looking as it did.
    private func plotHeight(lanes: Int) -> CGFloat { max(110, CGFloat(lanes) * 46) }
    private func laneHeight(lanes: Int) -> CGFloat {
        lanes > 1 ? plotHeight(lanes: lanes) / CGFloat(lanes) : 110
    }

    /// Devices contributing to this day, in the same first-appearance order the lanes use.
    private var timelineDevices: [String?] { Aggregations.orderedDevices(daySegments) }

    /// Short display name for a device: its user-set label, else the raw id, else "unknown" for
    /// rows recorded before device attribution existed.
    private func deviceName(_ id: String?) -> String {
        guard let id else { return "unknown" }
        // A device that hasn't been named yet shows its model rather than its raw id.
        return deviceLabels[id] ?? TimeslicePaths.shortDeviceName(id)
    }

    /// Rotated device names down the left edge, aligned to their lanes.
    ///
    /// Name only: the per-lane time made these long enough to be unreadable sideways, so the totals
    /// moved to their own line under the plot.
    private func deviceLaneLabels(lanes: Int) -> some View {
        // Lane -> device taken from the segments themselves, so a label can't drift from the row it
        // names (one device may span several lanes when its own blocks overlap).
        var owner: [Int: String?] = [:]
        for seg in daySegments where owner[seg.lane] == nil { owner[seg.lane] = seg.deviceID }
        return VStack(spacing: 0) {
            ForEach(0..<lanes, id: \.self) { lane in
                let device = owner[lane] ?? nil
                Text(deviceName(device))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // A width here, NOT `.fixedSize()`: rotation is a render transform, so this
                    // width becomes the label's visible height. `.fixedSize()` let the text grow to
                    // whatever the name needed and run straight over the lane above and below — with
                    // three devices the three names overlapped into an unreadable stack.
                    .frame(width: laneHeight(lanes: lanes) - 6)
                    .rotationEffect(.degrees(-90))
                    .frame(maxHeight: .infinity)
                    .help("\(device ?? "unattributed") — \(compactDuration(deviceSeconds(device)))")
            }
        }
        .frame(width: 14, height: plotHeight(lanes: lanes))
        // Nudge down so the labels line up with the plot area, not the axis strip.
        .padding(.bottom, 22)
    }

    /// Per-device totals as one quiet line under the timeline, in the same order as the lanes.
    ///
    /// Replaces rotated names down the plot edge: sideways text was hard to read and crowded the
    /// chart. Row identity now comes from hovering a block (the tooltip names the device), so the
    /// plot itself stays clean.
    ///
    /// Hidden for a single device, where every block has the same answer.
    @ViewBuilder
    private var deviceTotals: some View {
        let devices = timelineDevices
        if devices.count > 1 {
            HStack(spacing: 10) {
                ForEach(Array(devices.enumerated()), id: \.offset) { _, device in
                    HStack(spacing: 4) {
                        Text(deviceName(device))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(compactDuration(deviceSeconds(device)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A device's covered time in the visible range, honouring a selection like everything else.
    ///
    /// UNIONed per device rather than summed: a device's own blocks can overlap (that's why one
    /// device may occupy several lanes), and summing would count those minutes twice. Note the
    /// per-device figures can still exceed Tracked, which unions across ALL devices — two machines
    /// timing the same minutes is one minute of wall-clock but a minute on each.
    private func deviceSeconds(_ device: String?) -> TimeInterval {
        let segs = (hasSelection ? segmentsInSelection : daySegments)
            .filter { $0.deviceID == device }
        let day = range.start
        return SpanUnion.coveredSeconds(segs.map {
            (start: day.addingTimeInterval($0.startHour * 3600),
             end: day.addingTimeInterval($0.endHour * 3600))
        })
    }

    /// Tight duration for the rotated lane labels, where horizontal room is ~14pt: `45s`, `12m`,
    /// `6h`, `1d`. Deliberately coarser than `durationLabel` — "6h 41m" doesn't fit and the lane
    /// label is a glance, not a readout (the tooltip and Sessions have the precise figures).
    private func compactDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let mins = seconds / 60
        if mins < 60 { return "\(Int(mins.rounded()))m" }
        let hours = mins / 60
        if hours < 24 {
            // One decimal below 10h so 6.7h doesn't read as a flat 6h, which loses too much.
            return hours < 10 ? String(format: "%.1fh", hours) : "\(Int(hours.rounded()))h"
        }
        return String(format: "%.1fd", hours / 24)
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
            // Which machine recorded it — this is how a lane is identified now that the rows
            // aren't labelled. Only when more than one device is in play.
            if showDeviceColumn {
                Text(deviceName(seg.deviceID))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
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
    /// Tint for a "Where time went" row.
    ///
    /// The reverse of the timeline highlight: hovering a block on the timeline or a row in Sessions
    /// lights up the task (or project) it belongs to here, so you can go from "when was that?" back
    /// to "what was it, and how much in total?".
    ///
    /// Also tints the row under the cursor itself, so hovering gives feedback in both directions.
    private func breakdownTint(taskID: Int64) -> Color {
        var hit = rowHighlighted(taskIDs: [taskID])
        if pinnedFocus == nil {
            hit = hit || hoveredSegment?.projectID == taskID
        }
        return tintFor(hit: hit, taskID: taskID)
    }

    /// Pinned rows sit at a stronger tint than merely hovered ones — otherwise there's no way to
    /// tell a highlight that will persist from one that vanishes with the pointer.
    private func tintFor(hit: Bool, taskID: Int64? = nil, groupID: Int64?? = nil,
                         tagID: Int64?? = nil) -> Color {
        guard hit else { return .clear }
        // Stronger tint whenever the highlight came from a PIN, however it matched — an exact-kind
        // check would leave a row that lit up by containment looking merely hovered.
        _ = (taskID, groupID, tagID)
        return Color.accentColor.opacity(pinnedFocus != nil ? 0.28 : 0.15)
    }

    private func breakdownTint(groupID: Int64?) -> Color {
        let mine = Set(projectLookup.values.filter { $0.taskProjectID == groupID }.map(\.id))
        var hit = rowHighlighted(taskIDs: mine)
        if pinnedFocus == nil, let seg = hoveredSegment {
            // Compare the OPTIONALS directly so Inbox matches only ungrouped tasks.
            hit = hit || projectLookup[seg.projectID]?.taskProjectID == groupID
        }
        return tintFor(hit: hit, groupID: .some(groupID))
    }

    /// Row background: tints every block belonging to a hovered "Where time went" row, so the
    /// breakdown, the timeline and the session list all point at the same thing at once.
    /// Falls back to the plain cursor highlight when nothing is focused.
    private func sessionRowTint(_ seg: DaySegment) -> Color {
        let plain = Color(nsColor: .controlBackgroundColor)
        if activeFocus != nil, focusMatchesAnything {
            return matchesFocus(seg) ? Color.accentColor.opacity(0.15) : plain
        }
        if pinnedFocus != nil { return plain }
        return hoveredSegment?.id == seg.id ? Color.accentColor.opacity(0.15) : plain
    }

    /// Per-tag time for the visible range, narrowed to a timeline selection when there is one.
    private var tagTotals: [TagTotal] {
        let effective: DateRange
        if isDay, let r = selectedRange, r.upperBound > r.lowerBound {
            let dayStart = Calendar.current.startOfDay(for: range.start)
            effective = DateRange(unit: range.unit,
                                  start: dayStart.addingTimeInterval(r.lowerBound * 3600),
                                  end: dayStart.addingTimeInterval(r.upperBound * 3600))
        } else {
            effective = range
        }
        return Aggregations.tagTotals(tags: tags, intervals: rangeIntervals,
                                      tagIDsByTask: tagIDsByTask, range: effective)
    }

    private func tagRow(_ row: TagTotal, fraction: Double) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: row.colorHex)).frame(width: 9, height: 9)
            Text(row.name).font(.callout).lineLimit(1)
                .foregroundStyle(row.tag == nil ? Color.secondary : Color.primary)
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
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(breakdownTint(tagID: row.tag?.id)))
        .contentShape(Rectangle())
        .onHover { inside in focus = inside ? .tag(row.tag?.id) : nil }
        .onTapGesture {
            // Click to keep the highlight after the pointer leaves; click again to release it.
            let me: TimelineFocus = .tag(row.tag?.id)
            pinnedFocus = (pinnedFocus == me) ? nil : me
        }
    }

    private func breakdownTint(tagID: Int64?) -> Color {
        let mine: Set<Int64> = tagID == nil
            ? Set(projectLookup.keys.filter { (tagIDsByTask[$0] ?? []).isEmpty })
            : Set(projectLookup.keys.filter { (tagIDsByTask[$0] ?? []).contains(tagID!) })
        var hit = rowHighlighted(taskIDs: mine)
        if pinnedFocus == nil, let seg = hoveredSegment {
            let ids = tagIDsByTask[seg.projectID] ?? []
            hit = hit || (tagID == nil ? ids.isEmpty : ids.contains(tagID!))
        }
        return tintFor(hit: hit, tagID: .some(tagID))
    }

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
                    .opacity(activeFocus == nil || !focusMatchesAnything || matchesFocus(seg)
                             ? 1 : settings.highlightDimOpacity)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(sessionRowTint(seg))
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
                subtitle: "solid = focused (≥\(settings.deepBlockMinutes)m blocks)") {
            if buckets.isEmpty {
                placeholder("Nothing tracked in this range")
            } else {
                Chart {
                    ForEach(buckets) { b in
                        let base = Color.accentColor
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
            } else if scope == .tags {
                let rows = tagTotals
                if rows.isEmpty {
                    placeholder("Nothing tagged in this range")
                } else {
                    let maxSeconds = rows.map(\.seconds).max() ?? 1
                    VStack(spacing: 2) {
                        ForEach(rows) { row in
                            tagRow(row, fraction: maxSeconds > 0 ? row.seconds / maxSeconds : 0)
                        }
                        // Tags overlap, so these deliberately don't add up. Saying so beats letting
                        // the numbers look wrong.
                        Text("tags can overlap, so these don't sum to \(Format.compact(totals.reduce(0) { $0 + $1.seconds }))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
            } else if scope == .projects {
                // Rollup runs on the SAME totals, so grouped and ungrouped views always agree.
                let rolled = Aggregations.rollUp(totals: totals, taskProjects: appState.taskProjects)
                let maxSeconds = rolled.map(\.seconds).max() ?? 1
                VStack(spacing: 2) {
                    ForEach(rolled) { row in
                        groupRow(row, fraction: maxSeconds > 0 ? row.seconds / maxSeconds : 0)
                    }
                }
            } else {
                let maxSeconds = totals.map(\.seconds).max() ?? 1
                VStack(spacing: 2) {
                    ForEach(totals) { total in
                        rankRow(total, fraction: maxSeconds > 0 ? total.seconds / maxSeconds : 0)
                    }
                }
            }
        }
    }

    /// Tasks · Projects · Tags. Each option is hidden until it can do anything — no Projects
    /// choice before a group exists, no Tags choice before a tag does.
    @ViewBuilder
    private var groupToggle: some View {
        let available = BreakdownScope.allCases.filter { s in
            switch s {
            case .tasks: return true
            case .projects: return !appState.taskProjects.isEmpty
            case .tags: return !tags.isEmpty
            }
        }
        if available.count > 1 {
            HStack(spacing: 6) {
                ForEach(Array(available.enumerated()), id: \.element.id) { idx, option in
                    if idx > 0 { Text("·").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    Button { scope = option } label: {
                        Text(option.rawValue)
                            .font(.system(size: 11, weight: scope == option ? .semibold : .regular))
                            .foregroundStyle(scope == option ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
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
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(breakdownTint(groupID: row.project?.id)))
        .contentShape(Rectangle())
        .onHover { inside in focus = inside ? .group(row.project?.id) : nil }
        .onTapGesture {
            // Click to keep the highlight after the pointer leaves; click again to release it.
            let me: TimelineFocus = .group(row.project?.id)
            pinnedFocus = (pinnedFocus == me) ? nil : me
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
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(breakdownTint(taskID: total.project.id)))
        // contentShape so the gaps between elements are hoverable too, not just the text.
        .contentShape(Rectangle())
        .onHover { inside in focus = inside ? .task(total.project.id) : nil }
        .onTapGesture {
            // Click to keep the highlight after the pointer leaves; click again to release it.
            let me: TimelineFocus = .task(total.project.id)
            pinnedFocus = (pinnedFocus == me) ? nil : me
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


    /// Budget rows: actual against target, with a percentage, over/under, and a pace verdict.
    ///
    /// Absent entirely until at least one target exists, so nobody has to look at an empty section.
    @ViewBuilder
    private var targetsSection: some View {
        let rows = targetProgress
        if !rows.isEmpty {
            section("Allocations", subtitle: nil, accessory: { editTargetsButton }) {
                VStack(spacing: 2) {
                    budgetHeaderRow
                    ForEach(rows) { row in targetRow(row) }
                }
            }
        } else {
            // With no targets yet there's nothing to show, but there still has to be a way IN —
            // otherwise the feature is unreachable. One quiet link, not an empty section.
            HStack {
                Spacer()
                editTargetsButton
            }
        }
    }

    private var editTargetsButton: some View {
        Button(targets.isEmpty ? "Set up tags & allocations…" : "Edit") { showTargetsSheet = true }
            .buttonStyle(.link)
            .font(.system(size: 11))
    }

    /// Each target measured against ITS OWN period, not the range being browsed.
    ///
    /// Scaling onto the range was worse in practice: a 5h weekly budget viewed on a day became
    /// "42m", which is arithmetically right and completely meaningless. A budget answers "am I on
    /// track this week", and that shouldn't change because you're looking at Tuesday.
    /// Calendar days in the range being viewed, and how many of them have begun. Both feed the
    /// right-hand bar, which re-reads the same budget at whatever zoom the filter is set to.
    private var viewedRangeDays: Double {
        max(1, (range.end.timeIntervalSince(range.start) / 86_400).rounded())
    }

    /// Where a budget's period is measured from: `now` while you're on the current range, otherwise a
    /// point inside the range being viewed. So navigating to a past week reports THAT week.
    private var budgetAnchor: Date {
        TargetMath.periodAnchor(rangeStart: range.start, rangeEnd: range.end)
    }

    private var targetProgress: [TargetProgress] {
        let tasks = (try? appState.storeForEditing.listProjects(includeArchived: true)) ?? []
        let now = Date()
        return targets.compactMap { target in
            guard let name = targetName(target.subject, tasks: tasks) else { return nil }
            let unit: RangeUnit = {
                switch target.period {
                case .day: return .day
                case .week: return .week
                case .month: return .month
                }
            }()
            // Anchored INSIDE the range you're looking at, not at `now`. Keeping the budget's own
            // period (a weekly budget always shows a week) was right; anchoring it to today was not —
            // navigating back a week still reported this week's progress, so the section contradicted
            // every other number on the page.
            //
            // Clamped rather than just using `range.start`: while you're on the current period the
            // anchor stays `now`, which is what makes "on pace" meaningful.
            let window = DateRange.resolve(unit: unit, anchor: budgetAnchor)
            let secs = Aggregations.secondsForSubject(
                target.subject, intervals: rangeIntervals, tasks: tasks,
                tagIDsByTask: tagIDsByTask, range: window, now: now)
            // The anchor day's slice, not literally today's: on a past range "today" would be a day
            // outside what you're looking at.
            let today = Aggregations.secondsForSubject(
                target.subject, intervals: rangeIntervals, tasks: tasks,
                tagIDsByTask: tagIDsByTask,
                range: DateRange.resolve(unit: .day, anchor: budgetAnchor), now: now)
            // The subject's slice of the RANGE BEING VIEWED, for the share bar. A separate clock
            // from the budget period above, on purpose.
            let inRange = Aggregations.secondsForSubject(
                target.subject, intervals: rangeIntervals, tasks: tasks,
                tagIDsByTask: tagIDsByTask, range: range, now: now)
            return TargetMath.progress(target: target, name: name, actualSeconds: secs,
                                       rangeStart: window.start, rangeEnd: window.end, now: now,
                                       todaySeconds: today, rangeSeconds: inRange,
                                       viewedRangeDays: viewedRangeDays)
        }
        // The order you chose, not one I chose for you. `listTargets` returns them by `sort_order`,
        // so this deliberately doesn't re-sort — an automatic trouble-first sort and a manual order
        // can't both hold, and you asked for the manual one.
    }


    /// nil when the subject has been deleted — a stale target shouldn't render as a blank row.
    private func targetName(_ subject: TargetSubject, tasks: [Project]) -> String? {
        switch subject {
        case .task(let id): return tasks.first { $0.id == id }?.name
        case .project(let id): return appState.taskProjects.first { $0.id == id }?.name
        case .tag(let id): return tags.first { $0.id == id }?.name
        }
    }

    /// Captions over the two bars — otherwise there's nothing to say why a row has two percentages,
    /// or that the right one re-scales with the filter.
    private var budgetHeaderRow: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 9 + 96 + 42 + 10, height: 1)
            caption("allocated", leading: 56, trailing: 36)
            Color.clear.frame(width: 1, height: 1)
            caption("this \(rangeWord)", leading: 52, trailing: 44)
            Text("trend").font(.system(size: 8)).foregroundStyle(.quaternary)
                .frame(width: 108, alignment: .center)
        }
        .padding(.horizontal, 6)
    }

    /// A caption centred over a bar, with the bar's endpoint columns held aside so it lines up.
    private func caption(_ text: String, leading: CGFloat, trailing: CGFloat) -> some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: leading, height: 1)
            Text(text).font(.system(size: 8)).foregroundStyle(.quaternary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            Color.clear.frame(width: trailing, height: 1)
        }
    }

    private func targetRow(_ row: TargetProgress) -> some View {
        let color = verdictColor(row.verdict)
        // Bar clamps at full; the label carries the real number (or "over" for a blown ceiling).
        let goalFraction = min(max(row.percent / 100, 0), 1)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(row.name).font(.callout).lineLimit(1).truncationMode(.tail)
                .frame(width: 96, alignment: .leading)
            Text("\(row.target.direction.symbol) \(row.target.period.rawValue)")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 42, alignment: .leading)

            // GOAL: actual ▏bar▏ target. Endpoints label the bar instead of preceding it, so the
            // numbers read as the scale rather than as another column.
            Text(budgetDuration(row.actualSeconds))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 56, alignment: .trailing)
            InlineBar(fraction: goalFraction, label: percentText(row), fill: color)
                .help(budgetHelp(row))
            Text(budgetDuration(row.target.seconds))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.tertiary).lineLimit(1)
                .frame(width: 36, alignment: .leading)

            Divider().frame(height: 12)

            // SHARE: this subject's slice of everything tracked in the VIEWED range. Right-hand
            // endpoint is the range total, which is identical on every row — printed once in the
            // section subtitle instead of repeated here.
            Text(budgetDuration(row.rangeSeconds))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 52, alignment: .trailing)
            // The same commitment re-read at the viewed zoom: a 7h/week budget is 1h on one day.
            InlineBar(fraction: min(max(row.rangePercent / 100, 0), 1),
                      label: rangePercentText(row),
                      fill: subjectColor(row.target.subject))
                .help(rangeHelp(row))
            Text(budgetDuration(row.rangeExpectedSeconds))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.tertiary).lineLimit(1)
                .frame(width: 44, alignment: .leading)

            // Per-day view of a multi-day budget. From the budget's own period, not the filter.
            // One line, not two: a stacked pair set the row height and made the whole section
            // twice as tall as it needs to be.
            // Shape rather than another number: how this subject was spread across the viewed
            // range. Buckets follow the filter — hours across a day, days across a week or month.
            Sparkline(values: sparkValues(row), tint: subjectColor(row.target.subject))
                .frame(width: 108, height: 13)
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(budgetRowTint(row))
        )
        .contentShape(Rectangle())
        .onHover { inside in hoveredTargetID = inside ? row.target.id : nil }
        .onTapGesture {
            let me = focusFor(row.target.subject)
            pinnedFocus = (pinnedFocus == me) ? nil : me
        }
        // Reordering by right-click, not by dragging.
        //
        // Three attempts at a drag grip here didn't work: `.onDrag` from an overlay offset outside its
        // parent's bounds, inside a ScrollView, competing with the row's own tap gesture, never
        // started reliably — and every failure looked identical from the outside. A menu item cannot
        // half-work, and reordering four rows is not a gesture worth debugging further.
        .contextMenu {
            Button("Move up") {
                try? appState.storeForEditing.moveTarget(id: row.target.id, up: true)
                recompute()
            }
            .disabled(targets.first?.id == row.target.id)
            Button("Move down") {
                try? appState.storeForEditing.moveTarget(id: row.target.id, up: false)
                recompute()
            }
            .disabled(targets.last?.id == row.target.id)
        }
    }

    /// The one thing the row can't show: how far off target it is.
    /// Goal bar: how the budget's OWN period is going. Prefixed with the period so the two bars'
    /// tooltips can't be mistaken for each other.
    private func budgetHelp(_ row: TargetProgress) -> String {
        // Period total ÷ full period days — 19h43m across a week is 2h49m/day. Filter-agnostic.
        var out = "\(row.target.period.rawValue) · "
            + offBy(row.deltaSeconds, row.verdict, row.target.direction)
        if row.target.period != .day {
            out += " · avg \(tightDuration(row.averagePerDaySeconds))/d"
        }
        return out
    }

    /// Range bar: the same budget pro-rated onto what's on screen, plus the range's daily average.
    private func rangeHelp(_ row: TargetProgress) -> String {
        let delta = row.rangeSeconds - row.rangeExpectedSeconds
        let verdict: TargetProgress.Verdict
        if row.target.direction == .atMost {
            verdict = delta > 0 ? .over : .met
        } else {
            verdict = delta >= 0 ? .met : .behind
        }
        // No average here: it's a property of the budget's period, not of the range, so it lives on
        // the goal tooltip only and reads the same whatever the filter.
        return "\(rangeWord) · " + offBy(delta, verdict, row.target.direction)
    }

    private func offBy(_ delta: TimeInterval, _ verdict: TargetProgress.Verdict,
                       _ direction: Target.Direction) -> String {
        switch verdict {
        case .met: return direction == .atMost ? "within the limit" : "target reached"
        case .over: return "\(budgetDuration(abs(delta))) over"
        case .onPace, .behind: return "\(budgetDuration(abs(delta))) short"
        }
    }

    /// The viewed range as a word, for "% of week".
    private var rangeWord: String {
        switch range.unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .sixMonths: return "6 months"
        case .year: return "year"
        case .all: return "all time"
        }
    }

    /// A budget subject's own colour, for the share bar.
    private func subjectColor(_ subject: TargetSubject) -> Color {
        switch subject {
        case .tag(let id):
            return Color(hex: tags.first { $0.id == id }?.colorHex ?? "#8E8E93")
        case .project(let id):
            return Color(hex: appState.taskProjects.first { $0.id == id }?.colorHex ?? "#8E8E93")
        case .task(let id):
            return colorForProject(id)
        }
    }

    private func budgetRowTint(_ row: TargetProgress) -> Color {
        if pinnedFocus == focusFor(row.target.subject) { return Color.accentColor.opacity(0.28) }
        if hoveredTargetID == row.target.id { return Color.secondary.opacity(0.10) }
        return .clear
    }

    /// A budget's subject as a highlight. `.project` maps to `.group` — the breakdown calls the
    /// same thing a group, and one enum keeps the pin logic single-pathed.
    private func focusFor(_ subject: TargetSubject) -> TimelineFocus {
        switch subject {
        case .task(let id): return .task(id)
        case .project(let id): return .group(id)
        case .tag(let id): return .tag(id)
        }
    }

    private func percentText(_ row: TargetProgress) -> String {
        if row.target.direction == .atMost, row.verdict == .over { return "over" }
        return "\(Int(row.percent.rounded()))%"
    }

    /// Same rule for the pro-rated bar: a breached ceiling reads "over", not a runaway percentage.
    private func rangePercentText(_ row: TargetProgress) -> String {
        if row.target.direction == .atMost, row.rangePercent > 100 { return "over" }
        return "\(Int(row.rangePercent.rounded()))%"
    }

    private func verdictColor(_ v: TargetProgress.Verdict) -> Color {
        switch v {
        case .met: return .green
        case .onPace: return .accentColor
        case .behind: return .orange
        case .over: return .red
        }
    }

    private func verdictLabel(_ row: TargetProgress) -> String {
        let delta = abs(row.deltaSeconds)
        switch row.verdict {
        case .met: return row.target.direction == .atMost ? "within" : "met"
        case .onPace: return "on pace"
        case .behind: return "−\(Format.compact(delta))"
        case .over: return "+\(Format.compact(delta))"
        }
    }

    private func verdictHelp(_ row: TargetProgress) -> String {
        let pct = Int((row.elapsedFraction * 100).rounded())
        switch row.verdict {
        case .met:
            return row.target.direction == .atMost
                ? "Still inside the limit" : "Target reached"
        case .onPace:
            return "Behind the total but on track for \(pct)% of the period elapsed"
        case .behind:
            return "Short of where \(pct)% of the period would put you"
        case .over:
            return "Over the limit by \(Format.compact(abs(row.deltaSeconds)))"
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
    /// Per-bucket values for a row's sparkline, over the viewed range.
    private func sparkValues(_ row: TargetProgress) -> [TimeInterval] {
        let ids = Aggregations.taskIDs(for: row.target.subject,
                                       tasks: Array(projectLookup.values),
                                       tagIDsByTask: tagIDsByTask)
        guard !ids.isEmpty else { return [] }
        return Aggregations.sparkline(
            intervals: rangeIntervals.filter { ids.contains($0.projectID) }, range: range)
    }

    /// Same as `budgetDuration` without the inner space — for the narrow per-day column, where
    /// "3h 17m" plus "1h 7m today" overflowed 84pt and truncated to "1h…".
    private func tightDuration(_ seconds: TimeInterval) -> String {
        budgetDuration(seconds).replacingOccurrences(of: " ", with: "")
    }

    /// Duration for budget rows: hours and minutes, never days.
    ///
    /// `Format.compact` rolls over to "1d 16h" past 24 hours, which is unreadable as a *budget* —
    /// a 40h weekly target rendered as "1d 16h". Budgets are always talked about in hours.
    private func budgetDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total <= 0 { return "0" }
        if total < 60 { return "\(total)s" }
        let h = total / 3600, m = (total % 3600) / 60
        if h == 0 { return "\(m)m" }
        // Past 100h the minutes are noise, and they overflowed the column — a year view showed
        // "107h 2…" and "2085h…".
        if h >= 100 || m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    /// Hours, dropping the decimal once the number is big enough not to need it.
    ///
    /// "164.2h / 5840.0h" on the year view was long enough to wrap onto a second line, which made
    /// the tile taller than the four beside it. A tenth of an hour is meaningless at that scale
    /// anyway.
    private func hoursOnly(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        if abs(h) >= 100 || h == h.rounded() { return "\(Int(h.rounded()))h" }
        return String(format: "%.1fh", h)
    }
    private func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }

    // MARK: - Recompute

    private func recompute() {
        let store = appState.storeForEditing
        earliest = try? store.earliestIntervalStart()
        let all = (try? store.intervals()) ?? []
        let allProjects = (try? store.listProjects(includeArchived: true)) ?? []
        projectLookup = Dictionary(uniqueKeysWithValues: allProjects.map { ($0.id, $0) })
        deviceLabels = (try? store.deviceLabels()) ?? [:]
        tags = (try? store.listTags()) ?? []
        tagIDsByTask = (try? store.effectiveTagIDsByTask()) ?? [:]
        targets = (try? store.listTargets()) ?? []

        // Kept so the tag breakdown can be recomputed for a selection without another DB read.
        rangeIntervals = all
        let closed = all.filter { !$0.isRunning }

        summary = Aggregations.summary(
            intervals: all, range: range,
            deepThreshold: settings.deepBlockSeconds,
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

/// A progress bar with its percentage centred INSIDE it, legible at every fill level.
///
/// The label is drawn twice — once in a colour that reads on the fill, once in a colour that reads
/// on the empty track — each masked to its own side of the fill boundary. That is the whole trick:
/// a centred label is crossed by the boundary at ~50% fill, which is the common case, and a single
/// text colour disappears there against one side or the other.
///
/// The on-fill colour comes from the fill's luminance, so this works for any tag colour as well as
/// the green/orange/red verdict states without a per-colour table.
struct InlineBar: View {
    let fraction: Double          // 0…1, already clamped by the caller if it can exceed
    let label: String
    let fill: Color
    var height: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fw = min(max(fraction, 0), 1) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14))
                // No sliver at zero: a minimum-width stub reads as "started" when nothing has been.
                if fw > 0 { Capsule().fill(fill).frame(width: max(3, fw)) }

                text(color: onTrack)
                    .frame(width: w)
                    .mask(alignment: .leading) {
                        // Only the part of the glyphs sitting over empty track.
                        HStack(spacing: 0) { Color.clear.frame(width: fw); Rectangle() }
                    }
                text(color: onFill)
                    .frame(width: w)
                    .mask(alignment: .leading) {
                        HStack(spacing: 0) { Rectangle().frame(width: fw); Color.clear }
                    }
            }
        }
        .frame(height: height)
    }

    private func text(color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Readable against the empty track (which is a faint grey over the window background).
    private var onTrack: Color { .secondary }

    /// Readable against the fill. Perceptual luminance, not plain brightness — a saturated yellow is
    /// far lighter to the eye than its RGB max suggests.
    private var onFill: Color {
        guard let c = NSColor(fill).usingColorSpace(.deviceRGB) else { return .white }
        let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return l > 0.6 ? .black : .white
    }
}

/// A minimal per-bucket bar chart: shape at a glance, no axes or labels.
///
/// One shared scale (the range's own maximum), so heights within a row compare honestly. Empty
/// buckets draw a faint baseline rather than nothing, so a gap reads as a gap instead of the chart
/// silently compressing it.
struct Sparkline: View {
    let values: [TimeInterval]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let maxV = values.max() ?? 0
            // Downsample: a year of days would otherwise be 365 sub-pixel bars.
            let step = max(1, values.count / 60)
            let shown = stride(from: 0, to: values.count, by: step).map { values[$0] }
            let gap: CGFloat = shown.count > 30 ? 0.5 : 1
            let w = max(1, (geo.size.width - CGFloat(max(0, shown.count - 1)) * gap)
                        / CGFloat(max(1, shown.count)))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, v in
                    Rectangle()
                        .fill(v > 0 ? tint : Color.secondary.opacity(0.25))
                        .frame(width: w, height: maxV > 0 ? max(1, geo.size.height * CGFloat(v / maxV)) : 1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
    }
}
