import UIKit

/// UIKit delegate for push notification device token callbacks.
///
/// SwiftUI's `App` protocol has no equivalent of
/// `didRegisterForRemoteNotificationsWithDeviceToken`.
/// This delegate bridges the gap.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushRegistration.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushRegistration.shared.didFailToRegisterForRemoteNotifications(error: error)
        }
    }
}
