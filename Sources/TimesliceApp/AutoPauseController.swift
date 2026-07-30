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
    private var nagTimer: Timer?
    /// The task+time to offer resuming after a sleep-triggered pause.
    private var resumeAfterWake: (projectID: Int64, name: String)?
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

        // (Re)arm the long-session checkpoint whenever the running task or the threshold changes.
        // @Published fires in willSet (before the value updates), so hop to the next runloop tick
        // to read the settled `runningSince` — otherwise the arm reads nil and never fires.
        Publishers.Merge(
            engine.$runningSince.map { _ in () },
            settings.$autoPauseMinutes.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.rearmCheckpoint() }
        .store(in: &cancellables)
    }

    // MARK: - Sleep / wake

    @objc private func willSleep() {
        guard let id = engine.runningProjectID else { return }
        let name = appState.projects.first { $0.id == id }?.name ?? "task"
        // Back-date the pause to now (moment of sleep) — asleep time won't be counted.
        engine.pause(at: Date())
        resumeAfterWake = (id, name)
        dismissPrompt()
    }

    @objc private func didWake() {
        // The run loop is suspended during sleep, so the menu bar's deferred state refresh can be
        // missed — the paused task ends up without its orange pill. Nudge a refresh on wake.
        NotificationCenter.default.post(name: TimesliceNotifications.dataDidChange, object: nil)

        guard let resume = resumeAfterWake else { return }
        resumeAfterWake = nil
        // Only offer if that task still exists and isn't archived/finished.
        guard appState.selectableProjects.contains(where: { $0.id == resume.projectID }) else { return }
        promptResume(projectID: resume.projectID, name: resume.name)
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

        guard settings.autoPauseEnabled, let since = engine.runningSince else { return }
        let delay: TimeInterval
        if let debug = Self.debugSeconds {
            delay = debug
        } else {
            delay = max(1, since.addingTimeInterval(settings.autoPauseSeconds).timeIntervalSinceNow)
        }
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkpointReached() }
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
        }
    }

    private func promptResume(projectID: Int64, name: String) {
        showPrompt(
            title: "Welcome back — resume “\(name)”?",
            message: "Timeslice paused it when your Mac slept. Resume timing, or leave it paused?",
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
