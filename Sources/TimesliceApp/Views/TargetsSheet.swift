import SwiftUI
import TimesliceCore
import TimesliceUI

/// One place to manage tags and the budgets attached to them.
///
/// Tags and projects share this sheet deliberately: a target can point at either, and splitting them
/// across two screens would make "where do I set my office budget?" ambiguous when office is a tag
/// but `profiling` is a project.
struct TargetsSheet: View {
    @ObservedObject var appState: AppState
    let store: IntervalStore
    var onClose: () -> Void

    @State private var tags: [Tag] = []
    @State private var targets: [Target] = []
    /// Retired allocations with their allocated-vs-spent figures, for the history list.
    @State private var history: [AllocationHistory] = []
    @State private var newTagName = ""
    /// Every task, for the per-task allocation list. Loaded in `reload` with everything else.
    @State private var allTasks: [Project] = []
    @State private var taskQuery = ""
    /// Task ids in most-recent-first order, captured on open.
    @State private var recencyOrder: [Int64] = []
    /// Re-read after every edit. Cheap (a handful of rows) and avoids the whole class of bugs where
    /// the sheet shows something the store no longer agrees with.
    private func reload() {
        tags = (try? store.listTags()) ?? []
        targets = (try? store.listTargets()) ?? []
        history = loadHistory()
    }

