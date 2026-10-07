#if DEBUG
import SwiftUI

/// Real App Settings and Server Settings surfaces with one fixture server and
/// no network. The `SCREENSHOT_SETTINGS_PAGE` environment value picks the root
/// (default) or a section page, so each page can be captured without driving
/// navigation. `SCREENSHOT_SSH_HOSTS=1` turns the SSH Terminal experiment on;
/// `server*` pages use a fixture `ServerSettingsModel`, with an update on offer
/// when `SCREENSHOT_SERVER_UPDATE=1`.
/// Preview-only defaults in the argument domain: the preview reads them like
/// real preferences, and nothing is written to the app's persistent defaults,
/// which a simulator keeps across launches and test runs.
enum ScreenshotVolatileDefaults {
    static func apply(_ values: [String: Any]) {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments.merge(values) { _, new in new }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Call before `ThemeStore()`: its setters would persist the theme.
    static func applyDarkTheme(_ enabled: Bool) {
        guard enabled else { return }
        apply([
            "\(AppIdentifiers.subsystem).theme.mode": ThemeMode.manual.rawValue,
            ThemeID.storageKey: ThemeID.dark.rawValue,
        ])
    }
}

struct SettingsScreenshotPreview: View {
    private let coordinator: ConnectionCoordinator
    private let server: PairedServer
    private let serverModel: ServerSettingsModel
    @State private var navigation = AppNavigation()
    private let themeStore: ThemeStore

    init() {
        let environment = ProcessInfo.processInfo.environment
        ScreenshotVolatileDefaults.applyDarkTheme(environment["SCREENSHOT_COLOR_SCHEME"] == "dark")
        themeStore = ThemeStore()
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
        if environment["SCREENSHOT_SSH_HOSTS"] == "1" {
            ScreenshotVolatileDefaults.apply([AppPreferences.Experiments.sshTerminalKey: true])
        }
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([server])
        self.coordinator = coordinator
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
