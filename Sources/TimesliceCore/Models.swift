import Foundation

/// A tracked project (a row in the UI).
public struct Project: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var name: String
    public var colorHex: String
    public var sortOrder: Int
    public var archived: Bool
    /// Finished = done but still counted in Today/All-Time (struck-through at list end).
    /// Distinct from `archived`, which removes the task from those views entirely.
    public var finished: Bool
    /// When it was marked done — a task finished today stays visible (struck through) for the rest
    /// of the day, then drops out of Today while remaining in All Time.
    public var finishedAt: Date?
    /// The group this task rolls up to; nil = Inbox (uncategorised).
    public var taskProjectID: Int64?

    public init(id: Int64, name: String, colorHex: String, sortOrder: Int, archived: Bool,
                finished: Bool = false, finishedAt: Date? = nil, taskProjectID: Int64? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.archived = archived
        self.finished = finished
        self.finishedAt = finishedAt
        self.taskProjectID = taskProjectID
    }

    /// True when this task should still appear in the Today list: not finished, or finished today.
    public func showsInToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard finished else { return true }
        guard let finishedAt else { return false }   // finished before we tracked the date
        return calendar.isDate(finishedAt, inSameDayAs: now)
    }
}

/// A grouping above tasks. Named `TaskProject` because the `projects` DB table (and the `Project`
/// type above) actually hold *tasks* — early naming that predates this layer.
///
/// Tasks reference these; intervals never do. Grouping is therefore a display-time rollup, not a
/// property of recorded time.
public struct TaskProject: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var name: String
    public var colorHex: String
    public var sortOrder: Int

    public init(id: Int64, name: String, colorHex: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }
}

/// Seconds rolled up to a group. `project == nil` is the Inbox bucket.
public struct TaskProjectTotal: Identifiable, Hashable, Sendable {
    public let project: TaskProject?
    public let seconds: TimeInterval
    /// Tasks contributing to this group, largest first.
    public let taskCount: Int

    /// -1 stands in for Inbox so the type can be `Identifiable` without an optional id.
    public var id: Int64 { project?.id ?? -1 }
    public var name: String { project?.name ?? "Inbox" }
    public var colorHex: String { project?.colorHex ?? "#8E8E93" }

    public init(project: TaskProject?, seconds: TimeInterval, taskCount: Int) {
        self.project = project
        self.seconds = seconds
        self.taskCount = taskCount
    }
}

/// A single time interval: the append-only log unit. `end` is nil while running.
public struct Interval: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let projectID: Int64
    public let start: Date
    public let end: Date?
    /// Which device recorded this. nil for rows written before device attribution existed.
    public let deviceID: String?

    public init(id: Int64, projectID: Int64, start: Date, end: Date?, deviceID: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.start = start
        self.end = end
        self.deviceID = deviceID
    }

    public var isRunning: Bool { end == nil }

    /// Seconds elapsed, treating an open interval as ending `now`.
    public func seconds(now: Date = Date()) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }
}

/// The single currently-running interval, if any.
public struct RunningInterval: Hashable, Sendable {
    public let id: Int64
    public let projectID: Int64
    public let start: Date

    public init(id: Int64, projectID: Int64, start: Date) {
        self.id = id
        self.projectID = projectID
        self.start = start
    }
}

/// Aggregated total seconds for one project (Today or all-time, depending on the query window).
public struct ProjectTotal: Identifiable, Hashable, Sendable {
    public let project: Project
    public let seconds: TimeInterval
    public var id: Int64 { project.id }

    public init(project: Project, seconds: TimeInterval) {
        self.project = project
        self.seconds = seconds
    }
}

/// Seconds spent on a project on a specific local calendar day (for stacked daily bars).
public struct DailyBucket: Hashable, Sendable {
    public let day: Date          // startOfDay, local
    public let projectID: Int64
    public let seconds: TimeInterval

    public init(day: Date, projectID: Int64, seconds: TimeInterval) {
        self.day = day
        self.projectID = projectID
        self.seconds = seconds
    }
}

/// Seconds spent in a given (weekday, hour) cell for the heatmap. weekday: 0=Sunday…6=Saturday.
public struct HourCell: Hashable, Sendable {
    public let weekday: Int
    public let hour: Int
    public let seconds: TimeInterval

