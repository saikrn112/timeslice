import Foundation

/// Something that claims hours before any allocation gets a look in.
///
/// Declared rather than derived, and that is a finding rather than a preference: tracked time
/// averages about five hours of a sixteen-hour day, so the other eleven — meals, commute, getting
/// ready, everything that never becomes a task — is invisible to the database. A planner that
/// inferred "free time" from what was tracked would believe a Tuesday has ten hours spare when its
/// allocations already ask for fourteen.
public struct Reservation: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    /// Which days it claims. Reuses the allocation bitmask, so the bubbles, the day counting and the
    /// "none selected means every day" rule are the ones already written and tested.
    public let weekdays: Weekdays
    public let secondsPerDay: TimeInterval

    public init(id: Int64, name: String, weekdays: Weekdays = .all,
                secondsPerDay: TimeInterval) {
        self.id = id
        self.name = name
        self.weekdays = weekdays
        self.secondsPerDay = secondsPerDay
    }

    public func claims(weekday: Int) -> Bool { weekdays.effective.contains(weekday: weekday) }
}

/// Whether a week's intentions can coexist, where each of them lands, and what to change when they
/// can't.
///
/// Pure: no store, no dates beyond a weekday index, no UI. The arithmetic IS the feature, so it all
/// has to be reachable from the test harness.
///
/// ## Why the answer is a range and not a number
///
/// Allocations overlap by design — a tag covers work a project allocation also covers — so their
/// totals cannot simply be added. Finding the true minimum over arbitrary overlapping sets is a
/// linear program, and there is no solver here. So two honest ends are reported instead of one
/// invented middle:
///
/// * `requiredLowerSeconds` — the largest mutually **disjoint** subfamily. Each of those needs its
///   own hours, so the week cannot be done in less. If this exceeds capacity, it is oversubscribed
///   whatever the overlap, and that verdict is safe to state plainly.
/// * `requiredUpperSeconds` — the naive sum, which is what would be needed if no overlap were
///   exploited at all.
///
/// Capacity above the upper bound means it certainly fits. Between the two, it depends on how much
/// double duty the shared work really does, and saying so is more useful than picking a side.
public struct Planner: Sendable {

    // MARK: - Inputs

    public struct Input: Sendable {
        public let targets: [Target]
        public let reservations: [Reservation]
        public let membership: SubjectMembership
        /// Display name per target id — resolved by the caller, which already does this for the
        /// allocation rows (`BudgetRows.subjectName`).
        public let names: [Int64: String]
        /// From `AppSettings.wakingHours`, so the envelope is the user's, not a constant.
        public let wakingSecondsPerDay: TimeInterval

        public init(targets: [Target], reservations: [Reservation],
                    membership: SubjectMembership, names: [Int64: String],
                    wakingSecondsPerDay: TimeInterval) {
            self.targets = targets
            self.reservations = reservations
            self.membership = membership
            self.names = names
            self.wakingSecondsPerDay = wakingSecondsPerDay
        }
    }

    // MARK: - Outputs

    public struct Placement: Sendable, Hashable {
        public let targetID: Int64
        public let name: String
        public let seconds: TimeInterval
    }

    public struct DayPlan: Sendable {
        /// `Calendar`'s numbering, Sunday = 1, to match `Weekdays`.
        public let weekday: Int
        public let capacitySeconds: TimeInterval
        public let reservedSeconds: TimeInterval
        public let placements: [Placement]

        public var committedSeconds: TimeInterval { placements.reduce(0) { $0 + $1.seconds } }
        /// Negative when the day is over capacity, which is the whole point of showing it.
        public var slackSeconds: TimeInterval {
            capacitySeconds - reservedSeconds - committedSeconds
        }
        public var isOverCapacity: Bool { slackSeconds < -0.5 }
        /// Hours available to an allocation that hasn't been placed yet.
        public var freeSeconds: TimeInterval { max(0, slackSeconds) }
    }

