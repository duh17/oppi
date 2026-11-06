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

    /// What a stored write to a server's setting triggers, whichever screen saved it:
    /// - Server Metrics: the connection's cached flag (the host pill shows or hides Server
    ///   Metrics by it, and the Metrics page opens off it) follows what the server stored.
    /// - Durable Sessions: the connection's `durableSessions` capability follows it, so
    ///   Quick Session's engine switch appears or goes without waiting for `/server/info`.
    /// The store is the server's own, read back from the coordinator; a removed server
    /// updates nothing.
    static func liveServerAfterWrite(serverId: String, coordinator: ConnectionCoordinator) -> @MainActor (String) -> Void {
        { [weak coordinator] id in
            guard let coordinator, coordinator.serverStore.server(for: serverId) != nil else { return }
            let settings = coordinator.settings(for: serverId)
            switch id {
            case SettingsCatalog.serverMetricsEnabled.id:
                guard let stored = settings.read(SettingsCatalog.serverMetricsEnabled).current else { return }
                coordinator.setServerMetricsEnabledCache(stored, for: serverId)
            case SettingsCatalog.durableSessionsEnabled.id:
                guard let stored = settings.read(SettingsCatalog.durableSessionsEnabled).current else { return }
                coordinator.connection(for: serverId)?.noteDurableSessionsAvailable(stored)
            default:
                break
            }
        }
    }

    /// What a stored write triggers: the screen's idle timer follows Keep Awake
    /// After Activity the moment it changes, an open editor hears Auto-Save, an
    /// experiment switch is announced to the screens that re-read it (a Rex
    /// terminal has nothing left to show once its experiment is off), and no other
    /// setting has an effect.
    static func liveAfterWrite(screenAwake: ScreenAwakeController) -> @MainActor (String) -> Void {
        { id in
            switch id {
            case SettingsCatalog.keepAwakeAfterActivity.id:
                screenAwake.refreshFromPreferences()
            case SettingsCatalog.piIcon.id:
                // The Pi mark is drawn by the shared renderer: open screens
                // redraw on the signal a theme change sends.
                NotificationCenter.default.post(name: .oppiThemeDidChange, object: nil)
            case SettingsCatalog.autoSave.id:
                // The editor reads the value from the defaults, which a stored
                // write changes without telling anyone: the editors that are
                // open need to hear it to start or stop the save they owe.
                NotificationCenter.default.post(name: .codeEditorAutoSaveDidChange, object: nil)
            case SettingsCatalog.experimentRex.id, SettingsCatalog.experimentHerdr.id:
                // Out of an experiment at once, without a relaunch: a Rex terminal is a
                // pane of a session Oppi may no longer read, so it ends rather than
                // keeping a connection the switch just turned off.
                if !AppPreferenceStore.Experiments.rexEnabled {
                    SSHTerminalRegistry.shared.closeRexTerminals(reason: String(localized: "The Rex experiment was turned off."))
                }
                NotificationCenter.default.post(name: AppPreferences.Experiments.didChangeNotification, object: nil)
            default:
                break
            }
        }
    }
}
