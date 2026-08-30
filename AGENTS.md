# AGENTS.md — Timeslice

Orientation for an AI agent setting up or working on this project on a fresh host. Read this
first, then `README.md` for the feature-level picture.

## What this is

A native macOS menu-bar time tracker. Pure Swift Package Manager, local SQLite, no server, no
network. Two targets: `TimesliceCore` (UI-free logic + sqlite3) and `TimesliceApp` (AppKit/SwiftUI).

## Set it up on this machine

Run these in order from the repo root. Stop and report if any step fails.

```bash
# 1. Prerequisites
sw_vers -productVersion                       # must be >= 14.0
swift --version                               # must be Swift 6.x
xcode-select -p || xcode-select --install     # CLT provides `swift`; no full Xcode needed

# 2. Verify the code compiles and the logic is correct BEFORE installing
swift build                                   # expect: Build complete
swift run TimesliceSelfTest                   # expect: "N passed, 0 failed"

# 3. Build the .app, install to /Applications, and launch
./scripts/install.sh                          # ends with "✅ Timeslice installed"
```

Confirm success:

```bash
pgrep -lf "/Applications/Timeslice.app"       # should print a PID (app is running)
ls ~/Library/Application\ Support/Timeslice/timeslice.db   # DB created on first launch
```

## The one thing you CANNOT automate

The global hotkeys (`fn+⌘+⇧+…`) need **Accessibility permission**, which macOS only grants via a
manual human toggle at **System Settings → Privacy & Security → Accessibility**. You must *ask
the user* to enable "Timeslice" there — there is no CLI/API to flip it. Everything else (tracking,
metrics, popover, menu bar) works without it, so the app is fully usable before this step.

Why it's required: reading the `fn` key and detecting chord *release* need a `CGEventTap`, which
is Accessibility-gated. See `GlobalHotkeyManager.swift`.

## Signing & the Accessibility grant (important for iterating)

`install.sh` ad-hoc signs the app (`codesign -s -`), so it installs with no prompts. macOS ties
the Accessibility grant to the code signature, and an ad-hoc signature changes on every build:
**after you rebuild + reinstall, ask the user to re-enable Accessibility.** Installing once and
using it keeps the grant across restarts, so a user who never rebuilds only grants it a single time.

## Dev loop

```bash
swift build                 # compile
swift run TimesliceApp      # fast UI iteration (menu-bar item appears; ad-hoc, unbundled)
swift run TimesliceSelfTest # run the core-logic checks — ALWAYS run after touching TimesliceCore
./scripts/install.sh        # produce + install the real .app (for hotkey/privacy testing)
```

Notes:
- Tests are an executable (`TimesliceSelfTest`), **not** XCTest/swift-testing — those bundles
  aren't available under Command Line Tools. Add checks there when you change `Aggregations` or
  `IntervalStore`.
- `zsh` has `noclobber` on this setup: redirect build logs with `>|`, not `>`, or the write is
  refused with "file exists".
- Screen capture (`screencapture`) needs its own TCC grant; you generally can't screenshot the UI
  headlessly to verify it — rely on `swift run TimesliceSelfTest` + sqlite inspection instead.

## Working on the iPhone app

`ios/` is a thin Xcode shell around the same SwiftPM package (the Dynamic Island is an app
extension, which SwiftPM cannot express). If you are building the iOS app, read **both**:

- `~/workspace/persona/Notes/Projects/timeslice/artifacts/ios_full_parity.md` — the plan: review of
  what exists, the gap to the Mac app, feature spec, build order, and the traps not to rediscover.
- `ios/README.md` — how to generate the project, build, and run it.

The iOS work happens on the `feat/ios` branch, checked out as a git worktree at
`~/workspace/persona/timeslice-ios`. Rebase it on `main` before each phase so the phone never drifts
from the Mac.

## iOS: what will bite you

Hard-won, in rough order of how much time each one costs to rediscover. All of it was verified on
Xcode 26 / iOS 26 simulators.

### Build settings that are load-bearing and silent

Both live in `ios/project.yml`. Neither failure produces an error — you get a working build that
misbehaves at runtime.

- **`ENABLE_DEBUG_DYLIB: NO`.** Xcode 16+ defaults Debug builds to moving every symbol into
  `<Product>.debug.dylib`, leaving the main executable a ~58KB launcher stub. **AppIntents discovers
  `AppShortcutsProvider` by scanning the main executable**, so App Shortcuts break with
  `"Couldn't find AppShortcutsProvider"` while the on-disk metadata bundle looks perfect. Check it:

  ```bash
  nm -a "$APP/Timeslice" | grep -c YourProviderType   # must be > 0, and no *.debug.dylib in the bundle
  ```

