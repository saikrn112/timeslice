import Foundation
import Combine

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

    var deepBlockSeconds: TimeInterval { TimeInterval(deepBlockMinutes * 60) }
    var dailyGoalSeconds: TimeInterval { dailyGoalHours * 3600 }
    var autoPauseEnabled: Bool { autoPauseMinutes > 0 }
    var autoPauseSeconds: TimeInterval { TimeInterval(autoPauseMinutes * 60) }

    init() {
        deepBlockMinutes = defaults.object(forKey: Keys.deepBlockMinutes) as? Int ?? 25
        dailyGoalHours = defaults.object(forKey: Keys.dailyGoalHours) as? Double ?? 10
        autoPauseMinutes = defaults.object(forKey: Keys.autoPauseMinutes) as? Int ?? 60
    }

    private enum Keys {
        static let deepBlockMinutes = "deepBlockMinutes"
        static let dailyGoalHours = "dailyGoalHours"
        static let autoPauseMinutes = "autoPauseMinutes"
    }
}
