import Foundation
import UserNotifications

/// Opens Oppi's end-to-end-encrypted pushes (protocol/push/spec.md §2.5-§2.6) on this device.
///
/// The outer alert from the relay is fixed text. This extension verifies the server's
/// signature, decrypts with this device's push key, checks freshness and replay, applies App
/// Lock and scoped-lock redaction, and shows the result. Anything that fails a check, or a
/// timeout, shows the fixed fallback: never a field from the failed push.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let presentation = PushNotificationOpening.presentation(
            userInfo: request.content.userInfo,
            now: Date(),
            key: { PushSharedStore.loadKey(keyId: $0)?.material },
            acceptSequence: { PushSharedStore.acceptSequence($0, keyId: $1) },
            redaction: { PushSharedStore.loadRedactionSnapshot() }
        )
        deliver(presentation)
    }

    override func serviceExtensionTimeWillExpire() {
        deliver(.fallback)
    }

    private func deliver(_ presentation: PushAlertPresentation) {
        guard let contentHandler else { return }
        self.contentHandler = nil
        contentHandler(Self.content(for: presentation))
    }

    static func content(for presentation: PushAlertPresentation) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
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
