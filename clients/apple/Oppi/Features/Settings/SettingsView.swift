import SwiftUI
import UIKit

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
    @State private var selectedCodeTextScale = FontPreferences.codeTextScale
    @State private var selectedMessageTextScale = FontPreferences.messageTextScale
    @State private var useMonoMessages = FontPreferences.useMonoForMessages
    @State private var linkOpeningMode = AppPreferences.Browser.linkOpeningMode
    @State private var voiceEngineMode = AppPreferences.Voice.engineMode
    @State private var voiceReplyMode = AppPreferences.Voice.replyMode

    var body: some View {
        List {
            Section("Appearance") {
                Picker("Theme Source", selection: Binding(
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

                NavigationLink("Import Theme") {
                    ThemeImportView()
                }
            }

            Section {
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
            } header: {
                Text("Chat Display")
            } footer: {
                Text("Controls how chat activity appears on this device.")
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Code Text Size")
                        Spacer()
                        Text("\(Int(round(selectedCodeTextScale * 100)))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.themeComment)
                    }

                    Slider(
                        value: $selectedCodeTextScale,
                        in: FontPreferences.minimumCodeTextScale...FontPreferences.maximumCodeTextScale,
                        step: 0.05
                    ) {
                        Text("Code Text Size")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .accessibilityValue("\(Int(round(selectedCodeTextScale * 100))) percent")

                    Text("Code blocks, diffs, terminals, and tool output.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }
                .onChange(of: selectedCodeTextScale) { _, newValue in
                    FontPreferences.setCodeTextScale(CGFloat(newValue))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Message Text Size")
                        Spacer()
                        Text("\(Int(round(selectedMessageTextScale * 100)))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.themeComment)
                    }

                    Slider(
                        value: $selectedMessageTextScale,
                        in: FontPreferences.minimumMessageTextScale...FontPreferences.maximumMessageTextScale,
                        step: 0.05
                    ) {
                        Text("Message Text Size")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .accessibilityValue("\(Int(round(selectedMessageTextScale * 100))) percent")

                    Text("Assistant and user chat messages.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }
                .onChange(of: selectedMessageTextScale) { _, newValue in
                    FontPreferences.setMessageTextScale(CGFloat(newValue))
                }

                Toggle("Monospaced messages", isOn: $useMonoMessages)
                    .onChange(of: useMonoMessages) { _, newValue in
                        FontPreferences.setUseMonoForMessages(newValue)
                    }

                TypographyPreviewCard(
                    codeFont: selectedCodeFont,
                    codeTextScale: selectedCodeTextScale,
                    messageTextScale: selectedMessageTextScale,
                    useMonoMessages: useMonoMessages
                )
            } header: {
                Text("Text")
            } footer: {
                Text("Text settings are saved on this device.")
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

                Text(screenAwakeDetail)
                    .font(.footnote)
                    .foregroundStyle(.themeComment)

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
                Text("Sessions")
            } footer: {
                Text("Session defaults are saved on this device.")
            }

            Section {
                NavigationLink {
                    QuickCommentsSettingsView()
                } label: {
                    Label("Quick Comments", systemImage: "text.bubble")
                }

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
                Text("Input")
            } footer: {
                Text(
                    "Controls text selection shortcuts, voice replies, and dictation defaults. "
                        + "Session-specific changes still happen in chat."
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

            privacySecuritySection

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
            selectedCodeTextScale = FontPreferences.codeTextScale
            selectedMessageTextScale = FontPreferences.messageTextScale
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

    private var screenAwakeDetail: String {
        switch screenAwakePreset {
        case .off:
            return "Keeps the screen on while voice input is active or the agent is working."
        default:
            return "Keeps the screen on while active, plus \(screenAwakePreset.label) after activity ends."
        }
    }

    // MARK: - Privacy & Security Section

    private var privacySecurityFooter: String {
        let bio = BiometricService.shared
        let authenticationText = biometricEnabled
            ? "Sensitive local actions require \(bio.biometricName)."
            : "Sensitive local actions skip device authentication."
        let diagnosticsText = TelemetryMode.current == .public
            ? "Diagnostics stay on your server and are never shared externally."
            : "Internal builds upload performance metrics automatically."
        return "\(authenticationText) \(diagnosticsText)"
    }

    @ViewBuilder
    private var privacySecuritySection: some View {
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

            if TelemetryMode.current == .public {
                Toggle("Send Diagnostics to Server", isOn: $telemetryEnabled)
                    .onChange(of: telemetryEnabled) { _, newValue in
                        AppPreferences.Telemetry.setEnabled(newValue)
                        MetricKitService.shared.refreshAfterPreferenceChange()
                        DeviceResourceSampler.shared.refreshAfterPreferenceChange()
                    }
            } else {
                Text("Diagnostics are active (internal build)")
                    .foregroundStyle(.themeComment)
            }
        } header: {
            Text("Privacy & Security")
        } footer: {
            Text(privacySecurityFooter)
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

private struct TypographyPreviewCard: View {
    let codeFont: FontPreferences.CodeFontFamily
    let codeTextScale: CGFloat
    let messageTextScale: CGFloat
    let useMonoMessages: Bool

    private var codePreviewPointSize: CGFloat {
        FontPreferences.codePointSize(baseSize: 11, codeTextScale: codeTextScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Preview", systemImage: "text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFgDim)

            VStack(alignment: .leading, spacing: 6) {
                Text("Code and tool output")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)

                Text("let files = try await workspace.changedFiles()\nprint(files.count)")
                    .font(previewFont(size: codePreviewPointSize, uiWeight: .regular))
                    .foregroundStyle(.themeFg)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.themeBgDark, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("Assistant message")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)

                Text("I found the settings path and kept the global preference device-local.")
                    .font(messagePreviewFont)
                    .foregroundStyle(.themeFg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.themeBgHighlight.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var messagePreviewFont: Font {
        let pointSize = FontPreferences.messagePointSize(
            baseSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            messageTextScale: messageTextScale
        )
        guard useMonoMessages else { return .system(size: pointSize) }
        return previewFont(size: pointSize, uiWeight: .regular)
    }

    private func previewFont(size: CGFloat, uiWeight: UIFont.Weight) -> Font {
        if let postScriptName = codeFont.postScriptName(weight: uiWeight) {
            return .custom(postScriptName, size: size)
        }
        return .system(size: size, design: .monospaced)
    }
}
