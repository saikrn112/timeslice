import Foundation
import TimesliceCore

// Minimal assertion harness (no XCTest/swift-testing under Command Line Tools).
var failures = 0
var passed = 0

func check(_ condition: Bool, _ label: String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("  ✘ FAIL: \(label)  (\(file):\(line))")
    }
}

func approx(_ a: Double, _ b: Double, _ tol: Double = 0.5) -> Bool { abs(a - b) < tol }

// Fixed calendar in a known timezone so day/hour boundaries are deterministic.
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

func project(_ id: Int64) -> Project {
    Project(id: id, name: "P\(id)", colorHex: "#fff", sortOrder: 0, archived: false)
}

func makeStore() throws -> (IntervalStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("timeslice-test-\(UUID().uuidString).db")
    let store = try IntervalStore(databaseURL: url)
    try store.migrateIfNeeded()
    return (store, url)
}

// MARK: - Store tests

func testStore() throws {
    print("IntervalStore:")

    do { // switchTo closes previous interval
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        let b = try store.createProject(name: "B", colorHex: "#0f0")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try store.switchTo(projectID: a, at: t0)
        check(try store.openInterval()?.projectID == a, "open interval is A after switch")
        let t1 = t0.addingTimeInterval(60)
        try store.switchTo(projectID: b, at: t1)
        check(try store.openInterval()?.projectID == b, "open interval moves to B")
        let aInterval = try store.intervals().first { $0.projectID == a }
        check(aInterval?.end == t1, "A's interval closed at t1")
        check(approx(aInterval?.seconds(now: t1) ?? 0, 60, 0.001), "A recorded 60s")
    }

    do { // only one running interval ever exists
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        let b = try store.createProject(name: "B", colorHex: "#0f0")
        try store.switchTo(projectID: a)
        try store.switchTo(projectID: b)
        check(try store.intervals().filter { $0.isRunning }.count == 1, "exactly one running interval")
    }

    do { // stop closes; stop is no-op when idle
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        try store.switchTo(projectID: a)
        try store.stopOpenInterval()
        check(try store.openInterval() == nil, "stop closes open interval")
        try store.stopOpenInterval()
        check(try store.openInterval() == nil, "stop is no-op when idle")
    }

    do { // open interval elapsed = now - start
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        let start = Date(timeIntervalSince1970: 2_000_000)
        try store.switchTo(projectID: a, at: start)
        let interval = try store.intervals().first { $0.isRunning }!
        check(approx(interval.seconds(now: start.addingTimeInterval(125)), 125, 0.001), "open elapsed = now - start")
    }

    do { // finished vs archived are independent; finished stays in the active (non-archived) list
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        try store.setProjectFinished(id: a, finished: true)
        let active = try store.listProjects(includeArchived: false)
        check(active.first { $0.id == a }?.finished == true, "finished task still in active list, flagged finished")

        try store.setProjectArchived(id: a, archived: true)
        check(try store.listProjects(includeArchived: false).isEmpty, "archived task leaves active list")
        let all = try store.listProjects(includeArchived: true).first { $0.id == a }
        check(all?.archived == true && all?.finished == true, "archive + finished are independent flags")
    }

    do { // delete removes the task and its intervals
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        try store.switchTo(projectID: a); try store.stopOpenInterval()
        try store.deleteProject(id: a)
        check(try store.listProjects(includeArchived: true).isEmpty, "delete removes the task")
        check(try store.intervals().isEmpty, "delete removes the task's intervals")
    }
}

// MARK: - Aggregation tests

