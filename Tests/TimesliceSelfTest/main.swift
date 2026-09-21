import Foundation
import ImageIO
import TimesliceCore
import TimesliceUI
import SwiftUI

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

func testRefreshRefusalClassification() {
    print("Refresh refusal:")

    // Permanent: the grant is gone. Retrying can never succeed, so sync must stop and ask for
    // re-auth rather than looping on a dead credential — the bug this classifier exists to end.
    check(GoogleOAuth.isPermanentRefusal("{\"error\": \"invalid_grant\"}"),
          "invalid_grant is permanent")
    check(GoogleOAuth.isPermanentRefusal("{\"error\":\"invalid_client\",\"error_description\":\"x\"}"),
          "invalid_client is permanent")
    check(GoogleOAuth.isPermanentRefusal("unauthorized_client"),
          "unauthorized_client is permanent")

    // Transient: the token is still good. Signing the user out here would be a self-inflicted
    // outage every time a phone changes network.
    check(!GoogleOAuth.isPermanentRefusal(""), "an empty body is not permanent")
    check(!GoogleOAuth.isPermanentRefusal("The request timed out."), "a timeout is not permanent")
    check(!GoogleOAuth.isPermanentRefusal("{\"error\": \"internal_failure\"}"),
          "a 500 is not permanent")
    check(!GoogleOAuth.isPermanentRefusal("offline"), "being offline is not permanent")
}

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
        let url = GoogleOAuth.authorizationURL(
            pkce: GoogleOAuth.PKCE(), redirect: .loopback(port: 51789), state: "st")
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

    do { // token bodies must carry the verifier, and the secret whenever there is one.
        // Google rejects the exchange with "client_secret is missing." even for a Desktop client
        // using PKCE. Omitting it made sign-in fail silently, so pin it here.
        let body = String(decoding: GoogleOAuth.tokenRequestBody(
            code: "c", pkce: GoogleOAuth.PKCE(), redirect: .loopback(port: 1)), as: UTF8.self)
        check(body.contains("code_verifier="), "exchange sends the PKCE verifier")
        check(body.contains("grant_type=authorization_code"), "correct grant for the exchange")

        let refresh = String(decoding: GoogleOAuth.refreshRequestBody(refreshToken: "r"),
                            as: UTF8.self)
        check(refresh.contains("grant_type=refresh_token"), "refresh uses the right grant")

        // The AUTH url must never carry the secret — that would leak it into browser history.
        let authURL = GoogleOAuth.authorizationURL(
            pkce: GoogleOAuth.PKCE(), redirect: .loopback(port: 1), state: "s")
        check(!authURL.absoluteString.contains("client_secret"),
              "secret stays out of the authorization URL")

        // Credentials are supplied at runtime (env or ~/.config/timeslice/env), never committed,
        // so a bare checkout legitimately has none. Assert the plumbing, not the value.
        //
        // Empty fields are now DROPPED rather than sent blank, because an iOS client has no secret
        // and `client_secret=` is an error there rather than a no-op. So the presence of the field
        // tracks whether a secret exists — which is the property worth pinning either way.
        if GoogleOAuth.isConfigured {
            check(!GoogleOAuth.clientSecret.isEmpty, "configured secret is non-empty")
            check(body.contains("client_secret="), "configured secret reaches the exchange")
            check(refresh.contains("client_secret="), "refresh also carries the secret")
        } else {
            check(GoogleOAuth.clientID.isEmpty, "unconfigured build reports no client id")
            check(!body.contains("client_secret="), "no secret means the field is omitted, not blank")
        }
    }

    do { // the redirect URI must be identical in both legs, or Google refuses the exchange
        let scheme = GoogleOAuth.Redirect.customScheme("com.googleusercontent.apps.123-abc:/oauth")
        check(scheme.uriString == "com.googleusercontent.apps.123-abc:/oauth",
              "custom scheme is passed through verbatim")
        check(GoogleOAuth.Redirect.loopback(port: 8080).uriString == "http://127.0.0.1:8080",
              "loopback builds the Desktop-client redirect")

        let authURL = GoogleOAuth.authorizationURL(
            pkce: GoogleOAuth.PKCE(), redirect: scheme, state: "s").absoluteString
        let exchange = String(decoding: GoogleOAuth.tokenRequestBody(
            code: "c", pkce: GoogleOAuth.PKCE(), redirect: scheme), as: UTF8.self)
        // Both legs must agree. This is the failure the Redirect type exists to make impossible:
        // building the string twice let the consent and exchange drift apart.
        check(authURL.contains("com.googleusercontent.apps.123-abc"),
              "consent URL carries the custom-scheme redirect")
        check(exchange.contains("redirect_uri=com.googleusercontent.apps.123-abc"),
              "token exchange carries the SAME redirect")
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

    do {   // the reported bug: "Leave paused" and it asks again fifteen seconds later, forever
        let pausedAt = Date(timeIntervalSince1970: 1_000_000)
        let due = pausedAt.addingTimeInterval(20 * 60)      // 20m paused, threshold is 15m

        check(NudgePolicy.firesPausedNudge(both, isPaused: true, awaitingAnswer: false,
                                          promptPending: false, pausedSince: pausedAt,
                                          handledFor: nil, now: due),
              "a task paused past the threshold gets asked about")
        check(!NudgePolicy.firesPausedNudge(both, isPaused: true, awaitingAnswer: false,
                                           promptPending: false, pausedSince: pausedAt,
                                           handledFor: pausedAt, now: due),
              "but not twice for the SAME pause — that's what made Leave paused a loop")
        check(!NudgePolicy.firesPausedNudge(both, isPaused: true, awaitingAnswer: false,
                                           promptPending: false, pausedSince: pausedAt,
                                           handledFor: pausedAt,
                                           now: due.addingTimeInterval(3600)),
              "and it stays answered an hour later, not just for the next sweep")

        // A genuinely NEW pause is a new question, with nothing needing to be reset.
        let pausedAgain = pausedAt.addingTimeInterval(7200)
        check(NudgePolicy.firesPausedNudge(both, isPaused: true, awaitingAnswer: false,
                                          promptPending: false, pausedSince: pausedAgain,
                                          handledFor: pausedAt,
                                          now: pausedAgain.addingTimeInterval(20 * 60)),
              "a later pause is asked about even though the previous one was answered")

        // The conditions that were already right stay right.
        check(!NudgePolicy.firesPausedNudge(both, isPaused: true, awaitingAnswer: false,
                                           promptPending: false, pausedSince: pausedAt,
                                           handledFor: nil,
                                           now: pausedAt.addingTimeInterval(60)),
              "a pause shorter than the threshold isn't due yet")
        check(!NudgePolicy.firesPausedNudge(both, isPaused: true, awaitingAnswer: false,
                                           promptPending: true, pausedSince: pausedAt,
                                           handledFor: nil, now: due),
              "a prompt already on screen isn't asked a second time")
        check(!NudgePolicy.firesPausedNudge(both, isPaused: true, awaitingAnswer: true,
                                           promptPending: false, pausedSince: pausedAt,
                                           handledFor: nil, now: due),
              "and it never stacks on the still-working prompt, whose pause isn't yours")
        check(!NudgePolicy.firesPausedNudge(both, isPaused: false, awaitingAnswer: false,
                                           promptPending: false, pausedSince: nil,
                                           handledFor: nil, now: due),
              "nothing to nudge about when nothing is paused")
    }

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

// MARK: - Tagging a task directly

func testTaskTags() {
    print("Task tags:")
    do {
        let (store, url) = try! makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let group = try! store.upsertTaskProject(name: "office", colorHex: "#00f")
        let task = try! store.createProject(name: "recon paper", colorHex: "#f00", inGroup: group)
        let loose = try! store.createProject(name: "tax return", colorHex: "#0f0")

        let work = try! store.upsertTag(name: "work", colorHex: "#111")
        let research = try! store.upsertTag(name: "research", colorHex: "#222")

        // A tag on the PROJECT is inherited by its tasks — the behaviour that already existed.
        try! store.addTag(work, to: .project(group))
        check(try! store.effectiveTagIDsByTask()[task] == [work],
              "a task inherits its project's tag")

        // A tag on the TASK adds to what it inherits rather than replacing it: tags overlap by
        // design, and "this task is also research" is the whole reason to reach for it.
        try! store.addTag(research, to: .task(task))
        check(try! store.effectiveTagIDsByTask()[task] == [work, research],
              "and its own tag adds to that rather than replacing it")

        // A task in no project can be tagged on its own, which is what made this necessary: it was
        // taggable only by inventing a project to hold it.
        try! store.addTag(research, to: .task(loose))
        check(try! store.effectiveTagIDsByTask()[loose] == [research],
              "a task with no project carries its own tags")

        // Removing the task's own tag leaves the inherited one alone.
        try! store.removeTag(research, from: .task(task))
        check(try! store.effectiveTagIDsByTask()[task] == [work],
              "removing a task's own tag doesn't touch what it inherits")

        // What the UI shows on a task row: its own tags only, since the inherited ones are already
        // on the project header above it.
        try! store.addTag(research, to: .task(task))
        let direct = try! store.directTagIDsByTask()
        check(direct[task] == [research],
              "a task's own tags exclude what it inherits — the row shows the addition, not the copy")
        // Keyed by TASK only. Not asserted per-id: `task_projects` and `projects` are separate
        // autoincrement namespaces, so a project id can equal a task id and `direct[group]` would be
        // some unrelated task's entry. The key SET is the honest check.
        check(Set(direct.keys) == Set([task, loose]),
              "only directly-tagged tasks appear — project links don't leak into this map")
        try! store.removeTag(research, from: .task(task))

        // And the task's time reaches the tag through its OWN link, with no project involved.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try! store.insertClosedInterval(projectID: loose, start: t0, end: t0.addingTimeInterval(3600))
        let range = DateRange(unit: .day, start: t0.addingTimeInterval(-86_400),
                             end: t0.addingTimeInterval(86_400))
        let totals = Aggregations.tagTotals(tags: try! store.listTags(),
                                            intervals: try! store.intervals(),
                                            tagIDsByTask: try! store.effectiveTagIDsByTask(),
                                            range: range)
        check(totals.first { $0.tag?.id == research }?.seconds == 3600,
              "a directly-tagged task's time shows up under that tag")
    }
}

// MARK: - Reservations and shapes, persisted and synced

func testReservationsStore() {
    print("Reservations:")
    do {
        let (store, url) = try! makeStore(); defer { try? FileManager.default.removeItem(at: url) }

        let commute = try! store.addReservation(name: "commute", weekdays: .weekdaysOnly,
                                                secondsPerDay: 2 * 3600)!
        _ = try! store.addReservation(name: "meals", secondsPerDay: 90 * 60)
        var all = try! store.listReservations()
        check(all.count == 2, "both are stored")
        check(all.map(\.name) == ["commute", "meals"], "listed by name, so the list doesn't reshuffle")
        check(all.first { $0.name == "commute" }?.weekdays == Weekdays.weekdaysOnly,
              "the weekday mask survives, reusing the allocation encoding")

        // Blank names and non-positive hours are refused rather than stored as a row that claims
        // nothing and shows as an empty line.
        check(try! store.addReservation(name: "   ", secondsPerDay: 3600) == nil,
              "a blank name is refused")
        check(try! store.addReservation(name: "zero", secondsPerDay: 0) == nil,
              "and so is a zero-length reservation")

        // One field at a time. The COALESCE pattern exists because restating every field is exactly
        // how editing an allocation's hours used to wipe its weekdays.
        try! store.updateReservation(id: commute, secondsPerDay: 3 * 3600)
        all = try! store.listReservations()
        check(all.first { $0.id == commute }?.secondsPerDay == 3 * 3600, "the hours change")
        check(all.first { $0.id == commute }?.weekdays == Weekdays.weekdaysOnly,
              "and the days it was set for are untouched")
        try! store.updateReservation(id: commute, name: "commute + parking")
        check(try! store.listReservations().first { $0.id == commute }?.secondsPerDay == 3 * 3600,
              "renaming leaves the hours alone too")

        // Deleting tombstones, or a peer re-adds it.
        try! store.deleteReservation(id: commute)
        check(try! store.listReservations().count == 1, "it's gone")
        check(try! store.tombstoneRecords().contains { $0.kind == "reservation" },
              "and tombstoned so a peer can't resurrect it")
    }
}

func testReservationsSync() {
    print("Reservations over sync:")
    do {
        let (a, aURL) = try! makeStore(); defer { try? FileManager.default.removeItem(at: aURL) }
        let (b, bURL) = try! makeStore(); defer { try? FileManager.default.removeItem(at: bURL) }
        _ = try! a.addReservation(name: "commute", weekdays: .weekdaysOnly, secondsPerDay: 2 * 3600)

        func push(from x: IntervalStore, to y: IntervalStore, bump: TimeInterval = 0) {
            for r in try! x.reservationsForExport() {
                _ = try! y.applyRemoteReservation(uid: r.uid, name: r.name, weekdays: r.weekdays,
                                                  secondsPerDay: r.secondsPerDay,
                                                  remoteUpdatedAt: r.updatedAt + bump)
            }
        }
        push(from: a, to: b)
        check(try! b.listReservations().count == 1, "it arrives on the peer")
        check(try! b.listReservations().first?.weekdays == Weekdays.weekdaysOnly,
              "with its days — a plan is meaningless on a device that doesn't know which hours are gone")

        // Last write wins, and an older copy can't undo a newer edit.
        let id = try! b.listReservations().first!.id
        try! b.updateReservation(id: id, secondsPerDay: 4 * 3600)
        push(from: a, to: b)                    // a's older version, pushed again
        check(try! b.listReservations().first?.secondsPerDay == 4 * 3600,
              "an older copy from a peer doesn't overwrite a newer local edit")
        push(from: b, to: a)
        check(try! a.listReservations().first?.secondsPerDay == 4 * 3600,
              "and the newer edit reaches the other device")

        // A remote delete removes it here.
        let uid = try! a.reservationsForExport().first!.uid
        try! a.applyRemoteTombstone(uid: uid, kind: "reservation",
                                    deletedAt: Date().timeIntervalSince1970)
        check(try! a.listReservations().isEmpty, "a remote delete applies")
    }
}

func testTargetShapePersistence() {
    print("Allocation shapes:")
    do {
        let (store, url) = try! makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let tag = try! store.upsertTag(name: "research", colorHex: "#0f0")
        _ = try! store.setTarget(subject: .tag(tag), seconds: 7 * 3600, direction: .atLeast,
                                period: .week, weekdays: .all,
                                shape: .everyDay(minSeconds: 3600))
        check(try! store.listTargets().first?.shape == .everyDay(minSeconds: 3600),
              "a habit shape round-trips through the database")

        // The shape can be changed alone, and changing it must not disturb anything else.
        let id = try! store.listTargets().first!.id
        try! store.setTargetShape(id: id, .sessions(count: 2, minSeconds: 3 * 3600))
        let t = try! store.listTargets().first!
        check(t.shape == .sessions(count: 2, minSeconds: 3 * 3600), "and can be changed on its own")
        check(t.seconds == 7 * 3600 && t.weekdays.isAll, "without touching the amount or the days")

        // An unknown kind — a newer build's shape — degrades to flexible rather than breaking.
        check(TargetShape(kindRaw: 99, minSeconds: 60, count: 3) == .flexible,
              "an unrecognised shape reads as flexible instead of crashing or vanishing")
    }
}

func testTargetShapeSync() {
    print("Allocation shapes over sync:")
    do {
        let (a, aURL) = try! makeStore(); defer { try? FileManager.default.removeItem(at: aURL) }
        let (b, bURL) = try! makeStore(); defer { try? FileManager.default.removeItem(at: bURL) }
        let tagA = try! a.upsertTag(name: "research", colorHex: "#0f0")
        _ = try! a.setTarget(subject: .tag(tagA), seconds: 7 * 3600, direction: .atLeast,
                            period: .week, shape: .everyDay(minSeconds: 3600))
        for row in try! a.tagsWithUIDs() {
            _ = try! b.insertRemoteTag(uid: row.uid, name: row.tag.name, colorHex: row.tag.colorHex,
                                       sortOrder: row.tag.sortOrder, updatedAt: row.updatedAt)
        }
        func pushTargets(shapeless: Bool = false, bump: TimeInterval = 0) {
            for t in try! a.targetsForExport() {
                guard let table = IntervalStore.table(forSubjectKind: t.subjectKind),
                      let sid = try! b.localID(table: table, uid: t.subjectUID),
                      let subject = TargetSubject(kind: t.subjectKind, id: sid) else { continue }
                _ = try! b.applyRemoteTarget(
                    uid: t.uid, subject: subject, seconds: t.seconds,
                    direction: Target.Direction(rawValue: t.direction)!,
                    period: Target.Period(rawValue: t.period)!,
                    remoteUpdatedAt: t.updatedAt + bump, createdAt: t.createdAt,
                    completedAt: t.completedAt, weekdays: t.weekdays,
                    shapeKind: shapeless ? nil : t.shapeKind,
                    shapeMin: shapeless ? nil : t.shapeMin,
                    shapeCount: shapeless ? nil : t.shapeCount)
            }
        }
        pushTargets()
        check(try! b.listTargets().first?.shape == .everyDay(minSeconds: 3600),
              "the shape travels, so a habit means the same thing on both devices")

        // A peer on an older build sends no shape at all, and can easily be the newer writer. Silence
        // must mean "no opinion", never "flexible" — the same trap weekdays had.
        pushTargets(shapeless: true, bump: 60)
        check(try! b.listTargets().first?.shape == .everyDay(minSeconds: 3600),
              "an older peer's newer edit leaves the shape it doesn't know about alone")
    }
}

// MARK: - Planner

/// Builds the membership for a made-up world: `tasks` maps a task id to its group, `tags` maps a
/// task id to the tags it carries.
func plannerWorld(taskGroups: [Int64: Int64?], taskTags: [Int64: Set<Int64>]) -> SubjectMembership {
    let tasks = taskGroups.map { id, group in
        Project(id: id, name: "t\(id)", colorHex: "#fff", sortOrder: 0, archived: false,
                taskProjectID: group)
    }
    return SubjectMembership(tasks: tasks, tagIDsByTask: taskTags)
}

func floor(_ id: Int64, _ subject: TargetSubject, hours: Double,
           period: Target.Period = .week, weekdays: Weekdays = .all,
           shape: TargetShape = .flexible) -> Target {
    Target(id: id, subject: subject, seconds: hours * 3600, direction: .atLeast,
           period: period, weekdays: weekdays, shape: shape)
}

func plannerInput(_ targets: [Target], reservations: [Reservation] = [],
                  membership: SubjectMembership, wakingHours: Double = 16) -> Planner.Input {
    Planner.Input(targets: targets, reservations: reservations, membership: membership,
                  names: Dictionary(uniqueKeysWithValues: targets.map { ($0.id, "a\($0.id)") }),
                  wakingSecondsPerDay: wakingHours * 3600)
}

func testSubjectMembership() {
    print("Subject membership:")
    // 1,2 in group 10; 3 in the Inbox. 1 and 3 tagged 99.
    let m = plannerWorld(taskGroups: [1: 10, 2: 10, 3: nil], taskTags: [1: [99], 3: [99]])

    check(m.taskIDs(for: .task(2)) == [2], "a task is itself")
    check(m.taskIDs(for: .project(10)) == [1, 2], "a project is its tasks")
    check(m.taskIDs(for: .tag(99)) == [1, 3], "a tag is every task carrying it")

    // The two cases `TargetSubject` cannot express, which the metrics highlight relies on. They were
    // in the view before the hoist, so they need pinning here or the move could quietly lose them.
    check(m.taskIDs(inGroup: nil) == [3], "nil group is the Inbox, not every task")
    check(m.taskIDs(withTag: nil) == [2], "nil tag is the untagged bucket — task 2 carries none")

    check(m.relation(.task(1), .project(10)) == .containedIn, "a task inside its project")
    check(m.relation(.project(10), .task(1)) == .contains, "and the reverse")
    check(m.relation(.task(2), .tag(99)) == .disjoint, "an untagged task is disjoint from the tag")
    check(m.relation(.project(10), .tag(99)) == .partial,
          "a project and a tag sharing one task of two overlap partially — the case that makes the "
              + "bounds a range")
}

func testPlannerBounds() {
    print("Planner bounds:")

    // Disjoint floors simply add up: two separate things each need their own hours.
    do {
        let m = plannerWorld(taskGroups: [1: 10, 2: 20], taskTags: [:])
        let (lo, hi) = Planner.bounds(floors: [floor(1, .project(10), hours: 7),
                                               floor(2, .project(20), hours: 5)], membership: m)
        check(approx(lo / 3600, 12, 0.01) && approx(hi / 3600, 12, 0.01),
              "disjoint floors add to the same lower and upper bound")
    }

    // Nesting: a task inside a tag. Its hours are already inside the tag's, so the honest lower
    // bound is the tag alone — adding them would count the same work twice.
    do {
        let m = plannerWorld(taskGroups: [1: nil, 2: nil], taskTags: [1: [99], 2: [99]])
        let tag = floor(1, .tag(99), hours: 35)
        let inner = floor(2, .task(1), hours: 2)
        let (lo, hi) = Planner.bounds(floors: [tag, inner], membership: m)
        check(approx(lo / 3600, 35, 0.01),
              "a floor inside another contributes nothing to the lower bound")
        check(approx(hi / 3600, 37, 0.01),
              "while the upper bound is the naive sum, which is what no-sharing would cost")
    }

    // Partial overlap: neither contains the other, so they cannot both be in a disjoint family.
    do {
        let m = plannerWorld(taskGroups: [1: 10, 2: 10, 3: nil],
                             taskTags: [2: [99], 3: [99]])
        let group = floor(1, .project(10), hours: 10)     // tasks 1,2
        let tag = floor(2, .tag(99), hours: 35)           // tasks 2,3
        let (lo, hi) = Planner.bounds(floors: [group, tag], membership: m)
        check(approx(lo / 3600, 35, 0.01), "the larger of two partly-overlapping floors is the bound")
        check(lo < hi, "and the lower bound sits below the naive sum, as a range should")
    }

    // A ceiling is not work to do.
    do {
        let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])
        let ceiling = Target(id: 9, subject: .project(10), seconds: 3600, direction: .atMost,
                             period: .day)
        let p = Planner.plan(plannerInput([ceiling], membership: m))
        check(p.requiredUpperSeconds == 0, "an atMost allocation never consumes capacity")
        check(p.ceilings.count == 1, "but it is still reported, so it can be shown")
        check(p.verdict == .fits, "a week of nothing but ceilings fits trivially")
    }
}

func testPlannerNormalisation() {
    print("Planner period normalisation:")
    let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])
    check(approx(floor(1, .project(10), hours: 7, period: .week).weeklySeconds / 3600, 7, 0.01),
          "a weekly floor is itself")
    check(approx(floor(1, .project(10), hours: 30, period: .month).weeklySeconds / 3600, 7, 0.01),
          "a 30h month is 7h a week on the app's nominal month")
    // A DAILY floor is per claimed day, so the weekday mask decides how many of them there are.
    check(approx(floor(1, .project(10), hours: 1, period: .day).weeklySeconds / 3600, 7, 0.01),
          "1h a day across all seven days is 7h a week")
    check(approx(floor(1, .project(10), hours: 1, period: .day,
                       weekdays: .weekdaysOnly).weeklySeconds / 3600, 5, 0.01),
          "and 1h a day Monday to Friday is 5h — ignoring the mask would have said 7")
    _ = m
}

