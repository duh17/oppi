#if DEBUG
import SwiftUI

/// Real App Settings and Server Settings surfaces with one fixture server and
/// no network. The `SCREENSHOT_SETTINGS_PAGE` environment value picks the root
/// (default) or a section page, so each page can be captured without driving
/// navigation. `SCREENSHOT_SSH_HOSTS=1` turns the SSH Terminal experiment on;
/// `server*` pages use a fixture `ServerSettingsModel`, with an update on offer
/// when `SCREENSHOT_SERVER_UPDATE=1`.
struct SettingsScreenshotPreview: View {
    private let coordinator: ConnectionCoordinator
    private let server: PairedServer
    private let serverModel: ServerSettingsModel
    @State private var navigation = AppNavigation()
    private let themeStore = ThemeStore()

    init() {
        let environment = ProcessInfo.processInfo.environment
        var server = HostSwitcherPreviewData.server
        server.deviceCredential = DeviceCredential(
            deviceId: "dev-this",
            accessToken: "preview",
            expiresAt: Int64.max,
            refreshChallenge: nil
        )
        self.server = server
        serverModel = .screenshotFixture(
            serverId: server.id,
            currentDeviceId: "dev-this",
            updateAvailable: environment["SCREENSHOT_SERVER_UPDATE"] == "1"
        )
        UserDefaults.standard.set(
            environment["SCREENSHOT_SSH_HOSTS"] == "1",
            forKey: AppPreferences.Experiments.sshTerminalKey
        )
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([server])
        self.coordinator = coordinator
        if ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "dark" {
            themeStore.mode = .manual
            themeStore.manualThemeID = .dark
        }
    }

    var body: some View {
        // The real tracked workspace path, so Server Settings and Model
        // Providers push through `AppNavigation` exactly as in the app.
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.workspacePath) {
            page
                .navigationDestination(for: ServerDetailsNavTarget.self) { target in
                    ServerDetailsScopedDestinationView(target: target)
                }
                .navigationDestination(for: ModelProvidersNavTarget.self) { target in
                    ModelProvidersScopedDestinationView(target: target)
                }
        }
        .environment(coordinator)
        .environment(coordinator.serverStore)
        .withServerScopedEnvironment(coordinator.activeConnection)
        .environment(navigation)
        .environment(themeStore)
        .environment(\.theme, themeStore.appTheme)
        .environment(\.themeID, themeStore.activeThemeID)
        .tint(.themeBlue)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .accessibilityIdentifier("screenshot.ready")
    }

    @ViewBuilder
    private var page: some View {
        switch ProcessInfo.processInfo.environment["SCREENSHOT_SETTINGS_PAGE"] {
        case "general": SettingsGeneralPage()
        case "appearance": SettingsAppearancePage()
        case "text": SettingsTextPage()
        case "chat": SettingsChatPage()
        case "sessions": SettingsSessionsPage()
        case "session-rows": SessionRowDisplayEditor()
        case "voice": SettingsVoicePage()
        case "tailscale": TailnetSettingsView()
        case "privacy": SettingsPrivacyPage()
        case "experiments": SettingsExperimentsPage()
        case "storage": SettingsStoragePage()
        case "server": ServerSettingsRootView(server: server, model: serverModel)
        case "server-about": ServerAboutPage(model: serverModel, server: server)
        case "server-devices": ServerPairedDevicesPage(model: serverModel, server: server)
        case "server-badge": ServerBadgePage(server: server)
        default: SettingsView()
        }
    }
}
#endif
