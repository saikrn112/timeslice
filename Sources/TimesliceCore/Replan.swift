import Foundation

/// What's owed, and whether the rest of the period can still absorb it.
///
/// The planner answers "is this week possible at all". This answers the question that arrives on
/// Wednesday: **a day went differently, so is the week still recoverable, and where does the catch-up
/// have to go?**
///
/// The point is to say "already lost" early rather than on Sunday. A weekly floor that needs 6.2h a
/// day across the three days left, on days that have 5h free, is not going to happen — and knowing
/// that on Wednesday leaves a choice (cut it, move it, accept it), where knowing on Sunday leaves only
/// a fact.
///
/// Pure, like `Planner`: it takes the days still to come as weekday indices rather than working them
/// out from a calendar, so every branch is reachable from the test harness and no clock is involved.
public struct Replan: Sendable {

    /// Time already recorded against each allocation THIS period, keyed by target id. The caller
    /// computes it — the store and `SubjectMembership` already know how to attribute an interval to a
    /// subject, and duplicating that here would be a second answer to the same question.
    public typealias Actuals = [Int64: TimeInterval]

    public enum Standing: Sendable, Equatable {
        /// Done, or on course without needing more than a normal day.
        case onTrack
        /// Behind, but the days left can still hold what's owed.
        case recoverable
        /// The days left cannot hold what's owed, however they're arranged.
        case unreachable
        /// Nothing owed because the allocation is already met.
        case met
    }

    public struct Item: Sendable {
        public let targetID: Int64
        public let name: String
        /// What the allocation asks for over the whole period.
        public let targetSeconds: TimeInterval
        public let doneSeconds: TimeInterval
        /// What should have been done by now if it were spread evenly over its claimed days.
        public let expectedByNowSeconds: TimeInterval
        /// Negative when ahead. This is the backlog.
        public var debtSeconds: TimeInterval { max(0, expectedByNowSeconds - doneSeconds) }
        public var remainingSeconds: TimeInterval { max(0, targetSeconds - doneSeconds) }
        /// Claimed days still to come, today included.
        public let remainingClaimedDays: Int
        /// What the remaining days each have to carry to finish. Nil when there are none left.
        public let requiredPerRemainingDay: TimeInterval?
        /// The most those days could actually give it, everything else on them included.
        public let availableOnRemainingDays: TimeInterval
        public let standing: Standing
        /// What would have to change, when it can't be finished. Empty otherwise.
        public let adviceIfUnreachable: String
        /// What is taking the room on this allocation's remaining days, largest first.
        ///
        /// The answer to "why can't I finish this". "Behind by 3h" tells you the symptom; "office wants
        /// 28h of the same four days" tells you what to argue with. Without it the only honest advice
        /// is "do more", which is not advice.
        public let blockers: [Blocker]
        /// How much of the shortfall is simply the day being full versus the allocation being large.
        public var shortfallOnRemainingDays: TimeInterval {
            max(0, remainingSeconds - availableOnRemainingDays)
        }
    }

    /// Another allocation, or reserved time, competing for the same days.
    public struct Blocker: Sendable, Hashable {
        public let name: String
        /// Hours it claims on the days in question — not its weekly total, which would overstate its
        /// part in this particular problem.
        public let secondsOnThoseDays: TimeInterval
    }

    public let items: [Item]
    /// Total owed across every allocation, and what the rest of the period can hold.
    public let remainingNeedSeconds: TimeInterval
    public let remainingCapacitySeconds: TimeInterval
    /// Per remaining weekday: what it was already carrying, plus its share of the catch-up.
    public let replannedDays: [Planner.DayPlan]
    /// True when the week as a whole can no longer absorb what's left, whatever the per-allocation
    /// picture says.
    public var weekIsLost: Bool { remainingNeedSeconds > remainingCapacitySeconds + 60 }

    public var totalDebtSeconds: TimeInterval { items.reduce(0) { $0 + $1.debtSeconds } }
    public var unreachable: [Item] { items.filter { $0.standing == .unreachable } }
    public var behind: [Item] { items.filter { $0.standing == .recoverable } }

