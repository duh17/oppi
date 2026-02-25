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
    private var serverConnection: ServerConnection?

    private init() {}

    /// Configure with the active server connection.
    func configure(connection: ServerConnection) {
        self.serverConnection = connection
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
                    logger.info("Notification permission granted")
                } else {
                    logger.info("Notification permission denied")
                    return
                }
            } catch {
                logger.error("Failed to request notification permission: \(error)")
                return
            }
        } else if settings.authorizationStatus == .denied {
            logger.info("Notifications denied — user must enable in Settings")
            return
        }

        // Register for remote notifications (triggers didRegisterForRemoteNotificationsWithDeviceToken)
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called from AppDelegate when APNs device token is received.
    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = token
        logger.info("Device token received (chars: \(token.count))")

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
        guard let api = serverConnection?.apiClient else {
            logger.warning("Cannot send token — no API client configured")
            return
        }

        do {
            try await api.registerDeviceToken(token, tokenType: tokenType)
            isRegistered = true
            logger.info("Device token registered with server (type: \(tokenType))")
        } catch {
            logger.error("Failed to register device token: \(error)")
        }
    }

    /// Register the device token with ALL paired servers (multi-server support).
    ///
    /// Each server gets a separate registration call. Failures are per-server
    /// and don't block others.
    func registerWithAllServers(_ servers: [PairedServer]) async {
        guard let token = deviceToken else {
            logger.info("No device token yet — skipping multi-server registration")
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                guard let baseURL = server.baseURL else { continue }
                let serverToken = server.token
                let serverId = server.id

                group.addTask {
                    let api = APIClient(
                        baseURL: baseURL,
                        token: serverToken,
                        tlsCertFingerprint: server.tlsCertFingerprint
                    )
                    do {
                        try await api.registerDeviceToken(token, tokenType: "apns")
                        logger.info("Push token registered with server \(serverId.prefix(16), privacy: .public)")
                    } catch {
                        logger.error("Push token registration failed for server \(serverId.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Re-send the cached device token (e.g., after reconnect).
    func resendTokenIfNeeded() async {
        guard let token = deviceToken else { return }
        await sendTokenToServer(token, tokenType: "apns")
    }
}
