import Foundation

public enum TimeslicePaths {
    /// Asking the system for Application Support rather than building it from the home directory:
    /// `homeDirectoryForCurrentUser` is a Mac-shaped assumption, and on iOS the equivalent lives
    /// inside the app's sandbox container. The search-path API returns the right answer on both, and
    /// on an unsandboxed Mac it resolves to exactly `~/Library/Application Support`, so existing
    /// databases are found unchanged.
    public static func defaultSupportDirectoryURL(appName: String = "Timeslice") -> URL {
        // The fallback uses `NSHomeDirectory()`, not `homeDirectoryForCurrentUser`: the latter is
        // marked *unavailable* on iOS, so it fails to compile even sitting in a branch that can
        // never run there. `NSHomeDirectory()` exists on both and means the right thing on both —
        // the user's home on an unsandboxed Mac, the container root on iOS.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public static func defaultDatabaseURL(appName: String = "Timeslice") -> URL {
        // TIMESLICE_DB_PATH lets a second instance run against its own database on the SAME Mac,
        // which is the only practical way to test multi-device sync without a second machine.
        if let override = ProcessInfo.processInfo.environment["TIMESLICE_DB_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return defaultSupportDirectoryURL(appName: appName).appendingPathComponent("timeslice.db")
    }

    /// A stable identity for this device+install, minted once and kept next to the database.
    ///
    /// Deliberately NOT synced: restoring another device's id would make two devices claim the
    /// same identity, so each would ignore the other's files.
    public static func deviceID(databaseURL: URL = defaultDatabaseURL()) -> String {
        let file = databaseURL.deletingLastPathComponent().appendingPathComponent("device-id")
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let id = "\(deviceNameSlug())-\(UUID().uuidString.prefix(4).lowercased())"
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    /// A human-recognisable name for this device, so "which device took over?" is answerable.
    ///
    /// The hostname is often just a MAC address or DHCP-assigned string — on this developer's Macs
    /// it returns the same hex for both, which made two devices indistinguishable in the UI. So
    /// prefer the hardware model (`MacBookAir`, `MacBookPro`, `Macmini`, `iPhone`), which is both
    /// meaningful and different for different devices, and fall back to the hostname only when it
    /// looks like a real name.
    ///
    /// `ProcessInfo.hostName` rather than `Host.current().localizedName`: `Host` does not exist on
    /// iOS. This only affects *newly minted* ids — an existing device reads its persisted
    /// `device-id` file, so no device changes identity (which would fork its sync history).
    private static func deviceNameSlug() -> String {
        var host = ProcessInfo.processInfo.hostName.lowercased()
        // Bonjour hands back "somename.local"; the suffix is noise in a device label.
        if host.hasSuffix(".local") { host = String(host.dropLast(6)) }
        let hostSlug = slugify(host)
        // A bare hex string (MAC address) or empty name isn't useful; prefer the model.
        let looksLikeHex = !hostSlug.isEmpty
            && hostSlug.allSatisfy { $0.isHexDigit }
            && hostSlug.count >= 10
        if !hostSlug.isEmpty && !looksLikeHex { return String(hostSlug.prefix(16)) }

        if let model = hardwareModel() {
            // "Mac15,6" → "mac15-6"; "MacBookAir10,1" → "macbookair10-1"; "iPhone16,2" → "iphone16-2"
            return String(slugify(model.lowercased()).prefix(16))
        }
        return "device"
    }

    /// The model identifier, e.g. `MacBookAir10,1` or `iPhone16,2`.
    ///
    /// The sysctl key differs by platform and is genuinely counterintuitive: macOS puts the model in
    /// `hw.model` (`hw.machine` is just `arm64`), whereas on iOS `hw.model` is the internal board id
    /// (`D84AP`) and the model lives in `hw.machine`. Reading the wrong one yields a label no human
    /// recognises.
    private static func hardwareModel() -> String? {
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &chars, &size, nil, 0)
        let value = String(cString: chars)
        return value.isEmpty ? nil : value
    }

    private static func slugify(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: ",", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

public enum TimesliceNotifications {
    /// Posted (in-process) whenever intervals or projects change, so open windows/popovers refresh.
    public static let dataDidChange = Notification.Name("com.timeslice.dataDidChange")
}
