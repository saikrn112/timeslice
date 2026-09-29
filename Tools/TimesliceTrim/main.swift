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

/// `--overlaps` reports (and with `--apply`, removes) every double-counted span in the database.
func reportOverlaps(dbPath: String, apply: Bool, limitMinutes: Double?) throws {
    let store = try IntervalStore(databaseURL: URL(fileURLWithPath: dbPath))
    try store.migrateIfNeeded()
    let names = Dictionary(uniqueKeysWithValues: try store.listProjects(includeArchived: true)
        .map { ($0.id, $0.name) })
    let all = try store.intervals()
    var uids: [Int64: String] = [:]
    for (interval, uid) in try store.intervalsWithUIDs() { uids[interval.id] = uid }
    let limit = (limitMinutes ?? .infinity) * 60
    let clips = OverlapResolver.clips(all, uids: uids).filter { $0.removedSeconds <= limit }
    let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    guard !clips.isEmpty else { print("no overlap"); return }

    var removed: TimeInterval = 0
    for clip in clips {
        removed += clip.removedSeconds
        let name = names[clip.projectID] ?? "?"
        let lost = clip.lostTo.compactMap { id -> String? in
            guard let o = byID[id] else { return nil }
            return "\(names[o.projectID] ?? "?")@\(o.deviceID ?? "-")"
        }.joined(separator: ", ")
        print(String(format: "%@  %@ → %@  %@", formatter.string(from: clip.originalStart),
                     name, clip.deviceID ?? "-", "overlaps \(lost)"))
        print(String(format: "    -%.1fm, keeping %@", clip.removedSeconds / 60,
                     clip.keep.isEmpty
                        ? "nothing (covered entirely)"
                        : clip.keep.map {
                            "\(formatter.string(from: $0.start).suffix(8))–\(formatter.string(from: $0.end).suffix(8))"
                          }.joined(separator: " + ")))
    }
    print(String(format: "\n%d interval(s), %.1f minutes double-counted", clips.count, removed / 60))
    guard apply else { print("dry run — pass --apply to write"); return }
    let applied = try store.resolveClosedOverlaps(upToRemovedSeconds: limit)
    print("applied to \(applied.count) interval(s)")
    print("remaining overlap: \(OverlapResolver.clips(try store.intervals()).count)")
}

do {
    if CommandLine.arguments.contains("--overlaps") {
        guard let dbPath = value(for: "--db") else { print("need --db"); exit(2) }
        try reportOverlaps(dbPath: dbPath, apply: CommandLine.arguments.contains("--apply"),
                           limitMinutes: value(for: "--max-minutes").flatMap(Double.init))
        exit(0)
    }
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
