import AppKit
import TimesliceUI
import SwiftUI
import TimesliceCore

/// Spotlight-style task palette (fn+⌘+⇧+A). Type to fuzzy-search your tasks — active and
/// finished, but not archived — and Return acts on the highlighted row: resuming an existing task
/// (un-finishing it as needed) or creating a new one from the last row. This is how you pick a
/// task back up later without making a duplicate.
@MainActor
final class QuickAddPanel {
    private var window: NSPanel?
    /// Reused across shows — see the note in SwitchHUD: rebuilding the hosting view each time was
    /// the main cost before the palette appeared.
    private var hosting: NSHostingView<AnyView>?

    /// `onResume(id)` starts an existing task; `onCreate(name, group)` makes a new one, in
    /// `group` when a `/project` token was typed.
    /// `todaySeconds(id)` supplies the time shown on the right of each row.
    func show(search: @escaping (String) -> [TaskMatch],
              todaySeconds: @escaping (Int64) -> TimeInterval,
              onResume: @escaping (Int64) -> Void,
              onCreate: @escaping (String, String?) -> Void,
              groups: @escaping () -> [TaskProject],
              displayColor: @escaping (Int64) -> String,
              groupName: @escaping (Int64) -> String?) {
        let content = PaletteView(
            search: search,
            todaySeconds: todaySeconds,
            onResume: { [weak self] id in self?.close(); onResume(id) },
            onCreate: { [weak self] name, group in self?.close(); onCreate(name, group) },
            groups: groups,
            displayColor: displayColor,
            groupName: groupName,
            onCancel: { [weak self] in self?.close() }
        )
        let panel = window ?? makePanel()
        window = panel
        if let hosting {
            hosting.rootView = AnyView(content)
        } else {
            let h = NSHostingView(rootView: AnyView(content))
            h.frame = NSRect(x: 0, y: 0, width: 460, height: 340)
            h.autoresizingMask = [.width, .height]
            hosting = h
            panel.contentView = h
        }
        center(panel)

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

    /// Build the panel and its SwiftUI hierarchy up front so the first fn+⌘+⇧+A doesn't pay for it.
    func prewarm() {
        guard window == nil else { return }
        let panel = makePanel()
        window = panel
        let h = NSHostingView(rootView: AnyView(EmptyView()))
        h.frame = NSRect(x: 0, y: 0, width: 460, height: 340)
        h.autoresizingMask = [.width, .height]
        hosting = h
        panel.contentView = h
        h.layoutSubtreeIfNeeded()
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
    let onCreate: (String, String?) -> Void
    let groups: () -> [TaskProject]
    /// Colour a task renders in (project shade, or its own in Inbox).
    let displayColor: (Int64) -> String
    /// Short project label, nil for Inbox.
    let groupName: (Int64) -> String?
    let onCancel: () -> Void

    @State private var query = ""
    @State private var matches: [TaskMatch] = []
    @State private var selection = 0          // index into rows (matches + optional create row)
    /// True while the arrow keys own the selection, so hover can't hijack it as rows scroll
    /// beneath a stationary pointer. Reset by any genuine pointer movement.
    @State private var keyboardDriving = false
    /// Destination for the Create row, cycled with Tab: nil = Inbox, otherwise an index into `groups()`.
    ///
    /// Separate from the `/token` in the query, and the token wins when present — typing a destination is
    /// explicit, and having Tab silently override what you typed would be worse than it having no effect.
    @State private var groupCycle: Int?
    @FocusState private var focused: Bool

    /// The query split into task name + optional /group token.
    private var parsed: ParsedQuery { TaskSearch.parse(query) }

    /// Groups to offer while a `/token` is being typed.
    private var groupSuggestions: [TaskProject] {
        guard let token = parsed.groupToken else { return [] }
        return TaskSearch.rankGroups(token: token, groups: groups())
    }

    /// Show a "Create …" row unless the query exactly matches an existing task.
    private var showsCreateRow: Bool {
        let q = parsed.name
        guard !q.isEmpty else { return false }
        // A duplicate only blocks Create if it's in the SAME project you're filing into. Comparing
        // names alone meant "meetings /profiling" was refused because a `meetings` existed under
        // `job chores` — two different tasks, and the store already allows them.
        if let token = parsed.groupToken, !token.isEmpty {
            guard let target = groups().first(where: {
                $0.name.caseInsensitiveCompare(token) == .orderedSame
            }) else {
                // Naming a project that doesn't exist yet: it has no tasks, so nothing can clash.
                return true
            }
            return !matches.contains {
                $0.project.name.caseInsensitiveCompare(q) == .orderedSame
                    && $0.project.taskProjectID == target.id
            }
        }
        // No token → filing into Inbox, so only an Inbox task of that name is a duplicate.
        return !matches.contains {
            $0.project.name.caseInsensitiveCompare(q) == .orderedSame
                && $0.project.taskProjectID == nil
        }
    }
    private var rowCount: Int { matches.count + (showsCreateRow ? 1 : 0) }

    /// "Create “x” in /group" — always naming the destination, including Inbox.
    ///
    /// It used to say nothing when filing into Inbox, which was fine when Inbox was the only silent case.
    /// Now that Tab cycles the destination, a label that sometimes omits it would hide the thing Tab
    /// changes.
    private var createRowLabel: String {
        let base = "Create “\(parsed.name)”"
        guard let destination = createDestination else { return "\(base) in Inbox" }
        return "\(base) in /\(destination)"
    }

    /// Where the Create row would file the task: the typed `/token` if there is one, else whatever Tab has
    /// cycled to, else Inbox. One definition, so the label can't promise a different destination from the
    /// one that gets used.
    private var createDestination: String? {
        if let token = parsed.groupToken, !token.isEmpty {
            // A partial token resolves to the best matching existing group; otherwise it's a new group by
            // that literal name.
            return groupSuggestions.first?.name ?? token
        }
        guard let i = groupCycle else { return nil }
        let all = groups()
        guard i >= 0 && i < all.count else { return nil }
        return all[i].name
    }

    private func commitCreate() {
        guard !parsed.name.isEmpty else { return }
        onCreate(parsed.name, createDestination)
    }

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
            // Fresh every time the palette opens: a destination remembered from the last task you created
            // would file the next one somewhere you never chose.
            groupCycle = nil
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
                    // Match on the name only — the /group token isn't part of any task name.
                    matches = search(TaskSearch.parse(q).name)
                    selection = 0
                }
                .onSubmit(activateSelection)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                // Esc: a TextField normally swallows this (AppKit treats it as "clear field"),
                // so handle it explicitly here rather than relying on onExitCommand.
                .onKeyPress(.escape) { onCancel(); return .handled }
                // Tab reaches the Create row without arrowing past every match — with a long match list
                // that was the whole cost of creating a task. Once there, Tab keeps going and cycles the
                // destination project, so "new task, in that project" is Tab-Tab rather than typing a
                // /token. Deliberately NOT the arrow keys: ← → and ⌥← ⌥→ belong to editing the name.
                // ONE handler, reading the modifier itself: two `.onKeyPress(.tab)` handlers would both
                // see Shift-Tab and fight over it.
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    tab(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
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
                                color: Color(hex: displayColor(m.project.id)),
                                name: m.project.name,
                                badge: statusBadge(m.project),
                                selected: idx == selection,
                                time: todaySeconds(m.project.id),
                                group: groupName(m.project.id)
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
            if let token = parsed.groupToken, !groupSuggestions.isEmpty {
                Divider().opacity(0.25)
                HStack(spacing: 6) {
                    Text("/").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    ForEach(groupSuggestions.prefix(4)) { g in
                        HStack(spacing: 4) {
                            Circle().fill(Color(hex: g.colorHex)).frame(width: 6, height: 6)
                            Text(g.name).font(.system(size: 11))
                                // The first suggestion is the one Return will use.
                                .foregroundStyle(g.id == groupSuggestions.first?.id
                                                 ? Color.primary : Color.secondary)
                        }
                    }
                    if token.isEmpty && groupSuggestions.count > 4 {
                        Text("+\(groupSuggestions.count - 4)")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
            } else if showsCreateRow {
                // The destinations Tab walks, with the current one picked out. Showing them all means
                // cycling is a visible choice from a list rather than a guess about what comes next.
                Divider().opacity(0.25)
                destinationStrip
            }
            if showsCreateRow {
                Divider().opacity(0.25)
                let idx = matches.count
                row(
                    color: .green,
                    name: createRowLabel,
                    badge: nil,
                    selected: idx == selection,
                    systemImage: "plus.circle.fill"
                )
                .padding(.horizontal, 8).padding(.vertical, 6)
                .onTapGesture { commitCreate() }
                .onHover { if $0 { selection = idx } }
            }
        }
    }

    /// Inbox plus every group, scrolled horizontally, with the Tab destination highlighted.
    private var destinationStrip: some View {
        let all = groups()
        return ScrollViewReader { sp in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(name: "Inbox", color: .gray, active: groupCycle == nil).id(-1)
                    ForEach(Array(all.enumerated()), id: \.element.id) { idx, g in
                        chip(name: g.name, color: Color(hex: g.colorHex), active: groupCycle == idx)
                            .id(idx)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
            }
            // Keep the chosen one on screen: with a dozen projects, Tab would otherwise cycle to
            // something sitting off the right edge.
            .onChange(of: groupCycle) { _, new in sp.scrollTo(new ?? -1) }
        }
        .frame(height: 26)
    }

    private func chip(name: String, color: Color, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11))
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.45))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(active ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.06)))
    }

    private func row(color: Color, name: String, badge: (String, Color)?, selected: Bool,
                     time: TimeInterval? = nil, systemImage: String? = nil,
                     group: String? = nil) -> some View {
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
            if let group {
                Text(group)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.10)))
                    .lineLimit(1)
            }
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
            hint("⇥", selection < matches.count || !showsCreateRow ? "create row" : "project")
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

    /// Tab forward: jump to the Create row, then cycle its destination. Shift-Tab reverses, and from
    /// Inbox it steps back into the match list rather than dead-ending. The stepping itself lives in
    /// `PaletteNav` so it can be tested — a human pressing Tab is the only other way to exercise it.
    private func tab(_ delta: Int) {
        keyboardDriving = true
        let next = PaletteNav.tab(from: .init(selection: selection, groupCycle: groupCycle),
                                  delta: delta, matchCount: matches.count,
                                  showsCreateRow: showsCreateRow, groupCount: groups().count)
        selection = next.selection
        groupCycle = next.groupCycle
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
            commitCreate()
        }
    }
}
