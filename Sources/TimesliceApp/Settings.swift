import Foundation
import Combine
import TimesliceCore

/// User-configurable preferences, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Minimum unbroken session length (seconds) that counts as a "deep block" for Focus %.
    @Published var deepBlockMinutes: Int {
        didSet { defaults.set(deepBlockMinutes, forKey: Keys.deepBlockMinutes) }
    }

    /// Daily target hours (goal line on the daily-hours chart).
    /// Prompt "still working?" after a session has run this long (0 = off).
    @Published var autoPauseMinutes: Int {
        didSet { defaults.set(autoPauseMinutes, forKey: Keys.autoPauseMinutes) }
    }

    /// Prompt "still paused?" after the current task has sat paused this long (0 = off).
    /// Catches the opposite mistake to `autoPauseMinutes`: forgetting to *un*pause after a break.
    @Published var idleNudgeMinutes: Int {
        didSet { defaults.set(idleNudgeMinutes, forKey: Keys.idleNudgeMinutes) }
    }

    /// Master switch for every nudge — both directions. When false, nothing prompts, whatever
    /// the individual thresholds say. Sleep still pauses the timer (that protects the data);
    /// it just won't ask anything on wake.
    @Published var promptsEnabled: Bool {
        didSet { defaults.set(promptsEnabled, forKey: Keys.promptsEnabled) }
    }

    /// Hours you're awake on a typical day — the denominator for "how much of my day did I
    /// actually use".
    ///
    /// Replaced the old "daily goal", which stopped meaning anything once everything gets tracked
    /// rather than just work: 4h against an 8h work target said nothing about the other 12 hours.
    /// Per-subject commitments are Budgets' job now.
    @Published var wakingHours: Double {
        didSet { defaults.set(wakingHours, forKey: Keys.wakingHours) }
    }

    var wakingSeconds: TimeInterval { wakingHours * 3600 }

    /// How far non-matching items fade while something is highlighted, as a percentage.
    /// 0 = no dimming at all (matches are picked out only by what tints), 90 = nearly invisible.
    @Published var highlightDimPercent: Int {
        didSet { defaults.set(highlightDimPercent, forKey: Keys.highlightDimPercent) }
    }

    /// Opacity to draw non-matching items at.
    var highlightDimOpacity: Double { 1 - Double(highlightDimPercent) / 100 }

    /// Sync is OFF unless a folder is chosen — the app stays local-first, no account, no network,
    /// for anyone who doesn't opt in. A folder inside Dropbox/iCloud Drive is all it takes.
    @Published var syncFolderPath: String {
        didSet { defaults.set(syncFolderPath, forKey: Keys.syncFolderPath) }
    }

    /// Sync backend. Google Drive is the primary one — it needs no third-party app installed and
    /// is the only option that can reach an iPhone.
    enum SyncMode: String {
        case off, googleDrive, folder
    }

    @Published var syncMode: SyncMode {
        didSet { defaults.set(syncMode.rawValue, forKey: Keys.syncMode) }
    }

    /// What this device calls itself in the device list. Empty = derive from the machine.
    @Published var deviceLabel: String {
        didSet { defaults.set(deviceLabel, forKey: Keys.deviceLabel) }
    }

    var syncEnabled: Bool { syncMode != .off }

    var syncFolderURL: URL? {
        guard syncEnabled else { return nil }
        return URL(fileURLWithPath: (syncFolderPath as NSString).expandingTildeInPath)
    }

    var deepBlockSeconds: TimeInterval { TimeInterval(deepBlockMinutes * 60) }

    /// The nudge thresholds as the (unit-tested) policy type in TimesliceCore.
    var nudgeConfig: NudgePolicy.Config {
        .init(promptsEnabled: promptsEnabled,
              sessionMinutes: autoPauseMinutes,
              pausedMinutes: idleNudgeMinutes)
    }

    var autoPauseEnabled: Bool { nudgeConfig.sessionNudgeEnabled }
    var autoPauseSeconds: TimeInterval { nudgeConfig.sessionSeconds }
    var idleNudgeEnabled: Bool { nudgeConfig.pausedNudgeEnabled }
    var idleNudgeSeconds: TimeInterval { nudgeConfig.pausedSeconds }

    init() {
        deepBlockMinutes = defaults.object(forKey: Keys.deepBlockMinutes) as? Int ?? 25
        autoPauseMinutes = defaults.object(forKey: Keys.autoPauseMinutes) as? Int ?? 60
        idleNudgeMinutes = defaults.object(forKey: Keys.idleNudgeMinutes) as? Int ?? 15
        promptsEnabled = defaults.object(forKey: Keys.promptsEnabled) as? Bool ?? true
        wakingHours = defaults.object(forKey: Keys.wakingHours) as? Double ?? 16
        highlightDimPercent = defaults.object(forKey: Keys.highlightDimPercent) as? Int ?? 85
        // A sandbox run can point both instances at one folder without touching real settings.
        deviceLabel = defaults.string(forKey: Keys.deviceLabel) ?? ""
        syncFolderPath = ProcessInfo.processInfo.environment["TIMESLICE_SYNC_FOLDER"]
            ?? defaults.string(forKey: Keys.syncFolderPath) ?? ""
        // A sandbox run forces folder mode so two local instances can pair without OAuth.
        if ProcessInfo.processInfo.environment["TIMESLICE_SYNC_DRIVE"] == "1" {
            syncMode = .googleDrive
        } else if ProcessInfo.processInfo.environment["TIMESLICE_SYNC_FOLDER"] != nil {
            syncMode = .folder
        } else {
            syncMode = SyncMode(rawValue: defaults.string(forKey: Keys.syncMode) ?? "") ?? .off
        }
    }

    private enum Keys {
        static let deepBlockMinutes = "deepBlockMinutes"
        static let autoPauseMinutes = "autoPauseMinutes"
        static let idleNudgeMinutes = "idleNudgeMinutes"
        static let promptsEnabled = "promptsEnabled"
        static let wakingHours = "wakingHours"
        static let highlightDimPercent = "highlightDimPercent"
        static let syncFolderPath = "syncFolderPath"
        static let syncMode = "syncMode"
        static let deviceLabel = "deviceLabel"
    }
}
