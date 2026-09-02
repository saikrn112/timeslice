import SwiftUI
import TimesliceCore

/// The popover content: a keyboard-navigable list of tasks with today's time. ↑/↓ move
/// the selection, Space toggles the selected task's timer.
struct QuickPanelView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var engine: TimerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if appState.projects.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { appState.reload() }
        // Key handling (↑/↓/space/esc) is done by StatusBarController's local NSEvent monitor
        // while the popover is shown — more reliable than SwiftUI .onKeyPress in a popover.
    }

    private var header: some View {
        HStack {
            Text("Timeslice").font(.headline)
            Spacer()
            if engine.isRunning {
                LiveTimeText(clock: engine.clock, base: 0, isRunning: true, showMs: true, color: .green)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(10)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(appState.recencyOrderedTodayTotals) { total in
                    row(total)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 320)
    }

    private func row(_ total: ProjectTotal) -> some View {
        let isSelected = appState.selectedProjectID == total.project.id
        let isRunning = engine.runningProjectID == total.project.id
        return HStack(spacing: 8) {
            Circle().fill(Color(hex: total.project.colorHex)).frame(width: 9, height: 9)
            Text(total.project.name).lineLimit(1)
            Spacer()
            LiveTimeText(clock: engine.clock, base: total.seconds, isRunning: isRunning, showMs: isRunning,
                         color: isRunning ? .green : .secondary)
                .font(.system(.body, design: .monospaced))
            Image(systemName: isRunning ? "pause.circle.fill" : "play.circle")
                .foregroundStyle(isRunning ? .green : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedProjectID = total.project.id
            engine.toggle(projectID: total.project.id)
        }
    }

    private var footer: some View {
        HStack {
            Text("↑↓ select · space start/stop").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Open") { NotificationCenter.default.post(name: .openMainWindow, object: nil) }
                .buttonStyle(.link)
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No tasks yet").foregroundStyle(.secondary)
            Button("Add a task") { NotificationCenter.default.post(name: .openMainWindow, object: nil) }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("com.timeslice.openMainWindow")
    /// Asks for the task palette. Posted by the window's + button so it opens the SAME palette the
    /// hotkey does, rather than a second, weaker add form that has to be kept in step.
    static let openTaskPalette = Notification.Name("com.timeslice.openTaskPalette")
    /// Asks for the feedback window. A notification rather than a direct call because the toolbar
    /// button is inside a SwiftUI view, and the window is owned by the AppDelegate — the same route
    /// the palette takes.
    static let openFeedbackWindow = Notification.Name("com.timeslice.openFeedbackWindow")
    /// Asks for an immediate sync. Posted by the feedback window's refresh button, which is used
    /// precisely when something written on another device hasn't arrived yet.
    static let syncNow = Notification.Name("com.timeslice.syncNow")
}