    public enum Reason: Sendable, Equatable {
        /// The days it claims have no room left.
        case noSlack
        /// The requested shape can't hold on every claimed day, even though the total might fit.
        case shapeImpossible
        /// It claims too few days to hold its own total.
        case weekdaysTooNarrow
    }

    public struct Unplaced: Sendable {
        public let targetID: Int64
        public let name: String
        public let shortfallSeconds: TimeInterval
        public let reason: Reason
        /// The smallest change that would make it fit, in words. Computed, not guessed — see
        /// `largestFeasibleEveryDayMinimum` and `frontier`.
        public let wouldFitIf: String
    }

    public enum Verdict: Sendable, Equatable {
        /// Even the naive sum fits.
        case fits
        /// It fits, with little to absorb a bad day.
        case tight
        /// Even the disjoint lower bound doesn't fit. True whatever the overlap.
        case oversubscribed
        /// Capacity sits between the bounds: it depends on how much the overlapping work shares.
        case uncertain
    }

    /// One allocation entirely inside another, so its hours are already counted there. Worth naming
    /// in the UI: it looks like a separate commitment and isn't.
    public struct Nesting: Sendable {
        public let innerName: String
        public let outerName: String
        public let innerSeconds: TimeInterval
        public let outerSeconds: TimeInterval
    }

    public let days: [DayPlan]
    public let unplaced: [Unplaced]
    public let requiredLowerSeconds: TimeInterval
    public let requiredUpperSeconds: TimeInterval
    public let reservedSeconds: TimeInterval
    public let capacitySeconds: TimeInterval
    public let verdict: Verdict
    /// `atMost` allocations. Listed, never counted: a ceiling is permission to stop, not work to do.
    public let ceilings: [Target]
    public let nestings: [Nesting]

    // MARK: - Building

