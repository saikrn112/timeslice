import AppKit
import Combine
import SwiftUI
import TimesliceCore

/// Drives sync: publishes this device's payload, merges others', and applies takeovers.
///
/// Polling is adaptive because push is impossible without a server we run. The key economy: the
/// device that's actively timing **never polls** — it's the writer, so nobody can override it.
/// Only an idle device watches, and it's the one with nothing at stake.
@MainActor
final class SyncController: ObservableObject {
    /// Last merge result, so the UI can report "laptop added 312 intervals" instead of absorbing
    /// a year of data silently.
    @Published private(set) var lastReport: MergeReport?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?
    /// Which other device is timing right now — drives the device list.
    @Published private(set) var runningElsewhere: String?
    /// Set only when another device actually TOOK OVER from us, cleared as soon as we start again.
    /// The menu bar uses this, not `runningElsewhere`: a manual pause while some other device
    /// happens to be timing is not a takeover, and labelling it as one is a lie.
    @Published private(set) var takenOverBy: String?

    /// Set when the FIRST sync with a folder would absorb another device's history. Held for
    /// confirmation rather than applied: silently merging a year of data is what destroys trust
    /// in a tracker. Later merges apply automatically — by then you've agreed to the pairing.
    @Published private(set) var pendingFirstMerge: MergeReport?

    /// One row per device sharing this folder, for the Settings list. Built from the payloads we
    /// already read each poll, so it costs nothing extra.
    struct Peer: Identifiable, Equatable {
        let id: String            // device id
        /// Name that device published for itself, if any.
        let label: String?
        let lastSeen: Date        // when that device last published
        let isThisDevice: Bool
        /// Task this device is on, running or paused.
        let currentTask: String?
        /// True when that task is actively timing; false when paused on it.
        let isRunning: Bool
        /// The device stopped refreshing its marker, so what it reports can't be trusted as current.
        let isStale: Bool

        /// Kept for call sites that only care about live timing.
        var runningTask: String? { isRunning ? currentTask : nil }

        /// Green while timing, orange while paused on a task (the paused-highlight colour),
        /// grey when the device has no current task at all.
        var stateColor: Color {
            if currentTask == nil || isStale { return Color.secondary.opacity(0.4) }
            return isRunning ? .green : .orange
        }

        /// "macbook-pro" from "macbook-pro-b722" — the part a human recognises.
        var displayName: String {
            if let label, !label.isEmpty { return label }
            let parts = id.split(separator: "-")
            return parts.count > 1 ? parts.dropLast().joined(separator: "-") : id
        }
    }

    @Published private(set) var peers: [Peer] = []

    private let store: IntervalStore
    private let engine: TimerEngine
    private let appState: AppState
    private let settings: Settings
    private let deviceID: String

    private var transport: SyncTransport?
    private var timer: Timer?
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var cancellables: Set<AnyCancellable> = []

    private let auth: GoogleAuth

