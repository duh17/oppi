import SwiftUI

/// App Settings root: paired servers, then one row per focused section page.
///
/// Every control lives on a section page (`Settings*Page`); this view only
/// shows each page's current value so the index reads at a glance.
struct SettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(ConnectionCoordinator.self) private var coordinator

    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var sshTerminalEnabled = false

    @State private var summary = Summary.current()
    @State private var cacheSizeText: String?
    @State private var showAddServer = false

    /// Preference-backed values shown beside index rows. Refreshed whenever the
    /// root reappears, since section pages write straight to preferences.
    private struct Summary {
        var codeFont: String
        var dictationEngine: String

        @MainActor
        static func current() -> Summary {
            Summary(
                codeFont: FontPreferences.codeFont.displayName,
                dictationEngine: AppPreferences.Voice.engineMode.label
            )
        }
    }

    var body: some View {
        List {
            serversSection

            Section {
                SettingsIndexRow("General", systemImage: "gearshape") {
                    SettingsGeneralPage()
                }
                .accessibilityIdentifier("settings.row.general")
                SettingsIndexRow("Appearance", systemImage: "paintpalette", value: themeSummary) {
                    SettingsAppearancePage()
                }
                .accessibilityIdentifier("settings.row.appearance")
                SettingsIndexRow("Text", systemImage: "textformat.size", value: summary.codeFont) {
                    SettingsTextPage()
                }
                .accessibilityIdentifier("settings.row.text")
                SettingsIndexRow("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                    SettingsChatPage()
                }
                .accessibilityIdentifier("settings.row.chat")
                SettingsIndexRow("Sessions", systemImage: "rectangle.stack") {
                    SettingsSessionsPage()
                }
                .accessibilityIdentifier("settings.row.sessions")
                SettingsIndexRow("Voice & Dictation", systemImage: "mic", value: summary.dictationEngine) {
                    SettingsVoicePage()
                }
                .accessibilityIdentifier("settings.row.voice")
                SettingsIndexRow("Tailscale", systemImage: "network", value: tailscaleSummary) {
                    TailnetSettingsView()
                }
                .accessibilityIdentifier("settings.tailscale")
                if sshTerminalEnabled {
                    SettingsIndexRow("SSH Hosts", systemImage: "terminal") {
                        SSHTerminalHostListView()
                    }
                    .accessibilityIdentifier("settings.sshTerminal")
                }
                SettingsIndexRow("Privacy & Security", systemImage: "hand.raised") {
                    SettingsPrivacyPage()
                }
                .accessibilityIdentifier("settings.row.privacy")
                SettingsIndexRow("Experiments", systemImage: "flask", value: experimentsSummary) {
                    SettingsExperimentsPage()
                }
                .accessibilityIdentifier("settings.row.experiments")
                SettingsIndexRow("Storage & About", systemImage: "internaldrive", value: cacheSizeText) {
                    SettingsStoragePage()
                }
                .accessibilityIdentifier("settings.row.storage")
            }
        }
        .settingsPage("Settings", titleDisplayMode: .large)
        .accessibilityIdentifier("settings.list")
        .onAppear { summary = Summary.current() }
        .task { cacheSizeText = await SettingsStoragePage.formattedCacheSize() }
        .sheet(isPresented: $showAddServer) {
            OnboardingView(mode: .addServer)
        }
    }

    // MARK: - Servers

    private var serversSection: some View {
        Section("Servers") {
            ForEach(serverStore.servers) { server in
                let state = HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
                SettingsIndexActionRow {
                    openServerSettings(server)
                } label: {
                    HStack(spacing: 12) {
                        RuntimeBadge(icon: server.resolvedBadgeIcon, tint: state.tintColor)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(server.name)
                                LockBadge(state: ScopedLockService.shared.badge(.server(server.id)))
                            }
                            Text(state.title)
                                .font(.footnote)
                                .foregroundStyle(.themeComment)
                        }
                    }
                }
                .accessibilityLabel(server.name)
                .accessibilityValue(state.title)
                .accessibilityIdentifier("settings.server.\(server.id)")
            }

            Button {
                showAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.addServer")
        }
    }

    /// Server Settings follows the app's active host, so opening another
    /// paired server's settings first makes it the active one, as the host
    /// switcher does. The push goes through `AppNavigation` so the route stays
    /// on the tracked stack (iPhone) or detail path (iPad) and the host
    /// switcher knows it is on Server Settings.
    /// A locked server asks first; cancel stays in Settings.
    private func openServerSettings(_ server: PairedServer) {
        let coordinator = coordinator
        let navigation = navigation
        let perform: @MainActor () -> Void = {
            if coordinator.activeServerId != server.id {
                guard coordinator.restoreActiveServer(server.id) else { return }
                Task { await coordinator.prepareSelectedServerShell(for: server) }
            }
            navigation.openServerDetails(ServerDetailsNavTarget(serverId: server.id))
        }
        if ScopedLockService.shared.gate(.server(server.id), onUnlock: perform) {
            perform()
        }
    }

    // MARK: - Summaries

    private var themeSummary: String {
        switch themeStore.mode {
        case .manual: themeStore.manualThemeID.displayName
        case .system: ThemeMode.system.displayName
        }
    }

    private var tailscaleSummary: String {
        TailnetSettingsView.statusLabel(TailnetNodeController.shared.state)
    }

    private var experimentsSummary: String {
        let count = SettingsExperimentsPage.enabledCount(
            sessionThreadsEnabled: navigation.sessionThreadsEnabled
        )
        return "\(count) on"
    }
}
