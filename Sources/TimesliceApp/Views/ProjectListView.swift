import AppKit
import TimesliceUI
import SwiftUI
import TimesliceCore

/// The main task list. Active tasks (▶/⏸ timer, ✓ finish, 🗑 delete) sit above a collapsible
/// Archived section (↩ resume, 🗑 delete). Keyboard (only when a text field isn't focused):
/// ↑/↓ select, Space start/stop. The running row ticks live with milliseconds.
struct ProjectListView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var engine: TimerEngine

    /// Needed because a tag's own colour is painted as TEXT on the group header, and which direction
    /// that colour has to be pushed to stay readable depends on the appearance.
    @Environment(\.colorScheme) private var colorScheme

    @State private var newTaskName: String = ""
    @State private var editingID: Int64?
    @State private var editingName: String = ""
    @State private var showArchived: Bool = false
    @State private var pendingDelete: Project?
    @State private var pendingReset: Project?
    /// Task awaiting a "New project…" name from the prompt sheet. When `selecting` is on this
    /// applies to the whole selection instead of one task.
    @State private var newProjectFor: Project?
    @State private var newProjectName = ""
    /// Creating a project with nothing selected — an empty group you then drag tasks into.
    @State private var creatingEmptyProject = false

    /// Project awaiting a brand-new tag, and the name being typed.
    @State private var taggingProjectID: Int64?
    @State private var newTagName = ""

    /// WhatsApp-forward-style selection mode: tick boxes appear, and an action bar slides in to
    /// assign everything ticked in one go. Off by default so the list stays clean.
    @State private var selecting = false
    @State private var ticked: Set<Int64> = []

    /// Collapsed group ids (-1 = Inbox). Empty by default — everything starts unfolded.
    @State private var collapsed: Set<Int64> = []
    /// Group header being renamed in place.
    @State private var editingGroupID: Int64?
    @State private var editingGroupName = ""
    /// Group a card is currently hovered over during a drag.
    @State private var dropTargetID: Int64?
    /// Row under the pointer, so grip dots only assert themselves on hover.
    @State private var hoveredRowID: Int64?
    /// Group header under the pointer — its bulk actions only appear on hover, keeping the
    /// header uncluttered.
    @State private var hoveredGroupID: Int64?
    /// Project being dragged by its grip, so a drop on another header reorders instead of
    /// trying to move tasks.
    @State private var draggingGroupID: Int64?
    /// True while a task card is being dragged — gates the edge scroll zones so they can't
    /// swallow ordinary pointer events.
    @State private var isDraggingTask = false
    /// A just-created project, kept visible in Today even while empty so it can be dropped onto.
    /// Cleared once it has tasks or the scope changes.
    @State private var justCreatedProjectID: Int64?

    private enum Field: Hashable { case list, rename, renameGroup, newProject }
    @FocusState private var focus: Field?

    private var store: IntervalStore { appState.storeForEditing }
    /// Any in-place text entry. Missing a case here means the list's ↑/↓/space handlers steal
    /// keys mid-typing — which is exactly what broke spaces in project names.
    private var isTyping: Bool {
        focus == .rename || focus == .renameGroup || focus == .newProject
    }

    var body: some View {
        VStack(spacing: 0) {
            selectionToolbar
            list
            // The divider and bar only exist while selecting now — the add buttons moved up beside
            // Select, so there's nothing to show here otherwise.
            if selecting {
                Divider()
                selectionActionBar
            }
            KeybindingsFooter()
        }
        .focusable()
        .focusEffectDisabled()   // keep keyboard focus, but hide the blue focus-ring bars
        .focused($focus, equals: .list)
        .onAppear { focus = .list; DragSessionWatcher.start() }
        // Stop pinning an empty project once it has tasks (it now shows on its own) or when the
        // scope changes — otherwise it would linger in Today forever.
        .onChange(of: appState.scope) { _, _ in justCreatedProjectID = nil }
        .onChange(of: appState.projects) { _, _ in
            if let id = justCreatedProjectID,
               appState.projects.contains(where: { $0.taskProjectID == id }) {
                justCreatedProjectID = nil
            }
        }
        // A drag abandoned outside any drop target never reaches handleDrop, which would leave
        // the edge scroll zones armed and swallowing clicks. Reset on mouse-up regardless.
        .onReceive(NotificationCenter.default.publisher(for: .dragSessionEnded)) { _ in
            isDraggingTask = false
            draggingGroupID = nil
            dropTargetID = nil
        }
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
        // Naming a brand-new project for a task. A sheet (not a dialog) because it takes input.
        .sheet(isPresented: Binding(
            get: { taggingProjectID != nil },
            set: { if !$0 { taggingProjectID = nil; newTagName = "" } }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New tag").font(.headline)
                TextField("Tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitNewTag() }
                HStack {
                    Spacer()
                    Button("Cancel") { taggingProjectID = nil; newTagName = "" }
                    Button("Create") { commitNewTag() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
        .sheet(isPresented: Binding(
            get: { newProjectFor != nil || creatingEmptyProject },
            set: { if !$0 { newProjectFor = nil; creatingEmptyProject = false; newProjectName = "" } }
        )) {
            VStack(alignment: .leading, spacing: 14) {
                Text("New project").font(.headline)
                Text(newProjectSubtitle)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .newProject)
                    .onSubmit { commitNewProject() }
                HStack {
                    Spacer()
                    Button("Cancel") { dismissNewProject() }
                    Button("Create") { commitNewProject() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(18)
            .frame(width: 320)
            .onAppear { DispatchQueue.main.async { focus = .newProject } }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 3) {
                // Flat until you create a project; grouped headers appear only once there's
                // something to group by, so the list never gains chrome it doesn't need.
                if appState.taskProjects.isEmpty {
                    ForEach(appState.visibleTotals, id: \.rowIdentity) { total in
                        activeRow(total)
                    }
                } else {
                    ForEach(Array(groupedSections.enumerated()), id: \.element.id) { idx, section in
                        groupHeader(section)
                            .id(idx == 0 ? "list-top" : "section-\(section.id)")
                        if !collapsed.contains(section.id) {
                            if section.totals.isEmpty {
                                Text("Drag tasks here")
                                    .font(.caption).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 22).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                    .onDrop(of: [.text], isTargeted: Binding(
                                        get: { dropTargetID == section.id },
                                        set: { dropTargetID = $0 ? section.id : nil }
                                    )) { providers in handleDrop(providers, into: section.id) }
                            }
                            ForEach(section.totals, id: \.rowIdentity) { total in
                                activeRow(total)
                            }
                        }
                    }
                }
                // Archived tasks only appear in the All-Time view for now (showing them in
                // Today needs more thought).
                if appState.scope == .allTime && !appState.archivedTotals.isEmpty {
                    archivedSection
                }
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
        }
        // Pinned to the VIEWPORT, not the content: hovering a dragged card here scrolls, so
        // off-screen projects are reachable. SwiftUI's ScrollView has no built-in auto-scroll.
        .overlay(alignment: .top) { dragScrollZone(proxy: proxy, toward: .top) }
        .overlay(alignment: .bottom) { dragScrollZone(proxy: proxy, toward: .bottom) }
        }
    }

    // MARK: - Grouping

    private struct GroupSection: Identifiable {
        let id: Int64            // -1 = Inbox
        let name: String
        let colorHex: String
        let totals: [ProjectTotal]
        var seconds: TimeInterval { totals.reduce(0) { $0 + $1.seconds } }
    }

    /// Tasks split by project, in the same order groups were created; Inbox last so
    /// uncategorised work doesn't lead.
    private var groupedSections: [GroupSection] {
        let totals = appState.visibleTotals
        // In Today, a project with no tasks left to do drops out — the same rule that clears
        // finished tasks from Today while keeping them in All Time. All Time still lists every
        // project, so nothing is lost.
        //
        // Exception: a project created moments ago is kept regardless, since its header is the
        // drop target you're about to drag tasks onto. Without this the + button would appear to
        // do nothing in Today.
        // Finished tasks sink to the bottom of THEIR group (mirroring per-task behaviour), and
        // this must match AppState.orderedProjects or ↑/↓ won't track the visible rows.
        let inGroupOrder: ([ProjectTotal]) -> [ProjectTotal] = { rows in
            rows.sorted { a, b in
                if a.project.finished != b.project.finished { return !a.project.finished }
                if a.project.sortOrder != b.project.sortOrder { return a.project.sortOrder < b.project.sortOrder }
                return a.project.id < b.project.id
            }
        }
        var sections: [GroupSection] = appState.taskProjects.compactMap { group in
            let mine = inGroupOrder(totals.filter { $0.project.taskProjectID == group.id })
            if appState.scope == .today, mine.isEmpty, group.id != justCreatedProjectID {
                return nil
            }
            return GroupSection(id: group.id, name: group.name, colorHex: group.colorHex,
                                totals: mine)
        }
        let inbox = inGroupOrder(totals.filter { $0.project.taskProjectID == nil })
        if !inbox.isEmpty {
            sections.append(GroupSection(id: -1, name: "Inbox", colorHex: "#8E8E93", totals: inbox))
        }
        return sections
    }

    private func groupHeader(_ section: GroupSection) -> some View {
        let isFirstSection = groupedSections.first?.id == section.id
        let isCollapsed = collapsed.contains(section.id)
        let isDropTarget = dropTargetID == section.id
        return HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                .frame(width: 9)
            Circle().fill(Color(hex: section.colorHex)).frame(width: 7, height: 7)

            if editingGroupID == section.id {
                TextField("Project name", text: $editingGroupName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 160)
                    .focused($focus, equals: .renameGroup)
                    .onSubmit { commitGroupRename(section.id) }
                    // A TextField swallows onExitCommand (AppKit reads Esc as "clear field"),
                    // so Esc has to be caught explicitly or there's no way out of the editor.
                    .onKeyPress(.escape) { cancelGroupRename(); return .handled }
                    // Clicking anywhere else commits rather than trapping you mid-edit.
                    .onChange(of: focus) { _, new in
                        if new != .renameGroup && editingGroupID == section.id {
                            commitGroupRename(section.id)
                        }
                    }
            } else {
                Text(section.name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    // Inbox isn't a real row, so it can't be renamed.
                    .onTapGesture(count: 2) { if section.id != -1 { beginGroupRename(section) } }
            }

            Text("\(section.totals.count)").font(.caption2).foregroundStyle(.tertiary)

            // Tags, in their own colour but small and unweighted — the header is deliberately tiny,
            // so these have to read as an annotation rather than another control.
            //
            // The LABEL goes through `Theme.legibleText`; the capsule keeps the true colour. A tag's
            // own hex was previously painted straight onto a 14%-opacity capsule of itself, which over
            // a white window is essentially white text-on-white for most of the palette — measured,
            // 47 of 60 task/tag colours fail 4.5:1 there, the worst at 1.20:1. At 10pt that is not a
            // subtle deficiency, it's an invisible tag. Fill and label have genuinely different
            // requirements and now get different colours.
            if let tags = appState.tagsByProject[section.id], !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags) { tag in
                        Text(tag.name)
                            // 10pt, not 9: this is the smallest text in the app and the tag name is
                            // information, not texture.
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.legibleText(tag.colorHex,
                                                               dark: colorScheme == .dark))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color(hex: tag.colorHex).opacity(0.16))
                            )
                    }
                }
                .help("Tags on this project — right-click to change")
            }

            Spacer()

            // Time then buttons, in the same order as a task row, so the columns line up.
            Text(Format.compact(section.seconds))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)

            if !section.totals.isEmpty {
                let ids = section.totals.map(\.project.id)
                let allDone = section.totals.allSatisfy { $0.project.finished }
                groupIcon(allDone ? "arrow.uturn.left" : "checkmark",
                          help: allDone ? "Restore all tasks" : "Finish all tasks") {
                    allDone ? appState.unfinishAll(taskIDs: ids) : appState.finishAll(taskIDs: ids)
                }
                groupIcon("archivebox", help: "Archive all tasks") {
                    appState.archiveAll(taskIDs: ids)
                }
            }
            if section.id != -1 {
                GripDots()
                    .foregroundStyle(.tertiary)
                    .opacity(hoveredGroupID == section.id ? 0.8 : 0)
                    .contentShape(Rectangle())
                    .onDrag {
                        draggingGroupID = section.id
                        return NSItemProvider(object: "group:\(section.id)" as NSString)
                    }
                    .help("Drag to reorder project")
            }
        }
        .onHover { hoveredGroupID = $0 ? section.id : (hoveredGroupID == section.id ? nil : hoveredGroupID) }
        .padding(.leading, 3).padding(.trailing, 8)
        .padding(.top, isFirstSection ? 2 : 10).padding(.bottom, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard editingGroupID != section.id else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if isCollapsed { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
            }
        }
        .contextMenu {
            if section.id != -1 {
                Button("Rename…") { beginGroupRename(section) }
                tagMenu(for: section.id)
                Divider()
                Button("Delete project", role: .destructive) {
                    // Tasks fall back to Inbox — never destroys tracked time.
                    try? store.deleteTaskProject(id: section.id)
                    appState.reload()
                }
            }
        }
        // Drop a dragged task card onto a header to reassign it.
        .onDrop(of: [.text], isTargeted: Binding(
            get: { dropTargetID == section.id },
            set: { dropTargetID = $0 ? section.id : nil }
        )) { providers in
            handleDrop(providers, into: section.id)
        }
    }

    private enum ScrollEdge { case top, bottom }

    /// A thin invisible strip at the top/bottom of the list. While a drag hovers it, the list
    /// steps toward that end — the manual equivalent of the auto-scroll SwiftUI doesn't provide.
    private func dragScrollZone(proxy: ScrollViewProxy, toward edge: ScrollEdge) -> some View {
        Color.clear
            .frame(height: 26)
            .contentShape(Rectangle())
            .onDrop(of: [.text], isTargeted: Binding(
                get: { false },
                set: { hovering in
                    guard hovering else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        switch edge {
                        case .top:
                            proxy.scrollTo("list-top", anchor: .top)
                        case .bottom:
                            if let last = groupedSections.last {
                                proxy.scrollTo("section-\(last.id)", anchor: .bottom)
                            }
                        }
                    }
                }
            )) { _ in false }   // never consumes the drop; it only scrolls
            .allowsHitTesting(draggingGroupID != nil || isDraggingTask)
    }

    private func groupIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func beginGroupRename(_ section: GroupSection) {
        editingGroupName = section.name
        editingGroupID = section.id
        focus = .renameGroup
    }

    private func cancelGroupRename() {
        editingGroupID = nil
        editingGroupName = ""
        focus = .list
    }

    private func commitGroupRename(_ id: Int64) {
        let name = editingGroupName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { try? store.renameTaskProject(id: id, name: name) }
        editingGroupID = nil
        focus = .list
        appState.reload()
    }

    /// Move the dragged task ids into `groupID` (-1 = Inbox).
    /// Handles two payload kinds on the same drop targets:
    ///   • `"group:<id>"` — a project dragged by its grip → reorder to this position.
    ///   • `"1,2,3"`      — task ids → move those tasks into this project.
    private func handleDrop(_ providers: [NSItemProvider], into groupID: Int64) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let raw = value as? String else { return }
            Task { @MainActor in
                defer { dropTargetID = nil; draggingGroupID = nil; isDraggingTask = false }

                if raw.hasPrefix("group:") {
                    guard let movedID = Int64(raw.dropFirst("group:".count)),
                          movedID != groupID, groupID != -1 else { return }
                    appState.reorderTaskProject(movedID, toPositionOf: groupID)
                    return
                }

                let ids = raw.split(separator: ",").compactMap { Int64($0) }
                guard !ids.isEmpty else { return }
                let name = groupID == -1
                    ? nil
                    : appState.taskProjects.first { $0.id == groupID }?.name
                appState.assign(taskIDs: ids, toGroupNamed: name)
            }
        }
        return true
    }

    // MARK: - Active row

    private func activeRow(_ total: ProjectTotal) -> some View {
        let project = total.project
        let isSelected = appState.selectedProjectID == project.id
        let isRunning = engine.runningProjectID == project.id
        let isFinished = project.finished
        let isTicked = ticked.contains(project.id)
        return HStack(spacing: 9) {
            if selecting {
                Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isTicked ? Color.accentColor : Color.secondary.opacity(0.5))
            } else {
                // Grip dots: the affordance that this card can be picked up and dropped.
                GripDots()
                    .foregroundStyle(.tertiary)
                    .opacity(hoveredRowID == project.id ? 1 : 0.25)
                    .contentShape(Rectangle())
                    // Drag ONLY from the grip. Attached to the whole row it swallowed vertical
                    // drags and the list couldn't be scrolled.
                    .onDrag {
                        isDraggingTask = true
                        let ids = (selecting && isTicked) ? Array(ticked) : [project.id]
                        return NSItemProvider(
                            object: ids.map(String.init).joined(separator: ",") as NSString)
                    }
            }
            Circle().fill(Color(hex: appState.displayColorHex(for: project)).opacity(isFinished ? 0.5 : 1))
                .frame(width: 9, height: 9)

            if editingID == project.id {
                TextField("Name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .focused($focus, equals: .rename)
                    .onSubmit { commitRename(project.id) }
                    .onKeyPress(.escape) { editingID = nil; focus = .list; return .handled }
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
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(dropTargetID == (project.taskProjectID ?? -1)
                      ? Color.accentColor.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                if isTicked { ticked.remove(project.id) } else { ticked.insert(project.id) }
            } else {
                appState.selectedProjectID = project.id
            }
        }
        .onHover { hoveredRowID = $0 ? project.id : (hoveredRowID == project.id ? nil : hoveredRowID) }
        .contextMenu { projectMenu(for: project) }
        // The whole section is a drop zone, not just its header: dropping onto ANY task row
        // moves the dragged cards into that row's project.
        .onDrop(of: [.text], isTargeted: Binding(
            get: { dropTargetID == (project.taskProjectID ?? -1) },
            set: { dropTargetID = $0 ? (project.taskProjectID ?? -1) : nil }
        )) { providers in
            handleDrop(providers, into: project.taskProjectID ?? -1)
        }
        .animation(.easeInOut(duration: 0.15), value: isRunning)
        .animation(.easeInOut(duration: 0.15), value: isFinished)
    }

    /// Right-click → move a task into a project. Assignment lives here rather than in a
    /// dedicated mode so categorising never interrupts tracking.
    @ViewBuilder
    private func projectMenu(for task: Project) -> some View {
        Menu("Project") {
            ForEach(appState.taskProjects) { group in
                Button {
                    appState.assign(taskIDs: [task.id], toGroupNamed: group.name)
                } label: {
                    // A checkmark marks the current group.
                    Text(task.taskProjectID == group.id ? "✓ \(group.name)" : group.name)
                }
            }
            if !appState.taskProjects.isEmpty { Divider() }
            Button("New project…") { newProjectFor = task }
            if task.taskProjectID != nil {
                Divider()
                Button("Move to Inbox") { appState.assign(taskIDs: [task.id], toGroupNamed: nil) }
            }
        }
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
            Text(Format.compact(total.seconds))
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

    /// Enter/leave selection mode. Only offered once there's more than one task to act on.
    @ViewBuilder
    private var selectionToolbar: some View {
        if appState.visibleTotals.count > 1 {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selecting.toggle()
                        if !selecting { ticked.removeAll() }
                    }
                } label: {
                    Label(selecting ? "Done" : "Select", systemImage: selecting ? "xmark" : "checkmark.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)

                if selecting {
                    Text("\(ticked.count) selected").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(ticked.count == appState.visibleTotals.count ? "None" : "All") {
                        if ticked.count == appState.visibleTotals.count { ticked.removeAll() }
                        else { ticked = Set(appState.visibleTotals.map(\.project.id)) }
                    }
                    .buttonStyle(.borderless).font(.system(size: 11))
                } else {
                    Spacer()

                    // Up here beside Select rather than in a bar at the bottom: both are list-level
                    // actions, so they belong in the list's own header.
                    Button {
                        NotificationCenter.default.post(name: .openTaskPalette, object: nil)
                    } label: {
                        Label("New task", systemImage: "plus").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("New task or resume an existing one (Fn + ⌘ + ⇧ + A)")

                    Divider().frame(height: 14)

                    // Create an empty project up front, then drag tasks into it — the reverse of
                    // assigning from a task, and how you'd set up groups before categorising.
                    Button {
                        creatingEmptyProject = true
                    } label: {
                        Label("Project", systemImage: "folder.badge.plus").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("New project")
                }
            }
            // Taller with a faint tint so it reads as a row of its own rather than controls floating
            // above the list. Kept very light — the project headers below are deliberately quiet, and
            // a strong fill here would compete with them.
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.secondary.opacity(0.07))
        }
    }

    /// Assign everything ticked, in one action.
    private var selectionActionBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(appState.taskProjects) { group in
                    Button(group.name) {
                        appState.assign(taskIDs: Array(ticked), toGroupNamed: group.name)
                        finishSelecting()
                    }
                }
                if !appState.taskProjects.isEmpty { Divider() }
                Button("New project…") {
                    // Reuse the sheet; nil task means "apply to the selection".
                    newProjectFor = appState.visibleTotals.first { ticked.contains($0.project.id) }?.project
                }
                Divider()
                Button("Inbox") {
                    appState.assign(taskIDs: Array(ticked), toGroupNamed: nil)
                    finishSelecting()
                }
            } label: {
                Label("Move to project", systemImage: "folder")
            }
            .disabled(ticked.isEmpty)
            Spacer()
        }
        .padding(12)
    }

    private func finishSelecting() {
        ticked.removeAll()
        selecting = false
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

    private var newProjectSubtitle: String {
        if selecting && !ticked.isEmpty {
            return "Move \(ticked.count) selected task\(ticked.count == 1 ? "" : "s") into a new project."
        }
        if let task = newProjectFor {
            return "Group “\(task.name)” under a project. Its colour becomes the task's colour on charts."
        }
        return "Create an empty project, then drag tasks into it."
    }

    /// Clears every trigger of the new-project sheet. Missing `creatingEmptyProject` here is
    /// what made Cancel do nothing when the sheet came from the + button.
    private func dismissNewProject() {
        newProjectFor = nil
        creatingEmptyProject = false
        newProjectName = ""
    }

    private func commitNewProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Three entry points: a ticked selection, one task, or nothing (an empty project).
        let ids: [Int64]
        if selecting && !ticked.isEmpty {
            ids = Array(ticked)
        } else if let task = newProjectFor {
            ids = [task.id]
        } else {
            ids = []
        }
        if ids.isEmpty {
            // No tasks to move — just create the group so it can be a drop target.
            let newID = try? store.upsertTaskProject(
                name: name, colorHex: Palette.color(forIndex: appState.taskProjects.count))
            appState.reload()
            justCreatedProjectID = newID
        } else {
            appState.assign(taskIDs: ids, toGroupNamed: name)
        }
        newProjectFor = nil
        creatingEmptyProject = false
        newProjectName = ""
        if selecting { finishSelecting() }
    }

    private func rowBackground(isSelected: Bool, isRunning: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isRunning ? Color.green.opacity(0.7) : Color.black.opacity(0.04), lineWidth: isRunning ? 1.5 : 0.5)
            )
    }

