import SwiftUI

struct SettingsView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(AppNavigation.self) private var navigation
    @Environment(ThemeStore.self) private var themeStore

    @State private var biometricEnabled = BiometricService.shared.isEnabled
    @State private var biometricThreshold = BiometricService.shared.threshold
    @State private var autoSessionTitleEnabled = UserDefaults.standard.object(
        forKey: ChatActionHandler.autoTitleEnabledDefaultsKey
    ) as? Bool ?? true

    var body: some View {
        List {
            Section("Server") {
                if let creds = connection.credentials {
                    LabeledContent("Host", value: creds.host)
                    LabeledContent("Port", value: String(creds.port))
                } else {
                    Text("Not connected")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Circle()
                        .fill(connection.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(connection.isConnected ? "Connected" : "Disconnected")
                        .font(.subheadline)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { themeStore.selectedThemeID },
                    set: { themeStore.selectedThemeID = $0 }
                )) {
                    ForEach(ThemeID.allCases, id: \.self) { themeID in
                        Text(themeID.displayName).tag(themeID)
                    }
                }

                Text(themeStore.selectedThemeID.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

            Section("Cache") {
                Button("Clear Local Cache") {
                    Task.detached { await TimelineCache.shared.clear() }
                }
            }

            Section("Account") {
                Button("Disconnect & Sign Out", role: .destructive) {
                    signOut()
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Build", value: "Phase 1")
            }
        }
        .navigationTitle("Settings")
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

    private func signOut() {
        connection.disconnectSession()
        KeychainService.deleteCredentials()
        Task.detached { await TimelineCache.shared.clear() }
        navigation.showOnboarding = true
    }
}
