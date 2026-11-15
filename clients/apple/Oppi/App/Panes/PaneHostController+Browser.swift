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

    /// Opens `url` beside the focused pane: in the browser pane that is its
    /// companion (the next pane in its split, or the one before when it is
    /// last), else in a new pane after it, which takes focus. A companion
    /// showing anything else keeps it: replacing a Files or chat pane with a
    /// page on every tapped link would lose that pane's place. False on a
    /// compact window, when the window holds all the panes it can, or when the
    /// focused pane's server turned its Web Pages in Panes switch off.
    @discardableResult
    func openBrowser(_ url: URL) -> Bool {
        guard AdaptiveWidth.isWide(traitCollection) else { return false }
        let source = focusedCell
        let serverId = panes.context(of: source).serverId
        guard AppRootEnvironment.near(self)?.coordinator.server(serverId, offers: .browserPane) ?? true else {
            return false
        }
        let entry = PaneStackEntry(serverId: serverId, route: .browser(url))
        if let companion = browserCompanion(of: source) {
            if let browser = frontScreen(ofCell: companion) as? BrowserPaneViewController {
                browser.open(url)
            } else {
                panes.show(entry, in: companion)
                syncSplitLeaves()
            }
            focus(cell: companion)
            return true
        }
        guard canSplit, let made = panes.split(source, edge: .right, showing: entry) else { return false }
        syncSplitLeaves()
        focus(cell: made)
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
        return true
    }

    /// The pane beside `id` in its split when it shows a web page.
    private func browserCompanion(of id: PaneID) -> PaneID? {
        let cells = panes.cellLayout
        guard let path = cells.root.path(of: id), let index = path.last,
              case .split(_, let children, _)? = cells.root.node(at: Array(path.dropLast())) else { return nil }
        let neighbour = index + 1 < children.count ? index + 1 : index - 1
        guard children.indices.contains(neighbour), case .leaf(let leaf) = children[neighbour],
              case .browser? = leaf.stack.last?.route else { return nil }
        return leaf.id
    }

    /// A split leaf's screen moved on by itself to `entry`: the tree records
    /// it (restoration reads the tree), and the leaf keeps its screen.
    func leaf(_ id: PaneID, follows entry: PaneStackEntry) {
        guard splitLeaves[id] != nil, splitLeaves[id]?.entry != entry else { return }
        splitLeaves[id]?.entry = entry
        panes.show(entry, in: id)
    }
}
