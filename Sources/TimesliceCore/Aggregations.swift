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

    /// Seconds per project clipped to an arbitrary range — the general form of `todayTotals`.
    ///
    /// Added because "Where time went" needs per-task totals for whatever range is selected, and
    /// without it every caller hand-rolls its own interval trimming. That trimming is exactly the
    /// midnight/DST-sensitive part, so a second copy of it is how the phone's totals would start
    /// disagreeing with the Mac's.
    public static func rangeTotals(
        projects: [Project],
        intervals: [Interval],
        range: DateRange,
        now: Date = Date()
    ) -> [ProjectTotal] {
        totals(projects: projects, intervals: intervals) {
            clip($0, windowStart: range.start, windowEnd: range.end, now: now)
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

    // MARK: - Ranged aggregation (drives the global metrics filter)

    /// Seconds per project within `range` (clipped to it). Includes archived tasks if passed in.
    public static func totals(
        projects: [Project], intervals: [Interval], range: DateRange,
        now: Date = Date()
    ) -> [ProjectTotal] {
        var byProject: [Int64: TimeInterval] = [:]
        for interval in intervals {
            let secs = clip(interval, windowStart: range.start, windowEnd: range.end, now: now)
            guard secs > 0 else { continue }
            byProject[interval.projectID, default: 0] += secs
        }
        return projects.map { ProjectTotal(project: $0, seconds: byProject[$0.id] ?? 0) }
    }

    /// Time under each tag over a range, plus an "untagged" bucket.
    ///
    /// UNIONed per tag, not summed: one tag can span several projects whose intervals overlap (two
    /// devices mid-handoff), and wall-clock shouldn't be double-counted. Across tags the totals
    /// legitimately exceed the range's tracked time, because a task can carry several tags — the UI
    /// says so rather than presenting them as a partition.
    ///
    /// Rows with no time are dropped, so a tag only appears once it has something in the range.
    public static func tagTotals(
        tags: [Tag], intervals: [Interval], tagIDsByTask: [Int64: Set<Int64>],
        range: DateRange, now: Date = Date()
    ) -> [TagTotal] {
        // Clip once, then fan each interval out to its tags — clipping per tag would repeat the
        // midnight/DST work for every tag a task carries.
        var spansByTag: [Int64: [(start: Date, end: Date)]] = [:]
        var untaggedSpans: [(start: Date, end: Date)] = []

        for interval in intervals {
            let end = interval.end ?? now
            let start = max(interval.start, range.start)
            let stop = min(end, range.end)
            guard stop > start else { continue }
            let span = (start: start, end: stop)

            let ids = tagIDsByTask[interval.projectID] ?? []
            if ids.isEmpty {
                untaggedSpans.append(span)
            } else {
                for id in ids { spansByTag[id, default: []].append(span) }
            }
        }

        var out: [TagTotal] = tags.compactMap { tag in
            guard let spans = spansByTag[tag.id] else { return nil }
            let secs = SpanUnion.coveredSeconds(spans)
            return secs > 0 ? TagTotal(tag: tag, seconds: secs) : nil
        }
        let untagged = SpanUnion.coveredSeconds(untaggedSpans)
        if untagged > 0 { out.append(TagTotal(tag: nil, seconds: untagged)) }
        // Largest first, matching the other breakdowns; untagged sorts by size like anything else.
        return out.sorted { $0.seconds > $1.seconds }
    }

    /// Per-bucket seconds for a sparkline over `range`, bucketed to match the filter: hours across a
    /// day, days across a week or month, weeks across six months, months across a year.
    ///
    /// Deliberately NOT `buckets(...)`, which collapses an hourly range to a single day bucket — that
    /// suits the hours-per-day chart (hidden on the day view) but would give a one-bar sparkline.
    ///
    /// Returns every bucket in the range including empty ones, so the shape shows gaps rather than
    /// silently compressing them.
    public static func sparkline(
        intervals: [Interval], range: DateRange, now: Date = Date(), calendar: Calendar = .current
    ) -> [TimeInterval] {
        let component: Calendar.Component = range.unit == .day ? .hour : range.unit.bucket
        var out: [TimeInterval] = []
        var cursor = range.start
        // Bounded so a pathological range can't spin: 400 buckets is past any useful sparkline.
        while cursor < range.end, out.count < 400 {
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            let stop = min(next, range.end)
            var secs: TimeInterval = 0
            for interval in intervals {
                let end = interval.end ?? now
                let s = max(interval.start, cursor), e = min(end, stop)
                if e > s { secs += e.timeIntervalSince(s) }
            }
            out.append(secs)
            cursor = next
        }
        return out
    }

    /// Which tasks a subject covers. Shared so a "show me only this" filter and the target maths
    /// can't disagree about what belongs to a tag or project.
    public static func taskIDs(
        for subject: TargetSubject, tasks: [Project], tagIDsByTask: [Int64: Set<Int64>]
    ) -> Set<Int64> {
        switch subject {
        case .task(let id):
            return [id]
        case .project(let id):
            return Set(tasks.filter { $0.taskProjectID == id }.map(\.id))
        case .tag(let id):
            return Set(tagIDsByTask.filter { $0.value.contains(id) }.map(\.key))
        }
    }

    /// Seconds tracked against a target's subject over a range, unioned.
    ///
    /// A tag subject fans out through `tagIDsByTask`; a project subject covers every task in it; a
    /// task subject is just that task. Union everywhere so a target can't be tripped by two devices
    /// overlapping during a handoff.
    public static func secondsForSubject(
        _ subject: TargetSubject,
        intervals: [Interval],
        tasks: [Project],
        tagIDsByTask: [Int64: Set<Int64>],
        range: DateRange,
        now: Date = Date()
    ) -> TimeInterval {
        let taskIDs = self.taskIDs(for: subject, tasks: tasks, tagIDsByTask: tagIDsByTask)
        guard !taskIDs.isEmpty else { return 0 }

        var spans: [(start: Date, end: Date)] = []
        for interval in intervals where taskIDs.contains(interval.projectID) {
            let end = interval.end ?? now
            let start = max(interval.start, range.start)
            let stop = min(end, range.end)
            if stop > start { spans.append((start, stop)) }
        }
        return SpanUnion.coveredSeconds(spans)
    }

    /// Roll per-task totals up to their groups. Pure post-processing on whatever `totals(...)`
    /// already produced, which is why this works identically for every range — bucketing,
    /// midnight-splitting and clipping all happen upstream and are blind to grouping.
    ///
    /// Tasks with no group collapse into a single Inbox row (`project == nil`). Zero-second rows
    /// are dropped so a group only appears once it has time in the range.
    public static func rollUp(
        totals: [ProjectTotal],
        taskProjects: [TaskProject]
    ) -> [TaskProjectTotal] {
        let byID = Dictionary(uniqueKeysWithValues: taskProjects.map { ($0.id, $0) })
        var seconds: [Int64?: TimeInterval] = [:]
        var counts: [Int64?: Int] = [:]
        for total in totals where total.seconds > 0 {
            let key = total.project.taskProjectID
            seconds[key, default: 0] += total.seconds
            counts[key, default: 0] += 1
        }
        return seconds
            .map { key, secs in
                TaskProjectTotal(project: key.flatMap { byID[$0] },
                                 seconds: secs,
                                 taskCount: counts[key] ?? 0)
            }
            // Biggest first; Inbox sorts by its own size like any other row.
            .sorted { $0.seconds > $1.seconds }
    }

    /// Bucketed totals across `range` — one entry per day/week/month depending on `range.unit`.
    /// Empty buckets are included (as zeros) so charts show gaps honestly.
    ///
    /// Bucket totals are the UNION of their spans: overlapping intervals would otherwise draw a
    /// bar taller than the time that actually elapsed, sailing past the goal line.
    public static func buckets(
        intervals: [Interval], range: DateRange, deepThreshold: TimeInterval,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [Bucket] {
        let component: Calendar.Component = range.unit.bucket == .hour ? .day : range.unit.bucket
        // Seed every bucket start in the window.
        var starts: [Date] = []
        var cursor = bucketStart(for: range.start, component: component, calendar: calendar)
        while cursor < range.end {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        let seeded = Set(starts)
        var spans: [Date: [(start: Date, end: Date)]] = [:]
        var deepSpans: [Date: [(start: Date, end: Date)]] = [:]

        for interval in intervals {
            let end = interval.end ?? now
            let isDeep = end.timeIntervalSince(interval.start) >= deepThreshold
            // Split by day, then fold each day's slice into its bucket — keeps DST/midnight correct.
            forEachLocalDaySegment(start: interval.start, end: end, calendar: calendar) { dayStart, segStart, segEnd in
                guard dayStart >= range.start && dayStart < range.end else { return }
                guard segEnd > segStart else { return }
                let key = bucketStart(for: dayStart, component: component, calendar: calendar)
                guard seeded.contains(key) else { return }
                spans[key, default: []].append((segStart, segEnd))
                if isDeep { deepSpans[key, default: []].append((segStart, segEnd)) }
            }
        }
        return starts.map { key in
            let t = SpanUnion.coveredSeconds(spans[key] ?? [])
            let d = SpanUnion.coveredSeconds(deepSpans[key] ?? [])
            return Bucket(start: key, totalSeconds: t, deepSeconds: min(d, t))
        }
    }

    private static func bucketStart(for date: Date, component: Calendar.Component,
                                    calendar: Calendar) -> Date {
        switch component {
        case .weekOfYear: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        case .month:      return calendar.dateInterval(of: .month, for: date)?.start ?? date
        default:          return calendar.startOfDay(for: date)
        }
    }

    /// Headline stats for `range`.
    ///
    /// Per-day figures are the UNION of that day's spans, not their sum — overlapping intervals
    /// (two devices, or older imports) would otherwise inflate a day past what physically elapsed
    /// and falsely clear the goal line. `deepSeconds` still sums, since "focused time" is about
    /// individual session lengths.
    /// A typical recent day, as the MEDIAN of days that had any tracking.
    ///
    /// The dashboard's gauge needs something to be a fraction of, and this app has no daily hours target —
    /// budgets are per project/tag/task. Rather than invent one or ask for it, compare today against your own
    /// recent behaviour, which is what Whoop's baselines do and needs no setup.
    ///
    /// **Median, not mean.** One 14-hour day would drag a mean up for a fortnight and make every ordinary day
    /// afterwards look like a failure. The median is unmoved by a couple of outliers either way.
    ///
    /// **Empty days are excluded.** Including them answers "how often do I track" when the question is "how much
    /// do I track on a day I'm working" — a fortnight containing two weekends would sit ~30% low and flatter
    /// every weekday against it. Weekend patterns are real, but they belong in the week chart, not in the
    /// denominator of today's gauge.
    ///
    /// **Today is excluded**, or the gauge would compare today against a baseline containing itself and drift
    /// toward 100% as the day went on — erasing exactly the signal wanted.
    ///
    /// Returns nil below `minimumDays`: a baseline from two days is noise, and a gauge with no honest denominator
    /// should be absent rather than wrong.
    public static func typicalDaySeconds(
        intervals: [Interval], lookbackDays: Int = 14, minimumDays: Int = 3,
        now: Date = Date(), calendar: Calendar = .current
    ) -> TimeInterval? {
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -lookbackDays, to: today) else { return nil }
        let window = DateRange(unit: .day, start: from, end: today)
        // `deepThreshold` is irrelevant here — only totals are read — so it's passed as infinity to make that
        // explicit rather than borrowing a settings value that has nothing to do with this.
        let totals = dayDigests(intervals: intervals, range: window, deepThreshold: .infinity,
                                now: now, calendar: calendar)
            .map(\.totalSeconds)
            .filter { $0 > 0 }
            .sorted()
        guard totals.count >= minimumDays else { return nil }
        let mid = totals.count / 2
        return totals.count.isMultiple(of: 2) ? (totals[mid - 1] + totals[mid]) / 2 : totals[mid]
    }

    /// Everything the week/month day-list needs, per day, in ONE pass.
    ///
    /// The list shows a row per day: the total, the day's SHAPE as a small bar, and the task it went mostly
    /// into. Getting those separately would mean `windowTotals` for the totals, `daySegments` per day for the
    /// shapes and `rangeTotals` per day for the top task — three traversals, two of them per-day. On a month
    /// that's ~60 passes over the whole history, which is exactly the cost that made the period strip take
    /// 190 ms.
    ///
    /// Union, not sum, for the total: two devices overlapping during a handoff must not inflate a day past
    /// the time that physically elapsed. `topTask` is by summed seconds rather than unioned, because "which
    /// task got most of this day" is a per-task question and no task overlaps itself.
    public static func dayDigests(
        intervals: [Interval], range: DateRange, deepThreshold: TimeInterval,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [DayDigest] {
        // Seed every day in the range, so a day with nothing tracked still gets a row — a gap in the week is
        // information, and omitting it would silently renumber the list.
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: range.start)
        while cursor < range.end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        guard !days.isEmpty else { return [] }
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1, $0) })

        var spans = [[(start: Date, end: Date)]](repeating: [], count: days.count)
        var deepSpans = spans
        var perTask = [[Int64: TimeInterval]](repeating: [:], count: days.count)
        // 24 buckets of covered seconds per day, turned into fractions at the end.
        var hourSeconds = [[Double]](repeating: [Double](repeating: 0, count: 24), count: days.count)

        for interval in intervals {
            let end = interval.end ?? now
            guard end > range.start, interval.start < range.end else { continue }
            let isDeep = end.timeIntervalSince(interval.start) >= deepThreshold
            forEachLocalDaySegment(start: interval.start, end: end, calendar: calendar) { dayStart, segStart, segEnd in
                guard segEnd > segStart, let i = index[dayStart] else { return }
                spans[i].append((segStart, segEnd))
                if isDeep { deepSpans[i].append((segStart, segEnd)) }
                perTask[i][interval.projectID, default: 0] += segEnd.timeIntervalSince(segStart)
                forEachHourSegment(start: segStart, end: segEnd, calendar: calendar) { hStart, hEnd in
                    let hour = calendar.component(.hour, from: hStart)
                    guard hour >= 0, hour < 24 else { return }
                    hourSeconds[i][hour] += hEnd.timeIntervalSince(hStart)
                }
            }
        }

        return days.enumerated().map { i, day in
            let total = SpanUnion.coveredSeconds(spans[i])
            let deep = SpanUnion.coveredSeconds(deepSpans[i])
            let top = perTask[i].max { $0.value < $1.value }
            return DayDigest(day: day,
                             totalSeconds: total,
                             deepSeconds: min(deep, total),
                             hourFill: hourSeconds[i].map { min(1, $0 / 3600) },
                             topTaskID: top?.key,
                             topTaskSeconds: top?.value ?? 0)
        }
    }

    /// Totals for MANY windows in ONE pass over the intervals.
    ///
    /// Exists because the obvious thing — call `summary` once per window — is O(windows x intervals), and
    /// that showed up as a measured 190 ms hitch building a 60-card period strip. Same arithmetic, one
    /// traversal: each interval is split by local day (so DST and midnight stay correct), each slice is
    /// filed into the window containing it, and each window's spans are UNIONED at the end.
    ///
    /// Union, not sum, for the same reason `summary` unions: two devices overlapping during a handoff would
    /// otherwise inflate a period past the time that physically elapsed.
    ///
    /// `windows` must be sorted ascending and non-overlapping — which is what stepping a `DateRange`
    /// produces. Returns one entry per window, in the same order, so callers can zip.
    public static func windowTotals(
        intervals: [Interval], windows: [DateRange], deepThreshold: TimeInterval,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [(total: TimeInterval, deep: TimeInterval)] {
        guard !windows.isEmpty else { return [] }
        var spans = [[(start: Date, end: Date)]](repeating: [], count: windows.count)
        var deepSpans = spans
        let starts = windows.map(\.start)
        let overallStart = starts[0]
        let overallEnd = windows[windows.count - 1].end

        for interval in intervals {
            let end = interval.end ?? now
            guard end > overallStart, interval.start < overallEnd else { continue }
            let isDeep = end.timeIntervalSince(interval.start) >= deepThreshold
            forEachLocalDaySegment(start: interval.start, end: end, calendar: calendar) { dayStart, segStart, segEnd in
                guard segEnd > segStart, dayStart >= overallStart, dayStart < overallEnd else { return }
                // Rightmost window whose start is <= this day. Binary search rather than a linear scan:
                // with 60 windows the scan is what the single pass was meant to remove.
                var lo = 0, hi = starts.count - 1, found = -1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    if starts[mid] <= dayStart { found = mid; lo = mid + 1 } else { hi = mid - 1 }
                }
                guard found >= 0, dayStart < windows[found].end else { return }
                spans[found].append((segStart, segEnd))
                if isDeep { deepSpans[found].append((segStart, segEnd)) }
            }
        }

        return (0..<windows.count).map { i in
            let t = SpanUnion.coveredSeconds(spans[i])
            let d = SpanUnion.coveredSeconds(deepSpans[i])
            return (total: t, deep: min(d, t))
        }
    }

    public static func summary(
        intervals: [Interval], range: DateRange, deepThreshold: TimeInterval,
        now: Date = Date(), calendar: Calendar = .current
    ) -> RangeSummary {
        // Collect each day's spans first, then union them per day.
        var spansByDay: [Date: [(start: Date, end: Date)]] = [:]
        var deepSpansByDay: [Date: [(start: Date, end: Date)]] = [:]
        var longest: TimeInterval = 0

        for interval in intervals {
            let end = interval.end ?? now
            let full = end.timeIntervalSince(interval.start)
            let isDeep = full >= deepThreshold
            var withinRange: TimeInterval = 0
            forEachLocalDaySegment(start: interval.start, end: end, calendar: calendar) { dayStart, segStart, segEnd in
                guard dayStart >= range.start && dayStart < range.end else { return }
                guard segEnd > segStart else { return }
                spansByDay[dayStart, default: []].append((segStart, segEnd))
                if isDeep { deepSpansByDay[dayStart, default: []].append((segStart, segEnd)) }
                withinRange += segEnd.timeIntervalSince(segStart)
            }
            guard withinRange > 0 else { continue }
            longest = max(longest, min(full, withinRange))
        }

        let perDay = spansByDay.mapValues { SpanUnion.coveredSeconds($0) }
        let total = perDay.values.reduce(0, +)
        // Deep time is also wall-clock (it feeds Focus %, a share of total), so union it too —
        // otherwise focus could exceed 100%.
        let deepTotal = deepSpansByDay.values.reduce(0) { $0 + SpanUnion.coveredSeconds($1) }

        let switchesInRange = switchesPerDay(intervals: intervals.filter { !$0.isRunning }, calendar: calendar)
            .filter { $0.day >= range.start && $0.day < range.end }
            .reduce(0) { $0 + $1.switches }

        return RangeSummary(
            totalSeconds: total,
            deepSeconds: min(deepTotal, total),   // can't be more focused than tracked
            activeDays: perDay.values.filter { $0 > 0 }.count,
            switches: switchesInRange,
            longestSessionSeconds: longest,
            bestDaySeconds: perDay.values.max() ?? 0
        )
    }

    /// Average seconds per weekday across the active days in `range`.
    public static func weekdayAverages(
        intervals: [Interval], range: DateRange, now: Date = Date(), calendar: Calendar = .current
    ) -> [WeekdayAverage] {
        var perDay: [Date: TimeInterval] = [:]
        for interval in intervals {
            let end = interval.end ?? now
            forEachLocalDaySegment(start: interval.start, end: end, calendar: calendar) { dayStart, segStart, segEnd in
                guard dayStart >= range.start && dayStart < range.end else { return }
                perDay[dayStart, default: 0] += segEnd.timeIntervalSince(segStart)
            }
        }
        var sum = [Int: TimeInterval](); var count = [Int: Int]()
        for (day, secs) in perDay {
            let wd = (calendar.component(.weekday, from: day)) - 1   // 0=Sun
            sum[wd, default: 0] += secs
            count[wd, default: 0] += 1
        }
        return (0..<7).map { wd in
            let n = count[wd] ?? 0
            return WeekdayAverage(weekday: wd, averageSeconds: n > 0 ? (sum[wd] ?? 0) / Double(n) : 0)
        }
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
    /// `deviceOrder` is the canonical device order from `DeviceOrder`; lanes follow it so the
    /// timeline and the device list agree. Omit it and devices fall back to sorting by id.
    public static func daySegments(
        intervals: [Interval],
        day: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        deviceOrder: [String] = []
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
                                       startHour: startHour, endHour: endHour,
                                       deviceID: interval.deviceID))
        }
        return assignLanes(segments.sorted { $0.startHour < $1.startHour },
                           deviceOrder: deviceOrder)
    }

    /// Lane packing so overlapping segments never hide each other on the timeline.
    ///
    /// When more than one device contributed to the day, lanes are assigned BY DEVICE — one row per
    /// machine, in first-appearance order — so a row is a label the UI can name. Packing purely by
    /// overlap would put a single device's overlapping blocks on separate rows and interleave two
    /// devices onto one, making "which row is which machine" unanswerable.
    ///
    /// With a single device (the normal case) everything lands in lane 0 and the timeline looks
    /// exactly as before; within that lane, overlaps still fan out so nothing is hidden.
    public static func assignLanes(_ sorted: [DaySegment],
                                   deviceOrder: [String] = []) -> [DaySegment] {
        let devices = orderedDevices(sorted, deviceOrder: deviceOrder)
        guard devices.count > 1 else { return packByOverlap(sorted, baseLane: 0) }

        // Each device gets a contiguous block of lanes, sized to its own internal overlap, so two
        // devices never share a row and one device's overlaps still stay visible.
        var out: [DaySegment] = []
        var nextLane = 0
        for device in devices {
            let mine = sorted.filter { $0.deviceID == device }
            let packed = packByOverlap(mine, baseLane: nextLane)
            nextLane = (packed.map(\.lane).max() ?? nextLane) + 1
            out.append(contentsOf: packed)
        }
        return out.sorted { $0.startHour < $1.startHour }
    }

    /// Lanes packed purely by TIME OVERLAP, ignoring which device recorded what.
    ///
    /// `assignLanes` gives every device its own lane whenever more than one contributed, so three
    /// devices produce three rows even when their blocks never overlap in time. That reads as
    /// "these ran concurrently" when they didn't, and on a phone it costs three rows to say what one
    /// row says. Device attribution is still available — the per-device totals under the strip and
    /// the tap inspector both name it — so nothing is lost by collapsing rows that don't collide.
    ///
    /// The Mac keeps `assignLanes`; this exists for surfaces where vertical space is the scarce
    /// resource and only genuine overlap deserves a second row.
    public static func assignLanesByOverlap(_ segments: [DaySegment]) -> [DaySegment] {
        packByOverlap(segments.sorted { $0.startHour < $1.startHour }, baseLane: 0)
            .sorted { $0.startHour < $1.startHour }
    }

    public static func orderedDevices(_ segments: [DaySegment],
                                      deviceOrder: [String] = []) -> [String?] {
        // Sorted by id, NOT by first appearance. First-appearance order changed as soon as an
        // earlier block arrived from a peer, so a device's row moved on its own between syncs —
        // whichever device happened to have the earliest synced block took the top lane. Sorting by
        // a fixed key keeps a device on the same row all day, regardless of what has arrived yet.
        //
        // nil (unattributed, pre-attribution rows) sorts last so named devices keep the top lanes.
        // A device absent from THIS day simply contributes no lane; the ones present keep their
        // relative order, so scrubbing back through days doesn't reshuffle the rows either.
        let ids = Set(segments.map(\.deviceID))
        let rank = Dictionary(uniqueKeysWithValues: deviceOrder.enumerated().map { ($1, $0) })
        let named = ids.compactMap { $0 }.sorted {
            // Anything the caller didn't rank sorts after everything it did, by id, so an
            // unlabelled straggler is still placed deterministically.
            (rank[$0] ?? Int.max, $0) < (rank[$1] ?? Int.max, $1)
        }
        return named.map { Optional($0) } + (ids.contains(nil) ? [nil] : [])
    }

    /// Greedy first-fit: each segment takes the lowest free lane at or after `baseLane`.
    private static func packByOverlap(_ segments: [DaySegment], baseLane: Int) -> [DaySegment] {
        var laneEnds: [Double] = []          // last end-hour per lane
        return segments.sorted { $0.startHour < $1.startHour }.map { seg in
            var placed = seg
            if let lane = laneEnds.firstIndex(where: { $0 <= seg.startHour }) {
                laneEnds[lane] = seg.endHour
                placed.lane = baseLane + lane
            } else {
                laneEnds.append(seg.endHour)
                placed.lane = baseLane + laneEnds.count - 1
            }
            return placed
        }
    }

    /// How many lanes `segments` needs — 1 when nothing overlaps.
    public static func laneCount(_ segments: [DaySegment]) -> Int {
        (segments.map(\.lane).max() ?? 0) + 1
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
