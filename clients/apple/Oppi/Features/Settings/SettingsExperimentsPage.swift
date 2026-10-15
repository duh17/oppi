import SwiftUI

struct SettingsExperimentsPage: View {
    @Environment(AppNavigation.self) private var navigation

    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var sshTerminalEnabled = false
    @AppStorage(AppPreferences.Experiments.durableSessionsKey) private var durableSessionsEnabled = false
    @AppStorage(AppPreferences.Experiments.durableSessionsDefaultKey) private var durableSessionsByDefault = false
    @AppStorage(AppPreferences.Experiments.desktopLiveViewKey) private var desktopLiveViewEnabled = false

    /// How many experiments are currently on, for the root row summary.
    @MainActor
    static func enabledCount(sessionThreadsEnabled: Bool) -> Int {
        [
            ReleaseFeatures.liveActivitiesEnabled && AppPreferences.LiveActivity.isEnabled,
            sessionThreadsEnabled,
            AppPreferences.Experiments.sshTerminalEnabled,
            AppPreferences.Experiments.durableSessionsEnabled,
            AppPreferences.Experiments.desktopLiveViewEnabled,
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
                if durableSessionsEnabled {
                    Toggle("Start Sessions as Durable", isOn: $durableSessionsByDefault)
                        .accessibilityIdentifier("settings.experiments.durableSessionsDefault")
                }
            } footer: {
                Text("On servers that offer durable sessions, the new-session composer shows a Classic / Durable switch. New sessions start Classic unless Start Sessions as Durable is on. Durable sessions are a development playground: they don't run your Pi extensions yet and don't match terminal coding agents feature for feature.")
            }

            Section {
                Toggle("Live Remote Screen", isOn: $desktopLiveViewEnabled)
                    .accessibilityIdentifier("settings.experiments.desktopLiveView")
            } footer: {
                Text("Shows a live view of a granted Mac window on iPhone when the server offers Live Remote Screen. Off hides Remote Screen. Frames are not saved.")
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
