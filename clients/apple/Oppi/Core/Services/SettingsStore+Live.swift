import Foundation

extension SettingsStore {
    /// The app's store: server settings go through the paired server's
    /// connection, and a scope sentence names the server by its paired name.
    static func live(coordinator: ConnectionCoordinator) -> SettingsStore {
        SettingsStore(
            server: ServerAdapter { [weak coordinator] serverId in
                await coordinator?.apiClientReady(for: serverId)
            },
            serverName: { [weak coordinator] serverId in
                coordinator?.serverStore.server(for: serverId)?.name
            }
        )
    }
}
