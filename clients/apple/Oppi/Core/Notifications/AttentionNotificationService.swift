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
/// This keeps agent questions and extension prompts visible while working across sessions
/// without enabling remote APNs push registration.
@MainActor
final class AttentionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotificationService()

    /// Category ID for agent questions. Tapping opens the owning session.
    nonisolated static let askCategoryId = AttentionNotificationPolicy.askCategoryId

    /// Remote session-ended alerts. Tapping opens the owning session.
    nonisolated static let sessionDoneCategoryId = AttentionNotificationPolicy.sessionDoneCategoryId

    /// Remote session-error alerts. Tapping opens the owning session.
    nonisolated static let sessionErrorCategoryId = AttentionNotificationPolicy.sessionErrorCategoryId

    /// Called when the user taps an ask notification body.
    /// Navigate to the session containing this ask request.
    var onNavigateToSession: ((String) -> Void)? {
        didSet {
            deliverPendingNavigationTapsIfPossible()
        }
    }

    // Taps can arrive before OppiApp finishes wiring its navigation handler on
    // cold launch. Keep them app-layer agnostic here and deliver them once wired.
    private var pendingNavigationSessionIds: [String] = []

    // Test seams
    var _applicationStateForTesting: UIApplication.State?
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

        let sessionCategories = AttentionNotificationPolicy.sessionCategoryIds.map { identifier in
            UNNotificationCategory(
                identifier: identifier,
                actions: [],
                intentIdentifiers: []
            )
        }

        center.setNotificationCategories(Set(sessionCategories))
    }

    // MARK: - Fire Notifications

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

        let payload = AttentionNotificationPolicy.askPayload(for: ask)
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.subtitle = payload.subtitle
        content.body = payload.body
        content.categoryIdentifier = payload.categoryIdentifier
        content.userInfo = payload.userInfo
        content.threadIdentifier = payload.threadIdentifier
        content.targetContentIdentifier = payload.targetContentIdentifier
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        schedule(
            identifier: payload.identifier,
            content: content
        )
    }

    nonisolated static func shouldNotify(
        isAppActive: Bool,
        requestSessionId: String,
        activeSessionId: String?
    ) -> Bool {
        AttentionNotificationPolicy.shouldNotify(
            isAppActive: isAppActive,
            requestSessionId: requestSessionId,
            activeSessionId: activeSessionId
        )
    }

    /// Session id carried by a local ask banner or a remote session-event push.
    nonisolated static func navigationSessionId(
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> String? {
        AttentionNotificationPolicy.navigationSessionId(
            categoryIdentifier: categoryIdentifier,
            userInfo: userInfo
        )
    }

    /// Cancel ask notification when the ask is answered or superseded.
    func cancelAskNotification(sessionId: String) {
        let identifier = AttentionNotificationPolicy.askRequestIdentifier(sessionId: sessionId)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
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

    func handleAskNotificationTap(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        guard let onNavigateToSession else {
            pendingNavigationSessionIds.append(sessionId)
            return
        }
        onNavigateToSession(sessionId)
    }

    private func deliverPendingNavigationTapsIfPossible() {
        guard let onNavigateToSession, !pendingNavigationSessionIds.isEmpty else { return }
        let pendingSessionIds = pendingNavigationSessionIds
        pendingNavigationSessionIds.removeAll()
        for sessionId in pendingSessionIds {
            onNavigateToSession(sessionId)
        }
    }

    /// Handle taps on local attention notifications.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        if let sessionId = Self.navigationSessionId(
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        ) {
            Task { @MainActor in
                handleAskNotificationTap(sessionId: sessionId)
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
        case Self.askCategoryId:
            completionHandler([.banner, .sound])
        default:
            completionHandler([])
        }
    }
}
