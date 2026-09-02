import AppKit
import SwiftUI
import Combine
import TimesliceCore

/// Menu-bar presence: a status item whose title live-updates with the running timer, and a
/// popover hosting the QuickPanelView. Privacy Mode governs how much the title reveals.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let appState: AppState
    private let engine: TimerEngine
    private let privacy: PrivacyController
    private let autoPause: AutoPauseController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    /// `sync` is optional-by-nature: nil-safe so the menu bar works identically with sync off.
    private let sync: SyncController?

    init(appState: AppState, engine: TimerEngine, privacy: PrivacyController,
         autoPause: AutoPauseController, sync: SyncController? = nil) {
        self.sync = sync
        self.appState = appState
        self.engine = engine
        self.privacy = privacy
        self.autoPause = autoPause
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()

        // The live clock ticks 10x/sec while running — read it synchronously so the running
        // display is immediate.
        engine.clock.$elapsed.sink { [weak self] _ in self?.updateTitle() }.store(in: &cancellables)
        // State-change publishers (@Published) fire in willSet, BEFORE the value and the
        // dependent totals settle. Hop to the next runloop tick so updateTitle reads the final
        // state — otherwise pausing briefly drops the just-ended session's time from the total.
        Publishers.Merge3(
            engine.$runningProjectID.map { _ in () },
            engine.$currentProjectID.map { _ in () },
            appState.$todayTotals.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.updateTitle() }
        .store(in: &cancellables)
        // Redraw when another device starts/stops timing, so the "↳ device" hint appears and
        // clears without waiting for the next tick.
        sync?.$takenOverBy
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lastRenderedTitle = nil
                self?.updateTitle()
            }.store(in: &cancellables)
        privacy.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lastRenderedTitle = nil   // privacy flips what's shown; force a redraw
                self?.updateTitle()
            }.store(in: &cancellables)
        // Orange highlight while a "still working?" prompt is pending.
        autoPause.$awaitingResponse
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lastRenderedTitle = nil   // color changes; force a redraw
                self?.updateTitle()
            }.store(in: &cancellables)

        // After sleep/wake the run loop was suspended, so a deferred refresh can be missed and
        // the paused pill never gets drawn. Force a full redraw on wake (bypass the dedup cache).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastRenderedTitle = nil
                self?.updateTitle()
            }
        }

        updateTitle()
        // Belt-and-braces: also refresh on the next tick, so a restored timer is reflected even
        // if state settled after this init (the title otherwise stayed blank until a pause/start).
        DispatchQueue.main.async { [weak self] in
            self?.lastRenderedTitle = nil
            self?.updateTitle()
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Timeslice") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        let content = QuickPanelView(appState: appState, engine: engine)
        popover.contentViewController = NSHostingController(rootView: content)
    }

    // MARK: - Title rendering (privacy-aware)

    private func updateTitle() {
        guard let button = statusItem.button else { return }

        // Text sits to the LEFT of the clock icon (order: text + time, then icon on the right).
        button.imagePosition = .imageTrailing

        // Red pill whenever the current task is PAUSED — however it paused (manual, auto-pause
        // checkpoint, or sleep). Visible even in privacy mode via the tinted icon.
        let paused = engine.isPaused
        applyAwaitingStyle(paused, to: button)

        // Privacy = icon-only: show just the clock icon (no text).
        // Idle (no current task): fall back to the TOP task so the bar isn't empty.
        let displayID: Int64?
        if privacy.level == .full {
            displayID = engine.currentProjectID ?? appState.visibleTotals.first?.project.id
        } else {
            displayID = nil
        }
        guard let displayID else {
            let idle = button.image == nil ? "Timeslice " : ""
            let key = "\(paused ? "hl:" : "")\(idle)"
            if key != lastRenderedTitle {
                lastRenderedTitle = key
                button.attributedTitle = NSAttributedString(string: idle)
            }
            return
        }
        // Today's total for the task (committed today + live session while running). Seconds
        // resolution only — ms in the menu bar is visually noisy (the popover/list keep ms).
        let todayBase = appState.todayTotals.first { $0.project.id == displayID }?.seconds ?? 0
        let live = todayBase + engine.elapsed
        let time = Format.duration(live)
        let name = taskName(displayID)
        var text = name.isEmpty ? time : "\(name) · \(time)"
        // When another device is timing, say so — otherwise a silently-paused pill looks like a
        // bug rather than a takeover.
        // Only after an actual takeover — and using the device's friendly name, not its raw id.
        if paused, let other = sync?.takenOverBy {
            text += " ↳ \(other)"
        }
        // Skip redundant redraws: the clock ticks ~10x/sec but the title only shows whole
        // seconds, so rewrite only when the rendered text OR the paused state changes.
        let title = "\(text) "
        let renderKey = "\(paused ? "hl:" : "")\(title)"
        guard renderKey != lastRenderedTitle else { return }
        lastRenderedTitle = renderKey
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        if paused { attrs[.foregroundColor] = NSColor.black }   // dark text on the orange pill
        button.attributedTitle = NSAttributedString(string: title, attributes: attrs)
    }

    private var lastRenderedTitle: String?


    /// Draw (or clear) a solid orange pill on the status button while the current task is PAUSED.
    /// Icon + text go dark for contrast. Visible even in privacy mode (the tinted icon nags).
    private func applyAwaitingStyle(_ paused: Bool, to button: NSStatusBarButton) {
        button.wantsLayer = true
        button.contentTintColor = paused ? .black : nil   // dark icon on the orange pill
        guard let layer = button.layer else { return }
        if paused {
            layer.backgroundColor = NSColor.systemOrange.cgColor
            let h = button.bounds.height > 0 ? button.bounds.height : 22
            layer.cornerRadius = h / 2   // full pill
            layer.masksToBounds = true
            layer.borderWidth = 0
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
            layer.cornerRadius = 0
        }
    }

    private func taskName(_ id: Int64) -> String {
        if let p = appState.projects.first(where: { $0.id == id }) { return p.name }
        return (try? appState.storeForEditing.listProjects(includeArchived: true))?
            .first { $0.id == id }?.name ?? ""
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            appState.reload()
            // Freeze recency order for as long as the popover is open, so the rows and the ↑/↓ keys
            // walk the SAME list. Without the freeze the list would re-rank under the cursor and the
            // arrows would track a different order than the one on screen.
            let ordered = appState.beginSwitcherSession()
            // Default the highlight to the current (running/paused) task, else the top of the list.
            appState.selectedProjectID = engine.currentProjectID ?? ordered.first?.id
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.makeKey()                  // key WITHOUT NSApp.activate, so the main
                privacy.applySharing(to: window)  // window (if any) is NOT pulled to the front
            }
            installPopoverKeyMonitor()
        }
    }

    /// Local key monitor for the popover: SwiftUI `.onKeyPress` doesn't fire reliably in a
    /// transient popover, so handle ↑/↓/space/esc here while it's open.
    private var popoverKeyMonitor: Any?

    private func installPopoverKeyMonitor() {
        removePopoverKeyMonitor()
        popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            switch event.keyCode {
            case 126: self.appState.moveSelection(by: -1); return nil  // up arrow
            case 125: self.appState.moveSelection(by: 1); return nil   // down arrow
            case 49:  self.appState.toggleSelected(); return nil       // space
            case 53:  self.popover.performClose(nil); return nil       // esc
            default:  return event
            }
        }
    }

    private func removePopoverKeyMonitor() {
        if let monitor = popoverKeyMonitor {
            NSEvent.removeMonitor(monitor)
            popoverKeyMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Release the frozen order so the next open re-ranks with whatever you just worked on first.
        appState.endSwitcherSession()
        removePopoverKeyMonitor()
    }

    func showPopover() {
        if !popover.isShown { togglePopover(nil) }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Timeslice", action: #selector(openMain), keyEquivalent: "")
            .target = self
        // Reachable with the main window closed: feedback is its own window now, so it doesn't
        // depend on that toolbar being on screen.
        menu.addItem(withTitle: "Feedback…", action: #selector(openFeedback), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // restore left-click-to-popover behavior
    }

    @objc private func openMain() {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    @objc private func openFeedback() {
        NotificationCenter.default.post(name: .openFeedbackWindow, object: nil)
    }
}
