import Foundation

/// A stretch of work, as experienced rather than as recorded.
///
/// Pausing for one second correctly ends an interval — an interval is an immutable recorded fact and
/// has to stay one. But nothing a person would call a break happened, so every *derived* measure that
/// treats the gap as a wall is wrong about the day: 15m + a one-second pause + 15m was half an hour of
/// work credited with **zero** focused time, because focus asked whether one interval's own duration
/// reached the threshold.
///
/// A run is the maximal chain of intervals with no gap longer than the tolerance. On this database
/// 602 same-task gaps were under a minute, and bridging them moved focus over 56 days from 52.3% to
/// 61.2% without changing a single tracked hour — which is the whole design constraint below.
public struct WorkRun: Sendable, Hashable {
    /// The intervals that make up the run, in time order.
    public let intervalIDs: [Int64]
    public let start: Date
    public let end: Date
    /// Sum of the intervals' OWN durations. The bridged gaps are deliberately NOT added: the interval
    /// rows are the facts, and every total, the Planner's goals and the import dedup all rest on their
    /// sum. A run reinterprets continuity, never quantity.
    public let workSeconds: TimeInterval
    /// Tasks touched, in first-seen order. Exactly one entry for a per-task run.
    public let projectIDs: [Int64]

    public init(intervalIDs: [Int64], start: Date, end: Date,
                workSeconds: TimeInterval, projectIDs: [Int64]) {
        self.intervalIDs = intervalIDs
        self.start = start
        self.end = end
        self.workSeconds = workSeconds
        self.projectIDs = projectIDs
    }

    /// Wall-clock length including the bridged gaps. Never less than `workSeconds`.
    public var spanSeconds: TimeInterval { end.timeIntervalSince(start) }
}

/// What "focused" means: how long a stretch has to be, and how much of a pause it survives.
///
/// One value rather than two loose parameters because these two always travel together — five
/// aggregation functions need both, and a call site that passed the threshold but forgot the tolerance
/// would silently compute the old, wrong answer.
public struct FocusRule: Sendable, Hashable {
    /// A run this long or longer counts as focused.
    public let deepSeconds: TimeInterval
    /// A gap this long or shorter doesn't break the run.
    public let blendSeconds: TimeInterval

    public init(deepSeconds: TimeInterval, blendSeconds: TimeInterval) {
        self.deepSeconds = deepSeconds
        self.blendSeconds = blendSeconds
    }

    /// Focus with no fuzziness at all: only back-to-back intervals join up.
    public static func strict(deepSeconds: TimeInterval) -> FocusRule {
        .init(deepSeconds: deepSeconds, blendSeconds: 0)
    }
}

public enum WorkRuns {