- **`CODE_SIGN_IDENTITY: "-"`, never `CODE_SIGNING_ALLOWED: NO`.** Disabling signing skips the
  codesign step entirely, leaving only the linker stub: `Identifier` becomes the *binary name*
  instead of the bundle id, `Info.plist=not bound`, `Sealed Resources=none`. System services then
  reject the bundle. Ad-hoc (`-`) needs no team and does seal it. Check it:

  ```bash
  codesign -dv "$APP"    # want Identifier=com.timeslice.ios, Info.plist entries=N, Sealed Resources
  ```

### Do not compile AppIntents types into two targets

A widget extension needs an intent's *type* to render `Button(intent:)`, which tempts you into
putting intents in a shared file compiled into both targets. That ships **two** AppIntents metadata
bundles declaring the same intent identifiers, only one with an `AppShortcutsProvider`, and provider
resolution can bind to the wrong one. If both app and extension need an intent, hoist it into a
library they both *link* (one type, one registration) with the app supplying the behaviour.

Verify what each target actually publishes:

```bash
plutil -p "$APP/Metadata.appintents/extract.actionsdata" | grep -E 'autoShortcutProviderMangledName|"identifier"'
ls "$APP/PlugIns/"*.appex/Metadata.appintents 2>/dev/null   # usually should NOT exist
```

Also confirm the extractor is happy — it is quiet on success and quiet on failure:

```bash
xcodebuild … | grep -A4 "ExtractAppIntentsMetadata (in target 'YourApp'"
# want "Writing Metadata.appintents"; "Extracted no relevant App Intents symbols" for the app target is a bug
```

### The project is generated — edit the spec

`ios/project.yml` is the source of truth. `ios/Timeslice.xcodeproj` **and both `Info.plist` files**
are generated and gitignored. `info: path:` in XcodeGen means *generate that file*, so a hand-written
plist is silently overwritten on the next `xcodegen generate` — which is how `NSSupportsLiveActivities`
and the widget's `NSExtensionPointIdentifier` went missing once. Put plist keys in `info.properties`.

### Verifying without a human

Contrary to what the plan doc says, **screenshots work fine on the iOS Simulator** — the TCC
restriction applies to capturing the macOS desktop. `xcrun simctl io booted screenshot` is the single
most valuable tool here; it caught a duplicated section, a modal over first launch, a five-cards
layout bug and a wrong-semantics timer that no test would have.

```bash
xcrun simctl install booted "$APP"                                 # install FIRST
C=$(xcrun simctl get_app_container booted com.timeslice.ios data)  # UUID CHANGES on every install
printf metrics > "$C/Library/Application Support/Timeslice/start-tab"
xcrun simctl terminate booted com.timeslice.ios && xcrun simctl launch booted com.timeslice.ios
xcrun simctl io booted screenshot /tmp/shot.png
xcrun simctl spawn booted log show --last 60s --predicate 'process == "Timeslice"'
```

Resolve the container **after** installing, or you write to a dead path and see no effect.

`simctl` cannot tap. The app therefore reads a `start-tab` file beside its database to preselect a
tab or open a sheet (`tasks|metrics|switcher|settings`). Four other mechanisms were tried and each
silently did nothing: launch arguments (swallowed by simctl), `SIMCTL_CHILD_*` (arrives nil), a
global-domain `defaults write` (wrong domain), and a container plist write (`cfprefsd` caches it).
Extend the file hook rather than rediscovering that.

### What the Simulator genuinely cannot do

Stop debugging these there; they need hardware or a human tap.

| Thing | Why |
|---|---|
| Action Button | No physical button. The Settings pane exists, so assignment is exercisable, the press is not. iPhone 15 Pro and later. |
| Running an App Shortcut | `simctl` can't tap Run, and `shortcuts://run-shortcut?name=` does not address App Shortcuts. `linkd` also rejects ad-hoc-signed apps with `requiresValidBundle`. |
| Notification delivery | `xcrun simctl privacy` has no `notifications` service, so authorization needs a human tap of Allow. Scheduling *is* checkable via `getPendingNotificationRequests`. |
| `BGTaskScheduler` | Unsupported; `submit` returns `BGTaskSchedulerErrorDomain error 1` (.unavailable). Registration still succeeds. Foregrounding is the testable sync path. |
| Live Activity buttons | Need the expanded island, which needs a long press. |

