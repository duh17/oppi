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
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistration.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushRegistration.shared.didFailToRegisterForRemoteNotifications(error: error)
    }
}
