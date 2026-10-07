import SwiftUI

struct SettingsGeneralPage: View {
    @State private var hapticFeedbackEnabled = AppPreferences.Interaction.isHapticFeedbackEnabled
    @State private var screenAwakePreset = AppPreferences.ScreenAwake.timeoutPreset
    @State private var linkOpeningMode = AppPreferences.Browser.linkOpeningMode

    var body: some View {
        List {
            Section {
                Toggle("Haptic Feedback", isOn: $hapticFeedbackEnabled)
                    .onChange(of: hapticFeedbackEnabled) { _, newValue in
                        AppPreferences.Interaction.setHapticFeedbackEnabled(newValue)
                    }
            } footer: {
                Text("Adds short taps for optional in-app interactions like toolbar expansion, copy, selection, and long-press thresholds. Oppi also respects iOS System Haptics.")
            }

            Section {
                Picker("Keep Screen Awake", selection: $screenAwakePreset) {
                    ForEach(AppPreferences.ScreenAwake.TimeoutPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .onChange(of: screenAwakePreset) { _, newValue in
                    AppPreferences.ScreenAwake.setTimeoutPreset(newValue)
                    ScreenAwakeController.shared.refreshFromPreferences()
                }
            } footer: {
                Text(screenAwakeDetail)
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
            } footer: {
                Text(linkOpeningMode.detail)
            }
        }
        .settingsPage("General")
    }

    private var screenAwakeDetail: String {
        switch screenAwakePreset {
        case .off:
            return "Keeps the screen on while voice input is active or the agent is working."
        default:
            return "Keeps the screen on while active, plus \(screenAwakePreset.label) after activity ends."
        }
    }
}
