import UIKit
import UserNotifications
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Push")

/// Manages remote push notification registration and device token forwarding.
///
/// Flow:
/// 1. Request notification authorization (after successful server connection)
/// 2. Register with APNs (UIApplication.shared.registerForRemoteNotifications)
/// 3. Forward device token to server (POST /me/device-token)
///
/// Uses UIApplicationDelegate callbacks for token delivery.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    private(set) var isRegistered = false
    private var deviceToken: String?
    private weak var coordinator: ConnectionCoordinator?

    private init() {}

    /// Configure with the app's transport owner. The active server may not be
    /// prepared yet when APNs registration starts during launch.
    func configure(coordinator: ConnectionCoordinator) {
        self.coordinator = coordinator
    }

    /// Request notification permission and register for remote notifications.
    /// Call AFTER successful server connection to maximize grant rate.
    func requestAndRegister() async {
        let center = UNUserNotificationCenter.current()

        // Check current authorization status first
        let settings = await center.notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            // First time — request permission
            do {
                let granted = try await center.requestAuthorization(options: [
                    .alert, .sound, .badge, .providesAppNotificationSettings
                ])
                if granted {
                    logger.warning("Notification permission granted")
                } else {
                    logger.error("Notification permission denied")
                    return
                }
            } catch {
                logger.error("Failed to request notification permission: \(error)")
                return
            }
        } else if settings.authorizationStatus == .denied {
            logger.warning("Notifications denied — user must enable in Settings")
            return
        }

        // Register for remote notifications (triggers didRegisterForRemoteNotificationsWithDeviceToken)
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called from AppDelegate when APNs device token is received.
    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = token
        logger.warning("Device token received (chars: \(token.count))")

        // Forward to server
        Task {
            await sendTokenToServer(token, tokenType: "apns")
        }
    }

    /// Called from AppDelegate when registration fails.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        logger.error("Failed to register for remote notifications: \(error)")
    }

    /// Forward the device token to the server.
    func sendTokenToServer(_ token: String, tokenType: String = "apns") async {
        guard let coordinator,
              let serverId = coordinator.activeServerId,
              let api = await coordinator.apiClientReady(for: serverId) else {
            logger.warning("Cannot send token — active server transport is unavailable")
            return
        }

        do {
            try await api.registerDeviceToken(token, tokenType: tokenType)
            isRegistered = true
            logger.warning("Device token registered with server (type: \(tokenType))")
        } catch {
            logger.error("Failed to register device token: \(error)")
        }
    }

    /// Register the device token with ALL paired servers (multi-server support).
    ///
    /// Each server gets a separate registration call. Failures are per-server
    /// and don't block others.
    func registerWithAllServers(using coordinator: ConnectionCoordinator) async {
        guard let token = deviceToken else {
            logger.warning("No device token yet — skipping multi-server registration")
            return
        }

        for server in coordinator.serverStore.servers {
            let serverId = server.id
            guard let api = await coordinator.apiClientReady(for: serverId) else {
                logger.error("Push token registration skipped; transport unavailable for server \(serverId.prefix(16), privacy: .public)")
                continue
            }
            do {
                try await api.registerDeviceToken(token, tokenType: "apns")
                logger.warning("Push token registered with server \(serverId.prefix(16), privacy: .public)")
            } catch {
                logger.error("Push token registration failed for server \(serverId.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
