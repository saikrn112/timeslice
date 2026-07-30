import AppKit
import SwiftUI

/// A small center-screen input for quickly adding a task from anywhere (fn+⌘+⇧+A). Type a name,
/// press Return → the task is created and immediately started. Esc cancels.
@MainActor
final class QuickAddPanel {
    private var window: NSPanel?
    private var onSubmit: ((String) -> Void)?

    func show(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit

        let content = QuickAddView(
            onSubmit: { [weak self] name in self?.finish(name) },
            onCancel: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 96)

        let panel = window ?? makePanel()
        panel.contentView = hosting
        center(panel)
        window = panel

        // A regular panel that CAN become key, so the text field accepts typing. Activate the
        // app so keyboard focus lands in the field.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        if !trimmed.isEmpty { onSubmit?(trimmed) }
    }

    private func close() {
        window?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        // No .nonactivatingPanel — the panel must be able to become key so the text field
        // receives typing.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none   // keep the entered name out of screen captures
        return panel
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY + panel.frame.height   // a little above center
        ))
    }
}

/// A panel that can become key/main even without a standard title bar, so its text field
/// accepts keyboard input.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct QuickAddView: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                Text("New task").font(.headline).foregroundStyle(.white)
                Spacer()
                Text("↵ start · esc cancel").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
            TextField("Task name…", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit { onSubmit(name) }
                .onExitCommand { onCancel() }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.1)))
        }
        .padding(16)
        .frame(width: 420, height: 96)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
