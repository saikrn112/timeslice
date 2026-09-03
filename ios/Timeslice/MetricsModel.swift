import Foundation
import SwiftUI
import TimesliceCore

/// The state and derived data behind Metrics, shared by the summary and every detail screen.
///
/// One object rather than `@State` per screen, because the summary and its drill-downs must agree: a detail
/// screen that recomputed its own range or its own totals could differ from the row you tapped to reach it,
/// and that difference is invisible until you notice two numbers for one thing. Everything here is built once
/// per change and read by all of them.
///
/// Every figure still comes from `Aggregations` / `BudgetRows` in Core. This holds no arithmetic.
@MainActor
final class MetricsModel: ObservableObject {
    /// The period being viewed.
    @Published var range = DateRange.resolve(unit: .day, anchor: Date())

    /// The subject the page is FILTERED to, or nil for everything.
    ///
    /// This is the touch answer to the Mac's hover-linked highlighting: on a pointer you sweep a breakdown row
    /// and matching timeline blocks light up, which needs a hover and dies the moment you look away. A filter
    /// is stateful — you tap an allocation, every number on the page narrows to it, and it stays narrowed
    /// while you scroll and drill down.
    @Published var filter: TargetSubject?
    /// Human name for the filter, resolved when it's set — the subject is an id and a kind, which means
    /// nothing to read.
    @Published private(set) var filterName: String?

    @Published private(set) var data = MetricsData()
    @Published private(set) var earliest: Date?

    /// The period cards. Depends on the UNIT and the data, never on which period is selected, so it's cached
    /// separately — rebuilding 60 windows on every swipe was measured at 190ms.
    @Published private(set) var strip: [PeriodCard] = []
    private var stripUnit: RangeUnit?

    struct MetricsData {
        var summary = RangeSummary(totalSeconds: 0, deepSeconds: 0, activeDays: 0, switches: 0,
                                   longestSessionSeconds: 0, bestDaySeconds: 0)
        var segments: [DaySegment] = []
        var taskTotals: [ProjectTotal] = []
        var groupTotals: [TaskProjectTotal] = []
        var tagTotals: [TagTotal] = []
        var sessions: [Interval] = []
        var budgets: [BudgetRows.Row] = []
        var buckets: [Bucket] = []
    }

    /// Only Day, Week and Month on the phone.
    ///
    /// 6M, Y and All are comparative ranges you read at a desk — the phone answers "how is it going", not
    /// "how has it trended since March". Deferred rather than dropped; see `docs/ios_metrics_design.md`.
    static let units: [RangeUnit] = [.day, .week, .month]

    private var model: TimerModel { TimerModel.shared }

    // MARK: - Filtering

    /// Set or clear the filter. Tapping the active subject clears it, which is what a toggle should do.
    func toggleFilter(_ subject: TargetSubject?, name: String?) {
        if filter == subject {
            filter = nil
            filterName = nil
        } else {
            filter = subject
            filterName = name
        }
        rebuild()
    }

    /// Task ids the filter admits, or nil when unfiltered.
    ///
    /// Resolved through `Aggregations.taskIDs`, the same expansion budgets use — a tag filter has to mean
    /// "every task carrying it", and that logic exists once.
    private func admittedTaskIDs() -> Set<Int64>? {
        guard let filter, let store = model.storeIfLoaded else { return nil }
        let tagIDsByTask = (try? store.effectiveTagIDsByTask()) ?? [:]
        return Aggregations.taskIDs(for: filter, tasks: model.allTasks, tagIDsByTask: tagIDsByTask)
    }

    // MARK: - Building

    func rebuild() {
        guard let store = model.storeIfLoaded else { return }
        Perf.shared.measure(Perf.Path.metricsRebuild) { build(store) }
    }

    private func build(_ store: IntervalStore) {
        let now = Date()
        earliest = try? store.earliestIntervalStart()
        let deep = model.settings.deepBlockSeconds
        let everything = (try? store.intervals()) ?? []

        // The filter is applied ONCE, here, to the interval list every section derives from. Filtering per
        // section would be the same expression written five times, and the fifth would eventually differ.
        let admitted = admittedTaskIDs()
        let all = admitted.map { ids in everything.filter { ids.contains($0.projectID) } } ?? everything

        var d = MetricsData()
        d.summary = Aggregations.summary(intervals: all, range: range, deepThreshold: deep, now: now)
        d.buckets = Aggregations.buckets(intervals: all, range: range, deepThreshold: deep, now: now)
        d.segments = Aggregations.assignLanesByOverlap(
            Aggregations.daySegments(intervals: all, day: range.start, now: now))
        d.taskTotals = Aggregations.rangeTotals(projects: model.allTasks, intervals: all,
                                                range: range, now: now)
        d.groupTotals = Aggregations.rollUp(totals: d.taskTotals, taskProjects: model.groups)
        let tagIDsByTask = (try? store.effectiveTagIDsByTask()) ?? [:]
        d.tagTotals = Aggregations.tagTotals(tags: model.allTags, intervals: all,
                                             tagIDsByTask: tagIDsByTask, range: range, now: now)
        d.sessions = all
            .filter { ($0.end ?? now) > range.start && $0.start < range.end }
            .sorted { $0.start > $1.start }
        // Allocations are NEVER filtered: the section exists to say how each one is doing, and narrowing it
        // to the one you tapped would leave a list of length one saying what you already knew.
        d.budgets = BudgetRows.build(
            targets: (try? store.listTargets()) ?? [], tasks: model.allTasks,
            groups: model.groups, tags: model.allTags, tagIDsByTask: tagIDsByTask,
            intervals: everything, viewedRange: range, now: now)
        data = d

        rebuildStripIfNeeded(intervals: everything, deep: deep, now: now)
    }

