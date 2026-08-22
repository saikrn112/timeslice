import Foundation

/// Tracked vs untracked time inside an arbitrary slice of a day, plus the per-task split.
///
/// The day-level "Tracked" tile answers "how much of today did I record?", which isn't much use
/// for a specific stretch — you weren't working all day. This answers the same question for a
/// range you select on the timeline.
public struct WindowSummary: Equatable, Sendable {
    /// Bounds of the selection, in local hours (0…24).
    public let startHour: Double
    public let endHour: Double
    /// Seconds inside the window covered by *some* task.
    public let trackedSeconds: TimeInterval
    /// Seconds inside the window covered by nothing.
    public let idleSeconds: TimeInterval
    /// Per-task tracked seconds, largest first.
    public let byProject: [(projectID: Int64, seconds: TimeInterval)]

    public var totalSeconds: TimeInterval { max(0, (endHour - startHour) * 3600) }
    /// Share of the window that was tracked, 0…1.
    public var trackedRatio: Double {
        totalSeconds > 0 ? trackedSeconds / totalSeconds : 0
    }

    public static func == (a: WindowSummary, b: WindowSummary) -> Bool {
        a.startHour == b.startHour && a.endHour == b.endHour
            && a.trackedSeconds == b.trackedSeconds && a.idleSeconds == b.idleSeconds
            && a.byProject.map(\.projectID) == b.byProject.map(\.projectID)
            && a.byProject.map(\.seconds) == b.byProject.map(\.seconds)
    }
}

extension Aggregations {

    /// Pull a rough drag inward onto task boundaries: the start jumps forward to the next block
    /// that begins, the end falls back to the last block that ends.
    ///
    /// Dragging by hand always over- or under-shoots by a few pixels, and on a 24-hour axis a
    /// pixel is over a minute — so a selection meant to be "these three blocks" picks up slivers
    /// of the gaps on either side and reports idle time you didn't have. Snapping inward means the
    /// selection describes whole blocks, and any idle it reports is genuinely *between* them.
    ///
    /// Deliberately inward-only: widening a selection to blocks you didn't drag over would claim
    /// tracked time you didn't ask about. Returns the input unchanged when no boundary qualifies
    /// (e.g. a drag entirely inside one block, or across empty space), so a selection can still
    /// be all-idle when that's the truth.
    public static func snapToSegments(
        segments: [DaySegment],
        from: Double,
        to: Double
    ) -> (from: Double, to: Double) {
        let lo = min(from, to), hi = max(from, to)
        guard hi > lo else { return (lo, hi) }

        // First block that starts at/after the drag's left edge, and still inside the window.
        let snappedLo = segments.map(\.startHour).filter { $0 >= lo && $0 < hi }.min()
        // Last block that ends at/before the drag's right edge, and still inside the window.
        let snappedHi = segments.map(\.endHour).filter { $0 <= hi && $0 > lo }.max()

        let newLo = snappedLo ?? lo
        let newHi = snappedHi ?? hi
        // If snapping would invert or empty the range, keep the raw drag.
        guard newHi > newLo else { return (lo, hi) }
        return (newLo, newHi)
    }

    /// Summarise `segments` clipped to `[from, to]` hours.
    ///
    /// Tracked time is computed from the **union** of the clipped segments, not their sum: two
    /// segments can share an instant (a switch recorded at the same second, or overlapping rows
    /// from an older import), and summing those would report more tracked time than the window
    /// physically contains — and a negative idle. The per-task breakdown is left un-merged, since
    /// there each task's own contribution is what's wanted.
    public static func windowSummary(
        segments: [DaySegment],
        from: Double,
        to: Double
    ) -> WindowSummary {
        let lo = min(from, to), hi = max(from, to)

        // Clip each segment to the window, dropping anything outside it.
        let clipped: [(projectID: Int64, start: Double, end: Double)] = segments.compactMap { seg in
            let s = max(seg.startHour, lo), e = min(seg.endHour, hi)
            guard e > s else { return nil }
            return (seg.projectID, s, e)
        }

        // Union of covered spans → tracked time that can't exceed the window.
        var covered: TimeInterval = 0
        var cursor = lo
        for span in clipped.sorted(by: { $0.start < $1.start }) {
            let start = max(span.start, cursor)
            guard span.end > start else { continue }   // fully inside an already-counted span
            covered += (span.end - start) * 3600
            cursor = span.end
        }

        var perProject: [Int64: TimeInterval] = [:]
        for span in clipped {
            perProject[span.projectID, default: 0] += (span.end - span.start) * 3600
        }

        let total = max(0, (hi - lo) * 3600)
        let tracked = min(covered, total)
        return WindowSummary(
            startHour: lo,
            endHour: hi,
            trackedSeconds: tracked,
            idleSeconds: max(0, total - tracked),
            byProject: perProject
                .map { (projectID: $0.key, seconds: $0.value) }
                .sorted { $0.seconds > $1.seconds }
        )
    }
}
