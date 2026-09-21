import Foundation

/// The month as its weeks: how full each one was, what it still owes, and what wouldn't fit anywhere.
///
/// The same reading as the week view, one level up. A month of day cells says whether individual days went
/// well; it can't say "this month is a week behind", because that sentence is about weeks. So the weeks get
/// the filling-container treatment and the day grid stays underneath for detail.
///
/// **The window is the month, so catching up happens across weeks.** The week view deliberately never spills
/// work into the next week — it is isolated to the week you are looking at, and hours that can't fit are
/// simply hours you didn't get. A month view isolates to the MONTH: under `catchUp` a week that fell short
/// pushes its shortfall into the weeks of that month still to come, and only what the whole month cannot
/// absorb ends up in the pool. Same algorithm as `Replan.dailyPlan`, one unit up: chronological, forward only,
/// fair shares, no priority between allocations. `perDay` — per WEEK at this scale — moves nothing, and a miss
/// stays under the week that missed it.
///
/// **A column is a whole calendar week**, not a slice of one. The alternative was clipping the first and last
/// weeks to the month, which makes a month beginning on a Saturday open with a one-day stub beside six full
/// weeks. Instead every column is a real week; the days belonging to the neighbouring month are marked and
/// cannot be planned into, and only the month's own days are counted.
///
/// **The month's goal is what the allocations ask of its days**, not a weekly rate times four. September 2026
/// has 22 weekdays, so a 35h/week Mon–Fri allocation asks 154h of it — and each full week inside the month asks
/// its true 35h, which is exactly what the week view says about that same week. `weeklySeconds × 4` had the two
/// pages disagreeing by 14h about a week they both display.
public enum PlannerMonth {
    /// How finely the month is cut up. The rules are identical either way — one algorithm, whatever the
    /// resolution — so this only decides what a column stands for.
    public enum Resolution: String, Sendable, CaseIterable {
        case week, day
    }

    /// One unit of the month: a calendar week with the month's part identified, or a single day.
    ///
    /// Named for the week case because that came first; a day is the degenerate one — one weekday, nothing
    /// outside the month, and `firstDay == lastDay`.
    /// One calendar week that the month touches, with the month's part identified.
    public struct WeekSpan: Sendable, Equatable, Identifiable {
        /// 1-based, in calendar order — the column's identity.
        public let index: Int
        /// The whole calendar week. Every column is this tall, so none of them is a stub.
        public let week: DateInterval
        /// The part inside the month. Never empty: a span exists because the month reaches it.
        public let inMonth: DateInterval
        /// Weekdays (1...7) of this week that lie inside the month.
        public let weekdays: [Int]
        /// Weekdays belonging to the neighbouring month — the cross-hatched cap on the column.
        public let outsideWeekdays: [Int]
        /// Day-of-month numbers bounding the month's part, for a "2–8" heading.
        public let firstDay: Int
        public let lastDay: Int
        public var days: Int { weekdays.count }
        public var outsideDays: Int { outsideWeekdays.count }
        public var id: Int { index }

        public init(index: Int, week: DateInterval, inMonth: DateInterval, weekdays: [Int],
                    outsideWeekdays: [Int], firstDay: Int, lastDay: Int) {
            self.index = index
            self.week = week
            self.inMonth = inMonth
            self.weekdays = weekdays
            self.outsideWeekdays = outsideWeekdays
            self.firstDay = firstDay
            self.lastDay = lastDay
        }
    }

    /// The month's units at `resolution`: its calendar weeks, or its days.
    ///
    /// A day unit has NO out-of-month part. At week resolution a column is a real calendar week and the
    /// neighbouring month's days are marked on it; at day resolution there is nothing to mark, because a day
    /// either belongs to the month or isn't drawn at all.
    public static func units(month: DateInterval, resolution: Resolution,
                             calendar: Calendar) -> [WeekSpan] {
        switch resolution {
        case .week:
            return weekSpans(month: month, calendar: calendar)
        case .day:
            var out: [WeekSpan] = []
            var cursor = calendar.startOfDay(for: month.start)
            while cursor < month.end {
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                let day = calendar.component(.day, from: cursor)
                out.append(WeekSpan(index: out.count + 1,
                                    week: DateInterval(start: cursor, end: next),
                                    inMonth: DateInterval(start: cursor, end: next),
                                    weekdays: [calendar.component(.weekday, from: cursor)],
                                    outsideWeekdays: [],
                                    firstDay: day, lastDay: day))
                cursor = next
            }
            return out
        }
    }

