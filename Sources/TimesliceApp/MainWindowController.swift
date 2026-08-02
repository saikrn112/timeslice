import AppKit
import SwiftUI

/// Hosts the main window in an NSWindow so we can register it with the PrivacyController for
/// screen-capture exclusion (`sharingType = .none`).
@MainActor
final class MainWindowController {
    private let window: NSWindow
    private let privacy: PrivacyController

    /// Opens tall enough that the whole Metrics tab is visible without scrolling, clamped to
    /// the screen so it still fits on a laptop display (a 13" Mac has ~949pt usable height).
    /// A screenshot run of the Tasks tab uses a shorter window so the list isn't dwarfed by
    /// empty space.
    private static var defaultContentSize: NSSize {
        let usable = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let wantsShort = DemoData.isScreenshotRun
            && ProcessInfo.processInfo.environment["TIMESLICE_DEMO_TAB"] != "metrics"
        return NSSize(width: min(720, usable.width - 40),
                      height: min(wantsShort ? 640 : 920, usable.height - 40))
    }

    init(appState: AppState, engine: TimerEngine, privacy: PrivacyController, settings: Settings) {
        self.privacy = privacy
        let root = MainWindowView(appState: appState, engine: engine, privacy: privacy, settings: settings)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultContentSize.width, height: Self.defaultContentSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Timeslice"
        window.contentViewController = NSHostingController(rootView: root)
        // Set the size *after* installing the hosting controller: SwiftUI's frame(minWidth:
        // minHeight:) is applied on assignment and otherwise shrinks the window back down.
        window.setContentSize(Self.defaultContentSize)
        window.center()
        window.isReleasedWhenClosed = false
        privacy.manage(window)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }
}
