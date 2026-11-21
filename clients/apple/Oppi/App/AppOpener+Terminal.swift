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
            serverOffersRex: serverId.map { coordinator.server($0, offers: .rex) } ?? true
        )
        // The host's shell is behind this link, so a locked server asks first.
        if let serverId, case .openPane = route {
            guard await scopedLock.authorize(.server(serverId)), isCurrent(generation) else { return .finished }
        }
        guard isCurrent(generation) else { return .finished }
        guard let screen = linkSourceScreen else {
            toast(String(localized: "Open a screen first, then tap the terminal link again."))
            return .finished
        }
        TerminalLinkPresenter.show(route, from: screen, serverId: serverId) { [weak self] message in self?.toast(message) }
        return .finished
    }

    /// The screen a terminal link opens from: the main pane's front screen
    /// for a link from outside the app, which has no pane of its own; else
    /// the window's front screen, the one the link was tapped in.
    private var linkSourceScreen: UIViewController? {
        guard let window = navigation.window else { return nil }
        if sideContentOrigin == .external, let host = PaneHostController.focused(in: window) {
            return host.frontScreen(ofCell: host.panes.routedLeafID)
        }
        return Router.focusedScreen(in: window)
    }
}

@MainActor
enum TerminalLinkPresenter {
    /// `serverId` is the server the link belongs to, which `.openPane`
    /// always has: its saved host matched that server's host.
    static func show(
        _ route: TerminalLinkRoute,
        from screen: UIViewController,
        serverId: String?,
        toast: (String) -> Void
    ) {
        switch route {
        case .invalid:
            toast(String(localized: "This terminal link is not valid."))
        case .rexOff:
            toast(String(localized: "Rex is turned off on this server. Turn it on in Server Settings › Features."))
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
                // The host's Rex list beside `screen`'s pane, else over `screen`.
                let list = TerminalNavTarget { SSHTerminalRexSessionsViewController(profile: profile, opening: pane) }
                let content = PaneOpenContent(terminal: list, as: .rex, serverId: serverId ?? "")
                PaneHostController.open(content, kind: .rex, from: screen) {
                    list.show(from: screen)
                }
            }
        }
    }
}