func testAggregations() {
    print("Aggregations:")

    do { // today totals clip to local day
        let now = date(2026, 3, 10, 9, 0)
        let iv = Interval(id: 1, projectID: 1, start: date(2026, 3, 9, 23, 30), end: date(2026, 3, 10, 0, 45))
        let totals = Aggregations.todayTotals(projects: [project(1)], intervals: [iv], now: now, calendar: cal)
        check(approx(totals.first?.seconds ?? -1, 45 * 60), "today clips midnight-crossing to 45 min")
    }

    do { // midnight split → two daily buckets, 1h each
        let start = date(2026, 3, 9, 23, 0), end = date(2026, 3, 10, 1, 0)
        let buckets = Aggregations.dailyBuckets(intervals: [Interval(id: 1, projectID: 7, start: start, end: end)], calendar: cal)
        check(buckets.count == 2, "midnight-crossing splits into 2 daily buckets")
        check(buckets.first.map { approx($0.seconds, 3600) } ?? false, "day 1 = 1h")
        check(buckets.last.map { approx($0.seconds, 3600) } ?? false, "day 2 = 1h")
    }

    do { // hour heatmap splits across cells
        let iv = Interval(id: 1, projectID: 1, start: date(2026, 3, 10, 10, 30), end: date(2026, 3, 10, 12, 0))
        let byHour = Dictionary(uniqueKeysWithValues: Aggregations.hourHeatmap(intervals: [iv], calendar: cal).map { ($0.hour, $0.seconds) })
        check(approx(byHour[10] ?? -1, 30 * 60), "hour 10 = 30 min")
        check(approx(byHour[11] ?? -1, 60 * 60), "hour 11 = 60 min")
        check(byHour[12] == nil, "nothing bleeds into hour 12")
    }

    do { // switches per day
        let d = date(2026, 3, 10, 9, 0)
        let ivs = [
            Interval(id: 1, projectID: 1, start: d, end: d.addingTimeInterval(600)),
            Interval(id: 2, projectID: 1, start: d.addingTimeInterval(600), end: d.addingTimeInterval(1200)),
            Interval(id: 3, projectID: 2, start: d.addingTimeInterval(1200), end: d.addingTimeInterval(1800)),
            Interval(id: 4, projectID: 1, start: d.addingTimeInterval(1800), end: d.addingTimeInterval(2400)),
        ]
        check(Aggregations.switchesPerDay(intervals: ivs, calendar: cal).first?.switches == 2, "A,A,B,A = 2 switches")
    }

    do { // open interval treated as ending now
        let iv = Interval(id: 1, projectID: 1, start: date(2026, 3, 10, 8, 0), end: nil)
        let totals = Aggregations.allTimeTotals(projects: [project(1)], intervals: [iv], now: date(2026, 3, 10, 8, 30))
        check(approx(totals.first?.seconds ?? -1, 30 * 60), "open interval counts up to now")
    }

    do { // dayStats: totals, deep-block classification, and windowing
        let now = date(2026, 3, 10, 20, 0)
        let ivs = [
            // Today: one 30m deep block + one 5m shallow block on project 1.
            Interval(id: 1, projectID: 1, start: date(2026, 3, 10, 9, 0), end: date(2026, 3, 10, 9, 30)),
            Interval(id: 2, projectID: 1, start: date(2026, 3, 10, 10, 0), end: date(2026, 3, 10, 10, 5)),
            // 8 days ago — outside a 3-day window.
            Interval(id: 3, projectID: 1, start: date(2026, 3, 2, 9, 0), end: date(2026, 3, 2, 10, 0)),
        ]
        let stats = Aggregations.dayStats(intervals: ivs, days: 3, deepThreshold: 25 * 60, now: now, calendar: cal)
        check(stats.count == 3, "dayStats returns one entry per day in the window")
        let today = stats.first { cal.isDate($0.day, inSameDayAs: now) }
        check(approx(today?.totalSeconds ?? -1, 35 * 60), "today total = 35m")
        check(approx(today?.deepSeconds ?? -1, 30 * 60), "today deep = only the 30m block (5m excluded)")
        check(today.map { abs($0.focusRatio - (30.0/35.0)) < 0.01 } ?? false, "focus ratio = 30/35")
        check(!stats.contains { cal.isDate($0.day, inSameDayAs: date(2026,3,2,0,0)) }, "8-days-ago excluded from 3-day window")
    }
}

// MARK: - Finished-task visibility (semi-archive)

