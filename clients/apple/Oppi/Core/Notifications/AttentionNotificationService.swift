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
    nonisolated static let askCategoryId = "ASK_REQUEST"

    /// Remote session-ended alerts. Tapping opens the owning session.
    nonisolated static let sessionDoneCategoryId = "SESSION_DONE"

    /// Remote session-error alerts. Tapping opens the owning session.
    nonisolated static let sessionErrorCategoryId = "SESSION_ERROR"

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

        let sessionCategories = [
            Self.askCategoryId,
            Self.sessionDoneCategoryId,
            Self.sessionErrorCategoryId,
        ].map { identifier in
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

    /// Session id carried by a local ask banner or a remote session-event push.
    nonisolated static func navigationSessionId(
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> String? {
        switch categoryIdentifier {
        case askCategoryId, sessionDoneCategoryId, sessionErrorCategoryId:
            break
        default:
            return nil
        }
        guard let sessionId = userInfo["sessionId"] as? String else {
            return nil
        }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
