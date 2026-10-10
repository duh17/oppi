import Foundation

/// Locks the Notification Service Extension must honor (spec §2.6). The app writes it to the
/// App Group whenever App Lock or a scoped lock changes; the extension cannot run the app's
/// lock services.
struct PushRedactionSnapshot: Codable, Equatable, Sendable {
    struct Scope: Codable, Hashable, Sendable {
        let serverId: String
        let workspaceId: String?
        let sessionId: String?
    }

    var appLockEnabled: Bool
    /// Every scoped-lock flag: a server, a workspace, or a session.
    var lockedScopes: Set<Scope>

    /// When the snapshot cannot be read, everything is redacted.
    static let unknown = Self(appLockEnabled: true, lockedScopes: [])

    func redacts(serverId: String, plaintext: PushPlaintext) -> Bool {
        if appLockEnabled { return true }
        if lockedScopes.contains(Scope(serverId: serverId, workspaceId: nil, sessionId: nil)) { return true }
        if let workspaceId = plaintext.workspaceId,
           lockedScopes.contains(Scope(serverId: serverId, workspaceId: workspaceId, sessionId: nil)) {
            return true
        }
        return lockedScopes.contains(Scope(serverId: serverId, workspaceId: nil, sessionId: plaintext.sessionId))
    }
}

/// The alert a remote push becomes. Built only from a verified, decrypted plaintext, or the
/// fixed fallback.
struct PushAlertPresentation: Equatable, Sendable {
    enum Interruption: Equatable, Sendable {
        case passive, active, timeSensitive
    }

    let title: String
    let subtitle: String
    let body: String
    let categoryIdentifier: String
    let threadIdentifier: String
    let targetContentIdentifier: String?
    /// Tap routing; never anything the lock would hide.
    let userInfo: [String: String]
    let interruption: Interruption
    let playsSound: Bool

    /// Matches the relay's fixed outer alert (relay/src/core/apns.ts `FALLBACK_ALERT`).
    static let fallbackTitle = "Oppi"
    static let fallbackBody = "You have a new notification."

    /// Shown for anything that fails a check: nothing from the push itself.
    static let fallback = Self(
        title: fallbackTitle,
        subtitle: "",
        body: fallbackBody,
        categoryIdentifier: "",
        threadIdentifier: "",
        targetContentIdentifier: nil,
        userInfo: [:],
        interruption: .active,
        playsSound: false
    )

    static func make(serverId: String, plaintext: PushPlaintext, redacted: Bool) -> Self {
        let fixed = fixedText(event: plaintext.event, kind: plaintext.kind)
        var userInfo = [
            "event": plaintext.event.rawValue,
            "sessionId": plaintext.sessionId,
            "serverId": serverId,
        ]
        if let kind = plaintext.kind { userInfo["kind"] = kind.rawValue }
        if let workspaceId = plaintext.workspaceId { userInfo["workspaceId"] = workspaceId }
        return Self(
            title: redacted ? fixed.title : plaintext.title,
            subtitle: redacted ? "" : (plaintext.subtitle ?? ""),
            body: redacted ? fixed.body : plaintext.body,
            categoryIdentifier: category(for: plaintext.event),
            threadIdentifier: plaintext.sessionId,
            targetContentIdentifier: plaintext.sessionId,
            userInfo: userInfo,
            interruption: interruption(for: plaintext.event),
            playsSound: plaintext.event == .blocked || plaintext.event == .error
        )
    }

    /// Redacted text comes only from `event` and `kind` (spec §2.6).
    static func fixedText(event: PushPlaintext.Event, kind: PushPlaintext.Kind?) -> (title: String, body: String) {
        switch event {
        case .blocked:
            switch kind ?? .question {
            case .permission: (String(localized: "Needs Approval"), String(localized: "Waiting for your approval."))
            case .question: (String(localized: "Question"), String(localized: "Waiting for your answer."))
            case .auth: (String(localized: "Sign-in Needed"), String(localized: "Waiting for you to sign in."))
            }
        case .done: (String(localized: "Session Done"), String(localized: "The run finished."))
        case .error: (String(localized: "Session Error"), String(localized: "Open Oppi to review the session error."))
        case .ended: (String(localized: "Session Ended"), String(localized: "The session ended."))
        }
    }

    private static func category(for event: PushPlaintext.Event) -> String {
        switch event {
        case .blocked: SessionNotificationCategory.sessionBlocked
        case .done, .ended: SessionNotificationCategory.sessionDone
        case .error: SessionNotificationCategory.sessionError
        }
    }

    private static func interruption(for event: PushPlaintext.Event) -> Interruption {
        switch event {
        case .blocked: .timeSensitive
        case .error: .active
        case .done, .ended: .passive
        }
    }
}
