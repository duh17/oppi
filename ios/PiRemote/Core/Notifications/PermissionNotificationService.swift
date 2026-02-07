import Foundation
import UserNotifications
import UIKit

/// Manages local push notifications for permission requests.
///
/// Tier 1: When the app is backgrounded, fire a local notification
/// with Allow/Deny actions. The user can respond from the lock screen.
@MainActor
final class PermissionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PermissionNotificationService()

    static let categoryId = "PERMISSION_REQUEST"
    static let allowActionId = "ALLOW_PERMISSION"
    static let denyActionId = "DENY_PERMISSION"

    /// Called when the user responds to a notification action.
    /// The handler should route the response to the WebSocket.
    var onPermissionResponse: ((String, PermissionAction) -> Void)?

    override private init() {
        super.init()
    }

    // MARK: - Setup

    /// Register notification category and request authorization.
    func setup() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register action category
        let allow = UNNotificationAction(
            identifier: Self.allowActionId,
            title: "Allow",
            options: []
        )
        let deny = UNNotificationAction(
            identifier: Self.denyActionId,
            title: "Deny",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [allow, deny],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])

        // Request permission (first launch only)
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Fire Notification

    /// Schedule a local notification for a permission request.
    /// Only fires when app is not in the foreground.
    func notifyIfBackgrounded(_ request: PermissionRequest) {
        guard UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = "Permission Required"
        content.subtitle = request.tool
        content.body = request.displaySummary
        content.categoryIdentifier = Self.categoryId
        content.userInfo = [
            "permissionId": request.id,
            "sessionId": request.sessionId,
            "risk": request.risk.rawValue,
        ]
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        // Fire immediately (0.1s minimum for time-interval triggers)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let req = UNNotificationRequest(
            identifier: "perm-\(request.id)",
            content: content,
            trigger: trigger
        )

        Task {
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    /// Cancel notification when permission is resolved before user sees it.
    func cancelNotification(permissionId: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["perm-\(permissionId)"])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["perm-\(permissionId)"])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification action (Allow/Deny from lock screen).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let permissionId = userInfo["permissionId"] as? String else {
            completionHandler()
            return
        }

        let action: PermissionAction?
        switch response.actionIdentifier {
        case Self.allowActionId:
            action = .allow
        case Self.denyActionId:
            action = .deny
        default:
            action = nil  // User tapped the notification itself — open app
        }

        if let action {
            Task { @MainActor in
                onPermissionResponse?(permissionId, action)
            }
        }

        completionHandler()
    }

    /// Show notification even when app is in foreground (as banner).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + sound even in foreground for permissions
        completionHandler([.banner, .sound])
    }
}
