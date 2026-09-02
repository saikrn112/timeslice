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

// MARK: - Google OAuth / PKCE

func testOAuthPKCE() {
    print("OAuth PKCE:")

    do { // SHA-256 against RFC 7636's own test vector — a wrong hash fails PKCE in a way that
        // looks like an OAuth misconfiguration, so pin it.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        var hash = [UInt8](repeating: 0, count: 32)
        SHA256Public.hash(Array(verifier.utf8), into: &hash)
        let challenge = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        check(challenge == expected, "S256 matches the RFC 7636 test vector")
    }

    do { // SHA-256 of the empty string, the classic boundary case
        var hash = [UInt8](repeating: 0, count: 32)
        SHA256Public.hash([], into: &hash)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        check(hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
              "SHA-256 of empty input is correct")
    }

    do { // a long input crosses the 64-byte block boundary
        var hash = [UInt8](repeating: 0, count: 32)
        SHA256Public.hash(Array(String(repeating: "a", count: 200).utf8), into: &hash)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        check(hex.count == 64 && hex != String(repeating: "0", count: 64),
              "multi-block input hashes without error")
    }

    do { // verifiers are per-attempt and within RFC length limits
        let a = GoogleOAuth.PKCE(), b = GoogleOAuth.PKCE()
        check(a.verifier != b.verifier, "each attempt gets a fresh verifier")
        check(a.verifier.count >= 43 && a.verifier.count <= 128, "verifier length is RFC-legal")
        check(!a.challenge.contains("=") && !a.challenge.contains("+") && !a.challenge.contains("/"),
              "challenge is base64url with no padding")
    }

    do { // the consent URL carries what Google needs
        let url = GoogleOAuth.authorizationURL(pkce: GoogleOAuth.PKCE(), port: 51789, state: "st")
        let s = url.absoluteString
        check(s.hasPrefix(GoogleOAuth.authEndpoint), "points at Google's auth endpoint")
        check(s.contains("code_challenge_method=S256"), "declares S256")
        check(s.contains("127.0.0.1:51789"), "loopback redirect on the chosen port")
        // The scope MUST match the space DriveAPI uses (appDataFolder). Requesting drive.file
        // while calling spaces=appDataFolder produced 403s that looked like "not signed in".
        check(s.contains("drive.appdata"), "requests the app-data scope, matching spaces=appDataFolder")
        check(!s.contains("client_secret"), "no secret in the URL (public client)")
    }

    do { // redirect parsing, success and failure
        let ok = GoogleOAuth.parseRedirect(requestLine: "GET /?code=4%2Fabc&state=xyz HTTP/1.1")
        check(ok.code == "4/abc", "authorization code extracted and unescaped")
        check(ok.state == "xyz", "state extracted, so CSRF can be checked")
        check(ok.error == nil, "no error on success")

        let denied = GoogleOAuth.parseRedirect(requestLine: "GET /?error=access_denied HTTP/1.1")
        check(denied.error == "access_denied", "user denial surfaces as an error")
        check(denied.code == nil, "...with no code")
    }

    do { // token bodies must carry BOTH the verifier and the secret.
        // Google rejects the exchange with "client_secret is missing." even for a Desktop client
        // using PKCE. Omitting it made sign-in fail silently, so pin both here.
        let body = String(decoding: GoogleOAuth.tokenRequestBody(
            code: "c", pkce: GoogleOAuth.PKCE(), port: 1), as: UTF8.self)
        check(body.contains("code_verifier="), "exchange sends the PKCE verifier")
        check(body.contains("client_secret="), "exchange sends client_secret (Google requires it)")
        check(body.contains("grant_type=authorization_code"), "correct grant for the exchange")

        let refresh = String(decoding: GoogleOAuth.refreshRequestBody(refreshToken: "r"),
                            as: UTF8.self)
        check(refresh.contains("grant_type=refresh_token"), "refresh uses the right grant")
        check(refresh.contains("client_secret="), "refresh also needs client_secret")

        // The AUTH url must never carry the secret — that would leak it into browser history.
        let authURL = GoogleOAuth.authorizationURL(pkce: GoogleOAuth.PKCE(), port: 1, state: "s")
        check(!authURL.absoluteString.contains("client_secret"),
              "secret stays out of the authorization URL")
        // Credentials are supplied at runtime (env or ~/.config/timeslice/env), never committed,
        // so a bare checkout legitimately has none. Assert the plumbing, not the value.
        if GoogleOAuth.isConfigured {
            check(!GoogleOAuth.clientSecret.isEmpty, "configured secret is non-empty")
            check(body.contains("client_secret="), "configured secret reaches the exchange")
        } else {
            check(GoogleOAuth.clientID.isEmpty, "unconfigured build reports no client id")
        }
    }
}

// MARK: - Takeover policy (one timer across devices)

func testTakeoverPolicy() {
    print("Takeover policy:")

    let t0 = Date(timeIntervalSince1970: 1000)
    func marker(_ device: String, since: TimeInterval) -> RunningMarker {
        RunningMarker(deviceID: device, taskUID: "u", since: since)
    }

    do { // not timing locally → nothing to stop
        check(TakeoverPolicy.decide(localRunningSince: nil,
                                    markers: [marker("B", since: 2000)], now: Date(timeIntervalSince1970: 3000)) == nil,
              "idle device isn't affected by a remote timer")
    }

    do { // remote started LATER → it wins
        let d = TakeoverPolicy.decide(localRunningSince: t0,
                                      markers: [marker("laptop", since: 2000)],
                                      now: Date(timeIntervalSince1970: 3000))
        check(d != nil, "later remote start takes over")
        check(d?.byDeviceID == "laptop", "reports which device took over")
        check(d?.pauseAt == Date(timeIntervalSince1970: 2000), "back-dated to the remote start")
    }

    do { // remote started EARLIER → we keep running (we're the newer intent)
        let d = TakeoverPolicy.decide(localRunningSince: Date(timeIntervalSince1970: 5000),
                                      markers: [marker("B", since: 2000)],
                                      now: Date(timeIntervalSince1970: 6000))
        check(d == nil, "an older remote timer doesn't stop a newer local one")
    }

    do { // clock skew: a remote clock ahead of us must not end the interval in the future
        let d = TakeoverPolicy.decide(localRunningSince: t0,
                                      markers: [marker("fastclock", since: 99_999)],
                                      now: Date(timeIntervalSince1970: 3000))
        check(d?.pauseAt == Date(timeIntervalSince1970: 3000), "future timestamp clamped to now")
    }

    do { // remote start before our own start would make a negative interval
        let d = TakeoverPolicy.decide(localRunningSince: Date(timeIntervalSince1970: 5000),
                                      markers: [marker("B", since: 5500)],
                                      now: Date(timeIntervalSince1970: 9000))
        check((d?.pauseAt.timeIntervalSince1970 ?? 0) >= 5000, "cutoff never predates our start")
    }

    do { // THE case that was broken in the field: both devices timing, later start wins.
        // The bug wasn't here — this always returned a decision — it was that a running device
        // stopped polling, so it never fetched the other's marker to feed in.
        let older = Date(timeIntervalSince1970: 1000)
        let d = TakeoverPolicy.decide(localRunningSince: older,
                                      markers: [marker("other", since: 1500)],
                                      now: Date(timeIntervalSince1970: 2000))
        check(d != nil, "both running → the older device yields")
        check(d?.pauseAt == Date(timeIntervalSince1970: 1500),
              "older device's session ends when the newer one began, so time isn't double-counted")

        // And the newer device, evaluating the same pair, must NOT stop itself.
        let reverse = TakeoverPolicy.decide(localRunningSince: Date(timeIntervalSince1970: 1500),
                                            markers: [marker("other", since: 1000)],
                                            now: Date(timeIntervalSince1970: 2000))
        check(reverse == nil, "newer device keeps running — exactly one of the pair stops")
    }

    do { // three devices → the most recent start wins
        let d = TakeoverPolicy.decide(localRunningSince: t0,
                                      markers: [marker("B", since: 2000), marker("C", since: 2500)],
                                      now: Date(timeIntervalSince1970: 3000))
        check(d?.byDeviceID == "C", "latest starter wins among several")
    }

    do { // no markers at all
        check(TakeoverPolicy.decide(localRunningSince: t0, markers: [],
                                    now: Date(timeIntervalSince1970: 3000)) == nil,
              "no remote timers → keep running")
    }

    do { // exact tie keeps the local timer, avoiding pointless churn
        check(TakeoverPolicy.decide(localRunningSince: t0,
                                    markers: [marker("B", since: 1000)],
                                    now: Date(timeIntervalSince1970: 3000)) == nil,
              "identical start times don't trigger a takeover")
    }
}

// MARK: - Field-level sync coverage
//
// A guard against the failure mode that produced every sync bug so far: a field exists on the
// model, the UI can change it, but somebody forgot to include it in the payload or the LWW UPDATE.
// Symptoms were always the same — everything syncs EXCEPT one thing, discovered by hand weeks later.
//
// These tests mutate each field individually and assert it survives a real store→payload→merge
// round trip. Adding a syncable field without wiring it up should fail here, not in production.

func testFieldLevelSyncCoverage() throws {
    print("Field-level sync coverage:")

    /// Mutate one field on A, merge into B, and assert B observes the change.
    func roundTrip(
        _ label: String,
        mutate: (IntervalStore, Int64) throws -> Void,
        expect: (Project) -> Bool
    ) throws {
        let (a, ua) = try makeStore(); let (b, ub) = try makeStore()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let ea = SyncEngine(store: a, deviceID: "A")
        let eb = SyncEngine(store: b, deviceID: "B")

        let task = try a.createProject(name: "baseline", colorHex: "#888888")
        _ = try eb.merge(try ea.buildPayload())          // B learns about the task
        guard try b.listProjects(includeArchived: true).count == 1 else {
            check(false, "\(label): setup — B should have the task"); return
        }

        // updated_at has 1s resolution in places; make the edit unambiguously newer.
        Thread.sleep(forTimeInterval: 0.02)
        try mutate(a, task)
        _ = try eb.merge(try ea.buildPayload())

        guard let onB = try b.listProjects(includeArchived: true).first else {
            check(false, "\(label): task vanished on B"); return
        }
        check(expect(onB), "\(label) propagates to the other device")
    }

    try roundTrip("rename",
                  mutate: { store, id in try store.renameProject(id: id, name: "renamed") },
                  expect: { $0.name == "renamed" })

    try roundTrip("colour change",
                  mutate: { store, id in try store.setProjectColor(id: id, colorHex: "#123456") },
                  expect: { $0.colorHex == "#123456" })

    try roundTrip("archive",
                  mutate: { store, id in try store.setProjectArchived(id: id, archived: true) },
                  expect: { $0.archived })

    try roundTrip("finish",
                  mutate: { store, id in try store.setProjectFinished(id: id, finished: true) },
                  expect: { $0.finished && $0.finishedAt != nil })

    try roundTrip("un-finish",
                  mutate: { store, id in
                      try store.setProjectFinished(id: id, finished: true)
                      Thread.sleep(forTimeInterval: 0.02)
                      try store.setProjectFinished(id: id, finished: false)
                  },
                  expect: { !$0.finished })

    // The one that was actually broken: moving a task between projects.
    try roundTrip("project assignment",
                  mutate: { store, id in
                      let g = try store.upsertTaskProject(name: "moved-into", colorHex: "#0f0")
                      try store.setTaskProject(taskID: id, taskProjectID: g)
                  },
                  expect: { $0.taskProjectID != nil })

    try roundTrip("move back to Inbox",
                  mutate: { store, id in
                      let g = try store.upsertTaskProject(name: "temp", colorHex: "#0f0")
                      try store.setTaskProject(taskID: id, taskProjectID: g)
                      Thread.sleep(forTimeInterval: 0.02)
                      try store.setTaskProject(taskID: id, taskProjectID: nil)
                  },
                  expect: { $0.taskProjectID == nil })

    do { // Payload completeness: every mutable field on Project must appear in TaskRecord.
        // Reflection-based, so a newly added property fails this until it's carried in the payload.
        let task = Project(id: 1, name: "x", colorHex: "#fff", sortOrder: 3, archived: true,
                           finished: true, finishedAt: Date(), taskProjectID: 9)
        let modelFields = Set(Mirror(reflecting: task).children.compactMap(\.label))
        let record = SyncPayload.TaskRecord(
            uid: "u", name: "x", colorHex: "#fff", sortOrder: 3, archived: true, finished: true,
            finishedAt: 0, projectUID: "p", updatedAt: 0)
        var recordFields = Set(Mirror(reflecting: record).children.compactMap(\.label))
        // `taskProjectID` travels as `projectUID` (ids differ per device); `id` is device-local.
        recordFields.insert("taskProjectID")
        let missing = modelFields.subtracting(recordFields).subtracting(["id"])
        check(missing.isEmpty,
              "every syncable Project field is in the payload (missing: \(missing.sorted()))")
    }

    do { // Same for projects/groups.
        let group = TaskProject(id: 1, name: "g", colorHex: "#fff", sortOrder: 2)
        let modelFields = Set(Mirror(reflecting: group).children.compactMap(\.label))
        let record = SyncPayload.ProjectRecord(uid: "u", name: "g", colorHex: "#fff",
                                               sortOrder: 2, updatedAt: 0)
        let recordFields = Set(Mirror(reflecting: record).children.compactMap(\.label))
        let missing = modelFields.subtracting(recordFields).subtracting(["id"])
        check(missing.isEmpty,
              "every syncable TaskProject field is in the payload (missing: \(missing.sorted()))")
    }

    do { // Same for intervals. `deviceID` was added to Interval and initially wasn't carried in
        // the payload, so merged rows lost their attribution — exactly what this guard catches.
        let interval = Interval(id: 1, projectID: 2, start: Date(), end: Date(), deviceID: "d")
        let modelFields = Set(Mirror(reflecting: interval).children.compactMap(\.label))
        let record = SyncPayload.IntervalRecord(uid: "u", taskUID: "t", start: 0, end: 0,
                                               deviceID: "d")
        var recordFields = Set(Mirror(reflecting: record).children.compactMap(\.label))
        // `projectID` travels as `taskUID` (ids differ per device); `id` is device-local.
        recordFields.insert("projectID")
        let missing = modelFields.subtracting(recordFields).subtracting(["id"])
        check(missing.isEmpty,
              "every syncable Interval field is in the payload (missing: \(missing.sorted()))")
    }

    do { // Project (group) edits propagate too — rename and recolour.
        let (a, ua) = try makeStore(); let (b, ub) = try makeStore()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let ea = SyncEngine(store: a, deviceID: "A")
        let eb = SyncEngine(store: b, deviceID: "B")
        let g = try a.upsertTaskProject(name: "original", colorHex: "#aaaaaa")
        let t = try a.createProject(name: "task", colorHex: "#fff")
        try a.setTaskProject(taskID: t, taskProjectID: g)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTaskProjects().first?.name == "original", "B received the project")

        Thread.sleep(forTimeInterval: 0.02)
        try a.renameTaskProject(id: g, name: "renamed group")
        _ = try eb.merge(try ea.buildPayload())
        // Matched by uid, so the rename REPLACES the name rather than adding a second project.
        let names = try b.listTaskProjects().map(\.name).sorted()
        check(names == ["renamed group"],
              "renamed project is renamed on the other device, not duplicated (got \(names))")
        check(try b.listTaskProjects().count == 1, "no duplicate project left behind")

        // And a recolour propagates the same way.
        Thread.sleep(forTimeInterval: 0.02)
        try a.setTaskProjectColor(id: g, colorHex: "#bbbbbb")
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTaskProjects().first?.colorHex == "#bbbbbb", "recolour propagates")
    }
}

