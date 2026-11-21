import UIKit

// Browser leaves (build plan Stage 9): a web page opened in-app on a wide
// window opens in a pane beside the pane it came from (§1.6 rule 1 and 2),
// and a browser leaf's own navigation is written into the tree without
// rebuilding the leaf.
extension PaneHostController {
    /// The window's pane host in front of `window`'s focus, when that focus
    /// is in a pane (not in a sheet over the window).
    static func focused(in window: UIWindow) -> PaneHostController? {
        guard let screen = Router.focusedScreen(in: window) else { return nil }
        return containing(screen)
    }

    /// Opens `url` in a pane beside the focused one, where a web page goes
    /// (`openBeside`): a web page pane already open loads it in place. Says
    /// which pane took it, by what that pane was before the tap. Nil when it
    /// belongs in Safari's sheet: on a compact window, with no room for a
    /// pane, or when the focused pane's server turned its Web Pages in Panes
    /// switch off.
    @discardableResult
    func openBrowser(_ url: URL) -> WebLinkBranch? {
        let serverId = panes.context(of: focusedCell).serverId
        guard AppRootEnvironment.near(self)?.coordinator.server(serverId, offers: .browserPane) ?? true else { return nil }
        let before = panes.cellLayout
        let framesBefore = cellPresentation?.frames ?? [:]
        guard openBeside(PaneOpenContent(entry: PaneStackEntry(serverId: serverId, route: .browser(url))), kind: .webPage) else {
            return nil
        }
        // `openBeside` focuses the pane that shows the page.
        let page = focusedCell
        guard before.leaf(page) != nil else { return .newPane }
        if before.collapsed[page] != nil { return .reuseFolded }
        return framesBefore[page] == nil ? .reuseHidden : .reuse
    }

    /// The panes as a web link finds them, for its log line: what the
    /// focused pane shows, and how many panes are on screen, folded to a
    /// strip, or hidden (in Hidden Panes or behind a zoom).
    var webLinkLogFields: [String: String] {
        let cells = panes.cellLayout
        let frames = cellPresentation?.frames ?? [:]
        let folded = cells.leaves.count { cells.collapsed[$0.id] != nil && frames[$0.id] != nil }
        let visible = cells.leaves.count { cells.collapsed[$0.id] == nil && frames[$0.id] != nil }
        let focusedKind: String
        if focusedCell == panes.mainLeafID {
            focusedKind = "main"
        } else {
            switch cells.leaf(focusedCell).map(placementShown) {
            case .kind(let kind)?: focusedKind = "\(kind)"
            case .launcher?: focusedKind = "launcher"
            case .other?, nil: focusedKind = "other"
            }
        }
        return [
            "focusedPane": focusedKind,
            "visiblePanes": "\(visible)",
            "foldedPanes": "\(folded)",
            "hiddenPanes": "\(cells.leaves.count - visible - folded)",
            "canSplit": "\(canSplit)",
        ]
    }

    /// Whether the focused pane is open on screen: neither hidden nor
    /// folded to its strip.
    var focusedCellIsShown: Bool {
        cellFrame(focusedCell) != nil && panes.cellLayout.collapsed[focusedCell] == nil
    }

    /// A split leaf's screen moved on by itself to `entry`: the tree records
    /// it (restoration reads the tree), and the leaf keeps its screen.
    func leaf(_ id: PaneID, follows entry: PaneStackEntry) {
        guard splitLeaves[id] != nil, splitLeaves[id]?.entry != entry else { return }
        splitLeaves[id]?.entry = entry
        panes.show(entry, in: id)
    }
}