    public init(weekday: Int, hour: Int, seconds: TimeInterval) {
        self.weekday = weekday
        self.hour = hour
        self.seconds = seconds
    }
}

/// A task segment within a single day, positioned by hour-of-day (0…24) for the day timeline.
public struct DaySegment: Hashable, Sendable, Identifiable {
    public let id: Int64            // source interval id
    public let projectID: Int64
    public let startHour: Double    // 0…24, local
    public let endHour: Double      // 0…24, local (> startHour)
    /// Which horizontal sub-lane to draw in. 0 unless this segment overlaps another, in which
    /// case overlapping segments get distinct lanes so neither hides the other on the timeline.
    public var lane: Int = 0
    /// Device that recorded it; nil for rows predating device attribution.
    public let deviceID: String?

    public init(id: Int64, projectID: Int64, startHour: Double, endHour: Double, lane: Int = 0,
                deviceID: String? = nil) {
        self.id = id
        self.lane = lane
        self.projectID = projectID
        self.startHour = startHour
        self.endHour = endHour
        self.deviceID = deviceID
    }
}

/// One bucket (day / week / month) of a ranged chart.
public struct Bucket: Hashable, Sendable, Identifiable {
    public let start: Date            // bucket start, local
    public let totalSeconds: TimeInterval
    public let deepSeconds: TimeInterval
    public var id: Date { start }

    public init(start: Date, totalSeconds: TimeInterval, deepSeconds: TimeInterval) {
        self.start = start
        self.totalSeconds = totalSeconds
        self.deepSeconds = deepSeconds
    }

    public var focusRatio: Double { totalSeconds > 0 ? deepSeconds / totalSeconds : 0 }
}

/// Headline numbers for whatever range is selected.
public struct RangeSummary: Sendable {
    public let totalSeconds: TimeInterval
    public let deepSeconds: TimeInterval
    public let activeDays: Int
    public let daysOnGoal: Int
    public let switches: Int
    public let longestSessionSeconds: TimeInterval
    public let bestDaySeconds: TimeInterval

    public init(totalSeconds: TimeInterval, deepSeconds: TimeInterval, activeDays: Int,
                daysOnGoal: Int, switches: Int, longestSessionSeconds: TimeInterval,
                bestDaySeconds: TimeInterval) {
        self.totalSeconds = totalSeconds
        self.deepSeconds = deepSeconds
        self.activeDays = activeDays
        self.daysOnGoal = daysOnGoal
        self.switches = switches
        self.longestSessionSeconds = longestSessionSeconds
        self.bestDaySeconds = bestDaySeconds
    }

    public var focusRatio: Double { totalSeconds > 0 ? deepSeconds / totalSeconds : 0 }
    public var avgPerActiveDay: TimeInterval { activeDays > 0 ? totalSeconds / Double(activeDays) : 0 }
}

/// Average seconds per weekday (0=Sunday…6=Saturday) across a range.
public struct WeekdayAverage: Hashable, Sendable, Identifiable {
    public let weekday: Int
    public let averageSeconds: TimeInterval
    public var id: Int { weekday }

    public init(weekday: Int, averageSeconds: TimeInterval) {
        self.weekday = weekday
        self.averageSeconds = averageSeconds
    }
}

/// One day's totals for the daily-hours chart and focus trend.
public struct DayStat: Hashable, Sendable, Identifiable {
    public let day: Date              // local startOfDay
    public let totalSeconds: TimeInterval
    public let deepSeconds: TimeInterval   // time in sessions >= the deep-block threshold
    public var id: Date { day }

    public init(day: Date, totalSeconds: TimeInterval, deepSeconds: TimeInterval) {
        self.day = day
        self.totalSeconds = totalSeconds
        self.deepSeconds = deepSeconds
    }

    /// Fraction of the day's time spent in deep blocks (0…1). Zero when no time tracked.
    public var focusRatio: Double {
        totalSeconds > 0 ? deepSeconds / totalSeconds : 0
    }
}

/// Count of context switches on a given local day.
public struct DaySwitches: Hashable, Sendable {
    public let day: Date
    public let switches: Int

    public init(day: Date, switches: Int) {
        self.day = day
        self.switches = switches
    }
}

public enum TimesliceError: Error, LocalizedError {
    case database(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .database(code, message):
            return "Timeslice DB error \(code): \(message)"
        }
    }
}
