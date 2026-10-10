import UIKit
import UserNotifications
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Push")

/// Registers this device for APNs and hands its token to paired servers that send pushes.
///
/// Remote push is server-driven: a server advertises `capabilities.pushNotifications`
/// once its operator configures APNs (`apns.json`), and `ServerConnection` calls
/// `serverAdvertisesPush(api:serverId:)` when it loads that capability. A server that does not
/// advertise it is never sent a token; with no such server the app never registers with
/// APNs or asks for notification permission. Permission is asked only after APNs issues a
/// token, so a build without the Push Notifications entitlement never prompts.
///
/// `UIApplicationDelegate` delivers the token (see `AppDelegate`).
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// This process's APNs token. iOS issues it in response to the first
    /// `registerForRemoteNotifications()` of each launch, as Apple recommends.
    private var deviceToken: String?
    private var tokenWaiters: [CheckedContinuation<String?, Never>] = []

    #if DEBUG
    /// Replaces the APNs registration a server's push capability starts.
    var _onRegisterForTesting: ((String?) -> Void)?
    #endif

    private init() {}

    /// A paired server advertised push: send it this device's token, with this build's
    /// APNs environment. The server ties it to this paired device.
    func serverAdvertisesPush(api: APIClient, serverId: String?) {
        #if DEBUG
        if let onRegister = _onRegisterForTesting {
            onRegister(serverId)
            return
        }
        // Screenshot previews must not raise the system permission alert.
        if ScreenshotPreviewConfig.isEnabled { return }
        #endif
        Task { await register(with: api, serverId: serverId) }
    }

    private func register(with api: APIClient, serverId: String?) async {
        let server = serverId?.prefix(16) ?? "unknown"
        guard let environment = APNsEnvironment.current else {
            logger.error("Push registration skipped for server \(server, privacy: .public): the embedded provisioning profile has no aps-environment")
            return
        }
        guard let token = await currentDeviceToken(), await notificationsAuthorized() else { return }
        do {
            try await api.registerDeviceToken(token, apnsEnvironment: environment)
            logger.info("Push token registered with server \(server, privacy: .public) (\(environment.rawValue, privacy: .public))")
        } catch {
            logger.error("Push token registration failed for server \(server, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called from AppDelegate when APNs issues the device token.
    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        resumeTokenWaiters(with: token)
    }

    /// Called from AppDelegate when APNs registration fails, including on a build
    /// signed without the Push Notifications entitlement.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        logger.error("Failed to register for remote notifications: \(error.localizedDescription, privacy: .public)")
        resumeTokenWaiters(with: nil)
    }

    /// APNs registration needs no notification permission; asking for it waits until a
    /// token proves this build can receive pushes.
    private func currentDeviceToken() async -> String? {
        if let deviceToken { return deviceToken }
        return await withCheckedContinuation { continuation in
            tokenWaiters.append(continuation)
            if tokenWaiters.count == 1 {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private func resumeTokenWaiters(with token: String?) {
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: token)
        }
    }

    /// Ask on first use. A denied permission keeps the token off the server: it could only
    /// deliver alerts iOS would not show.
    private func notificationsAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                logger.error("Failed to request notification permission: \(error.localizedDescription, privacy: .public)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
