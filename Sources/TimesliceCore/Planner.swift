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
    /// Weekdays asking for more than they hold. The reason a week can total fine and still be
    /// impossible, so it's a first-class output rather than something the view has to notice.
    public let overloadedDays: [Int]

    // MARK: - Building

    public static func plan(_ input: Input) -> Planner {
        let allFloors = input.targets.filter { $0.direction == .atLeast }
        let ceilings = input.targets.filter { $0.direction == .atMost }
        let nestings = nestings(floors: allFloors, input: input)

        // An allocation entirely inside another asks for nothing extra: its hours are already part of
        // the parent's total. Letting it claim capacity of its own double-counted the same work and
        // then reported the child as "won't fit" — a contradiction, since the page also said its hours
        // were already counted. It's still listed, just not charged for twice.
        let nestedIDs = Set(allFloors.filter { inner in
            allFloors.contains { outer in
                inner.id != outer.id
                    && input.membership.relation(inner.subject, outer.subject) == .containedIn
            }
        }.map(\.id))
        let floors = allFloors.filter { !nestedIDs.contains($0.id) }

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

        // Each allocation spread EVENLY over the days it claims, rather than packed greedily into
        // whichever day happened to be emptiest.
        //
        // The greedy packer produced answers like "office: 16h on Monday, 16h on Tuesday, 3h on
        // Wednesday" — arithmetically valid, and not a plan anyone would follow. Worse, it replaced
        // the one figure that reads at a glance ("Tuesday is asking for 14 hours") with an arbitrary
        // schedule. An even spread is deterministic, explainable in one sentence, and is what the
        // question "is Tuesday possible?" actually needs.
        for target in floors.sorted(by: { ($0.weeklySeconds, -Double($0.id)) >
                                          ($1.weeklySeconds, -Double($1.id)) }) {
            let name = input.names[target.id] ?? "allocation"
            let claimed = (1...7).filter { target.weekdays.effective.contains(weekday: $0) }
            guard !claimed.isEmpty else { continue }
            let perDay = target.weeklySeconds / Double(claimed.count)
            for weekday in claimed {
                guard let i = days.firstIndex(where: { $0.weekday == weekday }) else { continue }
                days[i] = adding(perDay, of: target, name: name, to: days[i])
            }
        }

        // What can't work, judged per allocation against the load — no packing involved.
        let unplaced = problems(floors: floors, days: days, input: input)

        let (lower, upper) = bounds(floors: floors, membership: input.membership)
        let capacity = input.wakingSecondsPerDay * 7
        let reserved = days.reduce(0.0) { $0 + $1.reservedSeconds }
        let free = max(0, capacity - reserved)

        // A week can total comfortably and still be impossible, because weekday restrictions pile
        // onto particular days. The first version only compared totals and cheerfully said "fits"
        // while Monday and Tuesday were both at 16 of 16 hours.
        let overDays = days.filter(\.isOverCapacity)

        let verdict: Verdict
        if lower > free || !overDays.isEmpty { verdict = .oversubscribed }
        else if upper > free { verdict = .uncertain }
        // "Tight" is a tenth of the week — about a day and a half of waking hours — with nothing
        // spare. Anything less than that absorbs no surprises at all.
        else if free - upper < capacity * 0.1 || days.contains(where: { $0.freeSeconds < 3600 }) {
            verdict = .tight
        }
        else { verdict = .fits }

        return Planner(days: days, unplaced: unplaced,
                       requiredLowerSeconds: lower, requiredUpperSeconds: upper,
                       reservedSeconds: reserved, capacitySeconds: capacity,
                       verdict: verdict, ceilings: ceilings, nestings: nestings,
                       overloadedDays: overDays.map(\.weekday))
    }

    // MARK: - Placement

    /// What can't work, judged per allocation against the day loads.
    ///
    /// No packing: each allocation is asked three answerable questions, and every failure names a
    /// specific change. The greedy version could only ever say "there was no room left by the time I
    /// got here", which depended on the order it happened to try things and produced sentences like
    /// "would fit if the weekly total were 0m".
    static func problems(floors: [Target], days: [DayPlan], input: Input) -> [Unplaced] {
        var out: [Unplaced] = []
        for target in floors {
            let name = input.names[target.id] ?? "allocation"
            let claimed = (1...7).filter { target.weekdays.effective.contains(weekday: $0) }
            guard !claimed.isEmpty, target.weeklySeconds > 0 else { continue }
            let perDay = target.weeklySeconds / Double(claimed.count)
            let dayFor = { (w: Int) in days.first { $0.weekday == w } }

            // 1. Can its own days hold its own total, before anything else competes?
            let ownCeiling = Double(claimed.count) * input.wakingSecondsPerDay
            if target.weeklySeconds > ownCeiling + 1 {
                out.append(Unplaced(
                    targetID: target.id, name: name,
                    shortfallSeconds: target.weeklySeconds - ownCeiling,
                    reason: .weekdaysTooNarrow,
                    wouldFitIf: "it claimed more days — \(claimed.count) day(s) hold at most "
                              + hoursText(ownCeiling)))
                continue
            }

            // How much of a day is available to THIS allocation: everything except what other things
            // have already claimed. Deliberately not `freeSeconds`, which clamps at zero — on a day
            // already over capacity that clamp reported the allocation's own share back to it as
            // room, and a habit that plainly could not fit was passed as fine.
            let roomFor = { (day: DayPlan) -> TimeInterval in
                let mine = day.placements.first { $0.targetID == target.id }?.seconds ?? 0
                return day.capacitySeconds - day.reservedSeconds - (day.committedSeconds - mine)
            }

            // 2. If it wants to be a habit, can every claimed day take the daily minimum? Checked
            //    BEFORE the general overload below, because it is the more specific diagnosis and the
            //    question that started this feature: 7h a week is not 1h a day if Tuesday has no hour.
            if case .everyDay(let minPerDay) = target.shape {
                let rooms = claimed.compactMap { dayFor($0).map(roomFor) }
                let short = rooms.filter { $0 < minPerDay - 1 }.count
                if short > 0, let smallest = rooms.min() {
                    out.append(Unplaced(
                        targetID: target.id, name: name,
                        shortfallSeconds: Double(short) * minPerDay,
                        reason: .shapeImpossible,
                        wouldFitIf: smallest > 60
                            ? "the daily minimum were \(hoursText(smallest)) instead of "
                              + "\(hoursText(minPerDay)) — it fits as asked on "
                              + "\(claimed.count - short) of \(claimed.count) days"
                            : "some of those days were freed up — "
                              + "\(claimed.count - short) of \(claimed.count) can take it"))
                    continue
                }
            }

            // 3. Sessions: the total has to cover them, and enough days must have an unbroken run
            //    that long. Without the second half, "2 × 3h" would pass on days with 90 minutes each.
            if case .sessions(let count, let minLength) = target.shape {
                if Double(count) * minLength > target.weeklySeconds + 1 {
                    out.append(Unplaced(
                        targetID: target.id, name: name,
                        shortfallSeconds: Double(count) * minLength - target.weeklySeconds,
                        reason: .shapeImpossible,
                        wouldFitIf: "the total were at least \(hoursText(Double(count) * minLength)) for "
                                  + "\(count) sessions of \(hoursText(minLength))"))
                    continue
                }
                let roomyDays = claimed.compactMap { dayFor($0).map(roomFor) }
                    .filter { $0 >= minLength - 1 }.count
                if roomyDays < count {
                    out.append(Unplaced(
                        targetID: target.id, name: name,
                        shortfallSeconds: Double(count - roomyDays) * minLength,
                        reason: .shapeImpossible,
                        wouldFitIf: "\(count) of its days had \(hoursText(minLength)) free — only "
                                  + "\(roomyDays) do, so the sessions would have to be shorter or "
                                  + "fewer"))
                    continue
                }
            }

            // 4. Otherwise: are the days it claims over capacity at all? Reported against the worst
            //    one, because that is the day to fix.
            let overloaded = claimed.compactMap { dayFor($0) }.filter(\.isOverCapacity)
            if let worst = overloaded.max(by: { -$0.slackSeconds < -$1.slackSeconds }) {
                let excess = -worst.slackSeconds
                out.append(Unplaced(
                    targetID: target.id, name: name,
                    shortfallSeconds: min(excess, perDay),
                    reason: .noSlack,
                    wouldFitIf: "\(dayName(worst.weekday)) gave up \(hoursText(excess)) — it is asking "
                              + "for \(hoursText(worst.reservedSeconds + worst.committedSeconds)) of "
                              + "\(hoursText(worst.capacitySeconds))"))
            }
        }
        return out
    }

    /// The biggest per-day habit every claimed day could take, alongside everything else on it.
    public static func largestFeasibleEveryDayMinimum(claimed: [Int], days: [DayPlan]) -> TimeInterval {
        let frees = claimed.compactMap { w in days.first { $0.weekday == w }?.freeSeconds }
        return frees.min() ?? 0
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
        case .once:
            // A one-off has no rate. Its weekly equivalent is its total spread over the weeks its window
            // spans, which keeps figures that sum `weeklySeconds` roughly honest rather than reading zero;
            // anything that needs the exact ask for a period must call `ask(in:)`.
            guard let window = dayWindow else { return 0 }
            let days = max(1, window.end.timeIntervalSince(window.start) / 86_400)
            return seconds / days * 7
        }
    }

    /// A copy asking for a different weekly total, used by the frontier search.
    func withWeeklySeconds(_ weekly: TimeInterval) -> Target {
        let scaled: TimeInterval
        switch period {
        case .day: scaled = weekly / Double(max(1, weekdays.effective.selectedCount))
        case .week: scaled = weekly
        case .month: scaled = weekly / 7 * Target.Period.month.nominalDays
        case .once:
            // The frontier asks "how big could this be?" — for a one-off that's its total, and the window
            // is what it's spread over, so the weekly figure scales back through the same window length.
            let days = dayWindow.map { max(1, $0.end.timeIntervalSince($0.start) / 86_400) } ?? 7
            scaled = weekly / 7 * days
        }
        return Target(id: id, subject: subject, seconds: scaled, direction: direction,
                      period: period, createdAt: createdAt, completedAt: completedAt,
                      sortOrder: sortOrder, weekdays: weekdays, shape: shape,
                      startsOn: startsOn, endsOn: endsOn)
    }
}

/// Sunday-first, matching `Weekdays`' bit order.
private func dayName(_ weekday: Int) -> String {
    ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][
        max(0, min(6, weekday - 1))]
}

/// Hours, for the "would fit if" sentences. Deliberately coarse — the planner deals in hour-slabs,
/// so a suggestion of "0.42h/day" would imply a precision the whole model doesn't have.
private func hoursText(_ seconds: TimeInterval) -> String {
    let hours = seconds / 3600
    if hours >= 1 { return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours) }
    return "\(Int((seconds / 60).rounded()))m"
}