func testFinishedVisibility() {
    print("Finished visibility:")
    let now = date(2026, 3, 10, 15, 0)

    func p(finished: Bool, finishedAt: Date?) -> Project {
        Project(id: 1, name: "T", colorHex: "#fff", sortOrder: 0, archived: false,
                finished: finished, finishedAt: finishedAt)
    }

    check(p(finished: false, finishedAt: nil).showsInToday(now: now, calendar: cal),
          "unfinished tasks always show in Today")
    check(p(finished: true, finishedAt: date(2026, 3, 10, 9, 0)).showsInToday(now: now, calendar: cal),
          "finished TODAY still shows (struck through)")
    check(!p(finished: true, finishedAt: date(2026, 3, 9, 9, 0)).showsInToday(now: now, calendar: cal),
          "finished YESTERDAY drops out of Today")
    check(!p(finished: true, finishedAt: nil).showsInToday(now: now, calendar: cal),
          "finished with no timestamp (legacy) drops out of Today")
}

// MARK: - Task search (palette)

func testTaskSearch() {
    print("TaskSearch:")

    func proj(_ id: Int64, _ name: String, finished: Bool = false, archived: Bool = false) -> Project {
        Project(id: id, name: name, colorHex: "#fff", sortOrder: Int(id), archived: archived, finished: finished)
    }

    let projects = [
        proj(1, "Deep Work"),
        proj(2, "GPU profiling", finished: true),
        proj(3, "Design docs"),
        proj(4, "Old Prototype", archived: true),
    ]

    do { // fuzzy subsequence matches, non-matches score 0
        check(TaskSearch.score(query: "gpu", candidate: "gpu profiling") > 0, "prefix matches")
        check(TaskSearch.score(query: "dw", candidate: "deep work") > 0, "initials match as subsequence")
        check(TaskSearch.score(query: "zzz", candidate: "deep work") == 0, "no match scores 0")
    }

    do { // prefix beats mid-word for the same query
        let a = TaskSearch.score(query: "doc", candidate: "docs")
        let b = TaskSearch.score(query: "doc", candidate: "design docs review")
        check(a > b, "tighter/prefix candidate outranks a longer one")
    }

    do { // active outranks finished/archived when the match quality is equal
        let equal = [proj(1, "Alpha One"), proj(2, "Alpha Two", finished: true),
                     proj(3, "Alpha Three", archived: true)]
        let r = TaskSearch.rank(query: "alpha", projects: equal, lastActivity: [:])
        let tiers = r.map { $0.project.archived ? 2 : ($0.project.finished ? 1 : 0) }
        check(tiers == tiers.sorted(), "equal-scoring matches order active → finished → archived")
    }

    do { // a better match wins regardless of status — tiering must not gate score
        let r = TaskSearch.rank(query: "gpu", projects: projects, lastActivity: [:])
        check(r.first?.project.id == 2, "finished exact match outranks weaker active matches")
    }

    do { // finished tasks survive the limit even when active tasks fill it
        // The bug: tier-first sorting truncated every done task off the end.
        var many = (1...8).map { proj(Int64($0), "Active Task \($0)") }
        many.append(proj(99, "Active Retro", finished: true))
        let r = TaskSearch.rank(query: "retro", projects: many, lastActivity: [:], limit: 8)
        check(r.contains { $0.project.id == 99 }, "finished match not starved by 8 active tasks")
    }

    do { // empty query returns recents, most-recent first within a tier
        let now = Date()
        let activity: [Int64: Date] = [1: now.addingTimeInterval(-3600), 3: now]
        let r = TaskSearch.rank(query: "", projects: projects, lastActivity: activity)
        check(r.first?.project.id == 3, "empty query puts the most recently used active task first")
        check(r.count == projects.count, "empty query lists all tasks")
    }
}

// MARK: - Task projects (grouping above tasks)

