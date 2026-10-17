import Foundation
import os
import UserNotifications

/// Opens Oppi's end-to-end-encrypted pushes (protocol/push/spec.md §2.5-§2.6) on this device.
///
/// The outer alert from the relay is fixed text. This extension verifies the server's
/// signature, decrypts with this device's push key, checks freshness and replay, applies App
/// Lock and scoped-lock redaction, and shows the result. Anything that fails a check, or a
/// timeout, shows the fixed fallback: never a field from the failed push. Each fallback logs
/// its rejection reason, and nothing from the push.
/// The badge is set after counting delivered notifications, on another queue, so the content
/// handler is taken under a lock: whichever of that count or the timeout comes first delivers.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let now = Date()
        let result = PushNotificationOpening.open(
            userInfo: request.content.userInfo,
            now: now,
            key: { PushSharedStore.loadKey(keyId: $0)?.material },
            acceptMessage: { PushSharedStore.acceptMessage($0, keyId: $1, now: now) }
        )
        if case .failure(let reason) = result {
            PushSharedStore.logger.notice("Push shown as fallback: \(reason.rawValue, privacy: .public)")
        }
        let presentation = PushNotificationOpening.presentation(
            for: result,
            redaction: { PushSharedStore.loadRedactionSnapshot() }
        )
        let identifier = request.identifier
        UNUserNotificationCenter.current().getDeliveredNotifications { [self] delivered in
            deliver(presentation, badge: NotificationBadge.count(
                deliveredIdentifiers: delivered.map(\.request.identifier),
                adding: identifier
            ))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if deliver(.fallback, badge: nil) {
            PushSharedStore.logger.notice("Push shown as fallback: timeout")
        }
    }

    /// `badge` nil leaves the app icon badge as it is. False when already delivered.
    @discardableResult
    private func deliver(_ presentation: PushAlertPresentation, badge: Int?) -> Bool {
        lock.lock()
        let contentHandler = contentHandler
        self.contentHandler = nil
        lock.unlock()
        guard let contentHandler else { return false }
        contentHandler(Self.content(for: presentation, badge: badge))
        return true
    }

    static func content(for presentation: PushAlertPresentation, badge: Int?) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.badge = badge.map { NSNumber(value: $0) }
        content.title = presentation.title
        content.subtitle = presentation.subtitle
        content.body = presentation.body
        content.categoryIdentifier = presentation.categoryIdentifier
        content.threadIdentifier = presentation.threadIdentifier
        content.targetContentIdentifier = presentation.targetContentIdentifier
        content.userInfo = presentation.userInfo
        content.interruptionLevel = switch presentation.interruption {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        }
        content.sound = presentation.playsSound ? .default : nil
        return content
    }
}
