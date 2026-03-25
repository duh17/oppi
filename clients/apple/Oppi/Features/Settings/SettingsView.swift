import SwiftUI

struct SettingsView: View {
    private enum RuntimeUpdateBadgeState: Equatable {
        case updateAvailable
        case restartRequired
        case upToDate
        case unavailable
        case unknown
    }

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(ThemeStore.self) private var themeStore

    @State private var spinnerStyle = AppPreferences.Appearance.spinnerStyle
    @State private var biometricEnabled = BiometricService.shared.isEnabled
    @State private var autoTitleProvider = AppPreferences.Session.autoTitleProvider
    @State private var screenAwakePreset = ScreenAwakePreferences.timeoutPreset
    @State private var cacheSizeText: String?
    @State private var showAddServer = false
    @State private var renameServerId: String?
    @State private var renameServerText = ""
    @State private var showRemoveConfirmation: PairedServer?
    @State private var runtimeUpdateBadgesByServerId: [String: RuntimeUpdateBadgeState] = [:]
    @State private var selectedCodeFont = FontPreferences.codeFont
    @State private var useMonoMessages = FontPreferences.useMonoForMessages

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

                            HStack(spacing: 6) {
                                runtimeUpdateBadge(for: server)
                                serverStatusBadge(for: server)
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
                    }
                }

                Button {
                    showAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }

            Section {
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

                if !themeStore.selectedThemeID.detail.isEmpty {
                    Text(themeStore.selectedThemeID.detail)
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }

                NavigationLink("Import from Server") {
                    ThemeImportView()
                }

                Picker("Spinner Style", selection: $spinnerStyle) {
                    ForEach(SpinnerStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: spinnerStyle) { _, newValue in
                    AppPreferences.Appearance.setSpinnerStyle(newValue)
                }

                LabeledContent("Preview") {
                    WorkingSpinnerView(tintColor: .themeFg, style: spinnerStyle)
                        .frame(width: 20, height: 20)
                        .id(spinnerStyle)
                }

                NavigationLink {
                    AutoTitleSettingsView()
                } label: {
                    LabeledContent("Auto-name Sessions") {
                        Text(autoTitleProviderLabel)
                            .foregroundStyle(.themeComment)
                    }
                }

                Picker("Keep screen awake", selection: $screenAwakePreset) {
                    ForEach(ScreenAwakePreferences.TimeoutPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .onChange(of: screenAwakePreset) { _, newValue in
                    ScreenAwakePreferences.setTimeoutPreset(newValue)
                    ScreenAwakeController.shared.refreshFromPreferences()
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text(screenAwakeFooter)
            }

            Section {
                Picker("Code Font", selection: $selectedCodeFont) {
                    ForEach(FontPreferences.CodeFontFamily.allCases) { family in
                        Text(family.displayName)
                            .tag(family)
                    }
                }
                .onChange(of: selectedCodeFont) { _, newValue in
                    FontPreferences.setCodeFont(newValue)
                }

                Toggle("Monospaced messages", isOn: $useMonoMessages)
                    .onChange(of: useMonoMessages) { _, newValue in
                        FontPreferences.setUseMonoForMessages(newValue)
                    }
            } header: {
                Text("Typography")
            } footer: {
                Text(
                    "Code Font applies to code blocks, tool output, and diffs. "
                        + "Monospaced messages uses the selected code font for all message text."
                )
            }

            Section("Quick Actions") {
                NavigationLink {
                    PiActionsSettingsView()
                } label: {
                    Label("Text Selection Actions", systemImage: "contextualmenu.and.cursorarrow")
                }
            }

            if ReleaseFeatures.liveActivitiesEnabled || ReleaseFeatures.nativePlotRenderingEnabled {
                Section {
                    if ReleaseFeatures.liveActivitiesEnabled {
                        Toggle("Live Activities", isOn: liveActivityToggle)
                    }
                    if ReleaseFeatures.nativePlotRenderingEnabled {
                        Toggle("Native Chart Rendering", isOn: nativePlotToggle)
                    }
                } header: {
                    Text("Experiments")
                } footer: {
                    Text("Early builds — expect rough edges.")
                }
            }

            securitySection

            Section("Cache") {
                if let cacheSizeText {
                    LabeledContent("Size", value: cacheSizeText)
                }
                Button("Clear Local Cache") {
                    Task.detached {
                        await TimelineCache.shared.clear()
                        let formatted = await Self.formattedCacheSize()
                        await MainActor.run { cacheSizeText = formatted }
                    }
                }
            }
            .task { cacheSizeText = await Self.formattedCacheSize() }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
            }
        }
        .onAppear {
            // Refresh provider label when returning from AutoTitleSettingsView
            autoTitleProvider = AppPreferences.Session.autoTitleProvider
            Task {
                await refreshRuntimeUpdateBadges()
            }
        }
        .task(id: runtimeBadgeRefreshKey) {
            await refreshRuntimeUpdateBadges()
        }
        .themedListSurface()
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

    private var runtimeBadgeRefreshKey: String {
        serverStore.servers.map(\.id).joined(separator: ",")
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

    private var nativePlotToggle: Binding<Bool> {
        Binding(
            get: { NativePlotPreferences.isEnabled },
            set: { newValue in
                guard newValue != NativePlotPreferences.isEnabled else { return }
                NativePlotPreferences.setEnabled(newValue)
            }
        )
    }

    private var autoTitleProviderLabel: String {
        switch autoTitleProvider {
        case .server: return "Server"
        case .onDevice: return "On-device"
        case .off: return "Off"
        }
    }

    private var screenAwakeFooter: String {
        switch screenAwakePreset {
        case .off:
            return "Keeps the screen on while voice input is active or the agent is working."
        default:
            return "Keeps the screen on while active, plus \(screenAwakePreset.label) after activity ends."
        }
    }

    // MARK: - Security Section

    @ViewBuilder
    private var securitySection: some View {
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
            Text("Security")
        } footer: {
            if biometricEnabled {
                Text("Permission approvals require \(bio.biometricName). Deny is always one tap.")
            } else {
                Text("Permissions can be approved with a simple tap.")
            }
        }
    }

    @ViewBuilder
    private func runtimeUpdateBadge(for server: PairedServer) -> some View {
        switch runtimeUpdateBadgesByServerId[server.id] {
        case .updateAvailable:
            Text("Update")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeOrange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.themeOrange.opacity(0.16))
                )

        case .restartRequired:
            Text("Restart")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeYellow)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.themeYellow.opacity(0.16))
                )

        case .upToDate, .unavailable, .unknown, .none:
            EmptyView()
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

    @MainActor
    private func refreshRuntimeUpdateBadges() async {
        let servers = serverStore.servers
        var next: [String: RuntimeUpdateBadgeState] = [:]
        next.reserveCapacity(servers.count)

        for server in servers {
            next[server.id] = await runtimeUpdateBadgeState(for: server)
        }

        runtimeUpdateBadgesByServerId = next
    }

    @MainActor
    private func runtimeUpdateBadgeState(for server: PairedServer) async -> RuntimeUpdateBadgeState {
        guard let baseURL = server.baseURL else {
            return .unknown
        }

        let api = APIClient(
            baseURL: baseURL,
            token: server.token,
            tlsCertFingerprint: server.tlsCertFingerprint
        )

        do {
            let info = try await api.serverInfo()
            return runtimeUpdateBadgeState(from: info.runtimeUpdate)
        } catch {
            return .unknown
        }
    }

    private func runtimeUpdateBadgeState(
        from runtimeUpdate: ServerInfo.RuntimeUpdateInfo?
    ) -> RuntimeUpdateBadgeState {
        guard let runtimeUpdate else {
            return .unknown
        }

        if runtimeUpdate.restartRequired {
            return .restartRequired
        }
        if runtimeUpdate.updateAvailable {
            return .updateAvailable
        }
        if runtimeUpdate.canUpdate {
            return .upToDate
        }
        return .unavailable
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

    private static func formattedCacheSize() async -> String {
        let bytes = await TimelineCache.shared.diskSize()
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
