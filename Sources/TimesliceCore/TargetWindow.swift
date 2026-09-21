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
