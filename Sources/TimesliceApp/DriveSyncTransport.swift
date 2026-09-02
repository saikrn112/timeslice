import Foundation
import TimesliceCore

/// `SyncTransport` over Google Drive's `appDataFolder`.
///
/// Same file model as the folder transport — one payload file and one marker file per device, so
/// no two devices ever write the same file and conflicts are impossible by construction. The
/// difference is change detection: Drive's `changes.list` returns a **delta** ("nothing new") in
/// one small request, rather than listing and comparing files.
///
/// `SyncTransport` is synchronous (it was designed around file I/O), so each call bridges to the
/// async Drive API. Callers are already off the hot path — sync runs on a timer, never during
/// timing — so blocking briefly here is acceptable and keeps one merge implementation for both
/// transports.
final class DriveSyncTransport: SyncTransport {
    private let api: DriveAPI
    /// name → file id, so we PATCH instead of creating duplicates.
    private var idCache: [String: String] = [:]
    private let cacheLock = NSLock()

    init(api: DriveAPI) {
        self.api = api
    }

    private func payloadName(_ device: String) -> String { "device-\(device).json" }
    private func runningName(_ device: String) -> String { "device-\(device).running" }

    // MARK: - SyncTransport

    func put(payload: Data, deviceID: String) throws {
        try upsert(name: payloadName(deviceID), contents: payload)
    }

    func fetchOthers(excluding deviceID: String) throws -> [Data] {
        try fetch(suffix: ".json", excluding: deviceID)
    }

    func putRunning(_ marker: Data?, deviceID: String) throws {
        let name = runningName(deviceID)
        if let marker {
            try upsert(name: name, contents: marker)
        } else if let id = try lookup(name: name) {
            try blocking { try await self.api.delete(id: id) }
            cacheLock.lock(); idCache[name] = nil; cacheLock.unlock()
        }
    }

    func fetchOtherRunning(excluding deviceID: String) throws -> [Data] {
        try fetch(suffix: ".running", excluding: deviceID)
    }

    /// Markers paired with Drive's own last-modified time.
    ///
    /// The server timestamp is preferable to the marker's self-reported heartbeat for judging
    /// staleness: comparing against a peer's clock inherits the same skew weakness as LWW, whereas
    /// this is one clock for all devices. Falls back to the in-marker value when Drive omits it.
    func fetchOtherRunningWithTimes(excluding deviceID: String) throws -> [(data: Data, modified: Date?)] {
        try fetchWithTimes(suffix: ".running", excluding: deviceID)
    }

    func deleteUnreadablePayloads(excluding deviceID: String) -> Int {
        let mine = "device-\(deviceID)"
        guard let files = try? blocking({ try await self.api.list() }) else { return 0 }
        refreshCache(files)
        var removed = 0
        for file in files where file.name.hasSuffix(".json") && !file.name.hasPrefix(mine) {
            guard let data = try? blocking({ try await self.api.download(id: file.id) }),
                  (try? JSONDecoder().decode(SyncPayload.self, from: data)) == nil else { continue }
            if (try? blocking({ try await self.api.delete(id: file.id) })) != nil {
                cacheLock.lock(); idCache[file.name] = nil; cacheLock.unlock()
                removed += 1
            }
        }
        return removed
    }

    /// Remove every file belonging to `deviceID` — all payload copies and its marker.
    ///
    /// Deletes by listing rather than by cached id: the id cache holds one id per NAME, so
    /// duplicates were invisible to it and retiring a device left the extra copies behind (each
    /// still showing as its own row).
    func deletePayload(deviceID: String) throws {
        let prefix = "device-\(deviceID)"
        let files = try blocking { try await self.api.list() }
        for file in files where file.name.hasPrefix(prefix) {
            try? blocking { try await self.api.delete(id: file.id) }
            cacheLock.lock(); idCache[file.name] = nil; cacheLock.unlock()
        }
    }

    // MARK: - Helpers

    private func fetch(suffix: String, excluding deviceID: String) throws -> [Data] {
        try fetchWithTimes(suffix: suffix, excluding: deviceID).map(\.data)
    }

