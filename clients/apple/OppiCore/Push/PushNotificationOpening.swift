import Foundation

/// The Notification Service Extension's decision for one push, with its storage injected so
/// tests run the same path: open the envelope, check replay, redact, or fall back.
enum PushNotificationOpening {
    static func presentation(
        userInfo: [AnyHashable: Any],
        now: Date,
        key: (Data) -> PushKeyMaterial?,
        acceptMessage: (_ messageId: Data, _ keyId: Data) -> Bool,
        redaction: () -> PushRedactionSnapshot
    ) -> PushAlertPresentation {
        presentation(
            for: open(userInfo: userInfo, now: now, key: key, acceptMessage: acceptMessage),
            redaction: redaction
        )
    }

    static func presentation(
        for result: Result<OpenedPushEnvelope, PushEnvelopeRejection>,
        redaction: () -> PushRedactionSnapshot
    ) -> PushAlertPresentation {
        switch result {
        case .success(let opened):
            let redacted = redaction().redacts(serverId: opened.serverId, plaintext: opened.plaintext)
            return PushAlertPresentation.make(serverId: opened.serverId, plaintext: opened.plaintext, redacted: redacted)
        case .failure:
            return .fallback
        }
    }

    /// Steps 1-7 of spec §2.5. `acceptMessage` records the message id for the key and
    /// answers false for a replay or when replay state cannot be saved.
    static func open(
        userInfo: [AnyHashable: Any],
        now: Date,
        key: (Data) -> PushKeyMaterial?,
        acceptMessage: (_ messageId: Data, _ keyId: Data) -> Bool
    ) -> Result<OpenedPushEnvelope, PushEnvelopeRejection> {
        guard let envelope = userInfo["e"] as? String else { return .failure(.size) }
        do {
            let opened = try PushEnvelopeOpener.open(base64url: envelope, now: now, key: key)
            guard acceptMessage(opened.messageId, opened.keyId) else { return .failure(.replay) }
            return .success(opened)
        } catch {
            return .failure(error)
        }
    }
}
