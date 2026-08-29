import Foundation

/// Ordering rules shared by every surface that lists tasks "most recently worked first".
///
/// In Core rather than in a UI layer because three surfaces now depend on it — the Mac's switcher and
/// popover, and the phone's task list and Action Button wheel. The rules below are subtle enough
/// (a pinned current task, an untracked tail, a display-order tie-break) that a second implementation
/// would drift on the first edit, which is exactly the divergence this module exists to prevent.
public enum TaskOrdering {

    /// Tasks most-recently-worked first — the switcher's order.
    ///
    /// This makes `\` behave like alt-tab: index 0 is the current task, index 1 is the one you were
    /// on before it, so a single press lands on the task you just came from. Tasks you bounce
    /// between stay at the front; ones you haven't touched in weeks sink to the back instead of
    /// sitting in the middle of the cycle because of where they happen to appear in the list.
    ///
    /// Never-tracked tasks have no recency at all, so they keep displayed order behind the rest
    /// (an arbitrary-but-stable tail beats interleaving them randomly).
    ///
    /// - Parameters:
    ///   - display: tasks in their displayed order; also the tie-break when recency is equal.
    ///   - lastActivity: per-task last activity, from `IntervalStore.lastActivityByProject()`.
    ///   - current: the running-or-current task, pinned to index 0. See the note below.
    public static func recencyOrdered(
        display: [Project], lastActivity: [Int64: Date], current: Int64?
    ) -> [Project] {
        let displayRank = Dictionary(uniqueKeysWithValues: display.enumerated().map { ($1.id, $0) })
        // The current task is pinned to index 0 rather than left to the timestamps. Switching A -> B
        // closes A at the exact instant B starts, so both carry the same activity time and the tie
        // broke on display order — sometimes putting the task you just left at index 0 and the one
        // you're on at index 1, which inverts what one press of `\` does.
        return display.sorted { a, b in
            if (a.id == current) != (b.id == current) { return a.id == current }
            switch (lastActivity[a.id], lastActivity[b.id]) {
            case let (x?, y?) where x != y: return x > y            // more recent first
            case (nil, _?): return false                            // untracked sinks
            case (_?, nil): return true
            default: return (displayRank[a.id] ?? 0) < (displayRank[b.id] ?? 0)
            }
        }
    }
}
