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

private struct PresentationCompletion: @unchecked Sendable {
    private let handler: (UNNotificationPresentationOptions) -> Void
    init(_ handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        self.handler = handler
    }
    func call(_ options: UNNotificationPresentationOptions) {
        handler(options)
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
/// In the foreground, failed-run and agent-message pushes show unless that session is on
/// screen; pairing-approval and device-enrolled pushes always show; Needs-you (blocked)
/// pushes are dropped. Remote APNs registration lives in `PushRegistration`.
@MainActor
final class AttentionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotificationService()

    /// Category ID for agent questions. Tapping opens the owning session.
    nonisolated static let askCategoryId = AttentionNotificationPolicy.askCategoryId

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

    /// The app's one open owner. `AppDelegate` sets it before
    /// `didFinishLaunching` returns, which is when Apple requires this
    /// delegate to be ready, so a tap during launch has its destination.
    weak var opener: AppOpener?

    /// Whether that session's chat on that server is the one the user is in (its focused
    /// stream; a sheet over the chat still counts). A failed run or an agent's message arriving
    /// while Oppi is in front shows unless it is.
    var isSessionOnScreen: ((_ serverId: String, _ sessionId: String) -> Bool)?

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
        serverId: String?,
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
                serverId: serverId,
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

    /// App Lock or a new lock turned on: remove delivered and pending notifications
    /// that may show text from before (ask questions, and session names and agent messages
    /// in decrypted pushes).
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

    /// Every Oppi session notification: local ask banners and decrypted pushes, whose
    /// subtitle is the session name unless a lock was already on when they arrived.
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

    /// Oppi is in front: push fallbacks ("You have a new notification.") leave Notification
    /// Center. They open nothing, and the app now shows whatever they stood for.
    func removeFallbackNotifications() {
        guard !_skipSchedulingForTesting else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let identifiers = Self.fallbackNotificationIdentifiers(
                in: await center.deliveredNotifications().map(\.request)
            )
            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }

    /// Matched by the fixed text, so this also covers the relay's outer alert shown when the
    /// extension never ran.
    nonisolated static func fallbackNotificationIdentifiers(in requests: [UNNotificationRequest]) -> [String] {
        requests
            .filter {
                $0.content.title == PushAlertPresentation.fallbackTitle
                    && $0.content.body == PushAlertPresentation.fallbackBody
            }
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

    /// The user saw these sessions on `serverId`: their notifications leave Notification
    /// Center, as the badge counts down. This matches each notification's session, and its
    /// server when it names one (local banners do not).
    func removeDeliveredNotifications(serverId: String, sessionIds: [String]) {
        guard !_skipSchedulingForTesting else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let delivered = await center.deliveredNotifications().map(\.request)
            let identifiers = Self.sessionNotificationIdentifiers(
                in: delivered,
                serverId: serverId,
                sessionIds: Set(sessionIds)
            )
            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }

    nonisolated static func sessionNotificationIdentifiers(
        in requests: [UNNotificationRequest],
        serverId: String,
        sessionIds: Set<String>
    ) -> [String] {
        requests
            .filter { request in
                let content = request.content
                guard let sessionId = navigationSessionId(
                    categoryIdentifier: content.categoryIdentifier,
                    userInfo: content.userInfo
                ), sessionIds.contains(sessionId) else { return false }
                let notificationServerId = content.userInfo["serverId"] as? String
                return notificationServerId == nil || notificationServerId == serverId
            }
            .map(\.identifier)
    }

    /// Local banners carry the same app icon badge as pushes: the sessions waiting on the user.
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
            do {
                try await UNUserNotificationCenter.current().add(request(
                    badge: AppIconBadgeService.shared.refresh()
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
            #if DEBUG
            // Nobody answers the alert in a unit-test host or an E2E run (E2E dismisses
            // SpringBoard alerts only at launch), and while it is up the pool simulator's scene
            // stays inactive, which fails every later run on that device that needs frames.
            let environment = ProcessInfo.processInfo.environment
            if environment["XCTestConfigurationFilePath"] != nil || environment["PI_E2E_INVITE_URL"] != nil {
                return false
            }
            #endif
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
        defer {
            lifetime.cancel()
            budget.finish()
        }
        guard let approvalId = payload.approvalId, !budget.isExpired else { return }
        guard let opener else {
            notificationLogger.error("Pairing deny has no opener; approval fails closed when the server TTL elapses")
            return
        }
        await opener.denyPairingAndWait(serverId: payload.serverId, approvalId: approvalId)
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

    /// The one open a notification response asks for, or nil when it opens
    /// nothing. Pure, so every payload shape is testable.
    ///
    /// A pairing Deny acts without opening Oppi, so it acts only on an alert the
    /// extension opened, which tags it with that server's push key (`PushActionTag`,
    /// spec §6.1): APNs shows a push that skips the extension as sent, actions and
    /// all. Open and Approve only open Oppi, whose approval sheet shows only what the
    /// server lists.
    nonisolated static func openRequest(
        categoryIdentifier: String,
        actionIdentifier: String,
        userInfo: [String: String],
        pushKey: (Data) -> PushKeyMaterial? = { PushSharedStore.loadKey(keyId: $0)?.material }
    ) -> AppOpenRequest? {
        if let pairing = pairingNotificationPayload(
            categoryIdentifier: categoryIdentifier,
            actionIdentifier: actionIdentifier,
            userInfo: userInfo as [AnyHashable: Any]
        ) {
            if pairing.action == .deny {
                guard let approvalId = pairing.approvalId,
                      PushActionTag.verifies(userInfo, serverId: pairing.serverId, approvalId: approvalId, key: pushKey)
                else { return nil }
            }
            return .pairing(
                serverId: pairing.serverId,
                approvalId: pairing.approvalId,
                action: pairing.action
            )
        }
        guard let sessionId = navigationSessionId(
            categoryIdentifier: categoryIdentifier,
            userInfo: userInfo as [AnyHashable: Any]
        ) else {
            return nil
        }
        return .session(SessionOpen(
            serverId: nonEmptyValue(userInfo["serverId"]),
            sessionId: sessionId,
            workspaceId: nonEmptyValue(userInfo["workspaceId"]),
            origin: .externalURL
        ))
    }

    /// Notification payloads are string property lists; anything else is not
    /// an Oppi open.
    nonisolated static func stringUserInfo(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, let value = value as? String else { continue }
            values[key] = value
        }
        return values
    }

    nonisolated private static func nonEmptyValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Handle taps on local attention notifications.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let request = Self.openRequest(
            categoryIdentifier: content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier,
            userInfo: Self.stringUserInfo(content.userInfo)
        )
        guard let request else {
            if response.actionIdentifier == Self.pairingDenyActionId {
                notificationLogger.error("Pairing Deny ignored: the alert did not come through the push extension")
            }
            completionHandler()
            return
        }
        if case .pairing(let serverId, let approvalId, .deny) = request {
            let completion = NotificationCompletion(completionHandler)
            Task { @MainActor in
                await self.completePairingDeny(
                    PairingNotificationPayload(
                        serverId: serverId,
                        approvalId: approvalId,
                        action: .deny
                    ),
                    completion: completion
                )
            }
            return
        }
        Task { @MainActor in
            self.opener?.open(request)
        }
        completionHandler()
    }

    /// Show local attention notifications even when app is in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        switch content.categoryIdentifier {
        case Self.askCategoryId, Self.pairingApprovalCategoryId:
            completionHandler([.banner, .sound])
        case Self.deviceEnrolledCategoryId:
            completionHandler([.banner])
        case AttentionNotificationPolicy.sessionFailedCategoryId, AttentionNotificationPolicy.agentMessageCategoryId:
            let category = content.categoryIdentifier
            let serverId = content.userInfo["serverId"] as? String
            let sessionId = content.userInfo["sessionId"] as? String
            let completion = PresentationCompletion(completionHandler)
            Task { @MainActor in
                let onScreen = serverId.flatMap { server in
                    sessionId.map { isSessionOnScreen?(server, $0) ?? false }
                } ?? false
                completion.call(
                    AttentionNotificationPolicy.showsInForeground(
                        categoryIdentifier: category,
                        sessionIsOnScreen: onScreen
                    ) ? [.banner, .list, .sound] : []
                )
            }
        default:
            completionHandler([])
        }
    }
}
