import DeviceCheck
import SwiftUI

/// Opt-in for end-to-end-encrypted push from one server, shown only when the server pushes
/// through a relay. Off by default; turning it on first says what the relay can and cannot
/// see (protocol/push/spec.md §6).
struct ServerPushNotificationsSection: View {
    let serverId: String
    let connection: ServerConnection?

    @State private var isEnabled = false
    @State private var showDisclosure = false
    @State private var status: Status = .idle

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
        if let relayHost {
            Section {
                Toggle(
                    "Push Notifications",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            if newValue {
                                showDisclosure = true
                            } else {
                                turnOff()
                            }
                        }
                    )
                )
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
            } footer: {
                Text(Self.footer(relayHost: relayHost, relayRefusesThisDevice: Self.relayRefusesThisDevice))
            }
            .onAppear { isEnabled = PushRegistration.isEnabled(serverId: serverId) }
            .alert("Turn On Push Notifications?", isPresented: $showDisclosure) {
                Button("Turn On") { turnOn() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(Self.disclosure(relayHost: relayHost))
            }
        }
    }

    static func disclosure(relayHost: String) -> String {
        String(localized: "Alerts from this server travel through \(relayHost) and Apple. Their content is encrypted on your server to a key that only this device holds. The relay and Apple can see this device's push token, when each alert is sent, and your server's network address. They cannot read titles, session names, or questions.")
    }

    static func footer(relayHost: String, relayRefusesThisDevice: Bool) -> String {
        let base = String(localized: "End-to-end encrypted through \(relayHost). Off by default.")
        guard relayRefusesThisDevice else { return base }
        return base + " " + String(localized: "Not available on this device: it can't prove to the relay that it runs Oppi.")
    }

    private func turnOn() {
        guard let connection, let relay = connection.pushRelay, let api = connection.apiClient,
              let deviceId = connection.credentials?.deviceCredential?.deviceId else {
            status = .failed
            return
        }
        PushRegistration.setEnabled(true, serverId: serverId)
        isEnabled = true
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
                isEnabled = false
                status = .failed
            }
        }
    }

    private func turnOff() {
        isEnabled = false
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
