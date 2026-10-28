import Foundation

extension SettingsStore {
    /// The device store: device-scoped settings, with the side effect a stored
    /// write has (the idle timer follows Keep Awake After Activity).
    static func liveDevice() -> SettingsStore {
        SettingsStore(serverId: nil, server: ServerAdapter { _ in nil }, afterWrite: liveAfterWrite(screenAwake: .shared))
    }

    /// One paired server's store: its settings go through that server's connection.
    static func live(serverId: String, coordinator: ConnectionCoordinator) -> SettingsStore {
        SettingsStore(
            serverId: serverId,
            server: ServerAdapter { [weak coordinator] id in
                await coordinator?.apiClientReady(for: id)
            },
            afterWrite: liveServerAfterWrite(serverId: serverId, coordinator: coordinator)
        )
    }

    /// What a stored write to a server's setting triggers: the connection's cached Server
    /// Metrics flag (the host pill shows or hides Server Metrics by it, and the Metrics page
    /// opens off it) follows what the server stored, whichever screen saved it. The store
    /// is the server's own, read back from the coordinator; a removed server updates nothing.
    static func liveServerAfterWrite(serverId: String, coordinator: ConnectionCoordinator) -> @MainActor (String) -> Void {
        { [weak coordinator] id in
            let setting = SettingsCatalog.serverMetricsEnabled
            guard id == setting.id, let coordinator, coordinator.serverStore.server(for: serverId) != nil,
                  let stored = coordinator.settings(for: serverId).read(setting).current else { return }
            coordinator.setServerMetricsEnabledCache(stored, for: serverId)
        }
    }

    /// What a stored write triggers: the screen's idle timer follows Keep Awake
    /// After Activity the moment it changes, and no other setting has an effect.
    static func liveAfterWrite(screenAwake: ScreenAwakeController) -> @MainActor (String) -> Void {
        { id in
            if id == SettingsCatalog.keepAwakeAfterActivity.id {
                screenAwake.refreshFromPreferences()
            }
        }
    }
}
