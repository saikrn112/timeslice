import Foundation

/// A flat label attached to a project or an individual task.
///
/// Tags deliberately are NOT a third level of hierarchy above projects. They overlap freely and
/// don't have to cover everything, so a task can be in "office" and "side projects" at once and
/// nothing new has to be filled in when creating one. The cost of that freedom is that per-tag
/// totals don't sum to your tracked time — see `TagTotal`.
public struct Tag: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let colorHex: String
    public let sortOrder: Int

    public init(id: Int64, name: String, colorHex: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }
}

/// What a tag link or a target points at.
///
/// One enum for both, so adding a subject type later doesn't fork the schema or the query paths.
public enum TargetSubject: Hashable, Sendable {
    case task(Int64)
    case project(Int64)
    case tag(Int64)

    /// Stored in `subject_kind`.
    public var kind: String {
        switch self {
        case .task: return "task"
        case .project: return "project"
        case .tag: return "tag"
        }
    }

    public var id: Int64 {
        switch self {
        case .task(let id), .project(let id), .tag(let id): return id
        }
    }

    public init?(kind: String, id: Int64) {
        switch kind {
        case "task": self = .task(id)
        case "project": self = .project(id)
        case "tag": self = .tag(id)
        default: return nil
        }
    }
}

/// Hours spent under one tag over a range.
///
/// `seconds` is UNIONed, not summed: a tag can span several projects whose intervals overlap (two
/// devices during a handoff), and wall-clock time shouldn't be counted twice. Because tags overlap
/// each other, totals across tags can exceed the range's tracked time — that's expected, and the UI
/// says so rather than looking broken.
public struct TagTotal: Identifiable, Hashable, Sendable {
    public let tag: Tag?          // nil == the "untagged" bucket
    public let seconds: TimeInterval

    public var id: Int64 { tag?.id ?? -1 }
    public var name: String { tag?.name ?? "untagged" }
    public var colorHex: String { tag?.colorHex ?? "#8E8E93" }

    public init(tag: Tag?, seconds: TimeInterval) {
        self.tag = tag
        self.seconds = seconds
    }
}

/// A time budget: spend at least (or at most) `seconds` on `subject` per `period`.
public struct Target: Identifiable, Hashable, Sendable {
    public enum Direction: String, Sendable, CaseIterable {
        case atLeast, atMost

        /// Shown next to the number, so a floor and a ceiling are distinguishable at a glance.
        public var symbol: String { self == .atLeast ? "≥" : "≤" }
    }

    public enum Period: String, Sendable, CaseIterable {
        case day, week, month

        /// Nominal length, used to normalise a target onto a range of a different size.
        /// A month is 30 days here: targets are intentions, not accounting, and a calendar-exact
        /// month would make the same target read differently in February than in March.
        public var nominalDays: Double {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 30
            }
        }
    }

    public let id: Int64
    public let subject: TargetSubject
    public let seconds: TimeInterval
    public let direction: Direction
    public let period: Period
    /// When this allocation started, and when it was retired (nil while live).
    public let createdAt: Date
    public let completedAt: Date?
    /// Manual position in the allocations list.
    public let sortOrder: Int

    public var isLive: Bool { completedAt == nil }

    public init(id: Int64, subject: TargetSubject, seconds: TimeInterval,
                direction: Direction, period: Period,
                createdAt: Date = Date(), completedAt: Date? = nil, sortOrder: Int = 0) {
        self.id = id
        self.subject = subject
        self.seconds = seconds
        self.direction = direction
        self.period = period
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.sortOrder = sortOrder
    }
}

/// A retired allocation, measured over the span it was live for.
public struct AllocationHistory: Identifiable, Sendable {
    public let target: Target
    public let name: String
    /// The span actually measured: creation to completion.
    public let start: Date
    public let end: Date
    /// Amount × whole-and-part periods in the span.
    public let allocatedSeconds: TimeInterval
    /// Unioned actual time on the subject across the span.
    public let spentSeconds: TimeInterval

    public var id: Int64 { target.id }
    public var deltaSeconds: TimeInterval { spentSeconds - allocatedSeconds }

    /// Spent as a share of allocated. Over 100 means more time went in than was set aside — which for
    /// a ceiling is the failure and for a floor is the success, so the UI supplies the judgement.
    public var percent: Double {
        allocatedSeconds > 0 ? spentSeconds / allocatedSeconds * 100 : 0
    }

