import SwiftUI
import TimesliceCore
import TimesliceUI

/// The task palette: type, see what already exists, tap to start — or create.
///
/// Replaces a one-field `.alert` whose placeholder read "Name, or name /project". Two things were wrong
/// with that, and they compound:
///
/// 1. **It showed nothing.** The Mac's `fn+⌘+⇧+A` palette lists matching tasks as you type, so the
///    common case — "start the thing I already have" — is one gesture. The alert couldn't list anything,
///    so on the phone the only way to reach an existing task was to dismiss and scroll the list.
/// 2. **`/project` as the filing mechanism.** Typing punctuation to express structure is a
///    keyboard-first idiom; it is undiscoverable on a phone, unforgiving of typos, and creates a project
///    on a mistyped token. A picker can't be typo'd.
///
/// The ranking is `TaskSearch` from Core via `model.searchResults` — the same fuzzy, status-tiered order
/// the Mac's palette uses, including matching a task by its project's name. Nothing about search is
/// reimplemented here; this file is the phone's presentation of it.
///
/// `/project` still WORKS, because `addTask` and `searchResults` both parse it and the Mac relies on it.
/// It's simply no longer advertised or required.
struct AddTaskSheet: View {
    @ObservedObject private var model = TimerModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// Project to file a NEW task into. Nil is Inbox, which is also what the Mac does with no `/token`.
    @State private var groupID: Int64?
    @FocusState private var focused: Bool

    private var matches: [TaskMatch] { model.searchResults(query, limit: 30) }

    private var trimmed: String {
        TaskSearch.parse(query).name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Offer "Create" unless the text exactly names something that already exists — otherwise the
    /// palette invites you to make a duplicate of the row directly above it.
    private var showsCreate: Bool {
        guard !trimmed.isEmpty else { return false }
        return !matches.contains { $0.project.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                Divider()
                List {
                    if showsCreate { createSection }
                    if !matches.isEmpty { matchSection }
                    if matches.isEmpty && !showsCreate { emptyRow }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        // Opens with the keyboard up: the sheet exists to be typed into, and a manual tap on the field
        // is a gesture the sheet already knows you want.
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search or create a task", text: $query)
                .font(Theme.rowTitle)
                .focused($focused)
                .submitLabel(.go)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // Enter does the obvious thing: start the top match, or create when there isn't one.
                // Same rule as the Mac palette's ↵.
                .onSubmit { if let first = matches.first { start(first.project) } else { create() } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Create

    @ViewBuilder
    private var createSection: some View {
        Section {
            Button { create() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Create “\(trimmed)”").font(Theme.rowTitle)
                        Text(groupID == nil ? "in Inbox" : "in \(groupName(groupID) ?? "")")
                            .font(Theme.captionSmall).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // A picker, not typed punctuation. Creating a project is an explicit choice here rather
            // than a side effect of a token the parser didn't recognise.
            Picker("Project", selection: $groupID) {
                Text("Inbox").tag(Int64?.none)
                ForEach(model.groups) { g in
                    Text(g.name).tag(Int64?.some(g.id))
                }
            }
            .font(Theme.caption)
        }
    }

    // MARK: - Matches

    @ViewBuilder
    private var matchSection: some View {
        Section {
            ForEach(matches) { m in
                Button { start(m.project) } label: { matchRow(m.project) }
                    .buttonStyle(.plain)
            }
        } header: {
            Text(query.isEmpty ? "Recent" : "Matches").font(Theme.captionSmall)
        }
    }

    private func matchRow(_ task: Project) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color(hex: model.colorHex(for: task)))
                .frame(width: Theme.dot, height: Theme.dot)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name)
                    .font(Theme.rowTitle)
                    .foregroundStyle(task.finished ? .secondary : .primary)
                    .lineLimit(1)
                if let name = groupName(task.taskProjectID) {
                    Text(name).font(Theme.captionSmall).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            // The task's own time today, so the palette answers "have I already been on this?" without
            // going back to the list.
            if let secs = model.committedTodaySeconds[task.id], secs > 0 {
                Text(Format.compact(secs))
                    .font(Theme.rowTime)
                    .foregroundStyle(.secondary)
            }
            if model.currentTaskID == task.id {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "play.circle").foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyRow: some View {
        Text("No tasks yet — type a name to create one")
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func groupName(_ id: Int64?) -> String? {
        guard let id else { return nil }
        return model.groups.first { $0.id == id }?.name
    }

    /// Tapping a match STARTS it. The palette's whole point is getting a timer running in one gesture;
    /// opening an editor instead would make the common case the slow one.
    private func start(_ task: Project) {
        model.toggle(taskID: task.id)
        dismiss()
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        if let id = model.addTask(named: query, inGroup: groupID) {
            // Start it immediately: you typed a task name into a time tracker.
            model.toggle(taskID: id)
        }
        dismiss()
    }
}
