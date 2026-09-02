import BackgroundTasks
import Foundation
import TimesliceCore

/// One sync cycle, plus the `BGAppRefreshTask` that drives it on a phone.
///
/// The merge itself is entirely `SyncEngine` and `TakeoverPolicy` from Core — same payload format,
/// same uid-keyed facts, same last-writer-wins on `updated_at`, same tombstones as the Mac. Only the
/// *cadence* differs, and that difference is accepted rather than fought:
///
/// **`BGAppRefreshTask` is opportunistic.** iOS decides when (and whether) to run it, so a
/// backgrounded phone may not notice another device's takeover for minutes or hours. The data still
/// converges, because `TakeoverPolicy` back-dates `pauseAt` to when the other device *started* — so
/// when the phone finally wakes it retroactively clamps its own interval rather than losing or
/// double-counting the overlap. Do not try to beat this with background modes; there is no
/// legitimate one for "poll a file store".
///
/// **Consequence handled here:** a phone asleep mid-timer stops refreshing its marker, and after
/// `TakeoverPolicy.livenessCutoff` (5 minutes) the Mac treats its claim as stale and ignores it.
/// That's right for a dead device and wrong for a phone genuinely still timing — so the marker is
/// republished from the same background task that syncs, and a long-backgrounded phone simply loses
/// the takeover argument. That is the honest trade, not a bug to paper over.
@MainActor
final class SyncController {
    static let shared = SyncController()

    /// Registered with the system at launch; must match the value in project.yml's
    /// `BGTaskSchedulerPermittedIdentifiers`, or `register` throws at runtime.
    static let taskIdentifier = "com.timeslice.ios.sync"

    private var transport: SyncTransport?
    private var isSyncing = false

    private init() {}

    /// True only when a Google client is configured AND the user has a token. Sync stays off by
    /// default, exactly as on the Mac — there is nothing to sign into unless you want a second device.
    var isAvailable: Bool { GoogleOAuth.isConfigured && transport != nil }

    /// Point the controller at a transport. Left to the caller because acquiring a Drive token needs
    /// `ASWebAuthenticationSession` on iOS, which is UI, not sync.
    func use(transport: SyncTransport) { self.transport = transport }

