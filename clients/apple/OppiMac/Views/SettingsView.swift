import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The middle-column index for app preferences and host administration tools.
struct MacSettingsList: View {
    @Binding var selection: MacSettingsPane

    var body: some View {
        List(selection: $selection) {
            Section("Oppi") {
                settingsRow(.app)
            }

            Section("Host Tools") {
                ForEach(MacSettingsPane.hostToolPanes) { pane in
                    settingsRow(pane)
                }
            }
        }
        .navigationTitle("App Settings")
    }

    private func settingsRow(_ pane: MacSettingsPane) -> some View {
        Label(pane.title, systemImage: pane.icon)
            .tag(pane)
    }
}

/// Routes a selected Settings pane to the existing host-tool view.
struct SettingsView: View {
    let pane: MacSettingsPane
    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let permissionState: TCCPermissionState
    let sessionMonitor: MacSessionMonitor
    let remoteServerStore: MacRemoteServerStore
    let checkForUpdates: @MainActor () -> Void

    var body: some View {
        switch pane {
        case .app:
            AppSettingsView(checkForUpdates: checkForUpdates)
        case .pairing:
            PairView()
        case .permissions:
            PermissionsView(permissionState: permissionState)
        case .localServer:
            StatusView(
                processManager: processManager,
                healthMonitor: healthMonitor,
                sessionMonitor: sessionMonitor
            )
        case .stats:
            StatsTabView(
                monitor: sessionMonitor,
                healthMonitor: healthMonitor
            )
            .navigationTitle("Stats")
        case .remoteServers:
            RemoteServersDetail(
                processManager: processManager,
                healthMonitor: healthMonitor,
                store: remoteServerStore
            )
        case .logs:
            LogsView(processManager: processManager)
        case .doctor:
            DoctorView()
        }
    }
}

/// Titles for Mac Settings controls that persist through OppiCore keys.
enum MacAppSettingsPreferenceControl: String, CaseIterable, Identifiable {
    case assistantAvatar
    case spinnerStyle
    case keybindings
    case codeFont
    case codeTextSize
    case messageTextSize
    case monoMessages
    case autoTitle
    case keepScreenAwake
    case dictationEngine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistantAvatar: return "Assistant Avatar"
        case .spinnerStyle: return "Spinner Style"
        case .keybindings: return "Keybindings"
        case .codeFont: return "Code Font"
        case .codeTextSize: return "Code Text Size"
        case .messageTextSize: return "Message Text Size"
        case .monoMessages: return "Monospaced messages"
        case .autoTitle: return "Auto-name Sessions"
        case .keepScreenAwake: return "Keep screen awake"
        case .dictationEngine: return "Dictation Engine"
        }
    }

    var accessibilityIdentifier: String {
        "mac.settings.\(rawValue)"
    }
}

/// Built-in plus emoji avatar kinds. Mac does not offer Genmoji.
enum MacAssistantAvatarKind: String, CaseIterable, Identifiable {
    case officialPi
    case piText
    case golGrid
    case emoji

    var id: String { rawValue }

    var title: String {
        switch self {
        case .officialPi: return AssistantAvatarPreference.officialPi.displayName
        case .piText: return AssistantAvatarPreference.piText.displayName
        case .golGrid: return AssistantAvatarPreference.golGrid.displayName
        case .emoji: return "Emoji"
        }
    }

    init(avatar: AssistantAvatarPreference) {
        switch avatar {
        case .officialPi: self = .officialPi
        case .piText: self = .piText
        case .golGrid: self = .golGrid
        case .emoji: self = .emoji
        }
    }

    static func emojiDraft(for avatar: AssistantAvatarPreference) -> String {
        if case .emoji(let value) = avatar {
            return value
        }
        return ""
    }
}

/// General app preferences, runtime paths, and update controls.
///
/// Keep-screen-awake uses `MacScreenAwakeController` (`ProcessInfo`), not UIKit.
/// Clear Local Cache deletes leftover pasted-attachment temps. TimelineCache is
/// not linked on Mac, so that iOS cache is not invented here.
private struct AppSettingsView: View {
    let checkForUpdates: @MainActor () -> Void

