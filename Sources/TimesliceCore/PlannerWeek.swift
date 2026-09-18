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

    /// Whether a day's column draws PLAN blocks — the dashed "this day wants" bands — as opposed to only
    /// what was recorded.
    ///
    /// A finished week draws none, whatever the method. There is nothing left to reallocate into once a
    /// week is over, so a dashed "Monday wants 6.7h of office" is invented hindsight: it says the hours
    /// would have gone somewhere they demonstrably didn't. What a past week owes belongs below the columns,
    /// where `neverHappened` puts it.
    public static func drawsPlanBlocks(offset: Int, dayIsBeforeToday: Bool,
                                      showIntended: Bool) -> Bool {
        if showIntended { return false }
        if offset > 0 { return false }
        return !dayIsBeforeToday
    }

    /// What a finished week never did: per allocation, the hours it wanted and didn't get, filed under the
    /// last weekday it claimed — the day its chance ran out.
    ///
    /// Deliberately not a scheduling result. A past week has no room left to search for, so this is plain
    /// arithmetic on what the allocation asked for against what it was credited.
    public static func neverHappened(floors: [Target], credited: [Int64: TimeInterval],
                                     nested: Set<Int64> = [], weeks: Double = 1)
    -> [(id: Int64, missed: TimeInterval, lastDay: Int)] {
        var out: [(id: Int64, missed: TimeInterval, lastDay: Int)] = []
        for target in floors
        where target.direction == .atLeast && !nested.contains(target.id) {
            let missed = max(0, target.weeklySeconds * weeks - (credited[target.id] ?? 0))
            guard missed > 60 else { continue }
            guard let lastDay = (1...7).last(where: {
                target.weekdays.effective.contains(weekday: $0)
            }) else { continue }
            out.append((target.id, missed, lastDay))
        }
        return out.sorted { $0.missed > $1.missed }
    }
}
