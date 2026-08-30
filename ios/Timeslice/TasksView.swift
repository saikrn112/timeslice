import SwiftUI
import TimesliceCore
import TimesliceUI

/// The task list. Dense on purpose: this is scanned, not read.
///
/// Styling follows the Mac — 14pt titles, a 9pt colour dot, monospaced times, semantic greys for all
/// chrome, and each task's own colour as the only saturated thing in a row. The earlier version used
/// stock `.insetGrouped` with 17pt body type, which is why it read as oversized and unrelated to the
/// Mac app.
///
/// `Today · All Time` mirrors the Mac's plain-text scope toggle rather than a segmented control.
struct TasksView: View {
    @ObservedObject private var model = TimerModel.shared
    @State private var query = ""
    @State private var showingAdd = false
    @State private var newTaskName = ""
    @State private var editing: Project?
    @State private var showArchived = false
    @State private var scope: TimeScope = .today
    @State private var grouped = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = model.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Theme.caption).foregroundStyle(.red).padding(.bottom, 6)
                    }
                    controlRow
                    if model.tasks.isEmpty && model.archivedTasks.isEmpty {
                        empty
                    } else if !query.isEmpty {
                        card { rows(model.searchResults(query).map(\.project)) }
                    } else if grouped {
                        ForEach(model.sections) { section in
                            groupHeader(section)
                            card { rows(section.tasks) }
                        }
                    } else {
                        card { rows(model.recencyOrdered) }
                    }
                    archived
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // iOS 26's tab bar FLOATS over the content. With only a handful of rows nothing
                // reached that far and it looked fine; at 34 tasks the last rows sat permanently
                // underneath it. Reserve its height so the list can always be scrolled clear.
                .padding(.bottom, 56)
            }
            .background(Theme.page)
            .navigationTitle("Timeslice")
            .searchable(text: $query, prompt: "Search tasks or /project")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // The switcher had NO in-app entry point before — it was reachable only by an
                    // Action Button press or a Shortcut, so on a phone with neither it may as well
                    // not have existed.
                    Button { model.requestSwitcher() } label: {
                        Image(systemName: "arrow.triangle.swap")
                    }
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if model.currentTaskID != nil {
                        Button("Stop") { model.stop() }.font(Theme.caption)
                    }
                }
            }
            .alert("New task", isPresented: $showingAdd) {
                TextField("Name, or name /project", text: $newTaskName)
                Button("Add") { model.addTask(named: newTaskName); newTaskName = "" }
                Button("Cancel", role: .cancel) { newTaskName = "" }
            } message: {
                Text("“/project” files it into that project, creating it if needed.")
            }
            .sheet(item: $editing) { TaskDetailSheet(task: $0) }
        }
    }

    // MARK: - Controls

    /// One low-chrome row: scope on the left, grouping on the right — the Mac's arrangement, where
    /// these are plain text buttons rather than control blocks.
    private var controlRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(TimeScope.allCases.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Text("·").font(Theme.caption).foregroundStyle(.tertiary) }
                Button { scope = s } label: {
                    Text(s.rawValue)
                        .font(.system(size: 12, weight: scope == s ? .semibold : .regular))
                        .foregroundStyle(scope == s ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { grouped.toggle() } label: {
                Label(grouped ? "Projects" : "Recent",
                      systemImage: grouped ? "folder" : "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No tasks yet").font(Theme.rowTitleStrong)
            Text("Add one with +, then bind the Action Button in Settings.")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, Theme.cardPadding)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.card))
            .padding(.bottom, 10)
    }

    private func rows(_ tasks: [Project]) -> some View {
        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
            TaskRow(task: task,
                    colorHex: model.colorHex(for: task),
                    seconds: seconds(for: task),
                    liveOrigin: liveOrigin(for: task),
                    isCurrent: model.currentTaskID == task.id)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(taskID: task.id) }
                .onLongPressGesture { editing = task }
            if index < tasks.count - 1 { Divider() }
        }
    }

    /// Today or All Time, matching the Mac's scope toggle.
    private func seconds(for task: Project) -> TimeInterval {
        scope == .today
            ? (model.committedTodaySeconds[task.id] ?? 0)
            : (model.committedAllTimeSeconds[task.id] ?? 0)
    }

    /// A live clock only makes sense against Today's figure; on All Time the running seconds are a
    /// rounding error on a total measured in days, and ticking it implied the two scopes were the
    /// same number.
    private func liveOrigin(for task: Project) -> Date? {
        scope == .today ? model.liveOrigin(for: task.id) : nil
    }

    private func groupHeader(_ section: TimerModel.Section) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: section.colorHex)).frame(width: 6, height: 6)
            Text(section.name).font(Theme.sectionHeader)
            if let gid = section.group?.id, let tags = model.tagsByGroup[gid] {
                ForEach(tags) { tag in
                    Text(tag.name)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color(hex: tag.colorHex).opacity(0.22), in: Capsule())
                }
            }
            Spacer()
            Text(Format.compact(section.tasks.reduce(0) { $0 + seconds(for: $1) }))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var archived: some View {
        if !model.archivedTasks.isEmpty {
            Button { withAnimation { showArchived.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("Archived (\(model.archivedTasks.count))").font(Theme.sectionHeader)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)

            if showArchived {
                card {
                    ForEach(Array(model.archivedTasks.enumerated()), id: \.element.id) { i, task in
                        HStack(spacing: Theme.rowSpacing) {
                            Circle().fill(Color(hex: model.colorHex(for: task)).opacity(0.5))
                                .frame(width: Theme.dot, height: Theme.dot)
                            Text(task.name).font(Theme.rowTitle).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.compact(model.committedAllTimeSeconds[task.id] ?? 0))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Button { model.setArchived(taskID: task.id, false) } label: {
                                Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, Theme.rowVPadding)
                        if i < model.archivedTasks.count - 1 { Divider() }
                    }
                }
            }
        }
    }
}

/// One task row, at the Mac's density.
struct TaskRow: View {
    let task: Project
    let colorHex: String
    /// Committed seconds for the active scope. The live run is added by `liveOrigin`, not this.
    let seconds: TimeInterval
    /// Non-nil only for the running task: the backdated instant to tick today's total from.
    let liveOrigin: Date?
    let isCurrent: Bool

    private var isRunning: Bool { liveOrigin != nil }

    var body: some View {
        HStack(spacing: Theme.rowSpacing) {
            Circle()
                .fill(Color(hex: colorHex).opacity(task.finished ? 0.5 : 1))
                .frame(width: Theme.dot, height: Theme.dot)
                .overlay {
                    if isRunning {
                        Circle().stroke(Color(hex: colorHex).opacity(0.4), lineWidth: 4)
                    }
                }

            Text(task.name)
                .font(isCurrent ? Theme.rowTitleStrong : Theme.rowTitle)
                .strikethrough(task.finished)
                .foregroundStyle(task.finished ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if let liveOrigin {
                // TODAY'S TOTAL, ticking — committed base plus the live run, as the Mac shows.
                // Counting from the run's own start would collapse to zero on every switch.
                Text(timerInterval: liveOrigin...Date.distantFuture,
                     pauseTime: nil, countsDown: false)
                    .font(Theme.rowTime)
                    .foregroundStyle(Color(hex: colorHex))
            } else {
                Text(Format.compact(seconds))
                    .font(Theme.rowTime)
                    .foregroundStyle(seconds > 0 ? .primary : .tertiary)
            }
        }
        .padding(.vertical, Theme.rowVPadding)
    }
}

/// `sheet(item:)` for an optional Identifiable binding.
extension View {
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
