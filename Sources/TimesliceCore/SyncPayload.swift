import Foundation

/// What one device publishes for the others to read.
///
/// Deliberately **facts, not operations**: a closed interval is already an immutable value, so
/// there's no replay ordering, no idempotency concerns and no log compaction. Metadata carries
/// `updatedAt` for last-write-wins; deletes travel as tombstones.
public struct SyncPayload: Codable, Equatable, Sendable {
    public var formatVersion: Int = 1
    public var deviceID: String
    /// Friendly name this device calls itself, so the UI isn't stuck showing a model number or a
    /// MAC address. Optional for payloads written by older builds.
    public var deviceLabel: String?
    public var writtenAt: TimeInterval

    public var tasks: [TaskRecord]
    public var projects: [ProjectRecord]
    public var intervals: [IntervalRecord]
    public var tombstones: [TombstoneRecord]

    public struct TaskRecord: Codable, Equatable, Sendable {
        public var uid: String
        public var name: String
        public var colorHex: String
        public var sortOrder: Int
        public var archived: Bool
        public var finished: Bool
        public var finishedAt: TimeInterval?
        /// The *uid* of the owning project, not its local id — ids differ per device.
        public var projectUID: String?
        public var updatedAt: TimeInterval

        public init(uid: String, name: String, colorHex: String, sortOrder: Int, archived: Bool,
                    finished: Bool, finishedAt: TimeInterval?, projectUID: String?,
                    updatedAt: TimeInterval) {
            self.uid = uid; self.name = name; self.colorHex = colorHex; self.sortOrder = sortOrder
            self.archived = archived; self.finished = finished; self.finishedAt = finishedAt
            self.projectUID = projectUID; self.updatedAt = updatedAt
        }
    }

    public struct ProjectRecord: Codable, Equatable, Sendable {
        public var uid: String
        public var name: String
        public var colorHex: String
        public var sortOrder: Int
        public var updatedAt: TimeInterval

        public init(uid: String, name: String, colorHex: String, sortOrder: Int,
                    updatedAt: TimeInterval) {
            self.uid = uid; self.name = name; self.colorHex = colorHex
            self.sortOrder = sortOrder; self.updatedAt = updatedAt
        }
    }

    public struct IntervalRecord: Codable, Equatable, Sendable {
        public var uid: String
        /// Owning task by uid, for the same reason as above.
        public var taskUID: String
        public var start: TimeInterval
        public var end: TimeInterval
        /// Device that recorded it. Optional so payloads from older builds still decode; nil there
        /// means unattributed rather than "belongs to the sender".
        public var deviceID: String?

        public init(uid: String, taskUID: String, start: TimeInterval, end: TimeInterval,
                    deviceID: String? = nil) {
            self.uid = uid; self.taskUID = taskUID; self.start = start; self.end = end
            self.deviceID = deviceID
        }
    }

    public struct TombstoneRecord: Codable, Equatable, Sendable {
        public var uid: String
        public var kind: String        // "interval" | "task" | "task_project"
        public var deletedAt: TimeInterval

        public init(uid: String, kind: String, deletedAt: TimeInterval) {
            self.uid = uid; self.kind = kind; self.deletedAt = deletedAt
        }
    }

    public init(deviceID: String, deviceLabel: String? = nil, writtenAt: TimeInterval,
                tasks: [TaskRecord], projects: [ProjectRecord], intervals: [IntervalRecord],
                tombstones: [TombstoneRecord]) {
        self.deviceID = deviceID; self.deviceLabel = deviceLabel
        self.writtenAt = writtenAt; self.tasks = tasks
        self.projects = projects; self.intervals = intervals; self.tombstones = tombstones
    }
}

/// Which device is timing what, right now. Overwritten rather than appended — it's presence, not
/// history. Absent/empty means that device isn't timing.
public struct RunningMarker: Codable, Equatable, Sendable {
    public var deviceID: String
    public var taskUID: String
    public var since: TimeInterval
    /// False when the device has this task as *current* but paused. The marker used to be deleted
    /// whenever a device stopped timing, so other devices could only ever see "running" or nothing
    /// — a paused device looked identical to one that had never started.
    ///
    /// Optional for payloads written by older builds; absent means running, which is what those
    /// builds only ever published.
    public var isRunning: Bool?

    /// Only a RUNNING marker can trigger a takeover. A paused one is presence, not a claim.
    public var claimsTimer: Bool { isRunning ?? true }

    public init(deviceID: String, taskUID: String, since: TimeInterval, isRunning: Bool? = nil) {
        self.deviceID = deviceID; self.taskUID = taskUID; self.since = since
        self.isRunning = isRunning
    }
}

/// What a merge changed — shown to the user on first sync instead of silently absorbing data.
public struct MergeReport: Equatable, Sendable {
    public var tasksAdded = 0
    public var intervalsAdded = 0
    public var projectsAdded = 0
    /// Projects that already existed by name and were reused rather than duplicated.
    public var projectsMergedByName: [String] = []
    public var taskEditsApplied = 0
    /// Renames/recolours of a PROJECT adopted from another device.
    public var projectEditsApplied = 0
    /// Rows whose device attribution the sender corrected (see reattributeInterval).
    public var intervalsReattributed = 0
    public var deletionsApplied = 0

    public init() {}

    public var isEmpty: Bool {
        tasksAdded == 0 && intervalsAdded == 0 && projectsAdded == 0
            && projectsMergedByName.isEmpty && taskEditsApplied == 0
            && projectEditsApplied == 0 && deletionsApplied == 0
            && intervalsReattributed == 0
    }
}
