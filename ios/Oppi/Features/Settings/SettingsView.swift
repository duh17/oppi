import SwiftUI

struct SettingsView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerConnection.self) private var connection
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(ThemeStore.self) private var themeStore

    @State private var biometricEnabled = BiometricService.shared.isEnabled
    @State private var autoSessionTitleEnabled = UserDefaults.standard.object(
        forKey: ChatActionHandler.autoTitleEnabledDefaultsKey
    ) as? Bool ?? false
    @State private var showAddServer = false
    @State private var renameServerId: String?
    @State private var renameServerText = ""
    @State private var showRemoveConfirmation: PairedServer?

    var body: some View {
        List {
            Section("Servers") {
                ForEach(serverStore.servers) { server in
                    NavigationLink(value: server) {
                        HStack(spacing: 10) {
                            RuntimeBadge(
                                compact: true,
                                icon: server.resolvedBadgeIcon,
                                badgeColor: server.resolvedBadgeColor
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.subheadline.weight(.medium))
                                Text(verbatim: "\(server.host):\(server.port)")
                                    .font(.caption)
                                    .foregroundStyle(.themeComment)
                            }

                            Spacer()

                            serverStatusBadge(for: server)
                        }
                    }
                    .contextMenu {
                        Button {
                            renameServerId = server.id
                            renameServerText = server.name
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            showRemoveConfirmation = server
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                Button {
                    showAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { themeStore.selectedThemeID },
                    set: { themeStore.selectedThemeID = $0 }
                )) {
                    ForEach(ThemeID.builtins, id: \.self) { themeID in
                        Text(themeID.displayName).tag(themeID)
                    }
                    let customNames = CustomThemeStore.names()
                    if !customNames.isEmpty {
                        ForEach(customNames, id: \.self) { name in
                            Text(name).tag(ThemeID.custom(name))
                        }
                    }
                }

                Text(themeStore.selectedThemeID.detail)
                    .font(.footnote)
                    .foregroundStyle(.themeComment)

                NavigationLink("Import from Server") {
                    ThemeImportView()
                }
            }

            Section {
                Toggle("Auto-name new sessions", isOn: $autoSessionTitleEnabled)
                    .onChange(of: autoSessionTitleEnabled) { _, newValue in
                        UserDefaults.standard.set(
                            newValue,
                            forKey: ChatActionHandler.autoTitleEnabledDefaultsKey
                        )
                    }
            } header: {
                Text("Sessions")
            } footer: {
                Text(
                    "Uses the on-device model to generate a short title from the first prompt. "
                        + "When off, the first message is shown instead."
                )
            }

            if ReleaseFeatures.liveActivitiesEnabled {
                Section {
                    Toggle("Enable Live Activities", isOn: liveActivityToggle)
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text(
                        "Off by default. Turn on to show session state in Dynamic Island and Lock Screen. "
                            + "You must also allow Live Activities in iOS Settings for Oppi."
                    )
                }
            }

            biometricSection

            if ReleaseFeatures.composerDictationEnabled {
                Section {
                    NavigationLink {
                        DictationSettingsView()
                    } label: {
                        Label("Dictation", systemImage: "mic")
                    }
                } header: {
                    Text("Voice Input")
                } footer: {
                    Text("Configure speech-to-text for voice dictation in the composer.")
                }
            }

            Section("Cache") {
                Button("Clear Local Cache") {
                    Task.detached { await TimelineCache.shared.clear() }
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Build", value: "Phase 1")
            }
        }
        .navigationTitle("Settings")
        .navigationDestination(for: PairedServer.self) { server in
            ServerDetailView(server: server)
        }
        .sheet(isPresented: $showAddServer) {
            OnboardingView(mode: .addServer)
        }
        .alert("Rename Server", isPresented: Binding(
            get: { renameServerId != nil },
            set: { if !$0 { renameServerId = nil } }
        )) {
            TextField("Server name", text: $renameServerText)
            Button("Save") {
                if let id = renameServerId {
                    serverStore.rename(id: id, to: renameServerText)
                }
                renameServerId = nil
            }
            Button("Cancel", role: .cancel) {
                renameServerId = nil
            }
        }
        .confirmationDialog(
            removeDialogTitle,
            isPresented: Binding(
                get: { showRemoveConfirmation != nil },
                set: { if !$0 { showRemoveConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(removeDialogButtonTitle, role: .destructive) {
                if let server = showRemoveConfirmation {
                    removeServer(server)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeDialogMessage)
        }
    }

    private var liveActivityToggle: Binding<Bool> {
        Binding(
            get: { LiveActivityPreferences.isEnabled },
            set: { newValue in
                guard newValue != LiveActivityPreferences.isEnabled else { return }
                LiveActivityPreferences.setEnabled(newValue)
                if newValue {
                    _ = KeychainService.migrateLegacyServersToSharedGroup()
                }
                LiveActivityManager.shared.recoverIfNeeded()
            }
        )
    }

    // MARK: - Biometric Section

    @ViewBuilder
    private var biometricSection: some View {
        let bio = BiometricService.shared

        Section {
            Toggle(isOn: $biometricEnabled) {
                Label(
                    "Require \(bio.biometricName)",
                    systemImage: biometricIcon
                )
            }
            .onChange(of: biometricEnabled) { _, newValue in
                bio.isEnabled = newValue
            }
        } header: {
            Text("Biometric Approval")
        } footer: {
            if biometricEnabled {
                Text("All permission approvals require \(bio.biometricName). Deny is always one tap.")
            } else {
                Text("All permissions can be approved with a simple tap.")
            }
        }
    }

    @ViewBuilder
    private func serverStatusBadge(for server: PairedServer) -> some View {
        let conn = coordinator.connection(for: server.id)
        let wsStatus = conn?.wsClient?.status

        switch wsStatus {
        case .connected:
            Text("Connected")
                .font(.caption2)
                .foregroundStyle(.themeGreen)
        case .connecting:
            Text("Connecting…")
                .font(.caption2)
                .foregroundStyle(.themeYellow)
        case .reconnecting:
            Text("Reconnecting…")
                .font(.caption2)
                .foregroundStyle(.themeYellow)
        default:
            Text("Offline")
                .font(.caption2)
                .foregroundStyle(.themeComment)
        }
    }

    private var removingLastServer: Bool {
        guard let server = showRemoveConfirmation else {
            return false
        }
        return serverStore.servers.count == 1 && serverStore.servers.first?.id == server.id
    }

    private var removeDialogTitle: String {
        guard let server = showRemoveConfirmation else {
            return "Remove server?"
        }
        if removingLastServer {
            return "Remove your only paired server?"
        }
        return "Remove \(server.name)?"
    }

    private var removeDialogButtonTitle: String {
        removingLastServer ? "Remove Last Server" : "Remove Server"
    }

    private var removeDialogMessage: String {
        if removingLastServer {
            return "This is the only paired server on this device. Removing it will disconnect Oppi and return you to onboarding. You'll need to pair again before using the app."
        }
        return "This removes the server from this iPhone only. It does not delete anything on the server, and you can pair it again later."
    }

    private var biometricIcon: String {
        switch BiometricService.shared.biometricName {
        case "Face ID": return "faceid"
        case "Touch ID": return "touchid"
        case "Optic ID": return "opticid"
        default: return "lock"
        }
    }

    private func removeServer(_ server: PairedServer) {
        // Coordinator handles: disconnect, clean all stores, switch to next server
        coordinator.removeServer(id: server.id)

        // If no servers left, go to onboarding
        if serverStore.servers.isEmpty {
            navigation.showOnboarding = true
        }
    }
}
