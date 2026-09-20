import Foundation

/// The month as its weeks: how full each one was, what it still owes, and what wouldn't fit anywhere.
///
/// The same reading as the week view, one level up. A month of day cells says whether individual days went
/// well; it can't say "this month is a week behind", because that sentence is about weeks. So the weeks get
/// the filling-container treatment and the day grid stays underneath for detail.
///
/// **The window is the month, so catching up happens across weeks.** The week view deliberately never spills
/// work into the next week — it is isolated to the week you are looking at, and hours that can't fit are
/// simply hours you didn't get. A month view isolates to the MONTH: a week that fell short pushes its
/// shortfall into the weeks of that month still to come, and only what the whole month cannot absorb ends up
/// in the pool. Same algorithm as `Replan.dailyPlan`, one unit up: chronological, forward only, fair shares,
/// no priority between allocations.
///
/// **Partial weeks are prorated, not padded.** September 2026 starts on a Tuesday, so its first week holds
/// five days of the month, not seven. That week's capacity is five waking days AND its allocations only ask
/// for five sevenths of their weekly hours — the other two days belong to August. Treating it as a whole week
/// would invent a day of room and a week of work to put in it, and the first column of every month would read
/// as a disaster.
public enum PlannerMonth {
    /// One calendar week, intersected with the month.
    public struct WeekSpan: Sendable, Equatable, Identifiable {
        /// 1-based, in calendar order — the column's identity and its label.
        public let index: Int
        /// Clipped to the month, so the first and last spans are usually short.
        public let window: DateInterval
        /// The weekdays (1...7) this span covers inside the month.
        public let weekdays: [Int]
        /// Day-of-month numbers at either end, for a "1–5" heading.
        public let firstDay: Int
        public let lastDay: Int
        public var days: Int { weekdays.count }
        public var id: Int { index }

        public init(index: Int, window: DateInterval, weekdays: [Int], firstDay: Int, lastDay: Int) {
            self.index = index
            self.window = window
            self.weekdays = weekdays
            self.firstDay = firstDay
            self.lastDay = lastDay
        }
    }

    /// The month's weeks, in order, each clipped to the month.
    ///
    /// Walks days rather than adding weeks: `date(byAdding: .weekOfYear)` across a DST boundary lands on a
    /// different hour, and a month can start mid-week, so counting days is both simpler and correct.
    public static func weekSpans(month: DateInterval, calendar: Calendar) -> [WeekSpan] {
        var out: [WeekSpan] = []
        var cursor = calendar.startOfDay(for: month.start)
        var current: [Date] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
            out.append(WeekSpan(
                index: out.count + 1,
                window: DateInterval(start: first, end: end),
                weekdays: current.map { calendar.component(.weekday, from: $0) },
                firstDay: calendar.component(.day, from: first),
                lastDay: calendar.component(.day, from: last)))
            current = []
        }

        while cursor < month.end {
            // A new week starts whenever the weekday wraps back to the calendar's first day.
            if !current.isEmpty,
               calendar.component(.weekday, from: cursor) == calendar.firstWeekday {
                flush()
            }
            current.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        flush()
        return out
    }