func testTaskProjects() throws {
    print("TaskProjects:")

    do { // upsert is find-or-create, so "assign" and "create" are one action
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.upsertTaskProject(name: "tensorforge", colorHex: "#0f0")
        let b = try store.upsertTaskProject(name: "tensorforge", colorHex: "#f00")
        check(a == b, "upsert returns the existing group rather than duplicating")
        check(try store.listTaskProjects().count == 1, "only one group exists")
        let c = try store.upsertTaskProject(name: "  TensorForge  ", colorHex: "#00f")
        check(c == a, "name match is case- and whitespace-insensitive")
    }

    do { // tasks default to Inbox, and assignment never touches intervals
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let task = try store.createProject(name: "profiling", colorHex: "#fff")
        try store.switchTo(projectID: task, at: Date(timeIntervalSince1970: 1000))
        try store.stopOpenInterval(at: Date(timeIntervalSince1970: 4600))
        let intervalsBefore = try store.intervals().count

        check(try store.listProjects().first?.taskProjectID == nil, "new tasks start in Inbox")

        let group = try store.upsertTaskProject(name: "perf", colorHex: "#0f0")
        try store.setTaskProject(taskID: task, taskProjectID: group)
        check(try store.listProjects().first?.taskProjectID == group, "task moved into the group")
        check(try store.intervals().count == intervalsBefore, "assignment does not touch intervals")
        check(approx(try store.intervals().first?.seconds(now: Date()) ?? 0, 3600, 1),
              "...so its recorded time is unchanged")

        try store.setTaskProject(taskID: task, taskProjectID: nil)
        check(try store.listProjects().first?.taskProjectID == nil, "can move back to Inbox")
    }

    do { // deleting a group must never delete tracked time
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let task = try store.createProject(name: "profiling", colorHex: "#fff")
        try store.switchTo(projectID: task); try store.stopOpenInterval()
        let group = try store.upsertTaskProject(name: "perf", colorHex: "#0f0")
        try store.setTaskProject(taskID: task, taskProjectID: group)

        try store.deleteTaskProject(id: group)
        check(try store.listTaskProjects().isEmpty, "group is gone")
        check(try store.listProjects().count == 1, "its task survives")
        check(try store.listProjects().first?.taskProjectID == nil, "...and falls back to Inbox")
        check(try store.intervals().count == 1, "...keeping its intervals")
    }

    do { // rollup sums tasks into groups, Inbox included
        func task(_ id: Int64, group: Int64?) -> Project {
            Project(id: id, name: "T\(id)", colorHex: "#fff", sortOrder: 0, archived: false,
                    taskProjectID: group)
        }
        let groups = [TaskProject(id: 100, name: "perf", colorHex: "#0f0"),
                      TaskProject(id: 200, name: "admin", colorHex: "#00f")]
        let totals = [
            ProjectTotal(project: task(1, group: 100), seconds: 3600),
            ProjectTotal(project: task(2, group: 100), seconds: 1800),
            ProjectTotal(project: task(3, group: 200), seconds: 600),
            ProjectTotal(project: task(4, group: nil), seconds: 900),   // Inbox
            ProjectTotal(project: task(5, group: nil), seconds: 0),     // no time → dropped
        ]
        let rolled = Aggregations.rollUp(totals: totals, taskProjects: groups)

        check(rolled.count == 3, "perf + admin + Inbox")
        check(rolled.first?.name == "perf", "largest group first")
        check(approx(rolled.first?.seconds ?? 0, 5400), "perf = 1h + 30m")
        check(rolled.first?.taskCount == 2, "perf counts its two tasks")
        let inbox = rolled.first { $0.project == nil }
        check(inbox != nil && approx(inbox!.seconds, 900), "ungrouped tasks collapse into Inbox")
        check(inbox?.taskCount == 1, "the zero-second task is excluded from Inbox's count")

        // The invariant that makes this safe to show next to per-task rows.
        let taskSum = totals.reduce(0.0) { $0 + $1.seconds }
        let groupSum = rolled.reduce(0.0) { $0 + $1.seconds }
        check(approx(taskSum, groupSum), "group totals sum to the same time as task totals")
    }

    do { // project-name search: typing a project surfaces its tasks
        let tasks = [
            Project(id: 1, name: "ncu", colorHex: "#fff", sortOrder: 0, archived: false, taskProjectID: 7),
            Project(id: 2, name: "splitwise", colorHex: "#fff", sortOrder: 1, archived: false),
        ]
        let names: [Int64: String] = [1: "inference"]
        let r = TaskSearch.rank(query: "infer", projects: tasks, lastActivity: [:], groupNames: names)
        check(r.count == 1 && r[0].project.id == 1, "task matched via its project's name")

        // A task NAMED for the query still outranks one merely in that project.
        let mixed = tasks + [Project(id: 3, name: "inference notes", colorHex: "#fff",
                                     sortOrder: 2, archived: false)]
        let r2 = TaskSearch.rank(query: "infer", projects: mixed, lastActivity: [:], groupNames: names)
        check(r2.first?.project.id == 3, "direct name match beats project-name match")
    }

    do { // an unknown group id degrades to Inbox rather than vanishing
        let orphan = Project(id: 1, name: "T", colorHex: "#fff", sortOrder: 0, archived: false,
                             taskProjectID: 999)
        let rolled = Aggregations.rollUp(totals: [ProjectTotal(project: orphan, seconds: 60)],
                                        taskProjects: [])
        check(rolled.count == 1 && rolled[0].project == nil,
              "a dangling group reference shows as Inbox, and its time is not lost")
        check(approx(rolled[0].seconds, 60), "...with its seconds intact")
    }
}