    /// Retired allocations, newest first, each measured over the span it was actually live for.
    private func loadHistory() -> [AllocationHistory] {
        let all = (try? store.listTargets(includeCompleted: true)) ?? []
        let retired = all.filter { !$0.isLive }
        guard !retired.isEmpty else { return [] }
        let tasks = (try? store.listProjects(includeArchived: true)) ?? []
        allTasks = tasks
        recencyOrder = appState.recencyOrderedProjects.map(\.id)
        let tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        let intervals = (try? store.intervals()) ?? []
        let byTask = (try? store.effectiveTagIDsByTask()) ?? [:]

        return retired.compactMap { t in
            guard let end = t.completedAt else { return nil }
            let name: String?
            switch t.subject {
            case .task(let id): name = tasks.first { $0.id == id }?.name
            case .project(let id): name = appState.taskProjects.first { $0.id == id }?.name
            case .tag(let id): name = tagsByID[id]?.name
            }
            guard let name else { return nil }   // subject deleted: nothing meaningful to show
            let span = DateRange(unit: .all, start: t.createdAt, end: end)
            let spent = Aggregations.secondsForSubject(t.subject, intervals: intervals, tasks: tasks,
                                                       tagIDsByTask: byTask, range: span, now: end)
            return AllocationHistory(
                target: t, name: name, start: t.createdAt, end: end,
                allocatedSeconds: TargetMath.allocated(t, from: t.createdAt, to: end),
                spentSeconds: spent)
        }
        .sorted { $0.end > $1.end }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tags & allocations").font(.headline)
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tagSection
                    projectSection
                    taskSection
                    historySection
                }
                .padding(16)
            }
        }
        // 760 rather than 680: the row gained a Custom… button, and a one-off's summary ("once · 21 Sep")
        // is wider than the glyph it replaced. Everything heavier lives in the panel behind it.
        .frame(width: 760, height: 560)
        .onAppear { reload() }
    }

    // MARK: - Tags

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TAGS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Text("A tag groups projects that belong together. Tags can overlap, so a project can "
                 + "sit in more than one.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if tags.isEmpty {
                Text("No tags yet").font(.caption).foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(tags) { tag in
                    subjectRow(name: tag.name, colorHex: tag.colorHex, subject: .tag(tag.id)) {
                        // Deleting a tag drops its links and any target on it, never any tracked time.
                        try? store.deleteTag(id: tag.id)
                        reload()
                        appState.reload()
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("New tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { addTag() }
                Button("Add") { addTag() }
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(.top, 2)

            Text("Assign a tag to a project by right-clicking the project row in Tasks.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// S M T W T F S. Every day is on by default; tapping one narrows the allocation to the days it's
    /// actually meant to happen on, which is what makes its per-day pace mean anything — a 10h week
    /// worked Monday to Friday is 2h a day, not 1h26m.
    ///
    /// Only the DENOMINATOR changes. An hour recorded on an unselected day still counts towards the
    /// total, because saying "I do this on weekdays" describes how the hours are meant to be spread,
    /// not a refusal to count Sunday's work.
    private func weekdayBubbles(for target: Target) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<7, id: \.self) { bit in
                let on = target.weekdays.effective.contains(weekday: bit + 1)
                Button {
                    let next = target.weekdays.effective.toggling(weekday: bit + 1)
                    // Turning the last one off would divide the target by zero days, so an empty
                    // selection is stored as "every day" — which is what it means anyway.
                    try? store.setTargetWeekdays(id: target.id, next.selectedCount == 0 ? .all : next)
                    reload()
                } label: {
                    Text(Weekdays.initials[bit])
                        .font(.system(size: 9, weight: on ? .semibold : .regular))
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(on ? Color.accentColor.opacity(0.28)
                                                     : Color.secondary.opacity(0.10)))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .help(target.weekdays.effective.isAll
              ? "Every day — tap to pick the days this is meant to happen on"
              : "\(target.weekdays.selectedCount) days a week, so the pace is "
                + "\(Format.compact(target.seconds / Double(max(1, target.weekdays.selectedCount)))) per day")
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        _ = try? store.upsertTag(name: name, colorHex: Palette.color(forIndex: tags.count))
        newTagName = ""
        reload()
    }

    // MARK: - Projects

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROJECTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Text("An allocation can sit directly on a project too, without needing a tag.")
                .font(.caption2).foregroundStyle(.secondary)
            if appState.taskProjects.isEmpty {
                Text("No projects yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(appState.taskProjects) { project in
                    subjectRow(name: project.name, colorHex: project.colorHex,
                               subject: .project(project.id), onDelete: nil)
                }
            }
        }
    }

    // MARK: - Tasks

    /// An allocation directly on one task.
    ///
    /// Note 51: an ad-hoc goal ("ten hours on the tax return") was only expressible by inventing a
    /// project to hang it off, which litters the project list with one-task projects that exist for
    /// no other reason. `TargetSubject` and `Aggregations` already understood `.task`; nothing but
    /// this list was missing.
    ///
    /// Searchable and collapsed by default, because there are two orders of magnitude more tasks than
    /// projects and an unfiltered list of every task ever tracked would bury the two sections above.
    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("TASKS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer()
                TextField("Find a task", text: $taskQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            Text("For a one-off goal that doesn't deserve a project of its own.")
                .font(.caption2).foregroundStyle(.secondary)

            // Always shown, no Show/Hide toggle: one more button to reach the thing you came for,
            // and hiding a list that's already height-capped and scrollable saves nothing.
            //
            // FIXED height, scrolled inside. Letting it size to its contents made the whole sheet
            // grow and shrink on every keystroke as the match count changed, which is unusable for
            // typing into.
            Group {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let rows = matchingTasks
                        if rows.isEmpty {
                            Text(taskQuery.isEmpty ? "No tasks yet"
                                                   : "No task matches \"\(taskQuery)\"")
                                .font(.caption).foregroundStyle(.tertiary)
                        } else {
                            ForEach(rows) { task in
                                subjectRow(name: task.name,
                                           colorHex: appState.displayColorHex(for: task),
                                           subject: .task(task.id), onDelete: nil)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Ten rows. Deep enough to browse without the sheet becoming mostly task list.
                .frame(height: 230)
                // A scrollbar that appears once the content overflows reflows the rows under it. On
                // permanently, so the gutter is always the same width.
                .scrollIndicators(.visible)
                // Corner ticks rather than a box. The list reads best blended into the sheet, but
                // then nothing says it scrolls — and a half-visible row at the bottom edge is a
                // weak hint that only appears when you happen to have the right number of tasks.
                // Four short brackets mark the region's extent without drawing a container.
                .overlay(ScrollCorners().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                .padding(.vertical, 2)
            }
        }
    }

    /// Tasks matching the search, most recently worked on first.
    ///
    /// Recency order, not alphabetical or creation order: a goal is nearly always about something
    /// you're in the middle of, so what you touched today should be the first thing offered. The
    /// same reasoning (and the same source) as the task switcher's LRU cycle. No cap any more —
    /// the list scrolls at a fixed height instead, so length costs nothing.
    private var matchingTasks: [Project] {
        let q = taskQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = q.isEmpty ? orderedTasks : orderedTasks.filter { $0.name.lowercased().contains(q) }
        return pool
    }

    /// LRU order, resolved once per sheet open rather than per keystroke — it queries the store.
    private var orderedTasks: [Project] {
        guard !recencyOrder.isEmpty else { return allTasks }
        let rank = Dictionary(uniqueKeysWithValues: recencyOrder.enumerated().map { ($1, $0) })
        return allTasks.sorted { (rank[$0.id] ?? .max, $0.id) < (rank[$1.id] ?? .max, $1.id) }
    }

    /// Tasks that already carry a live allocation.
    private var taskTargets: [Project] {
        let ids = Set(targets.compactMap { target -> Int64? in
            if case .task(let id) = target.subject { return id }
            return nil
        })
        return allTasks.filter { ids.contains($0.id) }
    }

    // MARK: - History

    /// Retired allocations: what was set aside against what actually went in.
    ///
    /// Lives here rather than on the Metrics page because it's something you go and look at, not
    /// something you glance at while working.
    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("ARCHIVED ALLOCATIONS")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Text("Allocated is the amount × the time it was live for. Editing an amount while an "
                     + "allocation is running changes its history too — the figure isn't versioned.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(history) { row in historyRow(row) }
            }
        }
    }

    private func historyRow(_ row: AllocationHistory) -> some View {
        // For a floor, spending less than allocated is the miss; for a ceiling it's the win. Same
        // number, opposite meaning — so the arithmetic is shared and only the colour differs.
        let under = row.deltaSeconds < 0
        let good = row.target.direction == .atLeast ? !under : under
        return HStack(spacing: 8) {
            Circle().fill(good ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(row.name).font(.callout).lineLimit(1).frame(width: 120, alignment: .leading)
            Text("\(Self.dayFormatter.string(from: row.start)) – \(Self.dayFormatter.string(from: row.end))")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: 108, alignment: .leading)
            Text("\(hoursLabel(row.allocatedSeconds)) set aside")
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
            Text("\(hoursLabel(row.spentSeconds)) spent")
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 92, alignment: .trailing)
            Text("\(row.deltaSeconds < 0 ? "−" : "+")\(hoursLabel(abs(row.deltaSeconds)))")
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(good ? .green : .orange)
                .frame(width: 56, alignment: .trailing)
            Spacer(minLength: 4)
            Button("Reopen") {
                try? store.setTargetCompleted(id: row.target.id, completed: false)
                reload()
            }
            .buttonStyle(.link).font(.system(size: 10))
            .help("Put it back in the live list")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()

    // MARK: - Shared row

    /// One row: the subject, then its budget. `onDelete` is nil for projects — they're deleted from
    /// the Tasks tab, and offering it here would imply this sheet owns them.
    /// The allocation whose dates are being picked. One at a time: a popover per row that could all be
    /// open at once would let you edit two windows with one calendar on screen.
    /// Which end of which allocation's window has its calendar open. One at a time.
    private struct CalendarTarget: Equatable { let id: Int64; let isStart: Bool }
    @State private var calendarFor: CalendarTarget?
    /// Which allocation's Custom panel is open.
    @State private var customFor: Int64? = ProcessInfo.processInfo
        .environment["TIMESLICE_OPEN_CUSTOM"].flatMap { Int64($0) }

    /// One subject and its allocation controls.
    ///
    /// The name is tooltipped because it truncates: task and tag names are as long as they need to
    /// be, and a clipped label with no way to read the rest is a puzzle rather than a label.
    private func subjectRow(name: String, colorHex: String, subject: TargetSubject,
                            onDelete: (() -> Void)?) -> some View {
        let existing = targets.first { $0.subject == subject }
        return HStack(spacing: 8) {
            Circle().fill(Color(hex: colorHex)).frame(width: 9, height: 9)
            Text(name).font(.callout).lineLimit(1).truncationMode(.tail)
                .frame(width: 150, alignment: .leading)
                .help(name)

            // Budget controls sit at the RIGHT, just before delete — for both tags and projects — so
            // the "Set budget" link and the populated controls occupy the same place.
            Spacer(minLength: 4)

            if let existing {
                // Direction: tap to flip between a floor and a ceiling.
                Button(existing.direction.symbol) {
                    save(subject: subject, seconds: existing.seconds,
                         direction: existing.direction == .atLeast ? .atMost : .atLeast,
                         period: existing.period, weekdays: existing.weekdays,
                         startsOn: existing.startsOn, endsOn: existing.endsOn,
                         interval: existing.interval)
                }
                .buttonStyle(.bordered)
                .help(existing.direction == .atLeast
                      ? "At least this much — tap for a limit instead"
                      : "At most this much — tap for a minimum instead")

                Button("−") {
                    save(subject: subject, seconds: max(1800, existing.seconds - 1800),
                         direction: existing.direction, period: existing.period,
                         weekdays: existing.weekdays,
                         startsOn: existing.startsOn, endsOn: existing.endsOn,
                         interval: existing.interval)
                }.buttonStyle(.borderless)
                // Typeable, not just steppable: reaching 160h in half-hour clicks is 320 presses.
                HoursField(seconds: existing.seconds) { secs in
                    save(subject: subject, seconds: secs,
                         direction: existing.direction, period: existing.period,
                         weekdays: existing.weekdays,
                         startsOn: existing.startsOn, endsOn: existing.endsOn,
                         interval: existing.interval)
                }
                Button("+") {
                    save(subject: subject, seconds: existing.seconds + 1800,
                         direction: existing.direction, period: existing.period,
                         weekdays: existing.weekdays,
                         startsOn: existing.startsOn, endsOn: existing.endsOn,
                         interval: existing.interval)
                }.buttonStyle(.borderless)

                Picker("", selection: Binding(
                    get: { existing.period },
                    set: { period in
                        // Switching TO a one-off seeds today and opens the calendar; switching away leaves
                        // the window alone, so flipping once → week → once doesn't lose the dates.
                        let seedsToday = period == .once && existing.startsOn == nil
                        let today = Calendar.current.startOfDay(for: Date())
                        save(subject: subject, seconds: existing.seconds,
                             direction: existing.direction, period: period,
                             weekdays: existing.weekdays,
                             startsOn: seedsToday ? today : existing.startsOn,
                             endsOn: seedsToday ? today : existing.endsOn,
                             interval: existing.interval)
                        // A one-off with no dates asks for nothing, so choosing it opens the panel that
                        // owns them rather than leaving an inert allocation to be discovered.
                        if seedsToday { customFor = existing.id }
                    }
                )) {
                    ForEach(Target.Period.allCases, id: \.self) { p in
                        Text(p == .once ? "once" : p.rawValue).tag(p)
                    }
                }
                .labelsHidden()
                .frame(width: 84)

                // Which days it's meant to happen on. Only offered for a week or a month — a daily
                // allocation is already about one day, and picking days for it would be nonsense.
                if existing.period != .day {
                    weekdayBubbles(for: existing)
                }

                customButton(existing, subject: subject)

                // Retire rather than delete: the allocation leaves the live list but keeps its
                // history, which is the whole reason for the state.
                //
                // Named after WHERE it goes, not after being finished. It was a tick, which read as
                // "confirm this number"; then "Done", which read as "done editing" — the one thing a
                // button in a sheet is most likely to mean. "Archive" can be neither, and it's the
                // word the section below uses.
                Button("Archive") {
                    try? store.setTargetCompleted(id: existing.id, completed: true)
                    reload()
                }
                .buttonStyle(.link).font(.system(size: 11))
                .help("Finished with this allocation — keeps it, and its history, under "
                      + "ARCHIVED ALLOCATIONS")

                Button {
                    try? store.deleteTarget(id: existing.id)
                    reload()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Delete this allocation and its history")
            } else {
                Button("Set allocation") {
                    // A weekly floor is the common case; both are one tap from here. A brand-new
                    // allocation starts on every day — narrowing it is a later, deliberate choice.
                    save(subject: subject, seconds: 5 * 3600, direction: .atLeast, period: .week,
                         weekdays: .all, startsOn: nil, endsOn: nil, interval: 1)
                }
                .buttonStyle(.link).font(.system(size: 11))
            }

            if let onDelete {
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("Delete this tag")
            }
        }
    }

    /// `weekdays` must be passed through, not defaulted.
    ///
    /// `setTarget` upserts, and its `ON CONFLICT` clause assigns every column it was given — so
    /// leaving `weekdays` at its `.all` default meant editing the HOURS silently reset the day
    /// bubbles to all seven. Picking days and then adjusting the number lost the days, which is the
    /// order anyone would naturally work in.
    /// One button for everything the row doesn't show: when it starts, when it stops, and whether it repeats.
    ///
    /// The row keeps the three things you change constantly — hours, how often, which days — and this holds
    /// the rest, the way a calendar app puts recurrence behind "Custom…". When something non-default is set
    /// the button says what, so the row still tells the truth at a glance.
    private func customButton(_ target: Target, subject: TargetSubject) -> some View {
        let summary = Self.customSummary(target)
        return Button(summary ?? "Custom…") {
            customFor = target.id
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10, design: .rounded))
        .foregroundStyle(summary == nil ? Color.secondary : Color.accentColor)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(summary == nil
              ? "Dates, one-off, and how often it repeats"
              : "\(summary!) — click to change")
        .popover(isPresented: Binding(get: { customFor == target.id },
                                     set: { if !$0 { customFor = nil } }),
                 arrowEdge: .bottom) {
            customPanel(target, subject: subject)
        }
    }

    /// What's non-default about this allocation, in as few words as possible. Nil when nothing is.
    private static func customSummary(_ target: Target) -> String? {
        var parts: [String] = []
        if target.period == .once { parts.append("once") }
        if target.interval > 1 { parts.append("every \(target.interval)") }
        if let start = target.startsOn, let end = target.endsOn,
           Calendar.current.isDate(start, inSameDayAs: end) {
            parts.append(dayText(start))
        } else {
            if let start = target.startsOn { parts.append("from \(dayText(start))") }
            if let end = target.endsOn { parts.append("until \(dayText(end))") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The full options, in plain rows: does it repeat, when does it start, when does it stop.
    @ViewBuilder
    private func customPanel(_ target: Target, subject: TargetSubject) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        let start = target.startsOn ?? today
        let end = target.endsOn ?? start

        VStack(alignment: .leading, spacing: 14) {
            Text("When this applies").font(.system(size: 13, weight: .semibold))

            row("Repeats") {
                Picker("", selection: Binding(
                    get: { target.period == .once },
                    set: { once in
                        // A one-off needs dates or it asks for nothing, so choosing it seeds today.
                        save(subject: subject, seconds: target.seconds, direction: target.direction,
                             period: once ? .once : .week, weekdays: target.weekdays,
                             startsOn: once ? (target.startsOn ?? today) : target.startsOn,
                             endsOn: once ? (target.endsOn ?? today) : target.endsOn,
                             interval: once ? 1 : target.interval)
                    })) {
                    Text("Every").tag(false)
                    Text("Just once").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .labelsHidden()

                if target.period != .once {
                    Stepper(value: Binding(
                        get: { target.interval },
                        set: { count in
                            // Above 1 the cycle needs an anchor to count from, so it takes today if the
                            // allocation has no start date yet.
                            let anchor = count > 1 ? (target.startsOn ?? today) : target.startsOn
                            save(subject: subject, seconds: target.seconds,
                                 direction: target.direction, period: target.period,
                                 weekdays: target.weekdays, startsOn: anchor,
                                 endsOn: target.endsOn, interval: count)
                        }), in: 1...12) {
                        Text("\(target.interval) \(target.period.rawValue)\(target.interval == 1 ? "" : "s")")
                            .font(.system(size: 11)).monospacedDigit()
                    }
                    .fixedSize()
                }
            }

            if target.period == .once {
                row("On") {
                    dayButton(start, target: target, subject: subject, isStart: true)
                    Text("to").font(.system(size: 10)).foregroundStyle(.secondary)
                    dayButton(end, target: target, subject: subject, isStart: false)
                }
                Text("Its hours are the whole job, spread over the days above.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                row("Starts") {
                    Toggle("", isOn: Binding(
                        get: { target.startsOn != nil },
                        set: { on in
                            write(target, subject: subject, startsOn: on ? today : nil,
                                  endsOn: target.endsOn)
                        })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    if target.startsOn != nil {
                        dayButton(start, target: target, subject: subject, isStart: true)
                    } else {
                        Text("any time before now counts too")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                row("Ends") {
                    Toggle("", isOn: Binding(
                        get: { target.endsOn != nil },
                        set: { on in
                            let month = Calendar.current.date(byAdding: .month, value: 1, to: start)
                            write(target, subject: subject, startsOn: target.startsOn,
                                  endsOn: on ? month : nil)
                        })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    if target.endsOn != nil {
                        dayButton(end, target: target, subject: subject, isStart: false)
                    } else {
                        Text("runs until you archive it")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }

            HStack { Spacer(); Button("Done") { customFor = nil }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func row<Content: View>(_ title: String,
                                   @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            content()
        }
    }

    /// A date as a button that opens a month to click in — the system's compact field is 200pt and renders
    /// "10/ 1/2026", which is both wider and harder to read than "1 Oct".
    private func dayButton(_ date: Date, target: Target, subject: TargetSubject,
                           isStart: Bool) -> some View {
        Button(Self.dayText(date)) {
            calendarFor = CalendarTarget(id: target.id, isStart: isStart)
        }
        .buttonStyle(.bordered)
        .font(.system(size: 11, design: .rounded))
        .popover(isPresented: Binding(
            get: { calendarFor == CalendarTarget(id: target.id, isStart: isStart) },
            set: { if !$0 { calendarFor = nil } }), arrowEdge: .bottom) {
            VStack(spacing: 8) {
                DatePicker("", selection: Binding(
                    get: { date },
                    set: { picked in
                        // Kept in order here rather than validated later: an end before its start is an empty
                        // window, which Core honestly reports as asking for nothing.
                        if isStart {
                            write(target, subject: subject, startsOn: picked,
                                  endsOn: target.endsOn.map { max($0, picked) })
                        } else {
                            write(target, subject: subject,
                                  startsOn: target.startsOn.map { min($0, picked) }, endsOn: picked)
                        }
                    }), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(width: 230)
                Button("Done") { calendarFor = nil }.font(.system(size: 11))
            }
            .padding(12)
        }
    }

    private static func dayText(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    private func write(_ target: Target, subject: TargetSubject, startsOn: Date?, endsOn: Date?) {
        save(subject: subject, seconds: target.seconds, direction: target.direction,
             period: target.period, weekdays: target.weekdays, startsOn: startsOn, endsOn: endsOn,
             interval: target.interval)
    }

    /// `startsOn`/`endsOn` have no defaults for exactly the reason `weekdays` didn't get one: the upsert
    /// assigns every column it is given, so a defaulted window would be erased by any edit to the hours.
    private func save(subject: TargetSubject, seconds: TimeInterval,
                      direction: Target.Direction, period: Target.Period,
                      weekdays: Weekdays, startsOn: Date?, endsOn: Date?, interval: Int) {
        try? store.setTarget(subject: subject, seconds: seconds,
                             direction: direction, period: period, weekdays: weekdays,
                             startsOn: startsOn, endsOn: endsOn, interval: interval)
        reload()
    }

    private func hoursLabel(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h)
    }
}

/// The budget amount, in hours, as an editable field.
///
/// Its own view so each row keeps its own draft text: a shared `@State` in the parent would reset
/// every row's edit whenever any row saved.
struct HoursField: View {
    let seconds: TimeInterval
    let onCommit: (TimeInterval) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
            .focused($focused)
            .onSubmit { commit() }
            // Clicking away commits too, rather than silently discarding what was typed.
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onAppear { text = format(seconds) }
            // Follow external changes ALWAYS, including while focused. `seconds` only changes on an
            // explicit action (± or the period picker) — typing alone doesn't touch it until commit —
            // so there's nothing to overwrite, and gating this on focus was what made ± do nothing
            // while the cursor sat in the field.
            .onChange(of: seconds) { _, new in text = format(new) }
            // Digits, at most one dot, at most one decimal place. Filtered as you type rather than
            // rejected on commit, so the field can't hold something it will silently discard.
            .onChange(of: text) { _, new in
                let cleaned = NumericInput.hours(new)
                if cleaned != new { text = cleaned }
            }
    }


    private func commit() {
        guard let hours = Double(text), hours > 0 else {
            text = format(seconds)      // unparseable: put the old value back rather than zeroing
            return
        }
        onCommit(min(max(hours, 0.1), 10_000) * 3600)
    }

    private func format(_ s: TimeInterval) -> String {
        let h = s / 3600
        return h == h.rounded() ? "\(Int(h))" : String(format: "%.1f", h)
    }
}

/// Four L-shaped corner ticks, marking out a scrollable region without boxing it in.
///
/// A full border would make the list a container and lose the blended-into-the-sheet look that's
/// worth keeping; nothing at all leaves the fact that it scrolls to be discovered by accident.
struct ScrollCorners: Shape {
    /// Length of each arm. Long enough to read as a deliberate mark, short enough not to imply a box.
    var arm: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Each corner is two arms from the corner point, so the stroke joins cleanly instead of
        // drawing two overlapping segments with a doubled-opacity pixel where they meet.
        for corner in [(rect.minX, rect.minY, 1.0, 1.0),
                       (rect.maxX, rect.minY, -1.0, 1.0),
                       (rect.minX, rect.maxY, 1.0, -1.0),
                       (rect.maxX, rect.maxY, -1.0, -1.0)] {
            let (x, y, dx, dy) = corner
            path.move(to: CGPoint(x: x + arm * dx, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + arm * dy))
        }
        return path
    }
}
