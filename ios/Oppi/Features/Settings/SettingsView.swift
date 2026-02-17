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

private struct SecurityProfileEditorView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
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
                    // Save to per-server keychain slot (not legacy)
                    if let server = coordinator.serverStore.addOrUpdate(from: upgraded) {
                        try? KeychainService.saveServer(server)
                    }
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
