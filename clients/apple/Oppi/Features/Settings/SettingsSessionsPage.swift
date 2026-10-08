import SwiftUI

struct SettingsSessionsPage: View {
    @State private var autoTitleProvider = AppPreferences.Session.autoTitleProvider
    @State private var rowDensity = AppPreferences.SessionRows.display.density

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AutoTitleSettingsView()
                } label: {
                    LabeledContent("Auto-Name") {
                        Text(autoTitleProviderLabel)
                            .foregroundStyle(.themeComment)
                    }
                }
            }

            Section {
                NavigationLink {
                    SessionRowDisplayEditor()
                } label: {
                    LabeledContent("Session Rows") {
                        Text(rowDensity.label)
                            .foregroundStyle(.themeComment)
                    }
                }
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
