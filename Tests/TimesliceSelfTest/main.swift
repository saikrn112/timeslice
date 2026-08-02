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

// MARK: - Run

do {
    try testStore()
    testAggregations()
    testFinishedVisibility()
    testTaskSearch()
} catch {
    print("  ✘ threw: \(error)")
    failures += 1
}

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