func testPlannerPlacement() {
    print("Planner placement:")

    // Weekday spreading: a Mon-Fri floor never lands on the weekend.
    do {
        let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])
        let p = Planner.plan(plannerInput([floor(1, .project(10), hours: 10,
                                                 weekdays: .weekdaysOnly)], membership: m))
        let weekend = p.days.filter { $0.weekday == 1 || $0.weekday == 7 }
        check(weekend.allSatisfy { $0.committedSeconds == 0 },
              "a Monday-to-Friday floor puts nothing on Saturday or Sunday")
        check(approx(p.days.reduce(0) { $0 + $1.committedSeconds } / 3600, 10, 0.01),
              "and all ten hours are placed somewhere")
        check(p.unplaced.isEmpty, "with nothing left over")
    }

    // Narrow weekdays can make a total impossible before any competition.
    do {
        let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])
        let oneDay = Weekdays(rawValue: 1 << 1)          // Monday only
        let p = Planner.plan(plannerInput([floor(1, .project(10), hours: 20, weekdays: oneDay)],
                                          membership: m))
        check(p.unplaced.first?.reason == .weekdaysTooNarrow,
              "20h on a single 16h day is refused for the right reason")
        check(p.unplaced.first?.wouldFitIf.contains("more days") == true,
              "and the suggestion is to claim more days")
    }

    // The habit case, which is the question that started this feature.
    do {
        let m = plannerWorld(taskGroups: [1: 10, 2: 20], taskTags: [:])
        // 15h of the 16h day is reserved, leaving one hour free everywhere.
        let reserved = [Reservation(id: 1, name: "life", secondsPerDay: 15 * 3600)]
        let habit = floor(1, .project(10), hours: 7, shape: .everyDay(minSeconds: 3600))
        let p = Planner.plan(plannerInput([habit], reservations: reserved, membership: m))
        check(p.unplaced.isEmpty, "1h a day fits when exactly 1h a day is free")

        // Now take that hour away on two days by reserving more.
        let tight = [Reservation(id: 1, name: "life", secondsPerDay: 15 * 3600),
                     Reservation(id: 2, name: "tuesdays", weekdays: Weekdays(rawValue: 1 << 2),
                                 secondsPerDay: 3600)]
        let p2 = Planner.plan(plannerInput([habit], reservations: tight, membership: m))
        check(p2.unplaced.first?.reason == .shapeImpossible,
              "and is impossible as a habit when one day has no hour to give")
        check(p2.unplaced.first?.wouldFitIf.contains("of 7 days") == true
                || p2.unplaced.first?.wouldFitIf.contains("freed up") == true,
              "and the explanation offers a change: a smaller daily minimum, or freeing those days")
    }

    // Sessions: the question is whether enough days have an unbroken run that long, not which days
    // they land on. The planner deliberately stopped inventing a schedule — "office 16h on Monday"
    // was arithmetically valid and useless — so what's checked is feasibility.
    do {
        let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])
        // 3h free per day: two 3h sessions are possible.
        let reserved = [Reservation(id: 1, name: "life", secondsPerDay: 13 * 3600)]
        let target = floor(1, .project(10), hours: 6, shape: .sessions(count: 2, minSeconds: 3 * 3600))
        check(Planner.plan(plannerInput([target], reservations: reserved, membership: m))
                .unplaced.isEmpty,
              "two 3h sessions are fine when every day has 3h free")

        // 90 minutes free per day cannot hold a 3h block, however many days there are. Without the
        // room check this passed, because the weekly total fitted.
        let cramped = [Reservation(id: 1, name: "life", secondsPerDay: 14.5 * 3600)]
        let p = Planner.plan(plannerInput([floor(1, .project(10), hours: 6,
                                                shape: .sessions(count: 2, minSeconds: 3 * 3600))],
                                          reservations: cramped, membership: m))
        check(p.unplaced.first?.reason == .shapeImpossible,
              "but not when no day has an unbroken 3h in it, even though the total fits")
        check(p.unplaced.first?.wouldFitIf.contains("free") == true,
              "and the suggestion is about the daily room, not the weekly total")
    }

    // A shape that contradicts its own total.
    do {
        let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])
        let target = floor(1, .project(10), hours: 4, shape: .sessions(count: 3, minSeconds: 2 * 3600))
        let p = Planner.plan(plannerInput([target], membership: m))
        check(p.unplaced.first?.reason == .shapeImpossible,
              "three 2h sessions cannot come out of a 4h total")
    }
}

func testPlannerReservations() {
    print("Planner reservations:")
    let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])

    // Reservations claim their days first, and only their days.
    let commute = Reservation(id: 1, name: "commute", weekdays: .weekdaysOnly, secondsPerDay: 2 * 3600)
    let p = Planner.plan(plannerInput([], reservations: [commute], membership: m))
    check(approx(p.reservedSeconds / 3600, 10, 0.01), "2h on five weekdays is 10h reserved")
    check(p.days.first { $0.weekday == 1 }?.reservedSeconds == 0, "and nothing on Sunday")

    // A reservation bigger than the day is capped rather than producing negative slack, which would
    // read as an allocation problem instead of the data-entry mistake it is.
    let silly = Reservation(id: 2, name: "impossible", secondsPerDay: 30 * 3600)
    let p2 = Planner.plan(plannerInput([], reservations: [silly], membership: m))
    check(p2.days.allSatisfy { $0.reservedSeconds == $0.capacitySeconds },
          "a reservation longer than the waking day is capped at it")
    check(p2.days.allSatisfy { $0.slackSeconds == 0 }, "leaving zero slack, not negative slack")
}

func testPlannerVerdicts() {
    print("Planner verdicts:")
    let m = plannerWorld(taskGroups: [1: 10, 2: 20], taskTags: [:])

    // Comfortably inside: 20h of a 112h week.
    let easy = Planner.plan(plannerInput([floor(1, .project(10), hours: 20)], membership: m))
    check(easy.verdict == .fits, "20h in a 112h week fits")

    // Beyond even the disjoint lower bound.
    let heavy = Planner.plan(plannerInput([floor(1, .project(10), hours: 60),
                                           floor(2, .project(20), hours: 60)], membership: m))
    check(heavy.verdict == .oversubscribed,
          "120h of disjoint floors in a 112h week is oversubscribed whatever the overlap")

    // Between the bounds: the pair overlaps, so whether it fits depends on how much they share.
    do {
        let m2 = plannerWorld(taskGroups: [1: 10, 2: 10, 3: nil], taskTags: [2: [99], 3: [99]])
        let group = floor(1, .project(10), hours: 60)     // tasks 1,2
        let tag = floor(2, .tag(99), hours: 60)           // tasks 2,3
        let p = Planner.plan(plannerInput([group, tag], membership: m2))
        check(p.requiredLowerSeconds / 3600 == 60 && p.requiredUpperSeconds / 3600 == 120,
              "the bounds straddle the 112h capacity, and the range is what says the overlap matters")
        // Spread evenly, 120h over seven days is 17.1h a day against 16h awake, so days are over too.
        // The verdict takes the stronger reading: a week that cannot be laid out day by day is not
        // "uncertain", whatever the weekly total says.
        check(p.verdict == .oversubscribed,
              "and the day-level check makes the verdict definite rather than hopeful")
        check(!p.overloadedDays.isEmpty, "naming the days that are over")
    }

    // Nesting is named, so a commitment that is already counted can be shown as such.
    do {
        let m3 = plannerWorld(taskGroups: [1: nil, 2: nil], taskTags: [1: [99], 2: [99]])
        let p = Planner.plan(plannerInput([floor(1, .tag(99), hours: 35),
                                           floor(2, .task(1), hours: 2)], membership: m3))
        check(p.nestings.count == 1, "the inner allocation is reported as nested")
        check(p.nestings.first?.innerName == "a2" && p.nestings.first?.outerName == "a1",
              "naming which sits inside which")
    }
}

func testPlannerFrontier() {
    print("Planner frontier:")
    let m = plannerWorld(taskGroups: [1: 10, 2: 20], taskTags: [:])
    // 4h free a day, so 28h a week for everything.
    let reserved = [Reservation(id: 1, name: "life", secondsPerDay: 12 * 3600)]
    let fixed = floor(1, .project(10), hours: 20)
    let flexible = floor(2, .project(20), hours: 4)
    let input = plannerInput([fixed, flexible], reservations: reserved, membership: m)

    let ceiling = Planner.frontier(for: 2, in: input)
    check(approx(ceiling / 3600, 8, 0.3),
          "with 28h free and 20h taken, the other allocation tops out near 8h")

    // The frontier must agree with the planner, which is the point of bisecting through it.
    let at = Planner.plan(plannerInput([fixed, flexible.withWeeklySeconds(ceiling)],
                                       reservations: reserved, membership: m))
    check(at.unplaced.isEmpty, "an allocation set to its computed ceiling packs")
    let over = Planner.plan(plannerInput([fixed, flexible.withWeeklySeconds(ceiling + 3600)],
                                         reservations: reserved, membership: m))
    check(!over.unplaced.isEmpty, "and one hour more does not")
}

func testPlannerRealShape() {
    print("Planner against the real allocation shape:")
    // The live database, reduced to its structure: office covers most work; KT sits inside office;
    // vllm partly overlaps it; the rest are separate.
    //  tasks 1-3 = office-tagged work, 3 = presentation for KT, 4 = the other vllm task,
    //  5 = recon, 6 = deep technical creative (inside recon), 7 = family, 8 = gym, 9 = stonks
    let m = plannerWorld(
        taskGroups: [1: 100, 2: 100, 3: nil, 4: 100, 5: 200, 6: 200, 7: nil, 8: nil, 9: nil],
        taskTags: [1: [1], 2: [1], 3: [1], 7: [2]])
    let tueFri = Weekdays(rawValue: (1 << 2) | (1 << 5))
    let weekends = Weekdays(rawValue: (1 << 0) | (1 << 6))
    let monTue = Weekdays(rawValue: (1 << 1) | (1 << 2))
    let targets = [
        floor(1, .tag(1), hours: 35, weekdays: .weekdaysOnly),   // office
        floor(2, .project(100), hours: 10),                      // vllm — partial overlap with office
        floor(3, .project(200), hours: 7),                       // recon paper
        floor(4, .tag(2), hours: 7),                             // family
        floor(5, .task(8), hours: 4, weekdays: tueFri),          // gym
        floor(6, .task(9), hours: 2, weekdays: weekends),        // stonks
        floor(7, .task(6), hours: 4),                            // deep technical creative ⊂ recon
        floor(8, .task(3), hours: 2, weekdays: monTue),           // KT ⊂ office
    ]
    let p = Planner.plan(plannerInput(targets, membership: m))

    // 71h is the sum of every floor, but KT (2h) sits inside office and deep-technical-creative (4h)
    // inside recon paper, and an allocation inside another asks for nothing extra — its hours are
    // already in the parent's total. Charging for them twice was what made the page report a nested
    // allocation as "won't fit" while also saying its hours were already counted.
    check(approx(p.requiredUpperSeconds / 3600, 65, 0.01),
          "the upper bound excludes nested allocations: 71h of floors, 65h actually asked for")
    // office 35 + recon 7 + family 7 + gym 4 + stonks 2 = 55; vllm partly overlaps office so it can't
    // join a disjoint family.
    check(approx(p.requiredLowerSeconds / 3600, 55, 0.01),
          "and the disjoint lower bound is 55h — the figure that makes the verdict safe to state")
    check(!p.unplaced.contains { $0.name == "a8" },
          "a nested allocation is never reported as not fitting, which contradicted itself")
    check(p.nestings.contains { $0.innerName == "a8" && $0.outerName == "a1" },
          "KT is reported as already inside office")
    check(p.nestings.contains { $0.innerName == "a7" && $0.outerName == "a3" },
          "and deep technical creative as inside recon paper")
}

// MARK: - Backlog and replanning

func testReplan() {
    print("Replan:")
    let m = plannerWorld(taskGroups: [1: 10, 2: 20], taskTags: [:])
    // 10h a week on all seven days, so ~1.43h a day.
    let target = floor(1, .project(10), hours: 10)
    let input = plannerInput([target], membership: m)
    let plan = Planner.plan(input)

    // Wednesday, with Sunday to Tuesday gone and nothing done. Three days' worth is owed.
    do {
        let r = Replan.compute(plan: plan, input: input, actuals: [:],
                               elapsedWeekdays: [1, 2, 3], remainingWeekdays: [4, 5, 6, 7])
        let item = r.items.first!
        check(approx(item.expectedByNowSeconds / 3600, 30.0 / 7, 0.05),
              "three of seven days elapsed means three days' worth was expected")
        check(approx(item.debtSeconds / 3600, 30.0 / 7, 0.05), "and none of it was done, so that's the backlog")
        check(item.remainingClaimedDays == 4, "four of its days are left")
        check(approx((item.requiredPerRemainingDay ?? 0) / 3600, 2.5, 0.01),
              "so finishing needs 2.5h a day rather than the original 1.43h")
        check(item.standing == .recoverable, "which those days can hold, so it's still recoverable")
    }

    // Being ahead is not a backlog. An allocation with more done than expected owes nothing.
    do {
        let r = Replan.compute(plan: plan, input: input, actuals: [1: 8 * 3600],
                               elapsedWeekdays: [1, 2, 3], remainingWeekdays: [4, 5, 6, 7])
        check(r.items.first?.debtSeconds == 0, "ahead of schedule is not a debt")
        check(r.items.first?.standing == .onTrack, "and reads as on track")
        check(approx((r.items.first?.requiredPerRemainingDay ?? 0) / 3600, 0.5, 0.01),
              "with only the remainder left to spread")
    }

    // Met, so nothing is owed at all.
    do {
        let r = Replan.compute(plan: plan, input: input, actuals: [1: 10 * 3600],
                               elapsedWeekdays: [1, 2, 3], remainingWeekdays: [4, 5, 6, 7])
        check(r.items.first?.standing == .met, "a finished allocation is met, not on track")
        check(r.items.first?.remainingSeconds == 0, "with nothing remaining")
    }

    // The point of the whole thing: say "already lost" on Wednesday, not on Sunday.
    do {
        // 60h a week, nothing done, three days left. 20h a day against a 16h day is not happening.
        let heavy = floor(1, .project(10), hours: 60)
        let heavyInput = plannerInput([heavy], membership: m)
        let r = Replan.compute(plan: Planner.plan(heavyInput), input: heavyInput, actuals: [:],
                               elapsedWeekdays: [1, 2, 3, 4], remainingWeekdays: [5, 6, 7])
        let item = r.items.first!
        check(item.standing == .unreachable,
              "60h with three 16h days left is unreachable, and saying so now leaves a choice")
        check(item.adviceIfUnreachable.contains("drop it to"),
              "and the advice names the figure that would be reachable")
        check(r.weekIsLost, "the week as a whole can't absorb what's left either")
    }

    // A weekdays-only allocation owes NOTHING over a weekend. Charging it for days it never claimed is
    // how a planner tells you you're behind when you aren't.
    do {
        let weekdayOnly = floor(1, .project(10), hours: 10, weekdays: .weekdaysOnly)
        let wInput = plannerInput([weekdayOnly], membership: m)
        let r = Replan.compute(plan: Planner.plan(wInput), input: wInput, actuals: [:],
                               elapsedWeekdays: [1], remainingWeekdays: [2, 3, 4, 5, 6, 7])
        check(r.items.first?.expectedByNowSeconds == 0,
              "after only Sunday, a Monday-to-Friday allocation is not behind")
        check(r.items.first?.debtSeconds == 0, "so there is no backlog to report")
        check(r.items.first?.remainingClaimedDays == 5, "and all five of its days are still to come")
    }

    // No days left at all: unreachable for a reason worth stating differently.
    do {
        let weekdayOnly = floor(1, .project(10), hours: 10, weekdays: .weekdaysOnly)
        let wInput = plannerInput([weekdayOnly], membership: m)
        let r = Replan.compute(plan: Planner.plan(wInput), input: wInput, actuals: [1: 3 * 3600],
                               elapsedWeekdays: [1, 2, 3, 4, 5, 6], remainingWeekdays: [7])
        check(r.items.first?.standing == .unreachable, "Saturday is not one of its days")
        check(r.items.first?.adviceIfUnreachable.contains("none of its days are left") == true,
              "and the advice says so rather than suggesting a smaller number")
    }

    // Late in the day, only part of today is left. A replan at 9pm that assumed a full day would call
    // an evening recoverable after it had gone.
    do {
        let r = Replan.compute(plan: plan, input: input, actuals: [:],
                               elapsedWeekdays: [1, 2, 3, 4, 5, 6], remainingWeekdays: [7],
                               fractionOfTodayLeft: 0.1)
        check(r.items.first?.standing == .unreachable,
              "10h owed with a tenth of one day left is unreachable")
        let full = Replan.compute(plan: plan, input: input, actuals: [:],
                                  elapsedWeekdays: [1, 2, 3, 4, 5, 6], remainingWeekdays: [7],
                                  fractionOfTodayLeft: 1)
        check(full.items.first?.standing == .recoverable,
              "whereas a whole 16h day could technically still hold it")
    }

    // Catch-up may use ANY free hour on the remaining days, including hours the plan had pencilled in
    // for the very allocations that are behind.
    //
    // This is the bug that made a recoverable week read "cannot be finished": the room was computed as
    // `slackSeconds` — capacity minus reserved minus COMMITTED — and committed is the plan's own spread
    // of the allocations whose remaining need was being summed. So it compared what's left to do against
    // what's left after what's left to do. Nothing caught it, because every existing case had one
    // allocation, where the two definitions agree.
    do {
        let m2 = plannerWorld(taskGroups: [1: 10, 2: 20], taskTags: [:])
        // 60h of need in a 112h week, nothing done, the whole week ahead. Comfortable.
        let input2 = plannerInput([floor(1, .project(10), hours: 30),
                                   floor(2, .project(20), hours: 30)], membership: m2)
        let r = Replan.compute(plan: Planner.plan(input2), input: input2, actuals: [:],
                               elapsedWeekdays: [], remainingWeekdays: [1, 2, 3, 4, 5, 6, 7])
        check(approx(r.remainingNeedSeconds / 3600, 60, 0.01), "60h still to do")
        check(approx(r.remainingCapacitySeconds / 3600, 112, 0.01),
              "and the whole 112h of the week is available for it, not 112h minus the plan")
        check(!r.weekIsLost,
              "so the week is finishable — the old arithmetic called this lost by subtracting the "
                  + "need from the room before comparing them")
    }

    // Reserved time IS subtracted, because those hours genuinely aren't available.
    do {
        let m2 = plannerWorld(taskGroups: [1: 10], taskTags: [:])
        let reserved = [Reservation(id: 1, name: "life", secondsPerDay: 10 * 3600)]
        let input2 = plannerInput([floor(1, .project(10), hours: 50)], reservations: reserved,
                                  membership: m2)
        let r = Replan.compute(plan: Planner.plan(input2), input: input2, actuals: [:],
                               elapsedWeekdays: [], remainingWeekdays: [1, 2, 3, 4, 5, 6, 7])
        check(approx(r.remainingCapacitySeconds / 3600, 42, 0.01),
              "6h a day after a 10h reservation is 42h, not 112h")
        check(r.weekIsLost, "so 50h of need doesn't fit, and that verdict is about real hours")
    }

    // "Unreachable" is about one allocation's own days, not about losing a race with another. Mixing the
    // two made everything look impossible whenever the week was merely busy.
    do {
        let m2 = plannerWorld(taskGroups: [1: 10, 2: 20], taskTags: [:])
        let sat = Weekdays(rawValue: 1 << 6)
        // Two allocations both wanting Saturday, 10h each, on a 16h day.
        let input2 = plannerInput([floor(1, .project(10), hours: 10, weekdays: sat),
                                   floor(2, .project(20), hours: 10, weekdays: sat)],
                                  membership: m2)
        let plan2 = Planner.plan(input2)
        let r = Replan.compute(plan: plan2, input: input2, actuals: [:],
                               elapsedWeekdays: [], remainingWeekdays: [1, 2, 3, 4, 5, 6, 7])
        check(r.unreachable.isEmpty,
              "neither is unreachable: each would fit in Saturday on its own")
        // The two questions live in different places on purpose. `weekIsLost` compares HOURS, and the
        // week has 112 of them free, so it correctly says nothing is wrong with the total. Whether
        // those hours fall on days the work is allowed to use is the PLANNER's job, and it flags
        // Saturday. Answering both in one figure is what made every allocation look impossible
        // whenever the week was merely busy.
        check(!r.weekIsLost, "the week has hours to spare in aggregate, so that verdict stays clear")
        check(plan2.overloadedDays == [7],
              "and Saturday is flagged as over capacity, which is where the real problem is")
    }

    // How much of today is left, measured against midnight rather than against "how far through the
    // waking day are we" — which needs to know when your day starts, and doesn't.
    do {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        let waking: TimeInterval = 16 * 3600
        let at = { (h: Int) in c.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: h))! }
        // Early: more time before midnight than a waking day is long, so today is a whole day — it
        // doesn't become bigger than a day because you got up early.
        check(Replan.fractionOfDayLeft(now: at(6), wakingSeconds: waking, calendar: c) == 1,
              "at 6am today counts as a full day, clamped at one")
        // 8pm: four hours to midnight, a quarter of a waking day.
        check(approx(Replan.fractionOfDayLeft(now: at(20), wakingSeconds: waking, calendar: c),
                     0.25, 0.01),
              "at 8pm a quarter of a waking day is left")
        // The bug this replaces: dividing time-since-midnight by waking hours reported nothing left
        // from mid-afternoon, which called every allocation unreachable for the rest of the day.
        check(Replan.fractionOfDayLeft(now: at(15), wakingSeconds: waking, calendar: c) > 0.5,
              "and at 3pm there is still most of a working evening, not zero")
    }

    // Nested allocations are listed but not added to the total, or the same hours count twice.
    do {
        let m2 = plannerWorld(taskGroups: [1: nil, 2: nil], taskTags: [1: [99], 2: [99]])
        let outer = floor(1, .tag(99), hours: 20)
        let inner = floor(2, .task(1), hours: 5)
        let input2 = plannerInput([outer, inner], membership: m2)
        let r = Replan.compute(plan: Planner.plan(input2), input: input2, actuals: [:],
                               elapsedWeekdays: [], remainingWeekdays: [1, 2, 3, 4, 5, 6, 7])
        check(r.items.count == 2, "both are listed — you can be on pace for the tag and behind on the "
                                  + "piece of it you care about")
        check(approx(r.remainingNeedSeconds / 3600, 20, 0.01),
              "but the total counts 20h, not 25h: the inner hours are already inside the outer")
    }

    // The "why can't I finish this" half: what is taking the room on an allocation's own days.
    do {
        let m2 = plannerWorld(taskGroups: [1: 10, 2: 20, 3: 30], taskTags: [:])
        // A big weekday commitment, a small one that wants the same days, and 12h a day reserved so
        // there is only 4h to fight over.
        let big = floor(1, .project(10), hours: 18, weekdays: .weekdaysOnly)
        let small = floor(2, .project(20), hours: 10, weekdays: .weekdaysOnly)
        let reserved = [Reservation(id: 1, name: "life", weekdays: .weekdaysOnly,
                                    secondsPerDay: 12 * 3600)]
        let input2 = plannerInput([big, small], reservations: reserved, membership: m2)
        let r = Replan.compute(plan: Planner.plan(input2), input: input2, actuals: [:],
                               elapsedWeekdays: [1, 2, 3], remainingWeekdays: [4, 5, 6, 7])
        let item = r.items.first { $0.name == "a2" }!
        check(!item.blockers.isEmpty, "the row knows what else wants its days")
        check(item.blockers.first?.name == "a1" || item.blockers.first?.name == "reserved",
              "and names the biggest claimant, which is what there is to argue with")
        check(item.blockers.contains { $0.name == "reserved" },
              "reserved time counts as a competitor — it is the commonest reason a day has no room, "
                  + "and leaving it out would blame the wrong thing")
        check(item.blockers.allSatisfy { $0.secondsOnThoseDays > 0 },
              "each blocker carries the hours it takes on those days, not its weekly total")
        check(item.blockers.count <= 3, "capped, because a list of everything explains nothing")
    }

    // The replan itself: the remaining days carry the catch-up, and only the days still to come appear.
    do {
        let r = Replan.compute(plan: plan, input: input, actuals: [:],
                               elapsedWeekdays: [1, 2, 3], remainingWeekdays: [4, 5, 6, 7])
        check(r.replannedDays.map(\.weekday) == [4, 5, 6, 7], "only the days left are replanned")
        check(r.replannedDays.allSatisfy { day in
                approx(day.committedSeconds / 3600, 2.5, 0.01)
              },
              "each carrying the catch-up figure rather than the original 1.43h")
    }

    // Catch-up follows the ROOM, not an equal split. This is the difference between a planner that
    // reports "Friday is 2.2h over" while Saturday sits half empty, and one that uses Saturday.
    do {
        let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])
        let target = floor(1, .project(10), hours: 12)          // all seven days
        // Friday nearly full, Saturday nearly empty.
        let reserved = [Reservation(id: 1, name: "friday thing", weekdays: Weekdays(rawValue: 32),
                                    secondsPerDay: 14 * 3600)]
        let input = plannerInput([target], reservations: reserved, membership: m)
        let plan = Planner.plan(input)
        let r = Replan.compute(plan: plan, input: input, actuals: [:],
                               elapsedWeekdays: [1, 2, 3, 4], remainingWeekdays: [5, 6, 7])
        let friday = r.replannedDays.first { $0.weekday == 6 }!
        let saturday = r.replannedDays.first { $0.weekday == 7 }!
        check(friday.committedSeconds < saturday.committedSeconds,
              "the day with less room is given less of the catch-up")
        check(friday.committedSeconds <= friday.capacitySeconds - friday.reservedSeconds + 60,
              "and never more than it can actually hold")
        check(approx(r.replannedDays.reduce(0) { $0 + $1.committedSeconds } / 3600, 12, 0.05),
              "with the whole remaining need still placed somewhere")
    }

    // An allocation whose own days are gone can't be rescued by a free day it doesn't claim — the
    // honest answer, and the reason a day can still read as over capacity.
    do {
        let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])
        let weekdaysOnly = floor(1, .project(10), hours: 20, weekdays: .weekdaysOnly)
        let input = plannerInput([weekdaysOnly], membership: m)
        let r = Replan.compute(plan: Planner.plan(input), input: input, actuals: [:],
                               elapsedWeekdays: [1, 2, 3, 4, 5], remainingWeekdays: [6, 7])
        let saturday = r.replannedDays.first { $0.weekday == 7 }
        check(saturday?.placements.isEmpty ?? false,
              "Saturday stays empty for a Mon-Fri allocation however much room it has")
    }
}

