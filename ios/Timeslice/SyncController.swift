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

    // MARK: - One cycle

    /// Publish our facts, merge everyone else's, then settle the one-timer invariant.
    ///
    /// Order matters: publish before merging, so a peer polling concurrently sees our current state
    /// rather than a version from before this cycle.
    @discardableResult
    func syncOnce() async -> Bool {
        guard !isSyncing, let transport, let store = TimerModel.shared.storeIfLoaded else {
            return false
        }
        isSyncing = true
        defer { isSyncing = false }

        let deviceID = store.localDeviceID ?? TimeslicePaths.deviceID()
        let engine = SyncEngine(store: store, deviceID: deviceID)

        do {
            // 1. Publish our payload.
            let payload = try engine.buildPayload()
            try transport.put(payload: try JSONEncoder().encode(payload), deviceID: deviceID)

            // 2. Merge every other device's.
            for data in try transport.fetchOthers(excluding: deviceID) {
                guard let remote = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
                    // A payload we can't decode is a peer on a newer format or a truncated write;
                    // skipping it is right, and the transport prunes genuinely unreadable files.
                    continue
                }
                _ = try engine.merge(remote)
            }

            // 3. Resolve the one-timer invariant, then republish presence.
            try settleTakeover(transport: transport, deviceID: deviceID, store: store)
            try publishMarker(transport: transport, deviceID: deviceID, store: store)

            TimerModel.shared.reload()
            return true
        } catch {
            NSLog("[timeslice] sync failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Stop our timer if another device started one later. Decision is `TakeoverPolicy`'s.
    private func settleTakeover(transport: SyncTransport, deviceID: String,
                                store: IntervalStore) throws {
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

        let localSince = try store.openInterval()?.start
        guard let decision = TakeoverPolicy.decide(localRunningSince: localSince,
                                                   markers: markers,
                                                   observedAt: observedAt) else { return }
        // Back-dated to when the other device started, so the two devices' intervals abut instead of
        // overlapping — this is what makes the delayed wake-up harmless.
        try store.stopOpenInterval(at: decision.pauseAt)
        NSLog("[timeslice] paused by \(decision.byDeviceID) at \(decision.pauseAt)")
    }

    /// Republish our running/paused marker. Written every cycle, because its freshness is what other
    /// devices use to decide whether our claim is still live.
    private func publishMarker(transport: SyncTransport, deviceID: String,
                               store: IntervalStore) throws {
        guard let open = try store.openInterval() else {
            // No open interval: clear the claim rather than leaving a stale one that would pause
            // other devices indefinitely.
            try transport.putRunning(nil, deviceID: deviceID)
            return
        }
        // The task travels as its **uid**, never its row id — `subject_id = 8` is a different task on
        // the other machine.
        guard let uid = try store.uid(table: "projects", id: open.projectID) else { return }
        // `writtenAt` is the heartbeat, distinct from `since` (when the timer started). It's the
        // fallback freshness signal when a transport has no server-side timestamp of its own.
        let marker = RunningMarker(deviceID: deviceID, taskUID: uid,
                                   since: open.start.timeIntervalSince1970,
                                   isRunning: true,
                                   writtenAt: Date().timeIntervalSince1970)
        try transport.putRunning(try JSONEncoder().encode(marker), deviceID: deviceID)
    }
}
