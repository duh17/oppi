import Foundation

/// UIKit-free attention-notification policy shared by iOS and Mac painters.
///
/// Local banners exist for agent asks. `SESSION_DONE` / `SESSION_ERROR` are
/// tap-routing categories for remote payloads; this policy does not build
/// local session-ended banners because iOS does not post those locally.
enum AttentionNotificationPolicy: Sendable {
    static let askCategoryId = "ASK_REQUEST"
    static let sessionDoneCategoryId = "SESSION_DONE"
    static let sessionErrorCategoryId = "SESSION_ERROR"

    static let sessionCategoryIds = [
        askCategoryId,
        sessionDoneCategoryId,
        sessionErrorCategoryId,
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
        switch categoryIdentifier {
        case askCategoryId, sessionDoneCategoryId, sessionErrorCategoryId:
            break
        default:
            return nil
        }
        guard let sessionId = userInfo["sessionId"] as? String else {
            return nil
        }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func askRequestIdentifier(sessionId: String) -> String {
        "ask-\(sessionId)"
    }

    static func askPayload(for ask: AskRequest) -> AttentionNotificationPayload {
        let questionCount = ask.questions.count
        let firstQuestion = ask.questions.first?.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBody = questionCount == 1
            ? String(localized: "Open Oppi to answer a question.")
            : String(localized: "Open Oppi to answer questions.")
        let body: String
        if let firstQuestion, !firstQuestion.isEmpty {
            body = firstQuestion
        } else {
            body = fallbackBody
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
