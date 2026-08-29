import Charts
import SwiftUI
import TimesliceCore
import TimesliceUI

/// Metrics: headline tiles, the day timeline, per-bucket hours, where time went, and sessions.
///
/// Every number comes from `Aggregations` — `summary`, `daySegments`, `buckets`, `todayTotals`,
/// `rollUp`, `tagTotals`, `weekdayAverages`. Nothing is computed here, so the phone cannot disagree
/// with the Mac for the same range over the same database.
///
/// Dropped from the Mac deliberately: the timeline's **drag-select**. Dragging a range on a 390pt
/// wide chart fights scrolling and is imprecise with a thumb; tapping a segment to inspect it is the
/// touch equivalent and is what's here.
struct MetricsScreen: View {
    @ObservedObject private var model = TimerModel.shared
    @State private var unit: RangeUnit = .week
    @State private var data = MetricsData()
    /// Which axis "Where time went" is broken down by, mirroring the Mac's Tasks · Projects · Tags.
    @State private var axis: Axis = .tasks
    @State private var inspected: DaySegment?

    private enum Axis: String, CaseIterable, Identifiable {
        case tasks = "Tasks", projects = "Projects", tags = "Tags"
        var id: String { rawValue }
    }

    /// Everything the screen renders, recomputed together so no two views can disagree.
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
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Range", selection: $unit) {
                        ForEach(RangeUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                tilesSection
                if unit == .day { timelineSection } else { bucketsSection }
                whereSection
                weekdaySection
                sessionsSection
            }
            .navigationTitle("Metrics")
            .onAppear(perform: rebuild)
            .onChange(of: unit) { _, _ in rebuild() }
            .onChange(of: model.running?.projectID) { _, _ in rebuild() }
            .refreshable { model.reload(); rebuild() }
        }
    }

    // MARK: - Sections

    private var tilesSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 10) {
                Tile(label: "Tracked", value: Format.compact(data.summary.totalSeconds),
                     detail: "\(data.summary.activeDays) active day"
                             + (data.summary.activeDays == 1 ? "" : "s"))
                Tile(label: "Focus", value: "\(Int((data.summary.focusRatio * 100).rounded()))%",
                     detail: "\(Format.compact(data.summary.deepSeconds)) in long blocks")
                Tile(label: "Switches", value: "\(data.summary.switches)",
                     detail: perDaySwitches)
                Tile(label: "Longest", value: Format.compact(data.summary.longestSessionSeconds),
                     detail: "avg/day \(Format.compact(data.summary.avgPerActiveDay))")
            }
            .padding(.vertical, 2)
        }
    }

    private var perDaySwitches: String {
        guard data.summary.activeDays > 0 else { return "—" }
        let per = Double(data.summary.switches) / Double(data.summary.activeDays)
        return String(format: "%.1f/day", per)
    }

    /// The day view gets the timeline — on a small screen it's the single most informative chart,
    /// because it shows *shape* (when you worked, how fragmented) that no total can convey.
    private var timelineSection: some View {
        Section("Day timeline") {
            if data.segments.isEmpty {
                Text("Nothing tracked today").foregroundStyle(.secondary)
            } else {
                DayTimeline(segments: data.segments,
                            colorHex: { model.task(id: $0).map(model.colorHex(for:)) ?? "#8E8E93" },
                            onTap: { inspected = $0 })
                    .frame(height: 46)
                if let seg = inspected, let task = model.task(id: seg.projectID) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: model.colorHex(for: task)))
                            .frame(width: 8, height: 8)
                        Text(task.name).font(.caption)
                        Spacer()
                        Text("\(hourLabel(seg.startHour))–\(hourLabel(seg.endHour))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(Format.compact((seg.endHour - seg.startHour) * 3600))
                            .font(.system(.caption2, design: .monospaced))
                    }
                } else {
                    Text("Tap a block to inspect it.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var bucketsSection: some View {
        Section(unit == .year || unit == .all ? "Hours per month" : "Hours per day") {
            if data.buckets.allSatisfy({ $0.totalSeconds == 0 }) {
                Text("Nothing tracked in this range").foregroundStyle(.secondary)
            } else {
                Chart(data.buckets) { bucket in
                    BarMark(
                        x: .value("Bucket", bucket.start, unit: chartUnit),
                        y: .value("Hours", bucket.totalSeconds / 3600))
                        .foregroundStyle(Color.accentColor)
                }
                .chartYAxisLabel("h")
                .frame(height: 130)
            }
        }
    }

    private var chartUnit: Calendar.Component {
        switch unit {
        case .day: return .hour
        case .week, .month: return .day
        case .sixMonths: return .weekOfYear
        case .year, .all: return .month
        }
    }

    private var whereSection: some View {
        Section {
            Picker("Axis", selection: $axis) {
                ForEach(Axis.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            ForEach(whereRows, id: \.id) { row in
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: row.colorHex)).frame(width: 9, height: 9)
                    Text(row.name).lineLimit(1)
                    Spacer()
                    Text(Format.compact(row.seconds))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Where time went")
        } footer: {
            // Tags overlap, so their totals genuinely don't sum to the tracked total. Saying so is
            // cheaper than someone concluding the numbers are wrong.
            if axis == .tags {
                Text("A task with two tags counts in both, so these don't sum to the total.")
            }
        }
    }

    private struct WhereRow: Identifiable {
        let id: Int64
        let name: String
        let colorHex: String
        let seconds: TimeInterval
    }

    private var whereRows: [WhereRow] {
        switch axis {
        case .tasks:
            return data.taskTotals
                .filter { $0.seconds > 0 }
                .sorted { $0.seconds > $1.seconds }
                .map { WhereRow(id: $0.project.id, name: $0.project.name,
                                colorHex: model.colorHex(for: $0.project), seconds: $0.seconds) }
        case .projects:
            return data.groupTotals
                .filter { $0.seconds > 0 }
                .sorted { $0.seconds > $1.seconds }
                .map { WhereRow(id: $0.project?.id ?? -1, name: $0.project?.name ?? "Inbox",
                                colorHex: $0.project?.colorHex ?? "#8E8E93", seconds: $0.seconds) }
        case .tags:
            return data.tagTotals
                .filter { $0.seconds > 0 }
                .sorted { $0.seconds > $1.seconds }
                .map { WhereRow(id: $0.tag?.id ?? -1, name: $0.name,
                                colorHex: $0.colorHex, seconds: $0.seconds) }
        }
    }

    private var weekdaySection: some View {
        Section("Weekday pattern") {
            if data.weekdays.allSatisfy({ $0.averageSeconds == 0 }) {
                Text("Not enough data yet").foregroundStyle(.secondary)
            } else {
                Chart(data.weekdays) { day in
                    BarMark(x: .value("Day", weekdayName(day.weekday)),
                            y: .value("Avg hours", day.averageSeconds / 3600))
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                }
                .chartYAxisLabel("h")
                .frame(height: 110)
            }
        }
    }

    private var sessionsSection: some View {
        Section {
            if data.sessions.isEmpty {
                Text("No sessions in this range").foregroundStyle(.secondary)
            } else {
                ForEach(data.sessions, id: \.id) { session in
                    HStack(spacing: 8) {
                        if let task = model.task(id: session.projectID) {
                            Circle().fill(Color(hex: model.colorHex(for: task)))
                                .frame(width: 8, height: 8)
                            Text(task.name).font(.callout).lineLimit(1)
                        } else {
                            Text("(deleted task)").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(sessionRange(session))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(Format.compact(session.seconds()))
                            .font(.system(.caption, design: .monospaced))
                    }
                    .swipeActions {
                        // `deleteInterval` refuses the running one and tombstones the rest, so this
                        // can't orphan the live timer or resurrect on the next sync.
                        Button("Delete", role: .destructive) { deleteSession(session) }
                    }
                }
            }
        } header: {
            Text("Sessions")
        } footer: {
            Text("Swipe a session to delete it. The running session can't be deleted.")
        }
    }

    // MARK: - Data

    private func rebuild() {
        guard let store = model.storeIfLoaded else { return }
        let now = Date()
        let range = DateRange.resolve(unit: unit, anchor: now,
                                      earliest: try? store.earliestIntervalStart())
        let all = (try? store.intervals()) ?? []
        // Deep-block threshold: the Mac reads it from Settings (default 25 minutes). The phone has no
        // settings screen yet, so it uses the same default — stated here rather than hidden, because
        // a different threshold would make Focus % disagree between devices.
        let deepThreshold: TimeInterval = 25 * 60

        var d = MetricsData()
        d.summary = Aggregations.summary(intervals: all, range: range, deepThreshold: deepThreshold,
                                         now: now)
        d.buckets = Aggregations.buckets(intervals: all, range: range,
                                         deepThreshold: deepThreshold, now: now)
        d.segments = Aggregations.assignLanes(
            Aggregations.daySegments(intervals: all, day: now, now: now))
        // Per-task totals for the selected range. `rangeTotals` does the clipping in Core — an
        // earlier version trimmed intervals here by hand, which is precisely the DST/midnight-
        // sensitive arithmetic that must not exist in two places.
        d.taskTotals = Aggregations.rangeTotals(
            projects: model.allTasks, intervals: all, range: range, now: now)
        d.groupTotals = Aggregations.rollUp(totals: d.taskTotals, taskProjects: model.groups)
        d.tagTotals = Aggregations.tagTotals(
            tags: model.allTags, intervals: all,
            tagIDsByTask: (try? store.effectiveTagIDsByTask()) ?? [:], range: range, now: now)
        d.weekdays = Aggregations.weekdayAverages(intervals: all, range: range, now: now)
        d.sessions = all
            .filter { ($0.end ?? now) > range.start && $0.start < range.end }
            .sorted { $0.start > $1.start }
            .prefix(60)
            .map { $0 }
        data = d
    }

    private func deleteSession(_ session: Interval) {
        guard let store = model.storeIfLoaded else { return }
        _ = try? store.deleteInterval(id: session.id)
        model.reload()
        rebuild()
    }

    private func hourLabel(_ hour: Double) -> String {
        let h = Int(hour), m = Int((hour - Double(h)) * 60)
        return String(format: "%02d:%02d", h, m)
    }

    private func sessionRange(_ session: Interval) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        let start = f.string(from: session.start)
        guard let end = session.end else { return "\(start) → now" }
        let t = DateFormatter(); t.dateFormat = "HH:mm"
        return "\(start)–\(t.string(from: end))"
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let index = max(0, min(symbols.count - 1, weekday - 1))
        return symbols[index]
    }
}

private struct Tile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// The day as a 24-hour strip, one row per lane so overlapping segments (two devices during a
/// handoff) stay visible instead of hiding each other.
private struct DayTimeline: View {
    let segments: [DaySegment]
    let colorHex: (Int64) -> String
    let onTap: (DaySegment) -> Void

    private var lanes: Int { max(1, Aggregations.laneCount(segments)) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let laneH = geo.size.height / CGFloat(lanes)
            ZStack(alignment: .topLeading) {
                // Hour gridlines every 6h, so "morning vs evening" is readable without an axis.
                ForEach([6, 12, 18], id: \.self) { hour in
                    Rectangle().fill(Color.secondary.opacity(0.18))
                        .frame(width: 0.5, height: geo.size.height)
                        .offset(x: w * CGFloat(hour) / 24)
                }
                ForEach(segments) { seg in
                    let x = w * CGFloat(seg.startHour / 24)
                    let width = max(1.5, w * CGFloat((seg.endHour - seg.startHour) / 24))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: colorHex(seg.projectID)))
                        .frame(width: width, height: max(3, laneH - 2))
                        .offset(x: x, y: CGFloat(seg.lane) * laneH)
                        .onTapGesture { onTap(seg) }
                }
            }
        }
    }
}
