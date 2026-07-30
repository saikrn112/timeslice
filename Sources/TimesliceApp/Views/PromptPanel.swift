import AppKit
import SwiftUI

/// A floating dark prompt panel — same construction as the switcher HUD (which displays
/// reliably): borderless, `.statusBar` level, shown with `orderFrontRegardless()`. Unlike the
/// HUD it accepts clicks (buttons) and can become key. NON-modal, so background timers keep firing.
@MainActor
final class PromptPanel {
    private let panel: KeyPanel
    private let onChoice: (Bool) -> Void
    private var answered = false

    init(title: String, message: String, primary: String, secondary: String?,
         onChoice: @escaping (Bool) -> Void) {
        self.onChoice = onChoice

        let size = NSSize(width: 400, height: 156)
        // Behave like a system prompt: when another app is full-screen, activating our app pulls
        // the user OUT of that full-screen Space back to the desktop, where this panel is waiting
        // (rather than overlaying the full-screen app). So this is an ACTIVATING, key panel tied
        // to the app's own Space — NOT canJoinAllSpaces/nonactivating (that would keep it on the
        // full-screen Space and never yank focus back).
        let panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Normally excluded from screen capture; in demo mode leave it visible so it can be
        // screenshotted for the README.
        panel.sharingType = ProcessInfo.processInfo.environment["TIMESLICE_SEED_DEMO"] == "1" ? .readOnly : .none
        self.panel = panel

        let view = PromptView(
            title: title, message: message, primary: primary, secondary: secondary,
            onPrimary: { [weak self] in self?.finish(true) },
            onSecondary: { [weak self] in self?.finish(false) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
    }

    func present() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2,
                                         y: f.midY - panel.frame.height / 2))
        }
        // Activate the app — this yanks the user out of any other app's full-screen Space back
        // to the desktop, where the panel is shown key + front.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    private func finish(_ choice: Bool) {
        guard !answered else { return }
        answered = true
        panel.orderOut(nil)
        onChoice(choice)
    }
}

/// Borderless panel that can still become key so its buttons/keyboard work.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct PromptView: View {
    let title: String
    let message: String
    let primary: String
    let secondary: String?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(.white)
            Text(message).font(.callout).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if let secondary {
                    Button(secondary, action: onSecondary).controlSize(.large)
                }
                Button(primary, action: onPrimary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400, height: 156)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
    }
}
