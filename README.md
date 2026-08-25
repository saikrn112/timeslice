# Timeslice

**A time tracker for fast, restless, multitasking brains.**

If you bounce between things all day — the way a lot of ADHD folks do — you're great at *doing*
the work but terrible at *seeing where the hours went*. Most time trackers make that worse: they
demand you stop, find a window, click into a form, pick a project. By then you've lost the thread.

Timeslice removes almost all of that friction. It lives in your menu bar, and you drive it from
your keyboard without ever leaving what you're doing:

- **Switch tasks** — hold **Fn + Command (⌘) + Shift (⇧)** and tap `\` / `]` to flick through
  your tasks like ⌘-Tab, let go, and boom — the old one's paused, the new one's timing.
- **New task on the fly** — **Fn + Command (⌘) + Shift (⇧) + A**, type a name, hit Return, and
  boom — it's created and already tracking.

That's the whole idea: a near-zero-friction layer that quietly records where your time actually
goes, so at the end of the day you can *see* it — without ever having babysat a stopwatch.

It also covers the ways restless tracking goes wrong: forget to stop and it **auto-pauses** and
nudges you; close the laptop and it pauses on sleep; wander off mid-task and a quick tap puts you
back. Local-first, offline, no account, no server — just your time, on your Mac.

## See it

**Switch tasks with the revolver** — hold **Fn + ⌘ + ⇧**, tap `\`/`]` to cycle, release to
switch; start/stop with a tap. Works over whatever app you're in:

![Revolver task switcher](docs/media/switcher.gif)

**Find or add a task** — **Fn + ⌘ + ⇧ + A** opens the palette: type to fuzzy-search every task
(including finished ones), Return resumes it, or create a new one from the last row:

![Task palette](docs/media/quick-add.gif)

**Forgot to stop? It nudges you.**

![Still working prompt](docs/media/still-working.png)

**The task list** — one keypress to switch, the running task ticking live:

![Task list](docs/media/main-tasks.png)

**Where the time went** — pick a range (day / week / month / 6M / year / all) and everything
below follows it. Hover any bar for the numbers; the solid inner bar is focused time:

![Metrics](docs/media/metrics.png)

## Features

- **Menu bar**: live timer + current task; turns into an orange pill whenever it's paused.
- **Revolver switcher** (**Fn + ⌘ + ⇧** + `\`/`]`): flick between tasks from any app, release to switch.
- **Task palette** (**Fn + ⌘ + ⇧ + A**): Spotlight-style — type to search every task (including
  finished ones, and by their project's name), Enter resumes it, or create a new one. Two
  keypresses either way; add `/project` to file it as you create it.
- **Projects**: one optional project per task, everything else in Inbox — no filing decision when
  you're mid-flow. Tasks take a shade of their project's colour, so the timeline stays readable
  with dozens of tasks. Assign by right-click, multi-select, or dragging a card.
- **Auto-pause both ways**: runs too long → pauses and asks "still on this?"; sits paused too long
  → asks whether you forgot to resume. Sleeping pauses too. One switch silences all of it.
- **Metrics**: day timeline, hours-per-day vs a goal, focus %, and where your time went — grouped
  by task or project. Drag across the timeline to measure working vs idle in any stretch.
- **Sync across devices** (optional): sign in with Google and your devices stay in step through
  your *own* Drive — no account with us, no server we run. Off by default; see
  [docs/google-setup.md](docs/google-setup.md).
- **Screen-share safe**: one toggle (**Fn + ⌘ + ⇧ + P**) hides everything at once — the menu-bar
  task name, the switcher, and the windows themselves (they stay visible to you but come out
  blank in any capture, including full-screen). The timer keeps running the whole time.

## Global hotkeys

Keys: **Fn** (the globe/fn key, bottom-left) · **⌘ Command** · **⇧ Shift**. Hold all three
together, then press the last key. These work from any app:

| Hold | then press | What it does |
|---|---|---|
| Fn + ⌘ + ⇧ | `\` (next) or `]` (prev) | Cycle the task switcher; **release the three keys** to switch to the highlighted task. A quick press-and-release (without cycling) just pauses the current task. |
| Fn + ⌘ + ⇧ | `A` | Open the task palette: fuzzy-search your tasks, including finished ones and by project name (archived tasks stay out of the way). Enter resumes the highlighted one — un-finishing it as needed — or creates a new task from the last row. Append `/project` to file a new task as you create it. |
| Fn + ⌘ + ⇧ | `P` | Toggle privacy: hides the menu-bar task name, blanks the windows in any screen capture, and disables the switcher. Press again to reveal. |

Inside the app window/popover (no modifiers): **↑ / ↓** to select a task, **Space** to start/stop.

These need **Accessibility permission** (macOS gates the Fn key + release detection behind it).
Grant it once at **System Settings → Privacy & Security → Accessibility**. Everything else works
without it.

## Install

Requires macOS 14+ and the Swift toolchain (Xcode Command Line Tools is enough — no full Xcode).

```bash
./scripts/install.sh
```

Builds `Timeslice.app`, installs it to `/Applications`, and launches it — no prompts. Then enable
it under **System Settings → Privacy & Security → Accessibility** for the global hotkeys. Re-run
the script anytime to update.

> Dev: `swift build` / `swift run TimesliceApp` for iteration; `swift run TimesliceSelfTest` for
> the core-logic checks. Data lives at `~/Library/Application Support/Timeslice/timeslice.db`.

## License

[GPLv3](LICENSE). Free to use, study, modify and share — but if you distribute a modified version,
it has to stay free software under the same licence, source included.

Copyright (C) 2026 Ramana
