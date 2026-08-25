import Foundation

/// Merges another device's payload into the local store, and builds our own for publishing.
///
/// Transport-agnostic on purpose: it never touches the network. A `SyncTransport` supplies and
/// accepts bytes, so the same tested merge runs over a shared folder (Dropbox/iCloud) or the
/// Google Drive API. That also means the hard part — merge semantics — is unit-testable.
public struct SyncEngine {
    private let store: IntervalStore
    public let deviceID: String

    /// `deviceLabel` is a human-facing name published alongside the data.
    public let deviceLabel: String?

    public init(store: IntervalStore, deviceID: String, deviceLabel: String? = nil) {
        self.store = store
        self.deviceID = deviceID
        self.deviceLabel = deviceLabel
    }

    // MARK: - Export

    /// Everything this device knows, addressed by uid so ids can differ across devices.
    public func buildPayload(now: Date = Date()) throws -> SyncPayload {
        let projects = try store.listTaskProjects()
        var projectUIDByID: [Int64: String] = [:]
        var projectRecords: [SyncPayload.ProjectRecord] = []
        for p in projects {
            guard let uid = try store.uid(table: "task_projects", id: p.id) else { continue }
            projectUIDByID[p.id] = uid
            projectRecords.append(.init(uid: uid, name: p.name, colorHex: p.colorHex,
                                        sortOrder: p.sortOrder,
                                        updatedAt: try store.updatedAt(table: "task_projects", id: p.id) ?? 0))
        }

        var taskUIDByID: [Int64: String] = [:]
        var taskRecords: [SyncPayload.TaskRecord] = []
        for t in try store.listProjects(includeArchived: true) {
            guard let uid = try store.uid(table: "projects", id: t.id) else { continue }
            taskUIDByID[t.id] = uid
            taskRecords.append(.init(
                uid: uid, name: t.name, colorHex: t.colorHex, sortOrder: t.sortOrder,
                archived: t.archived, finished: t.finished,
                finishedAt: t.finishedAt?.timeIntervalSince1970,
                projectUID: t.taskProjectID.flatMap { projectUIDByID[$0] },
                updatedAt: try store.updatedAt(table: "projects", id: t.id) ?? 0))
        }

        // Only CLOSED intervals travel. A running one is presence, published separately, and
        // shipping it as a fact would let the other device record time it never observed ending.
        var intervalRecords: [SyncPayload.IntervalRecord] = []
        for (iv, uid) in try store.intervalsWithUIDs() {
            guard let end = iv.end, let taskUID = taskUIDByID[iv.projectID] else { continue }
            // Fall back to this device for rows predating attribution: they were, in fact,
            // recorded here, and the alternative is losing the information on every peer.
            intervalRecords.append(.init(uid: uid, taskUID: taskUID,
                                         start: iv.start.timeIntervalSince1970,
                                         end: end.timeIntervalSince1970,
                                         deviceID: iv.deviceID ?? deviceID))
        }

        let tombs = try store.tombstoneRecords()
        return SyncPayload(deviceID: deviceID, deviceLabel: deviceLabel,
                           writtenAt: now.timeIntervalSince1970,
                           tasks: taskRecords, projects: projectRecords,
                           intervals: intervalRecords, tombstones: tombs)
    }

    // MARK: - Merge

