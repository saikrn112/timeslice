import Foundation

/// Builds the displayable budget rows: subject name, colour, the three time windows a budget needs,
/// and the verdict ordering.
///
/// Hoisted out of the Mac's `MetricsView` because the phone's Budgets screen needs the identical
/// composition, and it is *not* a one-liner — each row measures its subject over three separate
/// windows (its own period, today, and the range being viewed) and the choice of window per figure
/// is the whole reason the numbers mean anything. Rebuilding that sequence on the phone is the most
/// likely place for the two platforms to quietly disagree.
public enum BudgetRows {

    /// Everything a budget row needs to render, beyond `TargetProgress` itself.
    public struct Row: Identifiable, Sendable {
        public let progress: TargetProgress
        /// `#RRGGBB` for the bar fill and sparkline tint — the subject's own colour.
        public let colorHex: String
        /// Per-bucket seconds over the *viewed* range, for the sparkline.
        public let sparkline: [TimeInterval]

        public var id: Int64 { progress.target.id }

        public init(progress: TargetProgress, colorHex: String, sparkline: [TimeInterval]) {
            self.progress = progress
            self.colorHex = colorHex
            self.sparkline = sparkline
        }
    }

    /// Resolve a subject to its display name, or nil when the subject no longer exists (a deleted
    /// task/project/tag leaves a target that should simply not render).
    public static func name(
        for subject: TargetSubject, tasks: [Project], groups: [TaskProject], tags: [Tag]
    ) -> String? {
        switch subject {
        case .task(let id): return tasks.first { $0.id == id }?.name
        case .project(let id): return groups.first { $0.id == id }?.name
        case .tag(let id): return tags.first { $0.id == id }?.name
        }
    }

    /// The subject's colour. A task's colour is its *display* colour, so a task inside a project
    /// shows the project's shade — matching the list and the Dynamic Island.
    public static func colorHex(
        for subject: TargetSubject, tasks: [Project], groups: [TaskProject], tags: [Tag]
    ) -> String {
        switch subject {
        case .tag(let id): return tags.first { $0.id == id }?.colorHex ?? "#8E8E93"
        case .project(let id): return groups.first { $0.id == id }?.colorHex ?? "#8E8E93"
        case .task(let id):
            guard let task = tasks.first(where: { $0.id == id }) else { return "#8E8E93" }
            return Palette.displayColorHex(for: task, groups: groups, allTasks: tasks)
        }
    }

    /// Trouble first: breached ceilings, then things falling behind, then on-pace, then met.
    public static func rank(_ verdict: TargetProgress.Verdict) -> Int {
        switch verdict {
        case .over: return 0
        case .behind: return 1
        case .onPace: return 2
        case .met: return 3
        }
    }

    /// Build every renderable row, sorted with trouble first.
    ///
    /// Each target is measured against **its own period**, not the range being browsed. Scaling onto
    /// the range was worse in practice: a 5h weekly budget viewed on a day became "42m", which is
    /// arithmetically right and completely meaningless. A budget answers "am I on track this week",
    /// and that shouldn't change because you're looking at Tuesday.
    ///
    /// - Parameters:
    ///   - viewedRange: the range the UI is showing, used for the share figure and the sparkline.
    ///   - intervals: candidate intervals; each window clips them itself, so pass a superset.
    public static func build(
        targets: [Target],
        tasks: [Project],
        groups: [TaskProject],
        tags: [Tag],
        tagIDsByTask: [Int64: Set<Int64>],
        intervals: [Interval],
        viewedRange: DateRange,
        now: Date = Date()
    ) -> [Row] {
        // Calendar days in the range being viewed, and how many have begun — feeds the pro-rated
        // figure, which re-reads the same budget at whatever zoom the filter is set to.
        let viewedRangeDays = max(1, (viewedRange.end.timeIntervalSince(viewedRange.start) / 86_400).rounded())

        return targets.compactMap { target -> Row? in
            guard let name = name(for: target.subject, tasks: tasks, groups: groups, tags: tags)
            else { return nil }

            let unit: RangeUnit = {
                switch target.period {
                case .day: return .day
                case .week: return .week
                case .month: return .month
                }
            }()
            // The budget's OWN period — the window the verdict is judged in.
            let window = DateRange.resolve(unit: unit, anchor: now)
            let secs = Aggregations.secondsForSubject(
                target.subject, intervals: intervals, tasks: tasks,
                tagIDsByTask: tagIDsByTask, range: window, now: now)
            // Today's slice of the same subject, for the per-day column. Period-independent —
            // "today" means today whatever range you're browsing.
            let today = Aggregations.secondsForSubject(
                target.subject, intervals: intervals, tasks: tasks,
                tagIDsByTask: tagIDsByTask, range: DateRange.resolve(unit: .day, anchor: now),
                now: now)
            // The subject's slice of the RANGE BEING VIEWED, for the share figure. A separate clock
            // from the budget period above, on purpose.
            let inRange = Aggregations.secondsForSubject(
                target.subject, intervals: intervals, tasks: tasks,
                tagIDsByTask: tagIDsByTask, range: viewedRange, now: now)

            let progress = TargetMath.progress(
                target: target, name: name, actualSeconds: secs,
                rangeStart: window.start, rangeEnd: window.end, now: now,
                todaySeconds: today, rangeSeconds: inRange,
                viewedRangeDays: viewedRangeDays)

            let ids = Aggregations.taskIDs(for: target.subject, tasks: tasks,
                                          tagIDsByTask: tagIDsByTask)
            let spark = ids.isEmpty ? [] : Aggregations.sparkline(
                intervals: intervals.filter { ids.contains($0.projectID) }, range: viewedRange,
                now: now)

            return Row(progress: progress,
                       colorHex: colorHex(for: target.subject, tasks: tasks, groups: groups, tags: tags),
                       sparkline: spark)
        }
        .sorted { rank($0.progress.verdict) < rank($1.progress.verdict) }
    }

    /// Duration for budget rows: hours and minutes, never days.
    ///
    /// `Format.compact` rolls over to "1d 16h" past 24 hours, which is unreadable as a *budget* —
    /// a 40h weekly target rendered as "1d 16h". Budgets are always talked about in hours.
    ///
    /// In Core beside the rows rather than in the UI layer so the phone can't quietly format a
    /// budget differently from the Mac.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total <= 0 { return "0" }
        if total < 60 { return "\(total)s" }
        let h = total / 3600, m = (total % 3600) / 60
        if h == 0 { return "\(m)m" }
        // Past 100h the minutes are noise, and they overflowed the column — a year view showed
        // "107h 2…" and "2085h…".
        if h >= 100 || m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}
