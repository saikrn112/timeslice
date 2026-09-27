import AppKit
import SwiftUI

/// A floating dark prompt panel — same construction as the switcher HUD (which displays
/// reliably): borderless, `.statusBar` level, shown with `orderFrontRegardless()`. Unlike the
/// HUD it accepts clicks (buttons) and can become key. NON-modal, so background timers keep firing.
@MainActor
final class PromptPanel {
    enum Choice { case primary, secondary, tertiary }

    private let panel: KeyPanel
    private let onChoice: (Choice) -> Void
    private let quiet: Bool
    private var answered = false

    /// Two buttons, answered as a Bool — what the checkpoint and the resume prompts want.
    convenience init(title: String, message: String, primary: String, secondary: String?,
                     onChoice: @escaping (Bool) -> Void) {
        self.init(title: title, message: message, primary: primary, secondary: secondary,
                  tertiary: nil, quiet: false) { onChoice($0 == .primary) }
    }

    /// `quiet` inverts every disruption decision made below, and that is the point.
    ///
    /// The alert form deliberately ACTIVATES the app so a full-screen Space is dropped and the panel is
    /// waiting on the desktop — right for "still working?", which is rare and is protecting your data
    /// from an hour of walked-away time. The break reminder fires around thirteen times on a median day
    /// at a 30-minute interval, so the same behaviour would be unusable. Quiet mode floats over
    /// whatever you are doing, including another app's full-screen Space, and never takes focus or a
    /// keystroke.
    init(title: String, message: String, primary: String, secondary: String?,
         tertiary: String?, quiet: Bool, onChoice: @escaping (Choice) -> Void) {
        self.onChoice = onChoice
        self.quiet = quiet

        let size = NSSize(width: quiet ? 420 : 400, height: quiet ? 112 : 156)
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
        panel.takesKey = !quiet
        panel.level = quiet ? .statusBar : .floating
        if quiet {
            // Visible over a full-screen app WITHOUT pulling you out of it — the exact opposite of the
            // alert form's choice, for the reason in the initialiser's comment.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Load-bearing: `NSPanel` hides itself whenever the app isn't active, and a prompt that
            // deliberately never activates the app is therefore never visible at all. It presented
            // correctly, logged correctly, and could not be screenshotted or seen.
            panel.hidesOnDeactivate = false
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Normally excluded from screen capture; in demo mode leave it visible so it can be
        // screenshotted for the README.
        panel.sharingType = ProcessInfo.processInfo.environment["TIMESLICE_SEED_DEMO"] == "1" ? .readOnly : .none
        self.panel = panel

        let view = PromptView(
            title: title, message: message, primary: primary, secondary: secondary,
            tertiary: tertiary, quiet: quiet, size: size,
            onPrimary: { [weak self] in self?.finish(.primary) },
            onSecondary: { [weak self] in self?.finish(.secondary) },
            onTertiary: { [weak self] in self?.finish(.tertiary) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
    }

    func present() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            // Quiet prompts sit top-right under the menu bar, where a notification would be, so they
            // read as a notification rather than as something demanding an answer.
            let origin = quiet
                ? NSPoint(x: f.maxX - panel.frame.width - 16, y: f.maxY - panel.frame.height - 16)
                : NSPoint(x: f.midX - panel.frame.width / 2, y: f.midY - panel.frame.height / 2)
            panel.setFrameOrigin(origin)
        }
        guard !quiet else {
            // No activation and no key status: the buttons are still clickable, and nothing you are
            // typing goes anywhere near this.
            panel.orderFrontRegardless()
            return
        }
        // Activate the app — this yanks the user out of any other app's full-screen Space back
        // to the desktop, where the panel is shown key + front.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    private func finish(_ choice: Choice) {
        guard !answered else { return }
        answered = true
        panel.orderOut(nil)
        onChoice(choice)
    }
}

/// Borderless panel that can still become key so its buttons/keyboard work.
private final class KeyPanel: NSPanel {
    /// False for a quiet prompt, so it can't steal the keystroke you were in the middle of.
    var takesKey = true
    override var canBecomeKey: Bool { takesKey }
    override var canBecomeMain: Bool { takesKey }
}

private struct PromptView: View {
    let title: String
    let message: String
    let primary: String
    let secondary: String?
    let tertiary: String?
    let quiet: Bool
    let size: NSSize
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onTertiary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: quiet ? 8 : 12) {
            Text(title).font(.headline).foregroundStyle(.white)
            Text(message).font(quiet ? .caption : .callout).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer()
                if let tertiary {
                    Button(tertiary, action: onTertiary).controlSize(quiet ? .regular : .large)
                }
                if let secondary {
                    Button(secondary, action: onSecondary).controlSize(quiet ? .regular : .large)
                }
                // No default-action shortcut in quiet mode: the panel isn't key, and claiming Return
                // would be claiming a keystroke from whatever you are actually typing in.
                if quiet {
                    Button(primary, action: onPrimary)
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(primary, action: onPrimary)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(quiet ? 16 : 20)
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
    }
}