// MARK: - Palette /project token

func testQueryParsing() {
    print("Query parsing:")

    do { // the common cases
        let a = TaskSearch.parse("profiling")
        check(a.name == "profiling" && a.groupToken == nil, "no slash → plain name")

        let b = TaskSearch.parse("profiling /tensor")
        check(b.name == "profiling" && b.groupToken == "tensor", "name + group token")

        let c = TaskSearch.parse("/tensor")
        check(c.name.isEmpty && c.groupToken == "tensor", "group-only query")

        let d = TaskSearch.parse("profiling /")
        check(d.name == "profiling" && d.groupToken == "", "bare slash = list all groups")
    }

    do { // a slash mid-word is part of the NAME, not a token
        let p = TaskSearch.parse("a/b testing")
        check(p.name == "a/b testing" && p.groupToken == nil,
              "mid-word slash doesn't start a group token")
    }

    do { // multi-word names and groups survive
        let p = TaskSearch.parse("review nova cr /work stuff")
        check(p.name == "review nova cr", "multi-word task name kept")
        check(p.groupToken == "work stuff", "multi-word group name kept")
    }

    do { // the last word-initial slash wins, so re-typing a token replaces it
        let p = TaskSearch.parse("profiling /old /new")
        check(p.groupToken == "new", "later token supersedes an earlier one")
        check(p.name == "profiling /old", "...and the earlier one stays in the name")
    }

    do { // group ranking reuses the tiered task scoring
        let groups = [
            TaskProject(id: 1, name: "tensorforge", colorHex: "#0f0"),
            TaskProject(id: 2, name: "admin", colorHex: "#00f"),
            TaskProject(id: 3, name: "team", colorHex: "#f00"),
        ]
        let r = TaskSearch.rankGroups(token: "te", groups: groups)
        check(r.count == 2, "'te' matches tensorforge + team, not admin")
        check(TaskSearch.rankGroups(token: "", groups: groups).count == 3,
              "empty token lists every group")
        check(TaskSearch.rankGroups(token: "zzz", groups: groups).isEmpty, "no match → empty")
    }
}

// MARK: - Window summary (drag-select on the day timeline)