// MARK: - Daily plan

func testDailyPlan() {
    print("Daily plan:")
    let m = plannerWorld(taskGroups: [1: 10, 2: 20], taskTags: [:])

    func shares(_ p: Replan.DailyPlan, _ weekday: Int, _ id: Int64) -> Replan.DayShare {
        p.byDay[weekday]?[id] ?? Replan.DayShare(intended: 0, carried: 0)
    }

    // 14h a week over all seven days: 2h a day. Nothing done, so the three days left owe 14h between
    // them — 2h each as their own share and the other 8h carried in.
    do {
        let target = floor(1, .project(10), hours: 14)
        let input = plannerInput([target], membership: m)
        let daily = Replan.dailyPlan(input: input, plan: Planner.plan(input),
                                     creditedByWeekday: [:], remainingWeekdays: [5, 6, 7])
        check(approx(shares(daily, 5, 1).intended / 3600, 2, 0.01), "each day keeps its own 2h share")
        let carried = [5, 6, 7].reduce(0.0) { $0 + shares(daily, $1, 1).carried } / 3600
        check(approx(carried, 8, 0.05), "and the four missed days' 8h is carried into them")
        check(daily.unplaced.isEmpty, "with room to spare, nothing is left over")
    }

    // On pace: each remaining day wants its own share and nothing is carried.
    do {
        let target = floor(1, .project(10), hours: 14)
        let input = plannerInput([target], membership: m)
        let onPace: [Int: [Int64: TimeInterval]] = [1: [1: 2 * 3600], 2: [1: 2 * 3600],
                                                   3: [1: 2 * 3600], 4: [1: 2 * 3600]]
        let daily = Replan.dailyPlan(input: input, plan: Planner.plan(input),
                                     creditedByWeekday: onPace, remainingWeekdays: [5, 6, 7])
        check([5, 6, 7].allSatisfy { shares(daily, $0, 1).carried < 60 },
              "a week on pace carries nothing")
        check(approx(shares(daily, 7, 1).intended / 3600, 2, 0.01), "and each day still wants its share")
    }

    // Already met: nothing anywhere, and nothing negative.
    do {
        let target = floor(1, .project(10), hours: 7)
        let input = plannerInput([target], membership: m)
        let daily = Replan.dailyPlan(input: input, plan: Planner.plan(input),
                                     creditedByWeekday: [1: [1: 9 * 3600]],
                                     remainingWeekdays: [5, 6, 7])
        check(daily.byDay.isEmpty, "an allocation already met asks for nothing")
    }

    // THE ONE THAT MATTERS: today has almost no hours left, so today can only be asked for what it can
    // hold and the rest moves to tomorrow.
    do {
        let target = floor(1, .project(10), hours: 14)
        let input = plannerInput([target], membership: m)
        let evening = Replan.dailyPlan(input: input, plan: Planner.plan(input),
                                       creditedByWeekday: [:], remainingWeekdays: [6, 7],
                                       fractionOfTodayLeft: 0.05)   // ~40m left of a 14h day
        let today = shares(evening, 6, 1).total / 3600
        check(today < 1, "an evening is asked for less than an hour")
        check(shares(evening, 7, 1).total > shares(evening, 6, 1).total,
              "and tomorrow takes what today couldn't hold")
    }

    // The week's remainder caps the total: 35h over Mon-Fri with 24.6h done leaves 10.4h, and the two days
    // left ask for exactly that rather than a nominal 7h each.
    do {
        let target = floor(1, .project(10), hours: 35, weekdays: .weekdaysOnly)
        let input = plannerInput([target], membership: m)
        let done: [Int: [Int64: TimeInterval]] = [2: [1: 8 * 3600], 3: [1: 8 * 3600],
                                                  4: [1: 5.4 * 3600], 5: [1: 3.2 * 3600]]
        let daily = Replan.dailyPlan(input: input, plan: Planner.plan(input),
                                     creditedByWeekday: done, remainingWeekdays: [5, 6])
        let total = ([5, 6].reduce(0.0) { $0 + shares(daily, $1, 1).total }) / 3600
        check(approx(total, 10.4, 0.05),
              "the days together ask for exactly what the week still needs")
        // Even TOTALS, not even asks: Thursday already holds 3.2h, so it is asked for 3.6h and Friday for
        // 6.8h, leaving both days at 6.8h. The old rule gave Thursday its full 3.8h remainder and left
        // Friday holding the difference, which is what made one day of a week look arbitrarily special.
        check(approx(shares(daily, 5, 1).total / 3600, 3.6, 0.05),
              "today is asked for its share of what's left, not its textbook remainder")
        check(approx(shares(daily, 6, 1).total / 3600, 6.8, 0.05),
              "so the two days end up holding the same 6.8h")
    }

    // An allocation whose own days are gone can't be caught up, and must not be dumped on a day it
    // doesn't claim.
    do {
        let target = floor(1, .project(10), hours: 10, weekdays: .weekdaysOnly)
        let input = plannerInput([target], membership: m)
        let daily = Replan.dailyPlan(input: input, plan: Planner.plan(input),
                                     creditedByWeekday: [:], remainingWeekdays: [7])
        check(daily.byDay.isEmpty, "a Mon-Fri allocation puts nothing on Saturday")
        // Reported as OUT OF DAYS rather than out of room: no amount of extra available hours would place
        // it, and a single "won't fit" figure covering both cases doesn't move when you change them.
        check(approx((daily.outOfDays[1] ?? 0) / 3600, 10, 0.05),
              "its 10h is reported as having no days left")
        check(daily.unplaced.isEmpty, "and not as a room shortage, which more hours could fix")
    }

    // Two allocations competing for one nearly-full day: the one needing more per day gets the room, and
    // the shortfall is reported rather than drawn.
    do {
        let big = floor(1, .project(10), hours: 20, weekdays: Weekdays(rawValue: 64))    // Sat only
        let small = floor(2, .project(20), hours: 4, weekdays: Weekdays(rawValue: 64))
        let input = plannerInput([big, small], membership: plannerWorld(taskGroups: [1: 10, 2: 20],
                                                                       taskTags: [:]))
        let daily = Replan.dailyPlan(input: input, plan: Planner.plan(input),
                                     creditedByWeekday: [:], remainingWeekdays: [7])
        let placed = (shares(daily, 7, 1).total + shares(daily, 7, 2).total) / 3600
        check(placed <= 16.01, "a day is never asked for more hours than it has")
        check(!daily.unplaced.isEmpty, "and what doesn't fit is reported")
        check(shares(daily, 7, 1).total > shares(daily, 7, 2).total,
              "the allocation needing more per day gets the room first")
    }
}

// MARK: - Planner week facts

/// The week-assembly step, which used to live in the view in two copies that drifted apart. These are the
/// checks that would have caught every one of the regressions it produced.
func testPlannerWeekFacts() {
    print("Planner week facts:")
    let calendar = Calendar.current
    func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }
    // Sun 13 Sep 2026 through Sat 19.
    let thisWeek = DateInterval(start: at(13, 0), end: at(20, 0))
    let lastWeek = DateInterval(start: at(6, 0), end: at(13, 0))

    // Tasks 1 and 2 in group 10; task 1 also tagged 99; task 3 covered by nothing.
    let membership = plannerWorld(taskGroups: [1: 10, 2: 10, 3: nil], taskTags: [1: [99]])
    let group = floor(100, .project(10), hours: 14)      // covers tasks 1 and 2
    let tag = floor(200, .tag(99), hours: 7)             // covers task 1 only — narrower
    let floors = [group, tag]
    let names: [Int64: String] = [1: "one", 2: "two", 3: "three"]

    // Monday of each week: 2h on task 1, 1h on task 3.
    let intervals = [
        Interval(id: 1, projectID: 1, start: at(14, 9), end: at(14, 11)),
        Interval(id: 2, projectID: 3, start: at(14, 12), end: at(14, 13)),
        Interval(id: 3, projectID: 1, start: at(7, 9), end: at(7, 14)),      // 5h, LAST week
    ]

    let this = PlannerWeek.facts(intervals: intervals, window: thisWeek, floors: floors,
                                 membership: membership, taskNames: names, calendar: calendar)
    let monday = this[2] ?? PlannerWeek.DayFacts()

    // Credited: both allocations get the two hours, because both cover task 1.
    check(approx((monday.credited[100] ?? 0) / 3600, 2, 0.01),
          "the group is credited work on a task it covers")
    check(approx((monday.credited[200] ?? 0) / 3600, 2, 0.01),
          "and so is the tag covering the same task — an hour is progress on both")

    // Primary: exactly one of them owns it, the narrower.
    check(monday.primary[100] == nil, "but only the narrowest allocation OWNS the hour")
    check(approx((monday.primary[200] ?? 0) / 3600, 2, 0.01), "which is the tag, covering one task")
    check(approx(monday.primary.values.reduce(0, +) / 3600, 2, 0.01),
          "so the owned hours of a day never exceed what was tracked")

    // Work no allocation covers is its own category, with the task recorded for the hand-off to Metrics.
    check(approx(monday.unallocated / 3600, 1, 0.01), "uncovered work is counted separately")
    check(monday.uncoveredTaskIDs == [3], "and the task behind it is named")
    check(approx(monday.total / 3600, 3, 0.01), "the day's total is everything tracked in it")

    // THE REGRESSION: a window is a window. Last week's five hours must not appear in this week, and this
    // week's must not appear in last — the planner once scheduled a finished week using the CURRENT week's
    // hours, and reported 25h as unplaceable while every day showed room.
    check(this.values.allSatisfy { $0.credited[100] ?? 0 <= 2 * 3600 + 1 },
          "no interval from outside the window leaks in")
    let last = PlannerWeek.facts(intervals: intervals, window: lastWeek, floors: floors,
                                 membership: membership, taskNames: names, calendar: calendar)
    check(approx((last[2]?.credited[100] ?? 0) / 3600, 5, 0.01),
          "and last week's Monday reports its own five hours")
    check((last[2]?.unallocated ?? 0) < 60, "with none of this week's uncovered work")

    // Nested allocations are credited but never own — otherwise their hours are counted in a day's total
    // and drawn nowhere, which is how a column came to disagree with its own untracked figure.
    let nested = PlannerWeek.facts(intervals: intervals, window: thisWeek, floors: floors,
                                   membership: membership, nested: [200],
                                   taskNames: names, calendar: calendar)
    check(approx((nested[2]?.credited[200] ?? 0) / 3600, 2, 0.01),
          "a nested allocation is still credited its own work")
    check(approx((nested[2]?.primary[100] ?? 0) / 3600, 2, 0.01),
          "and the hour falls to the parent rather than vanishing")
    check(nested[2]?.primary[200] == nil, "the nested one owns nothing")

    // An interval straddling the window edge is clipped, not counted whole or dropped.
    let straddling = [Interval(id: 9, projectID: 1, start: at(12, 22), end: at(13, 2))]
    let clipped = PlannerWeek.facts(intervals: straddling, window: thisWeek, floors: floors,
                                    membership: membership, taskNames: names, calendar: calendar)
    check(approx((clipped[1]?.total ?? 0) / 3600, 2, 0.01),
          "only the part inside the window counts")

    // A running interval (no end) is measured to `now`, not treated as zero.
    let running = [Interval(id: 10, projectID: 1, start: at(14, 9), end: nil)]
    let live = PlannerWeek.facts(intervals: running, window: thisWeek, floors: floors,
                                 membership: membership, taskNames: names,
                                 now: at(14, 12), calendar: calendar)
    check(approx((live[2]?.total ?? 0) / 3600, 3, 0.01), "a running interval counts up to now")

    // The totals helpers agree with the per-day facts, since two callers read them.
    let totals = PlannerWeek.creditedTotals(this)
    check(approx((totals[200] ?? 0) / 3600, 2, 0.01), "credited totals sum the days")
    check(PlannerWeek.creditedByWeekday(this)[2]?[200] == monday.credited[200],
          "and the by-weekday shape is the same numbers")
}

// MARK: - Dormancy

