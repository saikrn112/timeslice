import Foundation

/// Decides whether another device's running timer should stop ours.
///
/// Only one timer runs across all devices, so whichever *started later* wins. Kept as pure logic
/// so the rule is unit-testable without a network or a second machine.
public enum TakeoverPolicy {

    /// How long a running marker stays believable without a refresh.
    ///
    /// A running device republishes every 15s (foreground) or 45s (background), so five minutes is
    /// 6+ missed background polls — comfortably past an ordinary slow sync, network blip or a laptop
    /// briefly asleep, while still bounded. Generous on purpose: wrongly declaring a LIVE device
    /// dead lets two timers run at once and double-count, which is worse than reacting late.
    public static let livenessCutoff: TimeInterval = 300

    public struct Decision: Equatable, Sendable {
        /// Stop our timer, back-dated to this moment (when the other device started).
        public let pauseAt: Date
        /// Which device took over, for the menu-bar hint.
        public let byDeviceID: String

        public init(pauseAt: Date, byDeviceID: String) {
            self.pauseAt = pauseAt
            self.byDeviceID = byDeviceID
        }
    }

    /// `nil` = keep running.
    ///
    /// - `localRunningSince`: nil when we aren't timing, in which case there's nothing to stop.
    /// - `markers`: other devices' running markers (ours must already be excluded).
    /// - `now`: clamps a remote clock that's ahead of us, so we never back-date into the future.
    /// - `observedAt`: optional transport-side timestamp per device id (Drive's modifiedTime),
    ///   preferred over the marker's self-reported heartbeat because one server clock is more
    ///   trustworthy than every peer's.
    public static func decide(
        localRunningSince: Date?,
        markers: [RunningMarker],
        now: Date = Date(),
        observedAt: [String: Date] = [:]
    ) -> Decision? {
        guard let localSince = localRunningSince else { return nil }
        // Only devices actually RUNNING can take over. Paused markers exist purely so the UI can
        // show what another device was last on; treating one as a claim would stop this device for
        // no reason.
        //
        // A STALE claim is likewise ignored: a device that crashed or slept mid-timer left a marker
        // that never expires, and its `since` outranks any timer started earlier, so it would pause
        // this device indefinitely with no way to clear it.
        let claiming = markers.filter(\.claimsTimer).filter {
            $0.isFresh(now: now, cutoff: livenessCutoff, observedAt: observedAt[$0.deviceID])
        }
        // The most recent remote start wins; ties keep the local timer (no needless churn).
        guard let latest = claiming.max(by: { $0.since < $1.since }) else { return nil }
        let remoteSince = Date(timeIntervalSince1970: latest.since)
        guard remoteSince > localSince else { return nil }
        // Never before our own start, never after now.
        let cutoff = min(max(remoteSince, localSince), now)
        return Decision(pauseAt: cutoff, byDeviceID: latest.deviceID)
    }

    /// Rewrite each claim's `since` to the start of the SESSION it belongs to, using that device's own
    /// synced rows: walk back from `since` through closed blocks of the same task on the same device
    /// that abut within a second.
    ///
    /// Defence against peers on builds that claimed their open ROW's start. That start jumps forward
    /// at every 20-minute roll, so such a phone outranked a Mac you had switched to after it — and
    /// took the timer back. A phone can't be updated remotely; the Mac can judge its claim correctly
    /// regardless. Idempotent for a peer that already claims its session start.
    public static func sessionNormalized(_ markers: [RunningMarker], intervals: [Interval],
                                         localTaskID: (String) -> Int64?) -> [RunningMarker] {
        markers.map { m in
            guard m.claimsTimer, let task = localTaskID(m.taskUID) else { return m }
            let rows = intervals.filter { $0.deviceID == m.deviceID && $0.projectID == task && $0.end != nil }
            var start = m.since
            for _ in 0..<500 {
                guard let prev = rows.first(where: { abs($0.end!.timeIntervalSince1970 - start) <= 1
                                                     && $0.start.timeIntervalSince1970 < start })
                else { break }
                start = prev.start.timeIntervalSince1970
            }
            var out = m
            out.since = start
            return out
        }
    }
}
