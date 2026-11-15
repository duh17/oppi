import UIKit

// Terminal leaves: a terminal is drawn once. Opening one that another pane
// already shows (a Rex session from the Rex pane and the Terminal page, a
// folder terminal opened twice) focuses that pane, as a Godot link focuses
// the pane playing its game, instead of a second screen on the same shell
// that would size it for two widths.
extension PaneHostController {
    /// Focuses the pane, other than the one holding `source`, whose front
    /// screen is a terminal on `channel`. False when no other pane shows it.
    func focusPane(showing channel: SSHTerminalChannel, besides source: UIViewController) -> Bool {
        let sourceCell = cell(holding: source)
        guard let shown = panes.cellLayout.leaves.first(where: { leaf in
            leaf.id != sourceCell && (frontScreen(ofCell: leaf.id) as? SSHTerminalViewController)?.channel === channel
        }) else { return false }
        focus(cell: shown.id)
        return true
    }
}
