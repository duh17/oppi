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

private struct NotificationCompletion: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
    func call() {
        handler()
    }
}

/// Signals that iOS reclaimed the pairing-deny background budget.
/// One notification Deny: its background task and the notification completion handler.
/// `finish()` runs the handler exactly once and ends the task, on whichever comes first:
/// the deny settled, the background budget expired, or the approval's server lifetime
/// elapsed.
private final class PairingDenyBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var task = UIBackgroundTaskIdentifier.invalid
    private var completion: NotificationCompletion?

    init(completion: NotificationCompletion) {
        self.completion = completion
    }

    func setTask(_ task: UIBackgroundTaskIdentifier) {
        lock.lock()
        if completion == nil {
            // Already finished (budget expired before the task id arrived).
            lock.unlock()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            return
        }
        self.task = task
        lock.unlock()
    }

    func markExpired() {
        lock.lock()
        expired = true
        lock.unlock()
        finish()
    }

    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    func finish() {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        let task = self.task
        self.task = .invalid
        lock.unlock()
        completion?.call()
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }
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

    /// Deny from a notification action. Must not wait for App Lock; the system
    /// action already required device authentication.
    var onPairingDeny: ((PairingNotificationPayload) async -> Void)? {
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

    /// Post the Stopped banner the server skipped: a device holding a live stream gets no
    /// push, and agent keep-alive holds the stream open while the app is in the background.
    /// Only while the app is not active, like the push it replaces.
    /// - Parameters:
    ///   - body: how the run ended (`AttentionNotificationPolicy.stoppedBody`).
    ///   - hidesSessionName: true when a scoped lock covers the session; read when the
    ///     request is added.
    func notifySessionDoneIfNeeded(
        sessionId: String,
        sessionName: String?,
        body: String,
        hidesSessionName: @escaping @MainActor () -> Bool
    ) {
        let appState = _applicationStateForTesting ?? UIApplication.shared.applicationState
        guard appState != .active else { return }

        schedule(identifier: AttentionNotificationPolicy.sessionDoneRequestIdentifier(sessionId: sessionId)) { [self] in
            let payload = AttentionNotificationPolicy.sessionDonePayload(
                sessionId: sessionId,
                sessionName: sessionName,
                body: body,
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
        requests
            .filter { AttentionNotificationPolicy.sessionCategoryIds.contains($0.content.categoryIdentifier) }
            .map(\.identifier)
    }

    /// Pairing banners name a device, not a session. App Lock and a server-scope
    /// lock redact them; workspace and session locks do not.
    nonisolated static func pairingNotificationIdentifiers(
        in requests: [UNNotificationRequest],
        serverId: String? = nil
    ) -> [String] {
        let categories = Set([pairingApprovalCategoryId, deviceEnrolledCategoryId])
        return requests
            .filter { request in
                guard categories.contains(request.content.categoryIdentifier) else { return false }
                guard let serverId else { return true }
                return (request.content.userInfo["serverId"] as? String) == serverId
            }
            .map(\.identifier)
    }

    func removePairingNotifications(serverId: String? = nil) {
        guard !_skipSchedulingForTesting else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let delivered = await center.deliveredNotifications().map(\.request)
            let pending = await center.pendingNotificationRequests()
            center.removeDeliveredNotifications(
                withIdentifiers: Self.pairingNotificationIdentifiers(in: delivered, serverId: serverId)
            )
            center.removePendingNotificationRequests(
                withIdentifiers: Self.pairingNotificationIdentifiers(in: pending, serverId: serverId)
            )
        }
    }

    /// Cancel ask notification when the ask is answered or superseded.
    func cancelAskNotification(sessionId: String) {
        let identifier = AttentionNotificationPolicy.askRequestIdentifier(sessionId: sessionId)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Recount the app icon badge from what is left in Notification Center, after the user
    /// opened or cleared notifications while the app was away.
    func syncBadgeToDelivered() {
        guard !_skipSchedulingForTesting else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let count = await center.deliveredNotifications().count
            try? await center.setBadgeCount(count)
        }
    }

    private func schedule(identifier: String, content: @escaping @MainActor () -> UNMutableNotificationContent) {
        guard !_skipSchedulingForTesting else {
            return
        }

        // Fire immediately (0.1s minimum for time-interval triggers)
        func request(badge: Int? = nil) -> UNNotificationRequest {
            let content = content()
            content.badge = badge.map { NSNumber(value: $0) }
            return UNNotificationRequest(
                identifier: identifier,
                content: content,
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
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications().map(\.request.identifier)
            do {
                try await center.add(request(
                    badge: NotificationBadge.count(deliveredIdentifiers: delivered, adding: identifier)
                ))
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
        if payload.action == .deny {
            if let onPairingDeny {
                Task { await onPairingDeny(payload) }
            } else {
                pendingPairingNotifications.append(payload)
            }
            return
        }
        guard let onPairingNotification else {
            pendingPairingNotifications.append(payload)
            return
        }
        onPairingNotification(payload)
    }

    private func completePairingDeny(
        _ payload: PairingNotificationPayload,
        completion: NotificationCompletion
    ) async {
        let budget = PairingDenyBudget(completion: completion)
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "oppi.pairing.deny") {
            // Pending approvals live for 2 minutes on the server, then expire
            // (fail closed). If this background budget runs out before the deny
            // POST succeeds or 404s, the in-memory retry queue dies with the
            // process. No local persistence layer.
            notificationLogger.error(
                "Pairing deny background budget expired; approval fails closed when the server TTL elapses"
            )
            budget.markExpired()
        }
        budget.setTask(backgroundTask)

        // A foreground app's background task never expires: the approval's server
        // lifetime bounds the callback instead. Nothing can be denied after it.
        let lifetime = Task { @MainActor in
            try? await Task.sleep(for: PairingApprovalController.denyLifetime)
            budget.finish()
        }
        defer { lifetime.cancel() }

        let deadline = ContinuousClock.now + PairingApprovalController.denyLifetime
        while onPairingDeny == nil {
            if budget.isExpired || ContinuousClock.now >= deadline {
                budget.finish()
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let handler = onPairingDeny, !budget.isExpired {
            await handler(payload)
        }
        budget.finish()
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
        guard !pendingPairingNotifications.isEmpty else { return }
        let pending = pendingPairingNotifications
        pendingPairingNotifications.removeAll()
        var leftover: [PairingNotificationPayload] = []
        for payload in pending {
            if payload.action == .deny {
                if let onPairingDeny {
                    Task { await onPairingDeny(payload) }
                } else {
                    leftover.append(payload)
                }
            } else if let onPairingNotification {
                onPairingNotification(payload)
            } else {
                leftover.append(payload)
            }
        }
        pendingPairingNotifications = leftover + pendingPairingNotifications
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
            if pairing.action == .deny {
                let completion = NotificationCompletion(completionHandler)
                Task { @MainActor in
                    await self.completePairingDeny(pairing, completion: completion)
                }
                return
            }
            Task { @MainActor in
                handlePairingNotification(pairing)
            }
            completionHandler()
            return
        }
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
        case Self.askCategoryId, Self.pairingApprovalCategoryId:
            completionHandler([.banner, .sound])
        case Self.deviceEnrolledCategoryId:
            completionHandler([.banner])
        default:
            completionHandler([])
        }
    }
}
