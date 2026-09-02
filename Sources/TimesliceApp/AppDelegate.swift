import AppKit
import Combine
import TimesliceCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: IntervalStore!
    private var engine: TimerEngine!
    private var appState: AppState!
    private var privacy: PrivacyController!
    private let settings = AppSettings()
    private var statusBar: StatusBarController!
    private var mainWindowController: MainWindowController?
    private var hotkeys: GlobalHotkeyManager!
    private let hud = SwitchHUD()
    private let quickAdd = QuickAddPanel()

    /// Keeps App Nap off for the app's whole lifetime, so a global hotkey is answered promptly.
    ///
    /// TimerEngine holds its own assertion, but only WHILE a timer ticks — so a paused or idle
    /// Timeslice sitting in the background was nap-eligible, and the first fn+⌘+⇧+\ had to wake a
    /// throttled process before it could draw anything.
    ///
    /// Deliberately `.userInitiatedAllowingIdleSystemSleep`, NOT `.userInitiated`: the latter
    /// implies `.idleSystemSleepDisabled` and would stop the Mac sleeping on its own for as long as
    /// Timeslice is open. Responsiveness shouldn't cost you idle sleep.
    private var responsivenessActivity: NSObjectProtocol?
    private var autoPause: AutoPauseController?
    private var sync: SyncController?
    private let googleAuth = GoogleAuth()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if DemoData.isRequested {
                // Screenshot mode: use a separate demo DB and populate it with sample history.
                store = try IntervalStore(databaseURL: DemoData.databaseURL)
                try store.migrateIfNeeded()
                DemoData.seed(into: store)
            } else {
                store = try IntervalStore()
                try store.migrateIfNeeded()
                try seedProjectsIfEmpty()
            }
        } catch {
            presentFatal(error)
            return
        }

        engine = TimerEngine(store: store, settings: settings)
        privacy = PrivacyController()
        // In screenshot mode, keep windows capturable so `screencapture` can image them
        // (with privacy on, windows use sharingType = .none and appear blank to any capture).
        if DemoData.isRequested { privacy.setWindowsAlwaysCapturable(true) }
        appState = AppState(store: store, engine: engine)
        // Restore the open interval FIRST, then reload — otherwise totals are computed while
        // nothing is running and the menu bar's first paint has no current task (it only
        // appeared after a manual pause/start nudged a refresh).
        engine.restore()
        appState.reload()

        let autoPause = AutoPauseController(engine: engine, appState: appState, settings: settings)
        autoPause.openMainWindow = { [weak self] in self?.showMainWindow() }
        self.autoPause = autoPause

        // Sync stays inert unless a folder is configured — no account, no network by default.
        sync = SyncController(store: store, engine: engine, appState: appState,
                              settings: settings, auth: googleAuth)

        statusBar = StatusBarController(appState: appState, engine: engine, privacy: privacy,
                                        autoPause: autoPause, sync: sync)

        installMainMenu()
        setupHotkeys()

        // Build the two hotkey panels now, while we're already doing launch work, so the first
        // fn+⌘+⇧+\ or +A doesn't wait on SwiftUI construction. Nothing is shown.
        hud.prewarm()
        quickAdd.prewarm()

        responsivenessActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Global hotkeys must respond promptly"
        )

        NotificationCenter.default.publisher(for: .openMainWindow)
            .sink { [weak self] _ in self?.showMainWindow() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openTaskPalette)
            .sink { [weak self] _ in self?.showTaskPalette() }
            .store(in: &cancellables)

        if DemoData.isRequested {
            // Start a live timer so the running/paused UI shows, and open the window for capture.
            if let first = appState.projects.first { engine.switchTo(projectID: first.id) }
            appState.reload()
            showMainWindow()
        }
    }

    /// Build a minimal main menu so standard shortcuts (⌘Q quit, ⌘W close, ⌘M minimize) work.
    /// Without an app menu, ⌘Q does nothing.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Timeslice", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Timeslice", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Timeslice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Global hotkey handling (fn+⌘+⇧ task switcher)

    /// The task selected when the switcher chord was pressed — so we can tell if the user
    /// actually cycled to a different task before releasing.
    private var switcherStartID: Int64?

    /// Privacy mode no longer blocks the switcher or the palette.
    ///
    /// It used to, so nothing task-revealing could appear while sharing a screen. That was redundant:
    /// both panels set `sharingType = .none`, so they are already blank in any capture, including
    /// full-screen. The guard bought no privacy and cost the ability to switch or add a task at all
    /// while privacy was on — which is exactly when you're in a meeting and most likely to switch.
    ///
    /// What privacy still does: redact the menu-bar label and blank the windows in a capture.

    /// Opens the task palette — fuzzy search, resume, create with a `/project` token.
    ///
    /// One implementation, two triggers: the global hotkey and the window's + button. The window used
    /// to have its own text field that could only create a plain task, so the two disagreed about
    /// what "add a task" means.
    func showTaskPalette() {
        // The palette stands alone — it shows matches, statuses and today's times, so there's no
        // reason to drag the whole window forward just to add or resume a task.
        quickAdd.show(

                search: { [weak self] q in self?.appState.searchTasks(q) ?? [] },
                todaySeconds: { [weak self] id in self?.appState.todaySeconds(for: id) ?? 0 },
                onResume: { [weak self] id in
                    self?.appState.resumeAndStart(projectID: id)
                    self?.showHUDForRunning()
                },
                onCreate: { [weak self] name, group in
                    self?.appState.addAndStart(name: name, groupName: group)
                    self?.showHUDForRunning()
                },
                groups: { [weak self] in self?.appState.taskProjects ?? [] },
                displayColor: { [weak self] id in self?.appState.displayColorHex(forTaskID: id) ?? "#8E8E93" },
                groupName: { [weak self] id in self?.appState.shortGroupName(forTaskID: id) }
        )
    }

    private func setupHotkeys() {
        hotkeys = GlobalHotkeyManager()

        hotkeys.onActivate = { [weak self] in
            guard let self else { return }
            // Recency order, frozen for this hold: the task you were previously on is one press
            // away instead of wherever it sits in the list.
            let selectable = self.appState.beginSwitcherSession()
            // Begin cycling from the running task if it's still selectable; otherwise ensure the
            // selection lands on a selectable (unfinished) task so the HUD highlights something.
            if let running = self.engine.runningProjectID, selectable.contains(where: { $0.id == running }) {
                self.appState.selectedProjectID = running
            } else if !selectable.contains(where: { $0.id == self.appState.selectedProjectID }) {
                self.appState.selectedProjectID = selectable.first?.id
            }
            self.switcherStartID = self.appState.selectedProjectID
            self.hud.showSwitcher(tasks: selectable, selectedID: self.appState.selectedProjectID, todaySeconds: self.appState.todaySecondsByID, runningID: self.engine.runningProjectID, clock: self.engine.clock,
                                 displayColor: { [weak self] id in self?.appState.displayColorHex(forTaskID: id) ?? "#8E8E93" },
                                 groupName: { [weak self] id in self?.appState.shortGroupName(forTaskID: id) })
        }

        hotkeys.onCycle = { [weak self] delta in
            guard let self else { return }
            self.appState.moveSelection(by: delta)   // \ forward (+1), ] reverse (-1)
            self.hud.showSwitcher(tasks: self.appState.switcherProjects, selectedID: self.appState.selectedProjectID, todaySeconds: self.appState.todaySecondsByID, runningID: self.engine.runningProjectID, clock: self.engine.clock,
                                 displayColor: { [weak self] id in self?.appState.displayColorHex(forTaskID: id) ?? "#8E8E93" },
                                 groupName: { [weak self] id in self?.appState.shortGroupName(forTaskID: id) })
        }

        hotkeys.onCommit = { [weak self] in
            guard let self else { return }
            guard let selected = self.appState.selectedProjectID else { return }
            // Quick press+release on the already-running task → pause it (stays the current
            // task, so the menu bar keeps showing it). Otherwise switch to the selected task.
            if selected == self.switcherStartID && self.engine.runningProjectID == selected {
                self.engine.pause()
            } else {
                self.engine.switchTo(projectID: selected)  // pauses previous, starts selected
            }
            self.switcherStartID = nil
            self.appState.endSwitcherSession()
            self.showHUDForRunning()
        }

        hotkeys.onPrivacy = { [weak self] in self?.privacy.cycleLevel() }

        hotkeys.onQuickAdd = { [weak self] in self?.showTaskPalette() }

        // Requires Accessibility permission. If not yet granted, guide the user, then poll.
        // Only a screenshot run skips this — the modal would sit on top of the window being
        // captured. Plain demo mode still prompts, so hotkeys can be tested against demo data.
        if !hotkeys.register() && !DemoData.isScreenshotRun && !DemoData.isSandboxRun {
            promptForAccessibility()
            pollForAccessibility()
        }
    }

    /// Explain why the permission is needed and offer to open the right Settings pane.
    /// We do NOT call the system prompt (`prompt: true`) — that would stack macOS's own dialog on
    /// top of this one (a confusing double prompt). Our alert + a button to the settings pane is
    /// clearer and sufficient.
    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Turn on Timeslice’s quick task switcher"
        alert.informativeText = """
        The switcher lets you hold fn+⌘+⇧ and tap \\ or ] to flip through tasks — like ⌘-Tab \
        for apps — then release to start the one you land on.

        macOS needs your OK for this because two parts require it: reading the fn (globe) key, \
        and noticing when you let go of the keys to make your pick. macOS only allows that after \
        you enable Timeslice under Accessibility. It’s used only for these shortcuts — nothing else.

        Everything else in Timeslice works without this. (If an old “Timeslice” entry is already \
        listed, remove it with “–” and add this one.)
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func pollForAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if self.hotkeys.isActive { return }
            if self.hotkeys.register() { return }
            self.pollForAccessibility()
        }
    }

    private func showHUDForRunning() {
        if let id = engine.runningProjectID, let project = appState.projects.first(where: { $0.id == id }) {
            hud.showCommitted(text: project.name, colorHex: project.colorHex, running: true)
        } else {
            hud.showCommitted(text: "Stopped", colorHex: "#8E8E93", running: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregister()
    }

    /// Fires when the app is activated with no visible windows — e.g. ⌘-Tab to Timeslice or
    /// clicking its Dock icon after the main window was closed. Reopen the main window so the
    /// user doesn't have to go back to the popover's "Open" button.
    ///
    /// Skipped while a floating panel (the palette) owns the activation: it calls
    /// `NSApp.activate` to take keyboard focus, and with no other window visible macOS reads
    /// that as a reopen — which would pop the main window up behind the palette.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && !quickAdd.isPresenting { showMainWindow() }
        return true
    }

    private func seedProjectsIfEmpty() throws {
        guard try store.listProjects(includeArchived: true).isEmpty else { return }
        let starters = ["Deep Work", "Meetings", "Email", "Breaks"]
        for (index, name) in starters.enumerated() {
            try store.createProject(name: name, colorHex: Palette.color(forIndex: index))
        }
    }

    private func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController(appState: appState, engine: engine,
                                                       privacy: privacy, settings: settings,
                                                       sync: sync, auth: googleAuth)
        }
        mainWindowController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Timeslice failed to start"
        alert.informativeText = error.localizedDescription
        alert.runModal()
        NSApp.terminate(nil)
    }
}
