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
    @Published var dailyGoalHours: Double {
        didSet { defaults.set(dailyGoalHours, forKey: Keys.dailyGoalHours) }
    }

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

    var deepBlockSeconds: TimeInterval { TimeInterval(deepBlockMinutes * 60) }
    var dailyGoalSeconds: TimeInterval { dailyGoalHours * 3600 }

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
        dailyGoalHours = defaults.object(forKey: Keys.dailyGoalHours) as? Double ?? 10
        autoPauseMinutes = defaults.object(forKey: Keys.autoPauseMinutes) as? Int ?? 60
        idleNudgeMinutes = defaults.object(forKey: Keys.idleNudgeMinutes) as? Int ?? 15
        promptsEnabled = defaults.object(forKey: Keys.promptsEnabled) as? Bool ?? true
    }

    private enum Keys {
        static let deepBlockMinutes = "deepBlockMinutes"
        static let dailyGoalHours = "dailyGoalHours"
        static let autoPauseMinutes = "autoPauseMinutes"
        static let idleNudgeMinutes = "idleNudgeMinutes"
        static let promptsEnabled = "promptsEnabled"
    }
}
