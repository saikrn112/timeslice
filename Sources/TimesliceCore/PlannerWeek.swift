import Foundation

/// What actually happened in a window, arranged per weekday and per allocation.
///
/// This existed twice in the planner view — once for the current week, once for whichever week you had
/// browsed to — and the copies drifted, which is exactly the bug you'd expect: the past week's columns were
/// drawn from the past week's intervals while the SCHEDULER was still being fed the current week's, so a
/// finished week reported 25h of office as unplaceable while every one of its days showed hours free.
///
/// One function, in Core, with tests. Two figures come out of it because two different questions need them:
///
/// - **primary** — each hour attributed to exactly ONE allocation, the narrowest covering it, so a day's
///   blocks can never sum past the day.
/// - **credited** — each hour counted for EVERY allocation covering it, because an hour of kvcache is
///   genuine progress on both vllm and office, and what an allocation still owes has to be measured against
///   all of it.
public enum PlannerWeek {
    public struct DayFacts: Sendable, Equatable {
        /// Allocation → seconds, each second counted once under its narrowest owner.
        public var primary: [Int64: TimeInterval] = [:]
        /// Allocation → seconds, each second counted for every allocation covering it.
        public var credited: [Int64: TimeInterval] = [:]
        /// Seconds against tasks no allocation covers.
        public var unallocated: TimeInterval = 0
        /// Allocation (or -2 for unallocated) → task name → seconds, for tooltips.
        public var breakdown: [Int64: [String: TimeInterval]] = [:]
        /// The tasks behind `unallocated`, for handing to the metrics page.
        public var uncoveredTaskIDs: Set<Int64> = []
        /// Everything tracked that day, whatever it was against.
        public var total: TimeInterval = 0

        public init() {}
    }

    /// - Parameters:
    ///   - window: only the part of an interval inside this is counted, so a session spanning midnight or a
    ///     week boundary is split rather than double-counted.
    ///   - nested: allocations wholly inside another. They still get CREDITED hours — a nested allocation you
    ///     worked is progress on itself — but never own an hour, because their blocks aren't drawn and the
    ///     hour would then be counted in the day's total and drawn nowhere.
    public static func facts(intervals: [Interval],
                             window: DateInterval,
                             floors: [Target],
                             membership: SubjectMembership,
                             nested: Set<Int64> = [],
                             taskNames: [Int64: String] = [:],
                             now: Date = Date(),
                             calendar: Calendar = .current) -> [Int: DayFacts] {
        let coverage = Dictionary(uniqueKeysWithValues:
            floors.map { ($0.id, membership.taskIDs(for: $0.subject)) })
        let ownable = Dictionary(uniqueKeysWithValues:
            floors.filter { !nested.contains($0.id) }.map { ($0.id, $0.subject) })

        var out: [Int: DayFacts] = [:]
        for interval in intervals {
            let start = max(interval.start, window.start)
            let end = min(interval.end ?? now, window.end)
            guard end > start else { continue }
            let seconds = end.timeIntervalSince(start)
            let weekday = calendar.component(.weekday, from: start)
            let name = taskNames[interval.projectID] ?? "?"

            var day = out[weekday] ?? DayFacts()
            day.total += seconds

            var covered = false
            for (id, ids) in coverage where ids.contains(interval.projectID) {
                day.credited[id, default: 0] += seconds
                covered = true
            }
            if let owner = membership.primaryOwner(of: interval.projectID, among: ownable) {
                day.primary[owner, default: 0] += seconds
                day.breakdown[owner, default: [:]][name, default: 0] += seconds
            }
            if !covered {
                day.unallocated += seconds
                day.breakdown[-2, default: [:]][name, default: 0] += seconds
                day.uncoveredTaskIDs.insert(interval.projectID)
            }
            out[weekday] = day
        }
        return out
    }

    /// Per allocation, seconds credited across the whole window — what a progress bar reads.
    public static func creditedTotals(_ facts: [Int: DayFacts]) -> [Int64: TimeInterval] {
        var out: [Int64: TimeInterval] = [:]
        for day in facts.values {
            for (id, seconds) in day.credited { out[id, default: 0] += seconds }
        }
        return out
    }

    /// The shape `Replan` wants: weekday → allocation → credited seconds.
    public static func creditedByWeekday(_ facts: [Int: DayFacts]) -> [Int: [Int64: TimeInterval]] {
        facts.mapValues { $0.credited }
    }
}
