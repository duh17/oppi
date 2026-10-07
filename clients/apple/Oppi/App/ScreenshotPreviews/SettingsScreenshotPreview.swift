#if DEBUG
import SwiftUI

/// Real App Settings surfaces with one fixture server and no network. The
/// `SCREENSHOT_SETTINGS_PAGE` environment value picks the root (default) or a
/// section page, so each page can be captured without driving navigation.
struct SettingsScreenshotPreview: View {
    private let coordinator: ConnectionCoordinator
    @State private var navigation = AppNavigation()
    private let themeStore = ThemeStore()

    init() {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([HostSwitcherPreviewData.server])
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
        case "network": SettingsNetworkPage()
        case "privacy": SettingsPrivacyPage()
        case "experiments": SettingsExperimentsPage()
        case "storage": SettingsStoragePage()
        default: SettingsView()
        }
    }
}
#endif
