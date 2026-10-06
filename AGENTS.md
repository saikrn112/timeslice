# AGENTS.md — Timeslice

Orientation for an AI agent working on this project. Read this first, then `README.md` for the
feature-level picture. Everything here was learned by getting it wrong at least once.

## What this is

A native macOS menu-bar time tracker with an iPhone companion. Pure Swift Package Manager, local SQLite
per device, and **opt-in** sync through the user's own Google Drive (`appDataFolder`) — no server of our
own. Off by default; the app is fully local-first without it.

| Target | What it is |
|---|---|
| `TimesliceCore` | All logic, UI-free, sqlite3. **Anything both platforms need lives here.** |
| `TimesliceUI` | Shared SwiftUI: `Theme`, bars, rings, `Format`, the planner week grid. |
| `TimesliceApp` | The Mac app (AppKit + SwiftUI). |
| `TimesliceIntents` | App Intents shared by the phone app and its widget extension. |
| `TimesliceSelfTest` | The test suite — an executable, not XCTest. |
| `TimesliceSeed` | Seeds realistic data into any database file (`--preset rich`, `--preset screenshot`). |
| `TimeslicePlan` | Prints the Planner's computation for a real database, read-only. |
| `TimesliceTrim` | Interval corrections and overlap cleanup, through the store's own APIs. |
| `TimesliceWindowID`, `TimesliceHover` | Helpers for `scripts/shot.sh` (window lookup, cursor warp). |

`ios/` is a thin Xcode shell around the same package — see "Working on the iPhone app" below.

## Ground rules from the owner

These are standing instructions, not preferences to weigh.

- **Commit to `main` and push.** Only two branches exist: `main` and `feat/ios-metrics`. Don't create
  others.
- **No `Co-Authored-By` lines** in commit messages. Messages explain *why*, with the evidence — the
  history is how the next agent learns what was tried.
- **Project docs live in the Obsidian vault**, `~/workspace/persona/Notes/Projects/timeslice/artifacts/`,
  never in a `docs/` folder here.
- **Never mark the user's feedback notes as done.** The in-app feedback list is theirs to resolve after
  checking a fix themselves.
- **Tooltips are terse data rows, not advice.** `office  28.9h of 35h` — not a sentence telling the user
  what to do. Prose tooltips were rejected repeatedly.
- **Ask one plain question at a time**, using the user's own data as the example. Multi-part abstract
  questions get "I didn't understand half of these".
- **The user may be away while you work and won't see interleaved messages.** Never design a step that
  needs them to press keys at a precise moment. Leave a background probe writing to a file, or ask them
  to do it whenever and read the result next turn.

## Set it up

```bash
sw_vers -productVersion        # >= 14.0
swift --version                # Swift 6.x — Command Line Tools are enough for the Mac app
swift build                    # expect: Build complete
swift run TimesliceSelfTest    # expect: "N passed, 0 failed"
./scripts/install.sh           # builds, ad-hoc signs, installs to /Applications, launches
```

The database is `~/Library/Application Support/Timeslice/timeslice.db` (WAL). Treat it as production:
it is the user's real record and it syncs to their other devices.

## Accessibility, hotkeys, and the install that breaks them

The global hotkeys (`fn+⌘+⇧+\`/`]`/`A`/`P`) need a `CGEventTap`, which needs **Accessibility**. Only a
human can grant it, in System Settings → Privacy & Security → Accessibility.

What will happen to you:

1. **`install.sh` revokes the grant.** It ad-hoc signs, the signature changes every build, and the
   grant is tied to the signature. Confirmed from the app's own log, not just folklore. So **batch your
   installs**: get every change in, install once, then ask the user to re-grant.
2. **A grant added after launch is not picked up.** macOS caches "not trusted" for the running process,
   and the two-second permission poll retries against that cached answer forever. The user must
   **quit and reopen Timeslice** after toggling. Say so explicitly, every time; it is the step that
   gets skipped.
3. **Secure Input kills every event tap and looks like nothing at all.** If a password field turned on
   secure keyboard entry and it got stuck, the system delivers no keys to any tap. Permission, tap
   creation and `CGGetEventTapList` all report perfect health; the callback simply never fires. A
   restart clears it. This cost a day of chasing the fn key, which was innocent.

Diagnose in this order and stop at the first failure:

```bash
# 1. Granted?  auth_value 2 = yes
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select auth_value, datetime(last_modified,'unixepoch','localtime') from access
   where service='kTCCServiceAccessibility' and client like '%timeslice%';"
