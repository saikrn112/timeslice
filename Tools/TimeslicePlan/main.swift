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
