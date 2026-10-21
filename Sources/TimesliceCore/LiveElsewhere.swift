import Foundation

/// Another device's timer, running right now, as this device should show it.
///
/// A peer's running interval is never in its payload — only closed rows are synced facts — so a
/// phone timing for 40 minutes looked, on the Mac, like nothing at all: no row lit, no time in the
/// totals, nothing on the day timeline. Its running MARKER was arriving the whole time. This turns
/// that marker into the part of the session the rows don't cover yet.
///
/// Display only. It is never written, and it disappears the moment the real rows arrive or the other
/// device stops, so nothing here can double-count once the facts land.
public struct LiveElsewhere: Equatable, Sendable {
    public let deviceID: String
    public let projectID: Int64
    /// When that device's timer started, from its marker.
    public let since: Date
    /// Where the unpublished part begins: the end of the last row that device already sent for this
    /// run, or `since` if it has sent none. A phone rolls long sessions into closed blocks, and those
    /// arrive as ordinary intervals — counting from `since` regardless would count them twice.
    public let liveFrom: Date

    public init(deviceID: String, projectID: Int64, since: Date, intervals: [Interval]) {
        self.deviceID = deviceID
        self.projectID = projectID
        self.since = since
        let published = intervals
            .filter { $0.deviceID == deviceID && $0.projectID == projectID }
            .compactMap(\.end)
            .filter { $0 > since }
            .max()
        self.liveFrom = max(since, published ?? since)
    }

    /// The newest fresh claim among `markers`, resolved to a local task. nil when no other device is
    /// timing, its marker has gone stale, or its task hasn't been merged here yet.
    public static func resolve(markers: [RunningMarker], now: Date, observedAt: [String: Date],
                               localTaskID: (String) -> Int64?,
                               intervals: [Interval]) -> LiveElsewhere? {
        guard let m = markers
            .filter({ $0.claimsTimer && $0.isFresh(now: now, cutoff: TakeoverPolicy.livenessCutoff,
                                                   observedAt: observedAt[$0.deviceID]) })
            .max(by: { $0.since < $1.since }),
              let taskID = localTaskID(m.taskUID)
        else { return nil }
        return LiveElsewhere(deviceID: m.deviceID, projectID: taskID,
                             since: Date(timeIntervalSince1970: m.since), intervals: intervals)
    }

    /// Unpublished seconds, optionally only those after `notBefore` (the start of today, say).
    public func seconds(now: Date = Date(), notBefore: Date? = nil) -> TimeInterval {
        let from = max(liveFrom, notBefore ?? liveFrom)
        return max(0, now.timeIntervalSince(from))
    }

    /// The unpublished part as an open interval, for code that draws intervals. The id is negative so
    /// it can never collide with, or be mistaken for, a stored row.
    public var interval: Interval {
        Interval(id: -1, projectID: projectID, start: liveFrom, end: nil, deviceID: deviceID)
    }
}
