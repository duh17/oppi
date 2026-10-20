import SwiftUI

struct SettingsSessionsPage: View {
    @State private var autoTitleProvider = AppPreferences.Session.autoTitleProvider
    @State private var rowDensity = AppPreferences.SessionRows.display.density
    @Environment(\.screenNavigator) private var navigator
    @Environment(\.appRootEnvironment) private var root

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
                    guard let root else {
                        return assertionFailure("Session Rows needs the app root above Sessions")
                    }
                    navigator.push(SessionRowDisplayEditorViewController(root: root))
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