// MARK: - Sync engine (two devices, no network)

func testSyncEngine() throws {
    print("Sync engine:")

    func twoDevices() throws -> (IntervalStore, IntervalStore, URL, URL, SyncEngine, SyncEngine) {
        let (a, ua) = try makeStore()
        let (b, ub) = try makeStore()
        return (a, b, ua, ub, SyncEngine(store: a, deviceID: "A"), SyncEngine(store: b, deviceID: "B"))
    }

    do { // intervals flow both ways and nothing is lost
        let (a, b, ua, ub, ea, eb) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let t1 = try a.createProject(name: "deep work", colorHex: "#f00")
        try a.switchTo(projectID: t1, at: Date(timeIntervalSince1970: 1000))
        try a.stopOpenInterval(at: Date(timeIntervalSince1970: 4600))

        let t2 = try b.createProject(name: "ncu", colorHex: "#0f0")
        try b.switchTo(projectID: t2, at: Date(timeIntervalSince1970: 5000))
        try b.stopOpenInterval(at: Date(timeIntervalSince1970: 8600))

        let r = try eb.merge(try ea.buildPayload())
        check(r.tasksAdded == 1 && r.intervalsAdded == 1, "B gained A's task + interval")
        check(try b.listProjects(includeArchived: true).count == 2, "B now has both tasks")
        check(try b.intervals().count == 2, "B now has both intervals")

        try ea.merge(try eb.buildPayload())
        check(try a.intervals().count == 2, "A gained B's interval too")
    }

    do { // merging twice is a no-op — the property that makes a dumb transport safe
        let (a, b, ua, ub, ea, eb) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let t = try a.createProject(name: "x", colorHex: "#f00")
        try a.switchTo(projectID: t); try a.stopOpenInterval()

        let payload = try ea.buildPayload()
        _ = try eb.merge(payload)
        let after1 = (try b.listProjects().count, try b.intervals().count)
        let second = try eb.merge(payload)
        let after2 = (try b.listProjects().count, try b.intervals().count)
        check(after1 == after2, "second merge adds nothing")
        check(second.isEmpty, "...and reports no changes")
    }

    do { // projects with the SAME NAME merge into one; tasks with the same name do not
        let (a, b, ua, ub, ea, eb) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let ga = try a.upsertTaskProject(name: "personal", colorHex: "#f00")
        let ta = try a.createProject(name: "gym", colorHex: "#f00")
        try a.setTaskProject(taskID: ta, taskProjectID: ga)

        // B independently created a project with the same name, different uid.
        let gb = try b.upsertTaskProject(name: "Personal", colorHex: "#0f0")   // different case
        let tb = try b.createProject(name: "gym", colorHex: "#0f0")            // same task name!
        try b.setTaskProject(taskID: tb, taskProjectID: gb)

        let r = try eb.merge(try ea.buildPayload())
        check(try b.listTaskProjects().count == 1, "same-named projects merged into one")
        check(r.projectsMergedByName.count == 1, "...and the report says so")
        check(try b.listProjects().count == 2, "same-named TASKS stay separate (no time fusion)")
    }

    do { // same-named projects converge on ONE colour, and BOTH devices pick the same one.
        // Colours come from a per-device index, so each device generated its own hue for
        // "personal" and kept it — the same project looked different on each machine.
        let (a, b, ua, ub, ea, eb) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        _ = try a.upsertTaskProject(name: "personal", colorHex: "#FF0000")   // lexically larger
        _ = try b.upsertTaskProject(name: "personal", colorHex: "#00FF00")   // lexically smaller

        _ = try eb.merge(try ea.buildPayload())
        _ = try ea.merge(try eb.buildPayload())

        let colourA = try a.listTaskProjects().first?.colorHex
        let colourB = try b.listTaskProjects().first?.colorHex
        check(colourA == colourB, "both devices end up with the same project colour")
        check(colourA == "#00FF00", "the stable rule (smaller hex) decides, not merge order")
        check(try a.listTaskProjects().count == 1, "still one project, not a duplicate")
    }

    do { // convergence must not depend on WHICH device merges first
        let (a, b, ua, ub, ea, eb) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        _ = try a.upsertTaskProject(name: "work", colorHex: "#AAAAAA")
        _ = try b.upsertTaskProject(name: "work", colorHex: "#111111")
        // Reverse order from the previous case.
        _ = try ea.merge(try eb.buildPayload())
        _ = try eb.merge(try ea.buildPayload())
        check(try a.listTaskProjects().first?.colorHex == "#111111", "same winner either order (A)")
        check(try b.listTaskProjects().first?.colorHex == "#111111", "same winner either order (B)")
    }

    do { // last-write-wins on a metadata edit
        let (a, b, ua, ub, ea, eb) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let t = try a.createProject(name: "original", colorHex: "#f00")
        try a.switchTo(projectID: t); try a.stopOpenInterval()
        _ = try eb.merge(try ea.buildPayload())

        // A renames later than B's copy → A wins.
        Thread.sleep(forTimeInterval: 0.02)
        try a.renameProject(id: t, name: "renamed on A")
        let r = try eb.merge(try ea.buildPayload())
        check(r.taskEditsApplied == 1, "newer remote edit applied")
        check(try b.listProjects().first?.name == "renamed on A", "B took A's newer name")

        // Now B edits even later; A must NOT clobber it on the next merge.
        Thread.sleep(forTimeInterval: 0.02)
        let localID = try b.listProjects().first!.id
        try b.renameProject(id: localID, name: "newer on B")
        let r2 = try eb.merge(try ea.buildPayload())
        check(r2.taskEditsApplied == 0, "stale remote edit rejected")
        check(try b.listProjects().first?.name == "newer on B", "B's newer edit survives")
    }

    do { // editing a task created ELSEWHERE propagates back, including its project assignment
        let (a, b, ua, ub, ea, eb) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        // A creates a task in a project; B pulls both in.
        let ga = try a.upsertTaskProject(name: "work", colorHex: "#111111")
        let t = try a.createProject(name: "ncu", colorHex: "#f00")
        try a.setTaskProject(taskID: t, taskProjectID: ga)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listProjects().first?.taskProjectID != nil, "B received it inside a project")

        // B — which did NOT create it — moves it to a different project and renames it.
        let localTask = try b.listProjects().first!.id
        let gb = try b.upsertTaskProject(name: "personal", colorHex: "#222222")
        Thread.sleep(forTimeInterval: 0.02)
        try b.setTaskProject(taskID: localTask, taskProjectID: gb)
        try b.renameProject(id: localTask, name: "ncu profiling")

        // A merges B's newer edit: both the rename AND the move must land.
        _ = try ea.merge(try eb.buildPayload())
        let onA = try a.listProjects().first
        check(onA?.name == "ncu profiling", "rename by the non-creating device wins (newer)")
        let personalOnA = try a.taskProject(named: "personal")
        check(onA?.taskProjectID == personalOnA?.id,
              "project MOVE propagates too — this field was previously left out of LWW")
    }

    do { // a delete propagates and does NOT come back on the next merge
        let (a, b, ua, ub, ea, eb) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let t = try a.createProject(name: "doomed", colorHex: "#f00")
        try a.switchTo(projectID: t); try a.stopOpenInterval()
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listProjects().count == 1, "B has the task")

        try a.deleteProject(id: t)
        let r = try eb.merge(try ea.buildPayload())
        check(r.deletionsApplied >= 1, "delete propagated")
        check(try b.listProjects().isEmpty, "task gone on B")
        check(try b.intervals().isEmpty, "...and so are its intervals")

        // The killer case: B re-publishes, A merges back — the row must not resurrect.
        _ = try ea.merge(try eb.buildPayload())
        check(try a.listProjects().isEmpty, "deleted task does not come back on A")
    }

    do { // a RUNNING interval is never published as a fact
        let (a, _, ua, ub, ea, eb) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let t = try a.createProject(name: "live", colorHex: "#f00")
        try a.switchTo(projectID: t)   // left running
        let payload = try ea.buildPayload()
        check(payload.intervals.isEmpty, "running interval excluded from the payload")
        _ = eb
    }

    do { // a device ignores its own file
        let (a, _, ua, ub, ea, _) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let t = try a.createProject(name: "x", colorHex: "#f00")
        try a.switchTo(projectID: t); try a.stopOpenInterval()
        let r = try ea.merge(try ea.buildPayload())
        check(r.isEmpty, "merging our own payload is a no-op")
    }

    do { // end-to-end through a real folder: two stores, one directory, no network
        let (a, ua) = try makeStore(); let (b, ub) = try makeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-sync-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: ua)
            try? FileManager.default.removeItem(at: ub)
            try? FileManager.default.removeItem(at: dir)
        }
        let transport = try FolderSyncTransport(root: dir)
        let ea = SyncEngine(store: a, deviceID: "A")
        let eb = SyncEngine(store: b, deviceID: "B")

        let t = try a.createProject(name: "shared", colorHex: "#f00")
        try a.switchTo(projectID: t, at: Date(timeIntervalSince1970: 1000))
        try a.stopOpenInterval(at: Date(timeIntervalSince1970: 4600))

        // A publishes; B reads and merges.
        try transport.put(payload: try JSONEncoder().encode(try ea.buildPayload()), deviceID: "A")
        let others = try transport.fetchOthers(excluding: "B")
        check(others.count == 1, "B sees exactly A's file")
        for data in others {
            _ = try eb.merge(try JSONDecoder().decode(SyncPayload.self, from: data))
        }
        check(try b.intervals().count == 1, "B merged A's interval through the folder")

        // A must not read its own file back.
        check(try transport.fetchOthers(excluding: "A").isEmpty, "a device ignores its own payload")

        // Running markers: presence, not history.
        let marker = RunningMarker(deviceID: "A", taskUID: "u1", since: 5000)
        try transport.putRunning(try JSONEncoder().encode(marker), deviceID: "A")
        check(try transport.fetchOtherRunning(excluding: "B").count == 1, "B sees A is timing")
        try transport.putRunning(nil, deviceID: "A")
        check(try transport.fetchOtherRunning(excluding: "B").isEmpty, "clearing the marker works")
    }

    do { // payload survives a JSON round trip (what a transport actually moves)
        let (a, _, ua, ub, ea, _) = try twoDevices()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let g = try a.upsertTaskProject(name: "grp", colorHex: "#00f")
        let t = try a.createProject(name: "x", colorHex: "#f00")
        try a.setTaskProject(taskID: t, taskProjectID: g)
        try a.switchTo(projectID: t); try a.stopOpenInterval()

        let payload = try ea.buildPayload()
        let data = try JSONEncoder().encode(payload)
        let back = try JSONDecoder().decode(SyncPayload.self, from: data)
        check(back == payload, "payload round-trips through JSON unchanged")
    }
}

// MARK: - Overlap safety (two devices, or old imports)

