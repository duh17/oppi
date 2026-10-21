import ActivityKit
import DeviceCheck
import SwiftUI

/// Server Settings → Notifications: this server's push alerts and Live Activity on this device.
///
/// Push is opt-in and shown only when the server pushes through a relay; turning it on first
/// says what the relay can and cannot see (protocol/push/spec.md §6). The Live Activity is
/// opt-in too and shows counts only. With push on, the server also keeps the card current
/// while Oppi is closed; without push the card updates only while Oppi is open.
///
/// Anything that makes data leave the device asks first (docs/privacy.md, "The push relay"
/// and "Live Activities"): turning push on, and turning Live Activities on while push is on.
/// Turning Live Activities on with push off sends nothing, so it asks nothing.
struct ServerNotificationsSection: View {
    let serverId: String
    let connection: ServerConnection?

    @Environment(\.appRootEnvironment) private var appRoot
    @State private var pushEnabled = false
    @State private var liveActivityEnabled = false
    @State private var consent: Consent?
    @State private var status: Status = .idle
    @State private var liveActivityStatus: Status = .idle

    /// What the user is being asked to agree to before it takes effect. The relay host is
    /// captured when the alert is shown: the connection can drop while it is up, and the
    /// message must not change or go blank.
    enum Consent: Equatable {
        /// Push on. `withCounts`: Live Activities is already on, so the card's counts go too.
        case push(relayHost: String, withCounts: Bool)
        /// Live Activities on while push is already on.
        case liveActivity(relayHost: String)

        var title: String {
            switch self {
            case .push: String(localized: "Turn On Push Notifications?")
            case .liveActivity: String(localized: "Turn On Live Activities?")
            }
        }
    }

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

    /// The relay host is unknown while the server is offline or reconnecting.
    private static func hostForConsent(_ relayHost: String?) -> String {
        relayHost ?? String(localized: "the push relay")
    }

    /// The consent to show before turning Live Activities on, or nil when nothing leaves the
    /// device: counts reach the relay for any server whose push is on, even while it is offline
    /// (the server sends them once it reconnects), so only `pushEnabled` decides.
    static func consentForLiveActivityOn(pushEnabled: Bool, relayHost: String?) -> Consent? {
        pushEnabled ? .liveActivity(relayHost: hostForConsent(relayHost)) : nil
    }

    var body: some View {
        Section {
            if relayHost != nil {
                Toggle(isOn: Binding(
                    get: { pushEnabled },
                    set: { newValue in
                        if newValue {
                            consent = .push(
                                relayHost: Self.hostForConsent(relayHost),
                                withCounts: liveActivityEnabled
                            )
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
                set: { newValue in
                    if newValue,
                       let needed = Self.consentForLiveActivityOn(pushEnabled: pushEnabled, relayHost: relayHost) {
                        consent = needed
                    } else {
                        setLiveActivity(newValue)
                    }
                }
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
        .alert(
            consent?.title ?? "",
            isPresented: Binding(get: { consent != nil }, set: { if !$0 { consent = nil } }),
            presenting: consent
        ) { pending in
            Button("Turn On") {
                switch pending {
                case .push: turnPushOn()
                case .liveActivity: setLiveActivity(true)
                }
            }
            Button("Cancel", role: .cancel) {}
            // An alert cannot hold a link. This button closes it without turning anything on;
            // the user reads the policy, then turns the setting on again.
            Button("Privacy Policy") {
                appRoot?.opener.open(.webLink(AppSupportLinks.privacyPolicyURL))
            }
        } message: { pending in
            Text(Self.message(for: pending))
        }
    }

    /// Agrees with docs/privacy.md, "The push relay", "Apple" and "Live Activities". Describes
    /// Oppi's relay (the App Store and TestFlight relay); the doc says so too.
    static func message(for consent: Consent) -> String {
        switch consent {
        case .push(let relayHost, let withCounts):
            let base = String(localized: "Alerts travel through \(relayHost) on Cloudflare, then Apple, encrypted so only this device can read them. All three see this device's push token and when alerts are sent; only the relay and Cloudflare see your server's IP address. App Attest checks with Apple that this is Oppi, so Apple learns this install uses push.")
            guard withCounts else { return base }
            return base + " " + String(localized: "The Live Activity's two counts also reach all three unencrypted, up to once a minute.")
        case .liveActivity(let relayHost):
            return String(localized: "To keep the card current while Oppi is closed, its two counts go to \(relayHost), Cloudflare, and Apple unencrypted, up to once a minute. No names or other text.")
        }
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
