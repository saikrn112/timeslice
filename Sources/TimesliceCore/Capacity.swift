import Foundation

/// Where a period's *available* hours stand: how many are spent, how many are still owed to a
/// commitment, and how many are genuinely free.
///
/// The metrics hero could already say "Waking 33%" — one ratio, with its denominator invisible and no
/// hint of what the other 67% was promised to. Budgets answered the mirror question per allocation
/// ("6h of 10h this week") but never added up, so "how much of my day is already spoken for" had no
/// answer anywhere in either app.
///
/// It lives in Core, and not as three lines in the view, because the arithmetic has exactly one
/// non-obvious rule in it — see `owed` below — and a rule that subtle will not survive being written
/// twice.
public enum Capacity {

    /// One commitment's contribution, after de-duplication.
    public struct Share: Identifiable, Sendable {
        public let targetID: Int64
        public let subject: TargetSubject
        public let name: String
        public let colorHex: String
        /// Seconds this commitment adds to the total, already stripped of anything a narrower
        /// commitment inside it accounts for. Can be less than the target's own shortfall.
        public let seconds: TimeInterval

        public var id: Int64 { targetID }

        public init(targetID: Int64, subject: TargetSubject, name: String, colorHex: String,
                    seconds: TimeInterval) {
            self.targetID = targetID
            self.subject = subject
            self.name = name
            self.colorHex = colorHex
            self.seconds = seconds
        }
    }

    /// The whole and its parts. `tracked + owed + free == capacity` unless `isOvercommitted`.
    public struct Breakdown: Sendable {
        /// Waking hours in the range: the setting times the range's calendar days.
        public let capacitySeconds: TimeInterval
        /// Time actually recorded in the range, committed or not.
        public let trackedSeconds: TimeInterval
        /// Unmet floors, de-duplicated across overlapping scopes.
        public let owedSeconds: TimeInterval
        /// What's left after both. Floored at zero.
        public let freeSeconds: TimeInterval
        /// Which commitments the owed hours belong to, largest first.
        public let owed: [Share]
        /// Ceilings and their remaining headroom, largest first. Not part of `owedSeconds`: a cap
        /// you're trying to stay under is a limit, not an obligation, so reserving hours for it would
        /// invert what it means.
        public let limits: [Share]
        /// True when what's tracked plus what's owed exceeds the hours available — the promises don't
        /// fit in the period. Worth saying out loud rather than silently clamping `free` to zero.
        public let isOvercommitted: Bool

        /// Fractions of capacity, for drawing. Zero-capacity yields zeros rather than NaN, which
        /// would silently collapse a bar to nothing.
        public var trackedFraction: Double {
            capacitySeconds > 0 ? min(1, trackedSeconds / capacitySeconds) : 0
        }
        public var owedFraction: Double {
            guard capacitySeconds > 0 else { return 0 }
            return min(1 - trackedFraction, owedSeconds / capacitySeconds)
        }
        public var freeFraction: Double {
            capacitySeconds > 0 ? max(0, 1 - trackedFraction - owedFraction) : 0
        }

        public init(capacitySeconds: TimeInterval, trackedSeconds: TimeInterval,
                    owedSeconds: TimeInterval, freeSeconds: TimeInterval,
                    owed: [Share], limits: [Share], isOvercommitted: Bool) {
            self.capacitySeconds = capacitySeconds
            self.trackedSeconds = trackedSeconds
            self.owedSeconds = owedSeconds
            self.freeSeconds = freeSeconds
            self.owed = owed
            self.limits = limits
            self.isOvercommitted = isOvercommitted
        }
    }

    /// Calendar days in a range, counted by day boundaries rather than by dividing by 86,400.
    ///
    /// A DST week is 167 or 169 hours long, so the division gives 6.96 or 7.04 days and the capacity
    /// for that week comes out an hour wrong — small, but it's the same class of bug the project
    /// already banned from every other total.
    public static func days(in range: DateRange, calendar: Calendar = .current) -> Double {
        let from = calendar.startOfDay(for: range.start)
        let to = calendar.startOfDay(for: range.end)
        let counted = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        // A range shorter than a day (or an empty one) still has one day of capacity, otherwise the
        // bar divides by zero on the day view's first instant.
        return Double(max(1, counted))
    }