func testOverlapSafety() {
    print("Overlap safety:")

    let day = date(2026, 3, 10, 0, 0)
    let r = DateRange(unit: .day, start: day,
                      end: cal.date(byAdding: .day, value: 1, to: day)!)

    // Two devices each logged a session; they overlap 10:00–11:00.
    let ivs = [
        Interval(id: 1, projectID: 1, start: date(2026, 3, 10, 9, 0), end: date(2026, 3, 10, 11, 0)),
        Interval(id: 2, projectID: 2, start: date(2026, 3, 10, 10, 0), end: date(2026, 3, 10, 12, 0)),
    ]

    do { // summary: wall-clock is 9→12 = 3h, NOT 2h + 2h = 4h
        let s = Aggregations.summary(intervals: ivs, range: r, deepThreshold: 25 * 60,
                                     now: date(2026, 3, 10, 23, 0), calendar: cal)
        check(approx(s.totalSeconds, 3 * 3600), "summary unions overlap: 3h, not 4h")
        check(approx(s.bestDaySeconds, 3 * 3600), "best day also unioned")
        check(s.totalSeconds <= 24 * 3600, "a day can never exceed 24h")
        check(s.deepSeconds <= s.totalSeconds, "focused time can't exceed tracked time")
    }

    do { // the union must not inflate a day past what was actually worked
        let s = Aggregations.summary(intervals: ivs, range: r, deepThreshold: 25 * 60,
                                     now: date(2026, 3, 10, 23, 0), calendar: cal)
        check(approx(s.totalSeconds, 3 * 3600),
              "two overlapping 2h blocks are 3h of wall clock, not 4h")
        check(s.totalSeconds < 4 * 3600, "summing would have reported 4h")
    }

    do { // buckets: the bar height is wall-clock too
        let b = Aggregations.buckets(intervals: ivs, range: r, deepThreshold: 25 * 60,
                                     now: date(2026, 3, 10, 23, 0), calendar: cal)
        let onDay = b.first { cal.isDate($0.start, inSameDayAs: day) }
        check(onDay != nil, "found the day's bucket")
        check(approx(onDay?.totalSeconds ?? 0, 3 * 3600), "bucket unions overlap: 3h, not 4h")
        check((onDay?.deepSeconds ?? 0) <= (onDay?.totalSeconds ?? 0), "deep ≤ total in a bucket")
    }

    do { // per-TASK totals still sum — "how long on task 1" is 2h regardless of overlap
        let t = Aggregations.totals(projects: [project(1), project(2)], intervals: ivs, range: r,
                                    now: date(2026, 3, 10, 23, 0))
        let byID = Dictionary(uniqueKeysWithValues: t.map { ($0.project.id, $0.seconds) })
        check(approx(byID[1] ?? 0, 2 * 3600), "task 1 = 2h (per-task sums, by design)")
        check(approx(byID[2] ?? 0, 2 * 3600), "task 2 = 2h")
        let sum = t.reduce(0.0) { $0 + $1.seconds }
        check(sum > 3 * 3600, "Σ per-task (4h) exceeds wall-clock (3h) — expected, not a bug")
    }

    do { // fully-enclosed span adds nothing
        let nested = [
            Interval(id: 1, projectID: 1, start: date(2026, 3, 10, 9, 0), end: date(2026, 3, 10, 12, 0)),
            Interval(id: 2, projectID: 2, start: date(2026, 3, 10, 10, 0), end: date(2026, 3, 10, 11, 0)),
        ]
        let s = Aggregations.summary(intervals: nested, range: r, deepThreshold: 25 * 60,
                                     now: date(2026, 3, 10, 23, 0), calendar: cal)
        check(approx(s.totalSeconds, 3 * 3600), "enclosed span doesn't inflate the day")
    }

    do { // no overlap → everything in lane 0, timeline unchanged
        func seg(_ id: Int64, _ from: Double, _ to: Double) -> DaySegment {
            DaySegment(id: id, projectID: 1, startHour: from, endHour: to)
        }
        let laid = Aggregations.assignLanes([seg(1, 9, 10), seg(2, 10, 11), seg(3, 11, 12)])
        check(laid.allSatisfy { $0.lane == 0 }, "non-overlapping segments all use lane 0")
        check(Aggregations.laneCount(laid) == 1, "one lane needed")
    }

    do { // overlap → separate lanes so neither is hidden
        func seg(_ id: Int64, _ from: Double, _ to: Double) -> DaySegment {
            DaySegment(id: id, projectID: id, startHour: from, endHour: to)
        }
        let laid = Aggregations.assignLanes([seg(1, 9, 11), seg(2, 10, 12)])
        check(laid[0].lane != laid[1].lane, "overlapping segments get different lanes")
        check(Aggregations.laneCount(laid) == 2, "two lanes needed")
    }

    do { // a lane is REUSED once free — three sessions, only two overlap at a time
        func seg(_ id: Int64, _ from: Double, _ to: Double) -> DaySegment {
            DaySegment(id: id, projectID: id, startHour: from, endHour: to)
        }
        let laid = Aggregations.assignLanes([seg(1, 9, 11), seg(2, 10, 12), seg(3, 12, 13)])
        check(Aggregations.laneCount(laid) == 2, "third segment reuses lane 0, not a third lane")
        check(laid.first { $0.id == 3 }?.lane == 0, "...specifically lane 0")
    }

    do { // three-way overlap
        func seg(_ id: Int64, _ from: Double, _ to: Double) -> DaySegment {
            DaySegment(id: id, projectID: id, startHour: from, endHour: to)
        }
        let laid = Aggregations.assignLanes([seg(1, 9, 12), seg(2, 10, 12), seg(3, 11, 12)])
        check(Aggregations.laneCount(laid) == 3, "three concurrent segments need three lanes")
        check(Set(laid.map(\.lane)).count == 3, "...all distinct")
    }

    do { // touching (not overlapping) segments share a lane — 10:00 end, 10:00 start
        func seg(_ id: Int64, _ from: Double, _ to: Double) -> DaySegment {
            DaySegment(id: id, projectID: id, startHour: from, endHour: to)
        }
        let laid = Aggregations.assignLanes([seg(1, 9, 10), seg(2, 10, 11)])
        check(Aggregations.laneCount(laid) == 1, "back-to-back sessions aren't treated as overlap")
    }

    do { // SpanUnion directly: identical spans, and out-of-order input
        let a = date(2026, 3, 10, 9, 0), b = date(2026, 3, 10, 10, 0)
        check(approx(SpanUnion.coveredSeconds([(a, b), (a, b)]), 3600), "duplicate spans count once")
        let c = date(2026, 3, 10, 11, 0), d = date(2026, 3, 10, 12, 0)
        check(approx(SpanUnion.coveredSeconds([(c, d), (a, b)]), 7200), "unsorted input handled")
        check(approx(SpanUnion.coveredSeconds([]), 0), "no spans → 0")
        check(approx(SpanUnion.coveredSeconds([(b, a)]), 0), "inverted span ignored")
    }
}

// MARK: - Sync groundwork (uid / updated_at / tombstones)

func testSyncGroundwork() throws {
    print("Sync groundwork:")

    do { // every new row gets a unique uid — local AUTOINCREMENT ids collide across devices
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        let b = try store.createProject(name: "B", colorHex: "#0f0")
        try store.switchTo(projectID: a); try store.stopOpenInterval()
        try store.switchTo(projectID: b); try store.stopOpenInterval()
        let g = try store.upsertTaskProject(name: "grp", colorHex: "#00f")

        check(try store.uidCount(table: "projects") == 2, "both tasks got a uid")
        check(try store.uidCount(table: "intervals") == 2, "both intervals got a uid")
        check(try store.uidCount(table: "task_projects") == 1, "the project got a uid")
        check(try store.distinctUIDCount(table: "intervals") == 2, "interval uids are distinct")
        _ = g
    }

    do { // metadata edits stamp updated_at so LWW can order them
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        let first = try store.updatedAt(table: "projects", id: a)
        check(first != nil, "created rows have updated_at")

        // Rename later and confirm the stamp moves forward.
        Thread.sleep(forTimeInterval: 0.01)
        try store.renameProject(id: a, name: "A2")
        let second = try store.updatedAt(table: "projects", id: a)
        check((second ?? 0) > (first ?? 0), "rename advances updated_at")

        Thread.sleep(forTimeInterval: 0.01)
        try store.setProjectFinished(id: a, finished: true)
        let third = try store.updatedAt(table: "projects", id: a)
        check((third ?? 0) > (second ?? 0), "finishing advances updated_at")
    }

    do { // deletes leave tombstones, or a merge silently resurrects the row
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        try store.switchTo(projectID: a); try store.stopOpenInterval()
        try store.deleteProject(id: a)
        check(try store.tombstoneUIDs(kind: "task").count == 1, "deleting a task tombstones it")
        check(try store.tombstoneUIDs(kind: "interval").count == 1, "...and its intervals")
    }

    do { // resetting time tombstones the intervals but not the task
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        try store.switchTo(projectID: a); try store.stopOpenInterval()
        try store.resetProjectIntervals(id: a)
        check(try store.tombstoneUIDs(kind: "interval").count == 1, "reset tombstones the intervals")
        check(try store.tombstoneUIDs(kind: "task").isEmpty, "...but keeps the task alive")
    }

    do { // deleting a project tombstones it; its tasks survive (they fall back to Inbox)
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "A", colorHex: "#f00")
        let g = try store.upsertTaskProject(name: "grp", colorHex: "#0f0")
        try store.setTaskProject(taskID: a, taskProjectID: g)
        try store.deleteTaskProject(id: g)
        check(try store.tombstoneUIDs(kind: "task_project").count == 1, "project tombstoned")
        check(try store.tombstoneUIDs(kind: "task").isEmpty, "its task is NOT deleted")
        check(try store.listProjects().count == 1, "...and still exists locally")
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

// MARK: - Device attribution

func testDeviceAttribution() throws {
    print("Device attribution:")

    do { // writes self-stamp, and reads carry the device back
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let id = try store.createProject(name: "a", colorHex: "#fff")
        store.localDeviceID = "mac-1"
        try store.insertClosedInterval(projectID: id, start: date(2026, 8, 1, 9, 0),
                                       end: date(2026, 8, 1, 10, 0))
        let rows = try store.intervals()
        check(rows.count == 1 && rows[0].deviceID == "mac-1",
              "an interval records the device that wrote it")
    }

    do { // an explicit device wins over the local one (replay/import), and nil stays nil
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let id = try store.createProject(name: "a", colorHex: "#fff")
        store.localDeviceID = "mac-1"
        try store.insertClosedInterval(projectID: id, start: date(2026, 8, 1, 9, 0),
                                       end: date(2026, 8, 1, 10, 0), deviceID: "mac-2")
        store.localDeviceID = nil
        try store.insertClosedInterval(projectID: id, start: date(2026, 8, 1, 11, 0),
                                       end: date(2026, 8, 1, 12, 0))
        let rows = try store.intervals().sorted { $0.start < $1.start }
        check(rows[0].deviceID == "mac-2", "an explicit deviceID overrides the local one")
        check(rows[1].deviceID == nil, "no local device leaves the row unattributed, not guessed")
    }

    do { // a merged interval keeps its ORIGINATING device, not the merging one
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        a.localDeviceID = "mac-a"; b.localDeviceID = "mac-b"
        let ida = try a.createProject(name: "shared", colorHex: "#fff")
        try a.insertClosedInterval(projectID: ida, start: date(2026, 8, 1, 9, 0),
                                   end: date(2026, 8, 1, 10, 0))
        let ea = SyncEngine(store: a, deviceID: "mac-a", deviceLabel: "Air")
        let eb = SyncEngine(store: b, deviceID: "mac-b", deviceLabel: "Pro")
        _ = try eb.merge(try ea.buildPayload())
        let merged = try b.intervals()
        check(merged.count == 1 && merged[0].deviceID == "mac-a",
              "a merged interval stays attributed to the device that recorded it")
        check((try b.deviceLabels())["mac-a"] == "Air",
              "merging remembers the sender's label so offline devices stay nameable")
    }

    do { // the backfill's guess gets repaired by the owner on the next sync
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        a.localDeviceID = "mac-a"; b.localDeviceID = "mac-b"
        let ida = try a.createProject(name: "shared", colorHex: "#fff")
        try a.insertClosedInterval(projectID: ida, start: date(2026, 8, 1, 9, 0),
                                   end: date(2026, 8, 1, 10, 0))
        let ea = SyncEngine(store: a, deviceID: "mac-a")
        let eb = SyncEngine(store: b, deviceID: "mac-b")
        let payload = try ea.buildPayload()
        _ = try eb.merge(payload)

        // Simulate the one-time backfill mis-stamping a merged row as local.
        let uid = try b.intervalsWithUIDs().first!.uid
        try b.reattributeInterval(uid: uid, deviceID: "mac-b")
        check(try b.intervals()[0].deviceID == "mac-b", "precondition: the row is mis-attributed")

        let report = try eb.merge(payload)
        check(report.intervalsReattributed == 1, "the owner's payload repairs the attribution")
        check(try b.intervals()[0].deviceID == "mac-a", "the row is restored to its real device")

        // And it's idempotent: a third merge finds nothing left to fix.
        check(try eb.merge(payload).intervalsReattributed == 0,
              "re-attribution is idempotent, so it doesn't churn every poll")
    }

    do { // labels persist and a label-less payload doesn't blank a known name
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        try store.rememberDevice(id: "mac-1", label: "Air")
        try store.rememberDevice(id: "mac-1", label: nil)
        check((try store.deviceLabels())["mac-1"] == "Air",
              "a payload with no label keeps the previously-known name")
    }
}

// MARK: - Device-aware timeline lanes

func testDeviceLanes() {
    print("Device lanes:")

    let day = date(2026, 8, 1, 0, 0)
    func iv(_ id: Int64, _ h1: Int, _ h2: Int, _ dev: String?) -> Interval {
        Interval(id: id, projectID: 1, start: date(2026, 8, 1, h1, 0),
                 end: date(2026, 8, 1, h2, 0), deviceID: dev)
    }

    do { // one device: everything stays on lane 0, as before
        let segs = Aggregations.daySegments(
            intervals: [iv(1, 9, 10, "a"), iv(2, 11, 12, "a")], day: day, calendar: cal)
        check(Aggregations.laneCount(segs) == 1, "a single device keeps one lane")
    }

    do { // two devices: one lane each, even when their blocks DON'T overlap
        let segs = Aggregations.daySegments(
            intervals: [iv(1, 9, 10, "a"), iv(2, 11, 12, "b")], day: day, calendar: cal)
        check(Aggregations.laneCount(segs) == 2, "two devices get a lane each")
        let laneOf = Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0.lane) })
        check(laneOf[1] != laneOf[2], "non-overlapping blocks from different devices don't share a row")
    }

    do { // a device's own blocks never land on another device's row
        let segs = Aggregations.daySegments(
            intervals: [iv(1, 9, 12, "a"), iv(2, 10, 11, "a"), iv(3, 9, 10, "b")],
            day: day, calendar: cal)
        var lanesByDevice: [String: Set<Int>] = [:]
        for seg in segs { lanesByDevice[seg.deviceID ?? "?", default: []].insert(seg.lane) }
        check(lanesByDevice["a"]!.isDisjoint(with: lanesByDevice["b"]!),
              "each device owns its own lanes, so a row always names one machine")
        check(lanesByDevice["a"]!.count == 2, "a device's overlapping blocks still fan out")
    }

    do { // a DaySegment rebuilt with fewer arguments silently loses its device — the Sessions list
        // clipped segments to the selection this way and showed every row as "unknown".
        // Reflection-based so a newly added property fails this until it's carried too.
        let seg = DaySegment(id: 1, projectID: 2, startHour: 9, endHour: 10, lane: 3, deviceID: "d")
        let fields = Set(Mirror(reflecting: seg).children.compactMap(\.label))
        // Rebuild the way a clip does, then check nothing was dropped.
        let clipped = DaySegment(id: seg.id, projectID: seg.projectID,
                                 startHour: max(seg.startHour, 9.5), endHour: seg.endHour,
                                 lane: seg.lane, deviceID: seg.deviceID)
        let preserved = Set(Mirror(reflecting: clipped).children.compactMap { child -> String? in
            guard let label = child.label else { return nil }
            // Positions legitimately change when clipping; everything else must survive.
            if label == "startHour" || label == "endHour" { return label }
            let before = Mirror(reflecting: seg).children.first { $0.label == label }?.value
            return "\(child.value)" == "\(before ?? "")" ? label : nil
        })
        check(fields == preserved,
              "clipping a segment preserves every non-positional field (lost: \(fields.subtracting(preserved).sorted()))")
    }

    do { // per-device time UNIONS that device's own overlaps instead of summing them
        let day = date(2026, 8, 1, 0, 0)
        // Two blocks from one device overlapping 9:30-10:00: 9-10 plus 9:30-11 is 2h, not 2.5h.
        let segs = Aggregations.daySegments(
            intervals: [iv(1, 9, 10, "a"),
                        Interval(id: 2, projectID: 1, start: date(2026, 8, 1, 9, 30),
                                 end: date(2026, 8, 1, 11, 0), deviceID: "a")],
            day: day, calendar: cal)
        let spans = segs.filter { $0.deviceID == "a" }.map {
            (start: day.addingTimeInterval($0.startHour * 3600),
             end: day.addingTimeInterval($0.endHour * 3600))
        }
        check(approx(SpanUnion.coveredSeconds(spans) / 3600, 2.0),
              "a device's overlapping blocks count once, not twice")
    }

    do { // a raw device id reads as its model in a narrow lane label
        check(TimeslicePaths.shortDeviceName("iphone-b653") == "iphone",
              "the 4-hex disambiguator is dropped for display")
        check(TimeslicePaths.shortDeviceName("macbook-air-1e01") == "macbook-air",
              "a model slug containing a dash survives")
        check(TimeslicePaths.shortDeviceName("work") == "work", "a plain name is untouched")
        check(TimeslicePaths.shortDeviceName("my-desk-mac") == "my-desk-mac",
              "a user-chosen name whose last part isn't 4 hex chars is left alone")
        check(TimeslicePaths.shortDeviceName("80a9970a4461-57ec") == "80a9970a4461",
              "and a MAC-address-shaped id still loses only its suffix")
    }

    do { // ordering is stable and named devices come before unattributed rows
        let segs = Aggregations.daySegments(
            intervals: [iv(1, 9, 10, nil), iv(2, 11, 12, "b")], day: day, calendar: cal)
        check(Aggregations.orderedDevices(segs) == ["b", nil],
              "unattributed rows sort last so named devices keep the top lanes")
    }

    do { // the reported bug: a device's row must not move when an EARLIER block syncs in later.
        // Order used to follow first appearance, so whichever device had the earliest known block
        // took the top lane — and that changed as data arrived.
        let early = Aggregations.daySegments(intervals: [iv(1, 11, 12, "work")], day: day, calendar: cal)
        let laneOfWorkBefore = early.first { $0.deviceID == "work" }?.lane
        // now a peer's EARLIER block arrives
        let later = Aggregations.daySegments(
            intervals: [iv(1, 11, 12, "work"), iv(2, 8, 9, "personal")], day: day, calendar: cal)
        let laneOfWorkAfter = later.first { $0.deviceID == "work" }?.lane
        check(laneOfWorkBefore == 0, "precondition: sole device is on lane 0")
        check(laneOfWorkAfter == 1,
              "with two devices the order is by id (personal < work), not by who appeared first")
        // The point: the SAME inputs always give the same order, whatever order they arrive in.
        let shuffled = Aggregations.daySegments(
            intervals: [iv(2, 8, 9, "personal"), iv(1, 11, 12, "work")], day: day, calendar: cal)
        check(Aggregations.orderedDevices(later) == Aggregations.orderedDevices(shuffled),
              "lane order doesn't depend on input order")
        check(Aggregations.orderedDevices(later) == ["personal", "work"],
              "and is a fixed, predictable sequence rather than arrival-dependent")
    }

    do { // note 21: the timeline and the device list must agree, so both take one explicit order
        let order = DeviceOrder.sorted([(id: "uuid-zzz", label: "Air"),
                                        (id: "uuid-aaa", label: "Studio")])
        check(order == ["uuid-zzz", "uuid-aaa"],
              "devices order by the label you see, not by the uuid you don't")

        let segs = Aggregations.daySegments(
            intervals: [iv(1, 9, 10, "uuid-aaa"), iv(2, 11, 12, "uuid-zzz")],
            day: day, calendar: cal, deviceOrder: order)
        check(Aggregations.orderedDevices(segs, deviceOrder: order) == ["uuid-zzz", "uuid-aaa"],
              "lanes follow that same order rather than sorting the ids for themselves")
        check(segs.first { $0.deviceID == "uuid-zzz" }?.lane == 0,
              "so Air is the top lane here, exactly as it's the top row of the device list")

        // A device with nothing today drops out without shifting the ones that remain.
        let thin = Aggregations.daySegments(intervals: [iv(1, 9, 10, "uuid-aaa")],
                                            day: day, calendar: cal, deviceOrder: order)
        check(Aggregations.orderedDevices(thin, deviceOrder: order) == ["uuid-aaa"],
              "an idle device contributes no lane rather than an empty one")

        // Unlabelled devices still land somewhere predictable, after everything ranked.
        let withStray = Aggregations.daySegments(
            intervals: [iv(1, 9, 10, "uuid-aaa"), iv(2, 11, 12, "stray")],
            day: day, calendar: cal, deviceOrder: order)
        check(Aggregations.orderedDevices(withStray, deviceOrder: order) == ["uuid-aaa", "stray"],
              "a device the caller didn't rank sorts after the ones it did")

        check(DeviceOrder.key(id: "b", label: "  ") == ("b", "b"),
              "a blank label is no label, not a name that sorts before every real one")
        check(DeviceOrder.sorted([(id: "b", label: "Mac"), (id: "a", label: "Mac")]) == ["a", "b"],
              "two devices sharing a name can't swap places — the id breaks the tie")
    }
}

