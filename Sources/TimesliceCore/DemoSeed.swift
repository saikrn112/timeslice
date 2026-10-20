import Foundation

/// Generates believable data for screenshots and for seeing the UI at realistic scale.
///
/// In Core so both platforms use one generator. Two presets, because they answer different
/// questions:
///
/// - `.screenshot` — the Mac's long-standing fixture: 14 flat tasks, ~2 months, no groups or tags.
///   Preserved *exactly* so existing Mac screenshots don't change.
/// - `.rich` — many projects, tasks, tags, budgets, several months, and three devices. For finding
///   layout problems that only appear at scale: a project list that needs scrolling, a legend with
///   more entries than colours, a timeline with real lane contention.
///
/// Everything is **deterministic** — no RNG — so two runs produce the same database and a visual
/// difference is a real change rather than reshuffled data.
public enum DemoSeed {

    public enum Preset: String, Sendable {
        case screenshot
        case rich
        /// The product page's data. Generic names only — it is published. Contains EXACTLY the page's
        /// scripted Thursday (the most recent Thursday before today), so a screenshot of that day in the
        /// real app shows the same intervals the page animates; plus five weeks of history, projects, tags,
        /// allocations and two devices, so every view the page photographs has something true to show.
        case showcase
    }

    /// Wipe and repopulate. Destructive by design; callers point it at a demo/simulator database.
    public static func seed(into store: IntervalStore, preset: Preset = .screenshot,
                            now: Date = Date()) throws {
        // Fresh slate. Deleting the projects cascades their intervals, and tags/targets are detached
        // first by `deleteProject`, so this can't leave orphans behind.
        for p in (try? store.listProjects(includeArchived: true)) ?? [] {
            try? store.deleteProject(id: p.id)
        }
        for g in (try? store.listTaskProjects()) ?? [] { try? store.deleteTaskProject(id: g.id) }
        for t in (try? store.listTags()) ?? [] { try? store.deleteTag(id: t.id) }
        for t in (try? store.listTargets()) ?? [] { try? store.deleteTarget(id: t.id) }

        switch preset {
        case .screenshot: try seedScreenshot(store, now: now)
        case .rich: try seedRich(store, now: now)
        case .showcase: try seedShowcase(store, now: now)
        }
    }

    // MARK: - The Mac's original fixture

    /// "Now" pinned mid-afternoon so today's chart looks partially filled regardless of when this
    /// runs. Uses the real date, 15:40 local.
    static func referenceNow(_ now: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.startOfDay(for: now).addingTimeInterval(15 * 3600 + 40 * 60)
    }

    private static func seedScreenshot(_ store: IntervalStore, now: Date) throws {
        // Deliberately more tasks than the switcher HUD shows at once (8), so the windowing +
        // "N more" hints are exercised.
        let specs: [(String, String, Bool, Bool)] = [   // name, color, finished, archived
            ("Deep Work", "#4E79A7", false, false), ("Code Review", "#F28E2B", false, false),
            ("Meetings", "#59A14F", false, false), ("Email & Slack", "#E15759", false, false),
            ("Writing", "#B07AA1", false, false), ("Learning", "#76B7B2", false, false),
            ("Design Review", "#EDC948", false, false), ("Interviews", "#FF9DA7", false, false),
            ("On-call", "#7B68EE", false, false), ("Docs", "#20B2AA", false, false),
            ("Planning", "#DA70D6", false, false), ("Support", "#CD853F", false, false),
            ("Ship v0.3", "#9C755F", true, false), ("Old Prototype", "#BAB0AC", false, true),
        ]
        var ids: [String: Int64] = [:]
        for (name, color, finished, archived) in specs {
            if let id = try? store.createProject(name: name, colorHex: color) {
                ids[name] = id
                if finished { try? store.setProjectFinished(id: id, finished: true) }
                if archived { try? store.setProjectArchived(id: id, archived: true) }
            }
        }

        let weekdayBlocks: [(String, Double, Int)] = [
            ("Email & Slack", 9.0, 20), ("Deep Work", 9.5, 85), ("Code Review", 11.0, 35),
            ("Meetings", 11.75, 45), ("Email & Slack", 12.5, 15), ("Deep Work", 13.5, 70),
            ("Design Review", 14.75, 30), ("Writing", 15.4, 35), ("Learning", 16.1, 25),
            ("Docs", 16.6, 20), ("Planning", 17.0, 25), ("Support", 17.5, 20),
            ("Interviews", 18.0, 30), ("On-call", 18.6, 25),
        ]
        let weekendBlocks: [(String, Double, Int)] = [
            ("Learning", 10.5, 50), ("Writing", 11.5, 35), ("Deep Work", 15.0, 40),
        ]
        try paint(store, ids: ids, days: 70, weekday: weekdayBlocks, weekend: weekendBlocks,
                  devices: [nil], now: now)
    }

