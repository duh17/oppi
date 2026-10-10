import Foundation

/// UIKit-free attention-notification policy shared by iOS and Mac painters.
///
/// Local banners exist for agent asks, and for `done` while the app runs in the
/// background on a server that pushes: that server skips its push to a device
/// holding a live stream. `SESSION_DONE` / `SESSION_ERROR` / `SESSION_BLOCKED`
/// are also the tap-routing categories for remote session-event payloads
/// (ended, done, error, blocked).
enum AttentionNotificationPolicy: Sendable {
    static let askCategoryId = SessionNotificationCategory.ask
    static let sessionDoneCategoryId = SessionNotificationCategory.sessionDone
    static let sessionErrorCategoryId = SessionNotificationCategory.sessionError
    static let sessionBlockedCategoryId = SessionNotificationCategory.sessionBlocked

    static let sessionCategoryIds = [
        askCategoryId,
        sessionDoneCategoryId,
        sessionErrorCategoryId,
        sessionBlockedCategoryId,
    ]

    static func shouldNotify(
        isAppActive: Bool,
        requestSessionId: String,
        activeSessionId: String?
    ) -> Bool {
        guard isAppActive else {
            return true
        }
        return requestSessionId != activeSessionId
    }

    /// Session id carried by a local ask banner or a remote session-event push.
    static func navigationSessionId(
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> String? {
        guard sessionCategoryIds.contains(categoryIdentifier) else { return nil }
        guard let sessionId = userInfo["sessionId"] as? String else {
            return nil
        }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func askRequestIdentifier(sessionId: String) -> String {
        "ask-\(sessionId)"
    }

    static func sessionDoneRequestIdentifier(sessionId: String) -> String {
        "done-\(sessionId)"
    }

    /// A store update that moves a top-level session into `done`, matching the server's
    /// `done` push rule: delegated sessions report to their parent, and a first-seen status
    /// is not a transition.
    static func enteredDone(previous: Session?, current: Session) -> Bool {
        guard current.parentSessionId == nil,
              current.programStatus?.state == .done,
              let previousState = previous?.programStatus?.state else {
            return false
        }
        return previousState != .done
    }

    /// Local stand-in for the server's `done` push: same title, body, category, and
    /// payload keys. The push names the session; this banner hides the name while App Lock
    /// or a scoped lock covers it, like ask banners.
    static func sessionDonePayload(
        sessionId: String,
        sessionName: String?,
        revealsSessionName: Bool
    ) -> AttentionNotificationPayload {
        let name = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AttentionNotificationPayload(
            identifier: sessionDoneRequestIdentifier(sessionId: sessionId),
            title: String(localized: "Session Done"),
            subtitle: revealsSessionName ? name : "",
            body: String(localized: "The run finished."),
            categoryIdentifier: sessionDoneCategoryId,
            userInfo: [
                "event": "done",
                "sessionId": sessionId,
            ],
            threadIdentifier: sessionId,
            targetContentIdentifier: sessionId
        )
    }

    /// Body that names no question text.
    static func redactedAskBody(questionCount: Int) -> String {
        questionCount == 1
            ? String(localized: "Open Oppi to answer a question.")
            : String(localized: "Open Oppi to answer questions.")
    }

    /// - Parameter revealsQuestionText: false while iOS App Lock is on, so the
    ///   banner, Lock Screen, and Notification Center never show the question.
    static func askPayload(for ask: AskRequest, revealsQuestionText: Bool = true) -> AttentionNotificationPayload {
        let questionCount = ask.questions.count
        let firstQuestion = ask.questions.first?.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if revealsQuestionText, let firstQuestion, !firstQuestion.isEmpty {
            body = firstQuestion
        } else {
            body = redactedAskBody(questionCount: questionCount)
        }

        return AttentionNotificationPayload(
            identifier: askRequestIdentifier(sessionId: ask.sessionId),
            title: String(localized: "Question from agent"),
            subtitle: questionCount == 1 ? String(localized: "1 question") : "\(questionCount) questions",
            body: body,
            categoryIdentifier: askCategoryId,
            userInfo: [
                "kind": "ask",
                "askId": ask.id,
                "sessionId": ask.sessionId,
            ],
            threadIdentifier: ask.sessionId,
            targetContentIdentifier: ask.sessionId
        )
    }
}

struct AttentionNotificationPayload: Equatable, Sendable {
    let identifier: String
    let title: String
    let subtitle: String
    let body: String
    let categoryIdentifier: String
    let userInfo: [String: String]
    let threadIdentifier: String
    let targetContentIdentifier: String
}
