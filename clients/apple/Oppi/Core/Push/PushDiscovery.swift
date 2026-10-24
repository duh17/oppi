import DeviceCheck
import Foundation

/// The one-time card that tells a person push exists: "Get notified when an
/// agent needs you", in All Sessions, after their first session on a server
/// finishes or first needs input (whichever comes first).
///
/// Push is off by default and the switch lives in Server Settings →
/// Notifications, where nobody looks until they miss an alert. The moment worth
/// interrupting is the first time an agent finished or asked for them, because
/// that is the moment they could have been somewhere else.
///
/// State is per server and device-local, in `UserDefaults.standard` like the
/// push opt-in it points at:
///
/// - no value: nothing has happened yet;
/// - `ready`: a session finished or needed input, and the card has not been
///   answered;
/// - `closed`: the person dismissed the card, or push registered for the server
///   (from the card or Server Settings). It never comes back.
enum PushDiscovery {
    enum Stage: String, Equatable, Sendable {
        case ready
        case closed
    }

    /// Posted after the stage changes, so a visible All Sessions list redraws.
    static let didChangeNotification = Notification.Name("dev.chenda.Oppi.pushDiscoveryDidChange")

    private static func key(serverId: String) -> String {
        "\(AppIdentifiers.subsystem).push.discovery.\(serverId)"
    }

    static func stage(serverId: String, defaults: UserDefaults = .standard) -> Stage? {
        defaults.string(forKey: key(serverId: serverId)).flatMap(Stage.init(rawValue:))
    }

    /// A session on `serverId` finished or needs the person. The first one makes the card
    /// due; a person who already uses push, or closed the card, is not asked.
    @MainActor
    static func noteAttention(serverId: String, pushEnabled: Bool, defaults: UserDefaults = .standard) {
        guard stage(serverId: serverId, defaults: defaults) == nil else { return }
        if pushEnabled {
            close(serverId: serverId, defaults: defaults)
        } else {
            set(.ready, serverId: serverId, defaults: defaults)
        }
    }

    /// The person dismissed the card, or push is on. Final.
    static func close(serverId: String, defaults: UserDefaults = .standard) {
        guard stage(serverId: serverId, defaults: defaults) != .closed else { return }
        set(.closed, serverId: serverId, defaults: defaults)
    }

    /// The server was removed.
    static func forget(serverId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(serverId: serverId))
    }

    private static func set(_ stage: Stage, serverId: String, defaults: UserDefaults) {
        defaults.set(stage.rawValue, forKey: key(serverId: serverId))
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: - Visibility

    /// Whether this build and device can turn push on for a server that names `relay`:
    /// the server offers push (its operator has not set `push.mode` to `off`), the build is
    /// signed for APNs, and App Store and TestFlight builds can pass App Attest, which the
    /// relay requires (Server Settings explains the same refusal).
    static func isPushAvailable(relay: URL?) -> Bool {
        guard relay != nil, let environment = APNsEnvironment.current else { return false }
        return !(environment == .production && !DCAppAttestService.shared.isSupported)
    }

    /// The card shows when a first moment happened, push can be turned on here, it is not
    /// on yet, and the person has not answered the card.
    static func shouldShow(stage: Stage?, pushAvailable: Bool, pushEnabled: Bool) -> Bool {
        stage == .ready && pushAvailable && !pushEnabled
    }
}
