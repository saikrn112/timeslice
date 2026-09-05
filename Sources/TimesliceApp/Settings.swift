import Foundation
import Combine
import TimesliceCore

/// User-configurable preferences, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Minimum unbroken session length (seconds) that counts as a "deep block" for Focus %.
    /// SYNCED: it decides what counts as focused, so two devices with different values disagree
    /// about the same recorded day.
    @Published var deepBlockMinutes: Int {
        didSet {
            defaults.set(deepBlockMinutes, forKey: Keys.deepBlockMinutes)
            publishSynced(Keys.deepBlockMinutes, String(deepBlockMinutes))
        }
    }

    /// Daily target hours (goal line on the daily-hours chart).
    /// Prompt "still working?" after a session has run this long (0 = off).
    ///
    /// SYNCED. It decides where an interval ends, so it's part of the data model rather than a local
    /// taste — one Mac left on 60 while another sat on 30 produced hour-long sessions that looked
    /// like the checkpoint was broken.
    @Published var autoPauseMinutes: Int {
        didSet {
            defaults.set(autoPauseMinutes, forKey: Keys.autoPauseMinutes)
            publishSynced(Keys.autoPauseMinutes, String(autoPauseMinutes))
        }
    }

    /// Prompt "still paused?" after the current task has sat paused this long (0 = off).
    /// Catches the opposite mistake to `autoPauseMinutes`: forgetting to *un*pause after a break.
    @Published var idleNudgeMinutes: Int {
        didSet {
            defaults.set(idleNudgeMinutes, forKey: Keys.idleNudgeMinutes)
            publishSynced(Keys.idleNudgeMinutes, String(idleNudgeMinutes))
        }
    }

    /// Master switch for every nudge — both directions. When false, nothing prompts, whatever
    /// the individual thresholds say. Sleep still pauses the timer (that protects the data);
    /// it just won't ask anything on wake.
    @Published var promptsEnabled: Bool {
        didSet {
            defaults.set(promptsEnabled, forKey: Keys.promptsEnabled)
            publishSynced(Keys.promptsEnabled, promptsEnabled ? "1" : "0")
        }
    }

    /// Hours you're awake on a typical day — the denominator for "how much of my day did I
    /// actually use".
    ///
    /// Replaced the old "daily goal", which stopped meaning anything once everything gets tracked
    /// rather than just work: 4h against an 8h work target said nothing about the other 12 hours.
    /// Per-subject commitments are Budgets' job now.
    /// SYNCED: it's the denominator of "Tracked", so 4h of a 16h day and 4h of a 12h day are
    /// different claims about the same recorded time.
    @Published var wakingHours: Double {
        didSet {
            defaults.set(wakingHours, forKey: Keys.wakingHours)
            publishSynced(Keys.wakingHours, String(wakingHours))
        }
    }

    var wakingSeconds: TimeInterval { wakingHours * 3600 }

    /// How far non-matching items fade while something is highlighted, as a percentage.
    /// 0 = no dimming at all (matches are picked out only by what tints), 90 = nearly invisible.
    /// SYNCED, though it's only cosmetic: a highlight that dims by 85% here and 40% there makes the
    /// same page read differently for no reason.
    @Published var highlightDimPercent: Int {
        didSet {
            defaults.set(highlightDimPercent, forKey: Keys.highlightDimPercent)
            publishSynced(Keys.highlightDimPercent, String(highlightDimPercent))
        }
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

    // MARK: - Sync

    /// The store, once it exists. Weak isn't needed — `AppState` owns it and outlives this — but the
    /// reference is optional because `Settings` is built before the database is opened.
    private var store: IntervalStore?
    /// Set while adopting a peer's value, so writing it back doesn't stamp a NEW timestamp on it and
    /// beat the peer's edit forever — a feedback loop that would make the two devices fight.
    private var isAdopting = false

    /// Called once the store is open. Seeds any synced key the database hasn't seen, so a first run
    /// on this build joins in with the values already configured here rather than with nothing.
    func attach(store: IntervalStore) {
        self.store = store
        for (key, value) in syncedValues() where (try? store.settingValue(key)) ?? nil == nil {
            try? store.setSetting(key, value: value)
        }
        adoptSyncedSettings()
    }

    private func syncedValues() -> [(String, String)] {
        [(Keys.autoPauseMinutes, String(autoPauseMinutes)),
         (Keys.idleNudgeMinutes, String(idleNudgeMinutes)),
         (Keys.promptsEnabled, promptsEnabled ? "1" : "0"),
         (Keys.deepBlockMinutes, String(deepBlockMinutes)),
         (Keys.wakingHours, String(wakingHours)),
         (Keys.highlightDimPercent, String(highlightDimPercent))]
    }

    private func publishSynced(_ key: String, _ value: String) {
        guard !isAdopting, let store else { return }
        try? store.setSetting(key, value: value)
    }

    /// Take on whatever the store holds — called after a merge, when a peer's newer value has landed.
    func adoptSyncedSettings() {
        guard let store else { return }
        isAdopting = true
        defer { isAdopting = false }
        if let row = (try? store.settingValue(Keys.autoPauseMinutes)) ?? nil,
           let n = Int(row.value), n != autoPauseMinutes {
            autoPauseMinutes = n
        }
        if let row = (try? store.settingValue(Keys.idleNudgeMinutes)) ?? nil,
           let n = Int(row.value), n != idleNudgeMinutes {
            idleNudgeMinutes = n
        }
        if let row = (try? store.settingValue(Keys.promptsEnabled)) ?? nil {
            let on = row.value == "1"
            if on != promptsEnabled { promptsEnabled = on }
        }
        if let row = (try? store.settingValue(Keys.deepBlockMinutes)) ?? nil,
           let n = Int(row.value), n != deepBlockMinutes {
            deepBlockMinutes = n
        }
        if let row = (try? store.settingValue(Keys.wakingHours)) ?? nil,
           let n = Double(row.value), n != wakingHours {
            wakingHours = n
        }
        if let row = (try? store.settingValue(Keys.highlightDimPercent)) ?? nil,
           let n = Int(row.value), n != highlightDimPercent {
            highlightDimPercent = n
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