// MARK: - Feedback platform tag

func testFeedbackPlatform() {
    print("Feedback platform tag:")
    do {
        let (store, url) = try! makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let mac = try! store.addFeedback("grip doesn't drag", platform: .macOS)!
        let untagged = try! store.addFeedback("no idea whose problem this is")!

        var notes = try! store.listFeedback()
        check(notes.first { $0.id == mac }?.platform == .macOS, "the tag is stored with the note")
        check(notes.first { $0.id == untagged }?.platform == nil,
              "and stays absent rather than being guessed from the device that wrote it")

        // Retagging is its own call: the pill is clicked with no text edit to commit.
        try! store.setFeedbackPlatform(id: mac, .both)
        notes = try! store.listFeedback()
        check(notes.first { $0.id == mac }?.platform == .both, "retagging a note sticks")
        try! store.setFeedbackPlatform(id: mac, nil)
        check(try! store.listFeedback().first { $0.id == mac }?.platform == nil,
              "clicking the selected pill again clears the tag")
        try! store.setFeedbackPlatform(id: mac, .iOS)

        // The tag has to travel, or tagging on the phone is invisible on the Mac.
        let exported = try! store.feedbackForExport()
        check(exported.first { $0.text == "grip doesn't drag" }?.platform == "ios",
              "the tag is exported for sync")

        do {
            let (peer, purl) = try! makeStore()
            defer { try? FileManager.default.removeItem(at: purl) }
            for row in exported {
                _ = try! peer.applyRemoteFeedback(uid: row.uid, text: row.text,
                                                  deviceID: row.deviceID,
                                                  createdAt: row.createdAt,
                                                  resolvedAt: row.resolvedAt,
                                                  remoteUpdatedAt: row.updatedAt,
                                                  platform: row.platform)
            }
            let arrived = try! peer.listFeedback()
            check(arrived.first { $0.text == "grip doesn't drag" }?.platform == .iOS,
                  "and arrives on the peer, not just the text")

            // A later retag on one device wins on the other, like any other edit.
            let id = arrived.first { $0.text == "grip doesn't drag" }!.id
            let uid = exported.first { $0.text == "grip doesn't drag" }!.uid
            _ = try! peer.applyRemoteFeedback(uid: uid, text: "grip doesn't drag",
                                              deviceID: nil, createdAt: 0, resolvedAt: nil,
                                              remoteUpdatedAt: Date().timeIntervalSince1970 + 60,
                                              platform: "both")
            check(try! peer.listFeedback().first { $0.id == id }?.platform == .both,
                  "a newer retag from a peer replaces the older tag")
        }
    }
}

// MARK: - Feedback attachments

func testFeedbackAttachments() {
    print("Feedback attachments:")
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])   // not a real PNG; only the bytes matter
    do {
        let (store, url) = try! makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let note = try! store.addFeedback("this bit is wrong", platform: .macOS)!
        let shot = try! store.addAttachment(toFeedback: note, png: png)!

        check(shot.hasLocalFile, "the bytes are written before the row that names them")
        check(FileManager.default.contents(atPath: store.fileURL(forAttachment: shot.uid).path) == png,
              "and they're the bytes that were handed in")
        check(store.attachmentsDirectory.deletingLastPathComponent().path
                == url.deletingLastPathComponent().path,
              "images sit beside their own database, so a test store can't write to the real folder")
        check(store.attachmentsDirectory.lastPathComponent
                .hasPrefix(url.deletingPathExtension().lastPathComponent),
              "and the folder is named after the database, so two in one directory can't collide")

        let uid = try! store.feedbackUID(id: note)!
        check(try! store.attachmentsByFeedbackUID()[uid]?.count == 1,
              "an image is found by the note's uid, which is what survives a trip between devices")

        // The manifest travels; the bytes don't.
        let manifest = try! store.attachmentsForExport()
        check(manifest.count == 1 && manifest[0].feedbackUID == uid,
              "the manifest row references the note by uid, not by row id")
        check(try! store.attachmentsNeedingUpload().map(\.uid) == [shot.uid],
              "a freshly pasted image is queued for upload")
        try! store.markAttachmentUploaded(uid: shot.uid)
        check(try! store.attachmentsNeedingUpload().isEmpty,
              "and isn't uploaded twice — a screenshot is immutable, so once is enough")

        do {   // a peer gets the row first and the bytes later
            let (peer, purl) = try! makeStore()
            defer { try? FileManager.default.removeItem(at: purl) }
            let noteRows = try! store.feedbackForExport()
            for row in noteRows {
                _ = try! peer.applyRemoteFeedback(uid: row.uid, text: row.text,
                                                  deviceID: row.deviceID, createdAt: row.createdAt,
                                                  resolvedAt: row.resolvedAt,
                                                  remoteUpdatedAt: row.updatedAt,
                                                  platform: row.platform)
            }
            for m in manifest {
                check(try! peer.applyRemoteAttachment(uid: m.uid, feedbackUID: m.feedbackUID,
                                                      filename: m.filename, byteSize: m.byteSize,
                                                      createdAt: m.createdAt,
                                                      remoteUpdatedAt: m.updatedAt),
                      "the manifest row applies on the peer")
                check(!(try! peer.applyRemoteAttachment(uid: m.uid, feedbackUID: m.feedbackUID,
                                                        filename: m.filename, byteSize: m.byteSize,
                                                        createdAt: m.createdAt,
                                                        remoteUpdatedAt: m.updatedAt)),
                      "and applying it twice is a no-op — there's no field to overwrite")
            }
            let waiting = try! peer.attachmentsMissingBytes()
            check(waiting.map(\.uid) == [shot.uid],
                  "the peer knows an image exists before it has the bytes")
            check(try! peer.attachmentsNeedingUpload().isEmpty,
                  "and doesn't offer to upload an image it hasn't got")

            try! peer.storeAttachmentBytes(uid: shot.uid, png: png)
            check(try! peer.attachmentsMissingBytes().isEmpty,
                  "once the blob arrives the peer stops asking for it")

            // Deleting the note over there takes the picture with it, file included.
            let noteUID = manifest[0].feedbackUID
            try! peer.applyRemoteTombstone(uid: noteUID, kind: "feedback",
                                           deletedAt: Date().timeIntervalSince1970)
            check(try! peer.attachmentsForExport().isEmpty,
                  "a remote note delete cascades to its images rather than orphaning the manifest")
            check(!FileManager.default.fileExists(
                    atPath: peer.fileURL(forAttachment: shot.uid).path),
                  "and removes the file too, which no foreign key could have done for us")
        }

        // Locally, deleting the note does the same and tombstones each image.
        try! store.deleteFeedback(id: note)
        check(try! store.attachmentsForExport().isEmpty, "a local note delete clears its images")
        check(!FileManager.default.fileExists(atPath: store.fileURL(forAttachment: shot.uid).path),
              "including the file on disk")
        check(try! store.tombstoneRecords().contains { $0.uid == shot.uid
                                                    && $0.kind == "feedback_attachment" },
              "each image is tombstoned, or a peer would sync it straight back")
    }
}

// MARK: - Paused presence

