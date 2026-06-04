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
    @State private var linkOpeningMode = AppPreferences.Browser.linkOpeningMode
    @State private var voiceEngineMode = AppPreferences.Voice.engineMode
    @State private var voiceReplyMode = AppPreferences.Voice.replyMode

    var body: some View {
        List {
            Section("Appearance") {
                Picker("Theme Mode", selection: Binding(
                    get: { themeStore.mode },
                    set: { themeStore.mode = $0 }
                )) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text(themeStore.mode.detail)
                    .font(.footnote)
                    .foregroundStyle(.themeComment)

                if themeStore.mode == .manual {
                    themePicker("Theme", selection: Binding(
                        get: { themeStore.manualThemeID },
                        set: { themeStore.manualThemeID = $0 }
                    ))

                    if !themeStore.manualThemeID.detail.isEmpty {
                        Text(themeStore.manualThemeID.detail)
                            .font(.footnote)
                            .foregroundStyle(.themeComment)
                    }
                } else {
                    themePicker("Light Theme", selection: Binding(
                        get: { themeStore.lightThemeID },
                        set: { themeStore.lightThemeID = $0 }
                    ))

                    themePicker("Dark Theme", selection: Binding(
                        get: { themeStore.darkThemeID },
                        set: { themeStore.darkThemeID = $0 }
                    ))

                    Text("Uses your iOS Display & Brightness setting, including Apple's automatic schedule.")
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
                    QuickCommentsSettingsView()
                } label: {
                    Label("Quick Comments", systemImage: "text.bubble")
                }
            } header: {
                Text("Text Selection")
            } footer: {
                Text("Customize the quick comments shown after selecting text and choosing Comment.")
            }

            Section {
                Picker("Open Links", selection: $linkOpeningMode) {
                    ForEach(AppPreferences.Browser.LinkOpeningMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: linkOpeningMode) { _, newValue in
                    AppPreferences.Browser.setLinkOpeningMode(newValue)
                }

                Text(linkOpeningMode.detail)
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
            } header: {
                Text("Browser")
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

                Text(voiceReplyMode.detail)
                    .font(.footnote)
                    .foregroundStyle(.themeComment)

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
                    "Choose whether voice replies stay manual or follow each reply's playback behavior. "
                        + "You can still ask the agent to change this for the current session. "
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
        .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
        .themedListSurface()
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private func themePicker(_ title: String, selection: Binding<ThemeID>) -> some View {
        Picker(title, selection: selection) {
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
            // Release builds: opt-in toggle for diagnostics to user's own server.
            // Sentry (external crash reporting) is always disabled in release.
            Section {
                Toggle("Send Diagnostics to Server", isOn: $telemetryEnabled)
                    .onChange(of: telemetryEnabled) { _, newValue in
                        AppPreferences.Telemetry.setEnabled(newValue)
                        MetricKitService.shared.refreshAfterPreferenceChange()
                        DeviceResourceSampler.shared.refreshAfterPreferenceChange()
                    }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(
                    "Send performance metrics, client log breadcrumbs, and crash diagnostics to your server. "
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
                Text("Sensitive local actions require \(bio.biometricName).")
            } else {
                Text("Sensitive local actions skip device authentication.")
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
