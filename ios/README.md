# Timeslice for iPhone

Press the Action Button, and the task you're timing appears in the Dynamic Island in its own
project colour, counting up.

> ## Start here
>
> **The plan lives outside this repo, in the Obsidian vault:**
>
> ```
> ~/workspace/persona/Notes/Projects/timeslice/artifacts/ios_full_parity.md
> ```
>
> Read it before writing code. It carries the review of what's already built, the gap to the Mac
> app, the feature spec, an ordered build plan, and — most importantly — a list of traps that each
> already cost a debugging session on the Mac. This file below is only the build-and-run mechanics.
>
> Also read `AGENTS.md` at the repo root for the SwiftPM conventions and the self-test workflow.
> `ios_action_button.md` in the same vault folder is **superseded** by the parity plan; don't follow
> it.

## Build and run

Unlike the Mac app, this part **needs Xcode** — a Live Activity is an app extension, and SwiftPM has
no app-extension product type at any tools version, so the Dynamic Island isn't expressible in
`Package.swift`. All the logic still lives in the SwiftPM package above; this is a thin shell.

```bash
brew install xcodegen                       # once
xcodegen generate --spec ios/project.yml    # writes ios/Timeslice.xcodeproj (gitignored)

xcodebuild -project ios/Timeslice.xcodeproj -scheme TimesliceiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

xcrun simctl boot 'iPhone 17 Pro'
xcrun simctl install booted "$(find ~/Library/Developer/Xcode/DerivedData -name Timeslice.app | head -1)"
xcrun simctl launch booted com.timeslice.ios
```

`ios/project.yml` is the source of truth. The `.xcodeproj` and both `Info.plist` files are
**generated** — edit the spec, not them.

### Device builds

`project.yml` sets `CODE_SIGNING_ALLOWED: NO`, which is fine for the simulator and keeps the repo
free of anyone's team id. For a real phone, pass your own:

```bash
xcodebuild -project ios/Timeslice.xcodeproj -scheme TimesliceiOS \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=XXXXXXXXXX CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic
```

## The one thing you CANNOT automate

**The Action Button cannot be claimed programmatically** — there is no API for it. The app ships an
`AppIntent` and an `AppShortcutsProvider`, which is all it can do; you then assign it yourself:

> Settings → Action Button → swipe to **Shortcut** → choose **Toggle Timeslice Timer**

This is the iOS counterpart to the Accessibility grant the Mac app needs (see `AGENTS.md`), and for
the same reason: a deliberate user gesture the system won't let software perform on its own.

The Action Button is **iPhone 15 Pro and later**. The Simulator *does* expose it — the
Settings → Action Button pane is present on an iPhone 15/17 Pro simulator, so the assignment can be
made and exercised there; only the physical press is hardware. (An earlier version of this file
claimed the Simulator had no Action Button at all. It was wrong.)

Both intents are registered in the built app's `Metadata.appintents`, which is what makes them
discoverable in Shortcuts:

```bash
plutil -p "$(find ~/Library/Developer/Xcode/DerivedData -name Timeslice.app | head -1)/Metadata.appintents/extract.actionsdata" | grep Intent
```

## How it works

| Piece | Role |
|---|---|
| `Timeslice/` | container app: task list, today's totals, tap to start/pause |
| `TimesliceWidgets/` | the Live Activity — Dynamic Island + Lock Screen |
| `Shared/` | `TimerActivityAttributes`, compiled into **both** (separate processes must agree) |

**No background execution is involved.** A running interval is a database row with `start_utc` and
no end, so elapsed time is *derived*, never accumulated. The widget is handed that start date and
renders `Text(timerInterval:)`, which the **system** ticks — the clock keeps counting while the app
is suspended or terminated. No background modes, no push, no `BGTaskScheduler`.

Colours are resolved once, in the app, by `Palette.displayColorHex` from `TimesliceCore` — the same
function the Mac app calls — and passed to the widget as a hex string. The widget links
`TimesliceCore`/`TimesliceUI` so `Color(hex:)` is also shared. One implementation across three
processes, which is what keeps the phone from drifting from the Mac.

The widget never opens the database. That's deliberate: reading sqlite from an extension would force
an App Group container and reintroduce `0xdead10cc` (iOS kills a suspended app holding a file lock on
a shared container, and a WAL connection is such a lock).

## Sync

Off by default, as on the Mac. Signing in needs a **separate Google OAuth client of iOS type** (no
client secret) plus the reversed-client-id redirect scheme — Google refuses arbitrary schemes like
`timeslice://` for installed apps. Until that client is registered, the app works fully as a
standalone local tracker.
