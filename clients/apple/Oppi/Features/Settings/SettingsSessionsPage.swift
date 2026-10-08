import SwiftUI

struct SettingsSessionsPage: View {
    @State private var autoTitleProvider = AppPreferences.Session.autoTitleProvider
    @State private var rowDensity = AppPreferences.SessionRows.display.density
    @AppStorage(AppPreferences.SessionRows.leadingSwipeActionKey)
    private var leadingSwipeAction: SessionLeadingSwipeAction = .defaultValue

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

            Section {
                Picker("Swipe Right", selection: $leadingSwipeAction) {
                    ForEach(SessionLeadingSwipeAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.sessions.leadingSwipe")
            } header: {
                Text("Swipe Actions")
            } footer: {
                Text(swipeFooter)
            }
        }
        .settingsPage("Sessions")
        .onAppear {
            // Refresh summaries when returning from the pushed pages.
            autoTitleProvider = AppPreferences.Session.autoTitleProvider
            rowDensity = AppPreferences.SessionRows.display.density
        }
    }

    /// Footer for the current choice; swipe left is always lifecycle.
    private var swipeFooter: String {
        let right: String = switch leadingSwipeAction {
        case .none: "Swipe right on a session does nothing."
        case .lock: "Swipe right on a session to lock or unlock it."
        case .lifecycle: "Swipe right on a session to stop or resume it."
        }
        return right + " Swipe left to stop a session, or to resume or delete a stopped one."
    }

    private var autoTitleProviderLabel: String {
        switch autoTitleProvider {
        case .server: return "Server"
        case .onDevice: return "On-device"
        case .off: return "Off"
        }
    }
}
