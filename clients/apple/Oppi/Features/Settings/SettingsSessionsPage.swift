import SwiftUI

struct SettingsSessionsPage: View {
    @State private var autoTitleProvider = AppPreferences.Session.autoTitleProvider
    @State private var rowDensity = AppPreferences.SessionRows.display.density
    @Environment(\.screenNavigator) private var navigator

    var body: some View {
        List {
            Section {
                SettingsIndexActionRow(value: autoTitleProviderLabel) {
                    navigator.push { AutoTitleSettingsView() }
                } label: {
                    Text("Auto-Name")
                }
                .accessibilityLabel("Auto-Name")
                .accessibilityValue(autoTitleProviderLabel)
            }

            Section {
                SettingsIndexActionRow(value: rowDensity.label) {
                    navigator.push { SessionRowDisplayEditor() }
                } label: {
                    Text("Session Rows")
                }
                .accessibilityLabel("Session Rows")
                .accessibilityValue(rowDensity.label)
                .accessibilityIdentifier("settings.sessionRows")
            } footer: {
                Text("Choose the details shown on session rows in every session list.")
            }
        }
        .settingsPage("Sessions")
        .onAppear {
            // Refresh summaries when returning from the pushed pages.
            autoTitleProvider = AppPreferences.Session.autoTitleProvider
            rowDensity = AppPreferences.SessionRows.display.density
        }
    }

    private var autoTitleProviderLabel: String {
        switch autoTitleProvider {
        case .server: return "Server"
        case .onDevice: return "On-device"
        case .off: return "Off"
        }
    }
}