    // MARK: - Background scheduling

    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier, using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                // Reschedule FIRST: a thrown error or an expiry later in this block would otherwise
                // leave nothing queued and sync would stop permanently after one bad run.
                self.scheduleNextRefresh()
                refresh.expirationHandler = { self.isSyncing = false }
                let ok = await self.syncOnce()
                refresh.setTaskCompleted(success: ok)
            }
        }
    }

    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        // A floor, not a promise — iOS treats it as "no earlier than" and decides the rest from
        // usage patterns and battery.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expect `BGTaskSchedulerErrorDomain error 1` (.unavailable) on the SIMULATOR —
            // BGTaskScheduler isn't supported there at all. Registration still succeeds, so this is
            // a simulator limitation rather than a failure worth surfacing to the user. On a device
            // it means background refresh is disabled in Settings.
            NSLog("[timeslice] BG refresh submit failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Polling while the app is open

    private var pollTimer: Timer?

    /// Poll while the app is FOREGROUND, so a takeover started on another device is noticed here.
    ///
    /// This was the bug behind "auto pause is not working across devices". The phone only ever synced on
    /// three occasions: a foreground transition, its own local change, and an opportunistic
    /// `BGAppRefreshTask`. None of them fires while you're simply *looking* at the app — so if you started
    /// a timer on the Mac with the phone open in front of you, the phone never found out and both devices
    /// counted the same wall-clock minutes.
    ///
    /// The Mac has always polled on a timer; the phone never did. Same intervals as the Mac's active case,
    /// and the same reasoning: a device that is itself running only needs to notice a takeover, while an
    /// idle one is also waiting to pull in new work.
    ///
    /// Foreground only. A suspended app doesn't get timers anyway, and asking for background execution to
    /// poll a file store is exactly what iOS declines to grant.
    func startForegroundPolling() {
        stopForegroundPolling()
        let interval: TimeInterval = TimerModel.shared.isRunning ? 15 : 10
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.transport != nil else { return }
                await self.syncOnce()
                // Re-arm: `isRunning` may have changed, and the two cases want different rates.
                self.startForegroundPolling()
            }
        }
    }

    func stopForegroundPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Publishing a local change

    private var publishTask: Task<Void, Never>?

    /// Publish a local change promptly instead of waiting for the next poll.
    ///
    /// The Mac does this by debouncing `dataDidChange` by 2s and publishing. iOS had NO equivalent:
    /// starting a timer on the phone wrote nothing to Drive until the next foreground transition or an
    /// opportunistic `BGAppRefreshTask` — and if the app was already foreground when you tapped, that
    /// meant nothing at all. Other devices therefore never saw the running marker, so
    /// `TakeoverPolicy` had nothing to act on and the phone never stopped the Mac's timer.
    ///
    /// Debounced because a task switch is two mutations (close one interval, open another) and each
    /// would otherwise be a full publish.
    func publishSoon() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncOnce()
        }
    }

    // MARK: - One cycle

    /// Publish our facts, merge everyone else's, then settle the one-timer invariant.
    ///
    /// Order matters: publish before merging, so a peer polling concurrently sees our current state
    /// rather than a version from before this cycle.
    @discardableResult
    func syncOnce() async -> Bool {
        guard !isSyncing, transport != nil, TimerModel.shared.storeIfLoaded != nil else {
            return false
        }
        isSyncing = true
        defer { isSyncing = false }
        return await performSync()
    }

    /// The cycle itself, deliberately `nonisolated`.
    ///
    /// `DriveSyncTransport` bridges async Drive calls to `SyncTransport`'s synchronous API with a
    /// semaphore, and traps on the main thread — blocking there would deadlock, since the awaited
    /// work needs the main actor to proceed. As a plain method on this `@MainActor` class every
    /// transport call inherited main-actor isolation and tripped that guard, crashing the app on the
    /// first sync after sign-in. The Mac's `SyncController` hit this and solved it the same way.
    ///
    /// So the split is: transport I/O runs here, off the actor, and only `IntervalStore` work hops
    /// back — the store is not `Sendable` and belongs to the main-actor `TimerModel`.
    nonisolated private func performSync() async -> Bool {
        guard let transport = await MainActor.run(body: { self.transport }) else { return false }

        do {
            // 1. Publish our payload. Building it reads the store, so it happens on the main actor;
            //    only the upload leaves it.
            let (deviceID, encoded) = try await MainActor.run { () -> (String, Data) in
                let store = try Self.requireStore()
                let id = store.localDeviceID ?? TimeslicePaths.deviceID()
                // The label travels WITH the payload — that's how a peer shows "MacBook Air" rather
                // than a slug like `iphone-b653`. Omitting it left this device nameless on every other
                // device's timeline.
                let label = TimerModel.shared.settings.deviceLabel
                let engine = SyncEngine(store: store, deviceID: id,
                                        deviceLabel: label.isEmpty ? nil : label)
                // Recorded locally in the SAME hop, so this device's own list agrees with what peers
                // will see rather than showing the raw id until the next round trip.
                try? store.rememberDevice(id: id, label: label.isEmpty ? nil : label)
                return (id, try JSONEncoder().encode(try engine.buildPayload()))
            }
            try transport.put(payload: encoded, deviceID: deviceID)

            // 2. Fetch off-actor, then merge on it — one hop per payload, since each merge is a
            //    store write.
            for data in try transport.fetchOthers(excluding: deviceID) {
                guard let remote = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
                    // A payload we can't decode is a peer on a newer format or a truncated write;
                    // skipping it is right, and the transport prunes genuinely unreadable files.
                    continue
                }
                try await MainActor.run {
                    let store = try Self.requireStore()
                    _ = try SyncEngine(store: store, deviceID: deviceID).merge(remote)
                }
            }

            // 3. Feedback images, as their own blobs — after the manifest is published, so a peer
            //    never learns about a picture before the bytes it names are fetchable. Deliberately
            //    not in the payload: it's rewritten in full on every publish, and a few screenshots
            //    embedded there would mean re-uploading megabytes on a phone's mobile data.
            await transferAttachments(transport: transport)

            // 4. Resolve the one-timer invariant, then republish presence.
            try await settleTakeover(transport: transport, deviceID: deviceID)
            try await publishMarker(transport: transport, deviceID: deviceID)

            await MainActor.run { TimerModel.shared.reload() }
            return true
        } catch {
            NSLog("[timeslice] sync failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Upload images this device holds and fetch ones it only has a manifest row for.
    ///
    /// `nonisolated` for the same reason the rest of the sync is: `putBlob`/`fetchBlob` are transport
    /// I/O and `DriveSyncTransport.blocking()` traps if it's called on the main actor. Only the store
    /// hops back.
    ///
    /// Failures are swallowed on purpose. A screenshot that didn't transfer is worth retrying on the
    /// next sync; it is not worth failing the sync — and so losing the text of every note — over.
    nonisolated private func transferAttachments(transport: SyncTransport) async {
        let pending = (try? await MainActor.run {
            try Self.requireStore().attachmentsNeedingUpload()
        }) ?? []
        for shot in pending {
            guard let data = try? await MainActor.run(body: {
                try Data(contentsOf: try Self.requireStore().fileURL(forAttachment: shot.uid))
            }) else { continue }
            do {
                try transport.putBlob(name: shot.blobName, data: data)
                try? await MainActor.run {
                    try Self.requireStore().markAttachmentUploaded(uid: shot.uid)
                }
            } catch {
                continue        // left unmarked, so the next sync tries again
            }
        }

        let missing = (try? await MainActor.run {
            try Self.requireStore().attachmentsMissingBytes()
        }) ?? []
        for shot in missing {
            // nil is expected, not an error: the manifest row legitimately outruns the bytes.
            guard let data = try? transport.fetchBlob(name: shot.blobName), !data.isEmpty
            else { continue }
            try? await MainActor.run {
                try Self.requireStore().storeAttachmentBytes(uid: shot.uid, png: data)
            }
        }
    }

    /// The store, or a thrown error — it can be torn down between hops, and force-unwrapping it
    /// would turn an ordinary "not loaded yet" into a crash.
    @MainActor
    private static func requireStore() throws -> IntervalStore {
        guard let store = TimerModel.shared.storeIfLoaded else { throw SyncError.storeUnavailable }
        return store
    }

    enum SyncError: Error { case storeUnavailable }

    /// Stop our timer if another device started one later. Decision is `TakeoverPolicy`'s.
    ///
    /// `nonisolated`: the marker fetch is transport I/O and must not run on the main actor. Only the
    /// store read and the stop hop back.
    nonisolated private func settleTakeover(transport: SyncTransport,
                                            deviceID: String) async throws {
        let observed = try transport.fetchOtherRunningWithTimes(excluding: deviceID)
        var markers: [RunningMarker] = []
        var observedAt: [String: Date] = [:]
        for entry in observed {
            guard let marker = try? JSONDecoder().decode(RunningMarker.self, from: entry.data) else {
                continue
            }
            markers.append(marker)
            // Prefer the transport's own timestamp: one server clock beats trusting every peer's.
            if let modified = entry.modified { observedAt[marker.deviceID] = modified }
        }

        let localSince = try await MainActor.run { try Self.requireStore().openInterval()?.start }
        guard let decision = TakeoverPolicy.decide(localRunningSince: localSince,
                                                   markers: markers,
                                                   observedAt: observedAt) else { return }
        // Back-dated to when the other device started, so the two devices' intervals abut instead of
        // overlapping — this is what makes the delayed wake-up harmless.
        try await MainActor.run {
            try Self.requireStore().stopOpenInterval(at: decision.pauseAt)
            // Tell the model, don't just write the row. Stopping at the write left the Live Activity
            // ticking on a timer that no longer existed.
            TimerModel.shared.applyRemoteTakeover(byDeviceID: decision.byDeviceID, at: decision.pauseAt)
        }
        NSLog("[timeslice] paused by \(decision.byDeviceID) at \(decision.pauseAt)")
    }

    /// Republish our running/paused marker. Written every cycle, because its freshness is what other
    /// devices use to decide whether our claim is still live.
    ///
    /// `nonisolated` for the same reason as the rest: `putRunning` is transport I/O. The store reads
    /// are gathered in one main-actor hop first, so the marker is built from a consistent snapshot.
    nonisolated private func publishMarker(transport: SyncTransport,
                                           deviceID: String) async throws {
        let snapshot = try await MainActor.run { () -> (start: Date, uid: String)? in
            let store = try Self.requireStore()
            guard let open = try store.openInterval(),
                  // The task travels as its **uid**, never its row id — `subject_id = 8` is a
                  // different task on the other machine.
                  let uid = try store.uid(table: "projects", id: open.projectID) else { return nil }
            return (open.start, uid)
        }
        guard let snapshot else {
            // No open interval: clear the claim rather than leaving a stale one that would pause
            // other devices indefinitely.
            try transport.putRunning(nil, deviceID: deviceID)
            return
        }
        // `writtenAt` is the heartbeat, distinct from `since` (when the timer started). It's the
        // fallback freshness signal when a transport has no server-side timestamp of its own.
        let marker = RunningMarker(deviceID: deviceID, taskUID: snapshot.uid,
                                   since: snapshot.start.timeIntervalSince1970,
                                   isRunning: true,
                                   writtenAt: Date().timeIntervalSince1970)
        try transport.putRunning(try JSONEncoder().encode(marker), deviceID: deviceID)
    }
}
