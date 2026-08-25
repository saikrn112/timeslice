import Foundation

/// Wall-clock seconds covered by a set of possibly-overlapping spans.
///
/// The one place that answers "how much real time did this cover?". Summing span lengths instead
/// double-counts: two devices can log overlapping intervals (and older imports already contain
/// them), which reports more time than physically elapsed — a 2h overlap turns an 8h day into 10h,
/// clears the goal line, and can push a day past 24h.
///
/// The rule across the app:
///   • per-day / per-range WALL-CLOCK → union (this)
///   • per-task totals               → sum (Σ per-task ≥ wall-clock, by design)
public enum SpanUnion {

    /// Total covered seconds of `spans`, counting overlaps once.
    public static func coveredSeconds(_ spans: [(start: Date, end: Date)]) -> TimeInterval {
        guard !spans.isEmpty else { return 0 }
        var covered: TimeInterval = 0
        var cursor: Date?
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.end > span.start else { continue }
            let start = cursor.map { max(span.start, $0) } ?? span.start
            guard span.end > start else { continue }   // wholly inside an already-counted span
            covered += span.end.timeIntervalSince(start)
            cursor = max(cursor ?? span.end, span.end)
        }
        return covered
    }

    /// Same, for spans already expressed as hours-of-day (0…24).
    public static func coveredHours(_ spans: [(start: Double, end: Double)]) -> Double {
        guard !spans.isEmpty else { return 0 }
        var covered = 0.0
        var cursor: Double?
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.end > span.start else { continue }
            let start = cursor.map { max(span.start, $0) } ?? span.start
            guard span.end > start else { continue }
            covered += span.end - start
            cursor = max(cursor ?? span.end, span.end)
        }
        return covered
    }
}
