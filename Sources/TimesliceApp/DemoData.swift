import Foundation
import TimesliceCore

/// Populates the store with realistic-looking data for screenshots. Activated by launching with
/// `TIMESLICE_SEED_DEMO=1` (which also uses a separate demo DB so it never touches real data).
enum DemoData {
    /// `TIMESLICE_SCREENSHOT=1` additionally suppresses anything modal that would cover the
    /// window being captured. Plain demo mode keeps every prompt, so the global hotkeys stay
    /// testable against demo data.
    static var isScreenshotRun: Bool {
        ProcessInfo.processInfo.environment["TIMESLICE_SCREENSHOT"] == "1"
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TIMESLICE_SEED_DEMO"] == "1"
    }

    /// A separate DB file so seeding never clobbers the user's real timeslice.db.
    static var databaseURL: URL {
        TimeslicePaths.defaultSupportDirectoryURL().appendingPathComponent("timeslice-demo.db")
    }

    /// Wipe and repopulate with a believable ~3 weeks of history for a multitasking day.
    static func seed(into store: IntervalStore) {
        // Fresh slate.
        for p in (try? store.listProjects(includeArchived: true)) ?? [] {
            try? store.deleteProject(id: p.id)
        }

        // Tasks a fast-switching person might have, with distinct colors.
        // Deliberately more tasks than the switcher HUD shows at once (8), so the windowing +
        // "N more" hints are exercised in demos/screenshots.
        let specs: [(String, String, Bool, Bool)] = [   // name, color, finished, archived
            ("Deep Work",     "#4E79A7", false, false),
            ("Code Review",   "#F28E2B", false, false),
            ("Meetings",      "#59A14F", false, false),
            ("Email & Slack", "#E15759", false, false),
            ("Writing",       "#B07AA1", false, false),
            ("Learning",      "#76B7B2", false, false),
            ("Design Review", "#EDC948", false, false),
            ("Interviews",    "#FF9DA7", false, false),
            ("On-call",       "#7B68EE", false, false),
            ("Docs",          "#20B2AA", false, false),
            ("Planning",      "#DA70D6", false, false),
            ("Support",       "#CD853F", false, false),
            ("Ship v0.3",     "#9C755F", true,  false),   // finished (struck through)
            ("Old Prototype", "#BAB0AC", false, true),    // archived
        ]
        var ids: [String: Int64] = [:]
        for (name, color, finished, archived) in specs {
            if let id = try? store.createProject(name: name, colorHex: color) {
                ids[name] = id
                if finished { try? store.setProjectFinished(id: id, finished: true) }
                if archived { try? store.setProjectArchived(id: id, archived: true) }
            }
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: referenceNow())

        // A weekday "shape": (task, startHour, minutes). Weekends lighter. Deterministic — no RNG.
        let weekdayBlocks: [(String, Double, Int)] = [
            ("Email & Slack", 9.0, 20),
            ("Deep Work", 9.5, 85),
            ("Code Review", 11.0, 35),
            ("Meetings", 11.75, 45),
            ("Email & Slack", 12.5, 15),
            ("Deep Work", 13.5, 70),
            ("Design Review", 14.75, 30),
            ("Writing", 15.4, 35),
            ("Learning", 16.1, 25),
            ("Docs", 16.6, 20),
            ("Planning", 17.0, 25),
            ("Support", 17.5, 20),
            ("Interviews", 18.0, 30),
            ("On-call", 18.6, 25),
        ]
        let weekendBlocks: [(String, Double, Int)] = [
            ("Learning", 10.5, 50),
            ("Writing", 11.5, 35),
            ("Deep Work", 15.0, 40),
        ]

        // Backfill ~2 months so that whichever month a screenshot anchors to is fully populated
        // (20 days straddles the month boundary and leaves the current month nearly empty).
        for dayOffset in 0..<70 {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let weekday = cal.component(.weekday, from: day)   // 1=Sun, 7=Sat
            let isWeekend = (weekday == 1 || weekday == 7)
            let blocks = isWeekend ? weekendBlocks : weekdayBlocks
            // Vary volume a little by day index so the bars aren't identical (deterministic).
            let keep = isWeekend ? blocks.count : max(6, blocks.count - (dayOffset % 4))
            for (i, (task, startHour, minutes)) in blocks.prefix(keep).enumerated() {
                guard let taskID = ids[task] else { continue }
                let jitter = Double((dayOffset + i) % 5) * 3.0   // small deterministic wobble
                let mins = Double(minutes) + jitter - 6
                let start = day.addingTimeInterval(startHour * 3600)
                let end = start.addingTimeInterval(max(300, mins * 60))
                // Only backfill times already in the past.
                if end < referenceNow() {
                    try? store.insertClosedInterval(projectID: taskID, start: start, end: end)
                }
            }
        }
    }

    /// "Now" pinned mid-afternoon so today's chart looks partially filled in screenshots,
    /// regardless of when you actually run it. Uses the real date, 15:40 local.
    private static func referenceNow() -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let start = cal.startOfDay(for: Date())
        return start.addingTimeInterval(15 * 3600 + 40 * 60)
    }
}