The simulator's clock can also be hours off wall-clock time. That once made a whole day of seeded
data look missing when it was actually 00:50, not 12:50 — check `date` inside the simulator before
concluding data is wrong.

### Putting the app on a real iPhone

The Simulator table above says several things "need hardware". Getting there is mostly one-time
human setup — do not burn an hour trying to automate the parts that cannot be.

**What an agent can do:** detect the device (`xcrun devicectl list devices`), build, install
(`xcrun devicectl device install app --device <UDID> <path>`), launch, and read logs.

**What requires a human, with no CLI equivalent:**

- **An Apple ID in Xcode** (Settings → Accounts). This mints the signing certificate. Check with
  `security find-identity -v -p codesigning` — "0 valid identities found" means stop and ask.
- **Developer Mode on the phone** (Settings → Privacy & Security → Developer Mode, then reboot).
  Without it install fails with `CoreDeviceError 10005`.
- **Trusting the certificate** (Settings → General → VPN & Device Management). Without it the app
  installs but refuses to launch: *"invalid code signature, inadequate entitlements or its profile
  has not been explicitly trusted"*.

**Signing for a device build is a command-line override, not a spec edit.** `project.yml`'s ad-hoc
`CODE_SIGN_IDENTITY: "-"` is correct for the Simulator; a device build passes a real team instead:

```bash
xcodebuild -project ios/Timeslice.xcodeproj -scheme TimesliceiOS \
  -sdk iphoneos -configuration Debug -derivedDataPath build-device \
  DEVELOPMENT_TEAM=XXXXXXXXXX CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES -allowProvisioningUpdates
```

A Personal Team certificate **expires after 7 days** — "it stopped opening" usually means rebuild,
not a bug.

**Changing the bundle id is a `project.yml` edit, never an Xcode one.** A fork cannot register
`com.timeslice.ios` (it belongs to this account), so the id must change — and because the project is
generated, editing it in Xcode's GUI is silently reverted by the next `xcodegen generate`. Worse, the
GUI only changes the target you are looking at, leaving the widget's id no longer prefixed by the
app's: *"Embedded binary's bundle identifier is not prefixed with the parent app's bundle
identifier."* Change **both**, in the spec, together.

`BGTaskSchedulerPermittedIdentifiers` and the keychain service are separate identifier strings that
do **not** have to track the bundle id — leave them alone.

### Sync on iOS needs an *iOS* OAuth client, pasted at runtime

The Mac reads `~/.config/timeslice/env`; a phone has no such path, so the client id is typed into
Settings → Sync and the "Sign in with Google" button stays disabled until it is non-empty. A button
that "does nothing" is almost always this, not a broken handler.

It must be an **iOS** client (no secret, redirect derived from the reversed client id), created
against **this build's** bundle id — not the Desktop client the Mac uses, and not the id in the
on-screen help text if the fork renamed itself.

### Never touch a transport from the main actor

`DriveSyncTransport.blocking()` traps on the main thread — `assertionFailure`, so **Debug builds
crash and Release builds silently misbehave**. The guard is deliberate: the semaphore would deadlock
against async work that needs the main actor to proceed.

Both platforms hit this, and both fixed it the same way: the sync body is `nonisolated`, transport
I/O runs off the actor, and only `IntervalStore` work hops back via `MainActor.run` (the store is not
`Sendable` and belongs to a `@MainActor` owner). See `SyncController.performSync` on either side.

The trap is easy to reintroduce, because a plain method on a `@MainActor` class inherits that
isolation **even when called from `Task.detached`**. If you add a sync entry point, mark it
`nonisolated` and hop back only for store access. Symptom to recognise: the app dies immediately
after Google sign-in completes, since that path ends in a sync.

### Share logic through Core, always

The phone must not recompute anything the Mac already does; that is how the two silently diverge.
Already hoisted into `TimesliceCore` for exactly this reason — call these, don't reimplement:
`Palette` (colours **and** `displayColorHex` shade derivation), `TaskOrdering.recencyOrdered`,
`TaskSearch.groupNames`, `BudgetRows` (row composition, `duration`, verdict `rank`),
`Aggregations.rangeTotals`, `Aggregations.assignLanesByOverlap`, `AppSettings` (shared UserDefaults
keys and thresholds), `TimeScope`, `DemoSeed`. Shared SwiftUI lives in `TimesliceUI`
(`Theme`, `InlineBar`, `Sparkline`, `Format`, `Color(hex:)`).

