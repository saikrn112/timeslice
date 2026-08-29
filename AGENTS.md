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
