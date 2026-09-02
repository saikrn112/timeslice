import Foundation

/// Moves bytes between devices. Deliberately tiny so the merge logic stays transport-agnostic:
/// a shared folder today (Dropbox/iCloud, zero setup), the Google Drive API later (works on iOS,
/// where arbitrary filesystem access doesn't exist).
public protocol SyncTransport {
    /// Publish this device's payload.
    func put(payload: Data, deviceID: String) throws
    /// Every *other* device's payload.
    func fetchOthers(excluding deviceID: String) throws -> [Data]
    /// Publish/clear the running marker (nil = not timing here).
    func putRunning(_ marker: Data?, deviceID: String) throws
    /// Other devices' running markers.
    func fetchOtherRunning(excluding deviceID: String) throws -> [Data]
    /// Markers paired with the transport's own last-modified time, when it has one.
    ///
    /// Used to judge whether a running claim is still being refreshed. A transport-side timestamp is
    /// preferred over the marker's self-reported heartbeat because it's a single clock for all
    /// devices, whereas trusting each peer's clock inherits the skew weakness LWW already has.
    func fetchOtherRunningWithTimes(excluding deviceID: String) throws -> [(data: Data, modified: Date?)]
    /// Remove a device's payload — used to clean up self-test probes and retired devices.
    func deletePayload(deviceID: String) throws
    /// Delete payload files whose contents don't decode. They can't be addressed by device id
    /// (that lives inside the payload), so the transport removes them by name. Returns the count.
    func deleteUnreadablePayloads(excluding deviceID: String) -> Int

    /// Store an opaque blob under `name`. Used for feedback images, which are far too big to embed
    /// in a payload that's rewritten on every publish. Write-once: the name is derived from a uid,
    /// so the same name always means the same bytes.
    func putBlob(name: String, data: Data) throws
    /// Fetch a blob, or nil if the transport hasn't got it. Nil is expected, not an error: the
    /// manifest row syncs before the bytes do.
    func fetchBlob(name: String) throws -> Data?
    /// Forget a blob whose row has been deleted.
    func deleteBlob(name: String) throws
}

public extension SyncTransport {
    // Defaults so a transport that has no blob store (or a test double that doesn't care) still
    // conforms. Feedback text and tags sync as usual; only the images stay local.
    func putBlob(name: String, data: Data) throws {}
    func fetchBlob(name: String) throws -> Data? { nil }
    func deleteBlob(name: String) throws {}
}

/// A directory both devices can see — a folder inside Dropbox/iCloud Drive, or just a shared
/// volume. Each device owns exactly one payload file and one marker file, so **no two devices
/// ever write the same file** and file-level conflicts are impossible by construction.
public struct FolderSyncTransport: SyncTransport {
    private let root: URL
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func payloadURL(_ device: String) -> URL {
        root.appendingPathComponent("device-\(device).json")
    }
    private func runningURL(_ device: String) -> URL {
        root.appendingPathComponent("device-\(device).running")
    }

    public func put(payload: Data, deviceID: String) throws {
        // Write to a temp file then move: a reader can never observe a half-written payload.
        // `replaceItemAt` throws when the destination doesn't exist yet, orphaning the temp file
        // on a device's very first publish — and a stray `.json.tmp` also matched the `.json`
        // suffix filter below, so it could be read back as a payload. Write in place once the
        // file exists, and plainly the first time.
        // `Data.write(options: .atomic)` already writes to a temp file and renames it, so the
        // write a reader can observe is never partial. Doing our own temp + `replaceItemAt` on top
        // added nothing and left `.json.tmp` files behind — `replaceItemAt` doesn't reliably
        // consume the source here, and it throws outright when the destination doesn't exist yet.
        try payload.write(to: payloadURL(deviceID), options: .atomic)
    }

    public func fetchOthers(excluding deviceID: String) throws -> [Data] {
        try files(suffix: ".json", excluding: deviceID)
    }

    public func putRunning(_ marker: Data?, deviceID: String) throws {
        let url = runningURL(deviceID)
        if let marker {
            try marker.write(to: url, options: .atomic)
        } else if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    public func fetchOtherRunning(excluding deviceID: String) throws -> [Data] {
        try files(suffix: ".running", excluding: deviceID)
    }

    public func deletePayload(deviceID: String) throws {
        let url = payloadURL(deviceID)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    public func deleteUnreadablePayloads(excluding deviceID: String) -> Int {
        let mine = "device-\(deviceID)"
        var removed = 0
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasSuffix(".json")
            && !url.lastPathComponent.hasPrefix(mine) {
            guard let data = try? Data(contentsOf: url),
                  (try? JSONDecoder().decode(SyncPayload.self, from: data)) == nil else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private func files(suffix: String, excluding deviceID: String) throws -> [Data] {
        let mine = "device-\(deviceID)"
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .filter { !$0.lastPathComponent.hasSuffix(".tmp") }
            .filter { !$0.lastPathComponent.hasPrefix(mine) }
            .compactMap { try? Data(contentsOf: $0) }
    }
}

public extension SyncTransport {
    /// Default for transports with no notion of a server timestamp (e.g. a plain folder): fall back
    /// to the marker's own heartbeat by reporting no observation time.
    func fetchOtherRunningWithTimes(excluding deviceID: String) throws -> [(data: Data, modified: Date?)] {
        try fetchOtherRunning(excluding: deviceID).map { ($0, nil) }
    }
}