    // MARK: - Scale fixture

    // MARK: - The product page

    /// The scripted Thursday, as (task, start, end, device). Mirrored in the product page's JavaScript —
    /// change one and the other must follow, or the page stops showing what the app shows.
    static let showcaseDay: [(String, String, String, String)] = [
        ("Deep Work", "9:02", "9:18", "mac"), ("Deep Work", "9:18:08", "9:35", "mac"),
        ("Deep Work", "9:35:05", "9:51", "mac"), ("Deep Work", "9:51:40", "10:28", "mac"),
        ("Code Review", "10:28", "11:05", "mac"), ("Email & Slack", "11:05", "11:16", "mac"),
        ("Code Review", "11:16", "12:10", "mac"), ("Code Review", "12:58", "13:20", "mac"),
        ("Writing", "13:20", "13:40", "mac"), ("Design Review", "13:40:30", "14:36", "mac"),
        ("Design Review", "14:48", "16:12", "mac"), ("Meetings", "16:12", "16:58", "phone"),
        ("Planning", "17:05", "18:30", "mac"),
        // Home, on the personal laptop: the third device, so the page's multi-device chapter has a real lane.
        ("Learning", "20:10", "21:00", "air"),
    ]

    private static func seedShowcase(_ store: IntervalStore, now: Date) throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        // Projects, then tasks inside them. Tags cut ACROSS projects — that combination is what the page
        // explains: "work" spans Product, Docs and two Inbox tasks, so one allocation can cover all of it.
        let groupSpecs: [(String, String)] = [("Product", "#4E79A7"), ("Docs", "#B07AA1"), ("Personal", "#59A14F")]
        var groups: [String: Int64] = [:]
        for (name, hex) in groupSpecs { groups[name] = try store.upsertTaskProject(name: name, colorHex: hex) }
        let taskSpecs: [(String, String?)] = [
            ("Deep Work", "Product"), ("Code Review", "Product"), ("Design Review", "Product"),
            ("Planning", "Product"), ("Writing", "Docs"), ("Release notes", "Docs"),
            ("Learning", "Personal"), ("Gym", "Personal"),
            ("Email & Slack", nil), ("Meetings", nil),
        ]
        var ids: [String: Int64] = [:]
        for (i, (name, group)) in taskSpecs.enumerated() {
            ids[name] = try store.createProject(name: name, colorHex: Palette.color(forIndex: i),
                                                inGroup: group.flatMap { groups[$0] })
        }
        let work = try store.upsertTag(name: "work", colorHex: "#4E79A7")
        for g in ["Product", "Docs"] { if let id = groups[g] { try store.addTag(work, to: .project(id)) } }
        for t in ["Email & Slack", "Meetings"] { if let id = ids[t] { try store.addTag(work, to: .task(id)) } }
        let deep = try store.upsertTag(name: "deep", colorHex: "#B07AA1")
        for t in ["Deep Work", "Design Review", "Writing"] { if let id = ids[t] { try store.addTag(deep, to: .task(id)) } }

        let monFri = Weekdays(rawValue: 0b0111110)
        _ = try store.setTarget(subject: .tag(work), seconds: 35 * 3600, direction: .atLeast,
                                period: .week, weekdays: monFri)
        if let id = ids["Writing"] {
            _ = try store.setTarget(subject: .task(id), seconds: 5 * 3600, direction: .atLeast, period: .week)
        }
        if let id = ids["Email & Slack"] {
            _ = try store.setTarget(subject: .task(id), seconds: 3600, direction: .atMost, period: .day)
        }
        if let id = ids["Learning"] {
            _ = try store.setTarget(subject: .task(id), seconds: 3 * 3600, direction: .atLeast, period: .week)
        }

        try store.rememberDevice(id: "macbook-pro", label: "MacBook Pro")
        try store.rememberDevice(id: "macbook-air", label: "MacBook Air")
        try store.rememberDevice(id: "iphone", label: "iPhone")
        let device = ["mac": "macbook-pro", "air": "macbook-air", "phone": "iphone"]

