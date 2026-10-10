import Foundation

/// The Notification Service Extension's decision for one push, with its storage injected so
/// tests run the same path: open the envelope, check replay, redact, or fall back.
enum PushNotificationOpening {
    static func presentation(
        userInfo: [AnyHashable: Any],
        now: Date,
        key: (Data) -> PushKeyMaterial?,
        acceptSequence: (UInt64, Data) -> Bool,
        redaction: () -> PushRedactionSnapshot
    ) -> PushAlertPresentation {
        switch open(userInfo: userInfo, now: now, key: key, acceptSequence: acceptSequence) {
        case .success(let opened):
            let redacted = redaction().redacts(serverId: opened.serverId, plaintext: opened.plaintext)
            return PushAlertPresentation.make(serverId: opened.serverId, plaintext: opened.plaintext, redacted: redacted)
        case .failure:
            return .fallback
        }
    }

    static func open(
        userInfo: [AnyHashable: Any],
        now: Date,
        key: (Data) -> PushKeyMaterial?,
        acceptSequence: (UInt64, Data) -> Bool
    ) -> Result<OpenedPushEnvelope, PushEnvelopeRejection> {
        guard let envelope = userInfo["e"] as? String else { return .failure(.size) }
        do {
            let opened = try PushEnvelopeOpener.open(base64url: envelope, now: now, key: key)
            guard acceptSequence(opened.plaintext.seq, opened.keyId) else { return .failure(.replay) }
            return .success(opened)
        } catch {
            return .failure(error)
        }
    }
}
