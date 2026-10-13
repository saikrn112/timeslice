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

    /// Whether a clip is a takeover that failed — this interval overlaps only intervals recorded on OTHER
    /// devices — rather than an overlap on one device.
    ///
    /// The distinction is what decides who may resolve it. Across devices, two timers running at once is
    /// exactly what `TakeoverPolicy` exists to prevent, and its rule (the later start wins) is the right
    /// answer however long the overlap ran: a laptop left timing while you worked on another machine.
    /// That is safe to settle unattended at any size. On ONE device an overlap can only come from a
    /// manual entry — a backfill typed over live rows — and which side is true is the user's call.
    ///
    /// Rows with no device recorded are treated as same-device: unknown attribution is not evidence of a
    /// race.
    public static func isTakeoverRace(_ clip: Clip, intervals: [Interval]) -> Bool {
        guard let mine = clip.deviceID, !clip.lostTo.isEmpty else { return false }
        let byID = Dictionary(uniqueKeysWithValues: intervals.map { ($0.id, $0) })
        return clip.lostTo.allSatisfy { id in
            guard let other = byID[id]?.deviceID else { return false }
            return other != mine
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
        let closed = intervals.filter { $0.end != nil }
        // "Who started later" is decided per SESSION, not per row. A long session is stored as back-to-back
        // chunks (`rollOpenInterval` splits at the focus length), so comparing rows made the Air's
        // `parents`, chunked at 10:02:51, look as if it had started AFTER the Mac's 09:57:21 — and the
        // resolver handed ten minutes of the Mac's work to it. A chunk inherits the start of its session.
        let sessionStart = sessionStarts(closed)
        func began(_ i: Interval) -> Date { sessionStart[i.id] ?? i.start }
        let ordered = closed.sorted {
            let a = began($0), b = began($1)
            if a != b { return a < b }
            return $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        var out: [Clip] = []

        for (index, earlier) in ordered.enumerated() {
            guard let end = earlier.end, end > earlier.start else { continue }
            // Everything later in the order — a later-started session, or the same instant with a higher id,
            // so a tie still has exactly one winner on every device — that reaches into this row. The
            // earlier one gives up the shared time. No early `break`: ordered by session start, a later
            // session's chunk can begin at any time. Rows of one session never overlap each other, so they
            // can't appear here as rivals.
            let rivals = ordered[(index + 1)...].filter { l in
                guard let lEnd = l.end else { return false }
                return l.start < end && lEnd > earlier.start
            }
            guard !rivals.isEmpty else { continue }
            let covered = rivals.map {
                DateInterval(start: max($0.start, earlier.start), end: min($0.end!, end))
            }

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
                            keep: keep, lostTo: rivals.map(\.id)))
        }
        return out.sorted { $0.originalStart < $1.originalStart }
    }

    /// The start of the session each row belongs to: consecutive rows of the same task on the same device
    /// with no gap between them (within a second — `rollOpenInterval` writes them exactly end-to-start).
    /// Deliberately NOT the micro-pause tolerance: a real pause, however short, is a real restart as far as
    /// takeover is concerned, because that is when the device last claimed the timer.
    static func sessionStarts(_ closed: [Interval]) -> [Int64: Date] {
        var out: [Int64: Date] = [:]
        let groups = Dictionary(grouping: closed) { "\($0.deviceID ?? "-")|\($0.projectID)" }
        for (_, rows) in groups {
            var start: Date?
            var lastEnd: Date?
            for row in rows.sorted(by: { $0.start < $1.start }) {
                if let s = start, let e = lastEnd, row.start.timeIntervalSince(e) <= 1 {
                    out[row.id] = s
                } else {
                    start = row.start
                    out[row.id] = row.start
                }
                lastEnd = row.end
            }
        }
        return out
    }
}
