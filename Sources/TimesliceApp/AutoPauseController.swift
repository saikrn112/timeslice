import AppKit
import Combine
import TimesliceCore

/// Keeps the running timer honest against two "you're not actually working" cases:
///
///  • **Sleep/wake** — when the machine sleeps, pause the running timer back-dated to the moment
///    of sleep (so an overnight sleep counts nothing). On wake, if we paused for that reason,
///    offer to resume the same task.
///
///  • **Long session** — after a session runs for `settings.autoPauseMinutes`, prompt
///    "still working on X?". If you don't answer within a grace window, auto-pause back-dated to
///    when the prompt appeared (so a walked-away session isn't inflated). Answering "keep going"
///    resets the checkpoint and loses nothing.
@MainActor
final class AutoPauseController: ObservableObject {
    /// True while a "still working?" prompt is pending — the menu bar highlights the timer orange.
    @Published private(set) var awaitingResponse = false

    private let engine: TimerEngine
    private let appState: AppState
    private let settings: Settings

    /// Debug override for quick testing: set env `TIMESLICE_AUTOPAUSE_SECONDS=10` to make the
    /// checkpoint fire after 10s (and shrink the grace window to match). Ignored when unset.
    private static let debugSeconds: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment["TIMESLICE_AUTOPAUSE_SECONDS"],
              let v = Double(raw), v > 0 else { return nil }
        return v
    }()

    private var checkpointTimer: Timer?
    /// Repeating sweep that re-checks the thresholds from scratch.
    private var backstopTimer: Timer?
    private var nagTimer: Timer?
    /// The task to offer resuming after an absence-triggered pause, plus why it was paused so the
    /// prompt can say "your Mac slept" or "your screen turned off" accurately.
    private var resumeAfterWake: (projectID: Int64, name: String, because: String)?
    private var cancellables: Set<AnyCancellable> = []

    /// Opens/focuses the main window before prompting — a normal titled window is what actually
    /// yanks the user out of another app's full-screen Space. Set by AppDelegate.
    var openMainWindow: (() -> Void)?

    init(engine: TimerEngine, appState: AppState, settings: Settings) {
        self.engine = engine
        self.appState = appState
        self.settings = settings

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        // The DISPLAY going dark is its own event — system sleep may be hours later, or never
        // (a running timer holds .idleSystemSleepDisabled, so the Mac won't idle-sleep on its own).
        // A blank screen after the idle timeout means nobody is at the keyboard, so the timer
        // shouldn't keep counting.
        nc.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)

        // A single non-repeating Timer had to fire correctly once, hours out, with no recovery if it
        // didn't — and on 2026-08-25 it didn't, recording ~98 minutes nobody worked. The cause was
        // never found, which is the point: this sweep re-derives the answer from `runningSince` every
        // 15s, so a missed fire self-corrects in seconds whatever the reason. The one-shot above is
        // now an optimisation, not the guarantee.
        backstopTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }

        // (Re)arm the long-session checkpoint whenever the running task or the threshold changes.
        // @Published fires in willSet (before the value updates), so hop to the next runloop tick
        // to read the settled `runningSince` — otherwise the arm reads nil and never fires.
        Publishers.Merge3(
            engine.$runningSince.map { _ in () },
            settings.$autoPauseMinutes.map { _ in () },
            settings.$promptsEnabled.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.rearmCheckpoint() }
        .store(in: &cancellables)

        // Same for the mirror-image nudge: armed off `pausedSince` instead of `runningSince`.
        Publishers.Merge3(
            engine.$pausedSince.map { _ in () },
            settings.$idleNudgeMinutes.map { _ in () },
            settings.$promptsEnabled.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.rearmIdleNudge() }
        .store(in: &cancellables)
    }

    // MARK: - Sleep / wake

    /// How long the screen must stay dark before the timer is paused.
    ///
    /// Not instant, because the display-sleep timeout can be very short (2 minutes on battery is a
    /// common default) and reading something on screen without touching the keyboard is real work.
    /// Waking inside this window cancels the pause entirely, so a brief blank costs nothing; stay
    /// away longer and the pause is back-dated to the moment the screen went dark, so the grace
    /// period itself is never counted either way.
    private static let blankGraceSeconds: TimeInterval = 60

    /// When the display went dark with a timer running, and the pending pause for it.
    private var blankedAt: Date?
    private var blankPauseTimer: Timer?

    @objc private func willSleep() {
        // Full sleep is unambiguous — pause now, back-dated to the blank if the screen went dark
        // first (the grace timer can't fire while the machine is asleep).
        let at = blankedAt ?? Date()
        cancelPendingBlankPause()
        pauseForAbsence(at: at, because: "your Mac slept")
    }

    @objc private func screensDidSleep() {
        guard engine.isRunning, blankedAt == nil else { return }
        let at = Date()
        blankedAt = at
        blankPauseTimer = Timer.scheduledTimer(withTimeInterval: Self.blankGraceSeconds,
                                               repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blankPauseTimer = nil
                self.pauseForAbsence(at: at, because: "your screen turned off")
            }
        }
    }

    private func cancelPendingBlankPause() {
        blankPauseTimer?.invalidate(); blankPauseTimer = nil
        blankedAt = nil
    }

    /// Pause because the machine stopped being used. Not gated on `promptsEnabled`: that switch
    /// governs whether we ASK things, while this is about not recording time nobody worked. The
    /// wake-side prompt is gated.
    ///
    /// A no-op when nothing is running, so a display sleep that follows an already-paused timer
    /// (or a system sleep after a display sleep) can't overwrite the pending resume.
    private func pauseForAbsence(at when: Date, because reason: String) {
        guard let id = engine.runningProjectID else { return }
        let name = appState.projects.first { $0.id == id }?.name ?? "task"
        // Never back-date before the interval's own start, which would make it negative.
        let at = max(when, engine.runningSince ?? when)
        engine.pause(at: min(at, Date()))
        resumeAfterWake = (id, name, reason)
        blankedAt = nil
        dismissPrompt()
    }

    @objc private func didWake() {
        cancelPendingBlankPause()
        handleReturn()
    }

    @objc private func screensDidWake() {
        // Back inside the grace window: the pause never happened, so there's nothing to resume and
        // nothing to ask about. Silently carry on — this is the "I was just reading" case.
        let wasPending = blankPauseTimer != nil
        cancelPendingBlankPause()
        guard !wasPending else { return }
        handleReturn()
    }

    private func handleReturn() {
        // The run loop is suspended during sleep, so the menu bar's deferred state refresh can be
        // missed — the paused task ends up without its orange pill. Nudge a refresh on wake.
        NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)

        // Cleared before any early return below, so a screen wake followed by a system wake can't
        // prompt twice for the same pause.
        guard let resume = resumeAfterWake else { return }
        resumeAfterWake = nil
        // Prompts fully disabled → stay silent. Sleep still paused the timer (that's about
        // keeping the data honest, not about nudging), it just won't ask anything now.
        guard settings.promptsEnabled else { return }
        // Only offer if that task still exists and isn't archived/finished.
        guard appState.selectableProjects.contains(where: { $0.id == resume.projectID }) else { return }
        promptResume(projectID: resume.projectID, name: resume.name, because: resume.because)
    }

    // MARK: - Long-session checkpoint

    private func rearmCheckpoint() {
        // Ignore the state change caused by the checkpoint pausing the timer itself — otherwise
        // it would immediately cancel the prompt we just showed.
        if suppressRearm { suppressRearm = false; return }

        checkpointTimer?.invalidate(); checkpointTimer = nil
        // Re-arming means the situation reset (task switched/paused/kept going) — clear any nag.
        nagTimer?.invalidate(); nagTimer = nil
        awaitingResponse = false
        pendingPromptProjectID = nil
        dismissPrompt()

        guard NudgePolicy.armsSessionNudge(settings.nudgeConfig, isRunning: engine.isRunning),
              let since = engine.runningSince else { return }
        let delay = Self.debugSeconds
            ?? NudgePolicy.delay(since: since, threshold: settings.autoPauseSeconds)
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkpointReached() }
        }
    }

    /// Fire anything already overdue. Idempotent: `checkpointReached` pauses the timer, so the very
    /// condition that got us here stops being true and it can't fire twice.
    private func sweep() {
        // Don't interrupt a prompt that's already waiting for an answer.
        guard !awaitingResponse, !promptShowing else { return }

        if NudgePolicy.armsSessionNudge(settings.nudgeConfig, isRunning: engine.isRunning),
           let since = engine.runningSince,
           Date().timeIntervalSince(since) >= settings.autoPauseSeconds {
            checkpointReached()
            return
        }
        if NudgePolicy.armsPausedNudge(settings.nudgeConfig, isPaused: engine.isPaused,
                                       awaitingAnswer: awaitingResponse),
           let since = engine.pausedSince,
           Date().timeIntervalSince(since) >= settings.idleNudgeSeconds,
           !idleNudgePending {
            idleNudgeReached()
        }
    }

    private func checkpointReached() {
        guard let id = engine.runningProjectID else { return }
        let name = appState.projects.first { $0.id == id }?.name ?? "task"
        // Pause NOW (protects against forgot-to-pause / walked-away time), keeping the task as
        // current, then prompt to resume. The menu bar stays orange until you answer, so an
        // accidentally-dismissed prompt (e.g. during ⌘-Tab) keeps nagging instead of vanishing.
        //
        // This pause changes `runningSince`, which would normally trigger rearmCheckpoint (and
        // cancel the prompt we're about to show). Suppress that self-inflicted rearm.
        suppressRearm = true
        engine.pause()
        promptStillWorking(projectID: id, name: name)
    }

    /// Set while the checkpoint itself pauses the timer, so the resulting state change doesn't
    /// bounce back into rearmCheckpoint and cancel the prompt.
    private var suppressRearm = false

    // MARK: - Idle nudge (paused too long)

    /// The mirror of the long-session checkpoint. That one catches "you forgot to pause";
    /// this catches "you forgot to un-pause" — you took a break, came back, and started working
    /// without resuming the timer, so the time goes unrecorded.
    ///
    /// Nothing is written either way: being paused is already the safe state, so this only asks.
    private func rearmIdleNudge() {
        idleTimer?.invalidate(); idleTimer = nil
        idleNudgePending = false
        // A paused task that gets resumed or cleared dismisses any pending idle prompt.
        if !engine.isPaused { dismissIdlePromptIfShowing() }

        // Don't stack on the other prompt. The "still working?" checkpoint pauses the timer
        // itself, which sets `pausedSince` and would otherwise arm this nudge to fire a second
        // panel over the first. While that prompt is unanswered, the pause isn't yours — it's
        // the checkpoint's, and answering it re-arms whichever nudge then applies.
        guard NudgePolicy.armsPausedNudge(settings.nudgeConfig,
                                          isPaused: engine.isPaused,
                                          awaitingAnswer: awaitingResponse),
              let since = engine.pausedSince else { return }
        let delay = Self.debugSeconds
            ?? NudgePolicy.delay(since: since, threshold: settings.idleNudgeSeconds)
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleNudgeReached() }
        }
    }

    private func idleNudgeReached() {
        // Only nudge about a task that's still paused and still resumable.
        guard engine.isPaused, let id = engine.currentProjectID,
              appState.selectableProjects.contains(where: { $0.id == id }) else { return }
        let name = appState.projects.first { $0.id == id }?.name ?? "task"
        idleNudgePending = true
        promptStillPaused(projectID: id, name: name)
    }

    /// True while a "still paused?" prompt is pending, so its own dismissal can be told apart
    /// from a state change that should cancel it.
    private var idleNudgePending = false

    private func promptStillPaused(projectID: Int64, name: String) {
        let mins = Int(Date().timeIntervalSince(engine.pausedSince ?? Date()) / 60)
        let howLong = mins >= 1 ? "\(mins)m" : "a while"
        showPrompt(
            title: "“\(name)” is still paused",
            message: "Paused for \(howLong). Pick it back up, or leave it paused?",
            primary: "Resume",              // default — Return resumes
            secondary: "Leave paused"
        ) { [weak self] resume in
            guard let self else { return }
            self.idleNudgePending = false
            self.idleTimer?.invalidate(); self.idleTimer = nil
            if resume, self.appState.selectableProjects.contains(where: { $0.id == projectID }) {
                self.engine.switchTo(projectID: projectID)
            }
            // Declining doesn't re-arm: one nudge per pause, so leaving something paused
            // deliberately doesn't turn into a repeating interruption.
        }
    }

    private func dismissIdlePromptIfShowing() {
        guard idleNudgePending else { return }
        idleNudgePending = false
        dismissPrompt()
    }

    private var idleTimer: Timer?

    // MARK: - Prompts

    /// The task a pending "still working?" prompt is about (nil when not awaiting).
    private var pendingPromptProjectID: Int64?

    private func promptStillWorking(projectID: Int64, name: String) {
        awaitingResponse = true            // menu bar shows the orange highlight
        pendingPromptProjectID = projectID
        presentStillWorkingPanel(projectID: projectID, name: name)

        // If the panel gets dismissed without an answer (e.g. focus lost during ⌘-Tab), the
        // orange highlight persists and the panel re-appears until you actually respond.
        nagTimer?.invalidate()
        nagTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.awaitingResponse, !self.promptShowing else { return }
                self.presentStillWorkingPanel(projectID: projectID, name: name)
            }
        }
    }

    private func presentStillWorkingPanel(projectID: Int64, name: String) {
        showPrompt(
            title: "Still on “\(name)”?",
            message: "Paused it for now. Keep going, or leave it paused?",
            primary: "Keep going",       // default — highlighted, Return activates it
            secondary: "Keep it paused"
        ) { [weak self] keepGoing in
            guard let self else { return }
            self.awaitingResponse = false
            self.pendingPromptProjectID = nil
            self.nagTimer?.invalidate(); self.nagTimer = nil
            if keepGoing, self.appState.selectableProjects.contains(where: { $0.id == projectID }) {
                self.engine.switchTo(projectID: projectID)   // resume timing → re-arms checkpoint
            }
            // "Keep it paused" deliberately doesn't arm the "still paused?" nudge: you just
            // said you know it's paused, so asking again in a few minutes would be nagging.
            // (`pausedSince` doesn't change here, so no re-arm fires.)
        }
    }

    private func promptResume(projectID: Int64, name: String, because reason: String) {
        showPrompt(
            title: "Welcome back — resume “\(name)”?",
            message: "Timeslice paused it when \(reason). Resume timing, or leave it paused?",
            primary: "Resume",
            secondary: "Leave paused"
        ) { [weak self] resume in
            guard let self, resume,
                  self.appState.selectableProjects.contains(where: { $0.id == projectID }) else { return }
            self.engine.switchTo(projectID: projectID)
        }
    }

    // MARK: - Prompt

    /// Show a standard alert. Presented on the next runloop tick so it never fights the timer
    /// callback we're inside. `handler(true)` = primary button; `false` = secondary/dismiss.
    /// The timer is already paused before this is shown, so a brief modal is harmless.
    private func showPrompt(title: String, message: String, primary: String, secondary: String?,
                            handler: @escaping (Bool) -> Void) {
        dismissPrompt()
        promptShowing = true
        // Open the main window first — a normal titled window is what yanks the user out of
        // another app's full-screen Space back to the desktop. The panel then floats on top.
        openMainWindow?()
        let panel = PromptPanel(title: title, message: message, primary: primary, secondary: secondary) { [weak self] choice in
            self?.activePromptPanel = nil
            self?.promptShowing = false
            handler(choice)
        }
        activePromptPanel = panel
        panel.present()
    }

    /// True while a prompt panel is on screen — prevents the nag timer stacking panels.
    private var promptShowing = false
    private var activePromptPanel: PromptPanel?

    private func dismissPrompt() {
        activePromptPanel?.close()
        activePromptPanel = nil
        promptShowing = false
    }
}
