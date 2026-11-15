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

    /// Opens `url` in a pane beside the focused one, where a tapped link's
    /// page goes (`openLink`): a web page pane already open loads it in
    /// place. False when it belongs in Safari's sheet: on a compact window,
    /// with no room for a pane, or when the focused pane's server turned its
    /// Web Pages in Panes switch off.
    @discardableResult
    func openBrowser(_ url: URL) -> Bool {
        let serverId = panes.context(of: focusedCell).serverId
        guard AppRootEnvironment.near(self)?.coordinator.server(serverId, offers: .browserPane) ?? true else { return false }
        return openLink(PaneOpenContent(entry: PaneStackEntry(serverId: serverId, route: .browser(url))), kind: .webPage)
    }

    /// A split leaf's screen moved on by itself to `entry`: the tree records
    /// it (restoration reads the tree), and the leaf keeps its screen.
    func leaf(_ id: PaneID, follows entry: PaneStackEntry) {
        guard splitLeaves[id] != nil, splitLeaves[id]?.entry != entry else { return }
        splitLeaves[id]?.entry = entry
        panes.show(entry, in: id)
    }
}
