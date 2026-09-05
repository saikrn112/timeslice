import Foundation
import TimesliceCore

/// Seeds a Timeslice database with demo data.
///
/// Exists because the iOS app's database lives inside a simulator container — an ordinary file on
/// disk that a macOS tool can open directly. That's far better than hand-writing SQL: going through
/// `IntervalStore` means uids, `updated_at`, migrations and the one-running-interval index are all
/// correct, so the seeded database is one sync could actually replicate.
///
///     swift run TimesliceSeed --preset rich --db "<container>/Library/Application Support/Timeslice/timeslice.db"
///
/// With no `--db` it targets this Mac's demo database, never the real one.
let args = ProcessInfo.processInfo.arguments

func value(for flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let presetName = value(for: "--preset") ?? "rich"
guard let preset = DemoSeed.Preset(rawValue: presetName) else {
    print("unknown preset '\(presetName)' — use screenshot | rich")
    exit(2)
}

let dbPath = value(for: "--db")
    ?? TimeslicePaths.defaultSupportDirectoryURL()
        .appendingPathComponent("timeslice-demo.db").path

do {
    let store = try IntervalStore(databaseURL: URL(fileURLWithPath: dbPath))
    try store.migrateIfNeeded()
    try DemoSeed.seed(into: store, preset: preset)

    let tasks = try store.listProjects(includeArchived: true)
    let groups = try store.listTaskProjects()
    let tags = try store.listTags()
    let targets = try store.listTargets()
    let intervals = try store.intervals()
    let devices = try store.deviceLabels()
    let earliest = try store.earliestIntervalStart()

    print("seeded \(preset.rawValue) → \(dbPath)")
    print("  \(groups.count) projects, \(tasks.count) tasks, \(tags.count) tags, \(targets.count) budgets")
    print("  \(intervals.count) intervals across \(devices.count) device(s)")
    if let earliest {
        let days = Int(Date().timeIntervalSince(earliest) / 86_400)
        print("  history spans ~\(days) days (from \(earliest))")
    }
} catch {
    print("seed failed: \(error)")
    exit(1)
}