    /// Group intervals into runs.
    ///
    /// `perTask` is the whole difference between the three counters that use this:
    ///  • `true`  — focus, and the "still working on X?" clock. A switch to another task ends the run,
    ///    because "still on X" is a question about X.
    ///  • `false` — the break counter. Switching from A to B with no pause is continuous work and has
    ///    to keep accruing, or 5m on A + 10m on B + 10m on A + 5m on C counts as nothing.
    ///
    /// A gap is bridged whatever filled it. Thirty seconds answering a message, tracked as its own
    /// task, does not destroy task A's half-hour block: the tolerance measures how long an interruption
    /// lasted, not what you did during it. So a per-task run can span another task's interval, and two
    /// runs can overlap in time — which is safe because focus is unioned per day before it becomes a
    /// percentage.
    ///
    /// An open interval (`end == nil`) is measured to `now`, the same convention the rest of
    /// `Aggregations` uses.
    public static func runs(_ intervals: [Interval], gap: TimeInterval, perTask: Bool,
                            now: Date = Date()) -> [WorkRun] {
        guard !intervals.isEmpty else { return [] }
        // Sorted here rather than trusted: callers pass store queries, test fixtures and merged
        // multi-device sets, and a single out-of-order row would otherwise split one run into three.
        let sorted = intervals.sorted { $0.start < $1.start }

        /// A run being built. Kept mutable rather than rebuilt so a long day is one pass.
        struct Building {
            var ids: [Int64] = []
            var start: Date
            var end: Date
            var work: TimeInterval = 0
            var projects: [Int64] = []
        }
        var open: [Int64: Building] = [:]        // keyed by task, or by 0 when tasks are ignored
        var done: [WorkRun] = []

        func close(_ key: Int64) {
            guard let b = open.removeValue(forKey: key) else { return }
            done.append(WorkRun(intervalIDs: b.ids, start: b.start, end: b.end,
                                workSeconds: b.work, projectIDs: b.projects))
        }

        for interval in sorted {
            let end = interval.end ?? now
            let seconds = end.timeIntervalSince(interval.start)
            // A zero or negative row contributes nothing and must not be allowed to extend a run's
            // end backwards. Overlaps can't occur in real data (the one-timer invariant) but do occur
            // in the 18 known cross-device races, and a fixture can always be wrong.
            guard seconds > 0 else { continue }
            let key = perTask ? interval.projectID : 0

            if var b = open[key] {
                if interval.start.timeIntervalSince(b.end) <= gap {
                    b.ids.append(interval.id)
                    b.end = max(b.end, end)
                    b.work += seconds
                    if !b.projects.contains(interval.projectID) { b.projects.append(interval.projectID) }
                    open[key] = b
                    continue
                }
                close(key)
            }
            open[key] = Building(ids: [interval.id], start: interval.start, end: end,
                                 work: seconds, projects: [interval.projectID])
        }
        for key in open.keys { close(key) }
        return done.sorted { $0.start < $1.start }
    }

    /// Which intervals belong to a run long enough to count as focused.
    ///
    /// A set of ids rather than a recomputation per interval, so the five aggregation functions can
    /// keep their single pass over intervals and can't disagree with each other about the same day —
    /// the same reason `Aggregations.isDeepBlock` was centralised in the first place.
    public static func deepIntervalIDs(_ intervals: [Interval], focus: FocusRule,
                                       now: Date = Date()) -> Set<Int64> {
        var ids = Set<Int64>()
        for run in runs(intervals, gap: focus.blendSeconds, perTask: true, now: now)
        where Aggregations.isDeepBlock(duration: run.workSeconds, threshold: focus.deepSeconds) {
            ids.formUnion(run.intervalIDs)
        }
        return ids
    }

    /// The run in progress right now, or nil if the last interval ended longer than `gap` ago.
    ///
    /// This is what the "still working?" clock and the break counter measure, and deriving it from the
    /// rows rather than counting in memory is deliberate: it survives a restart, a crash and a resync,
    /// it picks up work another device recorded once that syncs, and it stays right when intervals are
    /// corrected after the fact.
    public static func current(_ intervals: [Interval], gap: TimeInterval, perTask: Bool,
                               now: Date = Date()) -> WorkRun? {
        runs(intervals, gap: gap, perTask: perTask, now: now)
            .filter { now.timeIntervalSince($0.end) <= gap }
            .max { $0.end < $1.end }
    }

    /// Seconds worked in the current run, counting only what falls at or after `since`.
    ///
    /// `since` is how the counters avoid re-firing forever. Answering "still working?" bridges the
    /// checkpoint's own pause, so the run start reverts to the original start and the clock would be
    /// over threshold again on the next tick; flooring at the moment you answered is what stops that.
    /// The break counter uses the same shape for a rest taken and for a snooze.
    public static func workedSeconds(_ intervals: [Interval], gap: TimeInterval, perTask: Bool,
                                     since: Date?, now: Date = Date()) -> TimeInterval {
        guard let run = current(intervals, gap: gap, perTask: perTask, now: now) else { return 0 }
        guard let since, since > run.start else { return run.workSeconds }
        // Re-measure the run's own intervals from the floor rather than subtracting elapsed wall time:
        // the gaps aren't work, so subtracting `since - run.start` would over-credit every pause.
        let ids = Set(run.intervalIDs)
        var total: TimeInterval = 0
        for interval in intervals where ids.contains(interval.id) {
            let end = interval.end ?? now
            let start = max(interval.start, since)
            if end > start { total += end.timeIntervalSince(start) }
        }
        return total
    }
}