    /// - Parameters:
    ///   - plan: the week as planned, which supplies the day loads and capacities.
    ///   - actuals: seconds recorded against each allocation so far this period.
    ///   - elapsedWeekdays: days already gone, NOT including today — today is still workable.
    ///   - remainingWeekdays: today and the days after it, in order.
    ///   - fractionOfTodayLeft: how much of today's capacity is still available (1 = all of it). A
    ///     replan at 9pm that assumes a full day would say "recoverable" about an evening that has
    ///     already gone. See `fractionOfDayLeft` for how to derive it from a clock.
    public static func compute(plan: Planner, input: Planner.Input, actuals: Actuals,
                               elapsedWeekdays: [Int], remainingWeekdays: [Int],
                               fractionOfTodayLeft: Double = 1) -> Replan {
        let floors = input.targets.filter { $0.direction == .atLeast }

        /// A day's capacity for planning purposes, with today discounted to what's left of it.
        func usable(_ day: Planner.DayPlan) -> TimeInterval {
            let isToday = day.weekday == remainingWeekdays.first
            let free = max(0, day.slackSeconds)
            return isToday ? free * max(0, min(1, fractionOfTodayLeft)) : free
        }

        /// What an allocation could still take on a given day: the day's own free time plus whatever
        /// the plan had already set aside for this very allocation.
        func roomFor(_ target: Target, on day: Planner.DayPlan) -> TimeInterval {
            let mine = day.placements.first { $0.targetID == target.id }?.seconds ?? 0
            let raw = day.capacitySeconds - day.reservedSeconds - (day.committedSeconds - mine)
            let isToday = day.weekday == remainingWeekdays.first
            return max(0, isToday ? raw * max(0, min(1, fractionOfTodayLeft)) : raw)
        }

        var items: [Item] = []
        for target in floors {
            let name = input.names[target.id] ?? "allocation"
            let claimed = (1...7).filter { target.weekdays.effective.contains(weekday: $0) }
            guard !claimed.isEmpty, target.weeklySeconds > 0 else { continue }
            let perClaimedDay = target.weeklySeconds / Double(claimed.count)

            // Expected by now counts only the allocation's OWN days that have passed. A weekdays-only
            // floor owes nothing on a Sunday, and charging it for the weekend is how a planner tells
            // you you're behind when you aren't.
            let elapsedClaimed = elapsedWeekdays.filter { claimed.contains($0) }.count
            let expected = perClaimedDay * Double(elapsedClaimed)
            let done = actuals[target.id] ?? 0
            let remaining = max(0, target.weeklySeconds - done)

            let remainingClaimed = remainingWeekdays.filter { claimed.contains($0) }
            let available = remainingClaimed
                .compactMap { w in plan.days.first { $0.weekday == w } }
                .reduce(0.0) { $0 + roomFor(target, on: $1) }

            let perDay: TimeInterval? = remainingClaimed.isEmpty
                ? nil : remaining / Double(remainingClaimed.count)

            let standing: Standing
            var advice = ""
            if remaining <= 60 {
                standing = .met
            } else if remainingClaimed.isEmpty {
                standing = .unreachable
                advice = "none of its days are left this week — it needs "
                       + hours(remaining) + " and has nowhere to put it"
            } else if remaining > available + 60 {
                standing = .unreachable
                advice = "the \(remainingClaimed.count) day(s) left can give it at most "
                       + hours(available) + ", and it still needs " + hours(remaining)
                       + " — drop it to " + hours(done + available) + " to make it reachable"
            } else if expected - done > 60 {
                standing = .recoverable
            } else {
                standing = .onTrack
            }

            // Who else wants those days. Reserved time counts as a competitor too — it is the most
            // common reason a day has no room, and leaving it out would blame the wrong thing.
            var claims: [String: TimeInterval] = [:]
            var reservedOnThose: TimeInterval = 0
            for weekday in remainingClaimed {
                guard let day = plan.days.first(where: { $0.weekday == weekday }) else { continue }
                reservedOnThose += day.reservedSeconds
                for placement in day.placements where placement.targetID != target.id {
                    claims[placement.name, default: 0] += placement.seconds
                }
            }
            if reservedOnThose > 60 { claims["reserved"] = reservedOnThose }
            let blockers = claims.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
                .prefix(3)
                .map { Blocker(name: $0.key, secondsOnThoseDays: $0.value) }

            items.append(Item(targetID: target.id, name: name,
                              targetSeconds: target.weeklySeconds, doneSeconds: done,
                              expectedByNowSeconds: expected,
                              remainingClaimedDays: remainingClaimed.count,
                              requiredPerRemainingDay: perDay,
                              availableOnRemainingDays: available,
                              standing: standing, adviceIfUnreachable: advice,
                              blockers: Array(blockers)))
        }

        // The week as a whole: everything still owed against everything still free.
        //
        // Nested allocations are excluded from the SUM while still being listed individually. Both
        // halves matter: you can be on pace for `office` and behind on the piece of it you care about,
        // so the row is worth showing — but its hours are already inside the parent's, so adding them
        // would inflate the total and could declare the week lost on work counted twice.
        let nestedIDs = Set(floors.filter { inner in
            floors.contains { outer in
                inner.id != outer.id
                    && input.membership.relation(inner.subject, outer.subject) == .containedIn
            }
        }.map(\.id))
        let need = items.filter { !nestedIDs.contains($0.targetID) }
            .reduce(0.0) { $0 + $1.remainingSeconds }
        let capacity = remainingWeekdays
            .compactMap { w in plan.days.first { $0.weekday == w } }
            .reduce(0.0) { $0 + usable($1) }

        // The remaining days, reloaded: each allocation's leftover spread over its own remaining days,
        // which is the "replan" — the same even-spread rule the week plan uses, applied to what's left.
        var replanned: [Planner.DayPlan] = []
        for weekday in remainingWeekdays {
            guard let base = plan.days.first(where: { $0.weekday == weekday }) else { continue }
            var placements: [Planner.Placement] = []
            for item in items where item.remainingSeconds > 60 {
                guard let target = floors.first(where: { $0.id == item.targetID }),
                      target.weekdays.effective.contains(weekday: weekday),
                      let perDay = item.requiredPerRemainingDay else { continue }
                placements.append(Planner.Placement(targetID: item.targetID, name: item.name,
                                                    seconds: perDay))
            }
            replanned.append(Planner.DayPlan(weekday: weekday,
                                             capacitySeconds: base.capacitySeconds,
                                             reservedSeconds: base.reservedSeconds,
                                             placements: placements))
        }

        return Replan(items: items, remainingNeedSeconds: need,
                      remainingCapacitySeconds: capacity, replannedDays: replanned)
    }
}

/// Same coarse hours the planner's sentences use — this deals in hour-slabs, so anything finer would
/// imply a precision the model doesn't have.
private func hours(_ seconds: TimeInterval) -> String {
    let h = seconds / 3600
    if h >= 1 { return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h) }
    return "\(Int((seconds / 60).rounded()))m"
}


public extension Replan {
    /// How much of today is still usable, as a share of a waking day.
    ///
    /// Measured as the hours left before midnight against the length of a waking day — NOT as "how far
    /// through the waking day are we", which needs to know when your day starts and doesn't. The naive
    /// version divided the time since midnight by the waking hours, so from mid-afternoon it reported
    /// nothing left and called every allocation unreachable.
    ///
    /// It clamps to 1: early in the morning there is more time before midnight than a waking day is
    /// long, and today does not become bigger than a day because you got up early.
    static func fractionOfDayLeft(now: Date, wakingSeconds: TimeInterval,
                                  calendar: Calendar = .current) -> Double {
        guard wakingSeconds > 0 else { return 0 }
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let secondsLeft = max(0, endOfDay.timeIntervalSince(now))
        return max(0, min(1, secondsLeft / wakingSeconds))
    }
}
