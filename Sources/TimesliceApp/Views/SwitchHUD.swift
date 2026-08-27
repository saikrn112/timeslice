import AppKit
import SwiftUI
import TimesliceCore

/// Center-screen HUD for the global task switcher. While cycling (holding fn+⌘+⇧, tapping \)
/// it shows the task list as a "revolver" with the selected task centered and highlighted and
/// neighbors dimmed above/below. On commit it shows a compact confirmation.
@MainActor
final class SwitchHUD {
    private var window: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    /// Built once and reused. A fresh `NSHostingView` per show meant every invocation — and every
    /// cycle keystroke — paid SwiftUI tree construction and a first layout pass, which is the bulk
    /// of the delay before the HUD appears.
    private var hosting: NSHostingView<AnyView>?

    /// Show the revolver list while cycling. Stays up (no auto-dismiss) until commit/hide.
    /// `todaySeconds` maps task id → today's committed seconds. `runningID`/`clock` let the
    /// currently-running task tick live and render green while you keep selecting.
    func showSwitcher(tasks: [Project], selectedID: Int64?, todaySeconds: [Int64: TimeInterval],
                      runningID: Int64?, clock: TickClock,
                      displayColor: ((Int64) -> String)? = nil,
                      groupName: ((Int64) -> String?)? = nil) {
        dismissWorkItem?.cancel()
        let view = SwitcherList(tasks: tasks, selectedID: selectedID, todaySeconds: todaySeconds,
                                runningID: runningID, clock: clock,
                                displayColor: displayColor, groupName: groupName)
        present(AnyView(view), size: switcherSize(count: tasks.count))
    }

    /// Show a brief confirmation of the committed task, then auto-dismiss.
    func showCommitted(text: String, colorHex: String, running: Bool) {
        let view = CommittedHUD(text: text, colorHex: colorHex, running: running)
        present(AnyView(view), size: NSSize(width: 260, height: 90))
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func hide() {
        window?.orderOut(nil)
    }

    // MARK: - Presentation

    private func switcherSize(count: Int) -> NSSize {
        // Rows stay a fixed height; when there are more tasks than fit, the list windows around
        // the selection and we add room for the "N more" hints above/below.
        let cap = SwitcherList.maxVisibleRows
        let rows = min(max(count, 1), cap)
        let hintRows = count > cap ? 2 : 0
        return NSSize(width: 440, height: CGFloat(rows) * 44 + CGFloat(hintRows) * 16 + 58)
    }

    private func present(_ view: AnyView, size: NSSize) {
        let panel = window ?? makePanel()
        window = panel
        if let hosting {
            // Swapping rootView reuses the existing view tree and its layout.
            hosting.rootView = view
            panel.setContentSize(size)
        } else {
            let h = NSHostingView(rootView: view)
            h.frame = NSRect(origin: .zero, size: size)
            h.autoresizingMask = [.width, .height]
            hosting = h
            panel.setContentSize(size)
            panel.contentView = h
        }
        center(panel)
        panel.orderFrontRegardless()
    }

    /// Build the panel and its SwiftUI hierarchy ahead of time, so the first hotkey press doesn't
    /// pay for it. Cheap: nothing is ordered front, so nothing appears on screen.
    func prewarm() {
        guard window == nil else { return }
        let panel = makePanel()
        window = panel
        let size = switcherSize(count: 1)
        let h = NSHostingView(rootView: AnyView(EmptyView()))
        h.frame = NSRect(origin: .zero, size: size)
        h.autoresizingMask = [.width, .height]
        hosting = h
        panel.setContentSize(size)
        panel.contentView = h
        // Force the hierarchy to lay out now rather than on first show.
        h.layoutSubtreeIfNeeded()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Normally excluded from screen capture (it names tasks); in demo mode leave it visible
        // so the switcher can be screen-recorded for the README.
        panel.sharingType = ProcessInfo.processInfo.environment["TIMESLICE_SEED_DEMO"] == "1" ? .readOnly : .none
        return panel
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2
        ))
    }
}

