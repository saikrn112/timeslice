import AppKit
import SwiftUI
import TimesliceCore

/// Spotlight-style task palette (fn+⌘+⇧+A). Type to fuzzy-search your tasks — active and
/// finished, but not archived — and Return acts on the highlighted row: resuming an existing task
/// (un-finishing it as needed) or creating a new one from the last row. This is how you pick a
/// task back up later without making a duplicate.
@MainActor
final class QuickAddPanel {
    private var window: NSPanel?

    /// `onResume(id)` starts an existing task; `onCreate(name)` makes a new one.
    /// `todaySeconds(id)` supplies the time shown on the right of each row.
    func show(search: @escaping (String) -> [TaskMatch],
              todaySeconds: @escaping (Int64) -> TimeInterval,
              onResume: @escaping (Int64) -> Void,
              onCreate: @escaping (String) -> Void) {
        let content = PaletteView(
            search: search,
            todaySeconds: todaySeconds,
            onResume: { [weak self] id in self?.close(); onResume(id) },
            onCreate: { [weak self] name in self?.close(); onCreate(name) },
            onCancel: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 340)

        let panel = window ?? makePanel()
        panel.contentView = hosting
        center(panel)
        window = panel

        isPresenting = true
        // No NSApp.activate: it raises *every* window the app owns, which is what dragged an
        // already-open main window forward with the palette. The panel is a
        // `.nonactivatingPanel`, so it can take key focus on its own — `orderFrontRegardless`
        // shows it even while another app is frontmost.
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// True while the palette is up. `AppDelegate` checks this before honouring a reopen, so
    /// activating Timeslice while the palette is open (Dock icon, ⌘-Tab) doesn't shove the main
    /// window in front of it.
    ///
    /// Deliberately not `window?.isVisible`: dismissing the palette orders it out *before* macOS
    /// delivers any resulting reopen, so that check read false exactly when it mattered.
    private(set) var isPresenting = false

    private func close() {
        window?.orderOut(nil)
        // Cleared only once the run loop settles: ordering out leaves the app with no visible
        // window, and any resulting reopen arrives after this returns.
        DispatchQueue.main.async { [weak self] in self?.isPresenting = false }
    }

    private func makePanel() -> NSPanel {
        // Must be able to become key so the search field takes typing.
        //
        // `.nonactivatingPanel` is what lets the palette take keyboard focus WITHOUT activating
        // Timeslice. Activating would raise every window the app owns, so an already-open main
        // window surfaced alongside the palette.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
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
        // Normally excluded from screen capture; in demo mode leave it visible for recordings.
        panel.sharingType = ProcessInfo.processInfo.environment["TIMESLICE_SEED_DEMO"] == "1" ? .readOnly : .none
        return panel
    }

    /// Truly centred, matching the switcher HUD — the two panels appear in the same place so
    /// your eye doesn't have to travel between them.
    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2
        ))
    }
}

/// A panel that can become key/main without a standard title bar.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct PaletteView: View {
    let search: (String) -> [TaskMatch]
    let todaySeconds: (Int64) -> TimeInterval
    let onResume: (Int64) -> Void
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var matches: [TaskMatch] = []
    @State private var selection = 0          // index into rows (matches + optional create row)
    /// True while the arrow keys own the selection, so hover can't hijack it as rows scroll
    /// beneath a stationary pointer. Reset by any genuine pointer movement.
    @State private var keyboardDriving = false
    @FocusState private var focused: Bool

    /// Show a "Create …" row unless the query exactly matches an existing task.
    private var showsCreateRow: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return false }
        return !matches.contains { $0.project.name.caseInsensitiveCompare(q) == .orderedSame }
    }
    private var rowCount: Int { matches.count + (showsCreateRow ? 1 : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider().opacity(0.3)
            if rowCount == 0 {
                Text(query.isEmpty ? "No tasks yet" : "No matches")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                rows
            }
            Divider().opacity(0.3)
            footer
        }
        .frame(width: 460, height: 340, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .onAppear {
            matches = search("")
            DispatchQueue.main.async { focused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
            TextField("Search or create a task…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
                .focused($focused)
                .onChange(of: query) { _, q in
                    matches = search(q)
                    selection = 0
                }
                .onSubmit(activateSelection)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                // Esc: a TextField normally swallows this (AppKit treats it as "clear field"),
                // so handle it explicitly here rather than relying on onExitCommand.
                .onKeyPress(.escape) { onCancel(); return .handled }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            // Matches scroll; the create row is pinned below so it's never buried off-screen.
            ScrollViewReader { sp in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { idx, m in
                            row(
                                color: Color(hex: m.project.colorHex),
                                name: m.project.name,
                                badge: statusBadge(m.project),
                                selected: idx == selection,
                                time: todaySeconds(m.project.id)
                            )
                            .id(idx)
                            .onTapGesture { onResume(m.project.id) }
                            // Hover only steers the selection once the pointer actually moves.
                            // Otherwise arrowing scrolls rows under a stationary cursor, whose
                            // hover then rewrites `selection` and fights the keyboard.
                            .onHover { if $0 && !keyboardDriving { selection = idx } }
                        }
                    }
                    .padding(8)
                }
                // Keep the keyboard selection in view when arrowing past the fold. No anchor:
                // SwiftUI then scrolls the minimum needed to reveal the row, so a selection
                // that's already visible doesn't move the list at all. `.center` re-centred on
                // every keypress, which made steady arrowing lurch.
                .onChange(of: selection) { _, new in
                    guard keyboardDriving, new < matches.count else { return }
                    sp.scrollTo(new)
                }
                .onContinuousHover { phase in
                    // Any real pointer movement hands control back to the mouse.
                    if case .active = phase { keyboardDriving = false }
                }
            }
            if showsCreateRow {
                Divider().opacity(0.25)
                let idx = matches.count
                row(
                    color: .green,
                    name: "Create “\(query.trimmingCharacters(in: .whitespaces))”",
                    badge: nil,
                    selected: idx == selection,
                    systemImage: "plus.circle.fill"
                )
                .padding(.horizontal, 8).padding(.vertical, 6)
                .onTapGesture { onCreate(query) }
                .onHover { if $0 { selection = idx } }
            }
        }
    }

    private func row(color: Color, name: String, badge: (String, Color)?, selected: Bool,
                     time: TimeInterval? = nil, systemImage: String? = nil) -> some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(color).font(.system(size: 12))
            } else {
                Circle().fill(color).frame(width: 9, height: 9)
            }
            Text(name)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let (text, tint) = badge {
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.18)))
            }
            if let time {
                Text(Format.duration(time))
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.white.opacity(time > 0 ? 0.6 : 0.25))
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.85) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func statusBadge(_ p: Project) -> (String, Color)? {
        p.finished ? ("done", .green) : nil   // archived tasks never reach the palette
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↑↓", "select")
            hint("↵", selection < matches.count ? "start" : "create")
            hint("esc", "cancel")
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.12)))
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func move(_ delta: Int) {
        guard rowCount > 0 else { return }
        keyboardDriving = true
        selection = (selection + delta + rowCount) % rowCount
    }

    private func activateSelection() {
        guard rowCount > 0 else { return }
        if selection < matches.count {
            onResume(matches[selection].project.id)
        } else {
            onCreate(query)
        }
    }
}