func testPausedPresence() {
    print("Paused presence:")

    let t0 = date(2026, 8, 1, 9, 0)
    check(RunningMarker(deviceID: "a", taskUID: "t", since: 0).claimsTimer,
          "a marker with no flag is treated as running (older builds only published those)")
    check(!RunningMarker(deviceID: "a", taskUID: "t", since: 0, isRunning: false).claimsTimer,
          "a paused marker is presence, not a timer claim")

    // A paused remote marker must NOT stop the local timer.
    let paused = RunningMarker(deviceID: "b", taskUID: "t", since: t0.addingTimeInterval(60).timeIntervalSince1970,
                              isRunning: false)
    check(TakeoverPolicy.decide(localRunningSince: t0, markers: [paused]) == nil,
          "a paused device never takes over a running one")

    // A running one still does.
    let running = RunningMarker(deviceID: "b", taskUID: "t", since: t0.addingTimeInterval(60).timeIntervalSince1970,
                               isRunning: true)
    check(TakeoverPolicy.decide(localRunningSince: t0, markers: [running]) != nil,
          "a later running device still takes over")

    // A paused marker alongside a running one doesn't shadow it.
    check(TakeoverPolicy.decide(localRunningSince: t0, markers: [paused, running]) != nil,
          "a paused marker doesn't mask a real claim")
}

// MARK: - Task name reuse

func testTaskNameReuse() throws {
    print("Task name reuse:")

    do { // same name in the same group reuses, case-insensitively
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "outsideworld", colorHex: "#fff")
        let b = try store.createProject(name: "OutsideWorld", colorHex: "#000")
        check(a == b, "re-adding a name reuses the task instead of forking its history")
        check(try store.listProjects(includeArchived: true).count == 1, "no twin row is created")
    }

    do { // the same name in DIFFERENT groups is two different tasks
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let work = try store.upsertTaskProject(name: "work", colorHex: "#fff")
        let home = try store.upsertTaskProject(name: "home", colorHex: "#000")
        let a = try store.createProject(name: "review", colorHex: "#fff", inGroup: work)
        try store.setTaskProject(taskID: a, taskProjectID: work)
        let b = try store.createProject(name: "review", colorHex: "#fff", inGroup: home)
        check(a != b, "the same name under two projects stays two distinct tasks")
    }

    do { // Inbox only matches Inbox
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let g = try store.upsertTaskProject(name: "work", colorHex: "#fff")
        let grouped = try store.createProject(name: "review", colorHex: "#fff", inGroup: g)
        try store.setTaskProject(taskID: grouped, taskProjectID: g)
        let inbox = try store.createProject(name: "review", colorHex: "#fff")
        check(grouped != inbox, "a grouped task isn't reused by an Inbox add")
    }

    do { // re-adding a FINISHED task reopens it rather than forking
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "dentist", colorHex: "#fff")
        try store.setProjectFinished(id: a, finished: true)
        let b = try store.createProject(name: "dentist", colorHex: "#fff")
        check(a == b, "a finished task is reused, not duplicated")
        let reopened = try store.listProjects(includeArchived: true).first { $0.id == a }
        check(reopened?.finished == false, "reusing a finished task reopens it")
    }

    do { // an ARCHIVED task is left alone — archiving means "out of the way"
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "old", colorHex: "#fff")
        try store.setProjectArchived(id: a, archived: true)
        let b = try store.createProject(name: "old", colorHex: "#fff")
        check(a != b, "an archived task is not silently resurrected")
    }

    do { // reuse keeps the interval history attached to one task
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.createProject(name: "t", colorHex: "#fff")
        try store.insertClosedInterval(projectID: a, start: date(2026, 8, 1, 9, 0),
                                       end: date(2026, 8, 1, 10, 0))
        let b = try store.createProject(name: "t", colorHex: "#fff")
        try store.insertClosedInterval(projectID: b, start: date(2026, 8, 2, 9, 0),
                                       end: date(2026, 8, 2, 10, 0))
        check(try store.intervals().allSatisfy { $0.projectID == a },
              "both sessions land on one task, so totals aren't split across twins")
    }
}

// MARK: - Deleting one session

func testDeleteInterval() throws {
    print("Delete session:")

    do { // deletes the row, leaves the task and the other intervals alone
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let t = try store.createProject(name: "t", colorHex: "#fff")
        try store.insertClosedInterval(projectID: t, start: date(2026, 8, 1, 9, 0),
                                       end: date(2026, 8, 1, 10, 0))
        try store.insertClosedInterval(projectID: t, start: date(2026, 8, 1, 11, 0),
                                       end: date(2026, 8, 1, 12, 0))
        let victim = try store.intervals().first { $0.start == date(2026, 8, 1, 9, 0) }!
        check(try store.deleteInterval(id: victim.id), "deleting an existing session succeeds")
        let left = try store.intervals()
        check(left.count == 1 && left[0].start == date(2026, 8, 1, 11, 0),
              "only that session goes; the other survives")
        check(try store.listProjects(includeArchived: true).count == 1, "the task itself stays")
    }

    do { // a tombstone is written, else the peer's log re-adds it on the next sync
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let t = try store.createProject(name: "t", colorHex: "#fff")
        try store.insertClosedInterval(projectID: t, start: date(2026, 8, 1, 9, 0),
                                       end: date(2026, 8, 1, 10, 0))
        let iv = try store.intervals()[0]
        let uid = try store.uid(table: "intervals", id: iv.id)!
        try store.deleteInterval(id: iv.id)
        check(try store.tombstoneUIDs().contains(uid), "the delete leaves a tombstone")
    }

    do { // and the delete survives a merge from the device that still has the row
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        let ta = try a.createProject(name: "shared", colorHex: "#fff")
        try a.insertClosedInterval(projectID: ta, start: date(2026, 8, 1, 9, 0),
                                   end: date(2026, 8, 1, 10, 0))
        let ea = SyncEngine(store: a, deviceID: "A")
        let eb = SyncEngine(store: b, deviceID: "B")
        _ = try eb.merge(try ea.buildPayload())
        check(try b.intervals().count == 1, "precondition: B has the interval")

        try b.deleteInterval(id: try b.intervals()[0].id)
        _ = try eb.merge(try ea.buildPayload())   // A still has it and re-sends
        check(try b.intervals().isEmpty, "a deleted session doesn't come back on the next sync")
    }

    do { // the RUNNING interval is refused — the timer would tick against a missing row
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let t = try store.createProject(name: "t", colorHex: "#fff")
        try store.switchTo(projectID: t, at: date(2026, 8, 1, 9, 0))
        let running = try store.openInterval()!
        check(try store.deleteInterval(id: running.id) == false,
              "the running session can't be deleted out from under the timer")
        check(try store.openInterval() != nil, "the timer is still running")
    }

    do { // a missing id is a no-op, not a crash or a stray tombstone
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        check(try store.deleteInterval(id: 9_999) == false, "deleting a missing session is a no-op")
        check(try store.tombstoneUIDs().isEmpty, "and writes no tombstone")
    }
}

// MARK: - Marker liveness

func testMarkerLiveness() {
    print("Marker liveness:")

    let t0 = date(2026, 8, 1, 9, 0)
    let cutoff = TakeoverPolicy.livenessCutoff

    func marker(since: Date, writtenAt: Date?, running: Bool = true) -> RunningMarker {
        RunningMarker(deviceID: "b", taskUID: "t", since: since.timeIntervalSince1970,
                      isRunning: running, writtenAt: writtenAt?.timeIntervalSince1970)
    }

    do { // the bug: an abandoned claim starts LATER than our timer, so it used to win forever
        let now = t0.addingTimeInterval(3 * 3600)
        let abandoned = marker(since: t0.addingTimeInterval(60),
                               writtenAt: t0.addingTimeInterval(120))   // last refreshed hours ago
        check(TakeoverPolicy.decide(localRunningSince: t0.addingTimeInterval(2 * 3600),
                                    markers: [abandoned], now: now) == nil,
              "a stale claim no longer pauses a timer started after it")
    }

    do { // a device refreshing normally still takes over
        let now = t0.addingTimeInterval(600)
        let live = marker(since: t0.addingTimeInterval(300), writtenAt: now.addingTimeInterval(-20))
        check(TakeoverPolicy.decide(localRunningSince: t0, markers: [live], now: now) != nil,
              "a freshly-refreshed claim still takes over")
    }

    do { // right at the boundary: just inside is live, just outside is dead
        let now = t0.addingTimeInterval(3600)
        let justLive = marker(since: t0.addingTimeInterval(60), writtenAt: now.addingTimeInterval(-cutoff + 5))
        let justDead = marker(since: t0.addingTimeInterval(60), writtenAt: now.addingTimeInterval(-cutoff - 5))
        check(TakeoverPolicy.decide(localRunningSince: t0, markers: [justLive], now: now) != nil,
              "a claim just inside the cutoff is honoured")
        check(TakeoverPolicy.decide(localRunningSince: t0, markers: [justDead], now: now) == nil,
              "a claim just outside the cutoff is ignored")
    }

    do { // an older build sends no heartbeat: treat as live, since assuming dead would let two
        // timers run at once and double-count
        let now = t0.addingTimeInterval(3600)
        let legacy = marker(since: t0.addingTimeInterval(60), writtenAt: nil)
        check(legacy.isFresh(now: now, cutoff: cutoff), "a marker with no heartbeat counts as live")
        check(TakeoverPolicy.decide(localRunningSince: t0, markers: [legacy], now: now) != nil,
              "so an older build can still take over")
    }

    do { // the transport's timestamp WINS over the marker's self-report (one clock, not N)
        let now = t0.addingTimeInterval(3600)
        // Marker claims it was just written, but Drive says the file is hours old — trust Drive.
        let lying = marker(since: t0.addingTimeInterval(60), writtenAt: now.addingTimeInterval(-1))
        check(!lying.isFresh(now: now, cutoff: cutoff, observedAt: t0),
              "the transport timestamp overrides a marker that misreports its own freshness")
        check(TakeoverPolicy.decide(localRunningSince: t0, markers: [lying], now: now,
                                    observedAt: ["b": t0]) == nil,
              "and the takeover is skipped on that basis")
    }

    do { // a clock AHEAD of ours must not read as stale
        let now = t0.addingTimeInterval(600)
        let ahead = marker(since: t0.addingTimeInterval(60), writtenAt: now.addingTimeInterval(120))
        check(ahead.isFresh(now: now, cutoff: cutoff),
              "a future timestamp means the peer's clock is ahead, not that it's dead")
    }

    do { // staleness doesn't resurrect a paused marker into a claim
        let now = t0.addingTimeInterval(600)
        let paused = marker(since: t0.addingTimeInterval(60), writtenAt: now, running: false)
        check(TakeoverPolicy.decide(localRunningSince: t0, markers: [paused], now: now) == nil,
              "a fresh paused marker is still not a claim")
    }
}

// MARK: - Deleting a group across devices

func testRemoteGroupDelete() throws {
    print("Remote group delete:")

    do { // A deletes a group; B still has a task in it. B must not hit a FOREIGN KEY error.
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        let ea = SyncEngine(store: a, deviceID: "A")
        let eb = SyncEngine(store: b, deviceID: "B")

        // Both know one group with one task in it.
        let g = try a.upsertTaskProject(name: "work", colorHex: "#aaaaaa")
        let t = try a.createProject(name: "profiling", colorHex: "#fff")
        try a.setTaskProject(taskID: t, taskProjectID: g)
        _ = try eb.merge(try ea.buildPayload())
        let bTask = try b.listProjects(includeArchived: true).first { $0.name == "profiling" }
        check(bTask?.taskProjectID != nil, "precondition: B has the task inside the group")

        // A deletes the group (its task falls back to Inbox there).
        try a.deleteTaskProject(id: g)

        // B merges the tombstone. This is where SQLITE_CONSTRAINT (19) fired: B's task still
        // referenced the group, and the DELETE had nothing clearing the reference first.
        _ = try eb.merge(try ea.buildPayload())

        let after = try b.listProjects(includeArchived: true).first { $0.name == "profiling" }
        check(after != nil, "the task survives — deleting a grouping must not delete tracked time")
        check(after?.taskProjectID == nil, "and falls back to Inbox, matching a local delete")
        check(try b.listTaskProjects().isEmpty, "the group itself is gone on B")
    }

    do { // the task's INTERVALS survive too — a group delete must never lose time
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        let ea = SyncEngine(store: a, deviceID: "A")
        let eb = SyncEngine(store: b, deviceID: "B")
        let g = try a.upsertTaskProject(name: "work", colorHex: "#aaaaaa")
        let t = try a.createProject(name: "profiling", colorHex: "#fff")
        try a.setTaskProject(taskID: t, taskProjectID: g)
        try a.insertClosedInterval(projectID: t, start: date(2026, 8, 1, 9, 0),
                                   end: date(2026, 8, 1, 10, 0))
        _ = try eb.merge(try ea.buildPayload())
        try a.deleteTaskProject(id: g)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.intervals().count == 1, "the tracked hour is still there after the group went")
    }

    do { // the tombstone itself only touches tasks pointing AT the deleted group.
        // Applied directly, isolated from the task-edit LWW that also runs during a full merge.
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        let doomed = try b.upsertTaskProject(name: "work", colorHex: "#aaaaaa")
        let keep = try b.upsertTaskProject(name: "home", colorHex: "#bbbbbb")
        let inDoomed = try b.createProject(name: "profiling", colorHex: "#fff")
        let inKeep = try b.createProject(name: "errands", colorHex: "#fff")
        try b.setTaskProject(taskID: inDoomed, taskProjectID: doomed)
        try b.setTaskProject(taskID: inKeep, taskProjectID: keep)
        let doomedUID = try b.uid(table: "task_projects", id: doomed)!

        try b.applyRemoteTombstone(uid: doomedUID, kind: "task_project",
                                   deletedAt: Date().timeIntervalSince1970)
        let all = try b.listProjects(includeArchived: true)
        check(all.first { $0.id == inDoomed }?.taskProjectID == nil,
              "a task in the deleted group falls back to Inbox")
        check(all.first { $0.id == inKeep }?.taskProjectID == keep,
              "a task in a DIFFERENT group is untouched by the tombstone")
    }

    do { // LWW still governs the assignment: a move made AFTER the delete survives the merge.
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        let ea = SyncEngine(store: a, deviceID: "A")
        let eb = SyncEngine(store: b, deviceID: "B")
        let doomed = try a.upsertTaskProject(name: "work", colorHex: "#aaaaaa")
        let t = try a.createProject(name: "profiling", colorHex: "#fff")
        try a.setTaskProject(taskID: t, taskProjectID: doomed)
        _ = try eb.merge(try ea.buildPayload())

        // Delete on A happens FIRST; B then deliberately files the task somewhere else.
        try a.deleteTaskProject(id: doomed)
        let keep = try b.upsertTaskProject(name: "home", colorHex: "#bbbbbb")
        let bTaskID = try b.listProjects(includeArchived: true).first { $0.name == "profiling" }!.id
        try b.setTaskProject(taskID: bTaskID, taskProjectID: keep)

        _ = try eb.merge(try ea.buildPayload())
        let after = try b.listProjects(includeArchived: true).first { $0.name == "profiling" }
        check(after?.taskProjectID == keep,
              "the newer local move wins over the older remote clear")
        check(try b.listTaskProjects().map(\.name) == ["home"],
              "and the deleted group is still gone")
    }
}

