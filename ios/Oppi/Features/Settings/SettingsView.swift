import SwiftUI

struct SettingsView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerConnection.self) private var connection
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(ThemeStore.self) private var themeStore

    @State private var biometricEnabled = BiometricService.shared.isEnabled
    @State private var biometricThreshold = BiometricService.shared.threshold
    @State private var autoSessionTitleEnabled = UserDefaults.standard.object(
        forKey: ChatActionHandler.autoTitleEnabledDefaultsKey
    ) as? Bool ?? true
    @State private var coloredThinkingBorder = UserDefaults.standard.bool(
        forKey: coloredThinkingBorderDefaultsKey
    )
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
                            Image(systemName: "server.rack")
                                .font(.caption)
                                .foregroundStyle(server.id == connection.currentServerId ? .green : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.subheadline.weight(.medium))
                                Text("\(server.host):\(server.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if server.id == connection.currentServerId {
                                Text("Active")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
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
                        .disabled(serverStore.servers.count <= 1)
                    }
                }

                Button {
                    showAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }

            Section("Connection") {
                HStack {
                    Circle()
                        .fill(connection.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(connection.isConnected ? "Connected" : "Disconnected")
                        .font(.subheadline)
                }

                Label("Security posture managed on server", systemImage: "shield.lefthalf.filled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)

                NavigationLink("Import from Server") {
                    ThemeImportView()
                }

                Toggle("Colored thinking border", isOn: $coloredThinkingBorder)
                    .onChange(of: coloredThinkingBorder) { _, newValue in
                        UserDefaults.standard.set(
                            newValue,
                            forKey: coloredThinkingBorderDefaultsKey
                        )
                    }
            }

            Section("Workspaces") {
                NavigationLink {
                    WorkspaceListView()
                } label: {
                    Label("Manage Workspaces", systemImage: "square.grid.2x2")
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
                    "Uses the first prompt to generate a short title on device. "
                        + "Enabled by default."
                )
            }

            biometricSection

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
            "Remove \(showRemoveConfirmation?.name ?? "server")?",
            isPresented: Binding(
                get: { showRemoveConfirmation != nil },
                set: { if !$0 { showRemoveConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let server = showRemoveConfirmation {
                    removeServer(server)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the server from your paired servers. You can re-pair later.")
        }
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

            if biometricEnabled {
                Picker("Minimum Risk Level", selection: $biometricThreshold) {
                    Text("High + Critical").tag(RiskLevel.high)
                    Text("Critical Only").tag(RiskLevel.critical)
                    Text("All Permissions").tag(RiskLevel.low)
                }
                .onChange(of: biometricThreshold) { _, newValue in
                    bio.threshold = newValue
                }
            }
        } header: {
            Text("Biometric Approval")
        } footer: {
            if biometricEnabled {
                Text("Permissions at or above \(biometricThreshold.label.lowercased()) risk require \(bio.biometricName) to approve. Deny is always one tap.")
            } else {
                Text("All permissions can be approved with a simple tap.")
            }
        }
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

