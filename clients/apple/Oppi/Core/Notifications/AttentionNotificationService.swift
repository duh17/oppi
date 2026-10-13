import Foundation
import UserNotifications
import UIKit
import OSLog

private let notificationLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "AttentionNotifications")

enum PairingNotificationAction: Equatable, Sendable {
    case open
    case approve
    case deny
}

/// Manages local notifications for attention requests received while the app is running.
///
/// Fires ask alerts when:
/// - App is backgrounded/inactive (lock screen/banner)
/// - App is foregrounded but the request is for a different session
///
/// This keeps agent questions and extension prompts visible while working across sessions.
/// It also posts the `done` banner a pushing server skips while this device holds a live
/// stream in the background. Remote APNs registration lives in `PushRegistration`.
@MainActor
final class AttentionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotificationService()

    /// Category ID for agent questions. Tapping opens the owning session.
    nonisolated static let askCategoryId = AttentionNotificationPolicy.askCategoryId

    /// Remote session-ended and session-done alerts, and the local `done` banner while
    /// backgrounded. Tapping opens the owning session.
    nonisolated static let sessionDoneCategoryId = AttentionNotificationPolicy.sessionDoneCategoryId

    /// Remote session-error alerts. Tapping opens the owning session.
    nonisolated static let sessionErrorCategoryId = AttentionNotificationPolicy.sessionErrorCategoryId

    /// Remote alerts for a session waiting on approval, an answer, or a sign-in. Tapping opens the owning session.
    nonisolated static let sessionBlockedCategoryId = AttentionNotificationPolicy.sessionBlockedCategoryId

    nonisolated static let pairingApprovalCategoryId = SessionNotificationCategory.pairingApproval
    nonisolated static let deviceEnrolledCategoryId = SessionNotificationCategory.deviceEnrolled
    nonisolated static let pairingApproveActionId = "PAIRING_APPROVE"
    nonisolated static let pairingDenyActionId = "PAIRING_DENY"

    struct PairingNotificationPayload: Equatable, Sendable {
        let serverId: String
        let approvalId: String?
        let action: PairingNotificationAction
    }

    /// Called when the user taps an ask notification body.
    /// Navigate to the session containing this ask request.
    var onNavigateToSession: ((String) -> Void)? {
        didSet {
            deliverPendingNavigationTapsIfPossible()
        }
    }

    var onPairingNotification: ((PairingNotificationPayload) -> Void)? {
        didSet {
            deliverPendingPairingNotificationsIfPossible()
        }
    }

    // Taps can arrive before OppiApp finishes wiring its navigation handler on
    // cold launch. Keep them app-layer agnostic here and deliver them once wired.
    private var pendingNavigationSessionIds: [String] = []
    private var pendingPairingNotifications: [PairingNotificationPayload] = []

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
        let approve = UNNotificationAction(
            identifier: Self.pairingApproveActionId,
            title: String(localized: "Approve"),
            options: [.authenticationRequired, .foreground]
        )
        let deny = UNNotificationAction(
            identifier: Self.pairingDenyActionId,
            title: String(localized: "Deny"),
            options: [.destructive, .authenticationRequired]
        )
        let pairingApproval = UNNotificationCategory(
            identifier: Self.pairingApprovalCategoryId,
            actions: [approve, deny],
            intentIdentifiers: []
        )
        let deviceEnrolled = UNNotificationCategory(
            identifier: Self.deviceEnrolledCategoryId,
            actions: [],
            intentIdentifiers: []
        )

        center.setNotificationCategories(Set(sessionCategories + [pairingApproval, deviceEnrolled]))
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

    /// Post the `done` banner the server skipped: a device holding a live stream gets no
    /// push, and agent keep-alive holds the stream open while the app is in the background.
    /// Only while the app is not active, like the push it replaces.
    /// - Parameter hidesSessionName: true when a scoped lock covers the session; read when
    ///   the request is added.
    func notifySessionDoneIfNeeded(
        sessionId: String,
        sessionName: String?,
        hidesSessionName: @escaping @MainActor () -> Bool
    ) {
        let appState = _applicationStateForTesting ?? UIApplication.shared.applicationState
        guard appState != .active else { return }

        schedule(identifier: AttentionNotificationPolicy.sessionDoneRequestIdentifier(sessionId: sessionId)) { [self] in
            let payload = AttentionNotificationPolicy.sessionDonePayload(
                sessionId: sessionId,
                sessionName: sessionName,
                revealsSessionName: !(_appLockEnabledForTesting ?? AppLockService.shared.isEnabled)
                    && !hidesSessionName()
            )
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.subtitle = payload.subtitle
            content.body = payload.body
            content.categoryIdentifier = payload.categoryIdentifier
            content.userInfo = payload.userInfo
            content.threadIdentifier = payload.threadIdentifier
            content.targetContentIdentifier = payload.targetContentIdentifier
            content.interruptionLevel = .passive
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

    /// App Lock or a new lock turned on: remove delivered and pending notifications
    /// that may show text from before (ask questions, session names in local `done`
    /// banners and in decrypted pushes).
    func removeLockSensitiveNotifications() {
        guard !_skipSchedulingForTesting else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let delivered = await center.deliveredNotifications().map(\.request)
            let pending = await center.pendingNotificationRequests()
            center.removeDeliveredNotifications(withIdentifiers: Self.lockSensitiveIdentifiers(in: delivered))
            center.removePendingNotificationRequests(withIdentifiers: Self.lockSensitiveIdentifiers(in: pending))
        }
    }

    /// Every Oppi session notification: local ask and `done` banners, and decrypted pushes,
    /// whose subtitle is the session name unless a lock was already on when they arrived.
    nonisolated static func lockSensitiveIdentifiers(in requests: [UNNotificationRequest]) -> [String] {
        let categories = Set(AttentionNotificationPolicy.sessionCategoryIds + [
            pairingApprovalCategoryId,
            deviceEnrolledCategoryId,
        ])
        return requests
            .filter { categories.contains($0.content.categoryIdentifier) }
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
            guard await notificationsAuthorized() else {
                return
            }
            do {
                try await UNUserNotificationCenter.current().add(request())
            } catch {
                notificationLogger.error("Failed to schedule attention notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The app's one notification-permission prompt, for local banners and push registration:
    /// asks on first use, true when alerts may show.
    func notificationsAuthorized() async -> Bool {
        #if DEBUG
        // Screenshot previews must not raise the system permission alert.
        if ScreenshotPreviewConfig.isEnabled { return false }
        #endif
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

    func handlePairingNotification(_ payload: PairingNotificationPayload) {
        guard !payload.serverId.isEmpty else { return }
        guard let onPairingNotification else {
            pendingPairingNotifications.append(payload)
            return
        }
        onPairingNotification(payload)
    }

    private func deliverPendingNavigationTapsIfPossible() {
        guard let onNavigateToSession, !pendingNavigationSessionIds.isEmpty else { return }
        let pendingSessionIds = pendingNavigationSessionIds
        pendingNavigationSessionIds.removeAll()
        for sessionId in pendingSessionIds {
            onNavigateToSession(sessionId)
        }
    }

    private func deliverPendingPairingNotificationsIfPossible() {
        guard let onPairingNotification, !pendingPairingNotifications.isEmpty else { return }
        let pending = pendingPairingNotifications
        pendingPairingNotifications.removeAll()
        for payload in pending {
            onPairingNotification(payload)
        }
    }

    nonisolated static func pairingNotificationPayload(
        categoryIdentifier: String,
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> PairingNotificationPayload? {
        guard categoryIdentifier == pairingApprovalCategoryId else { return nil }
        guard let serverId = userInfo["serverId"] as? String else { return nil }
        let trimmedServer = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else { return nil }
        let approvalId = (userInfo["approvalId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let action: PairingNotificationAction
        switch actionIdentifier {
        case pairingApproveActionId:
            action = .approve
        case pairingDenyActionId:
            action = .deny
        default:
            action = .open
        }
        return PairingNotificationPayload(
            serverId: trimmedServer,
            approvalId: approvalId?.isEmpty == false ? approvalId : nil,
            action: action
        )
    }

    /// Handle taps on local attention notifications.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        if let pairing = Self.pairingNotificationPayload(
            categoryIdentifier: content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier,
            userInfo: content.userInfo
        ) {
            Task { @MainActor in
                handlePairingNotification(pairing)
            }
        } else if let sessionId = Self.navigationSessionId(
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
        case Self.askCategoryId, Self.pairingApprovalCategoryId:
            completionHandler([.banner, .sound])
        case Self.deviceEnrolledCategoryId:
            completionHandler([.banner])
        default:
            completionHandler([])
        }
    }
}
