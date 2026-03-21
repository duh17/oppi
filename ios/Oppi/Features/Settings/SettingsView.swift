import SwiftUI

struct SettingsView: View {
    private enum VoiceEndpointProbeState: Equatable {
        case idle
        case probing
        case reachable(Int)
        case unreachable
    }

    private enum RuntimeUpdateBadgeState: Equatable {
        case updateAvailable
        case restartRequired
        case upToDate
        case unavailable
        case unknown
    }

    private static let remoteVoiceInputSettingsEnabled = false

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(ThemeStore.self) private var themeStore

    @State private var spinnerStyleRaw = UserDefaults.standard.string(forKey: "spinnerStyle") ?? SpinnerStyle.brailleDots.rawValue
    @State private var biometricEnabled = BiometricService.shared.isEnabled
    @State private var autoSessionTitleEnabled = UserDefaults.standard.object(
        forKey: ChatActionHandler.autoTitleEnabledDefaultsKey
    ) as? Bool ?? false
    @State private var screenAwakePreset = ScreenAwakePreferences.timeoutPreset
    @State private var voiceEngineMode = VoiceInputPreferences.engineMode
    @State private var remoteASREndpointText = VoiceInputPreferences.remoteEndpoint?.absoluteString ?? ""
    @State private var voiceEndpointError: String?
    @State private var voiceEndpointProbeState: VoiceEndpointProbeState = .idle
    @State private var cacheSizeText: String?
    @State private var showAddServer = false
    @State private var renameServerId: String?
    @State private var renameServerText = ""
    @State private var showRemoveConfirmation: PairedServer?
    @State private var runtimeUpdateBadgesByServerId: [String: RuntimeUpdateBadgeState] = [:]

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