func testWindowSummary() {
    print("WindowSummary:")

    func seg(_ id: Int64, _ project: Int64, _ from: Double, _ to: Double) -> DaySegment {
        DaySegment(id: id, projectID: project, startHour: from, endHour: to)
    }

    do { // tracked + idle always account for the whole window
        let segs = [seg(1, 10, 9.0, 10.0), seg(2, 11, 11.0, 11.5)]
        let s = Aggregations.windowSummary(segments: segs, from: 9, to: 12)
        check(approx(s.totalSeconds, 3 * 3600), "window total = 3h")
        check(approx(s.trackedSeconds, 1.5 * 3600), "tracked = 1h30m")
        check(approx(s.idleSeconds, 1.5 * 3600), "idle = the remaining 1h30m")
        check(approx(s.trackedSeconds + s.idleSeconds, s.totalSeconds), "tracked + idle = total")
        check(abs(s.trackedRatio - 0.5) < 0.001, "tracked ratio = 50%")
    }

    do { // segments are clipped to the window, not counted whole
        let segs = [seg(1, 10, 8.0, 11.0)]   // straddles both edges of a 9–10 window
        let s = Aggregations.windowSummary(segments: segs, from: 9, to: 10)
        check(approx(s.trackedSeconds, 3600), "a straddling segment contributes only its overlap")
        check(approx(s.idleSeconds, 0), "fully covered window has no idle time")
    }

    do { // overlapping segments must not double-count (would exceed the window / go negative)
        let segs = [seg(1, 10, 9.0, 10.0), seg(2, 11, 9.5, 10.5)]
        let s = Aggregations.windowSummary(segments: segs, from: 9, to: 11)
        check(approx(s.trackedSeconds, 1.5 * 3600), "overlap counted once (union, not sum)")
        check(s.idleSeconds >= 0, "idle never goes negative")
        check(s.trackedSeconds <= s.totalSeconds, "tracked never exceeds the window")
    }

    do { // a segment enclosed by another adds nothing to the union
        let segs = [seg(1, 10, 9.0, 11.0), seg(2, 11, 9.5, 10.0)]
        let s = Aggregations.windowSummary(segments: segs, from: 9, to: 11)
        check(approx(s.trackedSeconds, 2 * 3600), "enclosed segment doesn't inflate tracked time")
    }

    do { // per-task breakdown, largest first
        let segs = [seg(1, 10, 9.0, 9.5), seg(2, 11, 9.5, 11.0), seg(3, 10, 11.0, 11.25)]
        let s = Aggregations.windowSummary(segments: segs, from: 9, to: 12)
        check(s.byProject.count == 2, "one row per task")
        check(s.byProject.first?.projectID == 11, "largest contributor first")
        check(approx(s.byProject.first?.seconds ?? 0, 1.5 * 3600), "task 11 = 1h30m")
        check(approx(s.byProject.last?.seconds ?? 0, 0.75 * 3600), "task 10 = 45m across two blocks")
    }

    do { // reversed drag (right-to-left) normalises
        let segs = [seg(1, 10, 9.0, 10.0)]
        let a = Aggregations.windowSummary(segments: segs, from: 11, to: 9)
        let b = Aggregations.windowSummary(segments: segs, from: 9, to: 11)
        check(a == b, "dragging backwards gives the same summary")
    }

    do { // real prod shape: three blocks with two gaps in an 11:00–12:00 window.
        // Cross-checked against the same spans summed in SQL: 559 + 312 + 651 = 1522s tracked.
        func hm(_ hh: Int, _ mm: Int, _ ss: Int) -> Double {
            Double(hh) + Double(mm) / 60 + Double(ss) / 3600
        }
        let segs = [
            seg(1, 100, hm(11, 0, 0), hm(11, 9, 19)),
            seg(2, 100, hm(11, 31, 45), hm(11, 36, 57)),
            seg(3, 101, hm(11, 49, 8), hm(12, 0, 0)),
        ]
        let s = Aggregations.windowSummary(segments: segs, from: 11, to: 12)
        check(approx(s.trackedSeconds, 1522, 1), "real-data window: 1522s tracked")
        check(approx(s.idleSeconds, 2078, 1), "real-data window: 2078s idle")
        check(abs(s.trackedRatio - 1522.0 / 3600.0) < 0.001, "real-data window: ~42% tracked")
    }

    do { // snapping pulls both edges INWARD onto task boundaries
        let segs = [seg(1, 10, 9.0, 10.0), seg(2, 11, 11.0, 12.0)]
        // Sloppy drag from 8:45 to 12:15 → should tighten to exactly 9:00–12:00.
        let r = Aggregations.snapToSegments(segments: segs, from: 8.75, to: 12.25)
        check(approx(r.from, 9.0, 0.001), "start snaps forward to the first block's start")
        check(approx(r.to, 12.0, 0.001), "end snaps back to the last block's end")
    }

    do { // snapping never widens the selection beyond the drag
        let segs = [seg(1, 10, 9.0, 10.0), seg(2, 11, 11.0, 12.0)]
        // Drag covers only the second block; must not reach back to the first.
        let r = Aggregations.snapToSegments(segments: segs, from: 10.5, to: 12.25)
        check(approx(r.from, 11.0, 0.001), "start doesn't jump backwards to an earlier block")
        check(approx(r.to, 12.0, 0.001), "end still snaps in")
    }

    do { // a drag inside a single block has no boundary to snap to — left as-is
        let segs = [seg(1, 10, 9.0, 11.0)]
        let r = Aggregations.snapToSegments(segments: segs, from: 9.5, to: 10.5)
        check(approx(r.from, 9.5, 0.001) && approx(r.to, 10.5, 0.001),
              "a drag within one block keeps its raw edges")
    }

    do { // a drag across pure idle space stays as dragged (so it can report 100% idle)
        let segs = [seg(1, 10, 9.0, 10.0)]
        let r = Aggregations.snapToSegments(segments: segs, from: 11.0, to: 12.0)
        check(approx(r.from, 11.0, 0.001) && approx(r.to, 12.0, 0.001),
              "an all-idle selection isn't snapped onto distant blocks")
        let s = Aggregations.windowSummary(segments: segs, from: r.from, to: r.to)
        check(approx(s.trackedSeconds, 0) && approx(s.idleSeconds, 3600),
              "...and still reports a full hour idle")
    }

    do { // snapping keeps genuine gaps BETWEEN blocks as idle
        let segs = [seg(1, 10, 9.0, 9.5), seg(2, 11, 10.5, 11.0)]
        let r = Aggregations.snapToSegments(segments: segs, from: 8.9, to: 11.1)
        let s = Aggregations.windowSummary(segments: segs, from: r.from, to: r.to)
        check(approx(r.from, 9.0, 0.001) && approx(r.to, 11.0, 0.001), "snaps to 9:00–11:00")
        check(approx(s.trackedSeconds, 3600), "tracked = the two half-hour blocks")
        check(approx(s.idleSeconds, 3600), "the 1h gap between them stays idle")
    }

    do { // reversed drag snaps identically
        let segs = [seg(1, 10, 9.0, 10.0)]
        let a = Aggregations.snapToSegments(segments: segs, from: 10.5, to: 8.5)
        let b = Aggregations.snapToSegments(segments: segs, from: 8.5, to: 10.5)
        check(approx(a.from, b.from, 0.001) && approx(a.to, b.to, 0.001),
              "backwards drag snaps the same as forwards")
    }

    do { // no data at all is safe
        let r = Aggregations.snapToSegments(segments: [], from: 9.0, to: 12.0)
        check(approx(r.from, 9.0, 0.001) && approx(r.to, 12.0, 0.001), "no segments → unchanged")
    }

    do { // the per-task rows must reconcile with the Working figure shown above them.
        // byProject is un-merged, so with NO overlaps it should sum exactly to tracked time —
        // that's what makes it safe to drive "Where time went" from the same summary.
        let segs = [seg(1, 10, 9.0, 9.5), seg(2, 11, 10.0, 10.75), seg(3, 10, 11.0, 11.25)]
        let s = Aggregations.windowSummary(segments: segs, from: 9, to: 12)
        let rowSum = s.byProject.reduce(0.0) { $0 + $1.seconds }
        check(approx(rowSum, s.trackedSeconds), "per-task rows sum to the Working total")
        check(s.byProject.count == 2, "two distinct tasks in the selection")
    }

    do { // empty selection and no data are both safe
        let s = Aggregations.windowSummary(segments: [seg(1, 10, 9.0, 10.0)], from: 9, to: 9)
        check(approx(s.totalSeconds, 0) && approx(s.trackedSeconds, 0), "zero-width selection is empty")
        check(s.trackedRatio == 0, "ratio is 0 rather than NaN on a zero-width window")
        let none = Aggregations.windowSummary(segments: [], from: 9, to: 12)
        check(approx(none.idleSeconds, 3 * 3600), "no segments → the whole window is idle")
    }
}