// MARK: - Tags

    /// Tag assignment lives in a context menu rather than on the row: the project header is
    /// deliberately tiny, and tags are set once in a while, not per glance.
    ///
    /// Only projects can be tagged from the UI for now. Tasks can carry tags too — the store and
    /// schema already support it — so exposing that later needs no migration.
    @ViewBuilder
    private func tagMenu(for projectID: Int64) -> some View {
        let assigned = Set((try? store.tagIDs(for: .project(projectID))) ?? [])
        Menu("Tags") {
            ForEach(allTags) { tag in
                Button {
                    if assigned.contains(tag.id) {
                        try? store.removeTag(tag.id, from: .project(projectID))
                    } else {
                        try? store.addTag(tag.id, to: .project(projectID))
                    }
                    appState.reload()
                } label: {
                    // A leading tick stands in for a checkbox; Menu doesn't offer a real one.
                    Text(assigned.contains(tag.id) ? "✓ \(tag.name)" : "   \(tag.name)")
                }
            }
            if !allTags.isEmpty { Divider() }
            Button("New tag…") {
                newTagName = ""
                taggingProjectID = projectID
            }
        }
    }

    /// Read straight from the store rather than cached: the menu is built on demand, so a stale
    /// list can't be shown, and this runs once per right-click rather than per render.
    private var allTags: [Tag] { appState.allTags }

    private func commitNewTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let projectID = taggingProjectID else { return }
        // upsertTag reuses an existing name, so typing one you already have attaches it rather
        // than creating a second tag that would split its totals.
        if let tagID = try? store.upsertTag(name: name,
                                           colorHex: Palette.color(forIndex: allTags.count)) {
            try? store.addTag(tagID, to: .project(projectID))
        }
        taggingProjectID = nil
        newTagName = ""
        appState.reload()
    }

    // MARK: - Actions

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

