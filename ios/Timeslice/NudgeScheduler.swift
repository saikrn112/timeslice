import Foundation
import TimesliceCore
import UserNotifications

/// The phone's version of the Mac's two nudges, delivered as **local notifications** rather than
/// in-process timers.
///
/// The Mac can run a `Timer` because it's always awake. A phone suspends, so a scheduled
/// `UNTimeIntervalNotificationTrigger` is the only mechanism that survives — the system holds the
/// timer, not us. Which nudge to arm, and when, still comes from `NudgePolicy` in Core, so the two
/// platforms make the same decision and only the delivery differs.
///
/// Two nudges, in opposite directions:
///  • **still working?** — a session has run past the threshold; you probably forgot to pause.
///  • **still paused?** — a task has sat paused; real work is going unrecorded.
///
/// Notification *actions* are attached so answering needs no app launch: "Still on it" dismisses,
/// "Pause" stops the timer from the banner.
///
/// **Deliberately NOT ported: pausing on screen-off.** The Mac pauses when the display sleeps after a
/// grace period, because a dark Mac means nobody's there. A phone's screen goes off constantly while
/// you keep working, so that rule would shred every session. The long-session nudge is the phone's
/// equivalent safeguard.
@MainActor
final class NudgeScheduler: NSObject {
    static let shared = NudgeScheduler()

    /// Same defaults the Mac ships (60 minutes running, 15 minutes paused, prompts on). The phone has
    /// no settings screen yet; stated here rather than buried so the divergence is visible if the Mac's
    /// defaults ever change.
    private var config = NudgePolicy.Config(promptsEnabled: true, sessionMinutes: 60,
                                            pausedMinutes: 15)

    private enum ID {
        static let session = "timeslice.nudge.session"
        static let paused = "timeslice.nudge.paused"
        static let category = "timeslice.nudge"
    }

    private enum Action {
        static let stillOnIt = "timeslice.action.stillOnIt"
        static let pause = "timeslice.action.pause"
        static let resume = "timeslice.action.resume"
    }

    private let center = UNUserNotificationCenter.current()

    /// Registers the delegate and the actionable category. Does **not** prompt.
    ///
    /// Splitting registration from authorization matters: prompting at launch, before the user has
    /// started a single timer, asks for something they have no context for — and it was verified to
    /// put a modal over the UI on first run. Permission is requested from `rearm` instead, the first
    /// time a nudge is actually armed, which is still long before one could fire.
    func start() {
        center.delegate = self
        let category = UNNotificationCategory(
            identifier: ID.category,
            actions: [
                UNNotificationAction(identifier: Action.stillOnIt, title: "Still on it",
                                     options: []),
                UNNotificationAction(identifier: Action.pause, title: "Pause",
                                     options: [.destructive]),
                UNNotificationAction(identifier: Action.resume, title: "Resume", options: []),
            ],
            intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    private var hasRequestedAuthorization = false

    /// Ask once, the first time a nudge is armed.
    ///
    /// Requests are still scheduled whether or not permission is granted — a denied app keeps its
    /// pending list, it just doesn't display. So this never gates the scheduling path.
    private func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("[timeslice] notification authorization failed: \(error.localizedDescription)")
            } else {
                NSLog("[timeslice] notification authorization granted=\(granted)")
            }
        }
    }

    /// Re-arm from the current timer state. Safe to call after every mutation — it cancels first, so
    /// a switch can't leave a nudge armed against the task you left.
    func rearm(runningSince: Date?, pausedSince: Date?, taskName: String?) {
        center.removePendingNotificationRequests(withIdentifiers: [ID.session, ID.paused])

        let isRunning = runningSince != nil
        // `awaitingAnswer` is always false here: on the Mac it stops the paused nudge stacking on an
        // unanswered "still working?" prompt, but a notification has no unanswered state — it either
        // sits in Notification Centre or it's been actioned, and the two nudges are already mutually
        // exclusive because one needs a running timer and the other a paused one.
        let isPaused = !isRunning && pausedSince != nil

        if NudgePolicy.armsSessionNudge(config, isRunning: isRunning), let since = runningSince {
            requestAuthorizationIfNeeded()
            schedule(id: ID.session,
                     title: "Still working on \(taskName ?? "this")?",
                     body: "The timer has been running a while. Pause it if you've moved on.",
                     after: NudgePolicy.delay(since: since, threshold: config.sessionSeconds))
        }

        if NudgePolicy.armsPausedNudge(config, isPaused: isPaused, awaitingAnswer: false),
           let since = pausedSince {
            requestAuthorizationIfNeeded()
            schedule(id: ID.paused,
                     title: "\(taskName ?? "Timeslice") is still paused",
                     body: "Resume it if you're working — time isn't being recorded.",
                     after: NudgePolicy.delay(since: since, threshold: config.pausedSeconds))
        }
    }

    func cancelAll() {
        center.removePendingNotificationRequests(withIdentifiers: [ID.session, ID.paused])
    }

    private func schedule(id: String, title: String, body: String, after delay: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = ID.category
        content.sound = .default
        // `delay` is clamped to >= 1 by NudgePolicy, which matters: a trigger of 0 throws.
        let request = UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        center.add(request) { error in
            if let error {
                NSLog("[timeslice] scheduling \(id) failed: \(error.localizedDescription)")
            } else {
                NSLog("[timeslice] scheduled \(id) in \(Int(delay))s")
            }
        }
    }

    /// Logs what's actually armed. Exists because notification *delivery* can't be verified headlessly
    /// — `simctl privacy` has no notifications service, so permission can't be granted without a human
    /// tapping Allow. The pending list can be checked regardless of authorization, which at least
    /// proves the scheduling half.
    func logPending() {
        center.getPendingNotificationRequests { requests in
            let described = requests.map { r -> String in
                let secs = (r.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval ?? -1
                return "\(r.identifier)@\(Int(secs))s"
            }
            NSLog("[timeslice] pending nudges: \(described.isEmpty ? "none" : described.joined(separator: ", "))")
        }
    }
}

extension NudgeScheduler: UNUserNotificationCenterDelegate {
    /// Show the banner even in the foreground: the whole point is a checkpoint you might be ignoring,
    /// and suppressing it while the app happens to be open would hide it exactly when you're at the
    /// device.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let model = TimerModel.shared
        model.load()
        switch response.actionIdentifier {
        case Action.pause:
            if let id = model.running?.projectID { model.toggle(taskID: id) }
        case Action.resume:
            if let id = model.currentTaskID, !model.isRunning { model.toggle(taskID: id) }
        case Action.stillOnIt:
            // Answering "yes" re-arms the same nudge, so a long session keeps checking in rather
            // than going quiet after one dismissal.
            model.rearmNudges()
        default:
            break
        }
    }
}
