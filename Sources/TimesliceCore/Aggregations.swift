import Foundation

/// Pure, UI-free aggregation over intervals. All day/hour bucketing happens here in Swift
/// with `Calendar` (not SQLite `localtime`, which mishandles DST at day/hour boundaries).
/// An interval running across local midnight naturally contributes to both days.
public enum Aggregations {

    /// Seconds of `interval` that fall inside the half-open window [windowStart, windowEnd).
    /// An open interval (end == nil) is treated as ending at `now`.
    public static func clip(
        _ interval: Interval,
        windowStart: Date,
        windowEnd: Date,
        now: Date = Date()
    ) -> TimeInterval {
        let start = max(interval.start, windowStart)
        let end = min(interval.end ?? now, windowEnd)
        return max(0, end.timeIntervalSince(start))
    }

    // MARK: - Per-project totals

    /// All-time seconds per project. `intervals` should be the full set (from: nil).
    public static func allTimeTotals(
        projects: [Project],
        intervals: [Interval],
        now: Date = Date()
    ) -> [ProjectTotal] {
        totals(projects: projects, intervals: intervals) { $0.seconds(now: now) }
    }

    /// Today's seconds per project (clipped to the local calendar day containing `now`).
    public static func todayTotals(
        projects: [Project],
        intervals: [Interval],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ProjectTotal] {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        return totals(projects: projects, intervals: intervals) {
            clip($0, windowStart: dayStart, windowEnd: dayEnd, now: now)
        }
    }

    private static func totals(
        projects: [Project],
        intervals: [Interval],
        secondsFor: (Interval) -> TimeInterval
    ) -> [ProjectTotal] {
        var byProject: [Int64: TimeInterval] = [:]
        for interval in intervals {
            byProject[interval.projectID, default: 0] += secondsFor(interval)
        }
        return projects.map { ProjectTotal(project: $0, seconds: byProject[$0.id] ?? 0) }
    }

    // MARK: - Daily buckets (stacked bars)

    /// Seconds per (local day, project) across the intervals. Splits each interval at local
    /// midnight so a session spanning days is attributed to each day correctly.
    public static func dailyBuckets(
        intervals: [Interval],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyBucket] {
        var acc: [DayProjectKey: TimeInterval] = [:]
        for interval in intervals {
            let end = interval.end ?? now
            forEachLocalDaySegment(start: interval.start, end: end, calendar: calendar) { dayStart, segStart, segEnd in
                let seconds = segEnd.timeIntervalSince(segStart)
                guard seconds > 0 else { return }
                acc[DayProjectKey(day: dayStart, projectID: interval.projectID), default: 0] += seconds
            }
        }
        return acc
            .map { DailyBucket(day: $0.key.day, projectID: $0.key.projectID, seconds: $0.value) }
            .sorted { ($0.day, $0.projectID) < ($1.day, $1.projectID) }
    }

    // MARK: - Daily stats (hours + focus)

    /// Per-day totals for the last `days` calendar days ending on `now`'s day (inclusive).
    /// `deepSeconds` counts only time from intervals whose OWN duration ≥ `deepThreshold`
    /// ("deep blocks"); midnight-crossing intervals split across days but keep their deep status.
    public static func dayStats(
        intervals: [Interval],
        days: Int,
        deepThreshold: TimeInterval,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DayStat] {
        let today = calendar.startOfDay(for: now)
        // Seed every day in the window so the chart shows zeros, not gaps.
        var total: [Date: TimeInterval] = [:]
        var deep: [Date: TimeInterval] = [:]
        for offset in 0..<max(1, days) {
            if let d = calendar.date(byAdding: .day, value: -offset, to: today) {
                total[d] = 0; deep[d] = 0
            }
        }
        let windowStart = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today

        for interval in intervals {
            let end = interval.end ?? now
            let isDeep = end.timeIntervalSince(interval.start) >= deepThreshold
            forEachLocalDaySegment(start: interval.start, end: end, calendar: calendar) { dayStart, segStart, segEnd in
                guard dayStart >= windowStart else { return }
                let seconds = segEnd.timeIntervalSince(segStart)
                guard seconds > 0 else { return }
                total[dayStart, default: 0] += seconds
                if isDeep { deep[dayStart, default: 0] += seconds }
            }
        }
        return total.keys.sorted().map {
            DayStat(day: $0, totalSeconds: total[$0] ?? 0, deepSeconds: deep[$0] ?? 0)
        }
    }

    // MARK: - Day timeline

