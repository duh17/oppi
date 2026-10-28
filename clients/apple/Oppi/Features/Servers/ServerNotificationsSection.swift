import ActivityKit
import DeviceCheck
import Foundation
import Observation

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
///
/// The words live here, as statics, so every surface that turns push on says the same
/// thing (`PushEnableFlow`, Server Settings). The rows are a section of
/// `ServerSettingsViewController`; the per-server state is `ServerNotificationsController`.
enum ServerNotificationsSection {
    /// What the user is being asked to agree to before it takes effect. The relay is captured
    /// when the alert is shown: the connection can drop or name another relay while it is up,
    /// and the message must not change or go blank, nor push go to a relay it did not name.
    enum Consent: Equatable {
        /// Push on, through `relay`. `withCounts`: Live Activities is already on, so the card's
        /// counts go too.
        case push(relay: URL, withCounts: Bool)
        /// Live Activities on while push is already on.
        case liveActivity(relayHost: String)

        var title: String {
            switch self {
            case .push: String(localized: "Turn On Push Notifications?")
            case .liveActivity: String(localized: "Turn On Live Activities?")
            }
        }
    }


    /// The relay registers App Store and TestFlight builds only when App Attest vouches for
    /// them; development builds and Simulator may register without it.
    static var relayRefusesThisDevice: Bool {
        APNsEnvironment.current == .production && !DCAppAttestService.shared.isSupported
    }

    /// The relay host is unknown when neither the connection nor a registration names it.
    private static func hostForConsent(_ relayHost: String?) -> String {
        relayHost ?? String(localized: "the push relay")
    }

    /// The consent to show before turning Live Activities on, or nil when nothing leaves the
    /// device: counts reach the relay for any server whose push is on, even while it is offline
    /// (the server sends them once it reconnects), so only `pushEnabled` decides.
    static func consentForLiveActivityOn(pushEnabled: Bool, relayHost: String?) -> Consent? {
        pushEnabled ? .liveActivity(relayHost: hostForConsent(relayHost)) : nil
    }

    /// Agrees with docs/privacy.md, "The push relay", "Apple" and "Live Activities". Describes
    /// Oppi's relay (the App Store and TestFlight relay); the doc says so too.
    static func message(for consent: Consent) -> String {
        switch consent {
        case .push(let relay, let withCounts):
            let relayHost = relay.host() ?? relay.absoluteString
            let base = String(localized: "Alerts travel through \(relayHost) on Cloudflare, then Apple, encrypted so only this device can read them. All three see this device's push token and when alerts are sent; only the relay and Cloudflare see the IP addresses of your server and of this device. App Attest checks with Apple that this is Oppi, so Apple learns this install uses push.")
            guard withCounts else { return base }
            return base + " " + String(localized: "The Live Activity's two counts also reach all three unencrypted, up to once a minute.")
        case .liveActivity(let relayHost):
            return String(localized: "To keep the card current while Oppi is closed, its two counts go to \(relayHost), Cloudflare, and Apple unencrypted, up to once a minute. No names or other text.")
        }
    }

    static func message(for failure: PushRegistration.Failure) -> String {
        switch failure {
        case .notificationsOff:
            String(localized: "Couldn't turn on push: notifications are off for Oppi. Allow them in the Settings app, then try again.")
        case .relayBusy:
            String(localized: "Couldn't turn on push: the push relay is busy. Try again later.")
        case .refused:
            String(localized: "Couldn't turn on push: the server or the push relay didn't accept it. Try again later.")
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
}

/// One server's push and Live Activity state on this device, for the Notifications section of
/// its Server Settings page. The opt-ins live in `UserDefaults` per server
/// (`PushRegistration`, `LiveActivitySettings`); this holds what the section shows while a
/// turn-on or a registration runs, and why one failed.
///
/// A switch that was flipped but not turned on (the person cancelled the disclosure) is put
/// back by `redraw()`: the rows draw from this state, and a redraw with unchanged state would
/// otherwise leave the switch where the finger left it.
@MainActor @Observable
final class ServerNotificationsController {
    enum Status: Equatable {
        case idle
        case working
        case failed
    }

    let serverId: String
    private(set) var pushEnabled: Bool
    private(set) var liveActivityEnabled: Bool
    private(set) var pushStatus: Status = .idle
    /// Why turning push on last failed, in the words Server Settings shows; cleared on the next try.
    private(set) var pushFailure: String?
    private(set) var liveActivityStatus: Status = .idle
    /// Counts the times a switch has to be drawn again from this state.
    private(set) var redraws = 0

    @ObservationIgnored private let defaults: UserDefaults

    init(serverId: String, defaults: UserDefaults = .standard) {
        self.serverId = serverId
        self.defaults = defaults
        pushEnabled = PushRegistration.isEnabled(serverId: serverId, defaults: defaults)
        liveActivityEnabled = LiveActivitySettings.isEnabled(serverId: serverId, defaults: defaults)
    }

    /// Reads the opt-ins again: another surface (the discovery card) may have turned push on.
    func reload() {
        guard pushStatus != .working else { return }
        pushEnabled = PushRegistration.isEnabled(serverId: serverId, defaults: defaults)
        liveActivityEnabled = LiveActivitySettings.isEnabled(serverId: serverId, defaults: defaults)
    }

    /// Draws the rows again from the current state.
    func redraw() {
        redraws += 1
    }

    /// The steps of `PushEnableFlow` for this server's push switch. The opt-in is on from the
    /// moment registration starts, and nothing of a failed turn-on stays (`PushRegistration.enable`).
    func apply(_ outcome: PushEnableFlow.Outcome) {
        switch outcome {
        case .cancelled:
            redraw()
        case .working:
            pushFailure = nil
            pushEnabled = true
            pushStatus = .working
        case .enabled:
            pushEnabled = true
            pushStatus = .idle
        case .failed(let message):
            pushEnabled = false
            pushFailure = message
            pushStatus = .idle
        }
    }

    func turnPushOff(connection: ServerConnection?) {
        pushEnabled = false
        pushFailure = nil
        pushStatus = .working
        let serverId = serverId
        let api = connection?.apiClient
        let relay = connection?.pushRelay
        Task { [weak self] in
            await PushRegistration.shared.disable(serverId: serverId, api: api, relay: relay)
            self?.pushStatus = .idle
        }
    }

    func setLiveActivity(_ enabled: Bool, connection: ServerConnection?) {
        LiveActivitySettings.setEnabled(enabled, serverId: serverId, defaults: defaults)
        liveActivityEnabled = enabled
        LiveActivityManager.shared.settingsChanged(serverId: serverId)
        connection?.syncLiveActivityState()
        // The relay already follows the phone's state (settingsChanged sent it); the server
        // learns whether to drive the card. Turning it off takes effect at the relay either way.
        liveActivityStatus = .idle
        guard pushEnabled, let connection, let relay = connection.pushRelay, let api = connection.apiClient,
              let deviceId = connection.credentials?.deviceCredential?.deviceId else { return }
        liveActivityStatus = .working
        let serverId = serverId
        Task { [weak self] in
            let failure = await PushRegistration.shared.register(
                api: api,
                serverId: serverId,
                deviceId: deviceId,
                relay: relay
            )
            self?.liveActivityStatus = failure == nil ? .idle : .failed
        }
    }
}
