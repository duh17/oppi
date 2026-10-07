import SwiftUI
import UIKit

struct SettingsPrivacyPage: View {
    @State private var confirmNewServers = BiometricService.shared.isEnabled
    @State private var telemetryEnabled = AppPreferences.Telemetry.isEnabled
    @State private var appLock = AppLockService.shared

    var body: some View {
        List {
            Section {
                Picker("App Lock", selection: appLockSelection) {
                    ForEach(AppLockTimeout.allCases) { timeout in
                        Text(timeout.title).tag(timeout)
                    }
                }
                .disabled(!appLock.isAvailable || appLock.isAuthenticating)
                .accessibilityIdentifier("settings.appLock")
            } footer: {
                Text(appLockFooter)
            }

            Section {
                Toggle("Confirm New Servers", isOn: confirmNewServersSelection)
                    .disabled(appLock.isAuthenticating)
                    .accessibilityIdentifier("settings.confirmNewServers")
            } footer: {
                Text(
                    confirmNewServers
                        ? "Asks for \(authenticationPhrase) before Oppi trusts a new server or a server whose identity changed."
                        : "New and changed servers are trusted without device authentication."
                )
            }

            Section {
                Toggle("Send Diagnostics", isOn: $telemetryEnabled)
                    .onChange(of: telemetryEnabled) { _, newValue in
                        AppPreferences.Telemetry.setEnabled(newValue)
                        MetricKitService.shared.refreshAfterPreferenceChange()
                        DeviceResourceSampler.shared.refreshAfterPreferenceChange()
                    }
            } footer: {
                Text(
                    telemetryEnabled
                        ? "Diagnostics are sent only to your server."
                        : "Diagnostics uploads are off."
                )
            }

            Section {
                Link(destination: AppSupportLinks.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .environment(\.openURL, OpenURLAction { _ in
                    AppSupportLinks.open(AppSupportLinks.privacyPolicyURL)
                    return .handled
                })
                .accessibilityIdentifier("settings.privacyPolicy")
                .accessibilityHint("Opens Oppi's public Privacy Policy")

                Link(destination: AppSupportLinks.supportURL) {
                    Label("Support & Contact", systemImage: "questionmark.circle")
                }
                .environment(\.openURL, OpenURLAction { _ in
                    AppSupportLinks.open(AppSupportLinks.supportURL)
                    return .handled
                })
                .accessibilityIdentifier("settings.supportContact")
                .accessibilityHint("Opens Oppi's public support and contact page")
            } footer: {
                Text("These pages explain where Oppi data goes and how to report a problem. Links open using your Open Links setting.")
            }
        }
        .settingsPage("Privacy & Security")
        .onAppear { appLock.refreshAvailability() }
    }

    // MARK: - App Lock

    /// Shows Off while the device has no passcode. Changing or turning off an
    /// active App Lock asks for device authentication first, so someone
    /// holding the unlocked app cannot quietly disable it.
    private var appLockSelection: Binding<AppLockTimeout> {
        Binding(
            get: { appLock.isAvailable ? appLock.timeout : .off },
            set: { newValue in
                guard newValue != appLock.timeout else { return }
                // Turning App Lock on is always allowed.
                guard appLock.isEnabled else {
                    appLock.setTimeout(newValue)
                    return
                }
                Task {
                    if await appLock.authorizeProtectedAction(reason: String(localized: "Change App Lock")) {
                        appLock.setTimeout(newValue)
                    }
                }
            }
        )
    }

    /// Turning Confirm New Servers off while App Lock is on asks first.
    private var confirmNewServersSelection: Binding<Bool> {
        Binding(
            get: { confirmNewServers },
            set: { newValue in
                guard !newValue, appLock.isEnabled else {
                    applyConfirmNewServers(newValue)
                    return
                }
                Task {
                    if await appLock.authorizeProtectedAction(
                        reason: String(localized: "Turn off Confirm New Servers")
                    ) {
                        applyConfirmNewServers(newValue)
                    }
                }
            }
        )
    }

    private func applyConfirmNewServers(_ enabled: Bool) {
        confirmNewServers = enabled
        BiometricService.shared.isEnabled = enabled
    }

    private var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private var authenticationPhrase: String {
        appLock.method == .passcode
            ? "your \(deviceName) passcode"
            : "\(appLock.method.name) or your \(deviceName) passcode"
    }

    private var appLockFooter: String {
        guard appLock.isAvailable else {
            return "Set a passcode on this \(deviceName) to use App Lock."
        }
        let scope = "It does not protect data on your servers or other paired devices."
        let when: String
        switch appLock.timeout {
        case .off:
            return "Oppi opens without asking. App Lock guards Oppi from someone holding your unlocked \(deviceName). \(scope)"
        case .immediately:
            when = "every time you return"
        case .oneMinute:
            when = "after 1 minute away"
        case .fiveMinutes:
            when = "after 5 minutes away"
        case .fifteenMinutes:
            when = "after 15 minutes away"
        }
        let unlock = appLock.method == .passcode
            ? "Oppi asks for your \(deviceName) passcode \(when), never while it is open."
            : "Oppi asks for \(appLock.method.name) \(when), never while it is open. Your \(deviceName) passcode also unlocks it."
        let share = appLock.method == .passcode ? "your passcode" : appLock.method.name
        return "\(unlock) While App Lock is on, Oppi's own notifications and Live Activities never show session text, and Share asks for \(share) each time. \(scope)"
    }
}
