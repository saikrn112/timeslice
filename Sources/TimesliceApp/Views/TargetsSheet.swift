import SwiftUI
import TimesliceCore

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
    @State private var showTasks = false
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
        .frame(width: 680, height: 560)
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
                if showTasks {
                    TextField("Find a task", text: $taskQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                Button(showTasks ? "Hide" : "Show") { showTasks.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            Text("For a one-off goal that doesn't deserve a project of its own.")
                .font(.caption2).foregroundStyle(.secondary)

            if showTasks {
                // FIXED height, scrolled inside. Letting the list size to its contents made the
                // whole sheet grow and shrink on every keystroke as the match count changed, which
                // is unusable for typing into.
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
                .frame(height: 168)
            } else if !taskTargets.isEmpty {
                // Tasks that already HAVE an allocation stay visible while the section is collapsed,
                // or setting one would feel like it hadn't been saved.
                ForEach(taskTargets) { task in
                    subjectRow(name: task.name,
                               colorHex: appState.displayColorHex(for: task),
                               subject: .task(task.id), onDelete: nil)
                }
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
                Text("PAST ALLOCATIONS")
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
    private func subjectRow(name: String, colorHex: String, subject: TargetSubject,
                            onDelete: (() -> Void)?) -> some View {
        let existing = targets.first { $0.subject == subject }
        return HStack(spacing: 8) {
            Circle().fill(Color(hex: colorHex)).frame(width: 9, height: 9)
            Text(name).font(.callout).lineLimit(1).truncationMode(.tail)
                .frame(width: 150, alignment: .leading)

            // Budget controls sit at the RIGHT, just before delete — for both tags and projects — so
            // the "Set budget" link and the populated controls occupy the same place.
            Spacer(minLength: 4)

            if let existing {
                // Direction: tap to flip between a floor and a ceiling.
                Button(existing.direction.symbol) {
                    save(subject: subject, seconds: existing.seconds,
                         direction: existing.direction == .atLeast ? .atMost : .atLeast,
                         period: existing.period)
                }
                .buttonStyle(.bordered)
                .help(existing.direction == .atLeast
                      ? "At least this much — tap for a limit instead"
                      : "At most this much — tap for a minimum instead")

                Button("−") {
                    save(subject: subject, seconds: max(1800, existing.seconds - 1800),
                         direction: existing.direction, period: existing.period)
                }.buttonStyle(.borderless)
                // Typeable, not just steppable: reaching 160h in half-hour clicks is 320 presses.
                HoursField(seconds: existing.seconds) { secs in
                    save(subject: subject, seconds: secs,
                         direction: existing.direction, period: existing.period)
                }
                Button("+") {
                    save(subject: subject, seconds: existing.seconds + 1800,
                         direction: existing.direction, period: existing.period)
                }.buttonStyle(.borderless)

                Picker("", selection: Binding(
                    get: { existing.period },
                    set: { save(subject: subject, seconds: existing.seconds,
                                direction: existing.direction, period: $0) }
                )) {
                    ForEach(Target.Period.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .labelsHidden()
                .frame(width: 84)

                // Retire rather than delete: the allocation leaves the live list but keeps its
                // history, which is the whole reason for the state.
                // Spelled out, not a tick. A bare checkmark next to a value reads as "confirm
                // this number", which is not what it does — it retires the allocation.
                Button("Done") {
                    try? store.setTargetCompleted(id: existing.id, completed: true)
                    reload()
                }
                .buttonStyle(.link).font(.system(size: 11))
                .help("Finished with this — moves it to past allocations")

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
                    // A weekly floor is the common case; both are one tap from here.
                    save(subject: subject, seconds: 5 * 3600, direction: .atLeast, period: .week)
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

    private func save(subject: TargetSubject, seconds: TimeInterval,
                      direction: Target.Direction, period: Target.Period) {
        try? store.setTarget(subject: subject, seconds: seconds,
                             direction: direction, period: period)
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
private struct HoursField: View {
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