    public init(target: Target, name: String, start: Date, end: Date,
                allocatedSeconds: TimeInterval, spentSeconds: TimeInterval) {
        self.target = target
        self.name = name
        self.start = start
        self.end = end
        self.allocatedSeconds = allocatedSeconds
        self.spentSeconds = spentSeconds
    }
}

/// A target measured against actual tracked time over the range being viewed.
public struct TargetProgress: Identifiable, Sendable {
    public enum Verdict: Sendable {
        /// A floor that's been reached, or a ceiling still respected.
        case met
        /// A floor not yet reached, but on track for the elapsed part of the period.
        case onPace
        /// A floor that's falling behind the elapsed part of the period.
        case behind
        /// A ceiling that's been exceeded.
        case over
    }

    public let target: Target
    /// Human-facing label for the subject, resolved by the caller (tags/projects/tasks live in
    /// different tables, so the pure layer doesn't look them up).
    public let name: String
    public let actualSeconds: TimeInterval
    /// The target scaled to the viewed range — a weekly target over a month expects ~4.3×.
    public let expectedSeconds: TimeInterval
    /// How far through the range we are, 0…1. 1 for a range that has fully elapsed.
    public let elapsedFraction: Double
    public let verdict: Verdict
    /// Calendar days of the period that have begun, at least 1. The divisor for the daily average.
    public let daysElapsed: Double
    /// Length of the period in days. Stored rather than derived from `daysElapsed / elapsedFraction`
    /// — `daysElapsed` is rounded UP, so that division overestimated the period (7.8 days for a
    /// week) and understated the pace needed to catch up.
    public let periodDays: Double
    /// Time on this subject TODAY, supplied by the caller (it needs a separate query).
    public let todaySeconds: TimeInterval

    /// This subject's time within the RANGE BEING VIEWED.
    public let rangeSeconds: TimeInterval

    /// The target PRO-RATED onto the viewed range: a 7h weekly budget is 1h on a single day.
    ///
    /// A second reading of the same commitment at whatever zoom you're looking at, so the right-hand
    /// bar answers "am I on track *today*" while the left answers "am I on track this week". Note it
    /// assumes an even spread across every day of the period, weekends included — a 40h/week budget
    /// becomes 5h43m/day rather than 8h across five days.
    public let rangeExpectedSeconds: TimeInterval

    /// Progress against the pro-rated target. Can exceed 100, same as `percent`.
    public var rangePercent: Double {
        guard rangeExpectedSeconds > 0 else { return 0 }
        return rangeSeconds / rangeExpectedSeconds * 100
    }

    /// The period's total spread over ALL its days — 19h43m in a week is 2h49m/day.
    ///
    /// Divided by the full period (7), not the days elapsed (6). Two reasons: it's directly
    /// comparable to the target on the same basis (40h/week is 5h43m/day), and it doesn't drift as
    /// the week progresses, so the figure means the same thing whenever you look and whatever range
    /// the page is filtered to. The trade-off is that early in a period it reads low, because it
    /// counts days you haven't lived yet.
    public var averagePerDaySeconds: TimeInterval {
        periodDays > 0 ? actualSeconds / periodDays : 0
    }

    /// What a daily average would have to be over the remaining days to land on target. Nil once the
    /// period is over, or when there's nothing left to make up.
    public var requiredPerDaySeconds: TimeInterval? {
        let remainingDays = periodDays - daysElapsed
        guard remainingDays > 0.01 else { return nil }
        let shortfall = expectedSeconds - actualSeconds
        guard shortfall > 0 else { return nil }
        return shortfall / remainingDays
    }

    public var id: Int64 { target.id }

    /// Progress against the expectation, as a percentage. Can exceed 100 — for a ceiling that's
    /// exactly the signal you want to see.
    public var percent: Double {
        guard expectedSeconds > 0 else { return 0 }
        return actualSeconds / expectedSeconds * 100
    }

    /// Signed distance from the expectation. Positive means more time than the target.
    public var deltaSeconds: TimeInterval { actualSeconds - expectedSeconds }

    public init(target: Target, name: String, actualSeconds: TimeInterval,
                expectedSeconds: TimeInterval, elapsedFraction: Double, verdict: Verdict,
                daysElapsed: Double = 1, periodDays: Double = 1,
                todaySeconds: TimeInterval = 0,
                rangeSeconds: TimeInterval = 0, rangeExpectedSeconds: TimeInterval = 0) {
        self.target = target
        self.name = name
        self.actualSeconds = actualSeconds
        self.expectedSeconds = expectedSeconds
        self.elapsedFraction = elapsedFraction
        self.verdict = verdict
        self.daysElapsed = daysElapsed
        self.periodDays = periodDays
        self.todaySeconds = todaySeconds
        self.rangeSeconds = rangeSeconds
        self.rangeExpectedSeconds = rangeExpectedSeconds
    }
}

