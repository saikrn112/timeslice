import Foundation

/// When an allocation applies, and what it therefore asks of a given stretch of days.
///
/// One idea, and every goal figure on the planner reduces to it: **an allocation's claimed days are its
/// weekdays intersected with its window.** A `≥ 35h/week Mon–Fri` allocation bounded to 1–15 Oct claims the
/// eleven weekdays in that span and nothing else, so October asks 77h of it rather than 154h, September asks
/// nothing, and browsing back to September shows no goal instead of pretending this month's intentions
/// applied then.
///
/// A one-off (`period == .once`) is the same computation with a different rate: its `seconds` is the whole
/// job rather than a rate, so its per-day figure is the total divided by the claimed days of its *window*.
public extension Target {
    /// The allocation's window as a half-open day range, or nil if unbounded at both ends.
    ///
    /// Half-open because every date comparison in this app is `start <= x < end`, and `endsOn` is inclusive
    /// as a user states it ("until 15 Nov" includes the 15th) — so the stored end is pushed to the next
    /// midnight exactly once, here, rather than at each of a dozen call sites.
    var dayWindow: DateInterval? { dayWindow(calendar: .current) }

    func dayWindow(calendar: Calendar) -> DateInterval? {
        guard startsOn != nil || endsOn != nil else { return nil }
        let start = startsOn.map { calendar.startOfDay(for: $0) } ?? Date.distantPast
        let end = endsOn
            .map { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))
                   ?? calendar.startOfDay(for: $0) }
            ?? Date.distantFuture
        guard end > start else { return DateInterval(start: start, end: start) }
        return DateInterval(start: start, end: end)
    }

    /// Whether this allocation applies to any part of `range`.
    ///
    /// False means it shows nothing at all for that period — absent from the rail, the goal, the verdict and
    /// the grid — which is the whole point of a window: a past month stops having this month's intentions
    /// applied to it retroactively.
    func applies(to range: DateInterval, calendar: Calendar = .current) -> Bool {
        if !dates.isEmpty {
            return dates.contains { $0 >= range.start && $0 < range.end }
        }
        guard let window = dayWindow(calendar: calendar) else { return true }
        return window.intersects(range) && window.end > range.start && range.end > window.start
    }

    /// Whether `day` falls in a period this allocation actually runs in.
    ///
    /// Always true unless `interval > 1`. For "every 2 weeks" the periods are counted from the anchor's own
    /// period — week 0 active, week 1 skipped, week 2 active — which is why the anchor is `startsOn` and why
    /// an interval without one is treated as every period: there would be nothing to count from.
    func runsIn(day: Date, calendar: Calendar = .current) -> Bool {
        guard interval > 1, period != .once, let anchor = startsOn else { return true }
        let unit: Calendar.Component
        switch period {
        case .day: unit = .day
        case .week: unit = .weekOfYear
        case .month: unit = .month
        case .once: return true
        }
        let from = calendar.dateInterval(of: unit, for: anchor)?.start ?? anchor
        let to = calendar.dateInterval(of: unit, for: day)?.start ?? day
        guard let elapsed = calendar.dateComponents([unit], from: from, to: to).value(for: unit)
        else { return true }
        return elapsed >= 0 && elapsed % interval == 0
    }

    /// Days in `range` that this allocation both claims by weekday and lies inside its window.
    ///
    /// The denominator of every goal. Counted by walking days rather than arithmetic on lengths, because a
    /// weekday mask can't be divided and DST makes a "day" 23 or 25 hours twice a year.
    func claimedDays(in range: DateInterval, calendar: Calendar = .current) -> Int {
        // A chosen set of days is the whole answer: no mask, no window, no cycle. Anything else would mean
        // picking a Saturday and then being told the allocation doesn't work Saturdays.
        if !dates.isEmpty {
            return dates.filter { $0 >= range.start && $0 < range.end }.count
        }
        let window = dayWindow(calendar: calendar)
        let claimed = weekdays.effective
        var days = 0
        var cursor = calendar.startOfDay(for: range.start)
        while cursor < range.end {
            let inWindow = window.map { $0.start <= cursor && cursor < $0.end } ?? true
            if inWindow, claimed.contains(weekday: calendar.component(.weekday, from: cursor)),
               runsIn(day: cursor, calendar: calendar) {
                days += 1
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// Hours per claimed day — the rate everything else multiplies up.
    ///
    /// For a rate this is the period's amount over the days that period claims. For a one-off it is the total
    /// over the claimed days of its whole window, so a 20h job across eleven days of which seven are weekdays
    /// asks 2.9h of each weekday.
    func perClaimedDaySeconds(calendar: Calendar = .current) -> TimeInterval {
        // Chosen days share the whole job between them, which is what `once` means with a window.
        if !dates.isEmpty { return seconds / Double(dates.count) }
        let perWeek = Double(max(1, weekdays.effective.selectedCount))
        switch period {
        case .day:
            return seconds
        case .week:
            return seconds / perWeek
        case .month:
            return weeklySeconds / perWeek
        case .once:
            // Without a window there is nothing to spread over, and guessing a length would invent hours.
            guard let window = dayWindow(calendar: calendar) else { return 0 }
            let days = claimedDays(in: window, calendar: calendar)
            guard days > 0 else { return 0 }
            return seconds / Double(days)
        }
    }

    /// This allocation rewritten as a plain weekly one for the window being viewed — or nil if it doesn't
    /// apply there at all.
    ///
    /// The planner's day-level machinery (`Planner`, `Replan`) works in weekday numbers with no dates, so it
    /// cannot test a window or an every-N cycle. Rather than thread dates through all of it, each target is
    /// projected onto the viewed window first: the hours become what it actually asks of that window, the
    /// weekday mask is narrowed to the days that are genuinely eligible there, and the interval is spent. What
    /// comes out is an ordinary weekly allocation, so every existing figure keeps working unchanged.
    ///
    /// A one-off on a single Wednesday projects onto that week as "4h, Wednesdays only" — which is exactly
    /// what it means, and the planner then places it with the same rules as everything else.
    func projected(onto window: DateInterval, calendar: Calendar = .current) -> Target? {
        guard applies(to: window, calendar: calendar) else { return nil }
        let asked = direction == .atLeast ? ask(in: window, calendar: calendar) : seconds
        // Eligible days: inside the window, claimed by the mask, and in a running cycle. With chosen dates
        // it's simply the weekdays those dates fall on, inside this window.
        var mask = Weekdays(rawValue: 0)
        if !dates.isEmpty {
            for date in dates where date >= window.start && date < window.end {
                let weekday = calendar.component(.weekday, from: date)
                if !mask.contains(weekday: weekday) { mask = mask.toggling(weekday: weekday) }
            }
            guard mask.rawValue != 0, asked > 0 || direction == .atMost else { return nil }
            return Target(id: id, subject: subject, seconds: asked, direction: direction,
                          period: .week, createdAt: createdAt, completedAt: completedAt,
                          sortOrder: sortOrder, weekdays: mask, shape: shape,
                          startsOn: startsOn, endsOn: endsOn, interval: 1)
        }
        var cursor = calendar.startOfDay(for: window.start)
        let claimed = weekdays.effective
        let dayWin = dayWindow(calendar: calendar)
        while cursor < window.end {
            let weekday = calendar.component(.weekday, from: cursor)
            let inWindow = dayWin.map { $0.start <= cursor && cursor < $0.end } ?? true
            if inWindow, claimed.contains(weekday: weekday), runsIn(day: cursor, calendar: calendar),
               !mask.contains(weekday: weekday) {
                mask = mask.toggling(weekday: weekday)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        // A floor with no eligible day in this window asks nothing here; a ceiling still applies.
        if direction == .atLeast && (mask.rawValue == 0 || asked <= 0) { return nil }
        return Target(id: id, subject: subject, seconds: asked, direction: direction,
                      period: .week, createdAt: createdAt, completedAt: completedAt,
                      sortOrder: sortOrder,
                      weekdays: mask.rawValue == 0 ? weekdays : mask, shape: shape,
                      startsOn: startsOn, endsOn: endsOn, interval: 1, dates: dates)
    }

    /// How much of this allocation's OWN time in `range` has gone — not how much of the calendar has.
    ///
    /// The pace figure used one wall-clock fraction for every allocation, so a Mon–Fri office allocation on
    /// Friday evening was judged "85% through the week" and told it should be at 29.6h of 35h. By then all
    /// five of its days are spent: it should be at 35h. The mirror error is a weekend allocation being called
    /// behind on a Tuesday, when none of its days have arrived yet.
    ///
    /// Counted in claimed days, with today included as the fraction of the waking day gone — the same shape
    /// the planner uses to decide what today can still be asked for.
    func elapsedFraction(in range: DateInterval, now: Date = Date(),
                         fractionOfTodayElapsed: Double? = nil,
                         calendar: Calendar = .current) -> Double {
        let total = claimedDays(in: range, calendar: calendar)
        guard total > 0 else { return 1 }
        guard now < range.end else { return 1 }
        guard now >= range.start else { return 0 }

        let startOfToday = calendar.startOfDay(for: now)
        let past = claimedDays(in: DateInterval(start: range.start, end: startOfToday),
                               calendar: calendar)
        // Today counts only if this allocation claims it — otherwise a Tuesday adds nothing to a
        // weekend allocation's elapsed share.
        var elapsed = Double(past)
        if claimedDays(in: DateInterval(start: startOfToday,
                                        end: calendar.date(byAdding: .day, value: 1,
                                                           to: startOfToday) ?? range.end),
                       calendar: calendar) > 0 {
            let gone = fractionOfTodayElapsed
                ?? min(1, max(0, now.timeIntervalSince(startOfToday) / 86_400))
            elapsed += min(1, max(0, gone))
        }
        return min(1, max(0, elapsed / Double(total)))
    }

    /// What this allocation asks of `range`: its per-claimed-day rate times the claimed days it has there.
    ///
    /// Replaces every ad-hoc `weeklySeconds × someNumberOfWeeks` in the planner. A week wholly inside a
    /// window asks exactly its weekly amount; a month asks what its own days add up to; a one-off asks its
    /// share of the days of it that fall in the range; anything outside the window asks nothing.
    func ask(in range: DateInterval, calendar: Calendar = .current) -> TimeInterval {
        guard direction == .atLeast else { return 0 }
        let days = claimedDays(in: range, calendar: calendar)
        guard days > 0 else { return 0 }
        return perClaimedDaySeconds(calendar: calendar) * Double(days)
    }
}
