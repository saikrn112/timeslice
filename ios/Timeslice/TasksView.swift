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
    @State private var editing: Project?
    @State private var showArchived = false
    @State private var scope: TimeScope = .today
    /// Grouped by project by default, matching the Mac — `ProjectListView` has no toggle at all and
    /// simply groups whenever any project exists. The toggle stays because a phone benefits from a
    /// recency view the Mac gets from its switcher, but the default now agrees.
    @State private var grouped = true

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
                    controlRow
                    if model.tasks.isEmpty && model.archivedTasks.isEmpty {
                        empty
                    } else if !query.isEmpty {
                        card { rows(model.searchResults(query).map(\.project)) }
                    } else if grouped && !model.groups.isEmpty {
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
                    Button { model.showingAddTask = true } label: { Image(systemName: "plus") }
                }
                // No "Stop" here. On the Mac, stop and pause are meaningfully different — stop clears
                // the current task so the menu bar goes idle. On the phone the hero card's pause button
                // is right there and does the thing you actually want, so a second verb in the corner
                // was a choice you had to think about for no benefit. Stopping is still available from
                // the switcher and a Shortcut.
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
            // Hidden with no projects: "group by project" that groups nothing is chrome the list
            // doesn't need, which is the same reason the Mac stays flat until a project exists.
            if !model.groups.isEmpty {
                Button { grouped.toggle() } label: {
                    Label(grouped ? "Projects" : "Recent",
                          systemImage: grouped ? "folder" : "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
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

    /// The running task's uncommitted seconds — what the row's ticking clock shows beyond `seconds(for:)`.
    ///
    /// Zero for every task but the running one, and zero on All Time, matching `liveOrigin`. Derived from
    /// the run's own start rather than accumulated, so it can't drift.
    private func liveSeconds(for task: Project) -> TimeInterval {
        guard scope == .today, let running = model.running, running.projectID == task.id else { return 0 }
        return max(0, Date().timeIntervalSince(running.start))
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
            // Includes the RUNNING task's live time when its row does.
            //
            // `seconds(for:)` is committed-only, so a project header read 17s while the row directly
            // under it read 9:31 — the same project, two answers, six pixels apart. The live portion is
            // added from the same `liveOrigin` the row ticks from, so the two agree by construction
            // rather than by coincidence.
            //
            // Static text, not a `LiveClockText`: a header that ticked would drag every group's total
            // into the 10fps redraw for a figure you don't watch. It refreshes on the next reload, and
            // being a second stale is invisible at this size.
            Text(Format.compact(section.tasks.reduce(0) { total, task in
                total + seconds(for: task) + liveSeconds(for: task)
            }))
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
                Text(isRunning ? "tracking · today" : (task == nil ? "tap Start" : "paused · today"))
                    .font(Theme.captionSmall).foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

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
