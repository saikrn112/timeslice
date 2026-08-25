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

    func deletePayload(deviceID: String) throws {
        let name = payloadName(deviceID)
        guard let id = try lookup(name: name) else { return }
        try blocking { try await self.api.delete(id: id) }
        cacheLock.lock(); idCache[name] = nil; cacheLock.unlock()
    }

    // MARK: - Helpers

    private func fetch(suffix: String, excluding deviceID: String) throws -> [Data] {
        let mine = "device-\(deviceID)"
        let files = try blocking { try await self.api.list() }
        refreshCache(files)
        return try files
            .filter { $0.name.hasSuffix(suffix) && !$0.name.hasPrefix(mine) }
            .compactMap { file in
                try? blocking { try await self.api.download(id: file.id) }
            }
    }

    /// Create on first write, PATCH thereafter — Drive allows duplicate names, so without the id
    /// cache every publish would append another copy of the same logical file.
    private func upsert(name: String, contents: Data) throws {
        if let id = try lookup(name: name) {
            do {
                try blocking { try await self.api.update(id: id, contents: contents) }
                return
            } catch {
                // The cached id can outlive the file — deleting it elsewhere (cleanup, another
                // device, the Drive UI) leaves us PATCHing something gone, which Drive answers
                // with 404. Forget the id and fall through to creating it again.
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