    /// Apply a remote payload. Idempotent: merging the same payload twice changes nothing the
    /// second time, which is what makes a dumb transport safe (re-reads, retries, partial syncs).
    @discardableResult
    public func merge(_ remote: SyncPayload) throws -> MergeReport {
        var report = MergeReport()
        guard remote.deviceID != deviceID else { return report }   // never merge our own file

        // Record who sent this, so intervals attributed to that device can be labelled later even
        // when it's offline and absent from the live peer list.
        try store.rememberDevice(id: remote.deviceID, label: remote.deviceLabel,
                                 lastSeen: Date(timeIntervalSince1970: remote.writtenAt))

        // Deletions first, so we don't insert a row the remote already deleted.
        let knownTombstones = Set(try store.tombstoneUIDs())
        for t in remote.tombstones where !knownTombstones.contains(t.uid) {
            try store.applyRemoteTombstone(uid: t.uid, kind: t.kind, deletedAt: t.deletedAt)
            report.deletionsApplied += 1
        }
        let deleted = Set(try store.tombstoneUIDs())

        // Projects merge BY NAME: two devices each creating "personal" mean the same project.
        var projectIDByUID: [String: Int64] = [:]
        for p in remote.projects where !deleted.contains(p.uid) {
            if let existing = try store.localID(table: "task_projects", uid: p.uid) {
                projectIDByUID[p.uid] = existing
                // Apply the remote's edits if they're newer. Previously this only recorded the id,
                // so a project renamed or recoloured elsewhere never changed here — the same
                // "matched, then not updated" bug that hid the task-move issue.
                if try store.applyRemoteProjectEdit(uid: p.uid, name: p.name, colorHex: p.colorHex,
                                                    sortOrder: p.sortOrder,
                                                    remoteUpdatedAt: p.updatedAt) {
                    report.projectEditsApplied += 1
                }
            } else if let byName = try store.taskProject(named: p.name) {
                // Same name, different uid — adopt ours rather than creating a duplicate that
                // would violate the (case-insensitive) unique index.
                projectIDByUID[p.uid] = byName.id
                report.projectsMergedByName.append(byName.name)
                // Converge on ONE colour. Colours are generated from a per-device index, so two
                // devices that each created "personal" picked different hues and kept them
                // forever — the same project looked different on each machine. The lexically
                // smaller hex wins: an arbitrary but *stable* rule, so both sides pick the same
                // one without needing to know who created it first.
                if p.colorHex < byName.colorHex {
                    try store.setTaskProjectColor(id: byName.id, colorHex: p.colorHex)
                }
                // Converge on ONE uid too, by the same stable rule, so future renames match by uid
                // rather than arriving as new projects.
                if let mineUID = try store.uid(table: "task_projects", id: byName.id),
                   p.uid < mineUID {
                    try store.adoptTaskProjectUID(id: byName.id, uid: p.uid)
                }
            } else {
                // Preserve the remote uid so both devices share one identity from now on.
                let id = try store.insertRemoteTaskProject(
                    uid: p.uid, name: p.name, colorHex: p.colorHex,
                    sortOrder: p.sortOrder, updatedAt: p.updatedAt)
                projectIDByUID[p.uid] = id
                report.projectsAdded += 1
            }
        }

        // Tasks are NOT merged by name — duplicates are legal and fusing them would mix time.
        var taskIDByUID: [String: Int64] = [:]
        for t in remote.tasks where !deleted.contains(t.uid) {
            let localProjectID = t.projectUID.flatMap { projectIDByUID[$0] }
            if let existing = try store.localID(table: "projects", uid: t.uid) {
                taskIDByUID[t.uid] = existing
                if try store.applyRemoteTaskEdit(
                    uid: t.uid, name: t.name, colorHex: t.colorHex, archived: t.archived,
                    finished: t.finished,
                    finishedAt: t.finishedAt.map { Date(timeIntervalSince1970: $0) },
                    taskProjectID: localProjectID,
                    remoteUpdatedAt: t.updatedAt) {
                    report.taskEditsApplied += 1
                }
            } else {
                let id = try store.insertRemoteTask(
                    uid: t.uid, name: t.name, colorHex: t.colorHex, sortOrder: t.sortOrder,
                    archived: t.archived, finished: t.finished,
                    finishedAt: t.finishedAt.map { Date(timeIntervalSince1970: $0) },
                    taskProjectID: localProjectID, updatedAt: t.updatedAt)
                taskIDByUID[t.uid] = id
                report.tasksAdded += 1
            }
        }

        // Intervals are immutable facts: insert what we've never seen, skip the rest.
        let have = try store.uidsPresent(table: "intervals")

        // Repair attribution on rows we already have. The sender is authoritative about which
        // device recorded its own intervals, and the one-time backfill could only guess.
        for iv in remote.intervals where have.contains(iv.uid) {
            guard let owner = iv.deviceID else { continue }
            if try store.reattributeInterval(uid: iv.uid, deviceID: owner) {
                report.intervalsReattributed += 1
            }
        }

        for iv in remote.intervals where !have.contains(iv.uid) && !deleted.contains(iv.uid) {
            let resolved = try taskIDByUID[iv.taskUID] ?? store.localID(table: "projects", uid: iv.taskUID)
            guard let taskID = resolved else { continue }
            try store.insertRemoteInterval(uid: iv.uid, projectID: taskID,
                                           start: Date(timeIntervalSince1970: iv.start),
                                           end: Date(timeIntervalSince1970: iv.end),
                                           deviceID: iv.deviceID ?? remote.deviceID)
            report.intervalsAdded += 1
        }
        return report
    }
}