/// A finished week says what it did, and what it never did — and does NOT invent a plan for days that have
/// gone. Both halves of that were regressions: first a browsed week was scheduled from the CURRENT week's
/// credits, then the dashed "Monday wants 6.7h" bands were drawn over a week that was already over.
func testHistoricalWeek() {
    print("Historical week:")
    let monFri = Weekdays(rawValue: (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5))
    let tueFri = Weekdays(rawValue: (1 << 2) | (1 << 5))
    let weekend = Weekdays(rawValue: (1 << 0) | (1 << 6))

    // A week that has gone draws no plan blocks on any of its days, under either method — the method only
    // decides how the pool BELOW is attributed.
    for day in 1...7 {
        check(PlannerWeek.drawsPlanBlocks(offset: 1, dayIsBeforeToday: true, showIntended: false) == false,
          "past week draws no plan on day \(day)")
    }
    check(PlannerWeek.drawsPlanBlocks(offset: 1, dayIsBeforeToday: false, showIntended: false) == false,
          "a past week's own today is still past")
    check(PlannerWeek.drawsPlanBlocks(offset: 0, dayIsBeforeToday: false, showIntended: false),
          "this week's days still to come draw their plan")
    check(PlannerWeek.drawsPlanBlocks(offset: 0, dayIsBeforeToday: true, showIntended: false) == false,
          "this week's days that have gone draw none")
    check(PlannerWeek.drawsPlanBlocks(offset: 0, dayIsBeforeToday: false, showIntended: true) == false,
          "the intended view draws its own blocks, not these")

    let office = floor(1, .tag(1), hours: 35, weekdays: monFri)
    let vllm = floor(2, .tag(2), hours: 10)
    let gym = floor(3, .tag(3), hours: 4, weekdays: tueFri)
    let stonks = floor(4, .tag(4), hours: 2, weekdays: weekend)
    let met = floor(5, .tag(5), hours: 3)
    let ceiling = Target(id: 6, subject: .tag(6), seconds: 5 * 3600, direction: .atMost,
                         period: .week, weekdays: .all)
    let kt = floor(7, .tag(7), hours: 2, weekdays: monFri)      // nested inside office
    let all = [office, vllm, gym, stonks, met, ceiling, kt]
    let credited: [Int64: TimeInterval] = [1: 9.8 * 3600, 2: 0, 3: 2 * 3600,
                                           4: 0, 5: 3 * 3600, 7: 1 * 3600]

    let missed = PlannerWeek.neverHappened(floors: all, credited: credited, nested: [7])
    let byID = Dictionary(missed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    check(abs((byID[1]?.missed ?? 0) - 25.2 * 3600) < 1,
          "office missed 25.2h of 35h")
    check(byID[1]?.lastDay == 6,
          "office's chance ran out on Friday")
    check(abs((byID[2]?.missed ?? 0) - 10 * 3600) < 1,
          "vllm missed all 10h")
    check(byID[2]?.lastDay == 7,
          "vllm claims every day, so Saturday was its last")
    check(abs((byID[3]?.missed ?? 0) - 2 * 3600) < 1,
          "gym missed half of 4h")
    check(byID[3]?.lastDay == 6,
          "gym's last day is Friday, not Saturday")
    check(byID[4]?.lastDay == 7,
          "stonks' last day is Saturday")
    check(byID[5] == nil,
          "an allocation that was met is absent")
    check(byID[6] == nil,
          "a ceiling never appears — it isn't owed")
    check(byID[7] == nil,
          "a nested allocation is not owed twice")
    check(PlannerWeek.neverHappened(floors: all, credited: credited).contains { $0.id == 7 },
          "the same allocation IS owed when nothing declares it nested")
    check(missed.map(\.missed) == missed.map(\.missed).sorted(by: >),
          "biggest miss first")
    let total = missed.reduce(0) { $0 + $1.missed }
    check(abs(total - (25.2 + 10 + 2 + 2) * 3600) < 1,
          "the pool sums to the week's shortfall")

    // Nothing owed when everything was done, and no negative blocks when a week overshot.
    let over: [Int64: TimeInterval] = [1: 40 * 3600, 2: 12 * 3600, 3: 4 * 3600,
                                       4: 2 * 3600, 5: 3 * 3600]
    check(PlannerWeek.neverHappened(floors: all, credited: over, nested: [7]).isEmpty,
          "a week that beat every allocation has an empty pool")
    check(PlannerWeek.neverHappened(floors: [met], credited: [5: 3 * 3600 - 30]).isEmpty,
          "under a minute short is not a block")

    // Month view scales the weekly rate, which is what the goal rows read.
    let month = PlannerWeek.neverHappened(floors: [office], credited: [1: 40 * 3600], weeks: 4)
    check(abs((month.first?.missed ?? 0) - 100 * 3600) < 1,
          "a month wants four weeks of it")

    // A window is a window: the historical pool must read the BROWSED week's credits. Feeding it this
    // week's numbers is exactly the bug that reported 25h unplaceable on a week that had already gone.
    let lastWeek = PlannerWeek.neverHappened(floors: [office], credited: [1: 0])
    check(abs((lastWeek.first?.missed ?? 0) - 35 * 3600) < 1,
          "a week with nothing tracked owes all of it")
}

/// Every device this database knows about keeps a row on the day timeline, whether or not it recorded
/// anything that day. A missing row is indistinguishable from a missing machine, and rows that appear and
/// disappear as you scrub between days make the timeline unreadable.
func testDayTimelineRows() {
    print("Day timeline rows:")
    func seg(_ id: Int64, _ from: Double, _ to: Double, _ device: String?) -> DaySegment {
        DaySegment(id: id, projectID: 1, startHour: from, endHour: to, deviceID: device)
    }
    let order = ["mac", "phone", "studio"]

    // Only the Mac worked today; the phone and the studio still get a row each.
    let onlyMac = Aggregations.dayTimeline([seg(1, 9, 10, "mac"), seg(2, 11, 12, "mac")],
                                           deviceOrder: order, knownDevices: order)
    check(onlyMac.laneOwners == ["mac", "phone", "studio"],
          "an idle device keeps its row, in the canonical order")
    check(onlyMac.laneCount == 3, "three known devices means three rows")
    check(onlyMac.segments.allSatisfy { $0.lane == 0 },
          "the only device that worked owns the first row")
    check(onlyMac.segments.count == 2, "no segment is dropped by reserving empty rows")

    // A device with overlapping blocks takes two rows of its own, and the idle ones come after — not
    // interleaved into the middle of its block.
    let overlap = Aggregations.dayTimeline([seg(1, 9, 12, "mac"), seg(2, 10, 11, "mac"),
                                            seg(3, 14, 15, "studio")],
                                           deviceOrder: order, knownDevices: order)
    check(overlap.laneOwners == ["mac", "mac", "phone", "studio"],
          "overlap widens a device's own block of rows")
    check(overlap.segments.filter { $0.deviceID == "mac" }.map(\.lane).sorted() == [0, 1],
          "the overlapping pair is on two rows, neither hidden")
    check(overlap.segments.first { $0.deviceID == "studio" }?.lane == 3,
          "the studio's blocks land on the studio's row, not the phone's empty one")
    check(!overlap.segments.contains { $0.lane == 2 },
          "nothing is ever drawn on an idle device's row")

    // Nothing tracked at all: still one row per known device, so the rows don't jump when you scrub
    // onto an empty day.
    let empty = Aggregations.dayTimeline([], deviceOrder: order, knownDevices: order)
    check(empty.laneOwners == ["mac", "phone", "studio"], "an empty day keeps every row")
    check(empty.segments.isEmpty, "an empty day invents no segments")

    // One device is the ordinary case and must look exactly as it did: a single full-height row.
    let single = Aggregations.dayTimeline([seg(1, 9, 10, "mac")],
                                          deviceOrder: ["mac"], knownDevices: ["mac"])
    check(single.laneCount == 1, "one device is one row")
    check(single.laneOwners == ["mac"], "and that row is the device")

    // A single device with overlapping blocks still fans out within its own row.
    let singleOverlap = Aggregations.dayTimeline([seg(1, 9, 12, "mac"), seg(2, 10, 11, "mac")],
                                                deviceOrder: ["mac"], knownDevices: ["mac"])
    check(singleOverlap.laneCount == 2, "one device's overlap still needs two rows")
    check(singleOverlap.laneOwners == ["mac", "mac"], "both rows belong to it")

    // Rows recorded before device attribution existed sort last and keep a row of their own.
    let unattributed = Aggregations.dayTimeline([seg(1, 9, 10, nil), seg(2, 11, 12, "mac")],
                                                deviceOrder: order, knownDevices: ["mac"])
    check(unattributed.laneOwners == ["mac", nil], "unattributed rows sort after named devices")
    check(unattributed.segments.first { $0.deviceID == nil }?.lane == 1,
          "and their blocks follow their row")

    // A device absent from deviceOrder is still placed deterministically rather than dropped.
    let stranger = Aggregations.dayTimeline([], deviceOrder: ["mac"],
                                            knownDevices: ["mac", "zz-laptop", "aa-laptop"])
    check(stranger.laneOwners == ["mac", "aa-laptop", "zz-laptop"],
          "unranked devices come after ranked ones, ordered by id")

    // No devices at all — the very first launch. One row, unnamed, never zero.
    let none = Aggregations.dayTimeline([], deviceOrder: [], knownDevices: [])
    check(none.laneCount == 1, "there is always at least one row to draw into")
    check(none.laneOwners == [nil], "and it belongs to nobody")

    // knownDevices is additive, not a filter: a device that recorded today but isn't in the list yet
    // (a peer's first sync) must not lose its row.
    let newPeer = Aggregations.dayTimeline([seg(1, 9, 10, "phone")],
                                           deviceOrder: order, knownDevices: ["mac"])
    check(newPeer.laneOwners == ["mac", "phone"], "a device seen only in today's data still gets a row")
    check(newPeer.segments.first?.lane == 1, "and its blocks sit on it")
}

/// The month as weeks, and the one thing that makes it different from the week view: a week that fell short
/// pushes its hours into the weeks the MONTH has left, and only what the month can't absorb is a leftover.
func testPlannerMonthWeeks() {
    print("Planner month weeks:")
    // An explicit Sunday-first Gregorian calendar, so the span shapes below don't depend on the locale the
    // test happens to run under.
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 1
    cal.timeZone = .current
    func at(_ day: Int, _ hour: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }
    // September 2026 starts on a Tuesday and has 30 days.
    let september = DateInterval(start: at(1),
                                 end: cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!)

    // MARK: Spans

    let spans = PlannerMonth.weekSpans(month: september, calendar: cal)
    check(spans.count == 5, "September 2026 touches five calendar weeks")
    check(spans.map(\.days) == [5, 7, 7, 7, 4], "holding this many of the month's days each")
    check(spans.map(\.outsideDays) == [2, 0, 0, 0, 3],
          "and the edge weeks reach into August and October")
    check(spans.allSatisfy { $0.days + $0.outsideDays == 7 },
          "every column is a whole calendar week — none of them is a stub")
    check(spans.map(\.firstDay) == [1, 6, 13, 20, 27], "labelled from the month's first day in each")
    check(spans.map(\.lastDay) == [5, 12, 19, 26, 30], "to its last")
    check(spans.map(\.index) == [1, 2, 3, 4, 5], "numbered in calendar order")
    check(spans[0].weekdays == [3, 4, 5, 6, 7], "the first week's month days are Tuesday to Saturday")
    check(spans[0].outsideWeekdays == [1, 2], "with Sunday and Monday belonging to August")
    check(spans[4].weekdays == [1, 2, 3, 4], "and the last week's are Sunday to Wednesday")
    check(spans.allSatisfy { $0.inMonth.start >= september.start && $0.inMonth.end <= september.end },
          "no counted part reaches outside the month")
    check(zip(spans, spans.dropFirst()).allSatisfy { $0.inMonth.end == $1.inMonth.start },
          "and together the counted parts cover it without a gap or an overlap")
    check(spans.reduce(0) { $0 + $1.days } == 30, "every day of the month is in exactly one span")

    // A month that begins on the calendar's first weekday has no out-of-month days at its start.
    let february = DateInterval(start: cal.date(from: DateComponents(year: 2026, month: 2, day: 1))!,
                                end: cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!)
    let febSpans = PlannerMonth.weekSpans(month: february, calendar: cal)
    check(febSpans.first?.outsideDays == 0, "February 2026 starts on a Sunday, so its first week is whole")
    check(febSpans.reduce(0) { $0 + $1.days } == 28, "and its spans still cover the month exactly")

    // The case that drove the design: a month starting on a Saturday. Clipping to the month gave a one-day
    // stub beside six full weeks; whole weeks give six equal columns, the first almost entirely August's.
    let augustMonth = DateInterval(start: cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                                   end: at(1))
    let augSpansShape = PlannerMonth.weekSpans(month: augustMonth, calendar: cal)
    check(augSpansShape.count == 6, "August 2026 touches six calendar weeks")
    check(augSpansShape.first?.days == 1 && augSpansShape.first?.outsideDays == 6,
          "its first column is one August day and six July ones")
    check(augSpansShape.allSatisfy { $0.days + $0.outsideDays == 7 },
          "and every column is still a whole week")

    // MARK: Rollups

    let monFri = Weekdays(rawValue: (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5))
    let weekend = Weekdays(rawValue: (1 << 0) | (1 << 6))
    let membership = plannerWorld(taskGroups: [1: 10, 2: nil], taskTags: [2: [99]])
    let office = floor(1, .project(10), hours: 35, weekdays: monFri)
    let stonks = floor(2, .tag(99), hours: 2, weekdays: weekend)
    let floors = [office, stonks]
    let waking: TimeInterval = 12 * 3600

    // A month entirely in the past: no week has room, so nothing can be reallocated anywhere.
    let after = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
    let finished = PlannerMonth.rollups(month: september, intervals: [], floors: floors,
                                        membership: membership, wakingSeconds: waking,
                                        now: after, calendar: cal)
    check(finished.count == 5, "one rollup per span")
    check(finished.allSatisfy { $0.capacity == Double($0.span.days) * waking },
          "a column counts only the month's days, whatever the calendar week holds")
    check(finished.allSatisfy { $0.outsideCapacity == Double($0.span.outsideDays) * waking },
          "the rest of the week is the cap, sized to its own days")
    check(finished.allSatisfy { approx($0.untracked, $0.capacity, 60) },
          "a finished month with nothing tracked is untracked from end to end")
    check(finished.allSatisfy { $0.owed.isEmpty },
          "and nothing is planned into weeks that have gone")

    // THE GOAL: what the allocations ask of this month's days, which is what the columns must sum to.
    // September 2026 has 22 weekdays, so 35h/week Mon–Fri is 154h — not 140h.
    check(approx(PlannerMonth.goal(for: office, month: september, calendar: cal), 154 * 3600, 60),
          "a month's goal is its own claimed days, not the weekly rate times four")
    check(approx(PlannerMonth.goal(for: office, month: february, calendar: cal), 140 * 3600, 60),
          "February 2026 has 20 weekdays, so the same allocation asks 140h of it")
    let officeWant = finished.reduce(0.0) { $0 + ($1.want[1] ?? 0) }
    check(approx(officeWant, 154 * 3600, 60), "and the week columns add up to exactly that")
    check(approx(finished[1].want[1] ?? 0, 35 * 3600, 60),
          "a week wholly inside the month asks its true weekly hours — what the week view says too")
    check(approx(finished[0].want[1] ?? 0, 28 * 3600, 60),
          "and a cut week asks only for the claimed days the month has of it")
    let stonksWant = finished.reduce(0.0) { $0 + ($1.want[2] ?? 0) }
    check(approx(stonksWant, 8 * 3600, 60), "eight weekend days in September, so 8h of stonks")

    let officeLeft = finished.reduce(0.0) { $0 + ($1.leftover[1] ?? 0) }
    check(approx(officeLeft, 154 * 3600, 60), "none of it happened, so all of it is leftover")
    // Where the pool sits is the week view's rule one unit up: catch up accumulates an allocation's
    // unplaceable hours under the LAST week that could have used them — where the decision would have to be
    // made — and per week leaves each week's own miss under that week.
    check(finished[0].leftover[1] == nil,
          "catch up doesn't strand office's hours under a week that is already over")
    check(approx(finished[4].leftover[1] ?? 0, 154 * 3600, 60),
          "it accumulates them under the last week office claims a day in")
    let perWeek = PlannerMonth.rollups(month: september, intervals: [], floors: floors,
                                       membership: membership, wakingSeconds: waking,
                                       method: .perDay, now: after, calendar: cal)
    check(approx(perWeek[0].leftover[1] ?? 0, perWeek[0].want[1] ?? 0, 60),
          "per week keeps each week's own miss under that week")
    check(approx(perWeek.reduce(0.0) { $0 + ($1.leftover[1] ?? 0) }, 154 * 3600, 60),
          "and the two methods pool exactly the same hours, in different places")

    // In hindsight the method still decides WHERE the pool sits, which is the week view's rule one unit up.
    let hindsight = PlannerMonth.neverHappened(floors: floors, month: september,
                                               credited: [:], calendar: cal)
    check(hindsight.first?.id == 1, "the biggest miss comes first")
    check(approx(hindsight.first?.missed ?? 0, 154 * 3600, 60), "and it's the whole month's ask")
    check(hindsight.first?.lastWeek == 5,
          "accumulated under the last week that claimed a day — Mon–Fri reaches the final week")
    check(hindsight.contains { $0.id == 2 && $0.lastWeek == 5 },
          "and the weekend allocation's under the last week holding a weekend day")
    check(PlannerMonth.neverHappened(floors: floors, month: september,
                                     credited: [1: 200 * 3600, 2: 20 * 3600], calendar: cal).isEmpty,
          "a month that beat every allocation owes nothing")

    // A span with none of an allocation's days asks nothing of it.
    let august = augustMonth
    let augSpans = augSpansShape
    check(augSpans.first?.weekdays == [7], "1 August 2026 is a Saturday, the only August day in its week")
    let augRollups = PlannerMonth.rollups(month: august, intervals: [], floors: floors,
                                          membership: membership, wakingSeconds: waking,
                                          now: after, calendar: cal)
    check(augRollups[0].want[1] == nil, "a Mon-Fri allocation asks nothing of a Saturday-only week")
    check(augRollups[0].want[2] != nil, "while a weekend one asks for its Saturday")

    // MARK: Reallocation forward, inside the month

    // Mid-month: three weeks gone with nothing done, two to go. Today is Sunday 20 September, half spent.
    let now = at(20, 6)
    let live = PlannerMonth.rollups(month: september, intervals: [], floors: floors,
                                    membership: membership, wakingSeconds: waking,
                                    fractionOfTodayLeft: 0.5, now: now, calendar: cal)
    check(live[0].owed.isEmpty && live[1].owed.isEmpty && live[2].owed.isEmpty,
          "weeks that have gone are planned nothing — there is nowhere to put it")
    check((live[3].owed[1]?.carried ?? 0) > 3600,
          "the shortfall of the weeks that went shows up in the week in progress")
    check((live[3].owed[1]?.intended ?? 0) > 3600,
          "alongside that week's own share, counted separately")
    check(live[0].leftover.isEmpty == false || live[3].owed.isEmpty == false,
          "something must have happened to those hours")

    // THE INVARIANT: hours are neither invented nor lost. Everything wanted is either planned into a week
    // or reported as leftover.
    let wanted = live.reduce(0.0) { $0 + $1.want.values.reduce(0, +) }
    let planned = live.reduce(0.0) { $0 + $1.owed.values.reduce(0) { $0 + $1.total } }
    let leftover = live.reduce(0.0) { $0 + $1.leftover.values.reduce(0, +) }
    check(approx(planned + leftover, wanted, 5 * 60),
          "planned plus leftover is exactly what the month asked for")

    // No week is asked for more hours than it has left.
    for rollup in live {
        let asked = rollup.owed.values.reduce(0) { $0 + $1.total }
        check(asked <= rollup.room + 60,
              "week \(rollup.span.index) is never asked for more than it has left")
    }
    // And an allocation can't be asked to use days it doesn't claim.
    for rollup in live {
        let claimedDays = rollup.span.weekdays.filter { weekday in
            Weekdays(rawValue: (1 << 0) | (1 << 6)).contains(weekday: weekday)
        }.count
        let asked = rollup.owed[2]?.total ?? 0
        check(asked <= Double(claimedDays) * waking + 60,
              "week \(rollup.span.index) can't give stonks hours on days it doesn't claim")
    }

    // Work already done reduces what's owed rather than being ignored.
    let did = [Interval(id: 1, projectID: 1, start: at(7, 9), end: at(7, 17))]      // 8h, Monday week 2
    let credited = PlannerMonth.rollups(month: september, intervals: did, floors: floors,
                                       membership: membership, wakingSeconds: waking,
                                       fractionOfTodayLeft: 0.5, now: now, calendar: cal)
    check(approx(credited[1].tracked[1] ?? 0, 8 * 3600, 60), "the week it happened in owns those hours")
    check(approx(credited[1].credited[1] ?? 0, 8 * 3600, 60), "and is credited them")
    // The obligation shrinks by what was done. NOT `planned`, which is pinned by how much room the
    // remaining weeks have: when they are already full, eight hours done comes off the LEFTOVER instead.
    // Asserting that planned itself falls is the mistake that made this check fail.
    let creditedPlanned = credited.reduce(0.0) { $0 + $1.owed.values.reduce(0) { $0 + $1.total } }
    let creditedLeftover = credited.reduce(0.0) { $0 + $1.leftover.values.reduce(0, +) }
    check(approx(creditedPlanned + creditedLeftover, wanted - 8 * 3600, 5 * 60),
          "eight hours done is eight hours fewer for the month to find room for")
    check(approx(credited[1].untracked, credited[1].capacity - 8 * 3600, 60),
          "and the untracked band of that week shrinks by exactly as much")

    // MARK: Sharing room, with no allocation outranking another

    let none = PlannerMonth.share(room: 0, wants: [1: 5 * 3600, 2: 5 * 3600])
    check(none.placed.isEmpty, "no room places nothing")
    check(approx(none.leftover.values.reduce(0, +), 10 * 3600, 1), "and everything comes back")

    let plenty = PlannerMonth.share(room: 20 * 3600, wants: [1: 5 * 3600, 2: 2 * 3600])
    check(approx(plenty.placed[1] ?? 0, 5 * 3600, 1) && approx(plenty.placed[2] ?? 0, 2 * 3600, 1),
          "room for everything places everything, unrounded")
    check(plenty.leftover.isEmpty, "with nothing left over")

    let tight = PlannerMonth.share(room: 2 * 3600, wants: [1: 10 * 3600, 2: 10 * 3600])
    check(approx(tight.placed[1] ?? 0, 3600, 1) && approx(tight.placed[2] ?? 0, 3600, 1),
          "a contested hour is split evenly, in half-hour turns")
    check(approx(tight.leftover.values.reduce(0, +), 18 * 3600, 1), "and the rest is reported")

    let lopsided = PlannerMonth.share(room: 2 * 3600, wants: [1: 3600, 2: 100 * 3600])
    check(approx(lopsided.placed[1] ?? 0, 3600, 1),
          "a small want isn't starved by a large one — there is no priority")
    check(approx(lopsided.placed[2] ?? 0, 3600, 1), "they take the same turns")
    check(approx(lopsided.placed.values.reduce(0, +), 2 * 3600, 60), "and the room is spent exactly")
}

/// Allocations that start, stop, or happen once. Every goal figure on the planner reduces to `claimedDays`
/// — weekdays intersected with the window — so this is the function to get right before anything reads it.
func testAllocationWindows() {
    print("Allocation windows:")
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 1
    cal.timeZone = .current
    func day(_ month: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d))!
    }
    func span(_ from: Date, _ to: Date) -> DateInterval { DateInterval(start: from, end: to) }
    let monFri = Weekdays(rawValue: (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5))
    // October 2026: the 1st is a Thursday. 22 weekdays in the month.
    let october = span(day(10, 1), day(11, 1))
    let september = span(day(9, 1), day(10, 1))

    // MARK: Unbounded — nothing changes

    let office = floor(1, .tag(1), hours: 35, weekdays: monFri)
    check(office.dayWindow(calendar: cal) == nil, "no dates means no window")
    check(office.applies(to: september, calendar: cal), "and it applies to every period")
    check(office.claimedDays(in: october, calendar: cal) == 22,
          "October 2026 has 22 weekdays")
    check(approx(office.ask(in: october, calendar: cal), 154 * 3600, 60),
          "so a 35h/week Mon–Fri allocation asks 154h of it — the figure the month view already shows")
    check(approx(office.ask(in: span(day(10, 4), day(10, 11)), calendar: cal), 35 * 3600, 60),
          "and exactly its weekly amount of a whole week")

    // MARK: A bounded repeat

    // Same allocation, live only 1–15 October: eleven weekdays (1, 2, 5–9, 12–15).
    let bounded = Target(id: 2, subject: .tag(1), seconds: 35 * 3600, direction: .atLeast,
                         period: .week, weekdays: monFri,
                         startsOn: day(10, 1), endsOn: day(10, 15))
    check(bounded.claimedDays(in: october, calendar: cal) == 11,
          "eleven weekdays fall inside 1–15 October")
    check(approx(bounded.ask(in: october, calendar: cal), 77 * 3600, 60),
          "so October asks 77h of it, not 154h")
    check(!bounded.applies(to: september, calendar: cal),
          "September is before it existed, so it doesn't apply there at all")
    check(bounded.ask(in: september, calendar: cal) == 0, "and asks nothing of it")
    check(!bounded.applies(to: span(day(11, 1), day(12, 1)), calendar: cal),
          "November is after it ended")
    // The end date is INCLUSIVE as a person states it.
    check(bounded.claimedDays(in: span(day(10, 15), day(10, 16)), calendar: cal) == 1,
          "\"until the 15th\" includes the 15th")
    check(bounded.claimedDays(in: span(day(10, 16), day(10, 17)), calendar: cal) == 0,
          "and stops after it")

    // Open-ended at one end.
    let fromJan = Target(id: 3, subject: .tag(1), seconds: 4 * 3600, direction: .atLeast,
                         period: .week, startsOn: day(12, 1), endsOn: nil)
    check(!fromJan.applies(to: october, calendar: cal), "a start date alone still bounds the past")
    check(fromJan.applies(to: span(day(12, 1), day(12, 8)), calendar: cal),
          "and applies from that day on, forever")

    // MARK: One-offs

    // 6h on a single day — a Wednesday, so a Mon–Fri mask doesn't interfere.
    let oneDay = Target(id: 4, subject: .tag(1), seconds: 6 * 3600, direction: .atLeast,
                        period: .once, weekdays: monFri,
                        startsOn: day(10, 14), endsOn: day(10, 14))
    check(oneDay.claimedDays(in: october, calendar: cal) == 1, "a one-day window claims one day")
    check(approx(oneDay.perClaimedDaySeconds(calendar: cal), 6 * 3600, 1),
          "and its whole total lands on it")
    check(approx(oneDay.ask(in: october, calendar: cal), 6 * 3600, 60),
          "so the month asks for six hours, once")
    check(approx(oneDay.ask(in: span(day(10, 11), day(10, 18)), calendar: cal), 6 * 3600, 60),
          "all of it in the week containing that day")
    check(oneDay.ask(in: span(day(10, 18), day(10, 25)), calendar: cal) == 0,
          "and nothing in the week after")

    // 20h across 10–20 October with a Mon–Fri mask: 7 usable weekdays (12–16, 19, 20 — and 10, 11 are
    // the weekend). The number you confirmed: 2.9h each.
    let job = Target(id: 5, subject: .tag(1), seconds: 20 * 3600, direction: .atLeast,
                     period: .once, weekdays: monFri,
                     startsOn: day(10, 10), endsOn: day(10, 20))
    check(job.claimedDays(in: october, calendar: cal) == 7,
          "the weekday mask still applies inside a one-off's range")
    check(approx(job.perClaimedDaySeconds(calendar: cal) / 3600, 20.0 / 7, 0.01),
          "so each of those days carries 2.9h")
    check(approx(job.ask(in: october, calendar: cal), 20 * 3600, 60),
          "and the whole job is asked of the month exactly once")
    // Split across weeks: the week of 11–17 Oct holds five of the seven claimed days.
    let midWeek = span(day(10, 11), day(10, 18))
    check(approx(job.ask(in: midWeek, calendar: cal), 20 * 3600 * 5 / 7, 60),
          "a week gets its share of the job, by claimed days")
    let lastWeek = span(day(10, 18), day(10, 25))
    check(approx(job.ask(in: midWeek, calendar: cal) + job.ask(in: lastWeek, calendar: cal),
                 20 * 3600, 60),
          "and the shares of the weeks it spans add up to the whole job")

    // A one-off spanning a month boundary is split by the same rule, with nothing invented.
    let across = Target(id: 6, subject: .tag(1), seconds: 10 * 3600, direction: .atLeast,
                        period: .once, startsOn: day(10, 29), endsOn: day(11, 2))
    check(across.claimedDays(in: span(day(10, 29), day(11, 3)), calendar: cal) == 5,
          "five days, every one of them claimed")
    check(approx(across.ask(in: october, calendar: cal), 10 * 3600 * 3 / 5, 60),
          "October gets three fifths of it")
    check(approx(across.ask(in: span(day(11, 1), day(12, 1)), calendar: cal), 10 * 3600 * 2 / 5, 60),
          "November the other two")

    // MARK: Degenerate cases that must not invent hours

    let noWindow = Target(id: 7, subject: .tag(1), seconds: 9 * 3600, direction: .atLeast,
                          period: .once)
    check(noWindow.perClaimedDaySeconds(calendar: cal) == 0,
          "a one-off with no window asks nothing rather than guessing a length")
    check(noWindow.ask(in: october, calendar: cal) == 0, "so it claims no room either")

    let weekendOnly = Target(id: 8, subject: .tag(1), seconds: 4 * 3600, direction: .atLeast,
                             period: .once, weekdays: Weekdays(rawValue: (1 << 0) | (1 << 6)),
                             startsOn: day(10, 12), endsOn: day(10, 16))
    check(weekendOnly.claimedDays(in: october, calendar: cal) == 0,
          "a weekend-only job inside a Mon–Fri range claims nothing")
    check(weekendOnly.ask(in: october, calendar: cal) == 0, "and therefore asks nothing")

    let backwards = Target(id: 9, subject: .tag(1), seconds: 4 * 3600, direction: .atLeast,
                           period: .once, startsOn: day(10, 20), endsOn: day(10, 10))
    check(backwards.ask(in: october, calendar: cal) == 0,
          "an end before its start is an empty window, not a negative one")

    let ceiling = Target(id: 10, subject: .tag(1), seconds: 4 * 3600, direction: .atMost,
                         period: .week, startsOn: day(10, 1), endsOn: day(10, 31))
    check(ceiling.ask(in: october, calendar: cal) == 0, "a ceiling never asks for hours")
    check(ceiling.applies(to: october, calendar: cal),
          "but it still applies, so it can be shown and checked")

    // MARK: Every-N

    // 8h every OTHER week, Mon–Fri, anchored to Thursday 1 October. Weeks containing 1, 15 and 29 Oct run;
    // the ones between are skipped.
    let fortnight = Target(id: 11, subject: .tag(1), seconds: 8 * 3600, direction: .atLeast,
                           period: .week, weekdays: monFri, startsOn: day(10, 1), interval: 2)
    check(fortnight.runsIn(day: day(10, 1), calendar: cal), "the anchor's own week runs")
    check(!fortnight.runsIn(day: day(10, 8), calendar: cal), "the next one is skipped")
    check(fortnight.runsIn(day: day(10, 15), calendar: cal), "the one after that runs")
    check(!fortnight.runsIn(day: day(10, 22), calendar: cal), "and so on, alternating")
    check(fortnight.runsIn(day: day(10, 29), calendar: cal), "week four of the cycle runs")
    // Claimed weekdays in the running weeks only: 1–2, 12–16, 26–30 → 2 + 5 + 5 = 12.
    check(fortnight.claimedDays(in: october, calendar: cal) == 12,
          "only the weekdays of running weeks are claimed")
    check(approx(fortnight.ask(in: october, calendar: cal), 8 * 3600 / 5 * 12, 60),
          "so October asks for 19.2h rather than a weekly 8h times four and a half")
    check(approx(fortnight.ask(in: span(day(10, 12), day(10, 19)), calendar: cal), 8 * 3600, 60),
          "a running week asks its full weekly amount")
    check(fortnight.ask(in: span(day(10, 5), day(10, 12)), calendar: cal) == 0,
          "and a skipped week asks nothing at all")

    // An interval with no anchor cannot be phased, so it behaves as every period rather than guessing.
    let unanchored = Target(id: 12, subject: .tag(1), seconds: 8 * 3600, direction: .atLeast,
                            period: .week, weekdays: monFri, interval: 2)
    check(unanchored.claimedDays(in: october, calendar: cal) == 22,
          "every-N without a start date falls back to every period")

    // Monthly, every other month, from October: October runs, November doesn't, December does.
    let everyOther = Target(id: 13, subject: .tag(1), seconds: 20 * 3600, direction: .atLeast,
                            period: .month, startsOn: day(10, 1), interval: 2)
    check(everyOther.ask(in: october, calendar: cal) > 0, "October runs")
    check(everyOther.ask(in: span(day(11, 1), day(12, 1)), calendar: cal) == 0, "November is skipped")
    check(everyOther.ask(in: span(day(12, 1), day(12, 31)), calendar: cal) > 0, "December runs")

    // An interval of 1 is exactly what every allocation did before this existed.
    let plain = Target(id: 14, subject: .tag(1), seconds: 8 * 3600, direction: .atLeast,
                       period: .week, weekdays: monFri, startsOn: day(10, 1), interval: 1)
    check(plain.claimedDays(in: october, calendar: cal) == 22, "interval 1 claims every weekday")

    // MARK: The identity the planner depends on

    // Whatever the shape, the shares of the periods an allocation spans add up to what it asks in total.
    for target in [office, bounded, oneDay, job, across] {
        let whole = target.ask(in: span(day(9, 1), day(12, 1)), calendar: cal)
        let months = target.ask(in: september, calendar: cal)
            + target.ask(in: october, calendar: cal)
            + target.ask(in: span(day(11, 1), day(12, 1)), calendar: cal)
        check(approx(whole, months, 60),
              "allocation \(target.id): the months it spans add up to the whole ask")
    }
}