    /// What one week of the month is asked for, split by where the ask came from.
    ///
    /// Two numbers because they answer different questions — this week's own share versus work moved here
    /// from a week that fell short — and one block is drawn for their total, with the split in its tooltip.
    /// Printing "+1.4h moved here" as a separate block read as a duplicate of the allocation above it.
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
        /// Waking hours across the span's days — the column's height.
        public var capacity: TimeInterval
        /// How much of that capacity has gone: whole days for a week that's over, today only as far as the
        /// clock has got.
        public var elapsed: TimeInterval
        /// Allocation → seconds, each owned by exactly one allocation, so a column can't sum past its own
        /// capacity. What gets drawn solid.
        public var tracked: [Int64: TimeInterval]
        /// Allocation → seconds counted for every allocation covering them. What progress is measured with.
        public var credited: [Int64: TimeInterval]
        /// Tracked against nothing allocated.
        public var unallocated: TimeInterval
        /// Elapsed hours with nothing recorded at all.
        public var untracked: TimeInterval
        /// Allocation → what this span would ask for on its own, prorated to its days inside the month.
        public var want: [Int64: TimeInterval]
        /// Allocation → hours planned into this span, its own share and anything moved here. Drawn dashed.
        public var owed: [Int64: Share]
        /// Allocation → hours that originated in this span and fitted nowhere in the rest of the month. The
        /// pool under the column.
        ///
        /// Filed under the week they came FROM, not the last week of the month: a finished month then shows
        /// each week's own misses under that week, which is the retrospective the view is for.
        public var leftover: [Int64: TimeInterval]
        /// Everything tracked in the span, whatever it was against.
        public var total: TimeInterval { tracked.values.reduce(0, +) + unallocated }
        /// Hours of the span still to come.
        public var room: TimeInterval { max(0, capacity - elapsed) }
    }

    /// Roll the month up into its weeks, reallocating shortfalls forward inside the month.
    ///
    /// - Parameters:
    ///   - floors: `atLeast` allocations. Ceilings never ask for hours, so they take no room.
    ///   - nested: allocations wholly inside another. They are credited and drawn like anyone else, but ask
    ///     for nothing of their own — the parent's share already covers those hours. Leaving them in spends
    ///     the same hours twice, which is the bug that had a week showing free room above a full pool.
    ///   - fractionOfTodayLeft: how much of today is still usable, so the current week isn't offered hours
    ///     that have already gone.
    public static func rollups(month: DateInterval,
                               intervals: [Interval],
                               floors: [Target],
                               membership: SubjectMembership,
                               nested: Set<Int64> = [],
                               wakingSeconds: TimeInterval,
                               weeks: Double = 4,
                               fractionOfTodayLeft: Double = 1,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> [WeekRollup] {
        let spans = weekSpans(month: month, calendar: calendar)
        guard !spans.isEmpty else { return [] }
        let startOfToday = calendar.startOfDay(for: now)
        let asking = floors.filter { $0.direction == .atLeast && !nested.contains($0.id) }

        // MARK: What happened, per span

        var tracked = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        var credited = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        var unallocated = [TimeInterval](repeating: 0, count: spans.count)
        var total = [TimeInterval](repeating: 0, count: spans.count)
        var elapsed = [TimeInterval](repeating: 0, count: spans.count)

        for (index, span) in spans.enumerated() {
            let facts = PlannerWeek.facts(intervals: intervals, window: span.window, floors: floors,
                                          membership: membership, nested: nested,
                                          now: now, calendar: calendar)
            for day in facts.values {
                for (id, seconds) in day.primary { tracked[index][id, default: 0] += seconds }
                for (id, seconds) in day.credited { credited[index][id, default: 0] += seconds }
                unallocated[index] += day.unallocated
                total[index] += day.total
            }
            var cursor = calendar.startOfDay(for: span.window.start)
            while cursor < span.window.end {
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

        // A span's share of the MONTH's goal, divided by claimed days.
        //
        // Not `weeklySeconds` per span, which is the more obvious reading and makes the page contradict
        // itself: September has 22 weekdays, so a 35h/week Mon–Fri allocation would ask for 154h across the
        // columns while every other figure on the page — the rail, the headline, the verdict — states the
        // month's goal as `weeklySeconds × weeks`, or 140h. One denominator for the month, shared out by how
        // many of its claimed days each week holds. A Mon–Fri allocation asks nothing of a weekend-only span.
        var want = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        // The physical ceiling on catching up here: an allocation can't use hours on days it doesn't claim,
        // so a weekends-only allocation can absorb at most two waking days per span however far behind it is.
        var ceiling = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        for target in asking where target.weeklySeconds > 0 {
            let claimed = target.weekdays.effective
            let mineBySpan = spans.map { span in
                span.weekdays.filter { claimed.contains(weekday: $0) }.count
            }
            let claimedInMonth = mineBySpan.reduce(0, +)
            guard claimedInMonth > 0 else { continue }
            let monthGoal = target.weeklySeconds * weeks
            for (index, count) in mineBySpan.enumerated() where count > 0 {
                want[index][target.id] = monthGoal * Double(count) / Double(claimedInMonth)
                ceiling[index][target.id] = Double(count) * wakingSeconds
            }
        }

        // MARK: Place it, chronologically and forward only

        var room = spans.indices.map { max(0, Double(spans[$0].days) * wakingSeconds - elapsed[$0]) }
        var owed = [[Int64: Share]](repeating: [:], count: spans.count)
        var headroom = ceiling
        /// Debt still looking for somewhere to go: allocation → origin span → seconds.
        var debt: [Int64: [Int: TimeInterval]] = [:]

        for (index, _) in spans.enumerated() {
            // This span's own shortfall becomes debt originating here. A span that is over has no room, so
            // its shortfall simply carries — no special case for the past.
            for (id, wanted) in want[index] {
                let short = wanted - (credited[index][id] ?? 0)
                if short > 60 { debt[id, default: [:]][index, default: 0] += short }
            }

            // Its own share first, so a week with room keeps its plan intact rather than having it rationed
            // against work moved in from elsewhere.
            for id in want[index].keys.sorted() {
                guard room[index] > 60, let mine = debt[id]?[index], mine > 60 else { continue }
                let take = min(min(mine, room[index]), max(0, headroom[index][id] ?? 0))
                guard take > 60 else { continue }
                owed[index][id, default: Share()].intended += take
                room[index] -= take
                headroom[index][id] = (headroom[index][id] ?? 0) - take
                debt[id]?[index] = mine - take
            }

            // Then anything carried from an earlier week, shared in half-hour turns so nothing is starved.
            var carriedWants: [Int64: TimeInterval] = [:]
            for (id, byOrigin) in debt {
                guard ceiling[index][id] != nil else { continue }       // can't use this span's days at all
                let older = byOrigin.filter { $0.key < index }.values.reduce(0, +)
                let capped = min(older, max(0, headroom[index][id] ?? 0))
                if capped > 60 { carriedWants[id] = capped }
            }
            let split = share(room: room[index], wants: carriedWants)
            for (id, amount) in split.placed where amount > 60 {
                owed[index][id, default: Share()].carried += amount
                room[index] -= amount
                headroom[index][id] = (headroom[index][id] ?? 0) - amount
                // Oldest debt first: a week that fell short a fortnight ago is the one to clear.
                var remaining = amount
                for origin in (debt[id] ?? [:]).keys.sorted() where origin < index && remaining > 0 {
                    let here = debt[id]?[origin] ?? 0
                    let taken = min(here, remaining)
                    debt[id]?[origin] = here - taken
                    remaining -= taken
                }
            }
        }

        // MARK: Whatever the month couldn't absorb, under the week it came from

        var leftover = [[Int64: TimeInterval]](repeating: [:], count: spans.count)
        for (id, byOrigin) in debt {
            for (origin, seconds) in byOrigin where seconds > 60 {
                leftover[origin][id, default: 0] += seconds
            }
        }

        return spans.indices.map { index in
            WeekRollup(span: spans[index],
                       capacity: Double(spans[index].days) * wakingSeconds,
                       elapsed: elapsed[index],
                       tracked: tracked[index], credited: credited[index],
                       unallocated: unallocated[index],
                       untracked: max(0, elapsed[index] - total[index]),
                       want: want[index], owed: owed[index], leftover: leftover[index])
        }
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
