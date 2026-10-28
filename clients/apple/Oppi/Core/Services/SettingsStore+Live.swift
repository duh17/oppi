import Foundation

extension SettingsStore {
    /// The app's store: server settings go through the paired server's
    /// connection, a scope sentence names the server by its paired name, and a
    /// stored write runs the side effect its setting has.
    static func live(coordinator: ConnectionCoordinator) -> SettingsStore {
        SettingsStore(
            server: ServerAdapter { [weak coordinator] serverId in
                await coordinator?.apiClientReady(for: serverId)
            },
            serverName: { [weak coordinator] serverId in
                coordinator?.serverStore.server(for: serverId)?.name
            },
            afterWrite: { id in
                // The screen's idle timer follows the preset the moment it changes.
                if id == SettingsCatalog.keepAwakeAfterActivity.id {
                    ScreenAwakeController.shared.refreshFromPreferences()
                }
            }
        )
    }
}
