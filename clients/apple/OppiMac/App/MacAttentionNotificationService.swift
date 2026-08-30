import AppKit
import Foundation
import OSLog
import UserNotifications

private let notificationLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "AttentionNotifications"
)

/// Mac painter for local attention banners.
///
/// Posts a UserNotifications banner for an agent ask when the app is not key
/// or the ask belongs to another session. Tapping opens that session.
/// Does not post local session-done/error banners; iOS only posts asks locally.
@MainActor
final class MacAttentionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacAttentionNotificationService()

    /// Called when the user taps an ask notification body.
    var onNavigateToSession: ((String) -> Void)? {
        didSet {
            deliverPendingNavigationTapsIfPossible()
        }
    }

    /// Session whose card is on screen in the main window. Nil in Settings,
    /// Workspaces, utilities, and after the window is torn down.
    var activeSessionId: String?

    var _isAppActiveForTesting: Bool?
    var _skipSchedulingForTesting = false
    var _lastScheduledPayloadForTesting: AttentionNotificationPayload?
    var _cancelledSessionIdsForTesting: [String] = []

    private var pendingNavigationSessionIds: [String] = []
    private var postedAskIdBySession: [String: String] = [:]
    private var didConfigureForLaunch = false

    override private init() {
        super.init()
    }

    func configureForLaunch() {
        guard ReleaseFeatures.localAttentionNotificationsEnabled else {
            return
        }

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

    func notifyAskIfNeeded(_ ask: AskRequest) {
        guard ReleaseFeatures.localAttentionNotificationsEnabled else {
            return
        }
        guard postedAskIdBySession[ask.sessionId] != ask.id else {
            return
        }
        // Remember the ask even when suppressed so reconnect replays do not
        // banner after the user already saw the card in the key session.
        postedAskIdBySession[ask.sessionId] = ask.id

        let shouldNotify = AttentionNotificationPolicy.shouldNotify(
            isAppActive: isAppKey,
            requestSessionId: ask.sessionId,
            activeSessionId: activeSessionId
        )
        guard shouldNotify else {
            return
        }

        schedule(AttentionNotificationPolicy.askPayload(for: ask))
    }

    func cancelAskNotification(sessionId: String) {
        postedAskIdBySession.removeValue(forKey: sessionId)
        _cancelledSessionIdsForTesting.append(sessionId)

        guard !shouldSkipScheduling else {
            return
        }

        let identifier = AttentionNotificationPolicy.askRequestIdentifier(sessionId: sessionId)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func handleNotificationTap(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        guard let onNavigateToSession else {
            pendingNavigationSessionIds.append(sessionId)
            return
        }
        onNavigateToSession(sessionId)
    }

    func resetForTesting() {
        onNavigateToSession = nil
        activeSessionId = nil
        _isAppActiveForTesting = nil
        _skipSchedulingForTesting = true
        _lastScheduledPayloadForTesting = nil
        _cancelledSessionIdsForTesting = []
        pendingNavigationSessionIds = []
        postedAskIdBySession = [:]
    }

    private var isAppKey: Bool {
        if let _isAppActiveForTesting {
            return _isAppActiveForTesting
        }
        return NSApp.isActive && NSApp.keyWindow != nil
    }

    private var shouldSkipScheduling: Bool {
        if _skipSchedulingForTesting {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func schedule(_ payload: AttentionNotificationPayload) {
        _lastScheduledPayloadForTesting = payload

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

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: payload.identifier,
            content: content,
            trigger: trigger
        )

        guard !shouldSkipScheduling else {
            return
        }

        Task { @MainActor in
            guard await ensureAuthorizationForNotification() else {
                return
            }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                notificationLogger.error(
                    "Failed to schedule attention notification: \(error.localizedDescription, privacy: .public)"
                )
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
                notificationLogger.error(
                    "Failed to request notification permission: \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func deliverPendingNavigationTapsIfPossible() {
        guard let onNavigateToSession, !pendingNavigationSessionIds.isEmpty else { return }
        let pendingSessionIds = pendingNavigationSessionIds
        pendingNavigationSessionIds.removeAll()
        for sessionId in pendingSessionIds {
            onNavigateToSession(sessionId)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        if let sessionId = AttentionNotificationPolicy.navigationSessionId(
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        ) {
            Task { @MainActor in
                handleNotificationTap(sessionId: sessionId)
            }
        }

        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        switch notification.request.content.categoryIdentifier {
        case AttentionNotificationPolicy.askCategoryId:
            completionHandler([.banner, .sound])
        default:
            completionHandler([])
        }
    }
}
