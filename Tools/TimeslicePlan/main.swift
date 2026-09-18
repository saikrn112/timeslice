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