    /// The strip is built from UNFILTERED intervals on purpose: it's the navigation control, and cards that
    /// emptied out when a filter was applied would make the days you can reach depend on what you'd tapped.
    private func rebuildStripIfNeeded(intervals: [Interval], deep: TimeInterval, now: Date) {
        guard range.unit != .all else { strip = []; return }
        guard stripUnit != range.unit || strip.isEmpty else { return }
        strip = Perf.shared.measure(Perf.Path.stripBuild) {
            buildStrip(intervals: intervals, deep: deep, now: now)
        }
        stripUnit = range.unit
    }

    /// Invalidate the cached strip — after a sync, an edit, or a timer change.
    func invalidateStrip() { stripUnit = nil }

    private static let stripDepth = 60

    private func buildStrip(intervals: [Interval], deep: TimeInterval, now: Date) -> [PeriodCard] {
        let present = DateRange.resolve(unit: range.unit, anchor: now, earliest: earliest)
        var windows: [DateRange] = []
        var cursor = present
        for step in 0..<(Self.stripDepth * 2) {
            windows.append(cursor)
            if step >= Self.stripDepth - 1 && cursor.start <= range.start { break }
            if let earliest, cursor.start <= earliest { break }
            let next = cursor.stepped(by: -1, earliest: earliest)
            guard next.start < cursor.start else { break }
            cursor = next
        }
        let spanStart = windows.last?.start ?? present.start
        let inSpan = intervals.filter { ($0.end ?? now) >= spanStart }
        let ordered = Array(windows.reversed())
        let totals = Aggregations.windowTotals(intervals: inSpan, windows: ordered,
                                               deepThreshold: deep, now: now)
        var cards = zip(ordered, totals).map { window, t in
            PeriodCard(range: window, totalSeconds: t.total, deepSeconds: t.deep)
        }
        let busiest = cards.map(\.totalSeconds).max() ?? 0
        if busiest > 0 {
            for i in cards.indices { cards[i].fraction = cards[i].totalSeconds / busiest }
        }
        return cards
    }

    // MARK: - Navigation

    /// Move by whole periods; refuses the future. Returns false so a swipe can decline to buzz.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        let next = range.stepped(by: delta, earliest: earliest)
        guard next.start <= Date(), next != range else { return false }
        range = next
        rebuild()
        return true
    }

    func select(_ newRange: DateRange) {
        range = newRange
        rebuild()
    }

    func select(unit: RangeUnit) {
        // Keep your position in time when changing granularity: the week containing the day you were on.
        let anchor = range.isCurrent() ? Date() : min(range.start, Date())
        range = DateRange.resolve(unit: unit, anchor: anchor, earliest: earliest)
        rebuild()
    }

    // MARK: - Derived, for the summary rows

    var colorHexForTask: (Int64) -> String {
        { [weak self] id in
            guard let self, let task = self.model.task(id: id) else { return "#8E8E93" }
            return self.model.colorHex(for: task)
        }
    }

    /// Allocation verdicts, counted.
    var allocationCounts: (onTrack: Int, behind: Int) {
        var onTrack = 0, behind = 0
        for row in data.budgets {
            switch row.progress.verdict {
            case .met, .onPace: onTrack += 1
            case .behind, .over: behind += 1
            }
        }
        return (onTrack, behind)
    }

    /// The allocations WORTH NAMING on the summary, worst first.
    ///
    /// A row of verdict dots was too abstract to act on: five coloured circles say "something is behind"
    /// without saying which, so the row's only use was as a button. Naming the ones that need attention makes
    /// the summary answer the question instead of advertising that an answer exists elsewhere.
    ///
    /// Worst first by how far past its own pace it is, not by raw size — a 20-minute-a-day habit missed
    /// entirely matters more than a 60-hour month a little behind.
    var allocationsNeedingAttention: [BudgetRows.Row] {
        data.budgets
            .filter { row in
                switch row.progress.verdict {
                case .behind, .over: return true
                case .met, .onPace: return false
                }
            }
            .sorted { lhs, rhs in
                shortfallFraction(lhs.progress) > shortfallFraction(rhs.progress)
            }
    }

    /// How far behind pace, as a fraction of what was expected by now. Comparable across periods and sizes.
    private func shortfallFraction(_ p: TargetProgress) -> Double {
        guard p.expectedSeconds > 0 else { return 0 }
        return abs(p.expectedSeconds - p.actualSeconds) / p.expectedSeconds
    }

    /// When everything is fine, the one closest to trouble — so the row still names something rather than
    /// just asserting that all is well.
    var closestAllocation: BudgetRows.Row? {
        data.budgets.min { lhs, rhs in
            headroomFraction(lhs.progress) < headroomFraction(rhs.progress)
        }
    }

    private func headroomFraction(_ p: TargetProgress) -> Double {
        guard p.target.seconds > 0 else { return 1 }
        return p.remainingSeconds / p.target.seconds
    }

    /// True when the range genuinely has nothing in it, so the UI can say that once instead of printing a
    /// grid of zeros.
    var isEmpty: Bool { data.summary.totalSeconds <= 0 }
}