public enum TargetMath {

    /// How much a live-for-`span` allocation added up to.
    ///
    /// Fractional periods count pro-rata: an allocation retired mid-week allocated part of that week,
    /// not all or none of it. Computed from the CURRENT amount, so editing the number during an
    /// allocation's life retroactively changes its history — acceptable because a retired allocation
    /// stops changing, and the honest alternative is versioning every edit.
    public static func allocated(_ target: Target, from start: Date, to end: Date) -> TimeInterval {
        let days = max(0, end.timeIntervalSince(start)) / 86_400
        return target.seconds * days / max(target.period.nominalDays, 0.0001)
    }

    /// Where to measure a budget's period from, given the range being viewed.
    ///
    /// `now` while the viewed range contains it — that's what keeps "on pace" meaningful — otherwise a
    /// point inside the range. Anchoring at `now` unconditionally meant navigating back a week still
    /// reported the CURRENT week, so the budget section contradicted every other number on the page.
    ///
    /// For a past range the anchor is one second inside the end, not the end itself: `rangeEnd` is
    /// exclusive, so for a week it IS the following Sunday and would resolve to the wrong week.
    public static func periodAnchor(rangeStart: Date, rangeEnd: Date, now: Date = Date()) -> Date {
        if now >= rangeStart && now < rangeEnd { return now }
        return now < rangeStart ? rangeStart : rangeEnd.addingTimeInterval(-1)
    }

    /// Measure `target` against `actualSeconds` tracked over [rangeStart, rangeEnd).
    ///
    /// The target is normalised onto the range rather than only shown when the periods match, so a
    /// weekly ceiling is still answerable while you're looking at a month. `now` decides how much of
    /// the range has elapsed, which is what separates "behind" from "not finished yet": a 30h weekly
    /// floor sitting at 15h on Wednesday is on pace, and calling that a failure would train you to
    /// ignore the number.
    public static func progress(
        target: Target,
        name: String,
        actualSeconds: TimeInterval,
        rangeStart: Date,
        rangeEnd: Date,
        now: Date = Date(),
        todaySeconds: TimeInterval = 0,
        rangeSeconds: TimeInterval = 0,
        /// Length of the range being VIEWED, in days — used to pro-rate the target onto it.
        viewedRangeDays: Double = 0
    ) -> TargetProgress {
        let rangeDays = max(0, rangeEnd.timeIntervalSince(rangeStart)) / 86_400
        let scale = target.period.nominalDays > 0 ? rangeDays / target.period.nominalDays : 0
        let expected = target.seconds * scale

        // Clamped so a range entirely in the past counts as fully elapsed and one entirely in the
        // future counts as not started, instead of extrapolating past either end.
        let total = rangeEnd.timeIntervalSince(rangeStart)
        let elapsed = total > 0
            ? min(max(now.timeIntervalSince(rangeStart) / total, 0), 1)
            : 1

        let verdict: TargetProgress.Verdict
        switch target.direction {
        case .atMost:
            // A ceiling is judged against the WHOLE expectation, not the elapsed part: spending the
            // week's entire allowance on Monday isn't over budget yet, it's just used up.
            verdict = actualSeconds > expected ? .over : .met
        case .atLeast:
            if actualSeconds >= expected {
                verdict = .met
            } else if actualSeconds >= expected * elapsed {
                verdict = .onPace
            } else {
                verdict = .behind
            }
        }

        // Days that have BEGUN, so the average divides by 6 on a Friday rather than 5 — a partial
        // day still counts as a day you had.
        let daysElapsed = max(1, (rangeDays * elapsed).rounded(.up))

        return TargetProgress(target: target, name: name, actualSeconds: actualSeconds,
                              expectedSeconds: expected, elapsedFraction: elapsed,
                              verdict: verdict, daysElapsed: daysElapsed,
                              periodDays: max(1, rangeDays), todaySeconds: todaySeconds,
                              rangeSeconds: rangeSeconds,
                              rangeExpectedSeconds: target.seconds * viewedRangeDays
                                  / max(target.period.nominalDays, 0.0001))
    }
}
