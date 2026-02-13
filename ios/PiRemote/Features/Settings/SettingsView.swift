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
    @State private var coloredThinkingBorder = UserDefaults.standard.bool(
        forKey: coloredThinkingBorderDefaultsKey
    )

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

                NavigationLink {
                    SecurityProfileEditorView()
                } label: {
                    Label("Security Profile", systemImage: "shield.lefthalf.filled")
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

            Section("Cache") {
                Button("Clear Local Cache") {
                    Task.detached { await TimelineCache.shared.clear() }
                }
            }

            Section {
                Button("Re-pair via Invite Link") {
                    startRePairing()
                }
            } header: {
                Text("Pairing")
            } footer: {
                Text("Opens onboarding without clearing local cache, sessions, or workspaces.")
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

    private func startRePairing() {
        navigation.showOnboarding = true
    }

    private func signOut() {
        connection.disconnectSession()
        KeychainService.deleteCredentials()
        Task.detached { await TimelineCache.shared.clear() }
        navigation.showOnboarding = true
    }
}

private struct SecurityProfileEditorView: View {
    @Environment(ServerConnection.self) private var connection

    @State private var form = SecurityProfileFormState()
    @State private var baseline = SecurityProfileFormState()
    @State private var identityKeyId = ""
    @State private var identityFingerprint = ""
    @State private var identityEnabled = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private let inviteMaxAgeOptions: [(label: String, value: Int)] = [
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("30 minutes", 1800),
        ("1 hour", 3600),
        ("24 hours", 86_400),
    ]

    private var hasChanges: Bool {
        form != baseline
    }

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading security profile…")
                        Spacer()
                    }
                }
            } else {
                Section {
                    Picker("Mode", selection: $form.profile) {
                        Text("Tailscale Permissive").tag("tailscale-permissive")
                        Text("Strict").tag("strict")
                        Text("Legacy").tag("legacy")
                    }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Strict is recommended outside trusted tailnet/local environments.")
                }

                Section("Transport") {
                    Toggle("Require TLS outside tailnet", isOn: $form.requireTlsOutsideTailnet)
                    Toggle("Allow insecure HTTP in tailnet", isOn: $form.allowInsecureHttpInTailnet)
                }

                Section("Identity") {
                    Toggle("Require pinned server identity", isOn: $form.requirePinnedServerIdentity)

                    LabeledContent("Identity", value: identityEnabled ? "Enabled" : "Disabled")
                    if !identityKeyId.isEmpty {
                        LabeledContent("Key ID", value: identityKeyId)
                    }
                    if !identityFingerprint.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fingerprint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(identityFingerprint)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .padding(.top, 2)
                    }
                }

                Section {
                    Picker("Max age", selection: $form.inviteMaxAgeSeconds) {
                        ForEach(inviteMaxAgeOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                } header: {
                    Text("Invite")
                } footer: {
                    Text("Applies to newly generated invite links and QR codes.")
                }
            }
        }
        .navigationTitle("Security Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(isLoading || isSaving || !hasChanges)
            }
        }
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
        .alert("Security Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "Unknown error")
        }
    }

    private func load() async {
        guard let api = connection.apiClient else {
            isLoading = false
            error = "Not connected to server"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let profile = try await api.securityProfile()
            apply(profile)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let api = connection.apiClient else {
            error = "Not connected to server"
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let updated = try await api.updateSecurityProfile(
                profile: form.profile,
                requireTlsOutsideTailnet: form.requireTlsOutsideTailnet,
                allowInsecureHttpInTailnet: form.allowInsecureHttpInTailnet,
                requirePinnedServerIdentity: form.requirePinnedServerIdentity,
                inviteMaxAgeSeconds: form.inviteMaxAgeSeconds
            )
            apply(updated)

            if let creds = connection.credentials {
                let upgraded = creds.applyingSecurityProfile(updated)
                if upgraded != creds {
                    try? KeychainService.saveCredentials(upgraded)
                }
            }

            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ profile: ServerSecurityProfile) {
        let updatedForm = SecurityProfileFormState(profile: profile)
        form = updatedForm
        baseline = updatedForm
        identityEnabled = profile.identity.enabled ?? false
        identityKeyId = profile.identity.keyId
        identityFingerprint = profile.identity.normalizedFingerprint ?? ""
    }
}

private struct SecurityProfileFormState: Equatable {
    var profile: String = "tailscale-permissive"
    var requireTlsOutsideTailnet: Bool = true
    var allowInsecureHttpInTailnet: Bool = true
    var requirePinnedServerIdentity: Bool = true
    var inviteMaxAgeSeconds: Int = 600

    init() {}

    init(profile: ServerSecurityProfile) {
        self.profile = profile.profile
        self.requireTlsOutsideTailnet = profile.requireTlsOutsideTailnet ?? false
        self.allowInsecureHttpInTailnet = profile.allowInsecureHttpInTailnet ?? true
        self.requirePinnedServerIdentity = profile.requirePinnedServerIdentity ?? false
        self.inviteMaxAgeSeconds = profile.invite.maxAgeSeconds
    }
}