    /// Build the breakdown for a range.
    ///
    /// - Parameters:
    ///   - rows: the budget rows for this range, already built by `BudgetRows.build`. Their
    ///     `rangeExpectedSeconds` / `rangeSeconds` are the pro-rated pair this needs — a weekly
    ///     target read on a single day must contribute its daily slice, not its whole week.
    ///   - wakingSecondsPerDay: `Settings.wakingSeconds`.
    ///   - trackedSeconds: the range's total from `Aggregations.summary`, so the bar cannot disagree
    ///     with the number printed beside it.
    public static func breakdown(
        rows: [BudgetRows.Row],
        wakingSecondsPerDay: TimeInterval,
        range: DateRange,
        trackedSeconds: TimeInterval,
        tasks: [Project],
        tagIDsByTask: [Int64: Set<Int64>],
        calendar: Calendar = .current
    ) -> Breakdown {
        let capacity = max(0, wakingSecondsPerDay) * days(in: range, calendar: calendar)

        // Shortfall per floor, before de-duplication: what this target still wants within the range.
        var shortfalls: [(row: BudgetRows.Row, ids: Set<Int64>, seconds: TimeInterval)] = []
        var limits: [Share] = []
        for row in rows {
            let p = row.progress
            let ids = Aggregations.taskIDs(for: p.target.subject, tasks: tasks,
                                          tagIDsByTask: tagIDsByTask)
            switch p.target.direction {
            case .atLeast:
                let short = max(0, p.rangeExpectedSeconds - p.rangeSeconds)
                guard short > 0 else { continue }
                shortfalls.append((row, ids, short))
            case .atMost:
                limits.append(Share(targetID: p.target.id, subject: p.target.subject, name: p.name,
                                    colorHex: row.colorHex,
                                    seconds: max(0, p.rangeExpectedSeconds - p.rangeSeconds)))
            }
        }

        // The one rule worth having a file for: overlapping scopes must not double-book an hour.
        //
        // A tag "Deep Work ≥ 10h/wk" that covers a project "Timeslice ≥ 6h/wk" describes 10 hours of
        // intent, not 16 — the project's six are *part of* the tag's ten. Summing raw shortfalls made
        // committed time exceed the hours in the day, which would discredit the whole figure.
        //
        // So a commitment contributes its own shortfall minus whatever its narrower commitments
        // already account for. "Narrower" is decided by task-id containment, since that's what a
        // target actually resolves to; a tag and a project that merely *overlap* (neither contains the
        // other) both count in full, which can overstate — but the alternative is choosing whose hours
        // they are, and there's no honest basis for that choice.
        //
        // Only *maximal* descendants are subtracted. With task ⊂ project ⊂ tag, subtracting both from
        // the tag would remove the task's hours twice and understate what's owed.
        //
        // Targets resolving to the SAME tasks are handled first, and by max rather than by subtraction.
        // A tag that happens to cover exactly one project produces two targets over an identical task
        // set: neither contains the other, so containment alone left both counting in full — "≥10h
        // Deep Work" plus "≥6h Timeslice" over the same work reading as 16h. They describe the same
        // hours, so the binding one is simply the larger.
        var scopes: [(ids: Set<Int64>, seconds: TimeInterval, index: Int)] = []
        for (i, entry) in shortfalls.enumerated() {
            if let existing = scopes.firstIndex(where: { $0.ids == entry.ids }) {
                // Deterministic on ties: the lower target id wins, so the row that gets named doesn't
                // depend on target ordering.
                let incumbent = shortfalls[scopes[existing].index]
                let takes = entry.seconds > scopes[existing].seconds
                    || (entry.seconds == scopes[existing].seconds
                        && entry.row.progress.target.id < incumbent.row.progress.target.id)
                if takes { scopes[existing].seconds = entry.seconds; scopes[existing].index = i }
                else { scopes[existing].seconds = max(scopes[existing].seconds, entry.seconds) }
            } else {
                scopes.append((entry.ids, entry.seconds, i))
            }
        }

        var owed: [Share] = []
        for (i, scope) in scopes.enumerated() {
            let descendants = scopes.indices.filter { j in
                j != i && scopes[j].ids.isStrictSubset(of: scope.ids)
            }
            let maximal = descendants.filter { j in
                !descendants.contains { k in
                    k != j && scopes[j].ids.isStrictSubset(of: scopes[k].ids)
                }
            }
            let accountedFor = maximal.reduce(0) { $0 + scopes[$1].seconds }
            let net = max(0, scope.seconds - accountedFor)
            guard net > 0 else { continue }
            let entry = shortfalls[scope.index]
            owed.append(Share(targetID: entry.row.progress.target.id,
                              subject: entry.row.progress.target.subject,
                              name: entry.row.progress.name,
                              colorHex: entry.row.colorHex,
                              seconds: net))
        }

        let owedTotal = owed.reduce(0) { $0 + $1.seconds }
        let spokenFor = trackedSeconds + owedTotal
        return Breakdown(
            capacitySeconds: capacity,
            trackedSeconds: trackedSeconds,
            owedSeconds: owedTotal,
            freeSeconds: max(0, capacity - spokenFor),
            owed: owed.sorted { $0.seconds > $1.seconds },
            limits: limits.sorted { $0.seconds > $1.seconds },
            isOvercommitted: spokenFor > capacity)
    }
}
