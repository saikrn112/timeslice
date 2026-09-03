# iOS Metrics: the design, and what it deliberately omits

The Mac's Metrics page was ported to the phone section-for-section, and that was the wrong strategy. This
records the shape that replaced it and — more importantly — what is **not** there yet, so each absence reads
as a decision rather than an oversight.

## The shape

A **summary** screen with **drill-downs**.

```
METRICS                    [Day  Week  Month]

   Sun 16   Mon 17   Tue 18  ▸ Today       ← period strip, tap or swipe
    6h23     8h28     5h52     2h48

 ┌──────────────────────────────────────┐
 │  2h 48m                       68%    │   ← hero: the one number, and
 │  tracked today               focus   │     the one that qualifies it
 │  ──────────────────────────────────  │
 │  3          54m          1h 20m      │
 │  switches   longest      focused     │
 └──────────────────────────────────────┘

 Allocations   4 on track, 1 behind    ›     ← ●●●○○ verdict dots
 Timeline      12 blocks               ›     ← thumbnail of the day's shape
 Where time went                       ›     ← top three, proportional bars
```

Each row opens a full screen: **Allocations** (one card each, full width), **Timeline** (blocks + device band
+ the sessions list, with swipe-to-delete), **Where time went** (Tasks / Projects / Tags, tappable).

### Why a summary rather than one long scroll

The Mac fits ten sections on a page because a pointer and a large window make them workable: you sweep a
breakdown row and matching timeline blocks light up, drag-select a span, read a weekday pattern against an
hours chart. None of those gestures exist on a phone. The port kept the density and lost the mechanism, so
what remained was nine sections to scroll past to reach the one you wanted.

### Tapping an allocation filters the page

The Mac's hover-linked highlighting has no touch equivalent — a hover dies the moment you look away. A
**filter** is the stateful version: tap an allocation or a breakdown row, and every figure on the summary
narrows to that subject until you clear it. It survives scrolling and drilling down, which is the property
hover can't have.

Allocations themselves are never filtered: the section exists to say how each one is doing, and narrowing it
to the one you tapped would leave a list of length one repeating what you already knew.

### Type and colour

Metrics has its own type scale (`Theme.metric*`), larger than the task list's, with a **13pt floor**. The list
is scanned; metrics is read.

Chrome is grey with one accent. The tinted tiles — purple focus, orange switches, teal longest, blue best-day
— are gone. They were my invention rather than the Mac's, and they broke the rule `Theme` opens with: colour
is information, never decoration. The hue meant only "this is the third tile". The one saturated colour on the
page now belongs to a task, project or tag.

## Not here yet

Ordered roughly by how likely each is to be wanted.

| Missing | Why it's out for now |
|---|---|
| **6M / Y / All ranges** | Comparative ranges read at a desk. The phone answers "how is it going", not "how has this trended since March". Day/Week/Month cover check-in. |
| **Hours-per-bucket chart** | Largely duplicated by the period strip, which already shows per-period totals as rings and is also the navigation control. |
| **Weekday pattern** | "Average tracked per weekday in this range" — comparative analysis, acted on at a desk. |
| **Multi-select allocations + overlays** | Notes 46/47/48/56: union/intersection across several allocations, overlaid on the hours chart, with a tooltip. Genuinely pointer-and-large-window work, and it depends on the hours chart above. |
| **Drag-select a span on the timeline** | A drag on a 390pt-wide chart fights the scroll view. Tapping a block to inspect is the touch substitute. |
| **Dim-others / hover highlight** | Replaced by the filter, which is the stateful equivalent. |
| **Retired-allocation history** | The Mac's `AllocationHistory` view. Reviewing what a finished budget cost is a retrospective task. |

## Constraints that shaped this

- **No arithmetic in the views.** Every figure comes from `Aggregations`, `BudgetRows` or `TargetProgress` in
  Core, so the phone cannot disagree with the Mac about the same database.
- **One model, shared.** `MetricsModel` holds the range, the filter and the built data. A detail screen that
  recomputed its own would eventually differ from the row you tapped to reach it, and that difference is
  invisible until you spot two numbers for one thing.
- **The period strip is unfiltered and cached.** Unfiltered because it's the navigation control, and cards
  that emptied under a filter would make the days you can reach depend on what you'd tapped. Cached because
  rebuilding 60 windows measured 190 ms — see `Aggregations.windowTotals`.
