import Foundation

public enum TimeslicePaths {
    public static func defaultSupportDirectoryURL(appName: String = "Timeslice") -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
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

    /// A human-recognisable name for this machine, so "which device took over?" is answerable.
    ///
    /// `Host.current().localizedName` is often just a MAC address or DHCP-assigned string — on this
    /// developer's Macs it returns the same hex for both, which made two devices indistinguishable
    /// in the UI. So prefer the hardware model (`MacBookAir`, `MacBookPro`, `Macmini`), which is
    /// both meaningful and different for different machines, and fall back to the hostname only
    /// when it looks like a real name.
    private static func deviceNameSlug() -> String {
        let host = (Host.current().localizedName ?? "").lowercased()
        let hostSlug = slugify(host)
        // A bare hex string (MAC address) or empty name isn't useful; prefer the model.
        let looksLikeHex = !hostSlug.isEmpty
            && hostSlug.allSatisfy { $0.isHexDigit }
            && hostSlug.count >= 10
        if !hostSlug.isEmpty && !looksLikeHex { return String(hostSlug.prefix(16)) }

        if let model = hardwareModel() {
            // "Mac15,6" → "mac15-6"; "MacBookAir10,1" → "macbookair10-1"
            return String(slugify(model.lowercased()).prefix(16))
        }
        return "mac"
    }

    private static func hardwareModel() -> String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
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