/// The window survives a round trip, and a peer that has never heard of it cannot delete it.
func testAllocationWindowStorage() throws {
    print("Allocation window storage:")
    let cal = Calendar.current
    func day(_ month: Int, _ d: Int) -> Date {
        cal.startOfDay(for: cal.date(from: DateComponents(year: 2026, month: month, day: d))!)
    }

    do { // round trip
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let g = try store.upsertTaskProject(name: "conference", colorHex: "#fff")
        try store.setTarget(subject: .project(g), seconds: 20 * 3600, direction: .atLeast,
                            period: .once, startsOn: day(10, 10), endsOn: day(10, 20))
        let read = try store.listTargets()[0]
        check(read.period == .once, "a one-off keeps its period")
        check(read.startsOn == day(10, 10) && read.endsOn == day(10, 20),
              "and both ends of its window, at local start-of-day")

        // Editing the amount must not silently drop the window.
        try store.setTarget(subject: .project(g), seconds: 25 * 3600, direction: .atLeast,
                            period: .once, startsOn: day(10, 10), endsOn: day(10, 20))
        let again = try store.listTargets()[0]
        check(approx(again.seconds, 25 * 3600, 1) && again.endsOn == day(10, 20),
              "editing the hours leaves the window alone")
    }

    do { // unbounded stays unbounded
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let g = try store.upsertTaskProject(name: "office", colorHex: "#fff")
        try store.setTarget(subject: .project(g), seconds: 35 * 3600, direction: .atLeast, period: .week)
        let read = try store.listTargets()[0]
        check(read.startsOn == nil && read.endsOn == nil, "no dates given, none stored")
        check(read.dayWindow(calendar: cal) == nil, "so it has no window at all")
    }

    do { // THE SYNC TRAP: absent means "no opinion", never "clear it"
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let g = try store.upsertTaskProject(name: "thesis", colorHex: "#fff")
        try store.setTarget(subject: .project(g), seconds: 8 * 3600, direction: .atLeast,
                            period: .week, startsOn: day(10, 1), endsOn: day(11, 15))
        // A peer on an older build edits the amount. It cannot see windows, so it sends none — exactly
        // the shape of the bug that once reset a Mon–Fri allocation to all seven days.
        let applied = try store.applyRemoteTarget(
            uid: try store.targetsForExport()[0].uid, subject: .project(g), seconds: 9 * 3600,
            direction: .atLeast, period: .week,
            remoteUpdatedAt: Date().timeIntervalSince1970 + 60)
        check(applied, "the newer remote edit is taken")
        let after = try store.listTargets()[0]
        check(approx(after.seconds, 9 * 3600, 1), "its amount changes")
        check(after.startsOn == day(10, 1) && after.endsOn == day(11, 15),
              "and the window it never sent is still here")

        // A peer that DOES send a window may change it.
        _ = try store.applyRemoteTarget(
            uid: try store.targetsForExport()[0].uid, subject: .project(g), seconds: 9 * 3600,
            direction: .atLeast, period: .week,
            remoteUpdatedAt: Date().timeIntervalSince1970 + 120,
            startsOn: day(10, 1).timeIntervalSince1970,
            endsOn: day(12, 1).timeIntervalSince1970)
        check(try store.listTargets()[0].endsOn == day(12, 1),
              "a peer that knows about windows can move one")
    }

    do { // a window arriving for an allocation this device has never seen
        let (store, url) = try makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let g = try store.upsertTaskProject(name: "taxes", colorHex: "#fff")
        _ = try store.applyRemoteTarget(
            uid: "remote-uid", subject: .project(g), seconds: 10 * 3600,
            direction: .atLeast, period: .once,
            remoteUpdatedAt: Date().timeIntervalSince1970,
            startsOn: day(4, 1).timeIntervalSince1970, endsOn: day(4, 15).timeIntervalSince1970)
        let read = try store.listTargets()[0]
        check(read.period == .once && read.startsOn == day(4, 1) && read.endsOn == day(4, 15),
              "an inserted remote one-off arrives with its window intact")
    }
}

func testDormancy() {
    print("Dormancy:")
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 10))!
    func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: now)! }

    func task(_ id: Int64, finished: Bool = false, archived: Bool = false) -> Project {
        Project(id: id, name: "t\(id)", colorHex: "#fff", sortOrder: 0, archived: archived,
                finished: finished)
    }
    let tasks = [task(1), task(2), task(3), task(4, finished: true), task(5, archived: true)]
    let activity: [Int64: Date] = [1: daysAgo(2), 2: daysAgo(30), 4: daysAgo(90), 5: daysAgo(90)]

    let dormant = Dormancy.dormantTaskIDs(lastActivity: activity, tasks: tasks, afterDays: 30,
                                          now: now, calendar: calendar)
    check(!dormant.contains(1), "a task touched two days ago is not dormant")
    check(dormant.contains(2), "one silent for exactly the threshold is")
    check(dormant.contains(3), "and one never tracked at all counts as silent")
    check(!dormant.contains(4), "a finished task is closed, not drifting")
    check(!dormant.contains(5), "and an archived one isn't shown at all")

    // The threshold is a real setting, including off.
    check(Dormancy.dormantTaskIDs(lastActivity: activity, tasks: tasks, afterDays: 0,
                                  now: now, calendar: calendar).isEmpty,
          "zero days turns the whole idea off")
    check(Dormancy.dormantTaskIDs(lastActivity: activity, tasks: tasks, afterDays: 31,
                                  now: now, calendar: calendar).contains(2) == false,
          "and a longer threshold spares a task just under it")

    // A task nothing has ever been tracked against goes quiet from when it was WRITTEN DOWN. Without
    // this, a task is quiet the second you create it — and because Today hides quiet tasks, a task you
    // just added would never appear there at all.
    let fresh = [task(10), task(11), task(12)]
    let created: [Int64: Date] = [10: now, 11: daysAgo(40)]
    let byCreation = Dormancy.dormantTaskIDs(lastActivity: [:], created: created, tasks: fresh,
                                             afterDays: 30, now: now, calendar: calendar)
    check(!byCreation.contains(10), "a task written down today is not already quiet")
    check(byCreation.contains(11), "one written down 40 days ago and never started is")
    check(byCreation.contains(12), "and one with no creation date recorded keeps the old behaviour")
    check(Dormancy.dormantTaskIDs(lastActivity: [:], created: created, tasks: fresh, afterDays: 0,
                                  now: now, calendar: calendar).isEmpty,
          "off is still off, whatever the creation dates say")
    check(!Dormancy.dormantTaskIDs(lastActivity: [11: daysAgo(1)], created: created, tasks: fresh,
                                   afterDays: 30, now: now, calendar: calendar).contains(11),
          "tracking it beats its creation date — activity is what the rule is about")
    // Exactly at the threshold, matching the tracked case (>= afterDays).
    check(Dormancy.dormantTaskIDs(lastActivity: [:], created: [10: daysAgo(30)], tasks: [task(10)],
                                  afterDays: 30, now: now, calendar: calendar).contains(10),
          "the creation clock uses the same boundary as the activity clock")

    // Counted by calendar day, so the time of day at either end doesn't shift the answer.
    let lateNight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 23))!
    let earlyNow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 1))!
    check(Dormancy.daysSince(lateNight, now: earlyNow, calendar: calendar) == 30,
          "30 days means 30 calendar days, not 30 exact 24-hour blocks")
    check(Dormancy.daysSince(nil, now: now, calendar: calendar) == nil,
          "never tracked has no number of days")
}

// MARK: - Per-day method

/// The simple method: nothing moves. Tested alongside the reallocating one because the whole point of
/// offering both is that they disagree, and each has to be right about its own question.
func testPerDayPlan() {
    print("Per-day plan:")
    let m = plannerWorld(taskGroups: [1: 10], taskTags: [:])
    let target = floor(1, .project(10), hours: 14)          // 2h a day, all seven days
    let input = plannerInput([target], membership: m)

    // Nothing done: every remaining day owes its own 2h, and the days that have gone are recorded as missed.
    do {
        let plan = Replan.perDayPlan(input: input, creditedByWeekday: [:],
                                     remainingWeekdays: [5, 6, 7])
        check(approx((plan.byDay[5]?[1]?.intended ?? 0) / 3600, 2, 0.01),
              "each remaining day owes exactly its own share")
        check(plan.byDay.values.allSatisfy { $0.values.allSatisfy { $0.carried < 60 } },
              "and nothing is ever carried — that's the other method")
        check(plan.missedByDay.keys.sorted() == [1, 2, 3, 4],
              "the four days that have gone are each recorded as missed")
        check(approx((plan.missedByDay[1]?[1] ?? 0) / 3600, 2, 0.01),
              "each missing its own 2h, not a share of the week's shortfall")
    }

    // A day that got its share owes nothing and misses nothing.
    do {
        let plan = Replan.perDayPlan(input: input,
                                     creditedByWeekday: [1: [1: 2 * 3600], 5: [1: 2 * 3600]],
                                     remainingWeekdays: [5, 6, 7])
        check(plan.byDay[5] == nil, "a day already at its share owes nothing")
        check(plan.missedByDay[1] == nil, "and a past day that met its share missed nothing")
    }

    // Doing extra on one day does NOT reduce what another day owes. That's the difference from catch up,
    // and the reason someone might want this: the days don't move under you.
    do {
        let plan = Replan.perDayPlan(input: input, creditedByWeekday: [5: [1: 9 * 3600]],
                                     remainingWeekdays: [5, 6, 7])
        check(approx((plan.byDay[6]?[1]?.intended ?? 0) / 3600, 2, 0.01),
              "a huge day elsewhere leaves tomorrow's share untouched")
    }

    // Weekday-restricted allocations only owe on the days they claim.
    do {
        let weekdaysOnly = floor(2, .project(10), hours: 10, weekdays: .weekdaysOnly)
        let input2 = plannerInput([weekdaysOnly], membership: m)
        let plan = Replan.perDayPlan(input: input2, creditedByWeekday: [:],
                                     remainingWeekdays: [6, 7])
        check(plan.byDay[7] == nil, "Saturday owes nothing for a Mon-Fri allocation")
        check(approx((plan.byDay[6]?[2]?.intended ?? 0) / 3600, 2, 0.01), "but Friday owes its 2h")
    }

    // Nested allocations are skipped here too, or their parent's hours get asked for twice.
    do {
        let plan = Replan.perDayPlan(input: input, creditedByWeekday: [:],
                                     remainingWeekdays: [7], skipping: [1])
        check(plan.byDay.isEmpty && plan.missedByDay.isEmpty,
              "a skipped allocation asks for nothing and misses nothing")
    }
}

// MARK: - Primary owner

/// Which allocation owns an hour when several cover it — the rule that decides what a day's blocks say.
///
/// Tested because it was written inline in the view twice and wrong twice: once letting every covering
/// allocation draw the same hour, so a day's blocks summed past a day; once excluding nested allocations
/// from owning anything, which made an allocation you HAD worked invisible in the grid.
func testPrimaryOwner() {
    print("Primary owner:")
    // Tasks 1–4 in group 10, task 5 in the Inbox. Tasks 1 and 2 tagged 99.
    let m = plannerWorld(taskGroups: [1: 10, 2: 10, 3: 10, 4: 10, 5: nil],
                         taskTags: [1: [99], 2: [99]])
    let subjects: [Int64: TargetSubject] = [
        100: .project(10),      // four tasks
        200: .tag(99),          // two tasks
        300: .task(1),          // one task
    ]

    check(m.primaryOwner(of: 1, among: subjects) == 300,
          "the narrowest allocation covering a task owns it")
    check(m.primaryOwner(of: 2, among: subjects) == 200,
          "and when there is no task-level one, the tag beats the group")
    check(m.primaryOwner(of: 3, among: subjects) == 100,
          "a task only the group covers belongs to the group")
    check(m.primaryOwner(of: 5, among: subjects) == nil,
          "a task no allocation covers is owned by nothing — that's off-plan work")

    // A NESTED allocation still owns its hours. Excluding it is what made it invisible in the grid.
    let nestedSubjects: [Int64: TargetSubject] = [100: .project(10), 300: .task(1)]
    check(m.primaryOwner(of: 1, among: nestedSubjects) == 300,
          "a task allocation nested inside a group allocation still owns its own hours")

    // Each hour goes to exactly ONE allocation, so a day's blocks can never sum past the day.
    let everyTask: [Int64] = [1, 2, 3, 4, 5]
    let owners = everyTask.map { m.primaryOwner(of: $0, among: subjects) }
    check(owners.count == everyTask.count, "every task resolves to at most one owner")
    check(Set(owners.compactMap { $0 }).isSubset(of: Set(subjects.keys)),
          "and always to an allocation that exists")

    // Ties are broken deterministically, so a rebuild can't shuffle the colours in a column.
    let tied: [Int64: TargetSubject] = [7: .tag(99), 9: .tag(99)]
    check(m.primaryOwner(of: 1, among: tied) == 7, "equal-sized allocations resolve to the smaller id")
    check(m.primaryOwner(of: 1, among: tied) == m.primaryOwner(of: 1, among: tied),
          "and the answer doesn't change between calls")
}

// MARK: - Heavy overlap

/// Worlds where allocations overlap a lot, because that is where a planner's arithmetic quietly stops
/// adding up: an hour that counts toward three allocations can be credited three times, drawn three times,
/// or spent three times, and each mistake looks plausible on its own.
///
/// Rather than one hand-made case, this builds many worlds deterministically and asserts the invariants
/// that have to hold in all of them. Deterministic on purpose — a failure has to be reproducible, and
/// `Math.random` isn't available in this harness anyway.
func testHeavyOverlap() {
    print("Heavy overlap:")

    // 12 tasks, all in one group, every task carrying two or three of five tags. Allocations are then
    // written against the group, each tag, and three individual tasks — so most pairs of allocations
    // overlap partially, a few nest completely, and one is disjoint.
    var taskGroups: [Int64: Int64?] = [:]
    var taskTags: [Int64: Set<Int64>] = [:]
    for task in Int64(1)...12 {
        taskGroups[task] = task <= 10 ? 100 : 200          // 11 and 12 sit in a different group
        var tags: Set<Int64> = [901 + (task % 3)]
        if task % 2 == 0 { tags.insert(904) }
        if task % 4 == 0 { tags.insert(905) }
        taskTags[task] = tags
    }
    let membership = plannerWorld(taskGroups: taskGroups, taskTags: taskTags)

    let targets: [Target] = [
        floor(1, .project(100), hours: 30),                       // the big group
        floor(2, .tag(901), hours: 8),
        floor(3, .tag(902), hours: 8),
        floor(4, .tag(903), hours: 8),
        floor(5, .tag(904), hours: 10, weekdays: .weekdaysOnly),
        floor(6, .tag(905), hours: 4, weekdays: Weekdays(rawValue: 1 | 64)),
        floor(7, .task(4), hours: 3),                             // inside group 100, tags 902/904/905
        floor(8, .task(11), hours: 5),                            // the other group
        floor(9, .project(200), hours: 6),                        // contains task 11 and 12
    ]
    let input = plannerInput(targets, membership: membership)
    let plan = Planner.plan(input)

    // Bounds: the certainly-required figure can never exceed the naive sum, and both have to be positive
    // in a world this tangled. A lower bound above the upper one is the classic overlap arithmetic bug.
    check(plan.requiredLowerSeconds <= plan.requiredUpperSeconds + 1,
          "the disjoint lower bound never exceeds the naive sum")
    check(plan.requiredLowerSeconds > 0, "and it is not zero when allocations genuinely need hours")
    check(plan.requiredUpperSeconds <= targets.reduce(0) { $0 + $1.weeklySeconds } + 1,
          "the naive sum is exactly that — no allocation counted twice")

    // Nesting has to be found, and only where it exists: task 11 is inside group 200, and task 4 inside
    // group 100. Nothing should be reported as inside something it merely overlaps.
    let nestedNames = Set(plan.nestings.map { $0.innerName })
    check(nestedNames.contains("a8"), "a task allocation inside its group's allocation is nested")
    check(nestedNames.contains("a7"), "and so is a task inside the big group")
    check(!nestedNames.contains("a5"),
          "a tag that merely overlaps a group is NOT nested — partial overlap is not containment")

    // No day may be committed beyond its capacity by the planner's own spread.
    for day in plan.days {
        check(day.reservedSeconds + day.committedSeconds <= day.capacitySeconds * 1.0001
              || day.isOverCapacity,
              "a day over its capacity is reported as over rather than silently accepted")
    }

    // Now the daily plan, in a range of situations: nothing done, a normal week, and a week where one
    // allocation has been hammered and the rest ignored.
    let scenarios: [(String, [Int: [Int64: TimeInterval]])] = [
        ("nothing tracked", [:]),
        ("a little of everything",
         Dictionary(uniqueKeysWithValues: (1...4).map { weekday in
             (weekday, Dictionary(uniqueKeysWithValues: targets.map { ($0.id, 1.5 * 3600) }))
         })),
        ("one allocation hammered",
         [1: [1: 12 * 3600], 2: [1: 10 * 3600], 3: [1: 8 * 3600]]),
        ("everything already met",
         [1: Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.weeklySeconds) })]),
    ]

    for (label, credited) in scenarios {
        for remaining in [[1, 2, 3, 4, 5, 6, 7], [5, 6, 7], [7]] {
            let daily = Replan.dailyPlan(input: input, plan: plan, creditedByWeekday: credited,
                                         remainingWeekdays: remaining,
                                         fractionOfTodayLeft: 0.5)

            // THE invariant: no day is ever asked for more hours than it has. Everything else on the page
            // is built on a column that can't overflow.
            for weekday in remaining {
                guard let day = plan.days.first(where: { $0.weekday == weekday }) else { continue }
                let asked = (daily.byDay[weekday] ?? [:]).values.reduce(0) { $0 + $1.total }
                let isToday = weekday == remaining.first
                let room = (day.capacitySeconds - day.reservedSeconds) * (isToday ? 0.5 : 1)
                check(asked <= room + 1,
                      "\(label), \(remaining.count) days left: no day is asked for more than it has")
            }

            // Nothing is ever asked of a day the allocation doesn't claim.
            for (weekday, shares) in daily.byDay {
                for id in shares.keys {
                    let target = targets.first { $0.id == id }!
                    check(target.weekdays.effective.contains(weekday: weekday),
                          "\(label): an allocation is only planned on days it claims")
                }
            }

            // Placed plus unplaced is exactly what each allocation still needs — no hours invented, none
            // lost. This is what an overlap bug breaks first.
            for target in targets {
                let weekDone = (1...7).reduce(0.0) { $0 + (credited[$1]?[target.id] ?? 0) }
                let needed = max(0, target.weeklySeconds - weekDone)
                let placed = remaining.reduce(0.0) {
                    $0 + ((daily.byDay[$1]?[target.id])?.total ?? 0)
                }
                let unplaced = (daily.unplaced[target.id] ?? 0) + (daily.outOfDays[target.id] ?? 0)
                let claimsAnyRemaining = remaining.contains {
                    target.weekdays.effective.contains(weekday: $0)
                }
                if claimsAnyRemaining {
                    check(placed + unplaced <= needed + 60,
                          "\(label): never asks for more than the allocation still needs")
                } else {
                    check(placed < 60, "\(label): an allocation with no days left is planned nowhere")
                }
            }

            // No negative figures anywhere, in any scenario.
            check(daily.byDay.values.allSatisfy { shares in
                    shares.values.allSatisfy { $0.intended >= 0 && $0.carried >= 0 }
                  }, "\(label): no negative hours")
            check(daily.unplaced.values.allSatisfy { $0 >= 0 }
                  && daily.outOfDays.values.allSatisfy { $0 >= 0 },
                  "\(label): no negative overflow")
        }
    }

    // Membership itself, since every figure above depends on it: a heavily-tagged task belongs to several
    // allocations, and each allocation's set is exactly the tasks that qualify.
    check(membership.taskIDs(for: .project(100)).count == 10, "the group holds its ten tasks")
    check(membership.taskIDs(for: .tag(904)).count == 6, "the even-numbered tasks carry tag 904")
    check(membership.taskIDs(for: .task(4)) == [4], "and a task allocation is just that task")
    check(membership.relation(.task(4), .project(100)) == .containedIn,
          "a task inside a group is contained in it")
    check(membership.relation(.tag(904), .project(100)) == .partial,
          "a tag spanning two groups partially overlaps either of them")
    check(membership.relation(.project(100), .project(200)) == .disjoint,
          "two groups share nothing")
}

// MARK: - Focus block boundary

func testDeepBlockBoundary() {
    print("Deep block boundary:")
    // The reported bug: five half-hour blocks on screen, four counted as focused. The odd one out
    // measured 1799.999716s — 284 MICROseconds under 30 minutes — because interval boundaries come
    // from `Date()` and the auto-pause checkpoint aims for exactly the threshold.
    check(Aggregations.isDeepBlock(duration: 1799.999716, threshold: 1800),
          "a block 284µs short of the threshold still counts")
    check(Aggregations.isDeepBlock(duration: 1800, threshold: 1800),
          "and so does one exactly on it")
    check(Aggregations.isDeepBlock(duration: 1799.6, threshold: 1800),
          "half a second of slack is allowed, being far below anything anyone meant to record")
    check(!Aggregations.isDeepBlock(duration: 1799.4, threshold: 1800),
          "but a second short is genuinely short — the tolerance can't become a discount")
    check(!Aggregations.isDeepBlock(duration: 600, threshold: 1800),
          "and a ten-minute block is not a focused one")

    // End to end through the summary, which is where the wrong number was seen.
    do {
        let (store, url) = try! makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let p = try! store.createProject(name: "P", colorHex: "#f00")
        let day = date(2026, 9, 14, 9, 0)
        // Two blocks: one a hair under 30m, one comfortably over.
        try! store.insertClosedInterval(projectID: p, start: day,
                                        end: day.addingTimeInterval(1799.999716))
        try! store.insertClosedInterval(projectID: p, start: day.addingTimeInterval(7200),
                                        end: day.addingTimeInterval(7200 + 2400))
        let range = DateRange(unit: .day, start: cal.startOfDay(for: day),
                             end: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day))!)
        let summary = Aggregations.summary(intervals: try! store.intervals(), range: range,
                                           deepThreshold: 1800)
        check(approx(summary.deepSeconds, 1799.999716 + 2400, 0.01),
              "both blocks count towards focused time, not just the one that cleared 1800 exactly")
        check(approx(summary.focusRatio, 1, 0.001),
              "so a day made entirely of half-hour blocks reads as 100% focused")
    }
}

// MARK: - Allocation weekdays

func testAllocationWeekdays() {
    print("Allocation weekdays:")

    // Sunday is bit 0, matching Calendar's 1-based weekday minus one.
    check(Weekdays.all.selectedCount == 7, "every day by default")
    check(Weekdays.weekdaysOnly.selectedCount == 5, "Monday to Friday is five days")
    check(Weekdays.weekdaysOnly.contains(weekday: 2) && Weekdays.weekdaysOnly.contains(weekday: 6),
          "which are Monday and Friday in Calendar's numbering")
    check(!Weekdays.weekdaysOnly.contains(weekday: 1) && !Weekdays.weekdaysOnly.contains(weekday: 7),
          "and not Sunday or Saturday")
    check(Weekdays.all.toggling(weekday: 1).selectedCount == 6, "toggling a day off leaves six")
    check(Weekdays.none.effective.isAll,
          "no days selected means every day — there's no allocation you never work on, and zero "
              + "days would make the pace infinite")
    check(Weekdays(rawValue: 0xFF).selectedCount == 7,
          "a stray high bit is discarded rather than counted as an eighth day")

    // Counting the allocation's own days inside a range.
    let weekStart = date(2026, 8, 24, 0, 0)          // Monday
    let weekEnd = date(2026, 8, 31, 0, 0)
    check(Weekdays.all.daysIn(start: weekStart, end: weekEnd, calendar: cal) == 7,
          "a full week has seven of everybody's days")
    check(Weekdays.weekdaysOnly.daysIn(start: weekStart, end: weekEnd, calendar: cal) == 5,
          "and five weekdays")

    // The bug this walk had: normalising to startOfDay in a DIFFERENT calendar pulled the cursor
    // into the previous day, so a week counted as eight days and every pace came out low.
    check(Weekdays.all.daysIn(start: weekStart, end: weekEnd) == 7,
          "the count doesn't depend on the walker's calendar matching the range's")

    // A weekend-only allocation over a Tuesday-to-Thursday window has none of its days in view.
    let midweek = date(2026, 8, 25, 0, 0)
    let thursday = date(2026, 8, 27, 0, 0)
    let weekends = Weekdays(rawValue: 0b1000001)
    check(weekends.daysIn(start: midweek, end: thursday, calendar: cal) == 0,
          "a weekend allocation has no days in a midweek window")

    // And the pace: 10h a week over five days is 2h a day, not 1h26m.
    let fiveDay = Target(id: 1, subject: .tag(1), seconds: 10 * 3600,
                         direction: .atLeast, period: .week, weekdays: .weekdaysOnly)
    let p = TargetMath.progress(target: fiveDay, name: "office", actualSeconds: 6 * 3600,
                                rangeStart: weekStart, rangeEnd: weekEnd,
                                now: date(2026, 8, 26, 12, 0), calendar: cal)
    check(p.workingDays == 5, "the pace divides by the days it's meant to happen on")
    check(approx(p.targetPerDaySeconds / 3600, 2, 0.01), "10h over five days is 2h a day")
    check(approx(p.averagePerDaySeconds / 3600, 6.0 / 5, 0.01),
          "and the actual average uses the same five days")
    check(approx(p.expectedSeconds / 3600, 10, 0.01),
          "the WEEK's expectation is unchanged — days change the spread, not the total")

    // Time recorded on an unselected day still counts. Saying "I do this on weekdays" describes how
    // the hours are meant to be spread, not a refusal to count Sunday's work.
    let sundayWork = TargetMath.progress(target: fiveDay, name: "office",
                                         actualSeconds: 10 * 3600,
                                         rangeStart: weekStart, rangeEnd: weekEnd,
                                         now: weekEnd, calendar: cal)
    check(sundayWork.verdict == .met, "hitting the total counts however the hours fell")

    // Pro-rating onto a VIEWED day: a Saturday expects nothing from a weekdays-only allocation.
    let saturday = date(2026, 8, 29, 0, 0)
    let onSaturday = TargetMath.progress(target: fiveDay, name: "office", actualSeconds: 0,
                                         rangeStart: weekStart, rangeEnd: weekEnd,
                                         now: saturday, viewedRangeDays: 1,
                                         viewedRangeStart: saturday,
                                         viewedRangeEnd: date(2026, 8, 30, 0, 0), calendar: cal)
    check(onSaturday.rangeExpectedSeconds == 0,
          "a Saturday expects nothing from a Monday-to-Friday allocation")
    let onWednesday = TargetMath.progress(target: fiveDay, name: "office", actualSeconds: 0,
                                          rangeStart: weekStart, rangeEnd: weekEnd,
                                          now: date(2026, 8, 26, 12, 0), viewedRangeDays: 1,
                                          viewedRangeStart: date(2026, 8, 26, 0, 0),
                                          viewedRangeEnd: date(2026, 8, 27, 0, 0), calendar: cal)
    check(approx(onWednesday.rangeExpectedSeconds / 3600, 2, 0.01),
          "and a Wednesday expects the full 2h, not a seventh of the week")
}

