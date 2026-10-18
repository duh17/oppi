import Foundation

/// UIKit-free attention-notification policy shared by iOS and Mac painters.
///
/// Local banners exist only for agent asks. Every other session alert is a server push
/// (`SESSION_BLOCKED`, `SESSION_FAILED`, `AGENT_MESSAGE`), and these categories also route its tap.
enum AttentionNotificationPolicy: Sendable {
    static let askCategoryId = SessionNotificationCategory.ask
    static let sessionBlockedCategoryId = SessionNotificationCategory.sessionBlocked
    static let sessionFailedCategoryId = SessionNotificationCategory.sessionFailed
    static let agentMessageCategoryId = SessionNotificationCategory.agentMessage

    static let sessionCategoryIds = [
        askCategoryId,
        sessionBlockedCategoryId,
        sessionFailedCategoryId,
        agentMessageCategoryId,
    ]

    /// The server pushes a failed run and an agent's message to every device, even one with
    /// Oppi open, so the app shows them unless that session's chat is on screen.
    static func showsInForeground(categoryIdentifier: String, sessionIsOnScreen: Bool) -> Bool {
        (categoryIdentifier == sessionFailedCategoryId || categoryIdentifier == agentMessageCategoryId)
            && !sessionIsOnScreen
    }

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
