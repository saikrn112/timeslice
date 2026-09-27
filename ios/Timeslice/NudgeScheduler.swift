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
/// Two nudges, in opposite directions, plus the break reminder:
///  • **still working?** — a session has run past the threshold; you probably forgot to pause.
///  • **still paused?** — a task has sat paused; real work is going unrecorded.
///  • **break** — work has accumulated across tasks without a rest. The phone deliberately has no
///    "still working?" nudge (see `rearm`), so this is its only poke about the LENGTH of a stretch —
///    and the one that matters on a phone, where nothing is being over-recorded, you are just not
///    stopping.
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

    /// Read from the SHARED `AppSettings` rather than a local copy, so the Settings screen actually
    /// governs these and the phone can't drift from the Mac's thresholds. This was hardcoded to
    /// 60/15 before Settings existed on iOS.
    private var config: NudgePolicy.Config { TimerModel.shared.settings.nudgeConfig }

    private enum ID {
        static let session = "timeslice.nudge.session"
        static let paused = "timeslice.nudge.paused"
        static let brk = "timeslice.nudge.break"
        static let category = "timeslice.nudge"
        static let breakCategory = "timeslice.nudge.breakcat"
    }

    private enum Action {
        static let stillOnIt = "timeslice.action.stillOnIt"
        static let pause = "timeslice.action.pause"
        static let resume = "timeslice.action.resume"
        static let takeBreak = "timeslice.action.takeBreak"
        static let keepGoing = "timeslice.action.keepGoing"
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
        // Its own category: the break banner offers "Take a break" and "Keep going", and reusing the
        // other one would put Resume on a notification about a timer that is running.
        let breakCategory = UNNotificationCategory(
            identifier: ID.breakCategory,
            actions: [
                UNNotificationAction(identifier: Action.takeBreak, title: "Take a break", options: []),
                UNNotificationAction(identifier: Action.keepGoing, title: "Keep going", options: []),
            ],
            intentIdentifiers: [])
        center.setNotificationCategories([category, breakCategory])
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
    func rearm(runningSince: Date?, pausedSince: Date?, taskName: String?,
               workedSinceBreak: TimeInterval = 0) {
        center.removePendingNotificationRequests(withIdentifiers: [ID.session, ID.paused, ID.brk])

        let isRunning = runningSince != nil
        // `awaitingAnswer` is always false here: on the Mac it stops the paused nudge stacking on an
        // unanswered "still working?" prompt, but a notification has no unanswered state — it either
        // sits in Notification Centre or it's been actioned, and the two nudges are already mutually
        // exclusive because one needs a running timer and the other a paused one.
        let isPaused = !isRunning && pausedSince != nil

        // NO session nudge on the phone, deliberately.
        //
        // It asked "still working?" and paused if unanswered, which is exactly wrong in the case that
        // matters most: you can't answer a prompt while driving, and an unanswered one discarded real
        // time. `IntervalStore.rollOpenInterval` splits the run into focus-length blocks instead —
        // nothing is interrupted, nothing is lost, and an over-record is two swipes to trim in the
        // sessions list. Over-recording you can correct beats under-recording you can't.
        //
        // The PAUSED nudge below stays: forgetting to un-pause is still worth a poke, and unlike the
        // other one it's answerable whenever you next look at the phone.
        //
        // `runningSince` therefore goes unused here; it stays in the signature because the Mac's
        // `NudgePolicy` is shared and still arms both.
        _ = runningSince

        // Scheduled off work ALREADY done, so the banner lands when the accumulated stretch reaches the
        // threshold rather than a full interval later. A phone suspends, so the system has to hold the
        // timer — which means the delay is computed once here and not re-derived as you work; switching
        // tasks calls `rearm` again, which is what keeps it honest.
        let breakConfig = TimerModel.shared.settings.breakConfig
        if breakConfig.enabled, isRunning {
            requestAuthorizationIfNeeded()
            let rest = breakConfig.restMinutes
            schedule(id: ID.brk,
                     // The THRESHOLD, not the count so far: this banner is written now and delivered
                     // when the count reaches it, so "15m without a break" would arrive 30 minutes in.
                     title: "\(breakConfig.everyMinutes)m without a break",
                     body: "Pause for \(rest)m, or keep going?",
                     after: BreakPolicy.delay(breakConfig, workedSeconds: workedSinceBreak),
                     category: ID.breakCategory)
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
        center.removePendingNotificationRequests(withIdentifiers: [ID.session, ID.paused, ID.brk])
    }

    private func schedule(id: String, title: String, body: String, after delay: TimeInterval,
                          category: String = ID.category) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
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
        case Action.takeBreak:
            if let id = model.running?.projectID { model.toggle(taskID: id) }
        case Action.keepGoing:
            // Re-arms from the work done since, so declining buys the snooze rather than silence.
            model.rearmNudges()
        case Action.stillOnIt:
            // Answering "yes" re-arms the same nudge, so a long session keeps checking in rather
            // than going quiet after one dismissal.
            model.rearmNudges()
        default:
            break
        }
    }
}