/// Revolver-style vertical task list; the selected task is centered, bright, and scaled up.
/// The currently-running task shows a live, green, ticking time while you keep selecting.
private struct SwitcherList: View {
    let tasks: [Project]
    let selectedID: Int64?
    let todaySeconds: [Int64: TimeInterval]
    let runningID: Int64?
    @ObservedObject var clock: TickClock
    /// Project shade + short project label; nil-safe so the HUD works without grouping.
    var displayColor: ((Int64) -> String)?
    var groupName: ((Int64) -> String?)?

    /// Max rows drawn at once. With more tasks than this we window around the selection so rows
    /// stay full-size and readable instead of squashing to fit a fixed-height panel.
    static let maxVisibleRows = 8

    private func liveSeconds(for id: Int64) -> TimeInterval {
        let base = todaySeconds[id] ?? 0
        return id == runningID ? base + clock.elapsed : base
    }

    /// A window of tasks centered on the selection (clamped at the ends), plus how many are
    /// hidden above/below so we can hint at them.
    private var windowed: (tasks: [Project], hiddenAbove: Int, hiddenBelow: Int) {
        let cap = Self.maxVisibleRows
        guard tasks.count > cap else { return (tasks, 0, 0) }
        let selIndex = tasks.firstIndex { $0.id == selectedID } ?? 0
        var start = selIndex - cap / 2
        start = max(0, min(start, tasks.count - cap))
        let slice = Array(tasks[start..<(start + cap)])
        return (slice, start, tasks.count - (start + cap))
    }

    var body: some View {
        let win = windowed
        return VStack(spacing: 5) {
            if win.hiddenAbove > 0 {
                Text("▲ \(win.hiddenAbove) more")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
            ForEach(win.tasks) { task in
                let isSel = task.id == selectedID
                let isRunning = task.id == runningID
                let hex = displayColor?(task.id) ?? task.colorHex
                HStack(spacing: 11) {
                    // Always the task's own color (green is reserved for the live dot + timer).
                    Circle().fill(Color(hex: hex))
                        .frame(width: isSel ? 12 : 10, height: isSel ? 12 : 10)
                        .shadow(color: Color(hex: hex).opacity(isSel ? 0.6 : 0), radius: 4)
                    Text(task.name)
                        .font(.system(size: isSel ? 17 : 14, weight: isSel ? .bold : .medium, design: .rounded))
                        .foregroundStyle(isSel ? Color.white : Color.white.opacity(0.55))
                        .lineLimit(1)
                    if let group = groupName?(task.id) {
                        Text(group)
                            .font(.system(size: isSel ? 11 : 10))
                            .foregroundStyle(.white.opacity(isSel ? 0.6 : 0.35))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.10)))
                            .lineLimit(1)
                    }
                    if isRunning {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
                    }
                    Spacer(minLength: 12)
                    // Seconds resolution (no ms) — smoother to read while cycling.
                    Text(Format.duration(liveSeconds(for: task.id)))
                        .font(.system(size: isSel ? 14 : 12, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(isRunning ? Color.green : (isSel ? Color.white.opacity(0.9) : Color.white.opacity(0.4)))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSel ? Color.accentColor : Color.clear)
                        .shadow(color: isSel ? Color.accentColor.opacity(0.5) : .clear, radius: 8)
                )
            }
            if win.hiddenBelow > 0 {
                Text("▼ \(win.hiddenBelow) more")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 26)   // clearance for the hint overlay at the bottom
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                // Dark panel at 90% opacity (10% transparent) so white text reads bright.
                .fill(Color.black.opacity(0.90))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .overlay(alignment: .bottom) {
            Text("hold fn⌘⇧ · \\ next · ] prev · release to start")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.5))
                .padding(.bottom, 7)
        }
    }
}

private struct CommittedHUD: View {
    let text: String
    let colorHex: String
    let running: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(hex: colorHex)).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(running ? "Tracking" : "Stopped").font(.caption).foregroundStyle(.secondary)
                Text(text).font(.title3).fontWeight(.semibold).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: running ? "play.circle.fill" : "pause.circle.fill")
                .font(.title2).foregroundStyle(running ? .green : .secondary)
        }
        .padding(16)
        .frame(width: 260, height: 90)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