    init(store: IntervalStore, engine: TimerEngine, appState: AppState, settings: Settings,
         auth: GoogleAuth) {
        self.auth = auth
        self.store = store
        self.engine = engine
        self.appState = appState
        self.settings = settings
        self.deviceID = TimeslicePaths.deviceID(databaseURL: store.resolvedDatabaseURL)

        // Record OUR OWN label locally too. It's never merged from a payload (a device skips its
        // own file), so without this the timeline could name every peer except this machine.
        try? store.rememberDevice(id: deviceID,
                                  label: settings.deviceLabel.isEmpty ? nil : settings.deviceLabel)

        // Keep it current when the user renames this device.
        settings.$deviceLabel
            .receive(on: RunLoop.main)
            .sink { [weak self] label in
                guard let self else { return }
                try? self.store.rememberDevice(id: self.deviceID,
                                               label: label.isEmpty ? nil : label)
            }
            .store(in: &cancellables)

        // Re-arm whenever the folder changes or the timer starts/stops (running = no polling).
        Publishers.Merge(
            settings.$syncFolderPath.map { _ in () },
            settings.$syncMode.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.reconfigure() }
        .store(in: &cancellables)
        // Signing in/out changes whether a Drive transport can exist.
        auth.$isSignedIn
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconfigure() }
            .store(in: &cancellables)
        engine.$runningSince
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                if self?.engine.runningSince != nil { self?.takenOverBy = nil }
                self?.publishStateChange()
                self?.rearmTimer()
            }
            .store(in: &cancellables)

        // A local edit should reach other devices promptly, not on the next poll.
        NotificationCenter.default.publisher(for: TimesliceNotifications.dataDidChange)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publishStateChange() }
            .store(in: &cancellables)

        // The run loop is suspended while asleep, so poll once on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(syncNow), name: NSWorkspace.didWakeNotification, object: nil)

        reconfigure()
    }

    var isEnabled: Bool { transport != nil }

    /// Whether this device has agreed to merge with whatever else is in the folder. Keyed by
    /// folder path, so pointing at a *different* folder asks again.
    private var hasAcceptedPairing: Bool {
        get { UserDefaults.standard.string(forKey: Self.pairingKey) == settings.syncFolderPath }
        set { UserDefaults.standard.set(newValue ? settings.syncFolderPath : nil,
                                       forKey: Self.pairingKey) }
    }
    private static let pairingKey = "syncAcceptedPairingFolder"

    /// Prove the whole path works end to end: write a probe file to Drive, read it back, delete
    /// it. Answers "is sync actually working?" without needing a second device.
    @Published private(set) var selfTestResult: String?

    func runSelfTest() {
        guard let transport else {
            selfTestResult = "Sync isn't on"
            return
        }
        selfTestResult = "Checking…"
        Task.detached { [weak self] in
            await self?.performSelfTest(transport)
        }
    }

    /// `nonisolated` so the Drive calls really leave the main actor. As a plain method on this
    /// @MainActor class it would inherit main-actor isolation even from Task.detached — which is
    /// what tripped the transport's "must not be used from the main thread" guard.
    nonisolated private func performSelfTest(_ transport: SyncTransport) async {
        let probeID = "selftest-\(UUID().uuidString.prefix(6))"
        let sample = Data("{\"probe\":true}".utf8)
        let outcome: String
        do {
            try transport.put(payload: sample, deviceID: probeID)
            // Read it back as another device would.
            let seen = try transport.fetchOthers(excluding: "someone-else")
            let found = seen.contains(sample)
            // ALWAYS remove it. A lingering probe looks like a peer whose payload can't be
            // decoded, which surfaced as a permanent error on every later sync.
            try? transport.deletePayload(deviceID: probeID)
            outcome = found
                ? "Working — wrote and read back a test file"
                : "Wrote a test file but couldn't read it back"
        } catch {
            outcome = "Failed: \(error.localizedDescription)"
        }
        // Count what's actually in Drive, so the result names the peers it can see.
        var detail = ""
        if let files = try? transport.fetchOthers(excluding: "nobody") {
            detail = " (\(files.count) device file\(files.count == 1 ? "" : "s") in Drive)"
        }
        let message = outcome + (outcome.hasPrefix("Working") ? detail : "")
        let succeeded = message.hasPrefix("Working")
        await MainActor.run {
            self.selfTestResult = message
            // A passing test proves the previous failure is history — leaving it on screen next
            // to a green "Working" line is just confusing.
            if succeeded {
                self.lastError = nil
                self.syncNow()      // re-sync now that the cause is resolved
            }
        }
    }

    /// Remove device files in Drive that aren't a live device — retired machines, and probe files
    /// from earlier testing. Keeps this device's own file and anything that still decodes.
    func forgetStaleDevices() {
        guard let transport else { return }
        selfTestResult = "Cleaning up…"
        Task.detached { [weak self] in
            await self?.performCleanup(transport)
        }
    }

    nonisolated private func performCleanup(_ transport: SyncTransport) async {
        var removed = 0
        let message: String
        do {
            // Unreadable files can't be identified by device id (that's inside the payload we
            // can't parse), so they're removed by NAME from the raw listing below.
            removed += transport.deleteUnreadablePayloads(excluding: deviceID)

            for data in try transport.fetchOthers(excluding: deviceID) {
                guard let payload = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
                    continue
                }
                // A payload with no tasks AND no intervals was never a real device's data.
                if payload.tasks.isEmpty && payload.intervals.isEmpty {
                    try? transport.deletePayload(deviceID: payload.deviceID)
                    try? transport.putRunning(nil, deviceID: payload.deviceID)
                    removed += 1
                }
            }
            message = removed > 0
                ? "Removed \(removed) empty device file\(removed == 1 ? "" : "s")"
                : "Nothing to clean up"
        } catch DriveAPI.DriveError.notFound {
            // Already gone — that's the desired end state, not a failure.
            message = removed > 0 ? "Removed \(removed) empty device file(s)" : "Nothing to clean up"
        } catch {
            message = "Cleanup failed: \(error.localizedDescription)"
        }
        await MainActor.run {
            self.selfTestResult = message
            self.lastError = nil
            self.syncNow()
        }
    }

    /// Remove one specific device from Drive.
    ///
    /// Needed because `forgetStaleDevices` only clears EMPTY files, and a retired device (or one
    /// whose id changed) carries a full copy of your history — so it lingers as a duplicate that
    /// nothing can remove. Its data is already merged locally, so dropping the file loses nothing.
    func forget(deviceID id: String) {
        guard let transport else { return }
        selfTestResult = "Removing \(id)…"
        Task.detached { [weak self] in
            guard let self else { return }
            try? transport.deletePayload(deviceID: id)
            try? transport.putRunning(nil, deviceID: id)
            await MainActor.run {
                self.peers.removeAll { $0.id == id }
                self.selfTestResult = "Removed that device"
                self.syncNow()
            }
        }
    }

    /// Accept the pending merge and pull the data in.
    func acceptFirstMerge() {
        hasAcceptedPairing = true
        pendingFirstMerge = nil
        syncNow()
    }

    /// Decline: turn sync off rather than sitting in a half-paired state.
    func declineFirstMerge() {
        pendingFirstMerge = nil
        settings.syncFolderPath = ""
    }
    var deviceLabel: String { deviceID }

    private func reconfigure() {
        timer?.invalidate(); timer = nil
        folderWatcher?.cancel(); folderWatcher = nil
        transport = nil
        runningElsewhere = nil

        switch settings.syncMode {
        case .off:
            return
        case .googleDrive:
            guard auth.isSignedIn else { return }
            // The API refreshes the access token on demand via this closure.
            let api = DriveAPI(token: { [auth] in try await auth.validAccessToken() })
            transport = DriveSyncTransport(api: api)
            rearmTimer()
            syncNow()
        case .folder:
            guard let root = settings.syncFolderURL else { return }
            do {
                transport = try FolderSyncTransport(root: root)
                watchFolder(root)
                rearmTimer()
                syncNow()
            } catch {
                lastError = "Couldn't use that folder: \(error.localizedDescription)"
            }
        }
    }

    /// Wake on directory change — a synced folder dropping a file in is our closest thing to push.
    private func watchFolder(_ root: URL) {
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in self?.syncNow() }
        src.setCancelHandler { close(fd) }
        src.resume()
        folderWatcher = src
    }

    private func rearmTimer() {
        timer?.invalidate(); timer = nil
        guard transport != nil else { return }

        // A RUNNING device must keep polling. The earlier version skipped polling entirely while
        // timing ("we're the writer, nobody can override us"), which was exactly backwards: a
        // running device is the one that needs to learn it's been superseded. With both devices
        // timing, neither ever checked the other's marker, so the takeover could never fire and
        // both kept running — double-counting the same wall-clock time.
        //
        // Running devices poll a little slower: they only need to notice a takeover, whereas an
        // idle device is also waiting to pull in new work.
        let interval: TimeInterval
        if engine.runningSince != nil {
            interval = NSApp.isActive ? 15 : 45
        } else {
            interval = NSApp.isActive ? 10 : 60
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
    }

    /// Upload images this device holds and fetch ones it only has a manifest row for.
    ///
    /// Separate from the payload round-trip on purpose: an image is immutable and possibly a
    /// megabyte, so it's transferred once and then never looked at again, while the payload is
    /// rewritten every time anything changes.
    private func transferAttachments(engineSync: SyncEngine) async -> Int {
        guard let transport else { return 0 }
        let store = await MainActor.run { self.appState.storeForEditing }

        for pending in (try? await MainActor.run { try store.attachmentsNeedingUpload() }) ?? [] {
            guard let data = try? Data(contentsOf: store.fileURL(forAttachment: pending.uid))
            else { continue }
            do {
                try transport.putBlob(name: pending.blobName, data: data)
                try? await MainActor.run { try store.markAttachmentUploaded(uid: pending.uid) }
            } catch {
                // Left unmarked, so the next sync tries again.
                continue
            }
        }

        var fetched = 0
        for missing in (try? await MainActor.run { try store.attachmentsMissingBytes() }) ?? [] {
            guard let data = try? transport.fetchBlob(name: missing.blobName), !data.isEmpty
            else { continue }          // not uploaded yet — the row legitimately outruns the bytes
            if (try? await MainActor.run {
                try store.storeAttachmentBytes(uid: missing.uid, png: data)
            }) != nil { fetched += 1 }
        }
        return fetched
    }

    @objc func syncNow() {
        guard let transport else { return }
        // ALWAYS off the main thread. Drive calls block on the network, and blocking the main
        // actor here is what deadlocked the app; the transport now refuses main-thread use.
        Task.detached { [weak self] in
            await self?.performSync(transport)
        }
    }

    /// Runs the whole sync OFF the main actor.
    ///
    /// The previous version hopped straight back onto the main actor with `MainActor.run` and then
    /// blocked there on `DriveSyncTransport`'s semaphore — which waits for async work that needs
    /// the main actor to proceed. That deadlocked the app on the first Drive sync. Only the small
    /// published-state updates are hopped back, individually.
    nonisolated private func performSync(_ transport: SyncTransport) async {
        let engineSync = await MainActor.run { SyncEngine(store: self.store, deviceID: self.deviceID,
                                                    deviceLabel: self.settings.deviceLabel.isEmpty ? nil : self.settings.deviceLabel) }
        do {
            let payloads = try transport.fetchOthers(excluding: deviceID)

            let accepted = await MainActor.run { self.hasAcceptedPairing }
            if !accepted, !payloads.isEmpty {
                var preview = MergeReport()
                for data in payloads {
                    guard let p = try? JSONDecoder().decode(SyncPayload.self, from: data) else { continue }
                    preview.tasksAdded += p.tasks.count
                    preview.intervalsAdded += p.intervals.count
                    preview.projectsAdded += p.projects.count
                }
                if !preview.isEmpty {
                    let payload = try await MainActor.run { try engineSync.buildPayload() }
                    try transport.put(payload: try JSONEncoder().encode(payload), deviceID: deviceID)
                    let snapshot = preview   // immutable copy, so the hop can't race the mutation
                    await MainActor.run {
                        self.pendingFirstMerge = snapshot
                        self.lastSyncedAt = Date()
                    }
                    return
                }
                await MainActor.run { self.hasAcceptedPairing = true }
            }

            var combined = MergeReport()
            var discovered: [Peer] = []
            var skipped = 0
            for data in payloads {
                // Tolerate junk: one undecodable file must not abort syncing with every other
                // device. Stale probes and partially-written payloads both land here.
                guard let payload = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
                    skipped += 1
                    continue
                }
                // One row per device even if Drive holds several files for it. Dedupe the DISPLAY
                // only — the payload is still merged below, since skipping it could drop data if
                // the copies differ. Keep the most recently written one's label/timestamp.
                let seenAt = Date(timeIntervalSince1970: payload.writtenAt)
                if let i = discovered.firstIndex(where: { $0.id == payload.deviceID }) {
                    if seenAt > discovered[i].lastSeen {
                        discovered[i] = Peer(id: payload.deviceID, label: payload.deviceLabel,
                                             lastSeen: seenAt, isThisDevice: false,
                                             currentTask: nil, isRunning: false, isStale: false)
                    }
                } else {
                    discovered.append(Peer(id: payload.deviceID, label: payload.deviceLabel,
                                           lastSeen: seenAt,
                                           isThisDevice: false, currentTask: nil, isRunning: false,
                                           isStale: false))
                }
                // Store writes must happen on the main actor — that's where the store lives.
                let r = try await MainActor.run { try engineSync.merge(payload) }
                combined.tasksAdded += r.tasksAdded
                combined.intervalsAdded += r.intervalsAdded
                combined.projectsAdded += r.projectsAdded
                combined.projectsMergedByName += r.projectsMergedByName
                combined.taskEditsApplied += r.taskEditsApplied
                combined.projectEditsApplied += r.projectEditsApplied
                combined.intervalsReattributed += r.intervalsReattributed
                combined.deletionsApplied += r.deletionsApplied
            }

            // Takeover + presence need remote markers, fetched off-actor. Paired with Drive's own
            // modifiedTime so staleness is judged against ONE clock rather than each peer's.
            let markerData = try transport.fetchOtherRunningWithTimes(excluding: deviceID)
            var markers: [RunningMarker] = []
            var observedAt: [String: Date] = [:]
            for (data, modified) in markerData {
                guard let m = try? JSONDecoder().decode(RunningMarker.self, from: data) else { continue }
                markers.append(m)
                if let modified { observedAt[m.deviceID] = modified }
            }
            let payload = try await MainActor.run { try engineSync.buildPayload() }
            let presence = await MainActor.run { self.currentPresenceMarker() }

            try transport.put(payload: try JSONEncoder().encode(payload), deviceID: deviceID)
            if let presence {
                try transport.putRunning(try JSONEncoder().encode(presence), deviceID: deviceID)
            } else {
                try transport.putRunning(nil, deviceID: deviceID)
            }

            // Images move as their own blobs, AFTER the manifest is published, so a peer never
            // learns about a picture before the bytes it names are fetchable. Failures here are
            // logged and dropped: a screenshot that didn't make it is worth retrying next sync, not
            // worth failing the whole sync over.
            let moved = await transferAttachments(engineSync: engineSync)
            combined.attachmentsApplied += moved

            let report = combined      // ditto: snapshot before crossing the actor boundary
            let peersSeen = discovered
            let skippedCount = skipped
            await MainActor.run {
                if !report.isEmpty {
                    self.lastReport = report
                    self.appState.reload()
                    NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)
                }
                self.applyMarkers(markers, discovered: peersSeen)
                self.lastSyncedAt = Date()
                // Only mention skipped files; a clean sync should say nothing.
                self.lastError = skippedCount > 0
                    ? "Ignored \(skippedCount) unreadable file\(skippedCount == 1 ? "" : "s") in Drive"
                    : nil
            }
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
        }
    }

    /// This device's presence marker, or nil when it isn't timing.
    private func currentPresenceMarker() -> RunningMarker? {
        // Running: the timer is live and this is a claim other devices must yield to.
        if let since = engine.runningSince, let taskID = engine.runningProjectID,
           let uid = ((try? store.uid(table: "projects", id: taskID)) ?? nil) {
            // writtenAt is stamped NOW, not at `since`: it's a heartbeat, so other devices can tell
            // an actively-maintained claim from one abandoned by a crash or sleep.
            return RunningMarker(deviceID: deviceID, taskUID: uid,
                                 since: since.timeIntervalSince1970, isRunning: true,
                                 writtenAt: Date().timeIntervalSince1970)
        }
        // Paused: still publish, flagged not-running, so other devices can show what this one was
        // last on. Previously the marker was deleted here, so a paused device was indistinguishable
        // from one that had never started.
        if let taskID = engine.currentProjectID,
           let uid = ((try? store.uid(table: "projects", id: taskID)) ?? nil) {
            let at = engine.pausedSince ?? Date()
            return RunningMarker(deviceID: deviceID, taskUID: uid,
                                 since: at.timeIntervalSince1970, isRunning: false,
                                 writtenAt: Date().timeIntervalSince1970)
        }
        return nil   // genuinely idle: no current task at all
    }

    /// Peer list + takeover, given already-fetched markers.
    private func applyMarkers(_ markers: [RunningMarker], discovered: [Peer],
                              observedAt: [String: Date] = [:]) {
        let now = Date()
        var taskByDevice: [String: (name: String, running: Bool, live: Bool)] = [:]
        for m in markers {
            let name: String
            if let id = ((try? store.localID(table: "projects", uid: m.taskUID)) ?? nil),
               let task = (try? store.listProjects(includeArchived: true))?.first(where: { $0.id == id }) {
                name = task.name
            } else {
                name = "a task"   // not merged yet
            }
            // A stale RUNNING marker must not read as "timing now" — that's the green row that
            // lingered for a device which had already stopped.
            let live = m.isFresh(now: now, cutoff: TakeoverPolicy.livenessCutoff,
                                 observedAt: observedAt[m.deviceID])
            taskByDevice[m.deviceID] = (name, m.claimsTimer && live, live)
        }
        let myTask = (engine.runningProjectID ?? engine.currentProjectID).flatMap { id in
            appState.projects.first { $0.id == id }?.name
        }
        let mine = Peer(id: deviceID,
                        label: settings.deviceLabel.isEmpty ? nil : settings.deviceLabel,
                        lastSeen: Date(), isThisDevice: true,
                        currentTask: myTask, isRunning: engine.runningSince != nil,
                        isStale: false)
        // Sorted by `DeviceOrder`, the same comparator the day timeline's lanes use, and with this
        // device NOT hoisted to the top — so a device sits in the same position in both places.
        // Ordering by last-seen looked reasonable but meant the list reshuffled as devices synced,
        // and never matched the lane order beside it.
        peers = ([mine] + discovered
            .map { Peer(id: $0.id, label: $0.label, lastSeen: $0.lastSeen, isThisDevice: false,
                        currentTask: taskByDevice[$0.id]?.name,
                        isRunning: taskByDevice[$0.id]?.running ?? false,
                        isStale: taskByDevice[$0.id].map { !$0.live } ?? false) })
            .sorted { DeviceOrder.key(id: $0.id, label: $0.label)
                    < DeviceOrder.key(id: $1.id, label: $1.label) }
        runningElsewhere = markers
            .filter { $0.claimsTimer && $0.isFresh(now: now, cutoff: TakeoverPolicy.livenessCutoff,
                                                   observedAt: observedAt[$0.deviceID]) }
            .max(by: { $0.since < $1.since })?.deviceID

        if let decision = TakeoverPolicy.decide(localRunningSince: engine.runningSince,
                                               markers: markers, now: now,
                                               observedAt: observedAt) {
            engine.pause(at: decision.pauseAt)
            // Prefer the device's own published label over its raw id.
            let label = peers.first { $0.id == decision.byDeviceID }?.displayName
            takenOverBy = label ?? decision.byDeviceID
            appState.reload()
        }
    }

    /// Resolve running markers to task NAMES (markers carry uids, which mean nothing to a human)
    /// and put this device at the top of the list.
    /// Stop our timer if another device started one later. Silent by design — you're already
    /// working on the other machine, so a dialog here interrupts nothing.
    private func applyTakeover(_ transport: SyncTransport) throws {
        // Same freshness rule as the polling path: an abandoned marker outranks any earlier timer,
        // so without this a crashed device would pause this one on every check.
        let now = Date()
        var markers: [RunningMarker] = []
        var observedAt: [String: Date] = [:]
        for (data, modified) in try transport.fetchOtherRunningWithTimes(excluding: deviceID) {
            guard let m = try? JSONDecoder().decode(RunningMarker.self, from: data) else { continue }
            markers.append(m)
            if let modified { observedAt[m.deviceID] = modified }
        }
        runningElsewhere = markers
            .filter { $0.claimsTimer && $0.isFresh(now: now, cutoff: TakeoverPolicy.livenessCutoff,
                                                   observedAt: observedAt[$0.deviceID]) }
            .max(by: { $0.since < $1.since })?.deviceID
        guard let decision = TakeoverPolicy.decide(
            localRunningSince: engine.runningSince, markers: markers, now: now,
            observedAt: observedAt) else { return }
        engine.pause(at: decision.pauseAt)
        appState.reload()
    }

    /// Publish after a local change. Network transports go off-actor; a folder can be written
    /// inline since it's local file I/O.
    private func publishStateChange() {
        guard let transport else { return }
        if transport is DriveSyncTransport {
            Task.detached { [weak self] in
                guard let self else { return }
                let engineSync = await MainActor.run { SyncEngine(store: self.store, deviceID: self.deviceID,
                                                    deviceLabel: self.settings.deviceLabel.isEmpty ? nil : self.settings.deviceLabel) }
                do {
                    let payload = try await MainActor.run { try engineSync.buildPayload() }
                    try transport.put(payload: try JSONEncoder().encode(payload), deviceID: self.deviceID)
                    let presence = await MainActor.run { self.currentPresenceMarker() }
                    if let presence {
                        try transport.putRunning(try JSONEncoder().encode(presence), deviceID: self.deviceID)
                    } else {
                        try transport.putRunning(nil, deviceID: self.deviceID)
                    }
                } catch {
                    await MainActor.run { self.lastError = error.localizedDescription }
                }
            }
        }
    }

}