// MARK: - Duplicate Drive files

func testDuplicateFileCollapse() {
    print("Duplicate Drive files:")

    func f(_ name: String, _ minutesAgo: Int?) -> DriveAPI.RemoteFile {
        DriveAPI.RemoteFile(id: "\(name)-\(minutesAgo ?? -1)", name: name,
                            modifiedTime: minutesAgo.map { date(2026, 8, 1, 9, 0).addingTimeInterval(Double($0) * 60) })
    }

    do { // the reported bug: one device, many payload copies -> ONE entry
        let dupes = (0..<15).map { f("device-personal.json", $0) }
        let kept = DriveAPI.newestPerName(dupes)
        check(kept.count == 1, "fifteen copies of one file collapse to a single entry")
        check(kept[0].id == "device-personal.json-14", "and the newest copy is the one kept")
    }

    do { // distinct devices are untouched
        let files = [f("device-work.json", 1), f("device-personal.json", 2)]
        check(DriveAPI.newestPerName(files).count == 2, "different devices both survive")
    }

    do { // a missing modifiedTime never beats a real one
        let kept = DriveAPI.newestPerName([f("a.json", nil), f("a.json", 5), f("a.json", nil)])
        check(kept.count == 1 && kept[0].id == "a.json-5",
              "a file with no timestamp loses to one that has it")
    }

    do { // all timestamps missing: still collapses rather than duplicating
        check(DriveAPI.newestPerName([f("a.json", nil), f("a.json", nil)]).count == 1,
              "duplicates with no timestamps still collapse to one")
    }

    do { // stable order regardless of input order
        let a = DriveAPI.newestPerName([f("b.json", 1), f("a.json", 1)]).map(\.name)
        let b = DriveAPI.newestPerName([f("a.json", 1), f("b.json", 1)]).map(\.name)
        check(a == b && a == ["a.json", "b.json"], "output order is stable")
    }
}

// MARK: - Tags

func testTags() throws {
    print("Tags:")

    do { // reuse by name, case-insensitively — two "office" tags would split their totals
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let a = try store.upsertTag(name: "office", colorHex: "#fff")
        let b = try store.upsertTag(name: "Office", colorHex: "#000")
        check(a == b, "re-adding a tag name reuses it instead of forking")
        check(try store.listTags().count == 1, "no duplicate tag row")
    }

    do { // linking is idempotent
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let t = try store.upsertTag(name: "office", colorHex: "#fff")
        let g = try store.upsertTaskProject(name: "profiling", colorHex: "#fff")
        try store.addTag(t, to: .project(g))
        try store.addTag(t, to: .project(g))
        check(try store.tagIDs(for: .project(g)) == [t], "tagging twice leaves one link")
        try store.removeTag(t, from: .project(g))
        check(try store.tagIDs(for: .project(g)).isEmpty, "untagging removes it")
    }

    do { // a task INHERITS its project's tags, and can carry its own on top
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let office = try store.upsertTag(name: "office", colorHex: "#fff")
        let side = try store.upsertTag(name: "side", colorHex: "#fff")
        let g = try store.upsertTaskProject(name: "profiling", colorHex: "#fff")
        let task = try store.createProject(name: "optimal params", colorHex: "#fff")
        try store.setTaskProject(taskID: task, taskProjectID: g)
        try store.addTag(office, to: .project(g))
        try store.addTag(side, to: .task(task))
        let eff = try store.effectiveTagIDsByTask()
        check(eff[task] == Set([office, side]),
              "a task gets its project's tags plus its own")
    }

    do { // deleting a tag takes its links and targets with it (FKs are ON)
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let t = try store.upsertTag(name: "office", colorHex: "#fff")
        let g = try store.upsertTaskProject(name: "profiling", colorHex: "#fff")
        try store.addTag(t, to: .project(g))
        try store.setTarget(subject: .tag(t), seconds: 3600, direction: .atLeast, period: .week)
        try store.deleteTag(id: t)
        check(try store.listTags().isEmpty, "the tag is gone")
        check(try store.tagIDs(for: .project(g)).isEmpty, "its links are gone")
        check(try store.listTargets().isEmpty, "and any target pointing at it")
    }

    do { // deleting a PROJECT takes its tag links and target with it, so no orphan is left
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let tag = try store.upsertTag(name: "office", colorHex: "#fff")
        let g = try store.upsertTaskProject(name: "profiling", colorHex: "#fff")
        try store.addTag(tag, to: .project(g))
        try store.setTarget(subject: .project(g), seconds: 3600, direction: .atLeast, period: .week)
        try store.deleteTaskProject(id: g)
        check(try store.listTargets().isEmpty,
              "a deleted project leaves no orphan target (which would silently vanish from the UI)")
        check(try store.tagIDs(for: .project(g)).isEmpty, "and no dangling tag link")
        check(try store.listTags().count == 1, "but the tag itself survives — other projects use it")
    }

    do { // same for a TASK
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let tag = try store.upsertTag(name: "side", colorHex: "#fff")
        let t = try store.createProject(name: "timeslicer", colorHex: "#fff")
        try store.addTag(tag, to: .task(t))
        try store.setTarget(subject: .task(t), seconds: 3600, direction: .atMost, period: .week)
        try store.deleteProject(id: t)
        check(try store.listTargets().isEmpty, "a deleted task leaves no orphan target")
        check(try store.tagIDs(for: .task(t)).isEmpty, "and no dangling tag link")
    }

    do { // one target per subject+period; setting it again edits rather than duplicates
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let g = try store.upsertTaskProject(name: "profiling", colorHex: "#fff")
        try store.setTarget(subject: .project(g), seconds: 3600, direction: .atLeast, period: .week)
        try store.setTarget(subject: .project(g), seconds: 7200, direction: .atMost, period: .week)
        let targets = try store.listTargets()
        check(targets.count == 1, "the same subject+period stays one target")
        check(targets[0].seconds == 7200 && targets[0].direction == .atMost, "and is updated in place")
        // Changing the PERIOD moves the same target rather than adding a second. Keying identity on
        // the period is what let one subject end up with two contradictory budgets, the second of
        // them unreachable from the editor.
        try store.setTarget(subject: .project(g), seconds: 60, direction: .atLeast, period: .day)
        let after = try store.listTargets()
        check(after.count == 1, "changing the period edits the target instead of duplicating it")
        check(after[0].period == .day && after[0].seconds == 60, "and carries the new values")
    }
}

// MARK: - Tag totals

func testTagTotals() {
    print("Tag totals:")

    let day = date(2026, 8, 1, 0, 0)
    let range = DateRange(unit: .day, start: day, end: day.addingTimeInterval(86_400))
    let office = Tag(id: 1, name: "office", colorHex: "#fff", sortOrder: 0)
    let side = Tag(id: 2, name: "side", colorHex: "#fff", sortOrder: 1)
    func iv(_ id: Int64, _ task: Int64, _ h1: Int, _ h2: Int) -> Interval {
        Interval(id: id, projectID: task, start: date(2026, 8, 1, h1, 0),
                 end: date(2026, 8, 1, h2, 0))
    }

    do { // a task carrying two tags contributes to BOTH, so totals exceed tracked time
        let totals = Aggregations.tagTotals(
            tags: [office, side], intervals: [iv(1, 10, 9, 11)],
            tagIDsByTask: [10: [1, 2]], range: range)
        check(totals.count == 2, "both tags appear")
        check(totals.allSatisfy { approx($0.seconds / 3600, 2) },
              "each tag counts the full 2h — overlap means totals don't partition the day")
    }

    do { // UNION within a tag: two overlapping intervals under one tag count once
        let totals = Aggregations.tagTotals(
            tags: [office], intervals: [iv(1, 10, 9, 11), iv(2, 11, 10, 12)],
            tagIDsByTask: [10: [1], 11: [1]], range: range)
        check(totals.count == 1 && approx(totals[0].seconds / 3600, 3),
              "9-11 plus 10-12 under one tag is 3h, not 4h")
    }

    do { // untagged time is its own bucket, and zero-time tags are dropped
        let totals = Aggregations.tagTotals(
            tags: [office, side], intervals: [iv(1, 99, 9, 10)],
            tagIDsByTask: [:], range: range)
        check(totals.count == 1 && totals[0].tag == nil, "only the untagged row appears")
        check(approx(totals[0].seconds / 60, 60), "with the right time")
    }

    do { // intervals are clipped to the range
        let totals = Aggregations.tagTotals(
            tags: [office],
            intervals: [Interval(id: 1, projectID: 10, start: date(2026, 7, 31, 23, 0),
                                 end: date(2026, 8, 1, 1, 0))],
            tagIDsByTask: [10: [1]], range: range)
        check(approx(totals[0].seconds / 3600, 1), "only the in-range hour counts")
    }

    do { // subject resolution: task, project and tag all reduce to the right seconds
        let tasks = [Project(id: 10, name: "a", colorHex: "#fff", sortOrder: 0, archived: false,
                             finished: false, finishedAt: nil, taskProjectID: 7),
                     Project(id: 11, name: "b", colorHex: "#fff", sortOrder: 1, archived: false,
                             finished: false, finishedAt: nil, taskProjectID: 7)]
        let ivs = [iv(1, 10, 9, 10), iv(2, 11, 11, 12)]
        let byTask: [Int64: Set<Int64>] = [10: [1], 11: [1]]
        check(approx(Aggregations.secondsForSubject(.task(10), intervals: ivs, tasks: tasks,
                                                   tagIDsByTask: byTask, range: range) / 3600, 1),
              "a task subject counts only that task")
        check(approx(Aggregations.secondsForSubject(.project(7), intervals: ivs, tasks: tasks,
                                                   tagIDsByTask: byTask, range: range) / 3600, 2),
              "a project subject covers every task in it")
        check(approx(Aggregations.secondsForSubject(.tag(1), intervals: ivs, tasks: tasks,
                                                   tagIDsByTask: byTask, range: range) / 3600, 2),
              "a tag subject fans out to every task carrying it")
        check(Aggregations.secondsForSubject(.tag(99), intervals: ivs, tasks: tasks,
                                            tagIDsByTask: byTask, range: range) == 0,
              "an unused subject is zero, not a crash")
    }
}

// MARK: - Target maths

