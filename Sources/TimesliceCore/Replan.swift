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

        /// Hours a day can still give to allocations: waking hours minus the non-negotiables, with
        /// today discounted to what's left of it.
        ///
        /// Reserved time is subtracted; the PLAN is not. That distinction was a real bug: this used
        /// `slackSeconds`, which is capacity minus reserved minus *committed* — and committed is the
        /// plan's own spread of the very allocations whose remaining need is being summed. So it
        /// compared "what's left to do" against "what's left after what's left to do", and declared a
        /// perfectly recoverable week unfinishable. Catch-up can use any free hour on any remaining
        /// day; that is the whole point of catching up.
        func usable(_ day: Planner.DayPlan) -> TimeInterval {
            let free = max(0, day.capacitySeconds - day.reservedSeconds)
            let isToday = day.weekday == remainingWeekdays.first
            return isToday ? free * max(0, min(1, fractionOfTodayLeft)) : free
        }

        /// What one allocation could still take on a day, ignoring what other allocations want.
        ///
        /// Deliberately not "after the competition": an allocation is *unreachable* only when its own
        /// days physically cannot hold it, which is a fact about it alone. Whether all of them fit
        /// together is a different question, answered once at the week level by `weekIsLost` — and
        /// mixing the two made every allocation look impossible whenever the week was merely busy.
        func roomFor(_ target: Target, on day: Planner.DayPlan) -> TimeInterval {
            usable(day)
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

        // The remaining days, reloaded — and this is where catch-up actually gets decided.
        //
        // Not an even spread. An even spread put every allocation's leftover equally on each of its own
        // remaining days, which piled work onto a day that was already full while the next day sat half
        // empty: Friday came out 2.2h over capacity with Saturday holding 3h of free time that anything
        // claiming Saturday could have used. Even-spreading is the right rule for a whole week, where no
        // day has a history yet; mid-week it ignores the thing that has changed.
        //
        // So: worst-off allocation first, each one's leftover distributed across its claimed remaining
        // days in proportion to the room actually left on them, and never more than a day can hold.
        // What still doesn't fit stays unplaced rather than being drawn into an impossible day — the
        // per-allocation `standing` above is where that shortfall is reported.
        //
        // It cannot fix everything, and shouldn't pretend to: an allocation that claims Mon–Fri has only
        // Friday left however much room Saturday has. That is a fact about the allocation's own weekdays,
        // and the honest answer is to say the day is over capacity.
        var roomLeft: [Int: TimeInterval] = [:]
        for weekday in remainingWeekdays {
            guard let base = plan.days.first(where: { $0.weekday == weekday }) else { continue }
            roomLeft[weekday] = usable(base)
        }
        var byDay: [Int: [Planner.Placement]] = [:]
        for item in items.sorted(by: { $0.debtSeconds > $1.debtSeconds })
        where item.remainingSeconds > 60 {
            guard let target = floors.first(where: { $0.id == item.targetID }) else { continue }
            let claimed = remainingWeekdays.filter {
                target.weekdays.effective.contains(weekday: $0)
            }
            guard !claimed.isEmpty else { continue }
            var need = item.remainingSeconds

            // Two passes: proportional to free room, then a sweep for whatever rounding or capping left
            // over. Without the second pass a day that filled up would silently drop hours.
            let totalRoom = claimed.reduce(0.0) { $0 + max(0, roomLeft[$1] ?? 0) }
            // The proportion is taken against the ORIGINAL need, not the shrinking remainder. Using the
            // remainder made each day's share smaller than the last — four equal days split 10h as
            // 2.5/1.9/1.4/1.1 instead of 2.5 each — which looks like a deliberate taper and isn't one.
            let want = need
            if totalRoom > 0 {
                for weekday in claimed {
                    let room = max(0, roomLeft[weekday] ?? 0)
                    let share = min(room, want * (room / totalRoom))
                    guard share > 60 else { continue }
                    byDay[weekday, default: []].append(
                        Planner.Placement(targetID: item.targetID, name: item.name, seconds: share))
                    roomLeft[weekday] = room - share
                    need -= share
                }
            }
            if need > 60 {
                for weekday in claimed where need > 60 {
                    let room = max(0, roomLeft[weekday] ?? 0)
                    guard room > 60 else { continue }
                    let extra = min(room, need)
                    if let index = byDay[weekday]?.firstIndex(where: { $0.targetID == item.targetID }) {
                        let existing = byDay[weekday]![index]
                        byDay[weekday]![index] = Planner.Placement(targetID: existing.targetID,
                                                                   name: existing.name,
                                                                   seconds: existing.seconds + extra)
                    } else {
                        byDay[weekday, default: []].append(
                            Planner.Placement(targetID: item.targetID, name: item.name,
                                              seconds: extra))
                    }
                    roomLeft[weekday] = room - extra
                    need -= extra
                }
            }
        }

        var replanned: [Planner.DayPlan] = []
        for weekday in remainingWeekdays {
            guard let base = plan.days.first(where: { $0.weekday == weekday }) else { continue }
            replanned.append(Planner.DayPlan(weekday: weekday,
                                             capacitySeconds: base.capacitySeconds,
                                             reservedSeconds: base.reservedSeconds,
                                             placements: (byDay[weekday] ?? [])
                                                 .sorted { $0.seconds > $1.seconds }))
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

public extension Replan {
    /// Per remaining weekday, per allocation: hours of **catch-up** — the work pushed into a day beyond
    /// that day's own intention, because earlier days in the week were missed.
    ///
    /// Two numbers matter on a day and they are not the same question:
    ///
    /// - *What did today want?* — the allocation's even share of its claimed days, minus what today already
    ///   got. Stable, and the same figure the plan was built from.
    /// - *What is being carried into today?* — the week's shortfall, which has to land somewhere.
    ///
    /// Drawing only the first hides the backlog; drawing only their sum (which is what a full
    /// redistribution produces) makes today read 5.6h and tomorrow 2.7h for an allocation that plainly
    /// wants 7h a day, and those figures move when an unrelated day fills up. So they are computed
    /// separately and drawn separately.
    ///
    /// The debt goes where there is room: allocations in order of how far behind they are, each one's debt
    /// split across its remaining claimed days in proportion to the hours those days actually have left,
    /// and never more than a day can hold. What still doesn't fit is simply not placed — the day-level
    /// picture shouldn't claim an impossible hour, and `weekIsLost` is where that fact belongs.
    static func catchUp(input: Planner.Input,
                        plan: Planner,
                        actualsByWeekday: [Int: [Int64: TimeInterval]],
                        remainingWeekdays: [Int],
                        fractionOfTodayLeft: Double = 1) -> [Int: [Int64: TimeInterval]] {
        let floors = input.targets.filter { $0.direction == .atLeast }
        guard !floors.isEmpty, !remainingWeekdays.isEmpty else { return [:] }

        func done(_ weekday: Int, _ id: Int64) -> TimeInterval {
            actualsByWeekday[weekday]?[id] ?? 0
        }

        /// What each allocation still wants on each remaining day, before any catch-up.
        var intendedLeft: [Int64: [Int: TimeInterval]] = [:]
        var debts: [(id: Int64, debt: TimeInterval, days: [Int])] = []
        for target in floors {
            let claimed = (1...7).filter { target.weekdays.effective.contains(weekday: $0) }
            guard !claimed.isEmpty, target.weeklySeconds > 0 else { continue }
            let perDay = target.weeklySeconds / Double(claimed.count)
            let remainingClaimed = remainingWeekdays.filter { claimed.contains($0) }

            var byDay: [Int: TimeInterval] = [:]
            for weekday in remainingClaimed {
                byDay[weekday] = max(0, perDay - done(weekday, target.id))
            }
            intendedLeft[target.id] = byDay

            let weekDone = (1...7).reduce(0.0) { $0 + done($1, target.id) }
            let remaining = max(0, target.weeklySeconds - weekDone)
            let base = byDay.values.reduce(0, +)
            let debt = max(0, remaining - base)
            if debt > 60, !remainingClaimed.isEmpty {
                debts.append((target.id, debt, remainingClaimed))
            }
        }
        guard !debts.isEmpty else { return [:] }

        // Hours each remaining day has left once what has happened, what is reserved, and every
        // allocation's own intention for that day are accounted for. Catch-up can only use what's left.
        var room: [Int: TimeInterval] = [:]
        for weekday in remainingWeekdays {
            guard let day = plan.days.first(where: { $0.weekday == weekday }) else { continue }
            let isToday = weekday == remainingWeekdays.first
            let capacity = (day.capacitySeconds - day.reservedSeconds)
                * (isToday ? max(0, min(1, fractionOfTodayLeft)) : 1)
            let tracked = (actualsByWeekday[weekday] ?? [:]).values.reduce(0, +)
            let intended = intendedLeft.values.reduce(0.0) { $0 + ($1[weekday] ?? 0) }
            room[weekday] = max(0, capacity - tracked - intended)
        }

        var out: [Int: [Int64: TimeInterval]] = [:]
        for entry in debts.sorted(by: { $0.debt > $1.debt }) {
            var left = entry.debt
            let total = entry.days.reduce(0.0) { $0 + max(0, room[$1] ?? 0) }
            guard total > 60 else { continue }
            let want = left
            for weekday in entry.days {
                let available = max(0, room[weekday] ?? 0)
                guard available > 60 else { continue }
                let share = min(available, want * (available / total))
                guard share > 60 else { continue }
                out[weekday, default: [:]][entry.id, default: 0] += share
                room[weekday] = available - share
                left -= share
            }
            // A second sweep for what rounding or capping left behind, so hours aren't silently dropped.
            for weekday in entry.days where left > 60 {
                let available = max(0, room[weekday] ?? 0)
                guard available > 60 else { continue }
                let extra = min(available, left)
                out[weekday, default: [:]][entry.id, default: 0] += extra
                room[weekday] = available - extra
                left -= extra
            }
        }
        return out
    }
}

public extension Replan {
    /// Per remaining weekday, what one allocation still wants of that day — and no more than the week
    /// still needs in total.
    ///
    /// A day's intention is a fixed share of its claimed days: office at 35h over five days wants 7h on
    /// each. But if only 10.4h of the week remain, then drawing 3.8h today and 7h on Friday promises 10.8h
    /// and would overshoot the weekly target. The days are therefore filled in order and the week's
    /// remainder is spent down as they go — today takes its full 3.8h, Friday takes the 6.6h that is left
    /// rather than its nominal 7h.
    ///
    /// Order matters and it is deliberately chronological: the nearest day keeps its full intention, and the
    /// shortfall lands on the furthest one. The alternative — shaving a bit off every day — produces
    /// figures that are all slightly wrong and none of them memorable.
    ///
    /// `doneByWeekday` must be CREDITED hours: every second that counts toward this allocation, including
    /// work a narrower allocation also covers. Measuring against a primary attribution made office ask for
    /// 5.6h today when kvcache had already given it an hour and a half.
    static func owedByDay(target: Target,
                          doneByWeekday: [Int: TimeInterval],
                          remainingWeekdays: [Int]) -> [Int: TimeInterval] {
        let claimed = (1...7).filter { target.weekdays.effective.contains(weekday: $0) }
        guard !claimed.isEmpty, target.weeklySeconds > 0 else { return [:] }
        let perDay = target.weeklySeconds / Double(claimed.count)
        let weekDone = (1...7).reduce(0.0) { $0 + (doneByWeekday[$1] ?? 0) }
        var budget = max(0, target.weeklySeconds - weekDone)

        var out: [Int: TimeInterval] = [:]
        for weekday in remainingWeekdays where claimed.contains(weekday) {
            guard budget > 60 else { break }
            let want = max(0, perDay - (doneByWeekday[weekday] ?? 0))
            let take = min(want, budget)
            if take > 60 {
                out[weekday] = take
                budget -= take
            }
        }
        return out
    }
}