        func at(_ day: Date, _ hms: String) -> Date {
            let parts = hms.split(separator: ":").compactMap { Double($0) }
            let secs = parts[0] * 3600 + (parts.count > 1 ? parts[1] * 60 : 0) + (parts.count > 2 ? parts[2] : 0)
            return day.addingTimeInterval(secs)
        }
        func add(_ task: String, _ start: Date, _ end: Date, _ dev: String) throws {
            guard let id = ids[task], end > start, end <= now else { return }
            try store.insertClosedInterval(projectID: id, start: start, end: end, deviceID: device[dev])
        }

        let today = cal.startOfDay(for: now)
        // The most recent Thursday strictly before today, so the whole story day is in the past.
        var story = cal.date(byAdding: .day, value: -1, to: today)!
        while cal.component(.weekday, from: story) != 5 { story = cal.date(byAdding: .day, value: -1, to: story)! }

        // Ordinary days around it: the same cast in a different order, so the week and month views have a
        // believable shape. Deterministic, so a re-seed photographs identically.
        let weekdayShapes: [[(String, String, String, String)]] = [
            [("Email & Slack", "8:50", "9:10", "mac"), ("Deep Work", "9:10", "11:20", "mac"),
             ("Meetings", "11:30", "12:15", "phone"), ("Code Review", "13:10", "14:40", "mac"),
             ("Writing", "14:45", "15:50", "mac"), ("Planning", "16:00", "16:40", "mac")],
            [("Deep Work", "9:00", "10:45", "mac"), ("Email & Slack", "10:45", "11:05", "mac"),
             ("Design Review", "11:05", "12:20", "mac"), ("Code Review", "13:30", "15:10", "mac"),
             ("Meetings", "15:15", "16:00", "phone"), ("Release notes", "16:05", "16:50", "mac")],
            [("Planning", "9:15", "9:45", "mac"), ("Deep Work", "9:45", "12:10", "mac"),
             ("Email & Slack", "13:00", "13:25", "mac"), ("Design Review", "13:25", "15:00", "mac"),
             ("Writing", "15:05", "16:20", "mac"), ("Learning", "20:30", "21:15", "air")],
        ]
        let weekendShape: [(String, String, String, String)] = [
            ("Learning", "10:30", "11:30", "air"), ("Gym", "17:00", "18:00", "phone"),
        ]
        for back in 0..<36 {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            if day == story {
                for (t, a, b, d) in showcaseDay { try add(t, at(day, a), at(day, b), d) }
                continue
            }
            let wd = cal.component(.weekday, from: day)
            let shape = (wd == 1 || wd == 7) ? weekendShape : weekdayShapes[back % weekdayShapes.count]
            for (t, a, b, d) in shape { try add(t, at(day, a), at(day, b), d) }
        }
    }

    private static func seedRich(_ store: IntervalStore, now: Date) throws {
        // 8 projects. Colours from the shared palette so shades derive the way they do in real use.
        let groupNames = ["tensorforge", "clockwerk", "timeslice", "infra",
                          "admin", "hiring", "learning", "writing"]
        var groups: [String: Int64] = [:]
        for (i, name) in groupNames.enumerated() {
            groups[name] = try store.upsertTaskProject(name: name,
                                                       colorHex: Palette.color(forIndex: i))
        }

        // 34 tasks. Several per project so colour SHADES are exercised (a project's tasks must stay
        // tellable apart), plus a handful in Inbox, two finished and two archived.
        let taskSpecs: [(String, String?, Bool, Bool)] = [   // name, project, finished, archived
            ("kernel profiling", "tensorforge", false, false),
            ("ncu traces", "tensorforge", false, false),
            ("nsys usage", "tensorforge", false, false),
            ("lora mem check", "tensorforge", false, false),
            ("kernelforge", "tensorforge", false, false),
            ("streaming rewrite", "clockwerk", false, false),
            ("adapter cache", "clockwerk", false, false),
            ("worker restarts", "clockwerk", false, false),
            ("datum plumbing", "clockwerk", false, false),
            ("ios parity", "timeslice", false, false),
            ("dynamic island", "timeslice", false, false),
            ("budgets screen", "timeslice", false, false),
            ("sync merge", "timeslice", false, false),
            ("build pipeline", "infra", false, false),
            ("version set bump", "infra", false, false),
            ("host provisioning", "infra", false, false),
            ("expense report", "admin", false, false),
            ("weekly review", "admin", false, false),
            ("email & slack", "admin", false, false),
            ("standup", "admin", false, false),
            ("phone screens", "hiring", false, false),
            ("onsite loop", "hiring", false, false),
            ("debrief", "hiring", false, false),
            ("paper reading", "learning", false, false),
            ("cuda course", "learning", false, false),
            ("swift concurrency", "learning", false, false),
            ("design doc", "writing", false, false),
            ("blog draft", "writing", false, false),
            ("retro notes", "writing", false, false),
            ("scratch idea", nil, false, false),
            ("misc errand", nil, false, false),
            ("read later", nil, false, false),
            ("ship v0.3", "timeslice", true, false),
            ("old prototype", "tensorforge", false, true),
        ]
        var ids: [String: Int64] = [:]
        for (name, group, finished, archived) in taskSpecs {
            let gid = group.flatMap { groups[$0] }
            guard let id = try? store.createProject(
                name: name, colorHex: Palette.color(forIndex: ids.count), inGroup: gid) else { continue }
            ids[name] = id
            if finished { try? store.setProjectFinished(id: id, finished: true) }
            if archived { try? store.setProjectArchived(id: id, archived: true) }
        }

        // 8 tags on projects (tasks inherit). Several projects carry two, so the "tags don't sum"
        // caption on the breakdown is actually exercised.
        let tagSpecs: [(String, [String])] = [
            ("deep", ["tensorforge", "clockwerk", "timeslice"]),
            ("shallow", ["admin"]),
            ("perf", ["tensorforge", "infra"]),
            ("product", ["timeslice"]),
            ("people", ["hiring"]),
            ("growth", ["learning", "writing"]),
            ("oncall", ["infra"]),
            ("billable", ["clockwerk", "timeslice"]),
        ]
        for (i, (name, attachTo)) in tagSpecs.enumerated() {
            let tagID = try store.upsertTag(name: name, colorHex: Palette.color(forIndex: i + 3))
            for g in attachTo {
                if let gid = groups[g] { try? store.addTag(tagID, to: .project(gid)) }
            }
        }

        // Budgets across all three subject kinds, and both directions, so every verdict state shows:
        // a floor comfortably met, one behind, and a ceiling breached.
        let tags = try store.listTags()
        if let g = groups["tensorforge"] {
            _ = try? store.setTarget(subject: .project(g), seconds: 30 * 3600,
                                     direction: .atLeast, period: .week)
        }
        if let g = groups["admin"] {
            _ = try? store.setTarget(subject: .project(g), seconds: 5 * 3600,
                                     direction: .atMost, period: .week)
        }
        if let g = groups["timeslice"] {
            _ = try? store.setTarget(subject: .project(g), seconds: 60 * 3600,
                                     direction: .atLeast, period: .month)
        }
        if let deep = tags.first(where: { $0.name == "deep" }) {
            _ = try? store.setTarget(subject: .tag(deep.id), seconds: 25 * 3600,
                                     direction: .atLeast, period: .week)
        }
        if let shallow = tags.first(where: { $0.name == "shallow" }) {
            _ = try? store.setTarget(subject: .tag(shallow.id), seconds: 45 * 60,
                                     direction: .atMost, period: .day)
        }
        if let id = ids["email & slack"] {
            _ = try? store.setTarget(subject: .task(id), seconds: 30 * 60,
                                     direction: .atMost, period: .day)
        }
        if let id = ids["paper reading"] {
            _ = try? store.setTarget(subject: .task(id), seconds: 3 * 3600,
                                     direction: .atLeast, period: .week)
        }

        // Three devices, so the day timeline has real lane contention and Sessions has a device
        // column worth showing.
        let devices = ["macbookpro18-2", "macbookair10-1", "iphone17-a1b2"]
        try store.rememberDevice(id: devices[0], label: "MacBook Pro")
        try store.rememberDevice(id: devices[1], label: "MacBook Air")
        try store.rememberDevice(id: devices[2], label: "iPhone")

        // A dense weekday shape — more blocks than a phone screen can show at once, which is the
        // point: a fragmented day is what the timeline has to stay readable under.
        let weekday: [(String, Double, Int)] = [
            ("standup", 9.0, 15), ("email & slack", 9.3, 25), ("kernel profiling", 9.8, 75),
            ("ncu traces", 11.1, 40), ("streaming rewrite", 11.9, 35), ("phone screens", 12.6, 45),
            ("email & slack", 13.5, 20), ("ios parity", 13.9, 80), ("dynamic island", 15.3, 45),
            ("build pipeline", 16.1, 30), ("paper reading", 16.7, 35), ("design doc", 17.4, 40),
            ("adapter cache", 18.2, 30), ("swift concurrency", 18.8, 25), ("retro notes", 19.3, 20),
        ]
        let weekend: [(String, Double, Int)] = [
            ("cuda course", 10.5, 60), ("blog draft", 11.8, 45), ("scratch idea", 14.0, 30),
            ("paper reading", 15.2, 40),
        ]

        // ~5 months so 6M and Y ranges have shape, and the month view is full wherever it anchors.
        try paint(store, ids: ids, days: 150, weekday: weekday, weekend: weekend,
                  devices: devices.map { Optional($0) }, now: now)

        // Leave a timer RUNNING so the Dynamic Island, the ticking row and the "current task" states
        // are live on first launch — but start it AFTER the last closed block.
        //
        // Only ONE timer runs across all devices (that's what `TakeoverPolicy` enforces), so
        // concurrent intervals are data that cannot occur in practice. An earlier version opened this
        // 42 minutes back regardless, which collided with blocks already painted for today and made
        // the day timeline show lane contention that no real database would ever contain.
        if let id = ids["ios parity"] {
            let lastEnd = (try? store.intervals())?.compactMap(\.end).max() ?? .distantPast
            let start = max(lastEnd, now.addingTimeInterval(-42 * 60))
            try? store.switchTo(projectID: id, at: min(start, now))
        }
    }

    // MARK: - Painting days

    /// Lay `weekday`/`weekend` block shapes across `days` of history, rotating through `devices`.
    ///
    /// Deterministic jitter (derived from the day and block index, never a RNG) keeps bars from being
    /// identical without making runs differ.
    private static func paint(_ store: IntervalStore, ids: [String: Int64], days: Int,
                              weekday: [(String, Double, Int)],
                              weekend: [(String, Double, Int)],
                              devices: [String?], now: Date) throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let today = cal.startOfDay(for: now)
        // Never paint the future. `referenceNow` pins to 15:40 so a screenshot taken at any hour has a
        // partly-filled day, but used alone it writes blocks that haven't happened yet — which is how
        // "today" ended up containing sessions dated later than the clock.
        let cutoff = min(referenceNow(now), now)

        for dayOffset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let isWeekend = [1, 7].contains(cal.component(.weekday, from: day))
            let blocks = isWeekend ? weekend : weekday
            // Vary volume by day so the per-day bars differ; weekends stay light.
            let keep = isWeekend ? blocks.count : max(6, blocks.count - (dayOffset % 5))
            let chosen = Array(blocks.prefix(keep))
            for (i, (task, startHour, minutes)) in chosen.enumerated() {
                guard let taskID = ids[task] else { continue }
                let jitter = Double((dayOffset + i) % 5) * 3.0
                let mins = Double(minutes) + jitter - 6
                let start = day.addingTimeInterval(startHour * 3600)
                var end = start.addingTimeInterval(max(300, mins * 60))

                // CLAMP against the next block. The base shapes don't overlap, but the jitter
                // lengthens some of them past the following start — which produced 129 overlapping
                // pairs. Overlap is data the app cannot actually contain: only one timer runs across
                // all devices (`TakeoverPolicy` back-dates the loser), so a seeded overlap shows lane
                // contention on the day timeline that no real database would ever have.
                if i + 1 < chosen.count {
                    let nextStart = day.addingTimeInterval(chosen[i + 1].1 * 3600)
                    end = min(end, nextStart.addingTimeInterval(-60))
                }
                guard end > start else { continue }
                // Only backfill times already past, so today is partially filled rather than
                // claiming work that hasn't happened.
                guard end < cutoff else { continue }
                // Rotate devices per (day, block) so the history is attributed across machines —
                // sequentially, never concurrently, which is how the one-timer invariant actually
                // looks in practice.
                let device = devices[(dayOffset + i) % devices.count]
                try? store.insertClosedInterval(projectID: taskID, start: start, end: end,
                                                deviceID: device)
            }
        }
    }
}
