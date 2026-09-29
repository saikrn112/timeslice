import Foundation

/// Settles the one-timer invariant for intervals that are ALREADY CLOSED.
///
/// `TakeoverPolicy` can only act while a device is still running: it reads the `device-<id>.running`
/// markers, sees two timers going, and back-dates the loser. That covers the case where both devices are
/// online at the moment of the switch. It cannot cover this one:
///
///   phone starts `parents` 9:15 · Mac starts `gptoss` 9:53 without having seen the phone's marker ·
///   phone stops 10:06 · Mac stops 10:07 · they finally sync
///
/// By then both intervals are closed facts, the merge inserts them as given, and 13 minutes are counted
/// twice — permanently. 21 overlapping pairs had accumulated this way.
///
/// **The rule: the earlier-started interval ends where the later one begins.** That is exactly what
/// takeover would have done live, so a race settled late reaches the same answer as one settled on time.
///
/// **Determinism is the hard part.** Every device merges independently, so each will compute this clip
/// for itself. A correction that tombstones the original and re-inserts under a fresh random uid would
/// therefore produce one new row PER DEVICE — the overlap replaced by duplicates. So the replacement uid
/// is *derived* from the original and the new bounds: two devices computing the same clip produce the
/// same uid, and the rows converge instead of multiplying. Anything that makes this decision must depend
/// only on the intervals themselves, never on which device is asking or when.
public enum OverlapResolver {

    /// One interval's correction: replace it with `keep`, which may be empty.
    public struct Clip: Sendable, Hashable {
        public let id: Int64
        public let uid: String?
        public let projectID: Int64
        public let deviceID: String?
        public let originalStart: Date
        public let originalEnd: Date
        /// The pieces that survive, in time order. Empty when the interval is covered entirely.
        public let keep: [DateInterval]
        /// Intervals it overlapped, for the report.
        public let lostTo: [Int64]

        public var keptSeconds: TimeInterval { keep.reduce(0) { $0 + $1.duration } }
        public var removedSeconds: TimeInterval {
            originalEnd.timeIntervalSince(originalStart) - keptSeconds
        }
    }

    /// Deterministic replacement uid. Derived from the original uid and the piece's bounds, so the same
    /// clip computed on two devices is the same row, and re-inserting is an `INSERT OR IGNORE` rather
    /// than a duplicate. Seconds resolution is enough — the bounds come from another interval's stored
    /// timestamps, which are identical everywhere.
    public static func clippedUID(original: String, piece: DateInterval) -> String {
        "\(original)#clip-\(Int(piece.start.timeIntervalSince1970))-\(Int(piece.end.timeIntervalSince1970))"
    }

    /// Every clip needed to remove all double-counted time, in time order.
    ///
    /// **Only the overlapping portion is removed.** The first version back-dated the earlier interval to
    /// where the later one began, which is what live takeover does — but when a short interval sits
    /// entirely INSIDE a long one that also throws away the long one's tail, which never conflicted with
    /// anything. Subtracting just the covered portion removes exactly the time that was counted twice and
    /// nothing else.
    ///
    /// "Earlier" is by start, ties broken by id, so every device walks the same order and reaches the
    /// same answer. Only closed intervals are considered: a running one's end moves with the clock, and
    /// back-dating a live timer is `TakeoverPolicy`'s job.
    public static func clips(_ intervals: [Interval], uids: [Int64: String] = [:]) -> [Clip] {
        let closed = intervals.filter { $0.end != nil }.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        var out: [Clip] = []

        for (index, earlier) in closed.enumerated() {
            guard let end = earlier.end, end > earlier.start else { continue }
            // Everything that starts later and reaches into this one. Later-starting wins, so it is the
            // earlier interval that gives up the shared time.
            var covered: [DateInterval] = []
            for later in closed[(index + 1)...] {
                guard later.start < end else { break }        // sorted by start: nothing after can reach
                guard let lEnd = later.end, lEnd > earlier.start else { continue }
                covered.append(DateInterval(start: max(later.start, earlier.start),
                                            end: min(lEnd, end)))
            }
            guard !covered.isEmpty else { continue }

            // Subtract the union of the covered spans.
            var keep: [DateInterval] = []
            var cursor = earlier.start
            for span in covered.sorted(by: { $0.start < $1.start }) {
                if span.start > cursor { keep.append(DateInterval(start: cursor, end: span.start)) }
                cursor = max(cursor, span.end)
            }
            if cursor < end { keep.append(DateInterval(start: cursor, end: end)) }
            // Sub-second remainders are dropped rather than kept as rows that show in Sessions as an
            // empty block — the same rule `deleteIntervalSlice` uses.
            keep = keep.filter { $0.duration >= 1 }
            let kept = keep.reduce(0.0) { $0 + $1.duration }
            // 50ms, not half a second. The bigger tolerance left the sub-second slivers that takeover's
            // own back-dating produces sitting in the data, so the "no overlapping intervals" invariant
            // that the day timeline's single lane rests on stayed false by a few hundred milliseconds.
            guard kept < end.timeIntervalSince(earlier.start) - 0.05 else { continue }

            out.append(Clip(id: earlier.id, uid: uids[earlier.id], projectID: earlier.projectID,
                            deviceID: earlier.deviceID, originalStart: earlier.start, originalEnd: end,
                            keep: keep,
                            lostTo: closed[(index + 1)...].filter { l in
                                guard let lEnd = l.end else { return false }
                                return l.start < end && lEnd > earlier.start
                            }.map(\.id)))
        }
        return out
    }
}