# 2. Launched AFTER the grant? Compare with the grant time above.
ps -eo pid,lstart,command | grep /Applications/Timeslice.app | grep -v grep
# 3. Secure Input on? Any value here means no tap receives keys.
ioreg -l -w 0 | grep -o 'kCGSSessionSecureInputPID"=[0-9]*'
# 4. What the tap itself saw.
cat ~/Library/Application\ Support/Timeslice/hotkeys.log
```

`hotkeys.log` records the tap installing, a `tapCreate` failure, and any `\`/`]` arriving with an
incomplete chord (naming which modifiers were set). It is a file because **`NSLog` from this app reaches
nothing**: `log show` finds zero entries for the process at every level, even at launch. Don't spend time
on the unified log for the Mac app.

The app surfaces all of this itself now: the gear in the main window carries an orange badge for dead
hotkeys, Secure Input, a signed-out sync, a failed sync, and a sync that's gone quiet for 6h.

## Verifying UI: screenshots work, and they are the main tool

Older notes said the Mac UI can't be screenshotted headlessly. That was wrong, and believing it cost four
blind rounds of Planner redesign. With the Screen Recording grant, `scripts/shot.sh` builds from source,
launches a debug copy against a **copy** of the real database, and captures its window by id:

```bash
scripts/shot.sh planner /tmp/p.png 760 900      # tab: projects | metrics | planner
```

Roughly a dozen real defects were found this way that no test would have caught — a two-column
"today", a 40000h goal, a stale verdict, a ragged tile row. **Look at the screenshot before saying
something works.**

Environment hooks, all optional:

| Var | Effect |
|---|---|
| `PLANNER_UNIT=week\|month`, `PLANNER_OFFSET=N` | Planner period. **Positive N = N periods in the past.** |
| `RES=week\|day`, `METHOD`, `INTENDED=1` | Month resolution, allocation method, intended vs actual |
| `UNIT=day\|week\|month`, `SELECT=<allocation name>` | Metrics range, and pin an allocation |
| `SCROLL=bottom`, `HOVER="x,y"` | Scroll the page; hover a point so a tooltip is captured |
| `SETTINGS=1`, `ALLOC=1`, `CUSTOM=<name>` | Open the settings popover / allocations sheet / custom editor |
| `PALETTE=1`, `PALETTE_Q="name /proj"` | Open the task palette, pre-filled |
| `SYNC_WARN=1\|hotkeys` | Force the gear badge's sync or hotkey message |
| `MICROPAUSE=<s>`, `WAKING=<h>`, `DORMANT=<d>`, `SCOPE=all` | Render with a different threshold |
| `BREAK=<s>`, `FORCE_BREAK=1` | Make the break reminder due quickly, or show it at once |
| `DB_SRC=<path>` | Use a doctored database instead of a copy of the real one |
| `SCREEN=1` | Capture the whole display — required for anything not inside the main window |

Two capture traps:

- **`screencapture -l <windowID>` cannot see a floating panel** (the palette, the break reminder,
  prompts). Use `SCREEN=1`, then crop with `sips -c H W --cropOffset Y X`. Panels exclude themselves
  from capture unless `TIMESLICE_SEED_DEMO=1` or the run asked for that panel explicitly.
- **`NSPanel` hides itself whenever the app is inactive** (`hidesOnDeactivate` defaults to true). A
  panel that deliberately never activates the app is therefore never visible. Set it false.

## Tests

`swift run TimesliceSelfTest` — an assertion harness in `Tests/TimesliceSelfTest/main.swift`, because
XCTest isn't available under Command Line Tools. Register new `testX()` functions in the list at the
bottom of the file. Run it after touching anything in Core.

- **The fixture calendar is `America/New_York`** (`cal`), and `date(...)` builds dates in it. Any Core
  function taking a `calendar:` must be given `calendar: cal` in tests — the default `.current` is the
  Mac's own zone, and the mismatch is invisible until day boundaries start to matter (it put `now` 21h
  into the wrong day once).
- **`swift build` never compiles `ios/`.** After a Core signature change, build the phone with the
  xcodebuild line in `ios/README.md`, or it will break silently.
- **Give new parameters no default value** when they change behaviour. A defaulted parameter is how a
  call site silently keeps the old behaviour; `FocusRule` and `TargetsSheet.save(...)` both exist to
  force every caller to choose.

## Working on the live data

The user regularly asks for data corrections ("that was 20 minutes, not 40"). Rules:

- **Intervals are immutable synced facts.** An edit to an existing row doesn't propagate — peers insert
  if absent, so the old row comes back on the next merge. A correction must **tombstone the original and
  re-insert** the surviving pieces under fresh uids. Use `TimesliceTrim`, which goes through
  `IntervalStore.deleteIntervalSlice`:

  ```bash
  swift run TimesliceTrim --db "$DB" --id 2353 --keep-minutes 20            # dry run
  swift run TimesliceTrim --db "$DB" --id 2353 --from "y-M-d H:m:s" --to "…" --apply
  swift run TimesliceTrim --db "$DB" --overlaps [--max-minutes 1] [--apply] # double-counted time
  swift run TimesliceTrim --db "$DB" --merge 107 --into 94 [--apply]         # fold a duplicate task
  ```

  Dry run is the default; nothing is written without `--apply`.
- **Check for a running timer before writing** (`select … from intervals where running=1`). Writing
  alongside the running app is fine under WAL; just don't touch the open row.
- **Rehearse on a copy first, then apply to the live file.** `cp` the `.db` **and** its `-wal`, then run
  `PRAGMA wal_checkpoint(TRUNCATE)` on the copy. Never copy a live `-shm`: it poisons the WAL and
  silently discards edits made to the copy.
- **Quote the database path.** It contains a space (`Application Support`), and zsh doesn't
  word-split an unquoted variable the way bash does, so `$=CMD` or `set -- $pair` tricks silently pass
  the wrong arguments. Wrap the tool in a shell function that takes `"$@"`.
- **SQL timestamps are UTC.** Use `datetime(x,'unixepoch','localtime')` when matching what the UI shows,
  or you will be looking at the wrong hours (this produced a false "no rows" more than once).
- The user may already have fixed something themselves from another device. Read the current rows
  before inserting — a duplicate `meeting milind` was created that way.

## How the pieces fit

Each subsystem has a design doc in the vault's `artifacts/`; read it before changing the subsystem.

**Counters — `WorkRuns`** (`fuzzy_focus.md`). Focus, "still working?" and the break reminder all read
*runs*: chains of intervals with no gap longer than a tolerance. Bridged gaps are never counted as work.
Focus and "still working?" group per task; the break counter ignores tasks. Both clocks are floored at
the moment the user last answered — without the floor, the checkpoint's own pause is bridged and
"Keep going" re-prompts forever. Everything is derived from rows on demand, never counted in memory.

**Allocations — `Target` + `TargetWindow`** (`allocation_windows.md`). Every goal figure reduces to one
idea: *an allocation's claimed days are its weekdays ∩ its window ∩ its every-N cycle* (or its chosen
dates, which override all of that). One-offs (`period == .once`) are the whole job over their window,
not a rate — divide by `normalisingDays`, never `nominalDays`, which is 0 for them (that made a 4h job
read 40000h). **Archiving is an end bound, not a filter:** an archived allocation applies up to the day
it was archived, so history still shows it. Load `listTargets(includeCompleted: true)` and let the
window decide. Pace is measured against each allocation's *own* claimed days
(`elapsedFraction`), not the calendar's — a Mon–Fri goal is fully elapsed on Friday night.

**Planner** (`planner_todo.md`). Week view is self-contained; month view reallocates across its weeks
(or days, `RES=day`) and never spills across months. One placement algorithm for every view. Past
periods draw no plan blocks; what never happened goes in the pool below.

**Sync** (`drive_appdata_sync.md`, `multi_device_sync.md`). Each device writes `device-<id>.json`;
everyone merges everyone. Payload rule that has been paid for twice: **an absent field means "unknown",
never "cleared"** — merge with `COALESCE`, no default — or an older peer's silence deletes data it has
never heard of. The one-timer invariant is kept by `TakeoverPolicy` (races caught live) and
`OverlapResolver` (both devices already stopped); see the iPhone section for details.

**Task palette — `PaletteNav`.** Tab jumps to the Create row, then cycles the destination among the
options on offer (Inbox + every project, or the projects matching a typed `/token`). The palette, Tab and
the Create row read one list so they can't disagree.

## Adding a synced setting

Five places, all in Core, and missing any one fails silently:

1. A key in `AppSettings.Keys`.
2. An `@Published` property whose `didSet` writes defaults **and** calls `publishSynced`.
3. An entry in `syncedValues()` (seeds the table on first attach).
4. A branch in `adoptSyncedSettings()` (takes on a peer's newer value).
5. The key in `IntervalStore.syncedSettingKeys` — the merge rejects anything not listed. Update the
   self-test assertion that lists them.

Then expose it in **both** Settings screens (Mac `SettingsPanel`, iOS `SettingsSheet`). Missing step 5
is the easy one to miss: `dormantAfterDays` shipped without it and its value never left the device.


## Working on the iPhone app

`ios/` is a thin Xcode shell around the same SwiftPM package (the Dynamic Island is an app
extension, which SwiftPM cannot express). If you are building the iOS app, read **both**:

- `~/workspace/persona/Notes/Projects/timeslice/artifacts/ios_full_parity.md` — the plan: review of
  what exists, the gap to the Mac app, feature spec, build order, and the traps not to rediscover.
- `ios/README.md` — how to generate the project, build, and run it.

Most iOS work now lands directly on `main`. The only other branch is `feat/ios-metrics`, checked out
as a git worktree at `~/workspace/persona/timeslice-ios`. **Do not create new branches** — the owner
wants exactly `main` and `feat/ios-metrics`, and a fix once landed on a stale feature branch had to be
moved. Rebase the worktree on `main` before working in it so the phone never drifts from the Mac.

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

**An `AppSettings` must be attached to its store, or it silently uses defaults.** The phone created one
and never called `attach(store:)`, so for weeks it stored every synced threshold it received and used
none of them — awake hours read 16 against a stored 12, and sessions split at 25 minutes instead of
20. Both ends looked correct: the Mac published, the phone's merge stored. `TimerModel.load` now
attaches, and `SyncController` calls `adoptSyncedSettings()` when a merge reports `settingsApplied`.

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

Two mechanisms keep it true, and they cover different moments. `TakeoverPolicy` settles a race caught
in the act, off the running markers. `OverlapResolver` settles the one where both devices stopped before
they ever saw each other — by then both rows are closed facts and the merge would insert the overlap
permanently. It runs at the end of every `SyncEngine.merge`, removes only the genuinely double-counted
span (not the earlier row's whole tail), and is **bounded**: a clip removing more than a minute is
counted in `MergeReport.overlapsLeft` and left for `swift run TimesliceTrim --overlaps`, because deciding
which device was really in use for twenty minutes of recorded work is not a background merge's call.

Its replacement uids are DERIVED from the original plus the surviving bounds. Every device computes the
same clip independently, so a fresh random uid would replace one overlap with one duplicate per device.

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

## Drive sync setup

- `artifacts/drive_appdata_sync.md` — how the sync is built and why, trap-first: the scope that 403s
  everything, Drive permitting duplicate file names, the main-actor deadlock, payload compatibility.
  Read it before touching `DriveAPI`, `DriveSyncTransport`, `SyncPayload` or `SyncController`.
- `artifacts/google_drive_setup.md` — creating an OAuth client and pointing the app at it. Also inlined
  in README's Sync section.

**Secrets.** The Mac's OAuth client id and secret live in `~/.config/timeslice/env` (mode 0600) and
must never be committed — GitHub push protection rejects them anyway. The refresh token is a 0600 file
at `~/Library/Application Support/Timeslice/google-token.json`, not the Keychain, because Keychain ACLs
break under ad-hoc signing.

The Mac does **not** yet recover from a permanently refused token on its own (`isPermanentRefusal` is
wired on iOS only). It once sat signed out for eleven hours while the Planner reported the month as
badly behind; the gear badge exists because of that.

## Known open issues

Things found and deliberately left, so you don't rediscover them:

- Two overlapping intervals on 10 Aug, 28.6 minutes, from a one-time backfill of personal history
  entered around 24 Aug on top of live-recorded rows. Waiting on the user; `TimesliceTrim --overlaps`
  lists them.
- Fair share is absolute (even half-hour turns), not proportional; the user agreed proportional is
  better. `Replan.dailyPlan` and `PlannerMonth.rollups` should become one allocator.
- Pinning an allocation's hours so fair share can't cut them, and an iOS editor for windows and
  one-offs, are specified in `allocation_windows.md` and not built.

## Where things live

- `Sources/TimesliceCore/`
  - Storage: `IntervalStore` (schema, migrations, CRUD, tombstones), `TimeslicePaths`, `Models`.
  - Measures: `Aggregations`, `SpanUnion`, `WorkRuns` (runs, focus), `BreakPolicy`, `NudgePolicy`,
    `Dormancy`, `TaskOrdering`, `TaskSearch`, `PaletteNav`.
  - Allocations and planning: `Tags` (`Target`, `TargetMath`), `TargetWindow`, `Planner`,
    `PlannerWeek`, `PlannerMonth`, `Replan`, `SubjectMembership`, `BudgetRows`.
  - Sync: `SyncEngine`, `SyncPayload`, `SyncTransport`, `DriveAPI`, `DriveSyncTransport`,
    `GoogleOAuth`, `TakeoverPolicy`, `OverlapResolver`.
  - Shared state: `Settings` (`AppSettings`), `Palette`, `DateRange`, `DemoSeed`.
- `Sources/TimesliceApp/` — `AppDelegate` (wiring, hotkey callbacks), `TimerEngine`, `AppState`,
  `AutoPauseController` (sleep, screen-off, all three nudges), `GlobalHotkeyManager`, `SyncController`,
  `StatusBarController`, `PrivacyController`, `Views/` (`MetricsView`, `PlannerView`, `TargetsSheet`,
  `QuickAddPanel`, `PromptPanel`, `SyncBadge`, `SettingsPanel`, …).
- `ios/Timeslice/` — `TimerModel`, `TasksView`, `MetricsScreen`, `SettingsSheet`, `NudgeScheduler`,
  `SyncController`, `SwitchWheelSheet`, `LiveActivityController`.
- `Tools/`, `scripts/` (`install.sh`, `shot.sh`, `build_native_app.sh`, `sync_sandbox.sh`).

## Conventions

- Keep `TimesliceCore` UI-free so the self-test can reach it. If logic is only exercised by a human
  pressing a key, move it into Core and test it there (`PaletteNav` exists for exactly that reason).
- All day and hour math uses `Calendar` in Swift, never SQLite `localtime`, for DST and midnight. An
  interval crossing midnight is split per day before anything attributes it to a weekday.
- `DateInterval.contains` includes the end. For "is this day inside that period", compare
  `start <= x && x < end`; using `contains` once lit two columns as "today".
- One running interval max — a partial unique index on a `running` flag (a NULL-based index does not
  work in SQLite). Don't bypass `IntervalStore.switchTo/pause/stop`.
- `zsh` has `noclobber` here: redirect with `>|`, not `>`. A refused redirect is silent apart from a
  one-line "file exists", and has caused a wrong tab and a stale log being read.
