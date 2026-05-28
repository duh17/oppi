import Foundation
import UserNotifications
import UIKit
import OSLog

private let notificationLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "AttentionNotifications")

/// Manages local notifications for attention requests received while the app is running.
///
/// Fires alerts when:
/// - App is backgrounded/inactive (lock screen/banner)
/// - App is foregrounded but the request is for a different session
///
/// This keeps permission prompts and agent questions visible during multi-session supervision
/// without enabling remote APNs push registration.
@MainActor
final class PermissionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PermissionNotificationService()

    nonisolated static let categoryId = "PERMISSION_REQUEST"
    nonisolated static let allowActionId = "ALLOW_PERMISSION"
    nonisolated static let denyActionId = "DENY_PERMISSION"

    /// Category ID for biometric-gated permissions (deny-only from lock screen).
    nonisolated static let biometricCategoryId = "PERMISSION_BIOMETRIC"

    /// Category ID for agent questions. Tapping opens the owning session.
    nonisolated static let askCategoryId = "ASK_REQUEST"

    /// Called when the user responds to a notification action.
    /// The handler should route the response to the WebSocket.
    var onPermissionResponse: ((String, PermissionAction) -> Void)?

    /// Called when the user taps a permission notification body (not an action button).
    /// Navigate to the session containing this permission.
    var onNavigateToPermission: ((String, String) -> Void)?  // (permissionId, sessionId)

    /// Called when the user taps an ask notification body.
    /// Navigate to the session containing this ask request.
    var onNavigateToSession: ((String) -> Void)?

    // Test seams
    var _applicationStateForTesting: UIApplication.State?
    var _onNotifyDecisionForTesting: ((PermissionRequest, String?, Bool) -> Void)?
    var _skipSchedulingForTesting = false

    private var didConfigureForLaunch = false

    override private init() {
        super.init()
    }

    // MARK: - Setup

    /// Register notification categories and delegate.
    ///
    /// Apple recommends assigning the `UNUserNotificationCenter` delegate before
    /// app launch finishes so notification actions are not missed. Keep this
    /// synchronous and call it from `AppDelegate`.
    func configureForLaunch() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        guard !didConfigureForLaunch else {
            return
        }
        didConfigureForLaunch = true

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

        let askCategory = UNNotificationCategory(
            identifier: Self.askCategoryId,
            actions: [],
            intentIdentifiers: []
        )

        center.setNotificationCategories([standardCategory, biometricCategory, askCategory])
    }

    // MARK: - Fire Notifications

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
            "kind": "permission",
            "permissionId": request.id,
            "sessionId": request.sessionId,
        ]
        content.threadIdentifier = request.sessionId
        content.targetContentIdentifier = request.sessionId
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        schedule(
            identifier: "perm-\(request.id)",
            content: content
        )
    }

    /// Schedule a local notification for an agent question.
    func notifyAskIfNeeded(_ ask: AskRequest, activeSessionId: String?) {
        let appState = _applicationStateForTesting ?? UIApplication.shared.applicationState
        let isAppActive = appState == .active
        let shouldNotify = Self.shouldNotify(
            isAppActive: isAppActive,
            requestSessionId: ask.sessionId,
            activeSessionId: activeSessionId
        )
        guard shouldNotify else {
            return
        }

        let questionCount = ask.questions.count
        let firstQuestion = ask.questions.first?.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBody = questionCount == 1
            ? String(localized: "Open Oppi to answer a question.")
            : String(localized: "Open Oppi to answer questions.")

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Question from agent")
        content.subtitle = questionCount == 1 ? String(localized: "1 question") : "\(questionCount) questions"
        if let firstQuestion, !firstQuestion.isEmpty {
            content.body = firstQuestion
        } else {
            content.body = fallbackBody
        }
        content.categoryIdentifier = Self.askCategoryId
        content.userInfo = [
            "kind": "ask",
            "askId": ask.id,
            "sessionId": ask.sessionId,
        ]
        content.threadIdentifier = ask.sessionId
        content.targetContentIdentifier = ask.sessionId
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        schedule(
            identifier: "ask-\(ask.sessionId)",
            content: content
        )
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

    /// Cancel ask notification when the ask is answered or superseded.
    func cancelAskNotification(sessionId: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["ask-\(sessionId)"])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["ask-\(sessionId)"])
    }

    private func schedule(identifier: String, content: UNNotificationContent) {
        // Fire immediately (0.1s minimum for time-interval triggers)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        guard !_skipSchedulingForTesting else {
            return
        }

        Task { @MainActor in
            guard await ensureAuthorizationForNotification() else {
                return
            }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                notificationLogger.error("Failed to schedule attention notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func ensureAuthorizationForNotification() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                notificationLogger.error("Failed to request notification permission: \(error.localizedDescription, privacy: .public)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification action (Allow/Deny from lock screen).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let userInfo = content.userInfo
        let sessionId = userInfo["sessionId"] as? String ?? ""

        if content.categoryIdentifier == Self.askCategoryId {
            if !sessionId.isEmpty {
                Task { @MainActor in
                    onNavigateToSession?(sessionId)
                }
            }
            completionHandler()
            return
        }

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
            Task { @MainActor in
                onNavigateToPermission?(permissionId, sessionId)
            }
        }

        completionHandler()
    }

    /// Show local attention notifications even when app is in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        switch notification.request.content.categoryIdentifier {
        case Self.categoryId, Self.biometricCategoryId, Self.askCategoryId:
            completionHandler([.banner, .sound])
        default:
            completionHandler([])
        }
    }
}
