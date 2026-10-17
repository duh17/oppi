import ActivityKit
import DeviceCheck
import SwiftUI

/// Server Settings → Notifications: this server's push alerts and Live Activity on this device.
///
/// Push is opt-in and shown only when the server pushes through a relay; turning it on first
/// says what the relay can and cannot see (protocol/push/spec.md §6). The Live Activity is
/// opt-in too and shows counts only. With push on, the server also keeps the card current
/// while Oppi is closed; without push the card updates only while Oppi is open.
struct ServerNotificationsSection: View {
    let serverId: String
    let connection: ServerConnection?

    @State private var pushEnabled = false
    @State private var liveActivityEnabled = false
    @State private var showDisclosure = false
    @State private var status: Status = .idle
    @State private var liveActivityStatus: Status = .idle

    enum Status: Equatable {
        case idle
        case working
        case failed
    }

    private var relayHost: String? {
        connection?.pushRelay?.host()
    }

    /// The relay registers App Store and TestFlight builds only when App Attest vouches for
    /// them; development builds and Simulator may register without it.
    private static var relayRefusesThisDevice: Bool {
        APNsEnvironment.current == .production && !DCAppAttestService.shared.isSupported
    }

    var body: some View {
        Section {
            if relayHost != nil {
                Toggle(isOn: Binding(
                    get: { pushEnabled },
                    set: { newValue in
                        if newValue {
                            showDisclosure = true
                        } else {
                            turnPushOff()
                        }
                    }
                )) {
                    SettingsRowLabel(String(localized: "Push Notifications"), systemImage: "bell.badge")
                }
                .disabled(status == .working || Self.relayRefusesThisDevice)
                .accessibilityIdentifier("server.push.enabled")
                if status == .working {
                    ProgressView()
                        .accessibilityIdentifier("server.push.working")
                }
                if status == .failed {
                    Text("Couldn't turn on push. Check that notifications are allowed for Oppi, then try again.")
                        .foregroundStyle(.themeOrange)
                        .accessibilityIdentifier("server.push.error")
                }
            }
            Toggle(isOn: Binding(
                get: { liveActivityEnabled },
                set: { setLiveActivity($0) }
            )) {
                SettingsRowLabel(String(localized: "Live Activities"), systemImage: "platter.filled.bottom.iphone")
            }
            .disabled(liveActivityStatus == .working)
            .accessibilityIdentifier("server.liveActivity.enabled")
            if liveActivityStatus == .working {
                ProgressView()
                    .accessibilityIdentifier("server.liveActivity.working")
            }
            if liveActivityStatus == .failed, liveActivityEnabled {
                Text("Couldn't let this server update the Live Activity while Oppi is closed. Oppi tries again when it reconnects.")
                    .foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("server.liveActivity.error")
            }
            if liveActivityEnabled, !ActivityAuthorizationInfo().areActivitiesEnabled {
                Text("Live Activities are off for Oppi in the Settings app.")
                    .foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("server.liveActivity.systemOff")
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(Self.footer(
                relayHost: relayHost,
                relayRefusesThisDevice: Self.relayRefusesThisDevice,
                pushEnabled: pushEnabled
            ))
        }
        .onAppear {
            pushEnabled = PushRegistration.isEnabled(serverId: serverId)
            liveActivityEnabled = LiveActivitySettings.isEnabled(serverId: serverId)
        }
        .alert("Turn On Push Notifications?", isPresented: $showDisclosure) {
            Button("Turn On") { turnPushOn() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let relayHost {
                Text(Self.disclosure(relayHost: relayHost))
            }
        }
    }

    static func disclosure(relayHost: String) -> String {
        String(localized: "Alerts from this server travel through \(relayHost) and Apple. Their content is encrypted on your server to a key that only this device holds. The relay and Apple can see this device's push token, when each alert is sent, and your server's network address. They cannot read titles, session names, or questions.")
    }

    /// Push (when the server offers it), then the Live Activity, which depends on push to stay
    /// current while Oppi is closed.
    static func footer(relayHost: String?, relayRefusesThisDevice: Bool, pushEnabled: Bool) -> String {
        var parts: [String] = []
        if let relayHost {
            parts.append(String(localized: "Push alerts are end-to-end encrypted through \(relayHost). Off by default."))
            if relayRefusesThisDevice {
                parts.append(String(localized: "Push is not available on this device: it can't prove to the relay that it runs Oppi."))
            }
        }
        parts.append(String(localized: "The Live Activity shows only how many agents are running and how many need you."))
        parts.append(
            pushEnabled
                ? String(localized: "With push on, this server keeps it current while Oppi is closed.")
                : String(localized: "Without push, it updates only while Oppi is open.")
        )
        return parts.joined(separator: " ")
    }

    private func setLiveActivity(_ enabled: Bool) {
        LiveActivitySettings.setEnabled(enabled, serverId: serverId)
        liveActivityEnabled = enabled
        LiveActivityManager.shared.settingsChanged(serverId: serverId)
        connection?.syncLiveActivityState()
        // The relay already follows the phone's state (settingsChanged sent it); the server
        // learns whether to drive the card. Turning it off takes effect at the relay either way.
        liveActivityStatus = .idle
        guard pushEnabled, let connection, let relay = connection.pushRelay, let api = connection.apiClient,
              let deviceId = connection.credentials?.deviceCredential?.deviceId else { return }
        liveActivityStatus = .working
        Task {
            let updated = await PushRegistration.shared.register(
                api: api,
                serverId: serverId,
                deviceId: deviceId,
                relay: relay
            )
            liveActivityStatus = updated ? .idle : .failed
        }
    }

    private func turnPushOn() {
        guard let connection, let relay = connection.pushRelay, let api = connection.apiClient,
              let deviceId = connection.credentials?.deviceCredential?.deviceId else {
            status = .failed
            return
        }
        PushRegistration.setEnabled(true, serverId: serverId)
        pushEnabled = true
        status = .working
        Task {
            let registered = await PushRegistration.shared.register(
                api: api,
                serverId: serverId,
                deviceId: deviceId,
                relay: relay
            )
            if registered {
                status = .idle
            } else {
                PushRegistration.setEnabled(false, serverId: serverId)
                pushEnabled = false
                status = .failed
            }
        }
    }

    private func turnPushOff() {
        pushEnabled = false
        status = .working
        let connection = connection
        Task {
            await PushRegistration.shared.disable(
                serverId: serverId,
                api: connection?.apiClient,
                relay: connection?.pushRelay
            )
            status = .idle
        }
    }
}
