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

    public init(id: Int64, name: String, colorHex: String, sortOrder: Int, archived: Bool, finished: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.archived = archived
        self.finished = finished
    }
}

/// A single time interval: the append-only log unit. `end` is nil while running.
public struct Interval: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let projectID: Int64
    public let start: Date
    public let end: Date?

    public init(id: Int64, projectID: Int64, start: Date, end: Date?) {
        self.id = id
        self.projectID = projectID
        self.start = start
        self.end = end
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

    public init(id: Int64, projectID: Int64, startHour: Double, endHour: Double) {
        self.id = id
        self.projectID = projectID
        self.startHour = startHour
        self.endHour = endHour
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
