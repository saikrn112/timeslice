import Foundation

/// Whether a nudge should be armed, kept as pure logic so it's testable without any UI.
///
/// Two nudges, in opposite directions:
///  • **still working?** — a session has run a long time; you probably forgot to pause.
///  • **still paused?**  — a task has sat paused a long time; you probably forgot to resume,
///    so real work is going unrecorded.
///
/// They are mutually exclusive by construction: the first needs a *running* timer, the second a
/// *paused* one. The `awaitingAnswer` flag additionally stops the second from stacking on the
/// first — the "still working?" checkpoint pauses the timer itself, which would otherwise look
/// exactly like a task you'd left paused.
public enum NudgePolicy {

    public struct Config: Sendable {
        /// Master switch: false silences both nudges regardless of the thresholds.
        public let promptsEnabled: Bool
        /// Minutes before the "still working?" checkpoint (0 = that nudge off).
        public let sessionMinutes: Int
        /// Minutes before the "still paused?" nudge (0 = that nudge off).
        public let pausedMinutes: Int

        public init(promptsEnabled: Bool, sessionMinutes: Int, pausedMinutes: Int) {
            self.promptsEnabled = promptsEnabled
            self.sessionMinutes = sessionMinutes
            self.pausedMinutes = pausedMinutes
        }

        public var sessionNudgeEnabled: Bool { promptsEnabled && sessionMinutes > 0 }
        public var pausedNudgeEnabled: Bool { promptsEnabled && pausedMinutes > 0 }
        public var sessionSeconds: TimeInterval { TimeInterval(sessionMinutes * 60) }
        public var pausedSeconds: TimeInterval { TimeInterval(pausedMinutes * 60) }
    }

    /// Arm the long-session checkpoint? Requires an actively running timer.
    public static func armsSessionNudge(_ c: Config, isRunning: Bool) -> Bool {
        c.sessionNudgeEnabled && isRunning
    }

    /// Arm the paused-too-long nudge? Requires a paused task and no unanswered prompt.
    public static func armsPausedNudge(_ c: Config, isPaused: Bool, awaitingAnswer: Bool) -> Bool {
        !awaitingAnswer && c.pausedNudgeEnabled && isPaused
    }

    /// Seconds until a nudge should fire for something that started at `since`, never negative
    /// (a threshold already passed fires on the next tick rather than never).
    public static func delay(since: Date, threshold: TimeInterval, now: Date = Date()) -> TimeInterval {
        max(1, since.addingTimeInterval(threshold).timeIntervalSince(now))
    }
}
