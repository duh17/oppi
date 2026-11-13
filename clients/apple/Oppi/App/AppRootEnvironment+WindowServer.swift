import Foundation

/// The window's server, for the screens that follow it: the sidebar, session
/// lists, server-wide pages (Skills, Extensions, Agents, Schedules), and what
/// they present. A leaf (a chat, a file, a panel, a page pushed for one
/// server's item) takes its route's server instead, so a window switch never
/// moves it.
@MainActor
extension AppRootEnvironment {
    var windowServerId: String? {
        navigation.activeServerId(in: coordinator)
    }

    /// The window server's connection; nil before one is paired or staged.
    var windowConnection: ServerConnection? {
        windowServerId.flatMap(coordinator.connection(for:))
    }

    /// `windowConnection`, or a disconnected stand-in, for a screen that
    /// always reads one.
    var windowConnectionOrStandIn: ServerConnection {
        coordinator.connectionOrStandIn(for: windowServerId)
    }

    /// The window server's name, for a page's "Applies to every device on
    /// <server>" sentence.
    var windowServerName: String {
        windowServerId.flatMap { coordinator.serverStore.server(for: $0)?.name } ?? "this server"
    }
}
