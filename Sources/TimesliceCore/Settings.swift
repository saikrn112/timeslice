import Foundation
import Combine

/// Today vs All Time — the scope both the Mac's task list and the phone's toggle between.
///
/// In Core because both front-ends need it; it lived in the Mac's `AppState`, which the phone can't
/// reach.
public enum TimeScope: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case allTime = "All Time"
    public var id: String { rawValue }
}

/// User-configurable preferences, persisted in UserDefaults.
///
/// Named `AppSettings`, not `Settings`: SwiftUI already exports a `Settings` scene type, and once this
/// moved out of the app module into Core the bare name became ambiguous at every use site.
///
/// In Core rather than the Mac app target so the phone reads the SAME keys, defaults and
/// `nudgeConfig`. The iOS build previously hardcoded its own copies of the deep-block and nudge
/// thresholds, which meant Focus % and the nudge timings could silently disagree between devices.
@MainActor
public final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Minimum unbroken session length (seconds) that counts as a "deep block" for Focus %.
    @Published public var deepBlockMinutes: Int {
        didSet { defaults.set(deepBlockMinutes, forKey: Keys.deepBlockMinutes) }
    }

    /// Daily target hours (goal line on the daily-hours chart).
    /// Prompt "still working?" after a session has run this long (0 = off).
    @Published public var autoPauseMinutes: Int {
        didSet { defaults.set(autoPauseMinutes, forKey: Keys.autoPauseMinutes) }
    }

    /// Prompt "still paused?" after the current task has sat paused this long (0 = off).
    /// Catches the opposite mistake to `autoPauseMinutes`: forgetting to *un*pause after a break.
    @Published public var idleNudgeMinutes: Int {
        didSet { defaults.set(idleNudgeMinutes, forKey: Keys.idleNudgeMinutes) }
    }

    /// Master switch for every nudge — both directions. When false, nothing prompts, whatever
    /// the individual thresholds say. Sleep still pauses the timer (that protects the data);
    /// it just won't ask anything on wake.
    @Published public var promptsEnabled: Bool {
        didSet { defaults.set(promptsEnabled, forKey: Keys.promptsEnabled) }
    }

    /// Hours you're awake on a typical day — the denominator for "how much of my day did I
    /// actually use".
    ///
    /// Replaced the old "daily goal", which stopped meaning anything once everything gets tracked
    /// rather than just work: 4h against an 8h work target said nothing about the other 12 hours.
    /// Per-subject commitments are Budgets' job now.
    @Published public var wakingHours: Double {
        didSet { defaults.set(wakingHours, forKey: Keys.wakingHours) }
    }

    public var wakingSeconds: TimeInterval { wakingHours * 3600 }

    /// How far non-matching items fade while something is highlighted, as a percentage.
    /// 0 = no dimming at all (matches are picked out only by what tints), 90 = nearly invisible.
    @Published public var highlightDimPercent: Int {
        didSet { defaults.set(highlightDimPercent, forKey: Keys.highlightDimPercent) }
    }

    /// Opacity to draw non-matching items at.
    public var highlightDimOpacity: Double { 1 - Double(highlightDimPercent) / 100 }

    /// Sync is OFF unless a folder is chosen — the app stays local-first, no account, no network,
    /// for anyone who doesn't opt in. A folder inside Dropbox/iCloud Drive is all it takes.
    @Published public var syncFolderPath: String {
        didSet { defaults.set(syncFolderPath, forKey: Keys.syncFolderPath) }
    }

    /// Sync backend. Google Drive is the primary one — it needs no third-party app installed and
    /// is the only option that can reach an iPhone.
    public enum SyncMode: String {
        case off, googleDrive, folder
    }

    @Published public var syncMode: SyncMode {
        didSet { defaults.set(syncMode.rawValue, forKey: Keys.syncMode) }
    }

    /// What this device calls itself in the device list. Empty = derive from the machine.
    @Published public var deviceLabel: String {
        didSet { defaults.set(deviceLabel, forKey: Keys.deviceLabel) }
    }

    public var syncEnabled: Bool { syncMode != .off }

    public var syncFolderURL: URL? {
        guard syncEnabled else { return nil }
        return URL(fileURLWithPath: (syncFolderPath as NSString).expandingTildeInPath)
    }

    public var deepBlockSeconds: TimeInterval { TimeInterval(deepBlockMinutes * 60) }

    /// The nudge thresholds as the (unit-tested) policy type in TimesliceCore.
    public var nudgeConfig: NudgePolicy.Config {
        .init(promptsEnabled: promptsEnabled,
              sessionMinutes: autoPauseMinutes,
              pausedMinutes: idleNudgeMinutes)
    }

    public var autoPauseEnabled: Bool { nudgeConfig.sessionNudgeEnabled }
    public var autoPauseSeconds: TimeInterval { nudgeConfig.sessionSeconds }
    public var idleNudgeEnabled: Bool { nudgeConfig.pausedNudgeEnabled }
    public var idleNudgeSeconds: TimeInterval { nudgeConfig.pausedSeconds }

    public init() {
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
