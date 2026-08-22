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
    @State private var hapticFeedbackEnabled = AppPreferences.Interaction.isHapticFeedbackEnabled
    @State private var quietModeEnabled = AppPreferences.ChatDisplay.isCompactTurnsEnabled
    @State private var workStripStyle = AppPreferences.ChatDisplay.workStripStyle

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

                if UIDevice.current.userInterfaceIdiom == .phone {
                    Toggle("Compact turns", isOn: $quietModeEnabled)
                        .onChange(of: quietModeEnabled) { _, newValue in
                            AppPreferences.ChatDisplay.setCompactTurnsEnabled(newValue)
                        }
                        .accessibilityIdentifier("settings.compactTurns")

                    if quietModeEnabled {
                        Picker("Work strip", selection: $workStripStyle) {
                            ForEach(AppPreferences.ChatDisplay.WorkStripStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: workStripStyle) { _, newValue in
                            AppPreferences.ChatDisplay.setWorkStripStyle(newValue)
                        }
                        .accessibilityIdentifier("settings.workStripStyle")

                        WorkStripPreviewCard(style: workStripStyle)
                    }

                    Text("Collapse successful and failed tool work between messages. Thinking still folds, while messages, asks, system events, cache misses, and audio stay visible.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }
            } header: {
                Text("Chat Display")
            } footer: {
                Text("Controls how chat activity appears on this device.")
            }

            Section {
                Toggle("Haptic Feedback", isOn: $hapticFeedbackEnabled)
                    .onChange(of: hapticFeedbackEnabled) { _, newValue in
                        AppPreferences.Interaction.setHapticFeedbackEnabled(newValue)
                    }
            } header: {
                Text("Interaction")
            } footer: {
                Text("Adds short taps for optional in-app interactions like toolbar expansion, copy, selection, and long-press thresholds. Oppi also respects iOS System Haptics.")
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
            } header: {
                Text("Text Selection")
            } footer: {
                Text("Edit the quick comments shown after selecting text and choosing Comment.")
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
                    "Voice replies can stay manual or follow each reply's playback behavior. "
                        + "Session-specific changes still happen in chat. "
                        + "Server dictation sends audio to the speech-to-text service configured on your paired server; on-device dictation uses Apple's local dictation."
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

            documentationSection

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
        .onReceive(NotificationCenter.default.publisher(for: AppPreferences.ChatDisplay.didChangeNotification)) { _ in
            quietModeEnabled = AppPreferences.ChatDisplay.isCompactTurnsEnabled
            workStripStyle = AppPreferences.ChatDisplay.workStripStyle
        }
        .onAppear {
            // Refresh provider label when returning from AutoTitleSettingsView
            autoTitleProvider = AppPreferences.Session.autoTitleProvider
            selectedCodeTextScale = FontPreferences.codeTextScale
            selectedMessageTextScale = FontPreferences.messageTextScale
            quietModeEnabled = AppPreferences.ChatDisplay.isCompactTurnsEnabled
            workStripStyle = AppPreferences.ChatDisplay.workStripStyle
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
        case .officialPi, .piText, .golGrid:
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
        let diagnosticsText = telemetryEnabled
            ? "Diagnostics are sent only to your server."
            : "Diagnostics uploads are off."
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

            Toggle("Send Diagnostics to Server", isOn: $telemetryEnabled)
                .onChange(of: telemetryEnabled) { _, newValue in
                    AppPreferences.Telemetry.setEnabled(newValue)
                    MetricKitService.shared.refreshAfterPreferenceChange()
                    DeviceResourceSampler.shared.refreshAfterPreferenceChange()
                }
        } header: {
            Text("Privacy & Security")
        } footer: {
            Text(privacySecurityFooter)
        }
    }

    @ViewBuilder
    private var documentationSection: some View {
        Section {
            Link(destination: AppSupportLinks.privacyPolicyURL) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            .environment(\.openURL, OpenURLAction { _ in
                AppSupportLinks.open(AppSupportLinks.privacyPolicyURL)
                return .handled
            })
            .accessibilityIdentifier("settings.privacyPolicy")
            .accessibilityHint("Opens Oppi's public Privacy Policy")

            Link(destination: AppSupportLinks.supportURL) {
                Label("Support & Contact", systemImage: "questionmark.circle")
            }
            .environment(\.openURL, OpenURLAction { _ in
                AppSupportLinks.open(AppSupportLinks.supportURL)
                return .handled
            })
            .accessibilityIdentifier("settings.supportContact")
            .accessibilityHint("Opens Oppi's public support and contact page")
        } header: {
            Text("Help & Privacy")
        } footer: {
            Text("These pages explain where Oppi data goes and how to report a problem. Links open using your Open Links setting.")
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

struct WorkStripPreviewCard: View {
    let style: AppPreferences.ChatDisplay.WorkStripStyle

    static let sampleWorkLine = QuietTimelineWorkLine(
        id: "settings-work-strip-preview",
        turnID: "settings-work-strip-preview",
        sourceItemIDs: [],
        buckets: [
            .init(kind: .read, count: 4),
            .init(kind: .tooling, count: 7),
            .init(kind: .write, count: 1),
            .init(kind: .edit, count: 1, editStats: .init(added: 12, removed: 3)),
        ],
        displayStyle: .icons,
        isExpanded: false,
        isLive: true,
        liveStartedAt: Date(timeIntervalSince1970: 0)
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live Preview", systemImage: "rectangle.compress.vertical")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFgDim)

            Group {
                switch style {
                case .icons:
                    HStack(spacing: 12) {
                        ForEach(Array(Self.sampleWorkLine.buckets.enumerated()), id: \.offset) { _, bucket in
                            HStack(spacing: 4) {
                                Image(systemName: bucket.kind.symbolName)
                                if bucket.kind == .edit, let stats = bucket.editStats {
                                    Text("+\(stats.added)")
                                        .foregroundStyle(.themeGreen)
                                    Text("−\(stats.removed)")
                                        .foregroundStyle(.themeRed)
                                } else {
                                    Text("\(bucket.count)")
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        Text("· 7s")
                    }
                case .words:
                    wordsPreview
                }
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.themeBlue)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(.themeBlue.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.themeBlue.opacity(0.45), lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.sampleWorkLine.wordsSummary(now: Date(timeIntervalSince1970: 7)))
        }
        .padding(.vertical, 4)
    }

    private var wordsPreview: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.sampleWorkLine.buckets.enumerated()), id: \.offset) { index, bucket in
                if index > 0 {
                    Text("  ")
                }
                if bucket.kind == .edit, let stats = bucket.editStats {
                    Text("edit ")
                    Text("+\(stats.added)")
                        .foregroundStyle(.themeGreen)
                    Text(" −\(stats.removed)")
                        .foregroundStyle(.themeRed)
                } else {
                    Text(bucket.words)
                }
            }
        }
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
