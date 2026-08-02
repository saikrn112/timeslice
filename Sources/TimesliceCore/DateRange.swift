import Foundation

/// The global metrics filter: a granularity plus an anchor date, resolved into a concrete window.
/// One of these drives every tile and chart, so they can never disagree with each other.
public enum RangeUnit: String, CaseIterable, Sendable {
    case day = "D"
    case week = "W"
    case month = "M"
    case sixMonths = "6M"
    case year = "Y"
    case all = "All"

    /// How data is bucketed for bar/trend charts over this range.
    public var bucket: Calendar.Component {
        switch self {
        case .day: return .hour          // (timeline handles the day view itself)
        case .week, .month: return .day
        case .sixMonths: return .weekOfYear
        case .year, .all: return .month
        }
    }
}

/// A resolved window: `[start, end)` in local time, plus the unit that produced it.
public struct DateRange: Equatable, Sendable {
    public let unit: RangeUnit
    public let start: Date
    public let end: Date

    public init(unit: RangeUnit, start: Date, end: Date) {
        self.unit = unit
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Resolve `unit` around `anchor`. For `.all`, `earliest` bounds the start (falls back to
    /// one year back when there's no data yet).
    public static func resolve(unit: RangeUnit, anchor: Date, earliest: Date? = nil,
                              calendar: Calendar = .current) -> DateRange {
        let dayStart = calendar.startOfDay(for: anchor)
        switch unit {
        case .day:
            return DateRange(unit: unit, start: dayStart,
                             end: calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
        case .week:
            let s = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? dayStart
            return DateRange(unit: unit, start: s,
                             end: calendar.date(byAdding: .weekOfYear, value: 1, to: s) ?? s)
        case .month:
            let s = calendar.dateInterval(of: .month, for: anchor)?.start ?? dayStart
            return DateRange(unit: unit, start: s,
                             end: calendar.date(byAdding: .month, value: 1, to: s) ?? s)
        case .sixMonths:
            let monthStart = calendar.dateInterval(of: .month, for: anchor)?.start ?? dayStart
            let e = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            let s = calendar.date(byAdding: .month, value: -6, to: e) ?? monthStart
            return DateRange(unit: unit, start: s, end: e)
        case .year:
            let s = calendar.dateInterval(of: .year, for: anchor)?.start ?? dayStart
            return DateRange(unit: unit, start: s,
                             end: calendar.date(byAdding: .year, value: 1, to: s) ?? s)
        case .all:
            let e = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let s = earliest.map { calendar.startOfDay(for: $0) }
                ?? calendar.date(byAdding: .year, value: -1, to: e) ?? e
            return DateRange(unit: unit, start: s, end: e)
        }
    }

    /// Step the window by `delta` units (−1 = previous, +1 = next). `.all` doesn't step.
    public func stepped(by delta: Int, earliest: Date? = nil, calendar: Calendar = .current) -> DateRange {
        guard unit != .all else { return self }
        let component: Calendar.Component
        let amount: Int
        switch unit {
        case .day:       component = .day;        amount = delta
        case .week:      component = .weekOfYear; amount = delta
        case .month:     component = .month;      amount = delta
        case .sixMonths: component = .month;      amount = delta * 6
        case .year:      component = .year;       amount = delta
        case .all:       component = .day;        amount = 0
        }
        let newAnchor = calendar.date(byAdding: component, value: amount, to: start) ?? start
        return DateRange.resolve(unit: unit, anchor: newAnchor, earliest: earliest, calendar: calendar)
    }

    /// True when this window includes right now (i.e. we're at the present edge).
    public func isCurrent(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        contains(now)
    }

    /// Human label for the range bar.
    public func label(calendar: Calendar = .current, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        switch unit {
        case .day:
            if calendar.isDateInToday(start) { return "Today" }
            if calendar.isDateInYesterday(start) { return "Yesterday" }
            f.dateFormat = "EEE, MMM d yyyy"
            return f.string(from: start)
        case .week:
            f.dateFormat = "MMM d"
            let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            let lf = DateFormatter(); lf.calendar = calendar; lf.dateFormat = "MMM d, yyyy"
            return "\(f.string(from: start)) – \(lf.string(from: last))"
        case .month:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: start)
        case .sixMonths:
            f.dateFormat = "MMM yyyy"
            let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            return "\(f.string(from: start)) – \(f.string(from: last))"
        case .year:
            f.dateFormat = "yyyy"
            return f.string(from: start)
        case .all:
            return "All time"
        }
    }
}