// MARK: - Nudge policy (still-working / still-paused prompts)

func testNudgePolicy() {
    print("NudgePolicy:")

    let both = NudgePolicy.Config(promptsEnabled: true, sessionMinutes: 60, pausedMinutes: 15)

    // The two nudges are mutually exclusive: one needs a running timer, the other a paused one.
    check(NudgePolicy.armsSessionNudge(both, isRunning: true), "running arms the session nudge")
    check(!NudgePolicy.armsPausedNudge(both, isPaused: false, awaitingAnswer: false),
          "running does NOT arm the paused nudge")
    check(NudgePolicy.armsPausedNudge(both, isPaused: true, awaitingAnswer: false),
          "paused arms the paused nudge")
    check(!NudgePolicy.armsSessionNudge(both, isRunning: false),
          "paused does NOT arm the session nudge")

    // The checkpoint pauses the timer itself, so without this the second prompt would stack
    // on top of the first.
    check(!NudgePolicy.armsPausedNudge(both, isPaused: true, awaitingAnswer: true),
          "an unanswered prompt suppresses the paused nudge (no stacking)")

    // Master switch silences both, whatever the thresholds say.
    let off = NudgePolicy.Config(promptsEnabled: false, sessionMinutes: 60, pausedMinutes: 15)
    check(!NudgePolicy.armsSessionNudge(off, isRunning: true), "master off silences the session nudge")
    check(!NudgePolicy.armsPausedNudge(off, isPaused: true, awaitingAnswer: false),
          "master off silences the paused nudge")

    // Each threshold can be zeroed independently without affecting the other.
    let noSession = NudgePolicy.Config(promptsEnabled: true, sessionMinutes: 0, pausedMinutes: 15)
    check(!NudgePolicy.armsSessionNudge(noSession, isRunning: true), "0 minutes disables the session nudge")
    check(NudgePolicy.armsPausedNudge(noSession, isPaused: true, awaitingAnswer: false),
          "...leaving the paused nudge active")

    let noPaused = NudgePolicy.Config(promptsEnabled: true, sessionMinutes: 60, pausedMinutes: 0)
    check(!NudgePolicy.armsPausedNudge(noPaused, isPaused: true, awaitingAnswer: false),
          "0 minutes disables the paused nudge")
    check(NudgePolicy.armsSessionNudge(noPaused, isRunning: true), "...leaving the session nudge active")

    // Delay is measured from the start, and a threshold already passed fires promptly rather
    // than scheduling in the past (which would never fire).
    let t0 = date(2026, 3, 10, 9, 0)
    check(approx(NudgePolicy.delay(since: t0, threshold: 600, now: t0), 600, 0.001),
          "delay = full threshold at the moment of arming")
    check(approx(NudgePolicy.delay(since: t0, threshold: 600, now: t0.addingTimeInterval(400)), 200, 0.001),
          "delay shrinks as time passes")
    check(NudgePolicy.delay(since: t0, threshold: 600, now: t0.addingTimeInterval(9_999)) >= 1,
          "an overdue threshold still fires (never a negative delay)")
}

// MARK: - Run

do {
    try testStore()
    testAggregations()
    testFinishedVisibility()
    testTaskSearch()
    try testTaskProjects()
    testQueryParsing()
    testWindowSummary()
    testNudgePolicy()
} catch {
    print("  ✘ threw: \(error)")
    failures += 1
}

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
