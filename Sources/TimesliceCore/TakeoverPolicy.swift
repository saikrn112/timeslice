import Foundation

/// Decides whether another device's running timer should stop ours.
///
/// Only one timer runs across all devices, so whichever *started later* wins. Kept as pure logic
/// so the rule is unit-testable without a network or a second machine.
public enum TakeoverPolicy {

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
    public static func decide(
        localRunningSince: Date?,
        markers: [RunningMarker],
        now: Date = Date()
    ) -> Decision? {
        guard let localSince = localRunningSince else { return nil }
        // Only devices actually RUNNING can take over. Paused markers exist purely so the UI can
        // show what another device was last on; treating one as a claim would stop this device for
        // no reason.
        let claiming = markers.filter(\.claimsTimer)
        // The most recent remote start wins; ties keep the local timer (no needless churn).
        guard let latest = claiming.max(by: { $0.since < $1.since }) else { return nil }
        let remoteSince = Date(timeIntervalSince1970: latest.since)
        guard remoteSince > localSince else { return nil }
        // Never before our own start, never after now.
        let cutoff = min(max(remoteSince, localSince), now)
        return Decision(pauseAt: cutoff, byDeviceID: latest.deviceID)
    }
}