    public static func plan(_ input: Input) -> Planner {
        let floors = input.targets.filter { $0.direction == .atLeast }
        let ceilings = input.targets.filter { $0.direction == .atMost }

        // Every day of the week, with its reservations already taken.
        var days: [DayPlan] = (1...7).map { weekday in
            let reserved = input.reservations
                .filter { $0.claims(weekday: weekday) }
                .reduce(0.0) { $0 + $1.secondsPerDay }
            return DayPlan(weekday: weekday,
                           capacitySeconds: input.wakingSecondsPerDay,
                           // Capped: a day cannot be more than fully reserved, and letting it go
                           // further would hide the mistake inside a negative slack figure that
                           // reads like an allocation problem.
                           reservedSeconds: min(reserved, input.wakingSecondsPerDay),
                           placements: [])
        }

        var unplaced: [Unplaced] = []

        // Ordered by how constrained each one is, so the tightest claims first. Placing a flexible
        // allocation before a daily habit would let it take the very hour the habit needed.
        let ordered = floors.sorted { a, b in
            let rank = { (t: Target) -> Int in
                switch t.shape {
                case .everyDay: return 0
                case .sessions: return 1
                case .flexible: return 2
                }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            // Then the biggest first: a large allocation has the fewest ways to fit.
            if a.weeklySeconds != b.weeklySeconds { return a.weeklySeconds > b.weeklySeconds }
            return a.id < b.id      // deterministic, so the same week always plans the same way
        }

        for target in ordered {
            let name = input.names[target.id] ?? "allocation"
            let result = place(target, name: name, into: &days)
            if let problem = result { unplaced.append(problem) }
        }

        let (lower, upper) = bounds(floors: floors, membership: input.membership)
        let capacity = input.wakingSecondsPerDay * 7
        let reserved = days.reduce(0.0) { $0 + $1.reservedSeconds }
        let free = max(0, capacity - reserved)

        let verdict: Verdict
        if lower > free { verdict = .oversubscribed }
        else if upper > free { verdict = .uncertain }
        // "Tight" is a tenth of the week — about a day and a half of waking hours — with nothing
        // spare. Anything less than that absorbs no surprises at all.
        else if free - upper < capacity * 0.1 { verdict = .tight }
        else { verdict = .fits }

        return Planner(days: days, unplaced: unplaced,
                       requiredLowerSeconds: lower, requiredUpperSeconds: upper,
                       reservedSeconds: reserved, capacitySeconds: capacity,
                       verdict: verdict, ceilings: ceilings,
                       nestings: nestings(floors: floors, input: input))
    }

    // MARK: - Placement

    /// Put one allocation into the week, returning why it couldn't fit if it couldn't.
    private static func place(_ target: Target, name: String,
                              into days: inout [DayPlan]) -> Unplaced? {
        let claimed = (1...7).filter { target.weekdays.effective.contains(weekday: $0) }
        var remaining = target.weeklySeconds
        guard remaining > 0 else { return nil }

        switch target.shape {
        case .everyDay(let minPerDay):
            // The habit case, and the one that fails most informatively. Every claimed day must take
            // the minimum; if one can't, the habit is impossible even when the weekly total would
            // have fitted elsewhere — which is exactly the "I can't do an hour of research every
            // day" question.
            let short = claimed.filter { dayIndex(of: $0, days).map { days[$0].freeSeconds } ?? 0
                                          < minPerDay }
            if !short.isEmpty {
                let best = largestFeasibleEveryDayMinimum(claimed: claimed, days: days)
                let fits = claimed.count - short.count
                return Unplaced(
                    targetID: target.id, name: name,
                    shortfallSeconds: Double(short.count) * minPerDay,
                    reason: .shapeImpossible,
                    wouldFitIf: best > 0
                        ? "\(hoursText(best))/day instead of \(hoursText(minPerDay))/day "
                          + "— it fits on \(fits) of \(claimed.count) days as asked"
                        : "some of the day were freed up: \(fits) of \(claimed.count) days can take it")
            }
            for weekday in claimed {
                guard let i = dayIndex(of: weekday, days) else { continue }
                let take = min(minPerDay, days[i].freeSeconds)
                days[i] = adding(take, of: target, name: name, to: days[i])
                remaining -= take
            }
            // The rest of the total spreads flexibly over the same days.
            remaining = fill(remaining, of: target, name: name, over: claimed, in: &days)
            return remaining > 60
                ? Unplaced(targetID: target.id, name: name, shortfallSeconds: remaining,
                           reason: .noSlack,
                           wouldFitIf: "the weekly total were \(hoursText(target.weeklySeconds - remaining))")
                : nil

        case .sessions(let count, let minLength):
            // Sessions want unbroken room, so they go to the days with the most left — a three-hour
            // session split into six halves is not the thing that was asked for.
            guard Double(count) * minLength <= target.weeklySeconds + 1 else {
                return Unplaced(targetID: target.id, name: name,
                                shortfallSeconds: Double(count) * minLength - target.weeklySeconds,
                                reason: .shapeImpossible,
                                wouldFitIf: "the total were at least "
                                          + hoursText(Double(count) * minLength)
                                          + " for \(count) sessions of \(hoursText(minLength))")
            }
            var placedSessions = 0
            for _ in 0..<count {
                let candidates = claimed.compactMap { dayIndex(of: $0, days) }
                    .filter { days[$0].freeSeconds >= minLength }
                    .sorted { days[$0].freeSeconds > days[$1].freeSeconds }
                guard let i = candidates.first else { break }
                days[i] = adding(minLength, of: target, name: name, to: days[i])
                remaining -= minLength
                placedSessions += 1
            }
            if placedSessions < count {
                let missing = count - placedSessions
                return Unplaced(targetID: target.id, name: name,
                                shortfallSeconds: Double(missing) * minLength,
                                reason: .noSlack,
                                wouldFitIf: "there were \(missing) more day(s) with "
                                          + "\(hoursText(minLength)) free, or the sessions were shorter")
            }
            remaining = fill(remaining, of: target, name: name, over: claimed, in: &days)
            return remaining > 60
                ? Unplaced(targetID: target.id, name: name, shortfallSeconds: remaining,
                           reason: .noSlack,
                           wouldFitIf: "the weekly total were \(hoursText(target.weeklySeconds - remaining))")
                : nil

        case .flexible:
            // Narrow weekdays can make a total impossible on its own, before any competition: 20h
            // over one day cannot fit in a 16h day however empty the week is.
            let ceiling = Double(claimed.count) * days.first!.capacitySeconds
            if target.weeklySeconds > ceiling + 1 {
                return Unplaced(targetID: target.id, name: name,
                                shortfallSeconds: target.weeklySeconds - ceiling,
                                reason: .weekdaysTooNarrow,
                                wouldFitIf: "it claimed more days — \(claimed.count) day(s) hold at "
                                          + "most \(hoursText(ceiling))")
            }
            remaining = fill(remaining, of: target, name: name, over: claimed, in: &days)
            return remaining > 60
                ? Unplaced(targetID: target.id, name: name, shortfallSeconds: remaining,
                           reason: .noSlack,
                           wouldFitIf: "the weekly total were \(hoursText(target.weeklySeconds - remaining))")
                : nil
        }
    }

    /// Spread `seconds` over the claimed days, returning what wouldn't fit.
    ///
    /// Fills the EMPTIEST day first, which concentrates rather than scatters: it keeps long unbroken
    /// runs available instead of leaving every day with a fragment. That follows the app's own
    /// measure — it counts focus blocks of thirty minutes or more, so a planner that shredded work
    /// into ten-minute pieces would be planning for the thing the metrics call bad.
    private static func fill(_ seconds: TimeInterval, of target: Target, name: String,
                             over claimed: [Int], in days: inout [DayPlan]) -> TimeInterval {
        var remaining = seconds
        while remaining > 60 {
            let candidates = claimed.compactMap { dayIndex(of: $0, days) }
                .filter { days[$0].freeSeconds > 60 }
                .sorted { days[$0].freeSeconds > days[$1].freeSeconds }
            guard let i = candidates.first else { break }
            let take = min(remaining, days[i].freeSeconds)
            days[i] = adding(take, of: target, name: name, to: days[i])
            remaining -= take
        }
        return max(0, remaining)
    }

    private static func adding(_ seconds: TimeInterval, of target: Target, name: String,
                               to day: DayPlan) -> DayPlan {
        guard seconds > 0 else { return day }
        var placements = day.placements
        // One row per allocation per day: a day that takes an allocation twice (its habit minimum
        // and then some of the remainder) should read as one figure, not two.
        if let i = placements.firstIndex(where: { $0.targetID == target.id }) {
            placements[i] = Placement(targetID: target.id, name: name,
                                      seconds: placements[i].seconds + seconds)
        } else {
            placements.append(Placement(targetID: target.id, name: name, seconds: seconds))
        }
        return DayPlan(weekday: day.weekday, capacitySeconds: day.capacitySeconds,
                       reservedSeconds: day.reservedSeconds, placements: placements)
    }

    private static func dayIndex(of weekday: Int, _ days: [DayPlan]) -> Int? {
        days.firstIndex { $0.weekday == weekday }
    }

    /// The biggest per-day habit that every claimed day could actually take.
    ///
    /// Answers "an hour a day doesn't fit — what does?" with a number rather than a shrug. It's the
    /// minimum free time across the claimed days, because a habit is only as strong as its worst day.
    public static func largestFeasibleEveryDayMinimum(claimed: [Int], days: [DayPlan]) -> TimeInterval {
        let frees = claimed.compactMap { dayIndex(of: $0, days).map { days[$0].freeSeconds } }
        return frees.min() ?? 0
    }

    // MARK: - Bounds

    /// Lower bound: the largest mutually disjoint subfamily. Upper bound: the naive sum.
    ///
    /// Greedy by size, which is what makes the lower bound worth having — taking the biggest floor
    /// first tends to produce the largest disjoint family, and any disjoint family is a valid lower
    /// bound whether or not it is the largest.
    public static func bounds(floors: [Target], membership: SubjectMembership)
        -> (lower: TimeInterval, upper: TimeInterval) {
        let upper = floors.reduce(0.0) { $0 + $1.weeklySeconds }
        var chosen: [Target] = []
        for target in floors.sorted(by: { ($0.weeklySeconds, -Double($0.id)) >
                                          ($1.weeklySeconds, -Double($1.id)) }) {
            let clashes = chosen.contains { membership.relation(target.subject, $0.subject) != .disjoint }
            if !clashes { chosen.append(target) }
        }
        return (chosen.reduce(0.0) { $0 + $1.weeklySeconds }, upper)
    }

    /// Allocations wholly inside another, whose hours are therefore already counted.
    public static func nestings(floors: [Target], input: Input) -> [Nesting] {
        var out: [Nesting] = []
        for inner in floors {
            for outer in floors where inner.id != outer.id {
                if membershipRelation(inner, outer, input) == .containedIn {
                    out.append(Nesting(
                        innerName: input.names[inner.id] ?? "allocation",
                        outerName: input.names[outer.id] ?? "allocation",
                        innerSeconds: inner.weeklySeconds,
                        outerSeconds: outer.weeklySeconds))
                }
            }
        }
        return out
    }

    private static func membershipRelation(_ a: Target, _ b: Target,
                                           _ input: Input) -> SubjectMembership.Relation {
        input.membership.relation(a.subject, b.subject)
    }

    // MARK: - Frontier

    /// The most this allocation could ask for while everything else holds.
    ///
    /// Bisected through the very same planner, so the ceiling it reports and the verdict the planner
    /// gives can never disagree — a separately-derived formula would eventually drift from the packer
    /// and tell the user a number that doesn't work.
    public static func frontier(for targetID: Int64, in input: Input,
                                stepSeconds: TimeInterval = 900) -> TimeInterval {
        guard let subject = input.targets.first(where: { $0.id == targetID }) else { return 0 }
        let others = input.targets.filter { $0.id != targetID }

        func fits(_ seconds: TimeInterval) -> Bool {
            let candidate = subject.withWeeklySeconds(seconds)
            let trial = Input(targets: others + [candidate], reservations: input.reservations,
                              membership: input.membership, names: input.names,
                              wakingSecondsPerDay: input.wakingSecondsPerDay)
            return !plan(trial).unplaced.contains { $0.targetID == targetID }
        }

        guard fits(stepSeconds) else { return 0 }
        var low = stepSeconds
        var high = input.wakingSecondsPerDay * 7
        while high - low > stepSeconds {
            let mid = ((low + high) / 2 / stepSeconds).rounded() * stepSeconds
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
    }
}

// MARK: - Normalising a period onto a week

public extension Target {
    /// The allocation's total expressed as a week, so day, week and month allocations can be added
    /// to each other at all. Uses the same nominal month as the rest of the app.
    var weeklySeconds: TimeInterval {
        switch period {
        case .day:
            // A daily floor is per CLAIMED day, so a weekday-only daily floor is five of them, not
            // seven. Ignoring the mask here was the difference between 35h and 49h.
            return seconds * Double(max(1, weekdays.effective.selectedCount))
        case .week:
            return seconds
        case .month:
            return seconds / Target.Period.month.nominalDays * 7
        }
    }

    /// A copy asking for a different weekly total, used by the frontier search.
    func withWeeklySeconds(_ weekly: TimeInterval) -> Target {
        let scaled: TimeInterval
        switch period {
        case .day: scaled = weekly / Double(max(1, weekdays.effective.selectedCount))
        case .week: scaled = weekly
        case .month: scaled = weekly / 7 * Target.Period.month.nominalDays
        }
        return Target(id: id, subject: subject, seconds: scaled, direction: direction,
                      period: period, createdAt: createdAt, completedAt: completedAt,
                      sortOrder: sortOrder, weekdays: weekdays, shape: shape)
    }
}

/// Hours, for the "would fit if" sentences. Deliberately coarse — the planner deals in hour-slabs,
/// so a suggestion of "0.42h/day" would imply a precision the whole model doesn't have.
private func hoursText(_ seconds: TimeInterval) -> String {
    let hours = seconds / 3600
    if hours >= 1 { return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours) }
    return "\(Int((seconds / 60).rounded()))m"
}