`AppSettings` is named that, not `Settings`, because SwiftUI exports a `Settings` scene type and the
bare name is ambiguous once it crosses modules.

### Cross-device data must obey the one-timer invariant

Only one timer runs across all devices — `TakeoverPolicy` back-dates the loser. **Overlapping
intervals cannot occur in real data**, so a day timeline needs exactly one lane; lanes are for
anomalies. Anything that writes intervals (seeders, fixtures, merge code) must not create overlap.
`DemoSeed` produced 129 overlapping pairs before this was pinned by tests. Verify:

```bash
sqlite3 "$DB" "SELECT COUNT(*) FROM intervals a JOIN intervals b ON a.id<b.id
  AND b.start_utc < COALESCE(a.end_utc, strftime('%s','now'))
  AND a.start_utc < COALESCE(b.end_utc, strftime('%s','now'));"   # must be 0
```

Seed realistic data with `swift run TimesliceSeed --preset rich --db <path>` (`--preset screenshot`
reproduces the Mac's original fixture exactly). Pointing it at a simulator container works because
that database is an ordinary file, and going through `IntervalStore` keeps uids, `updated_at` and
migrations correct in a way hand-written SQL would not.

### Cross-platform Swift gotchas

- `#if canImport(UIKit)` branches **cannot be typechecked by a macOS build**. A missing argument
  label in a UIKit-only branch compiled clean on the Mac. After editing one arm, compile the other:
  `xcrun --sdk iphoneos swiftc -target arm64-apple-ios17.0 -typecheck Sources/TimesliceUI/*.swift`
- *Unavailable* is not *unused*: `homeDirectoryForCurrentUser` is `API_UNAVAILABLE(ios)` and fails to
  compile even inside a `??` fallback that could never run there. Use `NSHomeDirectory()`.
- The model sysctl key differs and the naming is backwards: macOS uses `hw.model` (`hw.machine` is
  just `arm64`); iOS puts the board id in `hw.model` and the model in `hw.machine`.
- Applying a modifier to multi-view `@ViewBuilder` content distributes it across **each** child of
  the TupleView. `.background` on a section's content rendered five separate cards. Wrap in a
  container first.
- `TabView` restores its previous selection across launches, overriding a `@State` initial value.
  Set the selection in `onAppear` too if a launch hint must win.

### Debugging method, learned the hard way

- **Read the OS log before changing code.** `xcrun simctl spawn booted log show --last 5m --predicate
  '…'` gave the exact cause of an App Shortcuts failure after five speculative fixes had missed it.
  The decisive detail was *which process* emitted the error.
- **Investigate a surprising probe instead of dismissing it.** `nm` reporting 123 symbols and none of
  the app's types was written off as "symbols are stripped". It was the actual bug — the code was in a
  debug dylib. A 58KB executable should have raised the question.
- **Read Apple's docs early.** The reference pages are JS-rendered; fetch
  `https://developer.apple.com/tutorials/data/documentation/<path>.json` instead.

## Where things live

- `Sources/TimesliceCore/` — `IntervalStore` (sqlite3, schema + migrations), `Aggregations`
  (Calendar-based day/hour bucketing, focus %, switches, day timeline), `Models`, `TimeslicePaths`.
- `Sources/TimesliceApp/` — `main` (`@main`, `.regular` activation), `AppDelegate` (wires
  everything + global-hotkey callbacks + menu), `TimerEngine` (+ `TickClock` for the 10fps live
  clock), `AppState`, `Settings`, `StatusBarController` (menu bar + popover), `GlobalHotkeyManager`
  (CGEventTap), `PrivacyController`, `MainWindowController`, `Views/`.
- `Tests/TimesliceSelfTest/main.swift` — assertion harness + checks.
- `scripts/` — `install.sh`, `build_native_app.sh`, `Info.plist`, `Timeslice.entitlements`,
  `make_icon.swift` (+ generated `Timeslice.icns`).

Data: `~/Library/Application Support/Timeslice/timeslice.db` (WAL). Deleting it resets all data.

## Conventions

- Keep `TimesliceCore` UI-free so it stays unit-testable.
- All day/hour math uses `Calendar` in Swift (not SQLite `localtime`) for correct DST/midnight
  handling.
- One running interval max — enforced by a partial unique index on a `running` flag (a NULL-based
  index does NOT work in SQLite). Don't bypass `IntervalStore.switchTo/pause/stop`.
