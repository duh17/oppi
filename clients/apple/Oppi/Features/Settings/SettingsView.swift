import SwiftUI

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themeStore

    @State private var spinnerStyle = AppPreferences.Appearance.spinnerStyle
    @State private var assistantAvatar = AssistantAvatar.current
    @State private var showAvatarPicker = false
    @State private var biometricEnabled = BiometricService.shared.isEnabled
    @State private var autoTitleProvider = AppPreferences.Session.autoTitleProvider
    @State private var screenAwakePreset = ScreenAwakePreferences.timeoutPreset
    @State private var cacheSizeText: String?
    @State private var selectedCodeFont = FontPreferences.codeFont
    @State private var useMonoMessages = FontPreferences.useMonoForMessages

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
