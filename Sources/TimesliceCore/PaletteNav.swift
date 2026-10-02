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

    /// A step through the palette. `option` indexes the destination list the caller is offering, which
    /// differs by context: Inbox plus every project when nothing is typed, or the projects matching a
    /// `/token` when one is. Indexing a caller-supplied list rather than modelling Inbox as a special
    /// `nil` is what lets both cases behave identically — the first version special-cased Inbox, and with
    /// a token typed Tab then moved a highlight while changing nothing.
    public struct Position: Equatable, Sendable {
        public var selection: Int
        public var option: Int

        public init(selection: Int, option: Int) {
            self.selection = selection
            self.option = option
        }
    }

    /// Tab (`delta` = +1) and Shift-Tab (-1).
    ///
    /// Forward: anything → the Create row → each destination in turn, wrapping.
    /// Backward: the destinations in reverse, and from the first one back into the match list rather than
    /// dead-ending there.
    public static func tab(from position: Position, delta: Int, matchCount: Int,
                          showsCreateRow: Bool, optionCount: Int) -> Position {
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
        // On the Create row. Shift-Tab from the first destination leaves for the last match.
        if delta < 0, position.option <= 0 {
            next.selection = max(0, matchCount - 1)
            next.option = 0
            return next
        }
        guard optionCount > 0 else { return next }
        next.option = (position.option + delta + optionCount) % optionCount
        return next
    }
}
