import SwiftUI
import TimesliceCore
import TimesliceUI

/// The task list: search, project sections, tap to start/pause, swipe for lifecycle.
///
/// Ordering, ranking and colours all come from `TimesliceCore` (`TaskOrdering`, `TaskSearch`,
/// `Palette`) so this screen agrees with the Mac by construction rather than by coincidence.
struct TasksView: View {
    @ObservedObject private var model = TimerModel.shared
    @State private var query = ""
    @State private var showingAdd = false
    @State private var newTaskName = ""
    @State private var editing: Project?
    @State private var showArchived = false
    @State private var mode: Mode = .recent

    /// Two orderings of the same task list. See the switch in `body` for why this is a mode rather
    /// than two stacked sections.
    private enum Mode: String, CaseIterable, Identifiable {
        case recent = "Recent"
        case projects = "Projects"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }

                if model.tasks.isEmpty && model.archivedTasks.isEmpty {
                    ContentUnavailableView(
                        "No tasks yet", systemImage: "timer",
                        description: Text("Add a task, then assign the Action Button to "
                                          + "“Toggle Timeslice Timer” in Settings."))
                } else if !query.isEmpty {
                    searchSection
                } else {
                    // Two ORDERINGS of one list, not a Recent section above the projects: with only
                    // a handful of tasks a "Recent" section repeats nearly every row below it, and
                    // the duplication reads as a bug. Recency is the default because switching fast
                    // is what the phone is for (§3.5); Projects is for filing and reviewing (§3.2).
                    switch mode {
                    case .recent:
                        Section {
                            ForEach(model.recencyOrdered, id: \.id) { row($0) }
                        } footer: {
                            Text("Most recently worked first — the same order the Action Button "
                                 + "wheel uses.")
                        }
                    case .projects:
                        ForEach(model.sections) { section in
                            Section {
                                ForEach(section.tasks, id: \.id) { row($0) }
                            } header: {
                                sectionHeader(section)
                            }
                        }
                    }
                    archivedSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Timeslice")
            // `/project` filing works here too, because the query goes through TaskSearch.parse.
            .searchable(text: $query, prompt: "Search tasks or /project")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Hidden while searching: results have their own ranking, so offering an
                    // ordering control that does nothing would be a lie.
                    if query.isEmpty {
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
                if model.currentTaskID != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Stop", role: .destructive) { model.stop() }
                    }
                }
            }
            .alert("New task", isPresented: $showingAdd) {
                TextField("Name, or name /project", text: $newTaskName)
                Button("Add") {
                    model.addTask(named: newTaskName)
                    newTaskName = ""
                }
                Button("Cancel", role: .cancel) { newTaskName = "" }
            } message: {
                Text("Adding “/project” files it into that project, creating it if needed.")
            }
            .sheet(item: $editing) { TaskDetailSheet(task: $0) }
            .refreshable { model.reload() }
        }
    }

    // MARK: - Pieces

    private var searchSection: some View {
        Section("Results") {
            let results = model.searchResults(query)
            if results.isEmpty {
                Text("No matches").foregroundStyle(.secondary)
            } else {
                ForEach(results) { row($0.project) }
            }
        }
    }

    @ViewBuilder
    private var archivedSection: some View {
        if !model.archivedTasks.isEmpty {
            Section {
                if showArchived {
                    ForEach(model.archivedTasks, id: \.id) { task in
                        HStack {
                            Circle().fill(Color(hex: model.colorHex(for: task)).opacity(0.5))
                                .frame(width: 9, height: 9)
                            Text(task.name).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.compact(model.committedAllTimeSeconds[task.id] ?? 0))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .swipeActions {
                            Button("Restore") { model.setArchived(taskID: task.id, false) }
                                .tint(.blue)
                        }
                    }
                }
            } header: {
                Button {
                    withAnimation { showArchived.toggle() }
                } label: {
                    HStack {
                        Text("Archived (\(model.archivedTasks.count))")
                        Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionHeader(_ section: TimerModel.Section) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: section.colorHex)).frame(width: 7, height: 7)
            Text(section.name)
            // Tags sit on the PROJECT (tasks inherit), so the chips belong on this header.
            if let gid = section.group?.id, let tags = model.tagsByGroup[gid] {
                ForEach(tags) { tag in
                    Text(tag.name)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color(hex: tag.colorHex).opacity(0.22), in: Capsule())
                }
            }
            Spacer()
            Text(Format.compact(sectionSeconds(section)))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// Sum of the section's committed today seconds. Plain addition of values Core produced — no
    /// aggregation logic re-implemented here.
    private func sectionSeconds(_ section: TimerModel.Section) -> TimeInterval {
        section.tasks.reduce(0) { $0 + (model.committedTodaySeconds[$1.id] ?? 0) }
    }

    private func row(_ task: Project) -> some View {
        TaskRow(task: task,
                colorHex: model.colorHex(for: task),
                committedSeconds: model.committedTodaySeconds[task.id] ?? 0,
                liveOrigin: model.liveOrigin(for: task.id),
                isCurrent: model.currentTaskID == task.id)
            .contentShape(Rectangle())
            .onTapGesture { model.toggle(taskID: task.id) }
            .swipeActions(edge: .trailing) {
                Button("Archive", systemImage: "archivebox") {
                    model.setArchived(taskID: task.id, true)
                }
                .tint(.orange)
                Button(task.finished ? "Resume" : "Finish",
                       systemImage: task.finished ? "arrow.uturn.backward" : "checkmark") {
                    model.setFinished(taskID: task.id, !task.finished)
                }
                .tint(.green)
            }
            .swipeActions(edge: .leading) {
                Button("Edit", systemImage: "pencil") { editing = task }.tint(.gray)
            }
    }
}

/// One task row. Time semantics are the load-bearing part — see `liveOrigin`.
struct TaskRow: View {
    let task: Project
    let colorHex: String
    /// Today's seconds from closed intervals. The live run is added by `liveOrigin`, not by this.
    let committedSeconds: TimeInterval
    /// Non-nil only for the running task: the backdated instant to tick today's total from.
    let liveOrigin: Date?
    let isCurrent: Bool

    private var isRunning: Bool { liveOrigin != nil }

    var body: some View {
        HStack(spacing: 10) {
            // The same swatch colour the Dynamic Island and the Mac timeline use.
            Circle()
                .fill(Color(hex: colorHex))
                .frame(width: 11, height: 11)
                .overlay {
                    if isRunning {
                        Circle().stroke(Color(hex: colorHex).opacity(0.45), lineWidth: 5)
                    }
                }

            Text(task.name)
                .fontWeight(isCurrent ? .semibold : .regular)
                .strikethrough(task.finished)
                .foregroundStyle(task.finished ? .secondary : .primary)
                .lineLimit(1)

            Spacer()

            if let liveOrigin {
                // TODAY'S TOTAL, ticking — committed base plus the live run, which is what the Mac
                // shows. Counting from the run's own start instead would make this number collapse
                // to zero on every task switch, reading as a reset rather than a context switch.
                Text(timerInterval: liveOrigin...Date.distantFuture,
                     pauseTime: nil, countsDown: false)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color(hex: colorHex))
            } else {
                Text(Format.compact(committedSeconds))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(committedSeconds > 0 ? .primary : .tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// `sheet(item:)` needs Identifiable; Project already is, this just adapts the optional binding.
private extension View {
    func sheet<Item: Identifiable, C: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C
    ) -> some View {
        sheet(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } })) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}
