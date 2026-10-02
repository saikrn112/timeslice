import Foundation

/// Where Tab moves in the task palette.
///
/// Pure, and in Core, because the interesting part is a small state machine over (selected row, chosen
/// destination) and the alternative is only ever exercised by a human pressing Tab — which is exactly the
/// kind of thing that quietly stops working.
///
/// The problem it solves: the Create row sits after every match, so creating a task meant arrowing past
/// the whole list. Tab jumps straight there; pressing it again cycles which project the new task is filed
/// into, so "new task, in that project" needs no `/token` typing at all.
public enum PaletteNav {

    /// A step through the palette. `groupCycle` is nil for Inbox, otherwise an index into the group list.
    public struct Position: Equatable, Sendable {
        public var selection: Int
        public var groupCycle: Int?

        public init(selection: Int, groupCycle: Int?) {
            self.selection = selection
            self.groupCycle = groupCycle
        }
    }

    /// Tab (`delta` = +1) and Shift-Tab (-1).
    ///
    /// Forward: anything → the Create row → its destinations, cycling Inbox → each group → Inbox.
    /// Backward: the destinations in reverse, and from Inbox back into the match list rather than
    /// dead-ending there.
    public static func tab(from position: Position, delta: Int, matchCount: Int,
                          showsCreateRow: Bool, groupCount: Int) -> Position {
        var next = position
        let rowCount = matchCount + (showsCreateRow ? 1 : 0)
        guard rowCount > 0 else { return next }

        // Nothing to create — an empty query, or a name that already exists in the target project. Tab
        // then behaves like an arrow rather than being inert.
        guard showsCreateRow else {
            next.selection = (position.selection + delta + rowCount) % rowCount
            return next
        }

        let createRow = matchCount
        if position.selection != createRow {
            if delta > 0 { next.selection = createRow } else {
                next.selection = (position.selection + delta + rowCount) % rowCount
            }
            return next
        }
        // On the Create row. Shift-Tab from Inbox leaves for the last match; otherwise cycle.
        if delta < 0, position.groupCycle == nil {
            next.selection = max(0, matchCount - 1)
            return next
        }
        guard groupCount > 0 else { return next }
        // Inbox occupies slot 0, the groups 1...groupCount.
        let current = position.groupCycle.map { $0 + 1 } ?? 0
        let slot = (current + delta + (groupCount + 1)) % (groupCount + 1)
        next.groupCycle = slot == 0 ? nil : slot - 1
        return next
    }
}
