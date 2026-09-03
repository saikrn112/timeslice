import SwiftUI
import UniformTypeIdentifiers
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
    @State private var editing: Project?
    @State private var showArchived = false
    @State private var scope: TimeScope = .today
    /// Grouped by project by default, matching the Mac — `ProjectListView` has no toggle at all and
    /// simply groups whenever any project exists. The toggle stays because a phone benefits from a
    /// recency view the Mac gets from its switcher, but the default now agrees.
    @State private var grouped = true
    @FocusState private var searchFocused: Bool
    /// Section id currently under a drag, so only that header highlights.
    @State private var dropTarget: Int64?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = model.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Theme.caption).foregroundStyle(.red).padding(.bottom, 6)
                    }
                    // First thing on screen, above the list: start/stop without hunting for a row.
                    //
                    // The recents chip strip that used to sit under this is gone. It clipped at both
                    // edges so half the chips read as fragments ("tch idea"), and every route it offered
                    // now exists somewhere better: the expanded Dynamic Island's switcher, the switcher
                    // sheet, and the Action Button. It was costing vertical space above the list to
                    // duplicate them badly.
                    if !(model.tasks.isEmpty && model.archivedTasks.isEmpty) {
                        NowCard()
                            .padding(.bottom, 12)
                    }
                    if model.tasks.isEmpty && model.archivedTasks.isEmpty {
                        empty
                    } else if !query.isEmpty {
                        if showsCreateRow {
                            card { createRow }
                        }
                        rows(matches)
                    } else if grouped && !model.groups.isEmpty {
                        ForEach(model.sections) { section in
                            groupHeader(section)
                            rows(section.tasks)
                        }
                    } else {
                        rows(model.recencyOrdered)
                    }
                    archived
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            }
            .background(Theme.page)
            // Pull to refresh here too, not only on Metrics. Same reasoning: background refresh is
            // opportunistic, so the gesture everyone already tries should force a poll.
            .refreshable {
                await SyncController.shared.syncOnce()
                model.load()
            }
            .navigationTitle("Timeslice")
            .toolbar { viewMenu }
            // Add and switch live at the BOTTOM, not in the top-right corner.
            //
            // Those are the two most-used actions in the app and they were in the hardest place on the
            // screen for a thumb. `safeAreaInset` puts the bar above the tab bar and shortens the scroll
            // view to match, so it never covers the last row — which a `ZStack` overlay would.
            //
            // No "Stop": on the Mac stop and pause differ (stop clears the current task so the menu bar
            // goes idle), but here the hero card's pause is right above and does what you want, so a
            // second verb would be a decision for no benefit. Stop stays in the switcher and Shortcuts.
            .safeAreaInset(edge: .bottom) { searchBar }
            // The launch hint and any "add a task" entry point now focus the ONE field rather than
            // presenting a second, weaker add UI.
            .onChange(of: model.showingAddTask) { _, wants in
                if wants { searchFocused = true; model.showingAddTask = false }
            }
            .sheet(item: $editing) { TaskDetailSheet(task: $0) }
        }
    }

    // MARK: - Controls

    /// ONE field at the bottom: search and create, in the place Add/Switch used to be.
    ///
    /// Three things collapse into this.
    ///
    /// **Search and add were the same gesture all along.** You type a name; either it exists, in which case
    /// you want to start it, or it doesn't, in which case you want to create it. Two separate entry points
    /// made you decide which up front — and the "add" one was a sheet that couldn't show you what already
    /// existed, so it invited duplicates.
    ///
    /// **Switch is gone.** A custom wheel is a control you have to learn; a filtered list is one you
    /// already know. Anything the wheel did, typing two letters does faster.
    ///
    /// **At the bottom, not the top.** `.searchable` puts the field under the navigation title, which is
    /// the far end of the screen from your thumb — the same reason Add and Switch moved down here.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("Search or add a task", text: $query)
                .font(.system(size: 16))
                .focused($searchFocused)
                .submitLabel(.go)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // Enter does the obvious thing: start the top match, or create when there is none.
                .onSubmit {
                    if let first = matches.first { model.toggle(taskID: first.id); clearSearch() }
                    else { createFromQuery() }
                }
            if !query.isEmpty {
                Button { clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Capsule().fill(Color.secondary.opacity(0.16)))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        // Lets the list scroll visibly under it rather than ending at a hard edge.
        .background(.bar)
    }

    /// Ranked matches for the typed text — `TaskSearch` from Core, the Mac's palette ranking.
    private var matches: [Project] {
        query.isEmpty ? [] : model.searchResults(query).map(\.project)
    }

    /// The `/project` token stripped, which is what a new task would actually be named.
    private var typedName: String {
        TaskSearch.parse(query).name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Offer create unless the text already names something exactly — otherwise the row invites a
    /// duplicate of the match directly above it.
    private var showsCreateRow: Bool {
        !typedName.isEmpty
            && !matches.contains { $0.name.caseInsensitiveCompare(typedName) == .orderedSame }
    }

    /// Create, start, and clear — you typed a task name into a time tracker.
    private func createFromQuery() {
        guard !typedName.isEmpty, let id = model.addTask(named: query) else { return }
        model.toggle(taskID: id)
        clearSearch()
    }

    private func clearSearch() {
        query = ""
        searchFocused = false
    }

    /// The create affordance, shown in the list above the matches.
    private var createRow: some View {
        Button { createFromQuery() } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Create \u{201C}\(typedName)\u{201D}").font(Theme.rowTitle)
                    // Names where it will land, since filing is no longer a picker in a sheet. A
                    // `/project` token still works and is honoured here.
                    Text(TaskSearch.parse(query).groupToken.map { "in \($0)" } ?? "in Inbox")
                        .font(Theme.captionSmall).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    /// Scope and grouping as ONE toolbar menu.
    ///
    /// These were a row sitting between the hero card and the first group header — a filter floating in
    /// the middle of the content it filters, taking a line of vertical space and reading as neither header
    /// nor control.
    ///
    /// A menu, and at the TOP, deliberately against the pattern of moving things to the bottom: Add and
    /// Switch went down because they're actions you take constantly, whereas scope and grouping are view
    /// options you set and forget. The bottom is scarce and belongs to the frequent thing. The label shows
    /// the current state, so nothing is hidden by folding it away.
    private var viewMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Scope", selection: $scope) {
                    ForEach(TimeScope.allCases) { s in Text(s.rawValue).tag(s) }
                }
                // Only meaningful once a project exists — grouping nothing is the same list either way,
                // which is why the Mac's list stays flat until then.
                if !model.groups.isEmpty {
                    Picker("Group by", selection: $grouped) {
                        Label("Projects", systemImage: "folder").tag(true)
                        Label("Recent", systemImage: "clock").tag(false)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(scope.rawValue)
                    if !model.groups.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Image(systemName: grouped ? "folder" : "clock")
                    }
                }
                .font(.system(size: 13, weight: .medium))
            }
        }
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

    /// Row height, fixed because the `List` below is measured rather than scrolled.
    ///
    /// 56, up from 46: a row is the primary tap target — tapping it starts a timer — and these were tight
    /// enough that hitting the right one felt like a decision. Apple's floor is 44pt for a target with
    /// nothing around it; a stack of adjacent ones wants more.
    private static let taskRowHeight: CGFloat = 56
    /// Gap between cards. What turns a table into separate objects: a divider says "same thing, next
    /// line", a gap says "different thing", and the second is what makes a mis-tap feel unlikely.
    private static let taskRowGap: CGFloat = 8

    /// Task rows in a `List`, so **done** and **archive** are system swipes.
    ///
    /// A `List` specifically because `.swipeActions` exists nowhere else — and you asked for archive to
    /// work "like sessions", which is that gesture. It's still wrapped in the existing card and its own
    /// scrolling is disabled with the height computed, so the page keeps one scroller and the card look
    /// is unchanged; two nested scrollers fight each other.
    ///
    /// Actions were previously invisible: the row had no controls at all, done/archive existed only in the
    /// long-press detail sheet, and nothing advertised either. Now:
    ///
    /// - tapping the row starts/pauses it (unchanged — the fastest thing should stay the cheapest)
    /// - an explicit play/pause button on the right, because a whole row that silently toggles a timer
    ///   gives no hint it's a control
    /// - swipe left: archive, then done — destructive-ish on the outside, matching Mail's ordering
    /// - long press still opens the detail sheet
    private func rows(_ tasks: [Project]) -> some View {
        List {
            ForEach(tasks, id: \.id) { task in
                TaskRow(task: task,
                        colorHex: model.colorHex(for: task),
                        seconds: seconds(for: task),
                        liveOrigin: liveOrigin(for: task),
                        isCurrent: model.currentTaskID == task.id,
                        onToggle: { model.toggle(taskID: task.id) })
                    .frame(height: Self.taskRowHeight)
                    .padding(.horizontal, Theme.cardPadding)
                    // Each row is its OWN card: no separators, its own rounded background, and a gap
                    // either side. Reported as "having in one table feels like I have to be careful
                    // while clicking" — which is what a shared container with hairline dividers
                    // communicates, since nothing says where one target ends.
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: Self.taskRowGap / 2, leading: 0,
                                              bottom: Self.taskRowGap / 2, trailing: 0))
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .fill(Theme.card)
                            .padding(.vertical, Self.taskRowGap / 2)
                    )
                    .contentShape(Rectangle())
                    // DRAG to refile. The Mac has a grip and drop targets; the phone had no way at all to
                    // move a task between projects short of the detail sheet's picker.
                    //
                    // No visible grip: a handle costs permanent width in every row, and on a touch screen
                    // long-press-to-lift IS the system's grip — `.draggable` gives the lift, the shadow and
                    // the drop animation for free. The drop targets highlight, which is what tells you the
                    // gesture is live.
                    //
                    // Carries the row id rather than the uid: this drag starts and ends inside one process,
                    // so there's no cross-device hop for an id to be wrong across.
                    .draggable(TaskDragID(id: task.id)) {
                        // Drag preview — the name alone, since the row's controls aren't meaningful mid-air.
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: model.colorHex(for: task)))
                                .frame(width: Theme.dot, height: Theme.dot)
                            Text(task.name).font(Theme.rowTitle)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    }
                    .onTapGesture { model.toggle(taskID: task.id) }
                    .onLongPressGesture {
                        // Confirms the press landed BEFORE the sheet animates in. A long press with no
                        // feedback reads as "did that register?", which is the whole reason start/stop
                        // already buzz.
                        Haptics.switched()
                        editing = task
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            model.setArchived(taskID: task.id, true)
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .tint(.orange)
                        Button {
                            model.setFinished(taskID: task.id, !task.finished)
                        } label: {
                            Image(systemName: task.finished ? "arrow.uturn.backward" : "checkmark")
                        }
                        .tint(.green)
                    }
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Self.taskRowHeight)
        .frame(height: (Self.taskRowHeight + Self.taskRowGap) * CGFloat(tasks.count))
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

    /// The running task's uncommitted seconds — what the row's ticking clock shows beyond `seconds(for:)`.
    ///
    /// Zero for every task but the running one, and zero on All Time, matching `liveOrigin`. Derived from
    /// the run's own start rather than accumulated, so it can't drift.
    private func liveSeconds(for task: Project) -> TimeInterval {
        guard scope == .today, let running = model.running, running.projectID == task.id else { return 0 }
        return max(0, Date().timeIntervalSince(running.start))
    }

    private func groupHeader(_ section: TimerModel.Section) -> some View {
        groupHeaderBody(section)
            // Drop target for a dragged task. The header is the project, so dropping onto it means
            // "belongs here" without inventing a separate well to aim at.
            .dropDestination(for: TaskDragID.self) { items, _ in
                guard let first = items.first else { return false }
                model.setGroup(taskID: first.id, groupID: section.group?.id)
                Haptics.started()
                return true
            } isTargeted: { targeted in
                dropTarget = targeted ? section.id : nil
            }
            // Only the header being aimed at lights up, so it's unambiguous where the task will land.
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(dropTarget == section.id ? Color.accentColor.opacity(0.18) : .clear)
            )
    }

    private func groupHeaderBody(_ section: TimerModel.Section) -> some View {
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
            // Includes the RUNNING task's live time, and TICKS while it does.
            //
            // `seconds(for:)` is committed-only, so a project header read 17s while the row under it read
            // 9:31 — same project, two answers, six pixels apart. Adding the live portion fixed the
            // arithmetic but I first left the header static, reasoning a second's staleness was invisible.
            // That was wrong: nothing recomputes it until the next reload, so the gap grows without bound
            // — a screenshot caught it reading 28m beside a row showing 29:03.
            //
            // So it observes the same clock the rows do. Only the section CONTAINING the running task
            // does; every other header stays static, so the 10fps redraw covers one small label rather
            // than all of them.
            LiveGroupTotal(
                committed: section.tasks.reduce(0) { $0 + seconds(for: $1) },
                runningOrigin: section.tasks.contains { $0.id == model.running?.projectID }
                    ? model.running?.start : nil)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// Archived tasks, filtered by the search like everything else.
    ///
    /// It wasn't: the section rendered `model.archivedTasks` verbatim, so searching "ios" still listed
    /// "old prototype" — which doesn't contain an i at all. Every other section respected the query, so
    /// the one that didn't looked like a broken match rather than an unfiltered list.
    ///
    /// Hidden entirely while searching if nothing archived matches, rather than showing an empty
    /// disclosure that implies there might be something behind it.
    @ViewBuilder
    private var archived: some View {
        let shown = model.searchArchived(query)
        if !shown.isEmpty {
            Button { withAnimation { showArchived.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("Archived (\(shown.count))").font(Theme.sectionHeader)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)

            if showArchived {
                card {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, task in
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
                        if i < shown.count - 1 { Divider() }
                    }
                }
            }
        }
    }
}

