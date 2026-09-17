import Foundation

/// Where the unfinished hours would actually have to go, laid out against the day's real clock.
///
/// This is the arithmetic behind drawing the planner as a calendar, and it exists in Core because it
/// IS the feasibility answer rather than a decoration on one. A day column shows what was tracked at
/// the times it happened; what an allocation still owes has no time attached, so it gets packed into
/// whatever gaps are left. If it doesn't fit, the leftover is the shortfall — the same number the
/// planner would have printed in a sentence, except now the geometry is the argument. Nothing has to
/// say "Tuesday is over capacity" when Tuesday visibly has nowhere to put it.
///
/// Splitting is deliberate and informative: three hours owed into a 2h gap and a 1h gap comes back as
/// two pieces, because that is genuinely what doing it would take. A packer that refused to split
/// would report "doesn't fit" for a day with three free hours in it.
public struct CalendarLayout {

    /// Half-open hour range within a day, measured from midnight. May exceed 24 for a band that runs
    /// past midnight — the caller draws it, so it only has to be consistent.
    public struct Span: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
        public var hours: Double { max(0, end - start) }
    }

    /// Something owed, with no time of its own yet.
    public struct Item: Sendable, Equatable {
        public let id: Int64
        public let hours: Double
        public init(id: Int64, hours: Double) {
            self.id = id
            self.hours = hours
        }
    }

    /// One piece of an owed item, given a place.
    public struct Piece: Sendable, Equatable {
        public let id: Int64
        public let span: Span
        public init(id: Int64, span: Span) {
            self.id = id
            self.span = span
        }
    }

    /// What's left of `band` once every busy span is removed.
    ///
    /// Busy spans may overlap and arrive in any order — tracked intervals shouldn't overlap in real
    /// data, but a merge anomaly must not turn into negative free time here.
    public static func gaps(band: Span, busy: [Span]) -> [Span] {
        guard band.hours > 0 else { return [] }
        let clipped = busy
            .map { Span(start: max(band.start, $0.start), end: min(band.end, $0.end)) }
            .filter { $0.hours > 0 }
            .sorted { $0.start < $1.start }

        var merged: [Span] = []
        for span in clipped {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }

        var out: [Span] = []
        var cursor = band.start
        for span in merged {
            if span.start > cursor { out.append(Span(start: cursor, end: span.start)) }
            cursor = max(cursor, span.end)
        }
        if cursor < band.end { out.append(Span(start: cursor, end: band.end)) }
        // Slivers aren't places you can do anything, and drawing them as blocks implies they are.
        return out.filter { $0.hours > 1.0 / 60 }
    }

    /// A span with the thing it belongs to, for merging runs of the same thing.
    public struct Keyed: Sendable, Equatable {
        public let key: Int64
        public var span: Span
        public init(key: Int64, span: Span) {
            self.key = key
            self.span = span
        }
    }

    /// Join consecutive spans that belong to the same thing and are effectively continuous, so one
    /// sitting looks like one block.
    ///
    /// A week of real tracking is ~150 intervals, because switching between two tasks in the same
    /// allocation, or pausing for two minutes, starts a new row. Drawn literally that is confetti, and
    /// it hides the shape of the day it is meant to show.
    ///
    /// Merging is done in **clock order across all keys**, not per key, which is the part that's easy to
    /// get wrong: office 9–10, vllm 10:02–10:30, office 10:35–11 must stay three blocks. Merging office
    /// with itself first would bridge 9–11 straight through the vllm block and draw two allocations in
    /// the same place. Only neighbours in time can join.
    public static func runs(_ items: [Keyed], maxGapHours: Double) -> [Keyed] {
        let sorted = items.filter { $0.span.hours > 0 }.sorted { $0.span.start < $1.span.start }
        var out: [Keyed] = []
        for item in sorted {
            if let last = out.last, last.key == item.key,
               item.span.start - last.span.end <= maxGapHours {
                out[out.count - 1].span.end = max(last.span.end, item.span.end)
            } else {
                out.append(item)
            }
        }
        return out
    }

    /// Lay owed items into the gaps, in the order given, splitting where a gap runs out.
    ///
    /// - Parameters:
    ///   - minPiece: never carve a piece smaller than this, unless it's all that's left of the item.
    ///     A planner that scatters twelve-minute fragments is planning the thing this app's own metrics
    ///     call bad, and it reads as noise rather than as intent.
    ///   - largestGapsFirst: place into the roomiest gaps before the earliest ones, so an owed hour
    ///     lands as one session where a session is possible.
    ///
    /// Caller order is the priority order: whatever matters most should be first, because the earliest
    /// gaps are the ones that survive contact with a day. Anything that doesn't fit comes back in
    /// `unplaced`, keyed by item, which is what the column's overflow marker draws.
    public static func pack(_ items: [Item], into gaps: [Span], minPiece: Double = 0,
                            largestGapsFirst: Bool = false)
                            -> (pieces: [Piece], unplaced: [Int64: Double]) {
        var remaining = gaps.filter { $0.hours > 1.0 / 60 }
        if largestGapsFirst { remaining.sort { $0.hours > $1.hours } }
        var pieces: [Piece] = []
        var unplaced: [Int64: Double] = [:]

        for item in items where item.hours > 1.0 / 60 {
            var left = item.hours
            var index = 0
            while left > 1.0 / 60, index < remaining.count {
                let gap = remaining[index]
                // A gap too small to hold a worthwhile piece is skipped rather than filled with a
                // sliver — unless the sliver is the whole of what's left, which is a real answer.
                if gap.hours < minPiece, left >= minPiece {
                    index += 1
                    continue
                }
                let take = min(left, gap.hours)
                pieces.append(Piece(id: item.id,
                                    span: Span(start: gap.start, end: gap.start + take)))
                left -= take
                if take >= gap.hours - 1.0 / 60 {
                    remaining.remove(at: index)
                } else {
                    remaining[index].start += take
                    index += 1
                }
            }
            if left > 1.0 / 60 { unplaced[item.id] = left }
        }
        // Chronological, whatever order they were placed in — the caller draws them on a clock.
        return (pieces.sorted { $0.span.start < $1.span.start }, unplaced)
    }
}