    @Environment(ThemeStore.self) private var themeStore
    @State private var selectedCodeFont = FontPreferenceStore.codeFont
    @State private var selectedCodeTextScale = FontPreferenceStore.codeTextScale
    @State private var selectedMessageTextScale = FontPreferenceStore.messageTextScale
    @State private var useMonoMessages = FontPreferenceStore.useMonoForMessages
    @State private var selectedSpinnerStyle = SpinnerStyle.current
    @State private var selectedKeybindingMode = KeybindingPreferenceStore().mode
    @State private var selectedAvatar = AssistantAvatarPreference.current
    @State private var avatarKind = MacAssistantAvatarKind(avatar: AssistantAvatarPreference.current)
    @State private var emojiDraft = MacAssistantAvatarKind.emojiDraft(
        for: AssistantAvatarPreference.current
    )
    @State private var avatarError: String?
    @State private var launchAtLogin = false
    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var importedThemeNames: [String] = CustomThemeStore.names()
    @State private var hostThemes: [MacAppSettingsThemeImport.HostTheme] = []
    @State private var importError: String?
    @State private var screenAwakePreset = AppPreferenceStore.ScreenAwake.timeoutPreset
    @State private var cacheSizeText: String?

    var body: some View {
        Form {
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
                    .foregroundStyle(.secondary)

                if themeStore.mode == .manual {
                    themePicker(
                        "Theme",
                        selection: Binding(
                            get: { themeStore.manualThemeID },
                            set: { themeStore.manualThemeID = $0 }
                        ),
                        matching: nil
                    )

                    if !themeStore.manualThemeID.detail.isEmpty {
                        Text(themeStore.manualThemeID.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    themePicker(
                        "Light Theme",
                        selection: Binding(
                            get: { themeStore.lightThemeID },
                            set: { themeStore.lightThemeID = $0 }
                        ),
                        matching: .light
                    )

                    themePicker(
                        "Dark Theme",
                        selection: Binding(
                            get: { themeStore.darkThemeID },
                            set: { themeStore.darkThemeID = $0 }
                        ),
                        matching: .dark
                    )

                    Text("Uses your macOS Appearance setting, including automatic schedule.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker(
                    MacAppSettingsPreferenceControl.assistantAvatar.title,
                    selection: $avatarKind
                ) {
                    ForEach(MacAssistantAvatarKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .onChange(of: avatarKind) { _, newValue in
                    commitAvatarKind(newValue)
                }
                .accessibilityIdentifier(
                    MacAppSettingsPreferenceControl.assistantAvatar.accessibilityIdentifier
                )

                if avatarKind == .emoji {
                    TextField("Emoji", text: $emojiDraft)
                        .onChange(of: emojiDraft) { _, newValue in
                            commitEmojiDraft(newValue)
                        }
                        .accessibilityIdentifier("mac.settings.assistantAvatarEmoji")
                }

                LabeledContent("Avatar Preview") {
                    MacAssistantAvatarView(
                        avatar: selectedAvatar,
                        sessionId: "settings-avatar-preview",
                        size: 22
                    )
                }

                if let avatarError {
                    Text(avatarError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Picker(
                    MacAppSettingsPreferenceControl.spinnerStyle.title,
                    selection: $selectedSpinnerStyle
                ) {
                    ForEach(SpinnerStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: selectedSpinnerStyle) { _, newValue in
                    AppPreferenceStore.Appearance.setSpinnerStyle(newValue)
                }
                .accessibilityIdentifier(
                    MacAppSettingsPreferenceControl.spinnerStyle.accessibilityIdentifier
                )

                LabeledContent("Spinner Preview") {
                    MacWorkingSpinnerView(
                        tint: Color.themeFg,
                        style: selectedSpinnerStyle
                    )
                    .frame(width: 20, height: 20)
                    .id(selectedSpinnerStyle)
                }

                Picker(
                    MacAppSettingsPreferenceControl.keybindings.title,
                    selection: $selectedKeybindingMode
                ) {
                    ForEach(KeybindingMode.allCases, id: \.rawValue) { mode in
                        Text(mode == .macDefault ? "Mac Default" : "Vim")
                            .tag(mode)
                    }
                }
                .onChange(of: selectedKeybindingMode) { _, newValue in
                    KeybindingPreferenceStore().mode = newValue
                }
                .accessibilityIdentifier(
                    MacAppSettingsPreferenceControl.keybindings.accessibilityIdentifier
                )
            } header: {
                Text("Chat Display")
            } footer: {
                Text("Controls how chat activity appears on this Mac.")
            }

            Section {
                Picker(MacAppSettingsPreferenceControl.codeFont.title, selection: $selectedCodeFont) {
                    ForEach(FontPreferenceStore.CodeFontFamily.allCases) { family in
                        Text(family.displayName)
                            .tag(family)
                    }
                }
                .onChange(of: selectedCodeFont) { _, newValue in
                    FontPreferenceStore.setCodeFont(newValue)
                }
                .accessibilityIdentifier(MacAppSettingsPreferenceControl.codeFont.accessibilityIdentifier)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(MacAppSettingsPreferenceControl.codeTextSize.title)
                        Spacer()
                        Text("\(Int(round(selectedCodeTextScale * 100)))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $selectedCodeTextScale,
                        in: FontPreferenceStore.minimumCodeTextScale...FontPreferenceStore.maximumCodeTextScale,
                        step: 0.05
                    ) {
                        Text(MacAppSettingsPreferenceControl.codeTextSize.title)
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .accessibilityIdentifier(MacAppSettingsPreferenceControl.codeTextSize.accessibilityIdentifier)
                    .accessibilityValue("\(Int(round(selectedCodeTextScale * 100))) percent")

                    Text("Code blocks, diffs, terminals, and tool output.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: selectedCodeTextScale) { _, newValue in
                    FontPreferenceStore.setCodeTextScale(newValue)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(MacAppSettingsPreferenceControl.messageTextSize.title)
                        Spacer()
                        Text("\(Int(round(selectedMessageTextScale * 100)))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $selectedMessageTextScale,
                        in: FontPreferenceStore.minimumMessageTextScale...FontPreferenceStore.maximumMessageTextScale,
                        step: 0.05
                    ) {
                        Text(MacAppSettingsPreferenceControl.messageTextSize.title)
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .accessibilityIdentifier(MacAppSettingsPreferenceControl.messageTextSize.accessibilityIdentifier)
                    .accessibilityValue("\(Int(round(selectedMessageTextScale * 100))) percent")

                    Text("Assistant and user chat messages.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: selectedMessageTextScale) { _, newValue in
                    FontPreferenceStore.setMessageTextScale(newValue)
                }

                Toggle(MacAppSettingsPreferenceControl.monoMessages.title, isOn: $useMonoMessages)
                    .onChange(of: useMonoMessages) { _, newValue in
                        FontPreferenceStore.setUseMonoForMessages(newValue)
                    }
                    .accessibilityIdentifier(MacAppSettingsPreferenceControl.monoMessages.accessibilityIdentifier)
            } header: {
                Text("Text")
            } footer: {
                Text("Text settings are saved on this device.")
            }

            Section {
                LabeledContent(MacAppSettingsPreferenceControl.autoTitle.title) {
                    Text(AppPreferenceStore.Session.AutoTitleProvider.server.label)
                }
                .accessibilityIdentifier(MacAppSettingsPreferenceControl.autoTitle.accessibilityIdentifier)

                Picker(
                    MacAppSettingsPreferenceControl.keepScreenAwake.title,
                    selection: $screenAwakePreset
                ) {
                    ForEach(AppPreferenceStore.ScreenAwake.TimeoutPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .onChange(of: screenAwakePreset) { _, newValue in
                    AppPreferenceStore.ScreenAwake.setTimeoutPreset(newValue)
                    MacScreenAwakeController.shared.refreshFromPreferences()
                }
                .accessibilityIdentifier(
                    MacAppSettingsPreferenceControl.keepScreenAwake.accessibilityIdentifier
                )

                Text(screenAwakeDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Sessions")
            } footer: {
                Text(
                    "Saved on this Mac. This app does not auto-name sessions, and it does not apply Off or on-device titles."
                )
            }

            Section {
                LabeledContent(MacAppSettingsPreferenceControl.dictationEngine.title) {
                    Text(AppPreferenceStore.Voice.EngineMode.remote.label)
                }
                .accessibilityIdentifier(MacAppSettingsPreferenceControl.dictationEngine.accessibilityIdentifier)
            } header: {
                Text("Voice")
            } footer: {
                Text(
                    "Mac dictation sends audio to the speech-to-text service on your Oppi server. On-device dictation is not available in this app."
                )
            }

            Section {
                if let cacheSizeText {
                    LabeledContent("Local Cache", value: cacheSizeText)
                }
                Button("Clear Local Cache") {
                    MacPastedAttachmentFileStore.clearAll()
                    cacheSizeText = MacPastedAttachmentFileStore.formattedDiskSize()
                }
                .accessibilityIdentifier("mac.settings.clearLocalCache")
            } header: {
                Text("Storage")
            } footer: {
                Text(
                    "Removes leftover pasted images stored on this Mac. This app does not keep a timeline cache."
                )
            }

            Section("Imported Themes") {
                if importedThemeNames.isEmpty && hostThemes.isEmpty {
                    Text("Import an Oppi theme JSON file, or a theme saved on this Mac.")
                        .foregroundStyle(.secondary)
                }

                ForEach(fileOnlyImportedNames, id: \.self) { name in
                    LabeledContent(name) {
                        Button("Remove", role: .destructive) {
                            removeImportedTheme(named: name)
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("mac.settings.removeImportedTheme")
                    }
                }

                ForEach(hostThemes) { theme in
                    LabeledContent {
                        if importedThemeNames.contains(theme.name) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Imported")
                                Button("Remove", role: .destructive) {
                                    removeImportedTheme(named: theme.name)
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Button("Import") {
                                importTheme(from: theme.url)
                            }
                            .controlSize(.small)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.name)
                            Text(theme.colorScheme)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button("Import Theme…") {
                    importThemeFromFile()
                }
                .accessibilityIdentifier("mac.settings.importTheme")

                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Launch") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                if loginItemStatus == .requiresApproval {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Requires approval in System Settings > Login Items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Open Login Items Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Section("Server") {
                if let cliPath = ServerProcessManager.resolveServerCLIPath() {
                    LabeledContent("CLI Path") {
                        Text(cliPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    LabeledContent("CLI Path") {
                        Text("Not found")
                            .foregroundStyle(.secondary)
                    }
                }

                if let runtimePath = ServerProcessManager.resolveRuntimePath() {
                    LabeledContent("Node.js") {
                        Text(runtimePath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Server Updates") {
                Text("The Oppi server and CLI are installed together with npm.")
                    .foregroundStyle(.secondary)
                Text("npm install -g oppi-server@latest")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("App Updates") {
                Button("Check for Updates...") {
                    checkForUpdates()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .task {
            refreshLoginItemStatus()
            refreshImportedThemes()
            refreshPersistedPreferences()
            cacheSizeText = MacPastedAttachmentFileStore.formattedDiskSize()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshLoginItemStatus()
        }
    }

    @ViewBuilder
    private func themePicker(
        _ title: String,
        selection: Binding<ThemeID>,
        matching scheme: ColorScheme?
    ) -> some View {
        let themes = ThemeID.pickerThemes(matching: scheme)
        let builtins = themes.filter { !$0.isImported }
        let imported = themes.filter(\.isImported)
        Picker(title, selection: selection) {
            Section("Built-in") {
                ForEach(builtins, id: \.self) { themeID in
                    Text(themeID.displayName).tag(themeID)
                }
            }
            if !imported.isEmpty {
                Section("Imported") {
                    ForEach(imported, id: \.self) { themeID in
                        Text(themeID.displayName).tag(themeID)
                    }
                }
            }
        }
        .id(importedThemeNames)
    }

    private var fileOnlyImportedNames: [String] {
        let hostNames = Set(hostThemes.map(\.name))
        return importedThemeNames.filter { !hostNames.contains($0) }
    }

    private func refreshPersistedPreferences() {
        selectedCodeFont = FontPreferenceStore.codeFont
        selectedCodeTextScale = FontPreferenceStore.codeTextScale
        selectedMessageTextScale = FontPreferenceStore.messageTextScale
        useMonoMessages = FontPreferenceStore.useMonoForMessages
        selectedSpinnerStyle = SpinnerStyle.current
        selectedKeybindingMode = KeybindingPreferenceStore().mode
        selectedAvatar = AssistantAvatarPreference.current
        avatarKind = MacAssistantAvatarKind(avatar: selectedAvatar)
        emojiDraft = MacAssistantAvatarKind.emojiDraft(for: selectedAvatar)
        avatarError = nil
        screenAwakePreset = AppPreferenceStore.ScreenAwake.timeoutPreset
    }

    private var screenAwakeDetail: String {
        switch screenAwakePreset {
        case .off:
            return "Keeps the display on while a session is working."
        default:
            return "Keeps the display on while a session is working, plus \(screenAwakePreset.label) after work ends."
        }
    }

    private func commitAvatarKind(_ kind: MacAssistantAvatarKind) {
        switch kind {
        case .officialPi:
            persistAvatar(.officialPi)
        case .piText:
            persistAvatar(.piText)
        case .golGrid:
            persistAvatar(.golGrid)
        case .emoji:
            commitEmojiDraft(emojiDraft)
        }
    }

    private func commitEmojiDraft(_ rawValue: String) {
        guard avatarKind == .emoji else { return }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            avatarError = nil
            return
        }
        persistAvatar(.emoji(trimmed))
    }

    private func persistAvatar(_ avatar: AssistantAvatarPreference) {
        do {
            selectedAvatar = try AssistantAvatarPreference.setCurrent(avatar)
            avatarError = nil
            if case .emoji(let emoji) = selectedAvatar {
                emojiDraft = emoji
            }
        } catch {
            avatarError = error.localizedDescription
        }
    }

    private func refreshImportedThemes() {
        importedThemeNames = CustomThemeStore.names()
        hostThemes = MacAppSettingsThemeImport.hostThemes(
            dataDir: ServerProcessManager.serverDataDir
        )
    }

    private func removeImportedTheme(named name: String) {
        themeStore.removeImportedTheme(named: name)
        importError = nil
        refreshImportedThemes()
    }

    private func importThemeFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose an Oppi theme JSON file"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                importTheme(from: url)
            }
        }
    }

    private func importTheme(from url: URL) {
        do {
            let theme = try MacAppSettingsThemeImport.loadTheme(from: url)
            CustomThemeStore.save(theme)
            themeStore.selectedThemeID = .custom(theme.name)
            importError = nil
            refreshImportedThemes()
        } catch {
            importError = error.localizedDescription
        }
    }

    private func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
        launchAtLogin = loginItemStatus == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Refresh below to reflect the actual registration state.
        }
        refreshLoginItemStatus()
    }
}

/// Decode Oppi theme JSON with APIs already linked on Mac.
enum MacAppSettingsThemeImport {
    enum DecodeError: Error, LocalizedError {
        case unrecognized
        case invalidPalette

        var errorDescription: String? {
            switch self {
            case .unrecognized:
                return "This file is not an Oppi theme."
            case .invalidPalette:
                return "This theme is missing required colors."
            }
        }
    }

    struct HostTheme: Identifiable, Equatable, Sendable {
        let name: String
        let filename: String
        let colorScheme: String
        let url: URL

        var id: String { filename }
    }

    static func decodeTheme(from data: Data) throws -> RemoteTheme {
        let decoder = JSONDecoder()
        if let theme = try? decoder.decode(RemoteTheme.self, from: data) {
            try validatePalette(theme)
            return theme
        }
        struct Wrapper: Decodable {
            let theme: RemoteTheme
        }
        if let wrapped = try? decoder.decode(Wrapper.self, from: data) {
            try validatePalette(wrapped.theme)
            return wrapped.theme
        }
        throw DecodeError.unrecognized
    }

    static func loadTheme(from url: URL) throws -> RemoteTheme {
        try decodeTheme(from: Data(contentsOf: url))
    }

    static func hostThemes(
        dataDir: String,
        fileManager: FileManager = .default
    ) -> [HostTheme] {
        let directory = URL(fileURLWithPath: dataDir, isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> HostTheme? in
                guard let theme = try? loadTheme(from: url) else { return nil }
                return HostTheme(
                    name: theme.name,
                    filename: url.deletingPathExtension().lastPathComponent,
                    colorScheme: theme.colorScheme ?? "dark",
                    url: url
                )
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private static func validatePalette(_ theme: RemoteTheme) throws {
        guard theme.toPalette() != nil else {
            throw DecodeError.invalidPalette
        }
    }
}
