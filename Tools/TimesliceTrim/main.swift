import Foundation
import TimesliceCore

/// Cuts a span out of one recorded interval, through the store's own `deleteIntervalSlice`.
///
/// Corrections like "that 40 minutes was really 20" come up regularly, and until now they were done
/// either by hand in the UI or with raw SQL. Raw SQL is the wrong tool: an interval is a synced fact
/// keyed by a uid, so a correction has to tombstone the original and re-insert the surviving pieces
/// under fresh uids, or the old row simply comes back from another device on the next merge. That logic
/// already exists and is tested — this only reaches it from a shell.
///
///     swift run TimesliceTrim --db <path> --id 2353 --from "2026-09-27 07:10:50" --to "2026-09-27 07:31:41"
///     swift run TimesliceTrim --db <path> --id 2353 --keep-minutes 20
///
/// `--keep-minutes` is the common case: keep the first N minutes of the interval and cut the rest.
/// Prints the row before and after, and refuses a running interval (its end moves with the clock, so
/// the span being cut wouldn't be the span you asked for).

func value(for flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func describe(_ i: Interval, _ name: String) -> String {
    let end = i.end.map { formatter.string(from: $0) } ?? "running"
    let mins = (i.end ?? Date()).timeIntervalSince(i.start) / 60
    return String(format: "  [%d] %@  %@ → %@  %.1fm  %@",
                  i.id, name, formatter.string(from: i.start), end, mins, i.deviceID ?? "-")
}

do {
    guard let dbPath = value(for: "--db"), let idRaw = value(for: "--id"), let id = Int64(idRaw) else {
        print("usage: TimesliceTrim --db <path> --id <interval id> "
              + "[--keep-minutes N | --from \"y-M-d H:m:s\" --to \"y-M-d H:m:s\"] [--apply]")
        exit(2)
    }
    let store = try IntervalStore(databaseURL: URL(fileURLWithPath: dbPath))
    try store.migrateIfNeeded()
    let names = Dictionary(uniqueKeysWithValues: try store.listProjects(includeArchived: true)
        .map { ($0.id, $0.name) })
    guard let target = try store.intervals().first(where: { $0.id == id }) else {
        print("no interval \(id)"); exit(1)
    }
    print("before:"); print(describe(target, names[target.projectID] ?? "?"))
    guard let end = target.end else { print("refused: interval is running"); exit(1) }

    let from: Date
    let to: Date
    if let keep = value(for: "--keep-minutes").flatMap(Double.init) {
        from = target.start.addingTimeInterval(keep * 60)
        to = end
    } else if let f = value(for: "--from").flatMap(formatter.date(from:)),
              let t = value(for: "--to").flatMap(formatter.date(from:)) {
        from = f; to = t
    } else {
        print("need --keep-minutes or --from/--to"); exit(2)
    }
    print(String(format: "cutting %@ → %@ (%.1fm)", formatter.string(from: from),
                 formatter.string(from: to), to.timeIntervalSince(from) / 60))

    // Dry run by default. A correction is a write to real data, so it takes an explicit --apply.
    guard CommandLine.arguments.contains("--apply") else {
        print("dry run — pass --apply to write"); exit(0)
    }
    let pieces = try store.deleteIntervalSlice(id: id, from: from, to: to)
    guard pieces >= 0 else { print("refused by the store"); exit(1) }
    print("after: \(pieces) piece(s) kept")
    for i in try store.intervals() where i.projectID == target.projectID
        && i.start >= target.start.addingTimeInterval(-1) && i.start <= end {
        print(describe(i, names[i.projectID] ?? "?"))
    }
} catch {
    print("failed: \(error)")
    exit(1)
}
