import UIKit

/// Turning push on from a UIKit surface (the All Sessions discovery card). The
/// same path as Server Settings → Notifications: the relay disclosure alert
/// (`ServerNotificationsSection.Consent`, same title and words), then
/// `PushRegistration.enable`, which asks iOS for notification permission and
/// registers with the relay. Nothing is sent to the relay before the person
/// taps Turn On.
@MainActor
enum PushEnableFlow {
    enum Outcome: Equatable {
        /// The person closed the disclosure without turning anything on.
        case cancelled
        /// Registration is running.
        case working
        case enabled
        /// What went wrong, in the words Server Settings uses.
        case failed(String)
    }

    /// Shows the relay disclosure over `presenter`, then turns push on for `connection`'s
    /// server. `progress` hears each step; the relay is the one the disclosure named, so a
    /// connection that names another relay by the time the person agrees fails before any
    /// relay hears from this phone.
    static func start(
        connection: ServerConnection,
        presenter: UIViewController,
        openPrivacyPolicy: @escaping () -> Void,
        progress: @escaping (Outcome) -> Void
    ) {
        guard let relay = connection.pushRelay, let serverId = connection.currentServerId else {
            progress(.failed(failureMessage(.refused)))
            return
        }
        let consent = ServerNotificationsSection.Consent.push(
            relay: relay,
            withCounts: LiveActivitySettings.isEnabled(serverId: serverId)
        )
        let alert = UIAlertController(
            title: consent.title,
            message: ServerNotificationsSection.message(for: consent),
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = "push.enable.disclosure"
        alert.addAction(UIAlertAction(title: String(localized: "Turn On"), style: .default) { [weak connection] _ in
            guard let connection else { return }
            turnOn(connection: connection, serverId: serverId, relay: relay, progress: progress)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
            progress(.cancelled)
        })
        // An alert cannot hold a link. This button closes it without turning anything on;
        // the person reads the policy, then turns push on again.
        alert.addAction(UIAlertAction(title: String(localized: "Privacy Policy"), style: .default) { _ in
            progress(.cancelled)
            openPrivacyPolicy()
        })
        Router.topPresenter(from: presenter).present(alert, animated: true)
    }

    private static func turnOn(
        connection: ServerConnection,
        serverId: String,
        relay: URL,
        progress: @escaping (Outcome) -> Void
    ) {
        guard connection.pushRelay == relay, let api = connection.apiClient,
              let deviceId = connection.credentials?.deviceCredential?.deviceId else {
            progress(.failed(failureMessage(.refused)))
            return
        }
        progress(.working)
        Task {
            let failure = await PushRegistration.shared.enable(
                api: api,
                serverId: serverId,
                deviceId: deviceId,
                relay: relay
            )
            progress(failure.map { .failed(failureMessage($0)) } ?? .enabled)
        }
    }

    private static func failureMessage(_ failure: PushRegistration.Failure) -> String {
        ServerNotificationsSection.message(for: failure)
    }
}
