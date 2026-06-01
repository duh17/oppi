import UIKit

/// UIKit delegate for push notification device token callbacks.
///
/// SwiftUI's `App` protocol has no equivalent of
/// `didRegisterForRemoteNotificationsWithDeviceToken`.
/// This delegate bridges the gap.
///
/// @MainActor isolates this to the main thread, avoiding the
/// `unsafeForcedSync` warning from @UIApplicationDelegateAdaptor.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Force-capture process start timestamp before any SwiftUI views load.
        // Static lets are lazy — this ensures it runs at app delegate init, not first view appear.
        ChatSessionTelemetry.warmProcessStartTime()
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            AttentionNotificationService.shared.configureForLaunch()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard ReleaseFeatures.remotePushNotificationsEnabled else {
            return
        }
        PushRegistration.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        guard ReleaseFeatures.remotePushNotificationsEnabled else {
            return
        }
        PushRegistration.shared.didFailToRegisterForRemoteNotifications(error: error)
    }
}
