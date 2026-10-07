import SwiftUI

struct SettingsPrivacyPage: View {
    @State private var biometricEnabled = BiometricService.shared.isEnabled
    @State private var telemetryEnabled = AppPreferences.Telemetry.isEnabled

    var body: some View {
        let bio = BiometricService.shared

        List {
            Section {
                Toggle("Require \(bio.biometricName)", isOn: $biometricEnabled)
                    .onChange(of: biometricEnabled) { _, newValue in
                        bio.isEnabled = newValue
                    }
            } footer: {
                Text(
                    biometricEnabled
                        ? "Sensitive local actions require \(bio.biometricName)."
                        : "Sensitive local actions skip device authentication."
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
    }
}