    /// One entry per logical file, newest kept when duplicates share a name.
    ///
    /// Duplicates are possible because Drive permits repeated names, so a single device can own
    /// several payload files. Without collapsing them the same payload is downloaded and merged
    /// once per copy, and the device shows up once per copy in the device list.
    private func fetchWithTimes(suffix: String, excluding deviceID: String) throws
        -> [(data: Data, modified: Date?)] {
        let mine = "device-\(deviceID)"
        let files = try blocking { try await self.api.list() }
        refreshCache(files)
        let mineExcluded = files.filter { $0.name.hasSuffix(suffix) && !$0.name.hasPrefix(mine) }
        return DriveAPI.newestPerName(mineExcluded).compactMap { file in
            guard let data = try? blocking({ try await self.api.download(id: file.id) })
            else { return nil }
            return (data, file.modifiedTime)
        }
    }

    // MARK: - Blobs (feedback images)

    /// Write-once. The name comes from a uid, so if it's already there the bytes are already right
    /// and re-uploading a screenshot on every sync would be pure waste.
    func putBlob(name: String, data: Data) throws {
        if try lookup(name: name) != nil { return }
        let id = try blocking { try await self.api.create(name: name, contents: data) }
        cacheLock.lock(); idCache[name] = id; cacheLock.unlock()
    }

    func fetchBlob(name: String) throws -> Data? {
        guard let id = try lookup(name: name) else { return nil }
        do {
            return try blocking { try await self.api.download(id: id) }
        } catch DriveAPI.DriveError.notFound {
            // Deleted under us — drop the stale id so a later attempt looks again rather than
            // retrying an id that can never resolve.
            cacheLock.lock(); idCache[name] = nil; cacheLock.unlock()
            return nil
        }
    }

    func deleteBlob(name: String) throws {
        guard let id = try lookup(name: name) else { return }
        try? blocking { try await self.api.delete(id: id) }
        cacheLock.lock(); idCache[name] = nil; cacheLock.unlock()
    }

    /// Create on first write, PATCH thereafter — Drive allows duplicate names, so without the id
    /// cache every publish would append another copy of the same logical file.
    private func upsert(name: String, contents: Data) throws {
        if let id = try lookup(name: name) {
            do {
                try blocking { try await self.api.update(id: id, contents: contents) }
                return
            } catch DriveAPI.DriveError.notFound {
                // ONLY a 404 means the file is genuinely gone (deleted by cleanup, another device,
                // or the Drive UI); recreating it is then correct.
                //
                // Every other failure must rethrow. Catching them all treated a transient error as
                // "file missing" and created a SECOND file — and Drive allows duplicate names, so a
                // stale token (401) or a network blip silently forked another copy every publish.
                // That is how one device ended up with a dozen payload files and appeared a dozen
                // times in the device list.
                cacheLock.lock(); idCache[name] = nil; cacheLock.unlock()
            }
        }
        let id = try blocking { try await self.api.create(name: name, contents: contents) }
        cacheLock.lock(); idCache[name] = id; cacheLock.unlock()
    }

    private func lookup(name: String) throws -> String? {
        cacheLock.lock()
        let cached = idCache[name]
        cacheLock.unlock()
        if let cached { return cached }
        let files = try blocking { try await self.api.list() }
        refreshCache(files)
        cacheLock.lock()
        let found = idCache[name]
        cacheLock.unlock()
        return found
    }

    /// Rebuild the cache from what Drive actually holds, dropping ids for files that are gone.
    /// Merging only new names would let a deleted file's id linger forever.
    private func refreshCache(_ files: [DriveAPI.RemoteFile]) {
        cacheLock.lock()
        idCache = Dictionary(files.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        cacheLock.unlock()
    }

    enum TransportError: LocalizedError {
        case mainThreadMisuse
        case timedOut

        var errorDescription: String? {
            switch self {
            case .mainThreadMisuse:
                return "Internal error: Drive sync attempted on the main thread"
            case .timedOut:
                return "Google Drive didn't respond in time"
            }
        }
    }

    /// Run an async call to completion from a synchronous context.
    ///
    /// Two guards, both learned the hard way: blocking the main thread here deadlocks the app
    /// (the awaited work needs the main actor to make progress), and an unbounded `wait()` turns
    /// any network stall into a permanent hang.
    private func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        guard !Thread.isMainThread else {
            assertionFailure("DriveSyncTransport must not be used from the main thread")
            throw TransportError.mainThreadMisuse
        }
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.value = .success(try await work()) }
            catch { box.value = .failure(error) }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 30) == .success else { throw TransportError.timedOut }
        guard let result = box.value else { throw TransportError.timedOut }
        return try result.get()
    }

    /// Small holder so the detached task doesn't capture a mutable local.
    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }
}
