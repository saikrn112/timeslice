import Foundation

/// When to suggest a break, kept as pure logic so it's testable without any UI.
///
/// The third counter, and the only one that ignores which task you were on: 5m on A + 10m on B + 10m on
/// A + 5m on C is half an hour at the desk, and neither existing nudge can see it. `NudgePolicy` asks
/// about one interval ("this session has run long", "this pause has lasted long"); this asks about the
/// accumulated stretch.
///
/// **A rest, not a pause.** The counter bridges gaps up to `restMinutes` rather than the micro-pause
/// tolerance, so two minutes fetching water doesn't wipe out thirty minutes of accrued work, while a
/// genuine ten-minute break does. That is what makes `restMinutes` mean something: it is the length a
/// break has to be to count as one.
public enum BreakPolicy {

    public struct Config: Sendable {
        /// Master switch, shared with the other nudges: false silences this too.
        public let promptsEnabled: Bool
        /// Minutes of accumulated work before suggesting a break (0 = off).
        public let everyMinutes: Int
        /// How long you have to be away for it to count as a rest.
        public let restMinutes: Int

        public init(promptsEnabled: Bool, everyMinutes: Int, restMinutes: Int) {
            self.promptsEnabled = promptsEnabled
            self.everyMinutes = everyMinutes
            self.restMinutes = restMinutes
        }

        public var enabled: Bool { promptsEnabled && everyMinutes > 0 }
        public var everySeconds: TimeInterval { TimeInterval(everyMinutes * 60) }
        public var restSeconds: TimeInterval { TimeInterval(max(1, restMinutes) * 60) }

        /// After a decline, how much MORE work before asking again.
        ///
        /// Half the interval rather than the whole one: at the default 30 minutes this database implies
        /// about thirteen prompts on a median day, so "not now" has to buy real quiet — but declining
        /// shouldn't switch the reminder off for the rest of a long stretch either.
        public var snoozeSeconds: TimeInterval { everySeconds / 2 }
    }

    /// Should the break prompt appear right now?
    ///
    /// `workedSeconds` comes from `WorkRuns.workedSeconds(…, gap: restSeconds, perTask: false, since:)`
    /// where `since` is the later of the last answer and the last snooze. Passing it in rather than
    /// reading a store keeps this pure and keeps the floor decision in one place.
    ///
    /// `offUntil` is the "not today" answer: a date (usually tomorrow's start) before which nothing
    /// fires. Silencing for a day is not the same as turning the feature off, and conflating them meant
    /// the only way to stop it for an afternoon was a setting you then had to remember to undo.
    public static func fires(_ c: Config, workedSeconds: TimeInterval, isRunning: Bool,
                             awaitingOtherPrompt: Bool, promptShowing: Bool,
                             offUntil: Date?, now: Date = Date()) -> Bool {
        guard c.enabled, isRunning, !promptShowing else { return false }
        // Never stack on the checkpoint. That one has already paused the timer and is waiting for an
        // answer; two panels about the same moment is worse than one arriving a minute later.
        guard !awaitingOtherPrompt else { return false }
        if let offUntil, now < offUntil { return false }
        return workedSeconds >= c.everySeconds
    }

    /// Seconds until the prompt is due, given work already done. Never below 1 — a threshold already
    /// passed fires on the next tick rather than never, the same rule as `NudgePolicy.delay`.
    public static func delay(_ c: Config, workedSeconds: TimeInterval) -> TimeInterval {
        max(1, c.everySeconds - workedSeconds)
    }
}