/// Two columns of dots — the conventional "this is draggable" grip, as on reorderable list rows.
///
/// Internal rather than private: the allocations sheet reorders by drag too, and a second copy of
/// this would be a second thing to keep looking the same.
struct GripDots: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().frame(width: 2, height: 2)
                    }
                }
            }
        }
        .frame(width: 10)
        .accessibilityLabel("Drag to move")
    }
}

extension ProjectTotal {
    /// Row identity for `ForEach`. Deliberately NOT just the task id: SwiftUI reuses a view when
    /// identity is unchanged, so after moving a task to another project the cached row kept its
    /// old colour and stale hit target. Folding the group and finished flag in forces a rebuild.
    var rowIdentity: String {
        "\(project.id)-\(project.taskProjectID.map(String.init) ?? "inbox")-\(project.finished)"
    }
}

extension Notification.Name {
    /// Fired on left-mouse-up so views can clear transient drag state even when the drag was
    /// abandoned over empty space (where no drop handler runs).
    static let dragSessionEnded = Notification.Name("TimesliceDragSessionEnded")
}

/// Installs one app-wide mouse-up monitor that broadcasts `dragSessionEnded`.
@MainActor
enum DragSessionWatcher {
    private static var monitor: Any?
    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            NotificationCenter.default.post(name: .dragSessionEnded, object: nil)
            return event
        }
    }
}