func testTargetMath() {
    print("Target maths:")

    let weekStart = date(2026, 8, 24, 0, 0)
    let weekEnd = date(2026, 8, 31, 0, 0)
    func weekly(_ hours: Double, _ dir: Target.Direction) -> Target {
        Target(id: 1, subject: .tag(1), seconds: hours * 3600, direction: dir, period: .week)
    }

    do { // a floor mid-week: reached => met, on track => onPace, behind => behind
        let midweek = date(2026, 8, 27, 0, 0)          // 3 of 7 days elapsed
        let t = weekly(30, .atLeast)
        let met = TargetMath.progress(target: t, name: "office", actualSeconds: 31 * 3600,
                                     rangeStart: weekStart, rangeEnd: weekEnd, now: midweek)
        check(met.verdict == .met, "a floor already reached is met")
        let onPace = TargetMath.progress(target: t, name: "office", actualSeconds: 14 * 3600,
                                        rangeStart: weekStart, rangeEnd: weekEnd, now: midweek)
        check(onPace.verdict == .onPace,
              "14h of 30h on day 3 of 7 is on pace, not a failure")
        let behind = TargetMath.progress(target: t, name: "office", actualSeconds: 2 * 3600,
                                        rangeStart: weekStart, rangeEnd: weekEnd, now: midweek)
        check(behind.verdict == .behind, "2h by day 3 is behind")
    }

    do { // a ceiling is judged against the WHOLE allowance, not the elapsed part
        let monday = date(2026, 8, 25, 0, 0)
        let t = weekly(5, .atMost)
        let used = TargetMath.progress(target: t, name: "side", actualSeconds: 4.5 * 3600,
                                      rangeStart: weekStart, rangeEnd: weekEnd, now: monday)
        check(used.verdict == .met,
              "spending most of the week's allowance early is not over budget")
        let over = TargetMath.progress(target: t, name: "side", actualSeconds: 6 * 3600,
                                      rangeStart: weekStart, rangeEnd: weekEnd, now: monday)
        check(over.verdict == .over, "exceeding it is over, whenever it happened")
    }

    do { // percentages, including above 100 for a breached ceiling
        let t = weekly(30, .atLeast)
        let p = TargetMath.progress(target: t, name: "office", actualSeconds: 15 * 3600,
                                    rangeStart: weekStart, rangeEnd: weekEnd, now: weekEnd)
        check(approx(p.percent, 50, 0.01), "15h of 30h is 50%")
        check(approx(p.deltaSeconds / 3600, -15), "and 15h short")
        let c = weekly(5, .atMost)
        let q = TargetMath.progress(target: c, name: "side", actualSeconds: 6 * 3600,
                                    rangeStart: weekStart, rangeEnd: weekEnd, now: weekEnd)
        check(approx(q.percent, 120, 0.01), "a breached ceiling reads over 100%")
    }

    do { // normalisation: a WEEKLY target viewed over a 30-day month expects ~4.3x
        let monthStart = date(2026, 8, 1, 0, 0)
        let monthEnd = date(2026, 8, 31, 0, 0)          // 30 days
        let p = TargetMath.progress(target: weekly(10, .atLeast), name: "office",
                                    actualSeconds: 0, rangeStart: monthStart, rangeEnd: monthEnd,
                                    now: monthEnd)
        check(approx(p.expectedSeconds / 3600, 10 * 30 / 7, 0.1),
              "a weekly target scales onto a month rather than vanishing")
    }

    do { // a fully-elapsed range can't be "on pace" — it's met or it isn't
        let p = TargetMath.progress(target: weekly(30, .atLeast), name: "office",
                                    actualSeconds: 29 * 3600, rangeStart: weekStart,
                                    rangeEnd: weekEnd, now: date(2026, 9, 5, 0, 0))
        check(p.elapsedFraction == 1, "a past range is fully elapsed")
        check(p.verdict == .behind, "missing a finished floor is behind, not on pace")
    }

    do { // a future range hasn't started, so nothing is behind yet
        let p = TargetMath.progress(target: weekly(30, .atLeast), name: "office",
                                    actualSeconds: 0, rangeStart: weekStart, rangeEnd: weekEnd,
                                    now: date(2026, 8, 1, 0, 0))
        check(p.elapsedFraction == 0, "a future range has not elapsed")
        check(p.verdict == .onPace, "and so isn't behind")
    }

    do { // per-day figures: average divides by days BEGUN, not days completed
        // weekStart is Mon Aug 24, so Fri Aug 28 midday is part-way through the 5th day.
        let friday = date(2026, 8, 28, 12, 0)
        let p = TargetMath.progress(target: weekly(40, .atLeast), name: "office",
                                    actualSeconds: 18 * 3600, rangeStart: weekStart,
                                    rangeEnd: weekEnd, now: friday, todaySeconds: 2 * 3600)
        check(p.daysElapsed == 5, "a part-elapsed day still counts as a day you had")
        check(approx(p.averagePerDaySeconds / 3600, 18.0 / 7, 0.02),
              "18h in the week averages 18/7 h/day, whatever day it is")
        check(approx(p.todaySeconds / 3600, 2), "today's figure is carried through")
        // 22h short with 2 of the 7 days left.
        check(approx((p.requiredPerDaySeconds ?? 0) / 3600, 11, 0.1),
              "the required pace spreads the shortfall over the days actually left")
    }

    do { // nothing required once the target is already met
        let p = TargetMath.progress(target: weekly(10, .atLeast), name: "office",
                                    actualSeconds: 12 * 3600, rangeStart: weekStart,
                                    rangeEnd: weekEnd, now: date(2026, 8, 26, 12, 0))
        check(p.requiredPerDaySeconds == nil, "a met floor needs no further pace")
    }

    do { // nor once the period is over — there are no days left to make it up in
        let p = TargetMath.progress(target: weekly(40, .atLeast), name: "office",
                                    actualSeconds: 1 * 3600, rangeStart: weekStart,
                                    rangeEnd: weekEnd, now: date(2026, 9, 10, 0, 0))
        check(p.requiredPerDaySeconds == nil, "a finished period has no remaining pace")
    }

    do { // the viewed-range bar PRO-RATES the target onto whatever range is showing
        let day = 1.0
        let p = TargetMath.progress(target: weekly(7, .atLeast), name: "recon paper",
                                    actualSeconds: 1.78 * 3600, rangeStart: weekStart,
                                    rangeEnd: weekEnd, now: weekEnd,
                                    rangeSeconds: 0, viewedRangeDays: day)
        check(approx(p.rangeExpectedSeconds / 3600, 1, 0.01),
              "a 7h weekly budget pro-rates to 1h over a single day")
        check(p.rangePercent == 0, "nothing tracked that day is 0% of it")
        check(approx(p.percent, 25, 0.5), "and the weekly goal percentage is untouched")
    }

    do { // over a month the same weekly budget scales UP
        let p = TargetMath.progress(target: weekly(40, .atLeast), name: "office",
                                    actualSeconds: 0, rangeStart: weekStart, rangeEnd: weekEnd,
                                    now: weekEnd, rangeSeconds: 98.8 * 3600,
                                    viewedRangeDays: 30)
        check(approx(p.rangeExpectedSeconds / 3600, 40 * 30 / 7, 0.1),
              "40h/week over 30 days expects ~171h")
        check(approx(p.rangePercent, 57.6, 0.5), "and reports progress against that")
    }

    do { // the average divides by the FULL period, so it doesn't drift as the week progresses
        let p = TargetMath.progress(target: weekly(40, .atLeast), name: "office",
                                    actualSeconds: 20 * 3600, rangeStart: weekStart,
                                    rangeEnd: weekEnd, now: weekEnd,
                                    rangeSeconds: 10 * 3600, viewedRangeDays: 5)
        check(approx(p.averagePerDaySeconds / 3600, 20.0 / 7, 0.02),
              "20h in a week averages 20/7 h/day — divided by all 7 days, not the 5 elapsed")
    }

    do { // a zero-length viewed range can't divide by zero
        let p = TargetMath.progress(target: weekly(40, .atLeast), name: "x", actualSeconds: 0,
                                    rangeStart: weekStart, rangeEnd: weekEnd,
                                    rangeSeconds: 0, viewedRangeDays: 0)
        check(p.rangeExpectedSeconds == 0 && p.rangePercent == 0, "inert, not NaN")
    }

    do { // the reported bug: a past range must report ITS period, not the current one
        let now = date(2026, 8, 28, 12, 0)                     // a Friday
        // Viewing the week two weeks earlier.
        let pastStart = date(2026, 8, 10, 0, 0), pastEnd = date(2026, 8, 17, 0, 0)
        let anchor = TargetMath.periodAnchor(rangeStart: pastStart, rangeEnd: pastEnd, now: now)
        check(anchor >= pastStart && anchor < pastEnd,
              "the anchor lands inside the range being viewed, not on today")
        // One second inside the end, not the end itself: rangeEnd is exclusive, so for a week it is
        // the FOLLOWING Sunday and would resolve to the wrong week.
        check(anchor == pastEnd.addingTimeInterval(-1), "and at the last instant of it")
    }

    do { // while you're on the current range the anchor stays `now`, so pace still means something
        let now = date(2026, 8, 26, 9, 0)
        let anchor = TargetMath.periodAnchor(rangeStart: date(2026, 8, 24, 0, 0),
                                            rangeEnd: date(2026, 8, 31, 0, 0), now: now)
        check(anchor == now, "an anchor inside the range is `now` itself")
    }

    do { // a future range hasn't started; anchor at its beginning rather than extrapolating
        let now = date(2026, 8, 1, 0, 0)
        let anchor = TargetMath.periodAnchor(rangeStart: date(2026, 9, 7, 0, 0),
                                            rangeEnd: date(2026, 9, 14, 0, 0), now: now)
        check(anchor == date(2026, 9, 7, 0, 0), "a future range anchors at its start")
    }

    do { // a past period reads as fully elapsed, so a missed floor is behind rather than "on pace"
        let p = TargetMath.progress(target: weekly(30, .atLeast), name: "office",
                                    actualSeconds: 5 * 3600,
                                    rangeStart: date(2026, 8, 10, 0, 0),
                                    rangeEnd: date(2026, 8, 17, 0, 0),
                                    now: date(2026, 8, 28, 12, 0))
        check(p.elapsedFraction == 1, "a finished week is fully elapsed")
        check(p.verdict == .behind, "and a floor it missed is behind, not still on pace")
    }

    do { // a zero-length range can't divide by zero
        let p = TargetMath.progress(target: weekly(30, .atLeast), name: "office",
                                    actualSeconds: 0, rangeStart: weekStart, rangeEnd: weekStart)
        check(p.expectedSeconds == 0 && p.percent == 0, "a zero range is inert, not NaN")
    }
}

// MARK: - Budget hours input

func testHoursInput() {
    print("Hours field input:")
    // Filtered as you type, so the field can never hold something commit would silently discard.
    let cases: [(String, String)] = [
        ("40", "40"),
        ("7.5", "7.5"),
        ("4.55", "4.5"),          // one decimal place only
        ("abc12x", "12"),         // letters dropped
        ("1.2.3", "1.2"),         // second dot dropped, and so is the digit after it — one
                                  // decimal place is the rule, so "1.23" would break it
        (".5", "5"),              // leading dot dropped — no bare ".5"
        (",5", "5"),              // comma keyboards: same rule
        ("1,5", "1.5"),           // comma becomes the decimal point
        ("", ""),
        ("...", ""),
    ]
    for (input, want) in cases {
        let got = NumericInput.hours(input)
        check(got == want, "hours(\"\(input)\") == \"\(want)\" (got \"\(got)\")")
    }
}

// MARK: - Tag / budget sync

func testTagSync() throws {
    print("Tag & budget sync:")

    func pair() throws -> (IntervalStore, URL, SyncEngine, IntervalStore, URL, SyncEngine) {
        let (a, ua) = try makeStore(); let (b, ub) = try makeStore()
        return (a, ua, SyncEngine(store: a, deviceID: "A"),
                b, ub, SyncEngine(store: b, deviceID: "B"))
    }

    do { // CREATE: a tag, its link and its budget all reach the other device
        let (a, ua, ea, b, ub, eb) = try pair()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let g = try a.upsertTaskProject(name: "profiling", colorHex: "#aaaaaa")
        let tag = try a.upsertTag(name: "office", colorHex: "#4E79A7")
        try a.addTag(tag, to: .project(g))
        try a.setTarget(subject: .tag(tag), seconds: 40 * 3600, direction: .atLeast, period: .week)

        _ = try eb.merge(try ea.buildPayload())

        let bTag = try b.tag(named: "office")
        check(bTag != nil, "the tag arrives")
        let bGroup = try b.taskProject(named: "profiling")!
        check(try b.tagIDs(for: .project(bGroup.id)) == [bTag!.id],
              "and so does the link, resolved to B's own project id")
        let bTargets = try b.listTargets()
        check(bTargets.count == 1, "and the budget")
        check(bTargets[0].subject == .tag(bTag!.id),
              "pointing at B's tag id, not A's — subjects travel as uids")
        check(bTargets[0].seconds == 40 * 3600 && bTargets[0].period == .week, "with its values")
    }

    do { // EDIT: renaming and re-budgeting propagate, newest wins
        let (a, ua, ea, b, ub, eb) = try pair()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let tag = try a.upsertTag(name: "office", colorHex: "#4E79A7")
        try a.setTarget(subject: .tag(tag), seconds: 10 * 3600, direction: .atLeast, period: .week)
        _ = try eb.merge(try ea.buildPayload())

        try a.renameTag(id: tag, name: "work")
        try a.setTarget(subject: .tag(tag), seconds: 25 * 3600, direction: .atMost, period: .month)
        _ = try eb.merge(try ea.buildPayload())

        check(try b.tag(named: "work") != nil, "a rename propagates")
        check(try b.tag(named: "office") == nil, "and doesn't leave the old name behind")
        let t = try b.listTargets()
        check(t.count == 1, "the budget is edited, not duplicated")
        check(t[0].seconds == 25 * 3600 && t[0].direction == .atMost && t[0].period == .month,
              "with every field carried")
    }

    do { // DELETE: a removed tag stays removed, even though the peer still has it
        let (a, ua, ea, b, ub, eb) = try pair()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let g = try a.upsertTaskProject(name: "profiling", colorHex: "#aaaaaa")
        let tag = try a.upsertTag(name: "office", colorHex: "#4E79A7")
        try a.addTag(tag, to: .project(g))
        try a.setTarget(subject: .tag(tag), seconds: 3600, direction: .atLeast, period: .week)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTags().count == 1, "precondition: B has it")

        try a.deleteTag(id: tag)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTags().isEmpty, "the delete propagates")
        check(try b.listTargets().isEmpty, "taking its budget with it")
        let bGroup = try b.taskProject(named: "profiling")!
        check(try b.tagIDs(for: .project(bGroup.id)).isEmpty, "and its links")

        // The peer re-sends its (stale) copy; the tombstone must hold.
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTags().isEmpty, "and holds against a re-send")
    }

    do { // DELETE of one link only — the tag itself survives
        let (a, ua, ea, b, ub, eb) = try pair()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let g = try a.upsertTaskProject(name: "profiling", colorHex: "#aaaaaa")
        let tag = try a.upsertTag(name: "office", colorHex: "#4E79A7")
        try a.addTag(tag, to: .project(g))
        _ = try eb.merge(try ea.buildPayload())
        try a.removeTag(tag, from: .project(g))
        _ = try eb.merge(try ea.buildPayload())
        let bGroup = try b.taskProject(named: "profiling")!
        check(try b.tagIDs(for: .project(bGroup.id)).isEmpty, "un-tagging propagates")
        check(try b.listTags().count == 1, "without deleting the tag")
    }

    do { // DELETE of a budget alone
        let (a, ua, ea, b, ub, eb) = try pair()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let tag = try a.upsertTag(name: "office", colorHex: "#4E79A7")
        try a.setTarget(subject: .tag(tag), seconds: 3600, direction: .atLeast, period: .week)
        _ = try eb.merge(try ea.buildPayload())
        try a.deleteTarget(id: try a.listTargets()[0].id)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTargets().isEmpty, "removing a budget propagates")
        check(try b.listTags().count == 1, "and leaves the tag alone")
    }

    do { // both devices invent the same tag name: converge on ONE, not two
        let (a, ua, ea, b, ub, eb) = try pair()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        _ = try a.upsertTag(name: "office", colorHex: "#111111")
        _ = try b.upsertTag(name: "Office", colorHex: "#999999")   // different case, different uid
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTags().count == 1, "same name means one tag, not a duplicate pair")
        _ = try ea.merge(try eb.buildPayload())
        check(try a.listTags().count == 1, "and the other direction agrees")
        let uidA = try a.uid(table: "tags", id: try a.listTags()[0].id)
        let uidB = try b.uid(table: "tags", id: try b.listTags()[0].id)
        check(uidA == uidB, "converging on one uid, so later renames match instead of forking")
    }

    do { // idempotent: merging the same payload twice changes nothing the second time
        let (a, ua, ea, b, ub, eb) = try pair()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let g = try a.upsertTaskProject(name: "profiling", colorHex: "#aaaaaa")
        let tag = try a.upsertTag(name: "office", colorHex: "#4E79A7")
        try a.addTag(tag, to: .project(g))
        try a.setTarget(subject: .tag(tag), seconds: 3600, direction: .atLeast, period: .week)
        let payload = try ea.buildPayload()
        _ = try eb.merge(payload)
        let second = try eb.merge(payload)
        check(second.tagsAdded == 0 && second.tagLinksAdded == 0 && second.targetsApplied == 0,
              "a repeat merge is a no-op — what makes a dumb transport safe")
        let tagCount = try b.listTags().count, targetCount = try b.listTargets().count
        check(tagCount == 1 && targetCount == 1, "and adds nothing")
    }

    do { // a payload from a build that predates tags must still decode
        let (a, ua, ea, _, ub, _) = try pair()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        _ = try a.upsertTag(name: "office", colorHex: "#4E79A7")
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(try ea.buildPayload())) as! [String: Any]
        json.removeValue(forKey: "tags")
        json.removeValue(forKey: "tagLinks")
        json.removeValue(forKey: "targets")
        let older = try JSONSerialization.data(withJSONObject: json)
        check((try? JSONDecoder().decode(SyncPayload.self, from: older)) != nil,
              "an older payload with no tag keys still decodes — optional, not required")
    }

    do { // a budget on a PROJECT resolves to the peer's own project row
        let (a, ua, ea, b, ub, eb) = try pair()
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        // Give B an extra project first so the ids can't coincidentally line up.
        _ = try b.upsertTaskProject(name: "decoy", colorHex: "#000000")
        let g = try a.upsertTaskProject(name: "profiling", colorHex: "#aaaaaa")
        try a.setTarget(subject: .project(g), seconds: 7 * 3600, direction: .atLeast, period: .week)
        _ = try eb.merge(try ea.buildPayload())
        let bGroup = try b.taskProject(named: "profiling")!
        let t = try b.listTargets()
        check(t.count == 1 && t[0].subject == .project(bGroup.id),
              "the budget points at B's project id, which differs from A's")
    }
}

