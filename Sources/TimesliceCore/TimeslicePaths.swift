import Foundation

public enum TimeslicePaths {
    public static func defaultSupportDirectoryURL(appName: String = "Timeslice") -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static func defaultDatabaseURL(appName: String = "Timeslice") -> URL {
        defaultSupportDirectoryURL(appName: appName).appendingPathComponent("timeslice.db")
    }
}

public enum TimesliceNotifications {
    /// Posted (in-process) whenever intervals or projects change, so open windows/popovers refresh.
    public static let dataDidChange = Notification.Name("com.timeslice.dataDidChange")
}
