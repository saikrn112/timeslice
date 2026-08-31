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

    /// Tags, tag links and budgets.
    ///
    /// OPTIONAL so a payload written by a build that predates them still decodes — a missing key
    /// would otherwise make the whole file unreadable and silently stop syncing with that device.
    public var tags: [TagRecord]?
    public var tagLinks: [TagLinkRecord]?
    public var targets: [TargetRecord]?
    /// Notes. Optional for the same reason as the rest: an older build's payload must still decode.
    public var feedback: [FeedbackRecord]?

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

    public struct TagRecord: Codable, Equatable, Sendable {
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

    /// "This tag applies to this task/project."
    ///
    /// Both ends travel as UIDs, never local ids: row ids are per-device, so `subject_id = 8` means a
    /// different project on the other machine. This is the same trap that made interval attribution
    /// need uids.
    public struct TagLinkRecord: Codable, Equatable, Sendable {
        public var uid: String
        public var tagUID: String
        public var subjectKind: String        // "task" | "project"
        public var subjectUID: String
        public var updatedAt: TimeInterval

        public init(uid: String, tagUID: String, subjectKind: String, subjectUID: String,
                    updatedAt: TimeInterval) {
            self.uid = uid; self.tagUID = tagUID; self.subjectKind = subjectKind
            self.subjectUID = subjectUID; self.updatedAt = updatedAt
        }
    }

    public struct TargetRecord: Codable, Equatable, Sendable {
        public var uid: String
        public var subjectKind: String        // "task" | "project" | "tag"
        public var subjectUID: String
        public var seconds: TimeInterval
        public var direction: String
        public var period: String
        public var updatedAt: TimeInterval
        /// Optional so a payload from a build without the done state still decodes; absent means live.
        public var createdAt: TimeInterval?
        public var completedAt: TimeInterval?

        public init(uid: String, subjectKind: String, subjectUID: String, seconds: TimeInterval,
                    direction: String, period: String, updatedAt: TimeInterval,
                    createdAt: TimeInterval? = nil, completedAt: TimeInterval? = nil) {
            self.uid = uid; self.subjectKind = subjectKind; self.subjectUID = subjectUID
            self.seconds = seconds; self.direction = direction; self.period = period
            self.updatedAt = updatedAt
            self.createdAt = createdAt; self.completedAt = completedAt
        }
    }

    public struct FeedbackRecord: Codable, Equatable, Sendable {
        public var uid: String
        public var text: String
        /// The device it was WRITTEN on, carried so context survives the trip — not the device that
        /// happened to sync it.
        public var deviceID: String?
        public var createdAt: TimeInterval
        public var resolvedAt: TimeInterval?
        public var updatedAt: TimeInterval

        public init(uid: String, text: String, deviceID: String?, createdAt: TimeInterval,
                    resolvedAt: TimeInterval?, updatedAt: TimeInterval) {
            self.uid = uid; self.text = text; self.deviceID = deviceID
            self.createdAt = createdAt; self.resolvedAt = resolvedAt; self.updatedAt = updatedAt
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
                tags: [TagRecord]? = nil, tagLinks: [TagLinkRecord]? = nil,
                targets: [TargetRecord]? = nil, feedback: [FeedbackRecord]? = nil,
                tasks: [TaskRecord], projects: [ProjectRecord], intervals: [IntervalRecord],
                tombstones: [TombstoneRecord]) {
        self.deviceID = deviceID; self.deviceLabel = deviceLabel
        self.writtenAt = writtenAt; self.tasks = tasks
        self.projects = projects; self.intervals = intervals; self.tombstones = tombstones
        self.tags = tags; self.tagLinks = tagLinks; self.targets = targets
        self.feedback = feedback
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

    /// Heartbeat: when this marker was last WRITTEN, as opposed to when the timer started.
    ///
    /// `since` never advances, so a marker abandoned by a crashed or sleeping device looks exactly
    /// like one being actively maintained. Worse, a takeover picks the LATEST `since`, so an
    /// abandoned claim keeps beating any timer started before it and pauses this device forever.
    /// The publishing device already rewrites its marker on every poll, so liveness is being
    /// transmitted — it just wasn't recorded anywhere comparable.
    ///
    /// Optional: markers from older builds have none, and those are treated as fresh rather than
    /// dead, since assuming dead would let two timers run at once.
    public var writtenAt: TimeInterval?

    public init(deviceID: String, taskUID: String, since: TimeInterval, isRunning: Bool? = nil,
                writtenAt: TimeInterval? = nil) {
        self.deviceID = deviceID; self.taskUID = taskUID; self.since = since
        self.isRunning = isRunning
        self.writtenAt = writtenAt
    }

    /// Whether this claim is recent enough to act on, given when it was observed.
    ///
    /// `observedAt` lets a caller substitute the TRANSPORT's timestamp (Drive's server-side
    /// modifiedTime) for the marker's self-reported one: comparing a peer's clock against ours has
    /// the same skew weakness as LWW, and one server clock beats N device clocks.
    public func isFresh(now: Date, cutoff: TimeInterval, observedAt: Date? = nil) -> Bool {
        guard let stamp = observedAt ?? writtenAt.map({ Date(timeIntervalSince1970: $0) }) else {
            return true      // no heartbeat available: treat as live, never invent a takeover
        }
        // A stamp in the future means the other clock is ahead, not that it's stale.
        return now.timeIntervalSince(stamp) <= cutoff
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
    public var tagsAdded = 0
    public var tagsMergedByName: [String] = []
    public var tagEditsApplied = 0
    public var tagLinksAdded = 0
    public var targetsApplied = 0
    public var feedbackApplied = 0
    public var deletionsApplied = 0

    public init() {}

    public var isEmpty: Bool {
        tasksAdded == 0 && intervalsAdded == 0 && projectsAdded == 0
            && projectsMergedByName.isEmpty && taskEditsApplied == 0
            && projectEditsApplied == 0 && deletionsApplied == 0
            && intervalsReattributed == 0
            && tagsAdded == 0 && tagsMergedByName.isEmpty && tagEditsApplied == 0
            && tagLinksAdded == 0 && targetsApplied == 0 && feedbackApplied == 0
    }
}
