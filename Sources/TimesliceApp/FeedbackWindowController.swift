import AppKit
import SwiftUI
import TimesliceCore

/// A half-written note and the tag it will carry, held outside the view.
///
/// The window can be closed while something is typed into it, and a SwiftUI view's `@State` dies
/// with its host. Keeping the draft here means shutting the window and reopening it later resumes
/// the sentence rather than throwing it away — the same reason the popover version handed its draft
/// to the parent, now that the parent is a window controller.
@MainActor
final class FeedbackDraft: ObservableObject {
    @Published var text = ""
    @Published var platform: FeedbackPlatform? = .macOS
    @Published var pendingImages: [Data] = []
}

/// Feedback in its OWN window, not a popover.
///
/// A popover is modal to the pointer: it closes the moment you click anything behind it, which made
/// working THROUGH the list impossible — every issue you went to check cost you the list and your
/// place in it. Reading feedback and evaluating what it describes are the same activity, so the two
/// have to be on screen together.
///
/// A separate window rather than a tab in the main one for the same reason: a tab would still make
/// the app show one thing at a time.
@MainActor
final class FeedbackWindowController {
    private let window: NSWindow
    private let draft = FeedbackDraft()

    init(store: IntervalStore, privacy: PrivacyController) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Feedback"
        window.contentViewController = NSHostingController(
            rootView: FeedbackSheet(store: store, draft: draft, onClose: { [weak window] in
                window?.performClose(nil)
            })
        )
        window.setContentSize(NSSize(width: 560, height: 620))
        // Not centred: the point is to sit BESIDE what it's about, so it opens offset from the
        // main window instead of on top of it.
        window.setFrameTopLeftPoint(Self.openingCorner)
        // Closing must not deallocate it — the controller is retained and reopened, and a released
        // window would take the draft with it.
        window.isReleasedWhenClosed = false
        // A note can quote a task name, so it hides from screen capture with everything else.
        privacy.manage(window)
    }

    /// Top-left corner: to the right of centre, so the main window can hold the left half of the
    /// screen and both stay usable without dragging either one.
    private static var openingCorner: NSPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return NSPoint(x: 120, y: 800) }
        return NSPoint(x: visible.midX + 40, y: visible.maxY - 40)
    }

    func show() {
        // Order front WITHOUT stealing focus from a window you might be typing in? No: you clicked
        // the button, so you want it. But it's not made key when it's already visible, or clicking
        // the toolbar button while reading would yank you out of the main window.
        if window.isVisible {
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
