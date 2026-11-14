import UIKit

// Godot leaves: a Godot link on a wide window opens beside the focused pane,
// or focuses the pane that already shows that game.
extension PaneHostController {
    /// Opens `entry` (a `.godot` route) beside the focused pane, which it
    /// focuses. False on a compact window, or when the window holds all the
    /// panes it can.
    @discardableResult
    func openGodot(_ entry: PaneStackEntry) -> Bool {
        guard AdaptiveWidth.isWide(traitCollection) else { return false }
        if let shown = panes.cellLayout.leaves.first(where: { $0.stack.last == entry }) {
            focus(cell: shown.id)
            return true
        }
        guard canSplit, let made = panes.split(focusedCell, edge: .right, showing: entry) else { return false }
        syncSplitLeaves()
        focus(cell: made)
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
        return true
    }
}