    /// Task segments for a single local day, each clipped to [00:00, 24:00) and expressed as
    /// hour-of-day offsets (0…24). An interval spanning midnight contributes only its portion
    /// within `day`. Used by the 0–24h day timeline.
    public static func daySegments(
        intervals: [Interval],
        day: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DaySegment] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        var segments: [DaySegment] = []
        for interval in intervals {
            let end = interval.end ?? now
            let clippedStart = max(interval.start, dayStart)
            let clippedEnd = min(end, dayEnd)
            guard clippedEnd > clippedStart else { continue }
            let startHour = clippedStart.timeIntervalSince(dayStart) / 3600
            let endHour = clippedEnd.timeIntervalSince(dayStart) / 3600
            segments.append(DaySegment(id: interval.id, projectID: interval.projectID,
                                       startHour: startHour, endHour: endHour))
        }
        return segments.sorted { $0.startHour < $1.startHour }
    }

    /// Per-day stats for every day in the calendar month containing `month`, including future
    /// days (which come back as zero). Used by the month-view hours-per-day chart.
    public static func monthStats(
        intervals: [Interval],
        month: Date,
        deepThreshold: TimeInterval,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DayStat] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month))
        else { return [] }

        var total: [Date: TimeInterval] = [:]
        var deep: [Date: TimeInterval] = [:]
        for dayOffset in 0..<range.count {
            if let d = calendar.date(byAdding: .day, value: dayOffset, to: monthStart) {
                total[d] = 0; deep[d] = 0
            }
        }
        guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return [] }

        for interval in intervals {
            let end = interval.end ?? now
            let isDeep = end.timeIntervalSince(interval.start) >= deepThreshold
            forEachLocalDaySegment(start: interval.start, end: end, calendar: calendar) { dayStart, segStart, segEnd in
                guard dayStart >= monthStart && dayStart < monthEnd else { return }
                let seconds = segEnd.timeIntervalSince(segStart)
                guard seconds > 0 else { return }
                total[dayStart, default: 0] += seconds
                if isDeep { deep[dayStart, default: 0] += seconds }
            }
        }
        return total.keys.sorted().map {
            DayStat(day: $0, totalSeconds: total[$0] ?? 0, deepSeconds: deep[$0] ?? 0)
        }
    }

    // MARK: - Hour × weekday heatmap

    /// Seconds per (weekday, hour) cell. Splits each interval at hour boundaries so a
    /// multi-hour session spreads across the cells it actually occupied.
    public static func hourHeatmap(
        intervals: [Interval],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HourCell] {
        var acc: [HourKey: TimeInterval] = [:]
        for interval in intervals {
            let end = interval.end ?? now
            forEachHourSegment(start: interval.start, end: end, calendar: calendar) { segStart, segEnd in
                let seconds = segEnd.timeIntervalSince(segStart)
                guard seconds > 0 else { return }
                let comps = calendar.dateComponents([.weekday, .hour], from: segStart)
                let weekday = (comps.weekday ?? 1) - 1   // Calendar weekday is 1-based (1=Sun)
                let hour = comps.hour ?? 0
                acc[HourKey(weekday: weekday, hour: hour), default: 0] += seconds
            }
        }
        return acc
            .map { HourCell(weekday: $0.key.weekday, hour: $0.key.hour, seconds: $0.value) }
            .sorted { ($0.weekday, $0.hour) < ($1.weekday, $1.hour) }
    }

    // MARK: - Context switches

    /// Context switches per local day. A switch = an interval whose project differs from the
    /// chronologically preceding interval within the same local day.
    public static func switchesPerDay(
        intervals: [Interval],
        calendar: Calendar = .current
    ) -> [DaySwitches] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var counts: [Date: Int] = [:]
        var previousByDay: [Date: Int64] = [:]
        for interval in sorted {
            let day = calendar.startOfDay(for: interval.start)
            if counts[day] == nil { counts[day] = 0 }
            if let prev = previousByDay[day], prev != interval.projectID {
                counts[day, default: 0] += 1
            }
            previousByDay[day] = interval.projectID
        }
        return counts
            .map { DaySwitches(day: $0.key, switches: $0.value) }
            .sorted { $0.day < $1.day }
    }

    // MARK: - Segment iteration helpers

    /// Invokes `body(dayStart, segmentStart, segmentEnd)` for each local calendar day the
    /// [start, end) range touches, clipped to that day.
    static func forEachLocalDaySegment(
        start: Date,
        end: Date,
        calendar: Calendar,
        body: (Date, Date, Date) -> Void
    ) {
        guard end > start else { return }
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let segEnd = min(nextDay, end)
            body(dayStart, cursor, segEnd)
            cursor = segEnd
        }
    }

    /// Invokes `body(segmentStart, segmentEnd)` for each clock-hour the [start, end) range touches.
    static func forEachHourSegment(
        start: Date,
        end: Date,
        calendar: Calendar,
        body: (Date, Date) -> Void
    ) {
        guard end > start else { return }
        var cursor = start
        while cursor < end {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start
                ?? calendar.startOfDay(for: cursor)
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? end
            let segEnd = min(nextHour, end)
            body(cursor, segEnd)
            cursor = segEnd
        }
    }

    private struct DayProjectKey: Hashable { let day: Date; let projectID: Int64 }
    private struct HourKey: Hashable { let weekday: Int; let hour: Int }
}

// Tuple comparison helper for sorting.
private func < (lhs: (Date, Int64), rhs: (Date, Int64)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
    return lhs.1 < rhs.1
}
private func < (lhs: (Int, Int), rhs: (Int, Int)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
    return lhs.1 < rhs.1
}
