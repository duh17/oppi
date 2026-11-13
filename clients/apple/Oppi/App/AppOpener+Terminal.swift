import UIKit

/// `oppi://terminal/rex?session=&block=`: opens the SSH terminal on one Rex pane.
///
/// Open-only: the link never types or runs anything. The saved SSH host comes
/// from the server the link belongs to (the chat it was tapped in, else the
/// active server) through `SSHTerminalHostMatch`. Sign-in is the terminal's
/// own, so Face ID for the key works as it does for any host.
extension AppOpener {
    func performTerminal(_ open: TerminalOpen, generation: UInt64) async -> AppOpenOutcome {
        let serverId = open.sourceServerID ?? windowServerId
        let route = TerminalLinkRoute.decide(
            link: open.link,
            serverHost: serverId.flatMap { serverStore.server(for: $0)?.host },
            profiles: SSHTerminalProfileStore().load(),
            rexEnabled: SSHTerminalExperimentAccess.current.rex
        )
        // The host's shell is behind this link, so a locked server asks first.
        if let serverId, case .openPane = route {
            guard await scopedLock.authorize(.server(serverId)), isCurrent(generation) else { return .finished }
        }
        guard isCurrent(generation) else { return .finished }
        guard let screen = TerminalLinkPresenter.frontScreen() else {
            toast(String(localized: "Open a screen first, then tap the terminal link again."))
            return .finished
        }
        TerminalLinkPresenter.show(route, from: screen) { [weak self] message in self?.toast(message) }
        return .finished
    }
}

@MainActor
enum TerminalLinkPresenter {
    static func show(
        _ route: TerminalLinkRoute,
        from screen: UIViewController,
        toast: (String) -> Void
    ) {
        switch route {
        case .invalid:
            toast(String(localized: "This terminal link is not valid."))
        case .rexOff:
            toast(String(localized: "Turn on the Rex experiment in Settings → Experiments to open this pane."))
        case .noServerHost:
            toast(String(localized: "Connect to a server first, then tap the terminal link again."))
        case .addHost(let serverHost):
            // The existing Add Host form, with the server's host filled in and Multiplexer set
            // to Rex, so saving it makes the same link work.
            Router.push(SSHTerminalSetupViewController(profileID: nil, host: serverHost, presetsRex: true), from: screen)
        case .hostNotRex(let profile):
            toast(String(localized: "Set Multiplexer to Rex for \(profile.endpointLabel) in its host settings to open this pane."))
        case .openPane(let profile, let pane):
            // This host's pane list is already on top: open the pane there, with no second list.
            if let list = screen as? SSHTerminalRexSessionsViewController, list.profileID == profile.id {
                list.openLinkedPane(pane)
            } else {
                Router.push(SSHTerminalRexSessionsViewController(profile: profile, opening: pane), from: screen)
            }
        }
    }

    /// The screen a push lands on: the front-most navigation stack's top
    /// controller (the detail column on iPad). Later children are in front of
    /// earlier ones in the shell's containers.
    static func frontScreen() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return window?.rootViewController.flatMap(front(of:))
    }

    private static func front(of controller: UIViewController) -> UIViewController? {
        // A presented controller with no navigation stack of its own (an alert, a plain
        // sheet) leaves the stack underneath to push on.
        if let presented = controller.presentedViewController, !presented.isBeingDismissed,
           let found = front(of: presented) {
            return found
        }
        if let navigation = controller as? UINavigationController {
            return navigation.topViewController.flatMap(front(of:)) ?? navigation.topViewController
        }
        // A push lands in the primary leaf, never in a screen's companion.
        if let host = controller as? PaneHostController {
            return front(of: host.primary)
        }
        if let split = controller as? UISplitViewController {
            let column = split.isCollapsed ? split.viewControllers.last : split.viewController(for: .secondary)
            return column.flatMap(front(of:))
        }
        for child in controller.children.reversed() {
            if let found = front(of: child) { return found }
        }
        return controller.navigationController == nil ? nil : controller
    }
}
