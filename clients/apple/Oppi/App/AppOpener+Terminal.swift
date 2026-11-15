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
            rexEnabled: SSHTerminalExperimentAccess.current.rex,
            serverOffersRex: serverId.map { coordinator.server($0, offers: .rex) } ?? true
        )
        // The host's shell is behind this link, so a locked server asks first.
        if let serverId, case .openPane = route {
            guard await scopedLock.authorize(.server(serverId)), isCurrent(generation) else { return .finished }
        }
        guard isCurrent(generation) else { return .finished }
        // The pane opens beside, or the push lands in, the window's focused
        // leaf: the one the link was tapped in, since a touch focuses its leaf.
        guard let screen = navigation.window.flatMap(Router.focusedScreen(in:)) else {
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
        case .rexOffOnServer:
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
                let list = SSHTerminalRexSessionsViewController(profile: profile, opening: pane)
                if !openBeside(list, from: screen) { Router.push(list, from: screen) }
            }
        }
    }

    /// The host's Rex list in a pane beside `screen`'s, where `PanePlacement`
    /// puts Rex; false where it belongs over `screen`.
    private static func openBeside(_ list: SSHTerminalRexSessionsViewController, from screen: UIViewController) -> Bool {
        guard let host = PaneHostController.containing(screen), let cell = host.cell(holding: screen) else { return false }
        let entry = PaneStackEntry(serverId: host.panes.context(of: cell).serverId, route: .local(PaneLocalScreen.rex.token))
        return host.openBeside(PaneOpenContent(entry: entry), kind: .rex, from: cell, screen: list)
    }
}
