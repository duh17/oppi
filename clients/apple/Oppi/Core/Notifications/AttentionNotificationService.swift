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
    /// Replaces authorization and `UNUserNotificationCenter.add`.
    var _deliverForTesting: ((UNNotificationRequest) -> Void)?
    var _appLockEnabledForTesting: Bool?

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
    /// - Parameter hidesQuestionText: true when the session, its workspace,
    ///   or its server is locked; read when the request is added. Required so
    ///   no caller can forget the scoped lock.
    func notifyAskIfNeeded(
        _ ask: AskRequest,
        activeSessionId: String?,
        hidesQuestionText: @escaping @MainActor () -> Bool
    ) {
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

        // The body is decided when the request is added, not now: App Lock may
        // turn on while authorization is pending, after it removed delivered
        // asks.
        schedule(identifier: AttentionNotificationPolicy.askRequestIdentifier(sessionId: ask.sessionId)) { [self] in
            let payload = AttentionNotificationPolicy.askPayload(
                for: ask,
                revealsQuestionText: !(_appLockEnabledForTesting ?? AppLockService.shared.isEnabled)
                    && !hidesQuestionText()
            )
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
            return content
        }
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

    /// App Lock turned on: remove delivered and pending ask notifications,
    /// which may show question text from before.
    func removeAskNotifications() {
        guard !_skipSchedulingForTesting else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let delivered = await center.deliveredNotifications().map(\.request)
            let pending = await center.pendingNotificationRequests()
            center.removeDeliveredNotifications(withIdentifiers: Self.askIdentifiers(in: delivered))
            center.removePendingNotificationRequests(withIdentifiers: Self.askIdentifiers(in: pending))
        }
    }

    nonisolated static func askIdentifiers(in requests: [UNNotificationRequest]) -> [String] {
        requests
            .filter { $0.content.categoryIdentifier == askCategoryId }
            .map(\.identifier)
    }

    /// Cancel ask notification when the ask is answered or superseded.
    func cancelAskNotification(sessionId: String) {
        let identifier = AttentionNotificationPolicy.askRequestIdentifier(sessionId: sessionId)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func schedule(identifier: String, content: @escaping @MainActor () -> UNNotificationContent) {
        guard !_skipSchedulingForTesting else {
            return
        }

        // Fire immediately (0.1s minimum for time-interval triggers)
        func request() -> UNNotificationRequest {
            UNNotificationRequest(
                identifier: identifier,
                content: content(),
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            )
        }

        Task { @MainActor in
            if let deliver = _deliverForTesting {
                deliver(request())
                return
            }
            guard await ensureAuthorizationForNotification() else {
                return
            }
            do {
                try await UNUserNotificationCenter.current().add(request())
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
