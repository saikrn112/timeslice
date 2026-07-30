import SwiftUI
import TimesliceCore

/// The main task list. Active tasks (▶/⏸ timer, ✓ finish, 🗑 delete) sit above a collapsible
/// Archived section (↩ resume, 🗑 delete). Keyboard (only when a text field isn't focused):
/// ↑/↓ select, Space start/stop. The running row ticks live with milliseconds.
struct ProjectListView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var engine: TimerEngine

    @State private var newTaskName: String = ""
    @State private var editingID: Int64?
    @State private var editingName: String = ""
    @State private var showArchived: Bool = false
    @State private var pendingDelete: Project?
    @State private var pendingReset: Project?

    private enum Field: Hashable { case list, newTask, rename }
    @FocusState private var focus: Field?

    private var store: IntervalStore { appState.storeForEditing }
    private var isTyping: Bool { focus == .newTask || focus == .rename }

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            addBar
            KeybindingsFooter()
        }
        .focusable()
        .focusEffectDisabled()   // keep keyboard focus, but hide the blue focus-ring bars
        .focused($focus, equals: .list)
        .onAppear { focus = .list }
        .onKeyPress(.upArrow) { guard !isTyping else { return .ignored }; appState.moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { guard !isTyping else { return .ignored }; appState.moveSelection(by: 1); return .handled }
        .onKeyPress(.space) { guard !isTyping else { return .ignored }; appState.toggleSelected(); return .handled }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete task and its time", role: .destructive) {
                if let p = pendingDelete { appState.delete(projectID: p.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently removes the task and all its tracked time.")
        }
        .confirmationDialog(
            "Reset “\(pendingReset?.name ?? "")”?",
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset tracked time", role: .destructive) {
                if let p = pendingReset { appState.reset(projectID: p.id) }
                pendingReset = nil
            }
            Button("Cancel", role: .cancel) { pendingReset = nil }
        } message: {
            Text("This clears all tracked time for the task but keeps the task itself.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(appState.visibleTotals) { total in
                    activeRow(total)
                }
                // Archived tasks only appear in the All-Time view for now (showing them in
                // Today needs more thought).
                if appState.scope == .allTime && !appState.archivedTotals.isEmpty {
                    archivedSection
                }
            }
            .padding(12)
        }
    }

    // MARK: - Active row

    private func activeRow(_ total: ProjectTotal) -> some View {
        let project = total.project
        let isSelected = appState.selectedProjectID == project.id
        let isRunning = engine.runningProjectID == project.id
        let isFinished = project.finished
        return HStack(spacing: 9) {
            Circle().fill(Color(hex: project.colorHex).opacity(isFinished ? 0.5 : 1)).frame(width: 9, height: 9)

            if editingID == project.id {
                TextField("Name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .focused($focus, equals: .rename)
                    .onSubmit { commitRename(project.id) }
                    .onExitCommand { editingID = nil; focus = .list }
            } else {
                Text(project.name)
                    .font(.callout)
                    .fontWeight(isRunning ? .semibold : .regular)
                    .strikethrough(isFinished, color: .secondary)
                    .foregroundStyle(isFinished ? .secondary : .primary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { beginRename(project) }   // double-click to rename in place
            }

            Spacer(minLength: 6)

            // Live ms only for the running row; others show a static value. LiveTimeText
            // observes the clock so only this label re-renders at tick rate.
            LiveTimeText(clock: engine.clock, base: total.seconds, isRunning: isRunning, showMs: isRunning,
                         color: isRunning ? .green : (isFinished ? .secondary : .primary))
                .font(.system(.callout, design: .monospaced))

            // Inline actions, in order: play/pause · reset · finish · archive.
            if !isFinished {
                iconButton(isRunning ? "pause.fill" : "play.fill",
                           tint: isRunning ? .green : .accentColor,
                           help: isRunning ? "Pause" : "Start") {
                    engine.toggle(projectID: project.id)
                }
            }
            iconButton("arrow.counterclockwise", tint: .orange, help: "Reset timer") {
                pendingReset = project
            }
            iconButton(isFinished ? "arrow.uturn.left" : "checkmark",
                       tint: isFinished ? .accentColor : .green,
                       help: isFinished ? "Un-finish" : "Finish") {
                isFinished ? appState.unfinish(projectID: project.id) : appState.finish(projectID: project.id)
            }
            iconButton("archivebox", tint: .secondary, help: "Archive") {
                appState.archive(projectID: project.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground(isSelected: isSelected, isRunning: isRunning))
        .contentShape(Rectangle())
        .onTapGesture { appState.selectedProjectID = project.id }
        .animation(.easeInOut(duration: 0.15), value: isRunning)
        .animation(.easeInOut(duration: 0.15), value: isFinished)
    }

    // MARK: - Archived section

    private var archivedSection: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showArchived.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Archived")
                    Text("\(appState.archivedTotals.count)")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Spacer()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .padding(.horizontal, 4)

            if showArchived {
                ForEach(appState.archivedTotals) { total in
                    archivedRow(total)
                }
            }
        }
    }

    private func archivedRow(_ total: ProjectTotal) -> some View {
        let project = total.project
        return HStack(spacing: 12) {
            Circle().fill(Color(hex: project.colorHex).opacity(0.5)).frame(width: 10, height: 10)
            // Preserve the "done" strike-through if the task was finished before archiving.
            Text(project.name)
                .strikethrough(project.finished, color: .secondary)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Format.duration(total.seconds))
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            iconButton("tray.and.arrow.up", tint: .accentColor, help: "Unarchive") {
                appState.unarchive(projectID: project.id)
            }
            iconButton("trash", tint: .red, help: "Delete permanently") {
                pendingDelete = project
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
    }

    // MARK: - Add bar

    private var addBar: some View {
        HStack {
            TextField("New task…", text: $newTaskName)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .newTask)
                .onSubmit(addTask)
            Button(action: addTask) {
                Label("Add", systemImage: "plus")
            }
            .disabled(newTaskName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    // MARK: - Building blocks

    private func iconButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint.opacity(0.14)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func rowBackground(isSelected: Bool, isRunning: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isRunning ? Color.green.opacity(0.7) : Color.black.opacity(0.04), lineWidth: isRunning ? 1.5 : 0.5)
            )
    }

    // MARK: - Actions

    private func addTask() {
        let name = newTaskName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let index = appState.projects.count
        _ = try? store.createProject(name: name, colorHex: Palette.color(forIndex: index))
        newTaskName = ""
        focus = .newTask
        appState.reload()
    }

    private func beginRename(_ project: Project) {
        editingName = project.name
        editingID = project.id
        focus = .rename
    }

    private func commitRename(_ id: Int64) {
        let name = editingName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { try? store.renameProject(id: id, name: name) }
        editingID = nil
        focus = .list
        appState.reload()
    }
}

/// Ghosted one-line hotkey reference shown under the task list.
struct KeybindingsFooter: View {
    var body: some View {
        HStack(spacing: 14) {
            hint("↑↓", "select")
            hint("space", "start/stop")
            Divider().frame(height: 12)
            hint("fn⌘⇧ + \\\\ / ]", "hold, tap to cycle · release to switch")
            hint("fn⌘⇧A", "new task")
            hint("fn⌘⇧P", "privacy")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
            Text(label)
        }
    }
}
