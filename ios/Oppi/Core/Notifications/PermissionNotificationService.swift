import Foundation
import UserNotifications
import UIKit

/// Manages local notifications for permission requests.
///
/// Fires alerts when:
/// - App is backgrounded/inactive (lock screen/banner)
/// - App is foregrounded but the request is for a different session
///
/// This keeps permission prompts visible during multi-session supervision.
@MainActor
final class PermissionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PermissionNotificationService()

    static let categoryId = "PERMISSION_REQUEST"
    static let allowActionId = "ALLOW_PERMISSION"
    static let denyActionId = "DENY_PERMISSION"

    /// Called when the user responds to a notification action.
    /// The handler should route the response to the WebSocket.
    var onPermissionResponse: ((String, PermissionAction) -> Void)?

    /// Called when the user taps the notification body (not an action button).
    /// Navigate to the session containing this permission.
    var onNavigateToPermission: ((String, String) -> Void)?  // (permissionId, sessionId)

    // Test seams
    var _applicationStateForTesting: UIApplication.State?
    var _onNotifyDecisionForTesting: ((PermissionRequest, String?, Bool) -> Void)?
    var _skipSchedulingForTesting = false

    override private init() {
        super.init()
    }

    // MARK: - Setup

    /// Category ID for biometric-gated permissions (deny-only from lock screen).
    static let biometricCategoryId = "PERMISSION_BIOMETRIC"

    /// Register notification categories and request authorization.
    ///
    /// Two categories:
    /// - `PERMISSION_REQUEST`: Allow/Deny actions (when biometric disabled)
    /// - `PERMISSION_BIOMETRIC`: Deny-only (when biometric enabled, must open app to allow)
    func setup() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let allow = UNNotificationAction(
            identifier: Self.allowActionId,
            title: String(localized: "Allow"),
            options: []
        )
        let deny = UNNotificationAction(
            identifier: Self.denyActionId,
            title: String(localized: "Deny"),
            options: [.destructive]
        )
        let standardCategory = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [allow, deny],
            intentIdentifiers: []
        )

        // Biometric-gated: Deny only — user must open app for Allow (triggers Face ID)
        let biometricCategory = UNNotificationCategory(
            identifier: Self.biometricCategoryId,
            actions: [deny],
            intentIdentifiers: []
        )

        center.setNotificationCategories([standardCategory, biometricCategory])

        // Request permission (first launch only)
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Fire Notification

    /// Schedule a local notification for a permission request.
    ///
    /// Fires when:
    /// - App is backgrounded/inactive (always)
    /// - App is active, but permission is for a non-active session
    ///
    /// This prevents missed approvals when multiple sessions run in parallel.
    func notifyIfNeeded(_ request: PermissionRequest, activeSessionId: String?) {
        let appState = _applicationStateForTesting ?? UIApplication.shared.applicationState
        let isAppActive = appState == .active
        let shouldNotify = Self.shouldNotify(
            isAppActive: isAppActive,
            requestSessionId: request.sessionId,
            activeSessionId: activeSessionId
        )
        _onNotifyDecisionForTesting?(request, activeSessionId, shouldNotify)
        guard shouldNotify else {
            return
        }

        let needsBiometric = BiometricService.shared.requiresBiometric

        let content = UNMutableNotificationContent()
        content.title = needsBiometric ? String(localized: "⚠ Permission Required") : String(localized: "Permission Required")
        content.subtitle = request.tool
        content.body = needsBiometric
            ? "Open app to approve with \(BiometricService.shared.biometricName)"
            : request.displaySummary
        content.categoryIdentifier = needsBiometric ? Self.biometricCategoryId : Self.categoryId
        content.userInfo = [
            "permissionId": request.id,
            "sessionId": request.sessionId,
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

        guard !_skipSchedulingForTesting else {
            return
        }

        Task {
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    nonisolated static func shouldNotify(
        isAppActive: Bool,
        requestSessionId: String,
        activeSessionId: String?
    ) -> Bool {
        guard isAppActive else {
            return true
        }
        return requestSessionId != activeSessionId
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
        } else {
            // User tapped the notification body — navigate to the session
            let sessionId = userInfo["sessionId"] as? String ?? ""
            Task { @MainActor in
                onNavigateToPermission?(permissionId, sessionId)
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
