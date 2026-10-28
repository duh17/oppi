import Foundation

extension SettingsStore {
    /// The app's store: server settings go through the paired server's
    /// connection, and a stored write runs the side effect its setting has.
    static func live(coordinator: ConnectionCoordinator) -> SettingsStore {
        SettingsStore(
            server: ServerAdapter { [weak coordinator] serverId in
                await coordinator?.apiClientReady(for: serverId)
            },
            afterWrite: liveAfterWrite(screenAwake: .shared)
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
