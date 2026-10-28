import UIKit

/// The shell's `.serverDetails` route: Server Settings for the visible server.
///
/// Server Settings follows the host switcher, but a page never swaps servers
/// itself: each `ServerSettingsViewController` is pinned to one server for its
/// whole life (its store, its model, and every action it runs).
/// `PinnedServerRouteViewController` resolves the visible server and replaces the page
/// when it changes; this route adds what Server Settings needs of a switch: it closes
/// the pages the old page pushed (About, Paired Devices, Badge Icon, Workspaces,
/// Dictation Dictionary: pinned to the old server too). A routed screen above this one,
/// such as Model Providers with a sign-in in progress, follows the visible server itself
/// and stays.
@MainActor
final class ServerSettingsRouteViewController: PinnedServerRouteViewController<ServerSettingsViewController> {
    let target: ServerDetailsNavTarget

    init(target: ServerDetailsNavTarget, root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.target = target
        super.init(
            root: root,
            openedServerId: target.serverId,
            showsSidebarToggle: showsSidebarToggle,
            title: HostSwitcherDestination.serverSettings.title,
            makePage: { ServerSettingsViewController(server: $0, root: root) }
        )
    }

    /// Takes only what `page` pushed off the stack: its own pages, and the pages those pushed
    /// in turn (Workspaces opens a workspace's settings, which is pinned to the old server too),
    /// up to the next screen the shell routed. A routed screen above this one is not its to
    /// close, whatever order they are in. A stack that cannot tell routed from pushed closes
    /// only the tracked pages.
    override func willReplace(_ page: ServerSettingsViewController) {
        guard let navigation = navigationController else { return }
        let owned = page.pushedScreens
        let routedStack = navigation as? RoutedScreenStack
        var insideOwnedPages = false
        var kept: [UIViewController] = []
        for screen in navigation.viewControllers {
            if owned.contains(where: { $0 === screen }) {
                insideOwnedPages = true
            } else if let routedStack, !routedStack.isRouted(screen), screen !== self, insideOwnedPages {
                continue
            } else {
                if routedStack?.isRouted(screen) == true { insideOwnedPages = false }
                kept.append(screen)
            }
        }
        guard kept.count != navigation.viewControllers.count else { return }
        navigation.setViewControllers(kept, animated: false)
    }
}