                Picker("Spinner Style", selection: $spinnerStyleRaw) {
                    ForEach(SpinnerStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .onChange(of: spinnerStyleRaw) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "spinnerStyle")
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

            Section("Pi Actions") {
                NavigationLink {
                    PiActionsSettingsView()
                } label: {
                    Label("Text Selection Actions", systemImage: "contextualmenu.and.cursorarrow")
                }
            }

            Section {
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
                Text("Display")
            } footer: {
                Text(screenAwakeFooter)
            }

            if ReleaseFeatures.voiceInputEnabled {
                Section {
                    if Self.remoteVoiceInputSettingsEnabled {
                        Picker("Transcription engine", selection: $voiceEngineMode) {
                            ForEach(VoiceInputPreferences.EngineMode.allCases) { mode in
                                Text(mode.label)
                                    .foregroundStyle(voiceModeTint(mode))
                                    .tag(mode)
                            }
                        }
                        .onChange(of: voiceEngineMode) { _, newValue in
                            VoiceInputPreferences.setEngineMode(newValue)
                            voiceEndpointProbeState = .idle

                            let trimmed = remoteASREndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if newValue == .remote, trimmed.isEmpty {
                                voiceEndpointError = "Remote mode requires a valid endpoint URL."
                            } else if trimmed.isEmpty || VoiceInputPreferences.normalizedEndpointURL(from: trimmed) != nil {
                                voiceEndpointError = nil
                            }
                        }

                        LabeledContent("Dictation route") {
                            HStack(spacing: 6) {
                                if shouldShowCloudForRoute {
                                    Image(systemName: "cloud.fill")
                                }
                                Text(dictationRouteLabel)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(dictationRouteColor)
                        }

                        if voiceEngineMode != .onDevice {
                            TextField("http://mac-studio.local:9847", text: $remoteASREndpointText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.URL)
                                .submitLabel(.done)
                                .onSubmit {
                                    applyVoiceEndpoint(remoteASREndpointText, canonicalizeInput: true)
                                    testVoiceEndpoint()
                                }
                                .onChange(of: remoteASREndpointText) { _, newValue in
                                    applyVoiceEndpoint(newValue)
                                    voiceEndpointProbeState = .idle
                                }

                            HStack(spacing: 10) {
                                Button {
                                    testVoiceEndpoint()
                                } label: {
                                    if voiceEndpointProbeState == .probing {
                                        HStack(spacing: 6) {
                                            ProgressView()
                                                .controlSize(.mini)
                                            Text("Testing…")
                                        }
                                    } else {
                                        Label("Test connection", systemImage: "network")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(voiceEndpointProbeState == .probing)

                                Spacer(minLength: 8)
                                voiceEndpointProbeLabel
                            }
                        }

                        if let voiceEndpointError {
                            Text(voiceEndpointError)
                                .font(.caption)
                                .foregroundStyle(.themeRed)
                        }
                    } else {
                        LabeledContent("Transcription engine") {
                            Text(VoiceInputPreferences.EngineMode.onDevice.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(voiceModeTint(.onDevice))
                        }

                        LabeledContent("Dictation route") {
                            Text("On-device")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(voiceModeTint(.onDevice))
                        }
                    }
                } header: {
                    Text("Voice Input")
                } footer: {
                    Text(voiceInputFooter)
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
                    Text(
                        "These features are under active development and off by default. "
                            + "Enable them to try early builds — expect rough edges."
                    )
                }
            }

            biometricSection

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
                LabeledContent("Build", value: "Phase 1")
            }
        }
        .onAppear {
            enforceVoiceInputAvailability()
            Task {
                await refreshRuntimeUpdateBadges()
            }
        }
        .task(id: runtimeBadgeRefreshKey) {
            await refreshRuntimeUpdateBadges()
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

    private var screenAwakeFooter: String {
        switch screenAwakePreset {
        case .off:
            return "Prevents auto-lock only while voice input is active or the agent is working. Screen sleep returns immediately when activity ends."
        default:
            return "Prevents auto-lock while voice input is active or the agent is working. After activity ends, keeps the screen awake for \(screenAwakePreset.label)."
        }
    }

    private func enforceVoiceInputAvailability() {
        guard !Self.remoteVoiceInputSettingsEnabled else { return }

        if voiceEngineMode != .onDevice || VoiceInputPreferences.engineMode != .onDevice {
            voiceEngineMode = .onDevice
            VoiceInputPreferences.setEngineMode(.onDevice)
        }

        voiceEndpointError = nil
        voiceEndpointProbeState = .idle
    }

    private var voiceInputFooter: String {
        guard Self.remoteVoiceInputSettingsEnabled else {
            return "Remote transcription is temporarily disabled. Oppi currently uses Apple's on-device transcription."
        }

        switch voiceEngineMode {
        case .auto:
            return "Automatic probes your remote endpoint first, then falls back to on-device transcription if unreachable."
        case .onDevice:
            return "Always uses Apple's on-device transcription (locale-aware Speech/Dictation routing)."
        case .remote:
            if remoteASREndpointText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Remote mode requires an endpoint URL below before recording can start."
            }
            return "Always uses the remote OpenAI-compatible /v1/audio/transcriptions endpoint."
        }
    }

    private var dictationRouteLabel: String {
        switch voiceEngineMode {
        case .onDevice:
            return "On-device"
        case .remote:
            return "Remote"
        case .auto:
            switch voiceEndpointProbeState {
            case .reachable:
                return "Remote"
            case .unreachable:
                return "On-device"
            case .idle:
                return "Automatic"
            case .probing:
                return "Checking…"
            }
        }
    }

    private var shouldShowCloudForRoute: Bool {
        switch voiceEngineMode {
        case .remote:
            return true
        case .auto:
            if case .reachable = voiceEndpointProbeState {
                return true
            }
            return false
        case .onDevice:
            return false
        }
    }

    private var dictationRouteColor: Color {
        switch voiceEngineMode {
        case .onDevice:
            return voiceModeTint(.onDevice)
        case .remote:
            return voiceModeTint(.remote)
        case .auto:
            switch voiceEndpointProbeState {
            case .reachable:
                return voiceModeTint(.remote)
            case .unreachable:
                return voiceModeTint(.onDevice)
            case .idle, .probing:
                return voiceModeTint(.auto)
            }
        }
    }

    private func voiceModeTint(_ mode: VoiceInputPreferences.EngineMode) -> Color {
        switch mode {
        case .auto:
            return .themeComment
        case .onDevice:
            return .themeBlue
        case .remote:
            return .themeCyan
        }
    }

    @ViewBuilder
    private var voiceEndpointProbeLabel: some View {
        switch voiceEndpointProbeState {
        case .idle:
            EmptyView()

        case .probing:
            Text("Checking…")
                .font(.caption)
                .foregroundStyle(.themeComment)

        case .reachable(let latencyMs):
            Label("Reachable (\(latencyMs) ms)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.themeGreen)

        case .unreachable:
            Label("Unreachable", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.themeOrange)
        }
    }

    func testVoiceEndpoint() {
        let trimmed = remoteASREndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = VoiceInputPreferences.normalizedEndpointURL(from: trimmed) else {
            voiceEndpointProbeState = .unreachable
            voiceEndpointError = "Enter a valid http:// or https:// URL."
            return
        }

        voiceEndpointProbeState = .probing

        Task {
            let start = ContinuousClock.now
            let reachable = await Self.probeVoiceEndpoint(endpoint)
            let elapsed = ContinuousClock.now - start
            let latencyMs = Int(
                elapsed.components.seconds * 1000
                    + elapsed.components.attoseconds / 1_000_000_000_000_000
            )

            await MainActor.run {
                if reachable {
                    voiceEndpointProbeState = .reachable(max(0, latencyMs))
                    if voiceEndpointError == "Can’t reach endpoint. Check server and network." {
                        voiceEndpointError = nil
                    }
                } else {
                    voiceEndpointProbeState = .unreachable
                    voiceEndpointError = "Can’t reach endpoint. Check server and network."
                }
            }
        }
    }

    private static func probeVoiceEndpoint(_ endpoint: URL) async -> Bool {
        let healthURL = endpoint.appendingPathComponent("health")
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 3.0
        config.waitsForConnectivity = false

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func applyVoiceEndpoint(_ raw: String, canonicalizeInput: Bool = false) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            VoiceInputPreferences.setRemoteEndpoint(nil)
            if voiceEngineMode == .remote {
                voiceEndpointError = "Remote mode requires a valid endpoint URL."
            } else {
                voiceEndpointError = nil
            }
            return
        }

        guard let normalized = VoiceInputPreferences.normalizedEndpointURL(from: trimmed) else {
            voiceEndpointError = "Enter a valid http:// or https:// URL."
            return
        }

        VoiceInputPreferences.setRemoteEndpoint(normalized)
        voiceEndpointError = nil

        if canonicalizeInput {
            remoteASREndpointText = normalized.absoluteString
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