    /// Every calendar week the month touches, in order.
    ///
    /// Walks days rather than adding weeks: `date(byAdding: .weekOfYear)` across a DST boundary lands on a
    /// different hour, so counting days is both simpler and correct.
    public static func weekSpans(month: DateInterval, calendar: Calendar) -> [WeekSpan] {
        guard let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start),
              let lastWeek = calendar.dateInterval(of: .weekOfYear,
                                                   for: month.end.addingTimeInterval(-1))
        else { return [] }

        var out: [WeekSpan] = []
        var weekStart = calendar.startOfDay(for: firstWeek.start)
        while weekStart < lastWeek.end {
            guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            var inside: [Date] = []
            var outside: [Int] = []
            var cursor = weekStart
            while cursor < weekEnd {
                if cursor >= month.start && cursor < month.end {
                    inside.append(cursor)
                } else {
                    outside.append(calendar.component(.weekday, from: cursor))
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            if let first = inside.first, let last = inside.last {
                let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
                out.append(WeekSpan(
                    index: out.count + 1,
                    week: DateInterval(start: weekStart, end: weekEnd),
                    inMonth: DateInterval(start: first, end: end),
                    weekdays: inside.map { calendar.component(.weekday, from: $0) },
                    outsideWeekdays: outside,
                    firstDay: calendar.component(.day, from: first),
                    lastDay: calendar.component(.day, from: last)))
            }
            weekStart = weekEnd
        }
        return out
    }

    /// What an allocation asks of a month: its daily rate times the days it claims inside it.
    ///
    /// Not `weeklySeconds × 4`. A month holds 20 to 23 weekdays depending on where it starts, and this figure
    /// has to be the one the week columns add up to — otherwise the rail and the grid on the same page state
    /// different goals for the same month.
    public static func goal(for target: Target, month: DateInterval,
                            calendar: Calendar) -> TimeInterval {
        let claimed = target.weekdays.effective
        var days = 0
        var cursor = calendar.startOfDay(for: month.start)
        while cursor < month.end {
            if claimed.contains(weekday: calendar.component(.weekday, from: cursor)) { days += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return target.weeklySeconds / Double(max(1, claimed.selectedCount)) * Double(days)
    }

    /// Every floor's month goal, for the rail, the headline and the verdict.
    public static func goals(floors: [Target], month: DateInterval, nested: Set<Int64> = [],
                             calendar: Calendar) -> [Int64: TimeInterval] {
        var out: [Int64: TimeInterval] = [:]
        for target in floors where target.direction == .atLeast && !nested.contains(target.id) {
            out[target.id] = goal(for: target, month: month, calendar: calendar)
        }
        return out
    }

    /// What one week of the month is asked for, split by where the ask came from.
    ///
    /// Two numbers because they answer different questions — this week's own share versus work moved here from
    /// a week that fell short — and one block is drawn for their total, with the split in its tooltip. Printing
    /// "+1.4h moved here" as a separate block read as a duplicate of the allocation above it.
    public struct Share: Sendable, Equatable {
        public var intended: TimeInterval = 0
        public var carried: TimeInterval = 0
        public var total: TimeInterval { intended + carried }
        public init(intended: TimeInterval = 0, carried: TimeInterval = 0) {
            self.intended = intended
            self.carried = carried
        }
    }

    /// One week column: what it held, what it is asked for, and what it couldn't take.
    public struct WeekRollup: Sendable {
        public var span: WeekSpan
        /// Waking hours across the month's days in this week — what "how full" is measured against.
        public var capacity: TimeInterval
        /// Waking hours of the days belonging to the neighbouring month: the column's cross-hatched cap.
        public var outsideCapacity: TimeInterval
        /// Hours tracked on those outside days. Shown, greyed, and counted toward nothing here — they are
        /// another month's hours, and this week appears in two months' views.
        public var outsideTracked: TimeInterval
        /// How much of `capacity` has gone: whole days for a week that's over, today only as far as the clock.
        public var elapsed: TimeInterval
        /// Allocation → seconds, each owned by exactly one allocation, so a column can't sum past its own
        /// capacity. What gets drawn solid.
        public var tracked: [Int64: TimeInterval]
        /// Allocation → seconds counted for every allocation covering them. What progress is measured with.
        public var credited: [Int64: TimeInterval]
        /// Tracked against nothing allocated.
        public var unallocated: TimeInterval
        /// Elapsed hours of the month's days here with nothing recorded at all.
        public var untracked: TimeInterval
        /// Allocation → what this week asks on its own: its true weekly rate, prorated only where the month
        /// cuts the week.
        public var want: [Int64: TimeInterval]
        /// Allocation → hours planned into this week, its own share and anything moved here. Drawn dashed.
        public var owed: [Int64: Share]
        /// Allocation → hours the month found no room for, pooled under this column.
        ///
        /// Where they sit is what the method decides once nothing more can be planned, and it mirrors the week
        /// view exactly: under `catchUp` an allocation's unplaceable hours accumulate under the LAST week that
        /// could have used them — where the decision would have to be made — and under `perDay` they stay under
        /// the week that missed them.
        public var leftover: [Int64: TimeInterval]
        /// Everything tracked in the month's part of this week, whatever it was against.
        public var total: TimeInterval { tracked.values.reduce(0, +) + unallocated }
        /// Hours of the month's part still to come.
        public var room: TimeInterval { max(0, capacity - elapsed) }
    }

    /// Roll the month up into its weeks, reallocating shortfalls forward inside the month.
    ///
    /// - Parameters:
    ///   - floors: `atLeast` allocations. Ceilings never ask for hours, so they take no room.
    ///   - nested: allocations wholly inside another. They are credited and drawn like anyone else, but ask for
    ///     nothing of their own — the parent's share already covers those hours. Leaving them in spends the
    ///     same hours twice, which is the bug that had a week showing free room above a full pool.
    ///   - method: `catchUp` moves a week's shortfall into the weeks the month has left; `perDay` — per week at
    ///     this scale — leaves it under the week that missed it.
    ///   - fractionOfTodayLeft: how much of today is still usable, so the current week isn't offered hours that
    ///     have already gone.
    public static func rollups(month: DateInterval,
                               intervals: [Interval],
                               floors: [Target],
                               membership: SubjectMembership,
                               nested: Set<Int64> = [],
                               wakingSeconds: TimeInterval,
                               resolution: Resolution = .week,
                               method: Replan.Method = .catchUp,
                               fractionOfTodayLeft: Double = 1,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> [WeekRollup] {
        let spans = units(month: month, resolution: resolution, calendar: calendar)
        guard !spans.isEmpty else { return [] }
        let startOfToday = calendar.startOfDay(for: now)
        let asking = floors.filter { $0.direction == .atLeast && !nested.contains($0.id) }

        // MARK: What happened, per span

        var tracked = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        var credited = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        var unallocated = [TimeInterval](repeating: 0, count: spans.count)
        var total = [TimeInterval](repeating: 0, count: spans.count)
        var elapsed = [TimeInterval](repeating: 0, count: spans.count)
        var outsideTracked = [TimeInterval](repeating: 0, count: spans.count)

        for (index, span) in spans.enumerated() {
            let facts = PlannerWeek.facts(intervals: intervals, window: span.inMonth, floors: floors,
                                          membership: membership, nested: nested,
                                          now: now, calendar: calendar)
            for day in facts.values {
                for (id, seconds) in day.primary { tracked[index][id, default: 0] += seconds }
                for (id, seconds) in day.credited { credited[index][id, default: 0] += seconds }
                unallocated[index] += day.unallocated
                total[index] += day.total
            }
            // Hours on the days this week has outside the month. Not broken down by allocation: those belong to
            // the neighbouring month's page, and repeating the breakdown here would invite counting it twice.
            for interval in intervals {
                let start = max(interval.start, span.week.start)
                let end = min(interval.end ?? now, span.week.end)
                guard end > start else { continue }
                let insideStart = max(start, span.inMonth.start)
                let insideEnd = min(end, span.inMonth.end)
                let inside = insideEnd > insideStart ? insideEnd.timeIntervalSince(insideStart) : 0
                outsideTracked[index] += end.timeIntervalSince(start) - inside
            }
            var cursor = calendar.startOfDay(for: span.inMonth.start)
            while cursor < span.inMonth.end {
                if cursor < startOfToday {
                    elapsed[index] += wakingSeconds
                } else if cursor == startOfToday {
                    elapsed[index] += wakingSeconds * (1 - max(0, min(1, fractionOfTodayLeft)))
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }

        // MARK: What each span asks for

        // The allocation's true daily rate times its claimed days here, so a week wholly inside the month asks
        // exactly what the week view says it asks, and only the weeks the month cuts are prorated.
        var want = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        // The physical ceiling on catching up here: an allocation can't use hours on days it doesn't claim, so a
        // weekends-only allocation can absorb at most two waking days per week however far behind it is.
        var ceiling = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        for target in asking where target.weeklySeconds > 0 {
            let claimed = target.weekdays.effective
            let perDay = target.weeklySeconds / Double(max(1, claimed.selectedCount))
            for (index, span) in spans.enumerated() {
                let mine = span.weekdays.filter { claimed.contains(weekday: $0) }.count
                guard mine > 0 else { continue }
                want[index][target.id] = perDay * Double(mine)
                ceiling[index][target.id] = Double(mine) * wakingSeconds
            }
        }

        // MARK: Place it, chronologically and forward only

        var room = spans.indices.map { max(0, Double(spans[$0].days) * wakingSeconds - elapsed[$0]) }
        var owed = [[Int64: Share]](repeating: [:], count: spans.count)
        var headroom = ceiling
        /// Debt still looking for somewhere to go: allocation → origin span → seconds.
        var debt: [Int64: [Int: TimeInterval]] = [:]

        // One pass, chronological, and the only rule this page has at any resolution:
        //
        // 1. Every unit's own shortfall becomes debt. A unit that is over has no room, so its debt simply
        //    carries forward — the past needs no special case.
        // 2. An allocation asks each open unit for an EVEN slice of everything it still owes, counting only
        //    the units ahead that it can actually use. No unit is singled out to carry the discrepancy, which
        //    is what made a week read 7h · 7h · 7h · 7h · 6h.
        // 3. When a unit can't satisfy everyone, its room is shared in half-hour turns. NOT in id order,
        //    which was a priority hiding as an implementation detail: office, being first, took 65% of a
        //    month's remaining room for 51% of its remaining work.
        // Every unit's shortfall, up front. Accumulating it as the loop walked meant a unit couldn't see what
        // the units AFTER it still wanted, so the early ones under-asked, the last one was handed everything,
        // and the pool grew by the difference.
        for index in spans.indices {
            for (id, wanted) in want[index] {
                let short = wanted - (credited[index][id] ?? 0)
                if short > 60 { debt[id, default: [:]][index, default: 0] += short }
            }
        }

        for index in spans.indices {
            guard room[index] > 60 else { continue }

            var wants: [Int64: TimeInterval] = [:]
            for target in asking {
                guard ceiling[index][target.id] != nil else { continue }   // doesn't claim a day here
                let owing = (debt[target.id] ?? [:]).values.reduce(0, +)
                guard owing > 60 else { continue }
                let asked: TimeInterval
                switch method {
                case .catchUp:
                    // Units from here on that this allocation claims and that still have room.
                    let ahead = spans.indices.filter {
                        $0 >= index && ceiling[$0][target.id] != nil && room[$0] > 60
                    }
                    asked = owing / Double(max(1, ahead.count))
                case .perDay:
                    // Its own share of this unit and nothing else: per week moves nothing between units.
                    asked = max(0, (want[index][target.id] ?? 0) - (credited[index][target.id] ?? 0))
                }
                let capped = min(min(asked, owing), max(0, headroom[index][target.id] ?? 0))
                if capped > 60 { wants[target.id] = capped }
            }

            for (id, amount) in share(room: room[index], wants: wants).placed where amount > 60 {
                // Split at this unit's nominal share: below it is the plan, above it is catching up. One block
                // is drawn for the total; the split is what the tooltip explains.
                let nominal = max(0, (want[index][id] ?? 0) - (credited[index][id] ?? 0))
                let own = min(amount, nominal)
                owed[index][id, default: Share()].intended += own
                if amount - own > 60 { owed[index][id, default: Share()].carried += amount - own }
                room[index] -= amount
                headroom[index][id] = (headroom[index][id] ?? 0) - amount
                // Oldest debt first, so the unit that fell short earliest is the one being cleared.
                var left = amount
                for origin in (debt[id] ?? [:]).keys.sorted() where left > 0 {
                    let here = debt[id]?[origin] ?? 0
                    let taken = min(here, left)
                    debt[id]?[origin] = here - taken
                    left -= taken
                }
            }
        }

        // MARK: Whatever the month couldn't absorb

        // Under catch up it goes to the last week that could have taken it, one block per allocation — the
        // same rule the week view uses when it files office's unplaceable hours under Friday, the last day it
        // claims. Under per week it stays under the week that missed it, because not moving anything is the
        // whole point of that method.
        var leftover = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        for (id, byOrigin) in debt {
            let total = byOrigin.values.filter { $0 > 60 }.reduce(0, +)
            guard total > 60 else { continue }
            if method == .catchUp {
                // The last week with a day this allocation claims. `ceiling` records exactly that.
                guard let last = spans.indices.last(where: { ceiling[$0][id] != nil }) else { continue }
                leftover[last][id, default: 0] += total
            } else {
                for (origin, seconds) in byOrigin where seconds > 60 {
                    leftover[origin][id, default: 0] += seconds
                }
            }
        }

        return spans.indices.map { index in
            WeekRollup(span: spans[index],
                       capacity: Double(spans[index].days) * wakingSeconds,
                       outsideCapacity: Double(spans[index].outsideDays) * wakingSeconds,
                       outsideTracked: outsideTracked[index],
                       elapsed: elapsed[index],
                       tracked: tracked[index], credited: credited[index],
                       unallocated: unallocated[index],
                       untracked: max(0, elapsed[index] - total[index]),
                       want: want[index], owed: owed[index], leftover: leftover[index])
        }
    }

    /// What a finished month never did: per allocation, the hours it wanted and didn't get, filed under the LAST
    /// week it claimed days in — the week its chance ran out.
    ///
    /// The month-scale twin of `PlannerWeek.neverHappened`, and the same reasoning: once the window is over
    /// there is nothing left to schedule, so this is arithmetic on wanted against credited. Which week the block
    /// lands under is the only thing the method still decides in hindsight — `catchUp` accumulates it at the
    /// end, `perDay` leaves each week's own miss under that week.
    public static func neverHappened(floors: [Target], month: DateInterval,
                                     credited: [Int64: TimeInterval], nested: Set<Int64> = [],
                                     calendar: Calendar)
    -> [(id: Int64, missed: TimeInterval, lastWeek: Int)] {
        let spans = weekSpans(month: month, calendar: calendar)
        var out: [(id: Int64, missed: TimeInterval, lastWeek: Int)] = []
        for target in floors where target.direction == .atLeast && !nested.contains(target.id) {
            let missed = max(0, goal(for: target, month: month, calendar: calendar)
                                - (credited[target.id] ?? 0))
            guard missed > 60 else { continue }
            let claimed = target.weekdays.effective
            guard let last = spans.last(where: { span in
                span.weekdays.contains { claimed.contains(weekday: $0) }
            }) else { continue }
            out.append((target.id, missed, last.index))
        }
        return out.sorted { $0.missed > $1.missed }
    }

    /// Hand out `room` among `wants` in half-hour turns.
    ///
    /// **No allocation outranks another.** Serving each want in full before the next starves whatever is
    /// numerically unlucky, and any ordering by size is a preference dressed up as arithmetic — the same
    /// reasoning as the week planner's round-robin. Turns keep the shares equal until one is satisfied, after
    /// which its share goes back into the pot.
    ///
    /// Room of zero is the ordinary case for a week that is over: everything comes back as leftover, which is
    /// what "there was nowhere left to put it" means.
    public static func share(room: TimeInterval, wants: [Int64: TimeInterval])
    -> (placed: [Int64: TimeInterval], leftover: [Int64: TimeInterval]) {
        var remaining = wants.filter { $0.value > 60 }
        guard room > 60, !remaining.isEmpty else { return ([:], remaining) }
        // Everything fits: no rationing, and no rounding to a half hour either.
        if remaining.values.reduce(0, +) <= room { return (remaining, [:]) }

        var placed: [Int64: TimeInterval] = [:]
        var left = room
        let quantum: TimeInterval = 30 * 60
        // Sorted by id alone, so the answer doesn't shuffle between rebuilds.
        var order = remaining.keys.sorted()
        while left > 60, !order.isEmpty {
            var progressed = false
            for id in order {
                guard left > 60, let want = remaining[id], want > 60 else { continue }
                let take = min(min(quantum, want), left)
                placed[id, default: 0] += take
                remaining[id] = want - take
                left -= take
                progressed = true
            }
            order = order.filter { (remaining[$0] ?? 0) > 60 }
            if !progressed { break }
        }
        return (placed, remaining.filter { $0.value > 60 })
    }
}
