import Foundation
import Testing
@testable import Oppi

@Suite("Attention notification policy")
struct AttentionNotificationPolicyTests {
    @Test func notifiesWhenAppIsNotKey() {
        #expect(
            AttentionNotificationPolicy.shouldNotify(
                isAppActive: false,
                requestSessionId: "s1",
                activeSessionId: "s1"
            )
        )
    }

    @Test func notifiesWhenKeyForDifferentSession() {
        #expect(
            AttentionNotificationPolicy.shouldNotify(
                isAppActive: true,
                requestSessionId: "s2",
                activeSessionId: "s1"
            )
        )
    }

    @Test func doesNotNotifyWhenKeyForActiveSession() {
        #expect(
            !AttentionNotificationPolicy.shouldNotify(
                isAppActive: true,
                requestSessionId: "s1",
                activeSessionId: "s1"
            )
        )
    }

    @Test func notifiesWhenKeyWithoutActiveSession() {
        #expect(
            AttentionNotificationPolicy.shouldNotify(
                isAppActive: true,
                requestSessionId: "s1",
                activeSessionId: nil
            )
        )
    }

    @Test func navigationSessionIdReadsAskAndRemoteSessionPayloads() {
        #expect(
            AttentionNotificationPolicy.navigationSessionId(
                categoryIdentifier: AttentionNotificationPolicy.askCategoryId,
                userInfo: ["sessionId": "ask-session"]
            ) == "ask-session"
        )
        #expect(
            AttentionNotificationPolicy.navigationSessionId(
                categoryIdentifier: AttentionNotificationPolicy.sessionDoneCategoryId,
                userInfo: ["sessionId": "ended-session"]
            ) == "ended-session"
        )
        #expect(
            AttentionNotificationPolicy.navigationSessionId(
                categoryIdentifier: AttentionNotificationPolicy.sessionErrorCategoryId,
                userInfo: ["sessionId": "error-session"]
            ) == "error-session"
        )
        #expect(
            AttentionNotificationPolicy.navigationSessionId(
                categoryIdentifier: AttentionNotificationPolicy.askCategoryId,
                userInfo: ["sessionId": "  "]
            ) == nil
        )
        #expect(
            AttentionNotificationPolicy.navigationSessionId(
                categoryIdentifier: "OTHER",
                userInfo: ["sessionId": "ignored"]
            ) == nil
        )
    }

    @Test func askPayloadUsesAskCategoryAndFirstQuestion() {
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "sess-9",
            questions: [
                AskQuestion(id: "q1", question: " Continue? ", options: [], multiSelect: false),
                AskQuestion(id: "q2", question: "Also?", options: [], multiSelect: false),
            ],
            allowCustom: true,
            timeout: nil
        )

        let payload = AttentionNotificationPolicy.askPayload(for: ask)
        #expect(payload.identifier == "ask-sess-9")
        #expect(payload.categoryIdentifier == AttentionNotificationPolicy.askCategoryId)
        #expect(payload.categoryIdentifier != AttentionNotificationPolicy.sessionDoneCategoryId)
        #expect(payload.categoryIdentifier != AttentionNotificationPolicy.sessionErrorCategoryId)
        #expect(payload.body == "Continue?")
        #expect(payload.subtitle == "2 questions")
        #expect(payload.userInfo["kind"] == "ask")
        #expect(payload.userInfo["askId"] == "ask-1")
        #expect(payload.userInfo["sessionId"] == "sess-9")
        #expect(payload.threadIdentifier == "sess-9")
        #expect(payload.targetContentIdentifier == "sess-9")
    }

    @Test func askPayloadFallsBackWhenQuestionIsBlank() {
        let ask = AskRequest(
            id: "ask-blank",
            sessionId: "sess-blank",
            questions: [
                AskQuestion(id: "q1", question: "   ", options: [], multiSelect: false),
            ],
            allowCustom: true,
            timeout: nil
        )

        let payload = AttentionNotificationPolicy.askPayload(for: ask)
        #expect(payload.subtitle == String(localized: "1 question"))
        #expect(payload.body == String(localized: "Open Oppi to answer a question."))
        #expect(payload.title == String(localized: "Question from agent"))
    }
}
