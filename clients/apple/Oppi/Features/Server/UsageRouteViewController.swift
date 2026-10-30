import UIKit

/// The shell's `.utility(.manageServers)` route: Usage for the visible server.
///
/// One rule for the Server area (`PinnedServerRouteViewController`): each
/// `UsageViewController` is pinned to one server, with its own model and requests, and
/// this route replaces the page when the visible server changes. With no server paired
/// it offers Add Server.
@MainActor
final class UsageRouteViewController: PinnedServerRouteViewController<UsageViewController> {
    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        super.init(
            root: root,
            openedServerId: nil,
            showsSidebarToggle: showsSidebarToggle,
            title: HostSwitcherDestination.usage.title,
            makePage: { UsageViewController(server: $0, root: root) }
        )
    }

    override func unavailableContent(palette: ThemePalette) -> UIContentUnavailableConfiguration {
        var content = UIContentUnavailableConfiguration.loadState(
            .empty(
                title: String(localized: "No Servers"),
                systemImage: "server.rack",
                message: String(localized: "Pair a server to view usage.")
            ),
            palette: palette
        )
        content.setProminentButton(String(localized: "Add Server")) { [weak self] in self?.addServer() }
        return content
    }

    private func addServer() {
        Router.present(
            OnboardingViewController(root: root, mode: .addServer),
            presentation: .sheet,
            from: self,
            theme: root.themeStore
        )
    }
}