/// A project header's total, ticking only when that project owns the running task.
///
/// Split out so the 10fps clock re-renders THIS label and nothing else — the whole point of the Mac's
/// `TickClock` split, applied here. Shown to the minute, like the Mac's header, so the digits don't
/// flicker at ten frames a second for a figure you glance at.
private struct LiveGroupTotal: View {
    let committed: TimeInterval
    /// The running interval's start, or nil when this project isn't the one running.
    let runningOrigin: Date?

    @ObservedObject private var clock = TickClock.shared

    var body: some View {
        if let runningOrigin {
            let live = max(0, clock.now.timeIntervalSince(runningOrigin))
            Text(Format.compact(committed + live))
                .onAppear { clock.subscribe() }
                .onDisappear { clock.unsubscribe() }
        } else {
            Text(Format.compact(committed))
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
    /// Start/pause this task. The row is tappable too, but a row that silently toggles a timer gives no
    /// hint it's a control — hence the explicit button as well.
    let onToggle: () -> Void

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
                // GREEN while running, not the task's colour — the same rule as the Dynamic Island
                // and the same thing the Mac's list already did (`isRunning ? .green : .primary`).
                // Painting a ticking clock in the task's own hex is what made it a barely-visible pale
                // blue: most of the palette fails text contrast, and this is the one number in the row
                // you actually watch.
                LiveClockText(origin: liveOrigin)
                    .font(Theme.rowTime)
                    .foregroundStyle(.green)
            } else {
                Text(Format.compact(seconds))
                    .font(Theme.rowTime)
                    .foregroundStyle(seconds > 0 ? .primary : .tertiary)
            }

            // The visible control. Until now the row's only affordance was tapping it, which nothing
            // advertised, so start/pause was invisible unless you already knew. Finished tasks don't get
            // one: resuming one is a deliberate act through the detail sheet, not a stray tap.
            if !task.finished {
                Button(action: onToggle) {
                    Image(systemName: isRunning ? "pause.circle.fill" : "play.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isRunning ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
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

/// The hero control at the top of Tasks: what's running, for how long, and one big button.
///
/// Opening the app should let you start or stop immediately, the way a stopwatch does — without
/// hunting for the right row first. This is the first piece written for touch rather than
/// transplanted from the Mac, where the equivalent job is done by a global hotkey.
///
/// Three states, and the button always says what it will do:
///  • running — ticking today's total, "Pause"
///  • paused  — frozen total, "Resume" (the task stays current, mirroring the Mac)
///  • idle    — "Start", which resumes the most recently worked task via `toggleCurrent()`
struct NowCard: View {
    @ObservedObject private var model = TimerModel.shared

    private var task: Project? { model.currentTaskID.flatMap { model.task(id: $0) } }
    private var isRunning: Bool { model.isRunning }

    var body: some View {
        let accent = task.map { Color(hex: model.colorHex(for: $0)) } ?? .secondary
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(accent).frame(width: 10, height: 10)
                    Text(task?.name ?? "Nothing running")
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                }
                // Today's total for the current task, ticking while running — the same number the
                // row and the Dynamic Island show, from the same `liveOrigin`.
                if let id = model.currentTaskID, let origin = model.liveOrigin(for: id) {
                    // Own clock, not `Text(timerInterval:)`: that API has no subsecond option, and the
                    // Mac shows milliseconds on the live figure.
                    LiveClockText(origin: origin)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.green)
                } else if let id = model.currentTaskID {
                    Text(Format.compact(model.committedTodaySeconds[id] ?? 0))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                // Names the device when a takeover stopped it. The Mac says who took over; the phone
                // just went quiet, which reads as the app losing the timer rather than another device
                // claiming it.
                if !isRunning, let by = model.takenOverBy, task != nil {
                    Text("paused · \(by) took over")
                        .font(Theme.captionSmall).foregroundStyle(.orange)
                } else {
                    Text(isRunning ? "tracking · today" : (task == nil ? "tap Start" : "paused · today"))
                        .font(Theme.captionSmall).foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            // STOP — the answer to "how will the app stop?".
            //
            // I removed the toolbar's Stop because a second verb in the corner was a decision for no
            // benefit, and that left no way to stop at all: pause keeps the task current, so the island
            // stays up and the task stays selected forever. Here it's contextual — only present when
            // something IS current, right next to the thing it contrasts with — which is what the toolbar
            // version wasn't.
            //
            // Deliberately smaller and unfilled: pause is what you press constantly, stop is what you
            // press when you're finished, and the sizes should say so.
            if model.currentTaskID != nil {
                Button {
                    model.stop()
                } label: {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.45), lineWidth: 1.5)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop tracking")
            }

            Button {
                model.toggleCurrent()
            } label: {
                // A 64pt circle: comfortably past the 44pt minimum tap target, and reachable with a
                // thumb without looking.
                ZStack {
                    Circle().fill(isRunning ? Color.orange : Color.green)
                    Image(systemName: isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRunning ? "Pause timer" : "Start timer")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
    }
}

/// A task being dragged, as a transferable payload.
///
/// A tiny wrapper rather than dragging a bare `Int64`: `Transferable` needs a concrete content type, and a
/// custom one means the drop destination can only ever receive a Timeslice task — dropping a number or a
/// string from another app can't accidentally match and refile something.
struct TaskDragID: Codable, Transferable {
    let id: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .timesliceTask)
    }
}

extension UTType {
    /// Declared in code only — this type never leaves the app, so it needs no Info.plist entry.
    static let timesliceTask = UTType(exportedAs: "com.timeslice.ios.task")
}
