import Foundation
import TimesliceCore

/// Prints the plan for a real database.
///
/// A separate executable for the same reason `TimesliceSeed` is one: the macOS UI can't be
/// screenshotted headlessly (screen capture needs a TCC grant, and the attempts capture whatever is
/// frontmost), so "does the Planner show the right numbers" has to be answerable another way. This
/// runs the SAME `Planner` the view runs, against the same database, and prints what it computed — so
/// the figures on screen can be checked against arithmetic that can also be reproduced in SQL.
///
///     swift run TimeslicePlan --db ~/Library/Application\ Support/Timeslice/timeslice.db
///
/// Read-only. It opens the store, computes, prints, and writes nothing.

func value(for flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

let dbPath = value(for: "--db")
    ?? NSString(string: "~/Library/Application Support/Timeslice/timeslice.db").expandingTildeInPath
let wakingHours = Double(value(for: "--waking") ?? "") ?? 16

func hrs(_ seconds: TimeInterval) -> String { String(format: "%.1fh", seconds / 3600) }

do {
    let store = try IntervalStore(databaseURL: URL(fileURLWithPath: dbPath))
    try store.migrateIfNeeded()

    let targets = try store.listTargets()
    let reservations = try store.listReservations()
    let tasks = try store.listProjects(includeArchived: true)
    let groups = try store.listTaskProjects()
    let tags = try store.listTags()
    let membership = SubjectMembership(tasks: tasks,
                                      tagIDsByTask: try store.effectiveTagIDsByTask())
    var names: [Int64: String] = [:]
    for t in targets {
        names[t.id] = BudgetRows.name(for: t.subject, tasks: tasks, groups: groups, tags: tags)
            ?? "(deleted)"
    }

    // Where each tracked hour of the current week actually LANDS, which is the question a column of blocks
    // answers and the only way to check it without a screenshot.
    let calendar = Calendar.current
    if let week = calendar.dateInterval(of: .weekOfYear, for: Date()) {
        let floors = targets.filter { $0.direction == .atLeast }
        let subjects = Dictionary(uniqueKeysWithValues: floors.map { ($0.id, $0.subject) })
        let intervals = try store.intervals(from: week.start, to: week.end)
        var byDay: [Int: [Int64?: TimeInterval]] = [:]
        for interval in intervals {
            let end = interval.end ?? Date()
            guard end > interval.start else { continue }
            let weekday = calendar.component(.weekday, from: interval.start)
            let owner = membership.primaryOwner(of: interval.projectID, among: subjects)
            byDay[weekday, default: [:]][owner, default: 0] += end.timeIntervalSince(interval.start)
        }
        print("\nwhere this week's hours land (most specific allocation wins):")
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        for weekday in 1...7 {
            guard let entries = byDay[weekday] else { continue }
            let total = entries.values.reduce(0, +) / 3600
            print(String(format: "  %@  %.1fh total", dayNames[weekday - 1], total))
            for (owner, seconds) in entries.sorted(by: { $0.value > $1.value }) {
                let label = owner.flatMap { names[$0] } ?? "off-plan"
                print(String(format: "      %-28@ %.2fh", label as NSString, seconds / 3600))
            }
        }
    }

    // What each remaining day is asked for, per allocation, split into its own share and what was moved
    // onto it. This is what the week grid draws, so a disagreement between the two is a view bug.
    if let week = calendar.dateInterval(of: .weekOfYear, for: Date()) {
        let floors = targets.filter { $0.direction == .atLeast }
        let today = calendar.component(.weekday, from: Date())
        let intervals = try store.intervals(from: week.start, to: week.end)
        var credited: [Int: [Int64: TimeInterval]] = [:]
        for interval in intervals {
            let end = interval.end ?? Date()
            guard end > interval.start else { continue }
            let weekday = calendar.component(.weekday, from: interval.start)
            let seconds = end.timeIntervalSince(interval.start)
            for target in floors
            where membership.taskIDs(for: target.subject).contains(interval.projectID) {
                credited[weekday, default: [:]][target.id, default: 0] += seconds
            }
        }
        let input = Planner.Input(targets: targets, reservations: reservations,
                                  membership: membership, names: names,
                                  wakingSecondsPerDay: wakingHours * 3600)
        let built = Planner.plan(input)
        // Nested allocations are skipped, exactly as the app skips them: their hours are already inside a
        // parent's share, and counting them again drains a day's room twice. A diagnostic that models
        // something other than the page it's diagnosing is worse than none.
        let nested = Set(built.nestings.compactMap { nesting in
            targets.first { names[$0.id] == nesting.innerName }?.id
        })
        let fraction = Replan.fractionOfDayLeft(now: Date(), wakingSeconds: wakingHours * 3600)
        let daily = Replan.dailyPlan(input: input, plan: built, creditedByWeekday: credited,
                                     remainingWeekdays: Array(today...7),
                                     fractionOfTodayLeft: fraction,
                                     skipping: nested)
        if !nested.isEmpty {
            print("\nskipped as nested: "
                  + nested.compactMap { names[$0] }.sorted().joined(separator: ", "))
        }
        let dayNames2 = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        print(String(format: "\nwhat the remaining days are asked for (%.0f%% of today left):",
                     fraction * 100))
        for weekday in today...7 {
            guard let shares = daily.byDay[weekday], !shares.isEmpty else { continue }
            let room = built.days.first { $0.weekday == weekday }
                .map { ($0.capacitySeconds - $0.reservedSeconds)
                        * (weekday == today ? fraction : 1) / 3600 } ?? 0
            print(String(format: "  %@  room %.1fh", dayNames2[weekday - 1], room))
            for (id, share) in shares.sorted(by: { $0.value.total > $1.value.total }) {
                print(String(format: "      %-24@ own %.2fh  moved %.2fh",
                             (names[id] ?? "?") as NSString,
                             share.intended / 3600, share.carried / 3600))
            }
        }
        for (id, seconds) in daily.unplaced {
            print(String(format: "  no room: %@ %.2fh", (names[id] ?? "?") as NSString, seconds / 3600))
        }
        for (id, seconds) in daily.outOfDays {
            print(String(format: "  no days left: %@ %.2fh", (names[id] ?? "?") as NSString,
                         seconds / 3600))
        }
    }

    let plan = Planner.plan(Planner.Input(
        targets: targets, reservations: reservations, membership: membership, names: names,
        wakingSecondsPerDay: wakingHours * 3600))

    print("database: \(dbPath)")
    print("waking:   \(hrs(plan.capacitySeconds / 7)) a day, \(hrs(plan.capacitySeconds)) a week")
    print("")
    print("committed: \(hrs(plan.requiredLowerSeconds)) certainly … \(hrs(plan.requiredUpperSeconds)) if nothing shares")
    print("reserved:  \(hrs(plan.reservedSeconds))")
    print("free:      \(hrs(max(0, plan.capacitySeconds - plan.reservedSeconds)))")
    print("verdict:   \(plan.verdict)")
    print("")
    print("per day:")
    let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    for day in plan.days {
        let bar = String(repeating: "#", count: Int((day.committedSeconds / 3600).rounded()))
        let flag = day.isOverCapacity ? "  OVER by \(hrs(-day.slackSeconds))" : ""
        print("  \(dayNames[day.weekday - 1])  reserved \(hrs(day.reservedSeconds))"
              + "  committed \(hrs(day.committedSeconds))  free \(hrs(day.freeSeconds))"
              + "  \(bar)\(flag)")
        for p in day.placements.sorted(by: { $0.seconds > $1.seconds }) {
            print("        \(p.name): \(hrs(p.seconds))")
        }
    }
    if !plan.unplaced.isEmpty {
        print("")
        print("won't fit:")
        for u in plan.unplaced {
            print("  \(u.name)  short \(hrs(u.shortfallSeconds))  (\(u.reason))")
            print("        would fit if \(u.wouldFitIf)")
        }
    }
    if !plan.nestings.isEmpty {
        print("")
        print("already counted:")
        for n in plan.nestings {
            print("  \(n.innerName) (\(hrs(n.innerSeconds))) is inside "
                  + "\(n.outerName) (\(hrs(n.outerSeconds)))")
        }
    }
    if !plan.ceilings.isEmpty {
        print("")
        print("limits (never counted against the week):")
        for c in plan.ceilings {
            let name = BudgetRows.name(for: c.subject, tasks: tasks, groups: groups, tags: tags) ?? "?"
            print("  \(name) ≤ \(hrs(c.seconds)) per \(c.period.rawValue)")
        }
    }
    // The backlog, from this week's actuals — the same computation the page shows.
    let cal = Calendar.current
    let now = Date()
    if let week = cal.dateInterval(of: .weekOfYear, for: now) {
        let intervals = try store.intervals(from: week.start, to: week.end)
        var actuals: [Int64: TimeInterval] = [:]
        for t in targets where t.direction == .atLeast {
            let ids = membership.taskIDs(for: t.subject)
            actuals[t.id] = intervals.filter { ids.contains($0.projectID) }.reduce(0.0) { sum, i in
                let end = min(i.end ?? now, week.end), start = max(i.start, week.start)
                return sum + max(0, end.timeIntervalSince(start))
            }
        }
        let today = cal.component(.weekday, from: now)
        let fractionLeft = Replan.fractionOfDayLeft(now: now, wakingSeconds: wakingHours * 3600,
                                                    calendar: cal)
        let replan = Replan.compute(plan: plan, input: Planner.Input(
                targets: targets, reservations: reservations, membership: membership, names: names,
                wakingSecondsPerDay: wakingHours * 3600),
            actuals: actuals, elapsedWeekdays: Array(1..<today),
            remainingWeekdays: Array(today...7), fractionOfTodayLeft: fractionLeft)

        print("")
        print("rest of the week (\(dayNames[today - 1]) onwards, "
              + "\(Int(fractionLeft * 100))% of today left):")
        print("  still needed \(hrs(replan.remainingNeedSeconds))"
              + "  ·  days left can hold \(hrs(replan.remainingCapacitySeconds))"
              + (replan.weekIsLost ? "  ·  WEEK CANNOT BE FINISHED" : ""))
        for item in replan.items.sorted(by: { $0.debtSeconds > $1.debtSeconds }) {
            let debt = item.debtSeconds > 60 ? "behind \(hrs(item.debtSeconds))" : "on pace"
            let per = item.requiredPerRemainingDay.map { "\(hrs($0))/day" } ?? "no days left"
            print("  \(item.name): \(hrs(item.doneSeconds)) of \(hrs(item.targetSeconds))"
                  + "  \(debt)  needs \(per) × \(item.remainingClaimedDays)  [\(item.standing)]")
            if !item.adviceIfUnreachable.isEmpty { print("        → \(item.adviceIfUnreachable)") }
            if item.standing == .unreachable || item.debtSeconds > 60 {
                print("        need \(hrs(item.remainingSeconds)) · room "
                      + "\(hrs(item.availableOnRemainingDays)) on those days"
                      + (item.blockers.isEmpty ? "" : "  ·  taken by "
                         + item.blockers.map { "\($0.name) \(hrs($0.secondsOnThoseDays))" }
                             .joined(separator: ", ")))
            }
        }
    }

    // The month, week by week — the same `PlannerMonth.rollups` the month view draws, so "why is my
    // backlog sitting in the pool instead of moving forward" is answerable as arithmetic.
    // `--month 0` is this month, `1` the previous one.
    if let monthArg = value(for: "--month"), let back = Int(monthArg) {
        let cal = Calendar.current
        let now = Date()
        let base = cal.date(byAdding: .month, value: -back, to: now) ?? now
        if let month = cal.dateInterval(of: .month, for: base) {
            let intervals = try store.intervals(from: month.start, to: month.end)
            let floors = targets.filter { $0.direction == .atLeast }
            let nested = Set(plan.nestings.compactMap { nesting in
                targets.first { names[$0.id] == nesting.innerName }?.id
            })
            for methodName in ["catch up", "per week"] {
                let method: Replan.Method = methodName == "catch up" ? .catchUp : .perDay
                let rollups = PlannerMonth.rollups(
                    month: month, intervals: intervals, floors: floors, membership: membership,
                    nested: nested, wakingSeconds: wakingHours * 3600, method: method,
                    fractionOfTodayLeft: Replan.fractionOfDayLeft(
                        now: now, wakingSeconds: wakingHours * 3600, calendar: cal),
                    now: now, calendar: cal)
                print("")
                print("month by week — \(methodName)")
                for r in rollups {
                    let asked = r.owed.values.reduce(0.0) { $0 + $1.total }
                    print("  \(r.span.firstDay)–\(r.span.lastDay): counted \(hrs(r.capacity))"
                          + " · room \(hrs(r.room)) · asked \(hrs(asked))"
                          + " · free after \(hrs(max(0, r.room - asked)))"
                          + " · pool \(hrs(r.leftover.values.reduce(0, +)))")
                    for (id, share) in r.owed.sorted(by: { $0.value.total > $1.value.total })
                    where share.total > 60 {
                        print("      plan \(names[id] ?? "?"): \(hrs(share.total))"
                              + " (own \(hrs(share.intended)), moved in \(hrs(share.carried)))"
                              + " of want \(hrs(r.want[id] ?? 0))")
                    }
                    for (id, seconds) in r.leftover.sorted(by: { $0.value > $1.value })
                    where seconds > 60 {
                        print("      pool \(names[id] ?? "?"): \(hrs(seconds))")
                    }
                }
                let goalTotal = floors.filter { !nested.contains($0.id) }
                    .reduce(0.0) { $0 + PlannerMonth.goal(for: $1, month: month, calendar: cal) }
                let placed = rollups.reduce(0.0) { $0 + $1.owed.values.reduce(0) { $0 + $1.total } }
                let pooled = rollups.reduce(0.0) { $0 + $1.leftover.values.reduce(0, +) }
                let room = rollups.reduce(0.0) { $0 + $1.room }
                print("  month goal \(hrs(goalTotal)) · room left \(hrs(room))"
                      + " · planned \(hrs(placed)) · pooled \(hrs(pooled))")
            }
        }
    }

    print("")
    // Nested allocations are skipped: they don't compete for capacity, so their ceiling is the whole
    // week and saying so is noise.
    let nestedNames = Set(plan.nestings.map(\.innerName))
    print("frontier — the most each could ask for, everything else held:")
    for t in targets where t.direction == .atLeast && !nestedNames.contains(names[t.id] ?? "") {
        let ceiling = Planner.frontier(for: t.id, in: Planner.Input(
            targets: targets, reservations: reservations, membership: membership, names: names,
            wakingSecondsPerDay: wakingHours * 3600))
        print("  \(names[t.id] ?? "?"): now \(hrs(t.weeklySeconds)) → at most \(hrs(ceiling))")
    }
} catch {
    FileHandle.standardError.write("failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