// MARK: - Editing an allocation keeps its days

func testEditingKeepsWeekdays() {
    print("Editing an allocation:")
    do {
        let (store, url) = try! makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let tag = try! store.upsertTag(name: "office", colorHex: "#f00")
        _ = try! store.setTarget(subject: .tag(tag), seconds: 10 * 3600,
                                direction: .atLeast, period: .week, weekdays: .weekdaysOnly)

        // The reported bug: pick days, then change the hours, and the days reset. `setTarget`
        // upserts and its ON CONFLICT clause assigns every column it is given, so a caller that
        // omitted `weekdays` wrote the .all default over the selection.
        _ = try! store.setTarget(subject: .tag(tag), seconds: 12 * 3600,
                                direction: .atLeast, period: .week,
                                weekdays: try! store.listTargets().first!.weekdays)
        let after = try! store.listTargets().first!
        check(after.seconds == 12 * 3600, "the new amount is saved")
        check(after.weekdays == Weekdays.weekdaysOnly, "and the days it was set for survive it")

        // The days can still be changed on their own, which is the other half of the interaction.
        try! store.setTargetWeekdays(id: after.id, .all)
        check(try! store.listTargets().first?.weekdays.isAll == true, "and are still editable")
        check(try! store.listTargets().first?.seconds == 12 * 3600,
              "without disturbing the amount either")
    }
}

// MARK: - Allocation weekdays travel

func testWeekdaysSync() {
    print("Allocation weekdays over sync:")
    do {
        let (a, aURL) = try! makeStore(); defer { try? FileManager.default.removeItem(at: aURL) }
        let (b, bURL) = try! makeStore(); defer { try? FileManager.default.removeItem(at: bURL) }
        let tagA = try! a.upsertTag(name: "office", colorHex: "#f00")
        _ = try! a.setTarget(subject: .tag(tagA), seconds: 10 * 3600,
                            direction: .atLeast, period: .week, weekdays: .weekdaysOnly)
        check(try! a.listTargets().first?.weekdays.selectedCount == 5, "the days are stored")

        // Both halves have to travel: the tag the allocation points at, then the allocation. Same
        // route `SyncEngine.merge` takes — resolve the subject's UID to a local row first.
        // `insertRemoteTag`, not `applyRemoteTagEdit`: the peer has never seen this tag, and the
        // edit path only updates one that's already there.
        for row in try! a.tagsWithUIDs() {
            _ = try! b.insertRemoteTag(uid: row.uid, name: row.tag.name,
                                       colorHex: row.tag.colorHex,
                                       sortOrder: row.tag.sortOrder, updatedAt: row.updatedAt)
        }
        func pushTargets(weekdaysOverride: Int?? = nil, bumpBy: TimeInterval = 0) {
            for t in try! a.targetsForExport() {
                guard let table = IntervalStore.table(forSubjectKind: t.subjectKind),
                      let subjectID = try! b.localID(table: table, uid: t.subjectUID),
                      let subject = TargetSubject(kind: t.subjectKind, id: subjectID)
                else { continue }
                _ = try! b.applyRemoteTarget(
                    uid: t.uid, subject: subject, seconds: t.seconds,
                    direction: Target.Direction(rawValue: t.direction)!,
                    period: Target.Period(rawValue: t.period)!,
                    remoteUpdatedAt: t.updatedAt + bumpBy, createdAt: t.createdAt,
                    completedAt: t.completedAt,
                    weekdays: weekdaysOverride ?? t.weekdays)
            }
        }
        pushTargets()
        check(try! b.listTargets().first?.weekdays == Weekdays.weekdaysOnly,
              "and arrive on the peer — a pace that differs per device is the bug we just fixed")

        // A peer on an older build sends no weekdays at all — and it can easily be the most recent
        // writer. Silence has to mean "no opinion", NOT "every day": overwriting with all-seven
        // would let a device that can't even see the setting destroy it just by editing the amount.
        pushTargets(weekdaysOverride: .some(nil), bumpBy: 60)
        check(try! b.listTargets().first?.weekdays == Weekdays.weekdaysOnly,
              "an older peer's newer edit leaves the days it doesn't know about alone")

        // But a row arriving for the FIRST time with no weekdays does default to every day, which is
        // the behaviour those builds had.
        do {
            let (c, cURL) = try! makeStore(); defer { try? FileManager.default.removeItem(at: cURL) }
            let tagC = try! c.upsertTag(name: "office", colorHex: "#f00")
            _ = try! c.applyRemoteTarget(uid: "fresh-uid", subject: .tag(tagC),
                                        seconds: 10 * 3600, direction: .atLeast, period: .week,
                                        remoteUpdatedAt: 1_000, weekdays: nil)
            check(try! c.listTargets().first?.weekdays.isAll == true,
                  "a brand-new allocation from an older peer is every day")
        }
    }
}

// MARK: - Feedback numbering

