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
            }
        )
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
