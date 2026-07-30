import AppKit
import SwiftUI

/// Hosts the main window in an NSWindow so we can register it with the PrivacyController for
/// screen-capture exclusion (`sharingType = .none`).
@MainActor
final class MainWindowController {
    private let window: NSWindow
    private let privacy: PrivacyController

    init(appState: AppState, engine: TimerEngine, privacy: PrivacyController, settings: Settings) {
        self.privacy = privacy
        let root = MainWindowView(appState: appState, engine: engine, privacy: privacy, settings: settings)
        // Taller in screenshot mode so the full Metrics tab fits in one capture.
        let height: CGFloat = ProcessInfo.processInfo.environment["TIMESLICE_SEED_DEMO"] == "1" ? 900 : 520
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Timeslice"
        window.contentViewController = NSHostingController(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
        privacy.manage(window)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }
}
