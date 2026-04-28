import SwiftUI

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themeStore

    @State private var spinnerStyle = AppPreferences.Appearance.spinnerStyle
    @State private var assistantAvatar = AssistantAvatar.current
    @State private var showAvatarPicker = false
    @State private var biometricEnabled = BiometricService.shared.isEnabled
    @State private var autoTitleProvider = AppPreferences.Session.autoTitleProvider
    @State private var screenAwakePreset = AppPreferences.ScreenAwake.timeoutPreset
    @State private var cacheSizeText: String?
    @State private var telemetryEnabled = AppPreferences.Telemetry.isEnabled
    @State private var selectedCodeFont = FontPreferences.codeFont
    @State private var useMonoMessages = FontPreferences.useMonoForMessages
    @State private var voiceEngineMode = AppPreferences.Voice.engineMode
    @State private var voiceReplyMode = AppPreferences.Voice.replyMode

    var body: some View {
        List {
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

                if !themeStore.selectedThemeID.detail.isEmpty {
                    Text(themeStore.selectedThemeID.detail)
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }

                NavigationLink("Import from Server") {
                    ThemeImportView()
                }

                Button {
                    showAvatarPicker = true
                } label: {
                    LabeledContent("Assistant Avatar") {
                        HStack(spacing: 10) {
                            Text(assistantAvatarSummary)
                                .foregroundStyle(.themeComment)
                            AssistantAvatarPreview(
                                avatar: assistantAvatar,
                                sessionId: "settings-avatar-preview",
                                size: 22
                            )
                        }
                    }
                }
                .sheet(isPresented: $showAvatarPicker) {
                    AvatarPickerView(avatar: $assistantAvatar)
                        .presentationDetents([.medium])
                }

                Picker("Spinner Style", selection: $spinnerStyle) {
                    ForEach(SpinnerStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: spinnerStyle) { _, newValue in
                    AppPreferences.Appearance.setSpinnerStyle(newValue)
                }

                LabeledContent("Spinner Preview") {
                    WorkingSpinnerView(tintColor: .themeFg, style: spinnerStyle)
                        .frame(width: 20, height: 20)
                        .id(spinnerStyle)
                }
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

            Section {
                NavigationLink {
                    AutoTitleSettingsView()
                } label: {
                    LabeledContent("Auto-name Sessions") {
                        Text(autoTitleProviderLabel)
                            .foregroundStyle(.themeComment)
                    }
                }

                NavigationLink {
                    SubagentSettingsView()
                } label: {
                    Label("Subagents", systemImage: "point.3.connected.trianglepath.dotted")
                }

                Picker("Keep screen awake", selection: $screenAwakePreset) {
                    ForEach(AppPreferences.ScreenAwake.TimeoutPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .onChange(of: screenAwakePreset) { _, newValue in
                    AppPreferences.ScreenAwake.setTimeoutPreset(newValue)
                    ScreenAwakeController.shared.refreshFromPreferences()
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text(screenAwakeFooter)
            }

            Section {
                NavigationLink {
                    PiActionsSettingsView()
                } label: {
                    Label("π Actions", systemImage: "contextualmenu.and.cursorarrow")
                }
            } header: {
                Text("Text Selection")
            } footer: {
                Text("Customize the π menu shown when selecting text in chat and file views.")
            }

            Section {
                Picker("Voice Replies", selection: $voiceReplyMode) {
                    ForEach(AppPreferences.Voice.ReplyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: voiceReplyMode) { _, newValue in
                    AppPreferences.Voice.setReplyMode(newValue)
                }

                if voiceReplyMode == .voice {
                    Text(AppPreferences.Voice.ReplyMode.voice.detail)
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }

                Picker("Dictation Engine", selection: $voiceEngineMode) {
                    ForEach(AppPreferences.Voice.supportedModes) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: voiceEngineMode) { _, newValue in
                    AppPreferences.Voice.setEngineMode(newValue)
                }
            } header: {
                Text("Voice")
            } footer: {
                Text(
                    "Voice mode autoplays only when the agent explicitly requests direct playback. "
                        + "Voice message mode never autoplays. Direct speak autoplays all voice replies. "
                        + "Server dictation uses your Mac's ASR model. On-device uses Apple's local dictation."
                )
            }

            if ReleaseFeatures.liveActivitiesEnabled {
                Section {
                    Toggle("Live Activities", isOn: liveActivityToggle)
                } header: {
                    Text("Experiments")
                } footer: {
                    Text("Early builds — expect rough edges.")
                }
            }

            securitySection

            diagnosticsSection

            Section("Storage") {
                if let cacheSizeText {
                    LabeledContent("Local Cache", value: cacheSizeText)
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
                LabeledContent("Version", value: appVersionLabel)
            }
        }
        .onAppear {
            // Refresh provider label when returning from AutoTitleSettingsView
            autoTitleProvider = AppPreferences.Session.autoTitleProvider
        }
        .themedListSurface()
        .navigationTitle("Settings")
    }

    private var liveActivityToggle: Binding<Bool> {
        Binding(
            get: { AppPreferences.LiveActivity.isEnabled },
            set: { newValue in
                guard newValue != AppPreferences.LiveActivity.isEnabled else { return }
                AppPreferences.LiveActivity.setEnabled(newValue)
                if newValue {
                    _ = KeychainService.migrateLegacyServersToSharedGroup()
                }
                LiveActivityManager.shared.recoverIfNeeded()
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

    private var assistantAvatarSummary: String {
        switch assistantAvatar {
        case .emoji:
            return "Emoji"
        case .genmoji:
            return "Genmoji"
        case .piText, .golGrid:
            return assistantAvatar.displayName
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private var screenAwakeFooter: String {
        switch screenAwakePreset {
        case .off:
            return "Keeps the screen on while voice input is active or the agent is working."
        default:
            return "Keeps the screen on while active, plus \(screenAwakePreset.label) after activity ends."
        }
    }

    // MARK: - Diagnostics Section

    @ViewBuilder
    private var diagnosticsSection: some View {
        if TelemetryMode.current == .public {
            // Release builds: opt-in toggle for metrics to user's own server.
            // Sentry (external crash reporting) is always disabled in release.
            Section {
                Toggle("Send Performance Metrics", isOn: $telemetryEnabled)
                    .onChange(of: telemetryEnabled) { _, newValue in
                        AppPreferences.Telemetry.setEnabled(newValue)
                        MetricKitService.shared.refreshAfterPreferenceChange()
                        DeviceResourceSampler.shared.refreshAfterPreferenceChange()
                    }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(
                    "Send performance metrics to your server. "
                        + "Data stays on your server and is never shared externally."
                )
            }
        } else {
            // Internal/debug builds: always active, no toggle needed.
            Section {
                Text("Diagnostics are active (internal build)")
                    .foregroundStyle(.themeComment)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Performance metrics are uploaded automatically in internal builds.")
            }
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
}
