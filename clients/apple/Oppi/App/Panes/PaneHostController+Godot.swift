import UIKit

// Godot leaves: a Godot link on a wide window focuses the pane that already
// shows that game, else opens beside the focused pane where `PanePlacement`
// puts a game.
extension PaneHostController {
    /// Opens `entry` (a `.godot` route) beside the focused pane, focused.
    /// False where it belongs in the main pane (`openBeside`).
    @discardableResult
    func openGodot(_ entry: PaneStackEntry) -> Bool {
        if panes.splitsEnabled, AdaptiveWidth.isWide(traitCollection),
           let shown = panes.cellLayout.leaves.first(where: { $0.stack.last == entry }) {
            focus(cell: shown.id)
            return true
        }
        return openBeside(PaneOpenContent(entry: entry), kind: .game)
    }
}