// MARK: - Allocation done state and history

func testAllocationLifecycle() throws {
    print("Allocation lifecycle:")

    do { // retiring one takes it out of the live list but keeps it for history
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let g = try store.upsertTaskProject(name: "recon paper", colorHex: "#fff")
        try store.setTarget(subject: .project(g), seconds: 7 * 3600, direction: .atLeast, period: .week)
        let id = try store.listTargets()[0].id

        try store.setTargetCompleted(id: id, completed: true)
        check(try store.listTargets().isEmpty, "a retired allocation leaves the live list")
        let all = try store.listTargets(includeCompleted: true)
        check(all.count == 1 && !all[0].isLive, "but is still there, marked done")
        check(all[0].completedAt != nil, "with when it ended")

        try store.setTargetCompleted(id: id, completed: false)
        check(try store.listTargets().count == 1, "and reopening puts it back")
    }

    do { // a subject can carry a NEW allocation after the old one is retired
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let g = try store.upsertTaskProject(name: "recon paper", colorHex: "#fff")
        try store.setTarget(subject: .project(g), seconds: 7 * 3600, direction: .atLeast, period: .week)
        try store.setTargetCompleted(id: try store.listTargets()[0].id, completed: true)
        // The unique index is scoped to live rows, so this must be allowed rather than rejected.
        try store.setTarget(subject: .project(g), seconds: 3 * 3600, direction: .atMost, period: .week)
        check(try store.listTargets().count == 1, "one live allocation")
        check(try store.listTargets(includeCompleted: true).count == 2,
              "alongside the retired one — starting again is normal, not a conflict")
    }

    do { // editing a live allocation still edits rather than duplicating
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let g = try store.upsertTaskProject(name: "x", colorHex: "#fff")
        try store.setTarget(subject: .project(g), seconds: 3600, direction: .atLeast, period: .week)
        try store.setTarget(subject: .project(g), seconds: 7200, direction: .atMost, period: .day)
        let live = try store.listTargets()
        check(live.count == 1 && live[0].seconds == 7200 && live[0].period == .day,
              "the live row is updated in place")
    }

    do { // allocated is the amount pro-rated over the span it was live
        let t = Target(id: 1, subject: .tag(1), seconds: 7 * 3600, direction: .atLeast, period: .week)
        let start = date(2026, 8, 3, 0, 0)
        check(approx(TargetMath.allocated(t, from: start, to: date(2026, 8, 31, 0, 0)) / 3600, 28, 0.1),
              "7h/week live for 4 weeks allocated 28h")
        // A part-week counts pro-rata rather than all-or-nothing.
        check(approx(TargetMath.allocated(t, from: start, to: date(2026, 8, 6, 12, 0)) / 3600, 3.5, 0.1),
              "retired mid-week allocates that fraction of the week")
        check(TargetMath.allocated(t, from: start, to: start) == 0, "a zero span allocates nothing")
    }

    do { // the done state SYNCS — otherwise it's retired on one Mac and live on the other
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        let ea = SyncEngine(store: a, deviceID: "A"), eb = SyncEngine(store: b, deviceID: "B")
        let g = try a.upsertTaskProject(name: "recon paper", colorHex: "#fff")
        try a.setTarget(subject: .project(g), seconds: 7 * 3600, direction: .atLeast, period: .week)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTargets().count == 1, "precondition: B has it live")

        try a.setTargetCompleted(id: try a.listTargets()[0].id, completed: true)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTargets().isEmpty, "marking done propagates")
        let bAll = try b.listTargets(includeCompleted: true)
        check(bAll.count == 1 && !bAll[0].isLive, "and B keeps it as history, not deletes it")

        // Reopening propagates too.
        try a.setTargetCompleted(id: try a.listTargets(includeCompleted: true)[0].id, completed: false)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listTargets().count == 1, "and so does reopening")
    }

    do { // created_at survives the trip, or history would restart on the peer
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        let ea = SyncEngine(store: a, deviceID: "A"), eb = SyncEngine(store: b, deviceID: "B")
        let g = try a.upsertTaskProject(name: "x", colorHex: "#fff")
        try a.setTarget(subject: .project(g), seconds: 3600, direction: .atLeast, period: .week)
        let mine = try a.listTargets()[0]
        _ = try eb.merge(try ea.buildPayload())
        let theirs = try b.listTargets()[0]
        check(abs(theirs.createdAt.timeIntervalSince(mine.createdAt)) < 2,
              "the start date carries, so the span isn't reset to the merge time")
    }
}

// MARK: - Notes (feedback)

func testFeedback() throws {
    print("Notes:")

    do { // written, listed newest first, stamped with the device that wrote it
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        store.localDeviceID = "iphone-b653"
        try store.addFeedback("budget row feels cramped", at: date(2026, 8, 30, 9, 0))
        try store.addFeedback("lane labels overlap", at: date(2026, 8, 31, 9, 0))
        let notes = try store.listFeedback()
        check(notes.count == 2, "both notes are kept")
        check(notes[0].text == "lane labels overlap", "newest first")
        check(notes[0].deviceID == "iphone-b653", "stamped with the device it was written on")
        check(notes.allSatisfy(\.isOpen), "and open by default")
    }

    do { // blank input is not a note
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        check(try store.addFeedback("   \n  ") == nil, "whitespace alone doesn't create a note")
        check(try store.listFeedback().isEmpty, "and nothing is stored")
    }

    do { // resolving hides it from the open list without losing it
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        try store.addFeedback("fix the thing")
        let id = try store.listFeedback()[0].id
        try store.setFeedbackResolved(id: id, resolved: true)
        check(try store.listFeedback(includeResolved: false).isEmpty, "done notes leave the open list")
        check(try store.listFeedback().count == 1, "but are still there")
        try store.setFeedbackResolved(id: id, resolved: false)
        check(try store.listFeedback(includeResolved: false).count == 1, "and can be reopened")
    }

    do { // summary is the first line, so a multi-line note fits a one-line row
        let n = Feedback(id: 1, text: "first line\nsecond line", createdAt: Date(),
                         deviceID: nil, resolvedAt: nil)
        check(n.summary == "first line", "the summary is the first line only")
    }

    do { // SYNC: a note written on one device reaches the other, keeping its origin
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        a.localDeviceID = "iphone-b653"; b.localDeviceID = "work"
        let ea = SyncEngine(store: a, deviceID: "A"), eb = SyncEngine(store: b, deviceID: "B")
        try a.addFeedback("noticed on the phone", at: date(2026, 8, 30, 9, 0))
        _ = try eb.merge(try ea.buildPayload())
        let got = try b.listFeedback()
        check(got.count == 1 && got[0].text == "noticed on the phone", "the note arrives")
        check(got[0].deviceID == "iphone-b653",
              "attributed to the device that WROTE it, not the one that synced it")
        check(abs(got[0].createdAt.timeIntervalSince(date(2026, 8, 30, 9, 0))) < 2,
              "with its original timestamp, not the merge time")
    }

    do { // resolving on one device propagates, and a delete stays deleted
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        let ea = SyncEngine(store: a, deviceID: "A"), eb = SyncEngine(store: b, deviceID: "B")
        try a.addFeedback("something")
        _ = try eb.merge(try ea.buildPayload())
        try a.setFeedbackResolved(id: try a.listFeedback()[0].id, resolved: true)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listFeedback(includeResolved: false).isEmpty, "marking done propagates")

        try a.deleteFeedback(id: try a.listFeedback()[0].id)
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listFeedback().isEmpty, "a deleted note is deleted on the peer too")
        _ = try eb.merge(try ea.buildPayload())
        check(try b.listFeedback().isEmpty, "and the tombstone holds against a re-send")
    }

    do { // idempotent, like every other merge
        let (a, ua) = try makeStore(); defer { try? FileManager.default.removeItem(at: ua) }
        let (b, ub) = try makeStore(); defer { try? FileManager.default.removeItem(at: ub) }
        let ea = SyncEngine(store: a, deviceID: "A"), eb = SyncEngine(store: b, deviceID: "B")
        try a.addFeedback("once")
        let payload = try ea.buildPayload()
        _ = try eb.merge(payload)
        check(try eb.merge(payload).feedbackApplied == 0, "a repeat merge changes nothing")
        check(try b.listFeedback().count == 1, "and doesn't duplicate the note")
    }
}

// MARK: - macOS feedback fixes

func testAllocationOrdering() throws {
    print("Allocation ordering:")
    let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
    let a = try store.upsertTaskProject(name: "aaa", colorHex: "#fff")
    let b = try store.upsertTaskProject(name: "bbb", colorHex: "#fff")
    let c = try store.upsertTaskProject(name: "ccc", colorHex: "#fff")
    for g in [a, b, c] {
        try store.setTarget(subject: .project(g), seconds: 3600, direction: .atLeast, period: .week)
    }
    func order() throws -> [Int64] { try store.listTargets().map { $0.subject.id } }
    check(try order() == [a, b, c], "new allocations land at the end, in creation order")

    try store.moveTarget(id: try store.listTargets()[2].id, up: true)
    check(try order() == [a, c, b], "moving one up swaps it with its neighbour")
    try store.moveTarget(id: try store.listTargets()[0].id, up: true)
    check(try order() == [a, c, b], "moving the first one up is a no-op, not a crash")
    try store.moveTarget(id: try store.listTargets()[2].id, up: false)
    check(try order() == [a, c, b], "and so is moving the last one down")

    // Drag-and-drop moves a row to an arbitrary position, which a neighbour swap can't express.
    let ids = try store.listTargets().map(\.id)
    try store.reorderTargets([ids[2], ids[0], ids[1]])
    check(try order() == [b, a, c], "an explicit order is persisted as given")
    try store.reorderTargets(try store.listTargets().map(\.id).reversed())
    check(try order() == [c, a, b], "and reversing it works too")
}

func testDuplicateNameIsProjectScoped() throws {
    print("Project-scoped names:")
    let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
    let jobs = try store.upsertTaskProject(name: "job chores", colorHex: "#fff")
    let prof = try store.upsertTaskProject(name: "profiling", colorHex: "#fff")

    let first = try store.createProject(name: "meetings", colorHex: "#fff", inGroup: jobs)
    // The reported bug: a `meetings` under one project must not block one under another.
    let second = try store.createProject(name: "meetings", colorHex: "#fff", inGroup: prof)
    check(first != second, "the same name under a different project is a different task")
    let both = try store.listProjects(includeArchived: true).filter { $0.name == "meetings" }
    check(both.count == 2, "both exist")
    check(both.compactMap(\.taskProjectID).sorted() == [jobs, prof].sorted(),
          "and each is filed in the project it was created for")
    // And within one project it still reuses rather than forking.
    let again = try store.createProject(name: "meetings", colorHex: "#fff", inGroup: prof)
    check(again == second, "but the same name in the SAME project still reuses")
}

// MARK: - Run

do {
    try testStore()
    testAggregations()
    testFinishedVisibility()
    testTaskSearch()
    testOAuthPKCE()
    testTakeoverPolicy()
    try testFieldLevelSyncCoverage()
    try testSyncEngine()
    testOverlapSafety()
    try testSyncGroundwork()
    try testTaskProjects()
    testQueryParsing()
    testWindowSummary()
    testNudgePolicy()
    try testDeviceAttribution()
    testDeviceLanes()
    testFeedbackPlatform()
    testFeedbackAttachments()
    testPausedPresence()
    try testTaskNameReuse()
    try testDeleteInterval()
    testMarkerLiveness()
    testHoursInput()
    try testRemoteGroupDelete()
    testDuplicateFileCollapse()
    try testTags()
    try testTagSync()
    try testAllocationLifecycle()
    try testFeedback()
    try testAllocationOrdering()
    try testDuplicateNameIsProjectScoped()
    testTagTotals()
    testTargetMath()
} catch {
    print("  ✘ threw: \(error)")
    failures += 1
}

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
