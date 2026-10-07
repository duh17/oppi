import SwiftUI

struct SettingsExperimentsPage: View {
    @Environment(AppNavigation.self) private var navigation

    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var sshTerminalEnabled = false
    @AppStorage(AppPreferences.Experiments.durableSessionsKey) private var durableSessionsEnabled = false

    /// How many experiments are currently on, for the root row summary.
    @MainActor
    static func enabledCount(sessionThreadsEnabled: Bool) -> Int {
        [
            ReleaseFeatures.liveActivitiesEnabled && AppPreferences.LiveActivity.isEnabled,
            sessionThreadsEnabled,
            AppPreferences.Experiments.sshTerminalEnabled,
            AppPreferences.Experiments.durableSessionsEnabled,
        ].filter { $0 }.count
    }

    var body: some View {
        List {
            if ReleaseFeatures.liveActivitiesEnabled {
                Section {
                    Toggle("Live Activities", isOn: liveActivityToggle)
                }
            }

            Section {
                Toggle("Session Threads", isOn: Bindable(navigation).sessionThreadsEnabled)
                    .accessibilityIdentifier("settings.sessionThreads")
            } footer: {
                Text("Groups sessions under the session that launched them, with Thread strips and a Thread view.")
            }

            Section {
                Toggle("SSH Terminal", isOn: $sshTerminalEnabled)
                    .accessibilityIdentifier("settings.experiments.sshTerminal")
            } footer: {
                Text("Adds SSH Hosts to Settings.")
            }

            Section {
                Toggle("Durable Sessions", isOn: $durableSessionsEnabled)
                    .accessibilityIdentifier("settings.experiments.durableSessions")
            } footer: {
                Text("Adds a Durable list for starting and finding durable sessions on servers that offer them. Experiments are early builds with rough edges.")
            }
        }
        .settingsPage("Experiments")
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
}
