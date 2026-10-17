import Foundation

/// The Notification Service Extension's decision for one push, with its storage injected so
/// tests run the same path: open the envelope, check replay, redact, or fall back.
enum PushNotificationOpening {
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

    /// The app icon badge for this push: its session joins the stored sessions owing a look
    /// (`SessionBadge`), and the badge is their count. Nil leaves the badge as it is: a push
    /// that failed a check, a pairing push, or stored state that could not be updated.
    /// `updateBadge` applies the change to the stored set and returns the result.
    static func badge(
        for result: Result<OpenedPushEnvelope, PushEnvelopeRejection>,
        updateBadge: ((inout SessionBadge) -> Void) -> SessionBadge?
    ) -> Int? {
        guard case .success(let opened) = result,
              let key = SessionBadge.key(serverId: opened.serverId, plaintext: opened.plaintext) else {
            return nil
        }
        return updateBadge { $0.insert(key) }?.count
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
