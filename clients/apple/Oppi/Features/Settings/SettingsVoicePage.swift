import SwiftUI

struct SettingsVoicePage: View {
    @Environment(ConnectionCoordinator.self) private var coordinator

    @State private var voiceReplyMode = AppPreferences.Voice.replyMode
    @State private var voiceEngineMode = AppPreferences.Voice.engineMode
    @State private var dictationIndicatorStyle = AppPreferences.Appearance.dictationIndicatorStyle

    var body: some View {
        List {
            Section {
                Picker("Voice Replies", selection: $voiceReplyMode) {
                    ForEach(AppPreferences.Voice.ReplyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: voiceReplyMode) { _, newValue in
                    AppPreferences.Voice.setReplyMode(newValue)
                }
            } footer: {
                Text("\(voiceReplyMode.detail) Session-specific changes still happen in chat.")
            }

            Section {
                Picker("Dictation Engine", selection: $voiceEngineMode) {
                    ForEach(AppPreferences.Voice.supportedModes) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: voiceEngineMode) { _, newValue in
                    AppPreferences.Voice.setEngineMode(newValue)
                }
            } footer: {
                Text(engineDetail)
            }

            Section {
                Picker("Dictation Animation", selection: $dictationIndicatorStyle) {
                    ForEach(DictationIndicatorStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: dictationIndicatorStyle) { _, newValue in
                    AppPreferences.Appearance.setDictationIndicatorStyle(newValue)
                }
                .accessibilityIdentifier("settings.dictationIndicatorStyle")

                LabeledContent("Preview") {
                    MicButtonLabel(
                        isRecording: true,
                        isProcessing: false,
                        voiceSpectrum: .zero,
                        languageLabel: "EN",
                        accentColor: .themeBlue,
                        engineBadge: .onDevice,
                        diameter: ComposerInputMetrics.controlDiameter,
                        dictationStyle: dictationIndicatorStyle
                    )
                    .id(dictationIndicatorStyle)
                }
            } footer: {
                Text("Preview only — not microphone capture.")
            }

            // Edits the active server's list, the same one Server Settings opens.
            if coordinator.activeServerId != nil {
                Section {
                    NavigationLink("Dictionary") {
                        DictationDictionaryView(workspaceId: nil)
                    }
                    .accessibilityIdentifier("settings.dictationDictionary")
                } footer: {
                    Text("Names and terms that help dictation recognize what you say. Kept on your server.")
                }
            }
        }
        .settingsPage("Voice & Dictation")
    }

    private var engineDetail: String {
        switch voiceEngineMode {
        case .remote:
            return "Server dictation sends audio to the speech-to-text service configured on your paired server."
        case .onDevice:
            return "On-device dictation uses Apple's local dictation."
        case .auto:
            return "Server dictation sends audio to the speech-to-text service configured on your paired server; on-device dictation uses Apple's local dictation."
        }
    }
}