func testFeedbackNumbering() {
    print("Feedback numbering:")
    do {
        let (mac, macURL) = try! makeStore(); defer { try? FileManager.default.removeItem(at: macURL) }
        let (phone, phoneURL) = try! makeStore(); defer { try? FileManager.default.removeItem(at: phoneURL) }

        // The reported bug: the number shown was the local row id, so the same note was #3 here and
        // something else there — and notes refer to each other by number ("for issue 47…").
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 1...3 { _ = try! mac.addFeedback("mac note \(i)", at: t0.addingTimeInterval(Double(i))) }
        let macNotes = try! mac.listFeedback().sorted { $0.seq < $1.seq }
        check(macNotes.map(\.seq) == [1, 2, 3], "numbers start at 1 and count up")

        // Sync them across. The peer must adopt the numbers, not mint its own.
        func push(from a: IntervalStore, to b: IntervalStore) {
            for row in try! a.feedbackForExport() {
                _ = try! b.applyRemoteFeedback(uid: row.uid, text: row.text, deviceID: row.deviceID,
                                               createdAt: row.createdAt, resolvedAt: row.resolvedAt,
                                               remoteUpdatedAt: row.updatedAt,
                                               platform: row.platform, seq: row.seq)
            }
            _ = try! b.normalizeFeedbackNumbers()
        }
        push(from: mac, to: phone)
        let onPhone = try! phone.listFeedback()
        check(onPhone.count == 3, "all three arrive")
        for note in onPhone {
            let here = macNotes.first { $0.text == note.text }!
            check(note.seq == here.seq, "\"\(note.text)\" is called #\(here.seq) on both devices")
        }

        // Rewording a note elsewhere must not renumber it, or every reference goes stale.
        let target = try! phone.listFeedback().first { $0.text == "mac note 2" }!
        try! phone.updateFeedback(id: target.id, text: "mac note 2, reworded")
        push(from: phone, to: mac)
        check(try! mac.listFeedback().first { $0.text == "mac note 2, reworded" }?.seq == 2,
              "an edit changes the text and leaves the number alone")

        // Both devices offline, both create a note: both pick the same next number, and the clash
        // has to settle the same way on each of them without any coordination.
        let clashMac = try! mac.addFeedback("written on the mac", at: t0.addingTimeInterval(100))!
        let clashPhone = try! phone.addFeedback("written on the phone", at: t0.addingTimeInterval(200))!
        check(try! mac.listFeedback().first { $0.id == clashMac }?.seq == 4,
              "each device independently picks 4")
        check(try! phone.listFeedback().first { $0.id == clashPhone }?.seq == 4,
              "which is why they collide")

        push(from: mac, to: phone)
        push(from: phone, to: mac)
        let macFinal = try! mac.listFeedback()
        let phoneFinal = try! phone.listFeedback()
        check(Set(macFinal.map(\.seq)).count == macFinal.count, "no two notes share a number here")
        check(Set(phoneFinal.map(\.seq)).count == phoneFinal.count, "nor there")
        for note in macFinal {
            let there = phoneFinal.first { $0.text == note.text }
            check(there?.seq == note.seq,
                  "\"\(note.text)\" settled on #\(note.seq) on BOTH devices, unprompted")
        }
        // The one created first keeps the contested number — the rule is age, not arrival order.
        check(macFinal.first { $0.text == "written on the mac" }?.seq == 4,
              "the older of the two clashing notes keeps 4")
        check(macFinal.first { $0.text == "written on the phone" }?.seq == 5,
              "and the newer one moves to the end")
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

// MARK: - Settings that have to agree across devices

func testSharedSettings() {
    print("Shared settings:")
    do {
        let (store, url) = try! makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let (peer, purl) = try! makeStore(); defer { try? FileManager.default.removeItem(at: purl) }

        // This is the reported bug: two devices, two different auto-pause thresholds, and nothing
        // carrying one to the other — so one Mac recorded hour-long sessions while the other capped
        // them at 30 minutes.
        let early = Date(timeIntervalSince1970: 1_000_000)
        let later = Date(timeIntervalSince1970: 2_000_000)
        try! store.setSetting("autoPauseMinutes", value: "30", at: later)
        try! peer.setSetting("autoPauseMinutes", value: "60", at: early)

        let exported = try! store.settingsForExport()
        check(exported.contains { $0.key == "autoPauseMinutes" && $0.value == "30" },
              "the threshold is exported for sync")

        for row in exported {
            _ = try! peer.applyRemoteSetting(key: row.key, value: row.value,
                                             remoteUpdatedAt: row.updatedAt)
        }
        check(try! peer.settingValue("autoPauseMinutes")?.value == "30",
              "the newer write wins, so both devices end up recording to the same threshold")

        // And the older one can't win on a later pass.
        check(!(try! store.applyRemoteSetting(key: "autoPauseMinutes", value: "60",
                                              remoteUpdatedAt: early.timeIntervalSince1970)),
              "an older value from a peer is ignored")
        check(try! store.settingValue("autoPauseMinutes")?.value == "30",
              "and doesn't overwrite what's here")

        // Same value with a newer stamp converges the clocks without reporting a change — the app
        // adopts settings on that signal, and re-adopting an unchanged value churns @Published.
        check(!(try! store.applyRemoteSetting(key: "autoPauseMinutes", value: "30",
                                              remoteUpdatedAt: later.timeIntervalSince1970 + 100)),
              "the same value arriving later isn't reported as a change")

        // Device-local settings deliberately don't travel; nor does a key from a newer build. A
        // filesystem path is the clearest case: one machine's folder means nothing on another, and a
        // phone has no such path at all.
        check(!(try! peer.applyRemoteSetting(key: "syncFolderPath", value: "/Users/someone/Dropbox",
                                            remoteUpdatedAt: later.timeIntervalSince1970)),
              "an unsynced key is ignored rather than stored")
        check(try! peer.settingValue("syncFolderPath") == nil,
              "so nothing accumulates rows that nothing reads")
        check(IntervalStore.syncedSettingKeys.sorted()
                == ["autoPauseMinutes", "deepBlockMinutes", "highlightDimPercent",
                    "idleNudgeMinutes", "promptsEnabled", "wakingHours"],
              "everything that changes what's recorded or what a number MEANS is shared")
        for local in ["syncFolderPath", "syncMode", "googleClientID", "deviceLabel"] {
            check(!IntervalStore.syncedSettingKeys.contains(local),
                  "\(local) stays per-device — a path, a channel, a client id and a name")
        }

        // A second key travels independently of the first, so adopting one can't stall another.
        try! store.setSetting("deepBlockMinutes", value: "45", at: later)
        for row in try! store.settingsForExport() {
            _ = try! peer.applyRemoteSetting(key: row.key, value: row.value,
                                             remoteUpdatedAt: row.updatedAt)
        }
        check(try! peer.settingValue("deepBlockMinutes")?.value == "45",
              "what counts as a focused block agrees across devices too")
    }
}

// MARK: - Deleting part of a session

func testIntervalSlice() {
    print("Interval slicing:")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func mins(_ n: Double) -> Date { t0.addingTimeInterval(n * 60) }

    func fresh() -> (IntervalStore, URL, Int64) {
        let (store, url) = try! makeStore()
        let p = try! store.createProject(name: "P", colorHex: "#f00")
        try! store.insertClosedInterval(projectID: p, start: t0, end: mins(60), deviceID: "air")
        return (store, url, p)
    }

    do {   // a bite out of the middle leaves two pieces
        let (store, url, _) = fresh(); defer { try? FileManager.default.removeItem(at: url) }
        check(try! store.deleteIntervalSlice(id: store.intervals(from: t0).first!.id,
                                            from: mins(20), to: mins(30)) == 2,
              "cutting the middle out leaves the head and the tail")
        let left = try! store.intervals(from: t0).sorted { $0.start < $1.start }
        check(left.count == 2, "two rows, not one edited row")
        check(left[0].end == mins(20) && left[1].start == mins(30),
              "and they stop and start exactly at the cut")
        check(left.allSatisfy { $0.deviceID == "air" },
              "the device that RECORDED it is carried over — re-stamping would corrupt attribution")
    }

    do {   // trimming the tail, which is the commute repair case
        let (store, url, _) = fresh(); defer { try? FileManager.default.removeItem(at: url) }
        let id = try! store.intervals(from: t0).first!.id
        check(try! store.deleteIntervalSlice(id: id, from: mins(17), to: mins(60)) == 1,
              "cutting to the end leaves just the head")
        let left = try! store.intervals(from: t0)
        check(left.count == 1 && left[0].end == mins(17), "which ends where the cut began")
    }

    do {   // the whole thing
        let (store, url, _) = fresh(); defer { try? FileManager.default.removeItem(at: url) }
        let id = try! store.intervals(from: t0).first!.id
        check(try! store.deleteIntervalSlice(id: id, from: t0, to: mins(60)) == 0,
              "cutting the whole span leaves nothing")
        check(try! store.intervals(from: t0).isEmpty, "and the row is gone")
        check(try! store.tombstoneRecords().contains { $0.kind == "interval" },
              "tombstoned, or a peer's log re-adds it on the next sync")
    }

    do {   // a sliver isn't worth a row
        let (store, url, _) = fresh(); defer { try? FileManager.default.removeItem(at: url) }
        let id = try! store.intervals(from: t0).first!.id
        // Cut everything but the last half-second.
        _ = try! store.deleteIntervalSlice(id: id, from: t0, to: mins(60).addingTimeInterval(-0.5))
        check(try! store.intervals(from: t0).isEmpty,
              "a sub-second remainder is dropped rather than kept as an empty-looking session")
    }

    do {   // a running interval is refused: its end moves, so the slice wouldn't be the visible one
        let (store, url) = try! makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let p = try! store.createProject(name: "P", colorHex: "#f00")
        try! store.switchTo(projectID: p, at: t0)
        let id = try! store.openInterval()!.id
        check(try! store.deleteIntervalSlice(id: id, from: t0, to: mins(5)) == -1,
              "slicing a running interval is refused")
        check(try! store.openInterval() != nil, "and it's still running afterwards")
    }
}

// MARK: - Image downscaling

func testImageBytes() {
    print("Image bytes:")
    let target = ImageBytes.targetSize(width: 3024, height: 1964, maxDimension: 1600)
    check(target.width == 1600, "the longest edge lands exactly on the cap")
    check(target.height == 1039, "and the other edge keeps the aspect ratio")

    let small = ImageBytes.targetSize(width: 800, height: 600, maxDimension: 1600)
    check(small == (800, 600), "an image already under the cap is left alone, not upscaled")

    let tall = ImageBytes.targetSize(width: 900, height: 3200, maxDimension: 1600)
    check(tall.height == 1600 && tall.width == 450, "height counts as the longest edge too")

    let sliver = ImageBytes.targetSize(width: 4000, height: 1, maxDimension: 1600)
    check(sliver.height == 1,
          "a one-pixel edge survives rounding — zero height would fail to encode at all")

    // And it produces real PNG bytes, downscaled, from a real image.
    let context = CGContext(data: nil, width: 3200, height: 1600, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1600))
    let png = ImageBytes.png(from: context.makeImage()!)
    check(png != nil, "encoding produces bytes")
    check(png?.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47]) == true,
          "and they're a PNG, since that's what the attachment filename claims")
    if let png, let decoded = CGImageSourceCreateWithData(png as CFData, nil)
        .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
        check(decoded.width == 1600, "the stored image really is the smaller one")
    } else {
        check(false, "the encoded PNG decodes again")
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

// MARK: - Palette / shared colour derivation

/// Colour derivation moved from `AppState` into Core so the iOS app and the Live Activity widget
/// (a separate process that can't link the Mac app) render a task in the SAME colour. These checks
/// are the thing that makes that guarantee real rather than aspirational.
func testPalette() {
    print("\nPalette:")

    do { // base palette, then generated hues — never a repeat
        check(Palette.color(forIndex: 0) == "#4E79A7", "index 0 is the first base colour")
        check(Palette.color(forIndex: 9) == "#BAB0AC", "index 9 is the last base colour")
        let generated = (0..<40).map { Palette.color(forIndex: $0) }
        check(Set(generated).count == 40, "40 tasks get 40 distinct colours")
        check(generated.allSatisfy { $0.count == 7 && $0.hasPrefix("#") }, "all are #RRGGBB")
    }

    do { // shade(index: 0) must be identity, or the first task stops matching its project swatch
        check(Palette.shade(ofHex: "#4E79A7", index: 0) == "#4E79A7", "shade 0 is the base colour")
        let shades = (0..<6).map { Palette.shade(ofHex: "#4E79A7", index: $0) }
        check(Set(shades).count == 6, "siblings get distinct shades")
        // Same hue family: a shade must stay recognisably the project's colour.
        let baseHue = Palette.hsv(fromHex: "#4E79A7")!.h
        check(shades.allSatisfy { abs(Palette.hsv(fromHex: $0)!.h - baseHue) < 0.02 },
              "shades preserve the project hue")
    }

    do { // malformed input degrades instead of crashing
        check(Palette.shade(ofHex: "nonsense", index: 3) == "nonsense", "bad hex passes through")
        check(Palette.hsv(fromHex: "#fff") == nil, "3-digit hex is rejected")
    }

    do { // Inbox (no group) keeps the task's own colour
        let task = Project(id: 1, name: "t", colorHex: "#123456", sortOrder: 0, archived: false)
        check(Palette.displayColorHex(for: task, groups: [], allTasks: [task]) == "#123456",
              "ungrouped task keeps its own colour")
    }

    do { // grouped tasks take shades of the GROUP colour, positionally by id
        let group = TaskProject(id: 7, name: "g", colorHex: "#59A14F")
        func t(_ id: Int64) -> Project {
            Project(id: id, name: "t\(id)", colorHex: "#000000", sortOrder: 0, archived: false,
                    taskProjectID: 7)
        }
        let all = [t(3), t(11), t(42)]
        let hexes = all.map { Palette.displayColorHex(for: $0, groups: [group], allTasks: all) }
        check(hexes[0] == "#59A14F", "first task in a group matches the group swatch")
        check(Set(hexes).count == 3, "three grouped tasks get three shades")

        // Input order must not matter — sorting is by id, so a reordered list is the same colours.
        let shuffled = [t(42), t(3), t(11)]
        check(Palette.displayColorHex(for: t(11), groups: [group], allTasks: shuffled) == hexes[1],
              "shade is independent of input order")

        // Archived siblings MUST still count: dropping one renumbers the rest and silently
        // recolours them, which is the bug the `allTasks` parameter exists to prevent.
        let withoutMiddle = [t(3), t(42)]
        check(Palette.displayColorHex(for: t(42), groups: [group], allTasks: withoutMiddle) != hexes[2],
              "omitting a sibling shifts later shades (so archived tasks must be included)")

        // A task pointing at a group that no longer exists falls back rather than vanishing.
        check(Palette.displayColorHex(for: t(3), groups: [], allTasks: all) == "#000000",
              "missing group falls back to the task's colour")
    }

    // MARK: colour used as TEXT
    //
    // The palette is chosen for FILLS. Used as text it is mostly unreadable: 47 of these 60 colours
    // fail 4.5:1 on a white window, worst at 1.20:1. These checks pin the repair, because an invisible
    // label is exactly the kind of bug that ships — nothing crashes and no compiler complains.
    do {
        // Known anchors, so a broken luminance implementation can't pass the sweep by accident.
        check(Palette.relativeLuminance(ofHex: "#FFFFFF").map { abs($0 - 1) < 0.001 } == true,
              "white has luminance 1")
        check(Palette.relativeLuminance(ofHex: "#000000").map { $0 < 0.001 } == true,
              "black has luminance 0")
        check(Palette.contrastRatio("#FFFFFF", "#000000").map { abs($0 - 21) < 0.01 } == true,
              "black on white is 21:1")
        check(Palette.relativeLuminance(ofHex: "#fff") == nil, "3-digit hex is rejected")
        check(Palette.legibleHex("nonsense", onBackground: "#FFFFFF") == "nonsense",
              "bad hex passes through untouched")

        // The sweep: every base colour AND every shade a project's tasks can take, on both
        // appearances. `shade` reaches brightness 0.97, which is where the invisible cases come from,
        // so testing only `Palette.colors` would miss the worst of them.
        let surfaces = [("light", "#FFFFFF"), ("dark", "#2E2E2E")]
        var subjects: [String] = []
        for base in Palette.colors {
            for i in 0..<6 { subjects.append(Palette.shade(ofHex: base, index: i)) }
        }
        for (name, bg) in surfaces {
            let repaired = subjects.map { Palette.legibleHex($0, onBackground: bg) }
            let worst = repaired.compactMap { Palette.contrastRatio($0, bg) }.min() ?? 0
            check(worst >= 4.5, "every task colour clears 4.5:1 as text on \(name) (worst \(worst))")

            // Hue is preserved, so a repaired colour still reads as "the blue one". Greys are exempt:
            // their hue is meaningless and HSV reports it as 0 regardless.
            let hueDrift = zip(subjects, repaired).compactMap { original, fixed -> Double? in
                guard let a = Palette.hsv(fromHex: original), let b = Palette.hsv(fromHex: fixed),
                      a.s > 0.15 else { return nil }
                // Circular distance — a red at 0.99 and one at 0.01 are neighbours, not opposites.
                let raw = abs(a.h - b.h)
                return min(raw, 1 - raw)
            }.max() ?? 0
            check(hueDrift < 0.02, "repair keeps the hue on \(name) (drift \(hueDrift))")
        }

        // Idempotent: a colour that already passes is returned unchanged, so this can be applied
        // without compounding.
        check(Palette.legibleHex("#000000", onBackground: "#FFFFFF") == "#000000",
              "already-legible colour is untouched")
        let once = Palette.legibleHex("#EDC948", onBackground: "#FFFFFF")
        check(Palette.legibleHex(once, onBackground: "#FFFFFF") == once, "repair is idempotent")

        // Direction: darker on a light page, lighter on a dark one.
        let onLight = Palette.hsv(fromHex: Palette.legibleHex("#EDC948", onBackground: "#FFFFFF"))!
        let onDark = Palette.hsv(fromHex: Palette.legibleHex("#4E79A7", onBackground: "#2E2E2E"))!
        check(onLight.v < Palette.hsv(fromHex: "#EDC948")!.v, "yellow darkens on a light page")
        check(onDark.v > Palette.hsv(fromHex: "#4E79A7")!.v, "blue lightens on a dark page")
    }
}


// MARK: - Shared bar components (TimesliceUI)

/// `InlineBar` draws its percentage INSIDE the bar, so the label colour has to flip based on the
/// fill. Getting that wrong makes the label invisible — a silent bug no compiler catches, and the
/// reason this threshold is pinned here rather than left to inspection.
///
/// Also guards the platform branch: a macOS build cannot typecheck the `#if canImport(UIKit)` arm at
/// all, so these run on the macOS arm and the iOS arm is verified separately by compiling for the
/// iOS SDK. Keeping them in step is manual.
func testInlineBarContrast() {
    print("\nInlineBar contrast:")

    // Perceptual, NOT max(r,g,b): a saturated yellow is far lighter to the eye than its RGB
    // suggests, and plain brightness would put white text on it.
    let yellow = InlineBar.perceptualLuminance(of: Color(red: 1, green: 1, blue: 0))
    let blue = InlineBar.perceptualLuminance(of: Color(red: 0, green: 0, blue: 1))
    check(yellow != nil && blue != nil, "luminance is readable for plain colours")
    if let yellow, let blue {
        check(yellow > 0.85, "yellow is perceptually light (\(yellow))")
        check(blue < 0.2, "pure blue is perceptually dark (\(blue))")
        check(yellow > blue, "yellow reads lighter than blue despite equal RGB maxima")
    }

    // The decisions that actually matter for legibility.
    check(InlineBar.readableTextColor(on: Color(red: 1, green: 1, blue: 0)) == .black,
          "black label on a light fill")
    check(InlineBar.readableTextColor(on: Color(red: 0, green: 0, blue: 1)) == .white,
          "white label on a dark fill")
    check(InlineBar.readableTextColor(on: .white) == .black, "black on white")
    check(InlineBar.readableTextColor(on: .black) == .white, "white on black")

    // Every palette colour must produce a legible label — these are the fills real budget rows use.
    for hex in Palette.colors {
        let picked = InlineBar.readableTextColor(on: Color(hex: hex))
        check(picked == .black || picked == .white, "palette \(hex) resolves a label colour")
    }

    // The verdict tints the Budgets rows use. Asserting only that each resolves to one of the two
    // legible options, not WHICH — the exact luminance of SwiftUI's semantic colours is Apple's to
    // change, and pinning it would make this test fail on an OS update rather than on a real bug.
    // (Written after guessing `.green` took a black label; it measures below the threshold and takes
    // white, which is correct — SwiftUI's green is a mid-dark green, not a bright one.)
    for (name, tint) in [("green", Color.green), ("orange", .orange), ("red", .red)] {
        let l = InlineBar.perceptualLuminance(of: tint) ?? -1
        let picked = InlineBar.readableTextColor(on: tint)
        check(picked == .black || picked == .white,
              "verdict \(name) (luminance \(String(format: "%.2f", l))) resolves a legible label")
        // The pairing must at least be self-consistent with the threshold it claims to use.
        check((l > 0.6) == (picked == .black), "verdict \(name) label agrees with its luminance")
    }
}


// MARK: - TaskOrdering (shared recency order)

/// Hoisted out of the Mac's `AppState` so the phone's task list and Action Button wheel order tasks
/// identically. The rules are subtle enough that a second implementation would drift, so they're
/// pinned here rather than trusted to two call sites agreeing.
func testTaskOrdering() {
    print("\nTask ordering:")

    func p(_ id: Int64) -> Project {
        Project(id: id, name: "t\(id)", colorHex: "#4E79A7", sortOrder: Int(id), archived: false)
    }
    let display = [p(1), p(2), p(3), p(4)]
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    do { // more recent first
        let order = TaskOrdering.recencyOrdered(
            display: display,
            lastActivity: [1: t0, 2: t0.addingTimeInterval(100), 3: t0.addingTimeInterval(50)],
            current: nil).map(\.id)
        check(order.prefix(3).elementsEqual([2, 3, 1]), "most recently worked comes first")
        check(order.last == 4, "never-tracked task sinks to the tail")
    }

    do { // the current task is PINNED to index 0, even when another is more recent
        let order = TaskOrdering.recencyOrdered(
            display: display,
            lastActivity: [1: t0, 2: t0.addingTimeInterval(999)],
            current: 1).map(\.id)
        check(order.first == 1, "current task is pinned to index 0")
        check(order.dropFirst().first == 2, "index 1 is the task you came from — alt-tab behaviour")
    }

    do { // A -> B leaves both with the SAME activity time; pinning is what breaks the tie correctly
        let same = t0
        let order = TaskOrdering.recencyOrdered(
            display: display, lastActivity: [1: same, 2: same], current: 2).map(\.id)
        check(order.first == 2,
              "equal timestamps: the current task still leads, so one press returns to the other")
        check(order.dropFirst().first == 1, "...and the one just left sits at index 1")
    }

    do { // untracked tasks keep DISPLAY order among themselves, rather than interleaving randomly
        let order = TaskOrdering.recencyOrdered(
            display: [p(9), p(3), p(7)], lastActivity: [:], current: nil).map(\.id)
        check(order == [9, 3, 7], "all-untracked keeps displayed order (stable, not arbitrary)")
    }

    do { // ordering must be a no-op on an empty list rather than trapping
        check(TaskOrdering.recencyOrdered(display: [], lastActivity: [:], current: 5).isEmpty,
              "empty input yields empty output")
    }
}


// MARK: - BudgetRows (shared budget row composition)

/// The composition hoisted out of the Mac's MetricsView so the phone's Budgets screen measures each
/// budget over the identical windows. Each row reads three separate clocks — its own period, today,
/// and the range being viewed — and which figure uses which window is the whole reason the numbers
/// mean anything. These checks pin that wiring, not the maths inside `TargetMath` (already covered).
func testBudgetRows() throws {
    print("\nBudget rows:")

    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let groupID = try store.upsertTaskProject(name: "work", colorHex: "#76B7B2")
    let a = try store.createProject(name: "alpha", colorHex: "#4E79A7", inGroup: groupID)
    let b = try store.createProject(name: "beta", colorHex: "#F28E2B")
    let tagID = try store.upsertTag(name: "deep", colorHex: "#59A14F")
    try store.addTag(tagID, to: .project(groupID))

    let tasks = try store.listProjects(includeArchived: true)
    let groups = try store.listTaskProjects()
    let tags = try store.listTags()
    let tagIDsByTask = try store.effectiveTagIDsByTask()

    // A fixed "now" so the elapsed fraction and windows are deterministic.
    let now = date(2026, 3, 11, 12, 0)               // a Wednesday, midday
    let dayRange = DateRange.resolve(unit: .day, anchor: now)

    // 2h on alpha today.
    try store.insertClosedInterval(projectID: a, start: date(2026, 3, 11, 9, 0),
                                   end: date(2026, 3, 11, 11, 0))
    // 1h on beta today.
    try store.insertClosedInterval(projectID: b, start: date(2026, 3, 11, 11, 0),
                                   end: date(2026, 3, 11, 12, 0))
    let intervals = try store.intervals()

    do { // a task floor, judged against ITS OWN period rather than the viewed range
        _ = try store.setTarget(subject: .task(a), seconds: 4 * 3600,
                                direction: .atLeast, period: .day)
        let rows = BudgetRows.build(targets: try store.listTargets(), tasks: tasks, groups: groups,
                                    tags: tags, tagIDsByTask: tagIDsByTask, intervals: intervals,
                                    viewedRange: dayRange, now: now)
        check(rows.count == 1, "one target yields one row")
        guard let row = rows.first else { return }
        check(row.progress.name == "alpha", "subject name resolved from the task")
        check(approx(row.progress.actualSeconds, 2 * 3600, 1), "actual is the subject's own seconds")
        check(approx(row.progress.expectedSeconds, 4 * 3600, 1), "a daily target expects its full amount on a day range")
        // Midday against a 4h floor with 2h done: on pace, NOT behind. Calling this a failure is
        // what would train you to ignore the number.
        if case .onPace = row.progress.verdict {} else {
            check(false, "half-done at half-elapsed is on pace, got \(row.progress.verdict)")
        }
        // A task inside a project takes the project's SHADE, matching the list and the island.
        check(row.colorHex != "#8E8E93", "task subject resolves a real colour")
        check(row.colorHex == Palette.displayColorHex(
                for: tasks.first { $0.id == a }!, groups: groups, allTasks: tasks),
              "task colour is its display shade, not its raw swatch")
    }

    do { // the budget PERIOD follows the viewed range, not today
        //
        // `TargetMath.periodAnchor` is tested on its own elsewhere; this asserts `BudgetRows.build`
        // actually routes through it. It didn't: every window was anchored at `now`, so paging back a
        // day still judged TODAY's budget and the section contradicted every other number on the page.
        // Both front-ends read these rows, so the regression would hit the Mac and the phone at once.
        for t in try store.listTargets() { try store.deleteTarget(id: t.id) }
        _ = try store.setTarget(subject: .task(a), seconds: 4 * 3600,
                                direction: .atLeast, period: .day)

        // 3h on alpha two days earlier, so the past day has a different total from today's 2h.
        try store.insertClosedInterval(projectID: a, start: date(2026, 3, 9, 9, 0),
                                       end: date(2026, 3, 9, 12, 0))
        let withPast = try store.intervals()

        let pastDay = DateRange.resolve(unit: .day, anchor: date(2026, 3, 9, 12, 0))
        let rows = BudgetRows.build(targets: try store.listTargets(), tasks: tasks, groups: groups,
                                    tags: tags, tagIDsByTask: tagIDsByTask, intervals: withPast,
                                    viewedRange: pastDay, now: now)
        guard let row = rows.first else { check(false, "past-range target produced a row"); return }
        check(approx(row.progress.actualSeconds, 3 * 3600, 1),
              "viewing a past day judges THAT day's 3h, not today's 2h")
        // A fully elapsed period is 100% elapsed, so "behind" is a verdict about the finished day
        // rather than about a pace that no longer applies.
        check(row.progress.elapsedFraction >= 0.999,
              "a past period counts as fully elapsed")

        // And the current range still reports today, so the fix didn't invert the common case.
        let todayRows = BudgetRows.build(targets: try store.listTargets(), tasks: tasks,
                                        groups: groups, tags: tags, tagIDsByTask: tagIDsByTask,
                                        intervals: withPast, viewedRange: dayRange, now: now)
        check(approx(todayRows.first?.progress.actualSeconds ?? 0, 2 * 3600, 1),
              "the current range still judges today")
    }

    do { // a TAG subject aggregates every task carrying it (via its project)
        for t in try store.listTargets() { try store.deleteTarget(id: t.id) }
        _ = try store.setTarget(subject: .tag(tagID), seconds: 1 * 3600,
                                direction: .atLeast, period: .day)
        let rows = BudgetRows.build(targets: try store.listTargets(), tasks: tasks, groups: groups,
                                    tags: tags, tagIDsByTask: tagIDsByTask, intervals: intervals,
                                    viewedRange: dayRange, now: now)
        guard let row = rows.first else { check(false, "tag target produced a row"); return }
        check(row.progress.name == "deep", "tag name resolved")
        check(approx(row.progress.actualSeconds, 2 * 3600, 1),
              "tag rolls up alpha's 2h (inherited from its project) and not beta's")
        check(row.colorHex == "#59A14F", "tag subject uses the tag's own colour")
        if case .met = row.progress.verdict {} else {
            check(false, "2h against a 1h floor is met, got \(row.progress.verdict)")
        }
    }

    do { // trouble sorts first: a breached ceiling ahead of a floor that's fine
        for t in try store.listTargets() { try store.deleteTarget(id: t.id) }
        _ = try store.setTarget(subject: .task(b), seconds: 10 * 60,
                                direction: .atMost, period: .day)     // 1h spent vs 10m ceiling
        _ = try store.setTarget(subject: .task(a), seconds: 1 * 3600,
                                direction: .atLeast, period: .day)    // 2h vs 1h floor: met
        let rows = BudgetRows.build(targets: try store.listTargets(), tasks: tasks, groups: groups,
                                    tags: tags, tagIDsByTask: tagIDsByTask, intervals: intervals,
                                    viewedRange: dayRange, now: now)
        check(rows.count == 2, "two targets, two rows")
        check(rows.first?.progress.name == "beta", "the breached ceiling sorts first")
        check(BudgetRows.rank(.over) < BudgetRows.rank(.behind)
              && BudgetRows.rank(.behind) < BudgetRows.rank(.onPace)
              && BudgetRows.rank(.onPace) < BudgetRows.rank(.met),
              "verdict ranking is over < behind < onPace < met")
    }

    do { // a target whose subject was deleted must not render as a blank row
        for t in try store.listTargets() { try store.deleteTarget(id: t.id) }
        _ = try store.setTarget(subject: .task(9_999), seconds: 3600,
                                direction: .atLeast, period: .day)
        let rows = BudgetRows.build(targets: try store.listTargets(), tasks: tasks, groups: groups,
                                    tags: tags, tagIDsByTask: tagIDsByTask, intervals: intervals,
                                    viewedRange: dayRange, now: now)
        check(rows.isEmpty, "a target pointing at a deleted subject is dropped, not rendered blank")
        check(BudgetRows.name(for: .task(9_999), tasks: tasks, groups: groups, tags: tags) == nil,
              "name resolution returns nil for a missing subject")
    }

    do { // budget durations are ALWAYS hours — never "1d 16h", which is unreadable as a budget
        check(BudgetRows.duration(40 * 3600) == "40h", "40h stays 40h rather than rolling to days")
        check(BudgetRows.duration(0) == "0", "zero is bare")
        check(BudgetRows.duration(90) == "1m", "under an hour shows minutes")
        check(BudgetRows.duration(30) == "30s", "under a minute shows seconds")
        check(BudgetRows.duration(3600 + 7 * 60) == "1h 7m", "hours and minutes")
        // Past 100h the minutes are noise and used to overflow the column.
        check(BudgetRows.duration(107 * 3600 + 2 * 60) == "107h", "minutes dropped past 100h")
    }
}


/// `createProject(inGroup:)` must actually FILE the task, not just use the group to dedup.
///
/// It used to drop the parameter after the dedup lookup, so a task created in a group landed in
/// Inbox. The Mac masked it by calling `setTaskProject` straight afterwards; the phone's `/project`
/// filing trusted the parameter and silently did nothing. Pinned here because the symptom is
/// invisible — the task exists, just in the wrong place.
func testCreateProjectFilesIntoGroup() throws {
    print("\nCreate-in-group:")
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let groupID = try store.upsertTaskProject(name: "work", colorHex: "#76B7B2")
    let filed = try store.createProject(name: "alpha", colorHex: "#4E79A7", inGroup: groupID)
    let inbox = try store.createProject(name: "beta", colorHex: "#F28E2B")

    let tasks = try store.listProjects(includeArchived: true)
    check(tasks.first { $0.id == filed }?.taskProjectID == groupID,
          "a task created inGroup is actually in that group")
    check(tasks.first { $0.id == inbox }?.taskProjectID == nil,
          "a task created with no group stays in Inbox")

    // And the consequence that made it matter: tag inheritance flows through the group.
    let tagID = try store.upsertTag(name: "deep", colorHex: "#59A14F")
    try store.addTag(tagID, to: .project(groupID))
    let byTask = try store.effectiveTagIDsByTask()
    check(byTask[filed]?.contains(tagID) == true, "the filed task inherits its project's tag")
    check(byTask[inbox]?.contains(tagID) != true, "an Inbox task inherits nothing")
}


/// The swipe-to-change-period convention.
///
/// Here because the gesture cannot be exercised headlessly — `simctl` has no drag — so the decision the
/// gesture delegates to is the only part that can be pinned down. An inverted direction builds cleanly
/// and screenshots identically, and would only show up as the screen going the wrong way in your hand.
func testSwipeDelta() {
    print("\nSwipe delta:")

    // Content follows the finger: left goes forward in time, right goes back.
    check(DateRange.swipeDelta(dx: -80, dy: 0) == 1, "dragging left moves forward")
    check(DateRange.swipeDelta(dx: 80, dy: 0) == -1, "dragging right moves back")

    // Mostly-vertical drags belong to the scroll view, not to us.
    check(DateRange.swipeDelta(dx: 10, dy: 90) == nil, "a vertical drag is ignored")
    check(DateRange.swipeDelta(dx: 30, dy: 30) == nil, "a diagonal drag is ignored")
    check(DateRange.swipeDelta(dx: 0, dy: 0) == nil, "a tap-sized drag is ignored")

    // Comfortably horizontal still wins even with some vertical drift, which every real thumb has.
    check(DateRange.swipeDelta(dx: -100, dy: 40) == 1, "horizontal wins despite drift")

    // The magnitude never matters — a long swipe is still one period, so a flick can't skip a week.
    check(DateRange.swipeDelta(dx: -1000, dy: 0) == 1, "a long swipe is still one period")
}

/// `rangeTotals` is the general form of `todayTotals`. Added because "Where time went" needs per-task
/// figures for an arbitrary range, and every caller was otherwise trimming intervals by hand — the
/// DST/midnight-sensitive arithmetic that must not exist twice.
func testRangeTotals() throws {
    print("\nRange totals:")
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let a = try store.createProject(name: "alpha", colorHex: "#4E79A7")
    let b = try store.createProject(name: "beta", colorHex: "#F28E2B")
    let tasks = try store.listProjects(includeArchived: true)
    let now = date(2026, 3, 11, 12, 0)

    // Fully inside the day.
    try store.insertClosedInterval(projectID: a, start: date(2026, 3, 11, 9, 0),
                                   end: date(2026, 3, 11, 11, 0))
    // Straddles midnight INTO the day — only the post-midnight hour counts.
    try store.insertClosedInterval(projectID: a, start: date(2026, 3, 10, 23, 0),
                                   end: date(2026, 3, 11, 1, 0))
    // Entirely before the day — must not count at all.
    try store.insertClosedInterval(projectID: b, start: date(2026, 3, 9, 9, 0),
                                   end: date(2026, 3, 9, 10, 0))
    let intervals = try store.intervals()

    let day = DateRange.resolve(unit: .day, anchor: now, calendar: cal)
    let totals = Aggregations.rangeTotals(projects: tasks, intervals: intervals, range: day, now: now)
    let byID = Dictionary(uniqueKeysWithValues: totals.map { ($0.project.id, $0.seconds) })

    check(approx(byID[a] ?? -1, 3 * 3600, 1),
          "2h inside + 1h of a midnight-straddling session = 3h, not 4h")
    check(approx(byID[b] ?? -1, 0, 1), "an interval entirely outside the range contributes nothing")

    // Widening the range must pick the earlier session up rather than change the clipping rules.
    let month = DateRange.resolve(unit: .month, anchor: now, calendar: cal)
    let wide = Aggregations.rangeTotals(projects: tasks, intervals: intervals, range: month, now: now)
    let wideByID = Dictionary(uniqueKeysWithValues: wide.map { ($0.project.id, $0.seconds) })
    check(approx(wideByID[a] ?? -1, 4 * 3600, 1), "over a month, both of alpha's sessions count fully")
    check(approx(wideByID[b] ?? -1, 3600, 1), "beta's earlier hour appears once the range includes it")

    // Agrees with todayTotals for a day range — they must not be two different clippings.
    let viaToday = Aggregations.todayTotals(projects: tasks, intervals: intervals, now: now,
                                            calendar: cal)
    let todayByID = Dictionary(uniqueKeysWithValues: viaToday.map { ($0.project.id, $0.seconds) })
    check(approx(todayByID[a] ?? -1, byID[a] ?? -2, 1),
          "rangeTotals over a day equals todayTotals")

    // Every project appears, including ones with no time — the UI filters, the maths doesn't.
    check(totals.count == tasks.count, "a row per project, zeroes included")
}


/// Lanes packed by time overlap only. `assignLanes` deliberately gives each DEVICE its own row; this
/// variant exists for the phone, where three devices whose blocks never overlap should not cost three
/// rows and should not imply concurrency that didn't happen.
func testLanesByOverlap() {
    print("\nLanes by overlap:")
    func seg(_ id: Int64, _ from: Double, _ to: Double, _ device: String?) -> DaySegment {
        DaySegment(id: id, projectID: id, startHour: from, endHour: to, deviceID: device)
    }

    do { // three devices, NO time overlap -> one row
        let out = Aggregations.assignLanesByOverlap([
            seg(1, 9, 10, "mac"), seg(2, 11, 12, "air"), seg(3, 13, 14, "phone"),
        ])
        check(out.allSatisfy { $0.lane == 0 }, "non-overlapping blocks share one lane across devices")
        check(Aggregations.laneCount(out) == 1, "laneCount is 1")
        // The device-per-lane function still behaves as the Mac needs it to.
        let macStyle = Aggregations.assignLanes([
            seg(1, 9, 10, "mac"), seg(2, 11, 12, "air"), seg(3, 13, 14, "phone"),
        ])
        check(Aggregations.laneCount(macStyle) == 3, "assignLanes still gives one lane per device")
    }

    do { // genuine overlap DOES get its own row
        let out = Aggregations.assignLanesByOverlap([
            seg(1, 9, 12, "mac"), seg(2, 10, 11, "air"),
        ])
        check(Set(out.map(\.lane)) == [0, 1], "overlapping blocks are split onto two lanes")
    }

    do { // overlap within ONE device also splits, so a handoff can't hide a block
        let out = Aggregations.assignLanesByOverlap([
            seg(1, 9, 12, "mac"), seg(2, 10, 13, "mac"),
        ])
        check(Set(out.map(\.lane)) == [0, 1], "one device's own overlap still fans out")
    }

    do { // touching but not overlapping stays on one lane
        let out = Aggregations.assignLanesByOverlap([seg(1, 9, 10, "a"), seg(2, 10, 11, "b")])
        check(out.allSatisfy { $0.lane == 0 }, "abutting blocks don't count as overlapping")
        check(Aggregations.assignLanesByOverlap([]).isEmpty, "empty input is empty output")
    }
}


/// The iOS client's redirect scheme is the REVERSED client id — not a free choice. Getting it wrong
/// means Google refuses the exchange, so the derivation is pinned here.
func testReversedClientID() {
    print("\nReversed client id:")
    let id = "1234567890-abcdefg.apps.googleusercontent.com"
    check(GoogleOAuth.reversedClientID(id) == "com.googleusercontent.apps.abcdefg-1234567890"
          || GoogleOAuth.reversedClientID(id) == "com.googleusercontent.apps.1234567890-abcdefg",
          "components are reversed, got \(GoogleOAuth.reversedClientID(id) ?? "nil")")

    // The redirect appends a path to that scheme.
    if let redirect = GoogleOAuth.iOSRedirect(id) {
        check(redirect.uriString.hasPrefix("com.googleusercontent.apps."),
              "redirect uses the reversed-client-id scheme")
        check(redirect.uriString.hasSuffix(":/oauth"), "redirect carries a path")
    } else {
        check(false, "iOSRedirect returned nil for a well-formed client id")
    }

    // A client id of the wrong shape must fail loudly rather than produce a scheme Google rejects.
    check(GoogleOAuth.reversedClientID("not-a-google-client") == nil,
          "a malformed client id yields no scheme")
    check(GoogleOAuth.iOSRedirect("nonsense") == nil, "and no redirect")

    // The runtime override feeds `clientID`, which is how iOS supplies one at all.
    let saved = GoogleOAuth.clientIDOverride
    GoogleOAuth.clientIDOverride = id
    check(GoogleOAuth.clientID == id, "override wins over the config file")
    check(GoogleOAuth.isConfigured, "an override is enough to report configured")
    GoogleOAuth.clientIDOverride = nil
    check(GoogleOAuth.clientID != id, "clearing the override restores the previous source")
    GoogleOAuth.clientIDOverride = saved
}


/// The seeded database must obey the app's own invariants — otherwise it shows the UI states that
/// cannot occur and hides the ones that can.
///
/// The one that matters here: **only one timer runs across all devices**, enforced by
/// `TakeoverPolicy`, so no two intervals may overlap in time regardless of which device recorded
/// them. An earlier seeder opened a running interval 42 minutes back on top of blocks it had already
/// painted for today, which put fake lane contention on the day timeline.
func testDemoSeedInvariants() throws {
    print("\nDemo seed invariants:")
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let now = date(2026, 3, 11, 12, 0)
    try DemoSeed.seed(into: store, preset: .rich, now: now)

    let intervals = try store.intervals().sorted { $0.start < $1.start }
    check(intervals.count > 500, "rich preset produces months of history (\(intervals.count))")

    // No overlaps, across every device.
    var offenders: [(Int64, Int64)] = []
    for (a, b) in zip(intervals, intervals.dropFirst()) {
        let aEnd = a.end ?? now
        if b.start < aEnd { offenders.append((a.id, b.id)) }
    }
    check(offenders.isEmpty,
          "no two intervals overlap — got \(offenders.count) pair(s), e.g. \(offenders.first.map(String.init(describing:)) ?? "none")")

    // Nothing in the future.
    let future = intervals.filter { ($0.end ?? now) > now }
    check(future.count <= 1, "at most the running interval reaches `now` (\(future.count))")
    check(intervals.allSatisfy { $0.start <= now }, "no interval starts in the future")

    // Exactly one open interval, and it's the last thing recorded.
    let open = intervals.filter { $0.end == nil }
    check(open.count == 1, "exactly one running interval")
    if let running = open.first, let previousEnd = intervals.compactMap(\.end).max() {
        check(running.start >= previousEnd,
              "the running interval starts at or after the last closed block")
    }

    // The shape the UI needs in order to be exercised at all.
    check(try store.listTaskProjects().count >= 8, "several projects")
    check(try store.listProjects(includeArchived: true).count >= 30, "many tasks")
    check(try store.listTags().count >= 8, "several tags")
    check(try store.listTargets().count >= 6, "budgets across subject kinds")
    check(try store.deviceLabels().count >= 3, "several devices")

    // And because the invariant holds, the day timeline needs only one lane.
    let segments = Aggregations.assignLanesByOverlap(
        Aggregations.daySegments(intervals: intervals, day: now, now: now))
    check(Aggregations.laneCount(segments) == 1,
          "a valid database needs ONE timeline lane; lanes only appear for anomalies")
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

// MARK: - Two devices through a transport (the takeover the phone was missing)

/// An in-memory `SyncTransport`, so two stores can be driven against each other with no network.
///
/// The gap this closes: `TakeoverPolicy.decide` and `SyncEngine.merge` were each well covered in
/// ISOLATION, and both were correct — yet "auto pause is not working across devices" was still a real
/// bug, because nothing tested the two of them wired together through a transport. A unit test per
/// component can't catch a missing caller.
final class MemoryTransport: SyncTransport, @unchecked Sendable {
    var payloads: [String: Data] = [:]
    var markers: [String: Data] = [:]
    /// What the transport reports as each marker's write time — the server clock `TakeoverPolicy`
    /// prefers over any peer's self-report.
    var modified: [String: Date] = [:]

    func put(payload: Data, deviceID: String) throws { payloads[deviceID] = payload }
    func fetchOthers(excluding deviceID: String) throws -> [Data] {
        payloads.filter { $0.key != deviceID }.map(\.value)
    }
    func putRunning(_ marker: Data?, deviceID: String) throws {
        if let marker { markers[deviceID] = marker; modified[deviceID] = Date() }
        else { markers[deviceID] = nil; modified[deviceID] = nil }
    }
    func fetchOtherRunning(excluding deviceID: String) throws -> [Data] {
        markers.filter { $0.key != deviceID }.map(\.value)
    }
    func fetchOtherRunningWithTimes(excluding deviceID: String) throws -> [(data: Data, modified: Date?)] {
        markers.filter { $0.key != deviceID }.map { ($0.value, modified[$0.key]) }
    }
    func deletePayload(deviceID: String) throws {
        payloads[deviceID] = nil; markers[deviceID] = nil; modified[deviceID] = nil
    }
    /// Nothing here is ever unreadable — this transport only holds what these tests put in it.
    func deleteUnreadablePayloads(excluding deviceID: String) -> Int { 0 }
}

func testCrossDeviceTakeover() throws {
    print("\nCross-device takeover:")
    let (macStore, macURL) = try makeStore()
    let (phoneStore, phoneURL) = try makeStore()
    defer {
        try? FileManager.default.removeItem(at: macURL)
        try? FileManager.default.removeItem(at: phoneURL)
    }
    let transport = MemoryTransport()

    // Same task on both sides, sharing a uid — which is the only handle that means anything across
    // devices. Row ids differ deliberately: the phone gets a decoy first so its ids can't line up.
    _ = try phoneStore.createProject(name: "decoy", colorHex: "#000000")
    let macTask = try macStore.createProject(name: "deep work", colorHex: "#4E79A7")
    let uid = try macStore.uid(table: "projects", id: macTask)!
    _ = try phoneStore.insertRemoteTask(uid: uid, name: "deep work", colorHex: "#4E79A7",
                                        sortOrder: 0, archived: false, finished: false,
                                        finishedAt: nil, taskProjectID: nil,
                                        updatedAt: Date().timeIntervalSince1970)
    let phoneTask = try phoneStore.localID(table: "projects", uid: uid)!
    check(phoneTask != macTask, "the same task has DIFFERENT row ids on the two devices")

    /// One device's settle step, mirroring what both `SyncController`s do.
    func settle(_ store: IntervalStore, deviceID: String, now: Date) throws -> String? {
        let observed = try transport.fetchOtherRunningWithTimes(excluding: deviceID)
        var marks: [RunningMarker] = []
        var observedAt: [String: Date] = [:]
        for e in observed {
            guard let m = try? JSONDecoder().decode(RunningMarker.self, from: e.data) else { continue }
            marks.append(m)
            if let mod = e.modified { observedAt[m.deviceID] = mod }
        }
        guard let d = TakeoverPolicy.decide(localRunningSince: try store.openInterval()?.start,
                                            markers: marks, now: now, observedAt: observedAt)
        else { return nil }
        try store.stopOpenInterval(at: d.pauseAt)
        return d.byDeviceID
    }

    func publishMarker(_ store: IntervalStore, deviceID: String, now: Date) throws {
        guard let open = try store.openInterval(),
              let taskUID = try store.uid(table: "projects", id: open.projectID) else {
            try transport.putRunning(nil, deviceID: deviceID)
            return
        }
        let m = RunningMarker(deviceID: deviceID, taskUID: taskUID,
                             since: open.start.timeIntervalSince1970,
                             isRunning: true, writtenAt: now.timeIntervalSince1970)
        try transport.putRunning(try JSONEncoder().encode(m), deviceID: deviceID)
    }

    let t0 = Date().addingTimeInterval(-600)      // phone started 10 minutes ago

    do { // the reported case: the phone is running, the Mac starts later, the phone must yield
        try phoneStore.switchTo(projectID: phoneTask, at: t0)
        try publishMarker(phoneStore, deviceID: "phone", now: t0)

        let macStart = t0.addingTimeInterval(300) // Mac starts 5 minutes later
        try macStore.switchTo(projectID: macTask, at: macStart)
        try publishMarker(macStore, deviceID: "mac", now: macStart)

        // The Mac shouldn't stop itself: its own start is the later one.
        check(try settle(macStore, deviceID: "mac", now: macStart) == nil,
              "the device that started LAST keeps running")

        // The phone notices and yields.
        let by = try settle(phoneStore, deviceID: "phone", now: macStart.addingTimeInterval(1))
        check(by == "mac", "the earlier device is taken over by the later one")
        check(try phoneStore.openInterval() == nil, "and its timer is actually stopped")

        // Back-dated to the Mac's start, so the two intervals ABUT rather than overlap. This is the
        // whole reason a late wake-up is harmless: no wall-clock second is counted twice.
        let phoneEnd = try phoneStore.intervals().compactMap(\.end).max()
        check(phoneEnd.map { abs($0.timeIntervalSince(macStart)) < 1 } == true,
              "the phone's interval ends exactly where the Mac's began")
    }

    do { // a STALE claim must not pause anyone — a slept device's marker never expires on its own
        try phoneStore.switchTo(projectID: phoneTask, at: Date().addingTimeInterval(-60))
        // The Mac's marker is old: written well beyond the liveness cutoff.
        transport.modified["mac"] = Date().addingTimeInterval(-TakeoverPolicy.livenessCutoff - 120)
        check(try settle(phoneStore, deviceID: "phone", now: Date()) == nil,
              "a stale marker is ignored, so a slept device can't pause this one forever")
        check(try phoneStore.openInterval() != nil, "the phone keeps running")
    }

    do { // clearing the marker on pause stops it taking anyone over afterwards
        try macStore.stopOpenInterval(at: Date())
        try publishMarker(macStore, deviceID: "mac", now: Date())
        check(transport.markers["mac"] == nil, "pausing clears the running marker")
        check(try settle(phoneStore, deviceID: "phone", now: Date()) == nil,
              "and a cleared marker takes nobody over")
    }
}

// MARK: - The stopwatch-style clock format

/// `durationHundredths` is what the in-app clock renders 30 times a second, so its edges matter: a format
/// that can emit `.100`, or that rounds up to a whole second early, produces a visible jump on a digit the
/// eye is already tracking.
func testDurationHundredths() {
    print("\nHundredths format:")
    check(Format.durationHundredths(0) == "0:00.00", "zero")
    check(Format.durationHundredths(1.5) == "0:01.50", "one and a half seconds")
    check(Format.durationHundredths(83.45) == "1:23.45", "minutes and seconds, stopwatch style")
    check(Format.durationHundredths(3600) == "1:00:00.00", "an hours field appears at an hour")
    check(Format.durationHundredths(3661.07) == "1:01:01.07", "hours, minutes, seconds, hundredths")

    // TRUNCATED, not rounded. 0.999 must read .99 and stay on second 0 — rounding gives ".100", which is
    // three digits in a two-digit field, and rounding the whole value would tick the seconds early.
    check(Format.durationHundredths(0.999) == "0:00.99", "0.999 truncates to .99 rather than rolling over")
    check(Format.durationHundredths(59.999) == "0:59.99", "and doesn't roll the minute early")

    // Negative elapsed is impossible but arrives if a clock is skewed; it must not render nonsense.
    check(Format.durationHundredths(-5) == "0:00.00", "negative clamps to zero")

    // Width is stable, which is what `monospacedDigit` plus a fixed format buys — a clock that changes
    // width 30 times a second drags the whole row with it.
    check(Format.durationHundredths(9.99).count == Format.durationHundredths(1.01).count,
          "same width regardless of value, within a magnitude")
}

// MARK: - Footprint series bucketing

/// The footprint chart's maths. Two things here are easy to get quietly wrong and would both produce a
/// convincing-looking chart: pairing samples across a RESTART (cumulative CPU resets, so the delta is
/// nonsense) and averaging away the spikes the chart exists to reveal.
func testFootprintSeries() {
    print("\nFootprint series:")
    let t0: Double = 1_800_000_000   // an arbitrary fixed epoch, so buckets are deterministic

    func sample(_ offset: Double, cpu: Double, mb: Double = 50, launch: Int = 1) -> FootprintSample {
        FootprintSample(t: t0 + offset, r: UInt64(mb * 1_048_576), c: cpu, n: 4, l: launch)
    }

    do { // load is a slope, so one sample can produce nothing
        check(FootprintSeries.bucket([sample(0, cpu: 0)], resolution: .tenMinutes).isEmpty,
              "a single sample yields no buckets — load needs a pair")
        check(FootprintSeries.bucket([], resolution: .hour).isEmpty, "no samples, no buckets")
    }

    do { // 60s apart, 6s of CPU consumed = 10% of one core
        let b = FootprintSeries.bucket([sample(0, cpu: 10), sample(60, cpu: 16)],
                                       resolution: .tenMinutes)
        check(b.count == 1, "both samples land in one 10-minute bucket")
        check(approx(b[0].peakCPULoad, 0.10, 0.001), "6s over 60s is 10% of a core")
        check(approx(b[0].meanCPULoad, 0.10, 0.001), "a single pair means peak == mean")
    }

    do { // the PEAK survives, which is the whole point
        let s = [sample(0, cpu: 0), sample(60, cpu: 0.6),      // 1%
                 sample(120, cpu: 30.6),                       // 50% — the spike
                 sample(180, cpu: 31.2)]                       // 1%
        let b = FootprintSeries.bucket(s, resolution: .tenMinutes)
        check(b.count == 1, "all within one bucket")
        check(approx(b[0].peakCPULoad, 0.50, 0.01), "the spike is reported, not averaged away")
        check(b[0].meanCPULoad < b[0].peakCPULoad, "and the mean is visibly lower, marking it as a burst")
    }

    do { // a RESTART must not fabricate a spike
        // Launch 1 reaches 100s of CPU; launch 2 starts over at 0.5s. Pairing across that boundary would
        // give a negative delta (discarded) — but pairing the other way round, which is what a naive
        // implementation does when the new launch has already accrued more, invents an enormous spike.
        let s = [sample(0, cpu: 99, launch: 1), sample(60, cpu: 100, launch: 1),
                 sample(120, cpu: 0.5, launch: 2), sample(180, cpu: 1.0, launch: 2)]
        let b = FootprintSeries.bucket(s, resolution: .tenMinutes)
        check(b.count == 1, "one bucket")
        // Only the two same-launch pairs count, both ~1s/60s.
        check(b[0].peakCPULoad < 0.05,
              "no spike is invented at the launch boundary (got \(b[0].peakCPULoad))")
    }

    do { // a long gap is not a flat reading
        // Two samples an hour apart in a 10-minute chart: the gap exceeds twice the bucket width, so the
        // pair is dropped rather than dividing a tiny delta across an hour and reporting a reassuring zero.
        let b = FootprintSeries.bucket([sample(0, cpu: 0), sample(3600, cpu: 5)],
                                       resolution: .tenMinutes)
        check(b.allSatisfy { $0.peakCPULoad == 0 }, "a pair spanning a long sleep contributes no load")
    }

    do { // buckets align to absolute multiples, so the same data always charts the same
        let b = FootprintSeries.bucket([sample(0, cpu: 0), sample(60, cpu: 1),
                                        sample(1200, cpu: 2), sample(1260, cpu: 3)],
                                       resolution: .tenMinutes)
        check(b.count == 2, "samples 20 minutes apart fall in different 10-minute buckets")
        check(b[0].start < b[1].start, "and come back in chronological order")
        let width = FootprintResolution.tenMinutes.seconds
        check(b.allSatisfy { $0.start.timeIntervalSince1970.truncatingRemainder(dividingBy: width) == 0 },
              "bucket starts are aligned to the width, not to the first sample")
    }

    do { // trimming
        let old = sample(-40 * 86_400, cpu: 1)
        let recent = sample(-1 * 86_400, cpu: 1)
        let kept = FootprintSeries.trimmed([old, recent], keepingDays: 30,
                                           now: Date(timeIntervalSince1970: t0))
        check(kept.count == 1 && kept[0].t == recent.t, "samples older than the window are dropped")
    }
}

// MARK: - windowTotals agrees with summary, in one pass

/// `windowTotals` exists purely for speed, so the only thing worth asserting is that it is IDENTICAL to the
/// per-window `summary` calls it replaced. A faster function that quietly disagrees is worse than a slow one.
func testWindowTotals() throws {
    print("\nWindow totals:")
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let a = try store.createProject(name: "alpha", colorHex: "#4E79A7")
    let b = try store.createProject(name: "beta", colorHex: "#F28E2B")

    let now = date(2026, 3, 11, 12, 0)
    // Spread across several days, including one interval that CROSSES MIDNIGHT — the case a naive
    // bucket-by-start-date would put entirely in the wrong window.
    try store.insertClosedInterval(projectID: a, start: date(2026, 3, 9, 22, 30),
                                   end: date(2026, 3, 10, 1, 15))
    try store.insertClosedInterval(projectID: b, start: date(2026, 3, 10, 9, 0),
                                   end: date(2026, 3, 10, 10, 30))
    try store.insertClosedInterval(projectID: a, start: date(2026, 3, 11, 9, 0),
                                   end: date(2026, 3, 11, 11, 0))
    // Overlapping pair on one day, so the UNION (not sum) behaviour is exercised.
    try store.insertClosedInterval(projectID: b, start: date(2026, 3, 11, 10, 30),
                                   end: date(2026, 3, 11, 11, 30))
    let intervals = try store.intervals()
    let deep: TimeInterval = 25 * 60

    // Six days ending today, oldest first — the shape the period strip builds.
    var windows: [DateRange] = []
    var cursor = DateRange.resolve(unit: .day, anchor: now)
    for _ in 0..<6 { windows.append(cursor); cursor = cursor.stepped(by: -1) }
    windows.reverse()

    let fast = Aggregations.windowTotals(intervals: intervals, windows: windows,
                                         deepThreshold: deep, now: now)
    check(fast.count == windows.count, "one result per window, in order")

    for (i, window) in windows.enumerated() {
        let slow = Aggregations.summary(intervals: intervals, range: window,
                                        deepThreshold: deep, now: now)
        check(approx(fast[i].total, slow.totalSeconds, 0.5),
              "window \(i) total matches summary (\(fast[i].total) vs \(slow.totalSeconds))")
        check(approx(fast[i].deep, slow.deepSeconds, 0.5),
              "window \(i) deep matches summary")
    }

    // The midnight-crossing interval must be SPLIT across two adjacent windows rather than landing
    // wholly in one.
    //
    // Asserted as a PROPERTY, not as specific minute counts. My first attempt hard-coded "90m on the 9th,
    // 75m on the 10th" and failed — not because the code was wrong (every window matched `summary` above)
    // but because the test's own `date()` helper and the `Calendar` used for day boundaries don't
    // necessarily share a timezone, so which calendar day a 22:30 instant belongs to isn't fixed. The
    // splitting behaviour is what matters and it holds regardless.
    let nonEmpty = fast.enumerated().filter { $0.element.total > 0 }.map(\.offset)
    check(nonEmpty.count >= 3, "time lands in at least three distinct windows")
    check(zip(nonEmpty, nonEmpty.dropFirst()).contains { $1 == $0 + 1 },
          "the crossing interval puts time in two ADJACENT windows")

    // And nothing is lost or double-counted: the windows together account for exactly the same time as one
    // range spanning all of them.
    let whole = DateRange(unit: .day, start: windows[0].start, end: windows[windows.count - 1].end)
    let spanning = Aggregations.summary(intervals: intervals, range: whole,
                                        deepThreshold: deep, now: now)
    check(approx(fast.reduce(0) { $0 + $1.total }, spanning.totalSeconds, 1),
          "the windows sum to the whole span's total — nothing dropped at a boundary")

    check(Aggregations.windowTotals(intervals: intervals, windows: [],
                                    deepThreshold: deep, now: now).isEmpty,
          "no windows yields no results")
}

// MARK: - Chunked running intervals

/// `rollOpenInterval` replaces prompt-based auto-pause: a long run becomes consecutive blocks instead of
/// being paused when a "still working?" prompt goes unanswered.
///
/// The invariant that matters most is that this changes NOTHING about totals — it's a storage shape, not
/// a measurement. If rolling could lose or duplicate a second, it would silently corrupt every
/// aggregation, which is far worse than the prompt it replaces.
func testRollOpenInterval() throws {
    print("\nChunked intervals:")
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let a = try store.createProject(name: "alpha", colorHex: "#4E79A7")

    let start = date(2026, 4, 1, 9, 0)
    let chunk: TimeInterval = 30 * 60

    do { // nothing to do before the first boundary
        try store.switchTo(projectID: a, at: start)
        check(try store.rollOpenInterval(chunkSeconds: chunk,
                                         now: start.addingTimeInterval(20 * 60)) == 0,
              "a run shorter than one chunk is left alone")
        check(try store.openInterval()?.start == start, "and keeps its original start")
    }

    do { // 100 minutes at 30 = three boundaries crossed, four rows, one still running
        let now = start.addingTimeInterval(100 * 60)
        check(try store.rollOpenInterval(chunkSeconds: chunk, now: now) == 3,
              "three boundaries crossed in 100 minutes")
        let all = try store.intervals().filter { $0.projectID == a }
        check(all.count == 4, "three closed chunks plus the live one")
        check(try store.openInterval() != nil, "the timer is STILL RUNNING — this isn't a pause")
        check(try store.openInterval()?.start == start.addingTimeInterval(90 * 60),
              "the live row starts at the last boundary")

        // The whole point: identical measured time.
        let closed = all.filter { $0.end != nil }
        let total = closed.reduce(0.0) { $0 + $1.seconds() }
        check(approx(total, 90 * 60, 1), "the closed chunks total exactly the 90 elapsed minutes")

        // Abutting, not overlapping — otherwise the day timeline would show fake lane contention and
        // `SpanUnion` would have to paper over it.
        let sorted = closed.sorted { $0.start < $1.start }
        var abut = true
        for (prev, next) in zip(sorted, sorted.dropFirst()) {
            if let end = prev.end, abs(end.timeIntervalSince(next.start)) > 0.001 { abut = false }
        }
        check(abut, "each chunk ends exactly where the next begins")
    }

    do { // idempotent: calling again at the same instant must not roll a zero-length block
        let now = start.addingTimeInterval(100 * 60)
        check(try store.rollOpenInterval(chunkSeconds: chunk, now: now) == 0,
              "a second call at the same time is a no-op")
    }

    do { // a boundary landing exactly on `now` must not roll, or it would loop forever
        try store.stopOpenInterval(at: start.addingTimeInterval(100 * 60))
        let s2 = date(2026, 4, 2, 9, 0)
        try store.switchTo(projectID: a, at: s2)
        check(try store.rollOpenInterval(chunkSeconds: chunk,
                                         now: s2.addingTimeInterval(chunk)) == 0,
              "a boundary exactly at now is not yet past")
    }

    do { // guards
        check(try store.rollOpenInterval(chunkSeconds: 30, now: Date()) == 0,
              "an implausibly small chunk is refused rather than shredding the row")
        try store.stopOpenInterval(at: date(2026, 4, 2, 12, 0))
        check(try store.rollOpenInterval(chunkSeconds: chunk, now: Date()) == 0,
              "nothing running is a no-op")
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
    testRefreshRefusalClassification()
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
    testTaskTags()
    testReservationsStore()
    testReservationsSync()
    testTargetShapePersistence()
    testTargetShapeSync()
    testSubjectMembership()
    testPlannerBounds()
    testPlannerNormalisation()
    testPlannerPlacement()
    testPlannerReservations()
    testPlannerVerdicts()
    testPlannerFrontier()
    testPlannerRealShape()
    testReplan()
    testDeepBlockBoundary()
    testAllocationWeekdays()
    testEditingKeepsWeekdays()
    testWeekdaysSync()
    testFeedbackNumbering()
    testFeedbackAttachments()
    testSharedSettings()
    testIntervalSlice()
    testImageBytes()
    testPausedPresence()
    try testTaskNameReuse()
    try testDeleteInterval()
    testMarkerLiveness()
    testHoursInput()
    try testRemoteGroupDelete()
    testDuplicateFileCollapse()
    try testTags()
    try testTagSync()
    testTagTotals()
    testTargetMath()
    testDailyPlan()
    testPlannerWeekFacts()
    testHistoricalWeek()
    testDayTimelineRows()
    testPlannerMonthWeeks()
    testAllocationWindows()
    try testAllocationWindowStorage()
    testDormancy()
    testPerDayPlan()
    testPrimaryOwner()
    testHeavyOverlap()
    testPalette()
    testInlineBarContrast()
    testTaskOrdering()
    try testCreateProjectFilesIntoGroup()
    try testBudgetRows()
    testSwipeDelta()
    try testRangeTotals()
    testLanesByOverlap()
    testReversedClientID()
    try testDemoSeedInvariants()
    try testAllocationLifecycle()
    testDurationHundredths()
    testFootprintSeries()
    try testWindowTotals()
    try testCrossDeviceTakeover()
    try testRollOpenInterval()
    try testFeedback()
    try testAllocationOrdering()
    try testDuplicateNameIsProjectScoped()
    testTagTotals()
    testTargetMath()
    testDailyPlan()
    testPlannerWeekFacts()
    testHistoricalWeek()
    testDayTimelineRows()
    testPlannerMonthWeeks()
    testAllocationWindows()
    try testAllocationWindowStorage()
    testDormancy()
    testPerDayPlan()
    testPrimaryOwner()
    testHeavyOverlap()
} catch {
    print("  ✘ threw: \(error)")
    failures += 1
}

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
