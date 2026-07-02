import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session trace ask handling")
struct MacSessionTraceStoreAskTests {
    @Test func storesAndClearsFocusedAskRequests() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)

        let request = ExtensionUIRequest(
            id: "ask-1",
            sessionId: target.sessionId,
            method: "ask",
            timeout: 30_000,
            workspaceId: target.workspaceId,
            askQuestions: [
                AskQuestion(
                    id: "q1",
                    question: "Choose?",
                    options: [AskOption(value: "yes", label: "Yes")],
                    multiSelect: false
                ),
            ],
            allowCustom: false
        )

        store.applyServerMessageForTesting(.extensionUIRequest(request), target: target)

        #expect(store.currentAskRequest?.id == "ask-1")
        #expect(store.currentAskRequest?.questions.first?.question == "Choose?")
        #expect(store.currentAskRequest?.allowCustom == false)

        store.applyServerMessageForTesting(
            .extensionUISettled(id: "ask-1", sessionId: target.sessionId),
            target: target
        )

        #expect(store.currentAskRequest == nil)
    }

    @Test func mapsInlineSelectRequestsToAskCardState() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)

        let request = ExtensionUIRequest(
            id: "select-1",
            sessionId: target.sessionId,
            method: "select",
            title: "Choose model",
            options: ["fast", "careful"]
        )

        store.applyServerMessageForTesting(.extensionUIRequest(request), target: target)

        #expect(store.currentAskRequest?.responseEncoding == .extensionSelect)
        #expect(store.currentAskRequest?.questions.first?.id == MacAskResponseEncoder.inlineQuestionId)
        #expect(store.currentAskRequest?.questions.first?.options.map(\.value) == ["fast", "careful"])
    }

    @Test func ignoresAskRequestsForOtherSessions() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)

        let request = ExtensionUIRequest(
            id: "ask-other",
            sessionId: "other-session",
            method: "ask",
            askQuestions: [
                AskQuestion(id: "q", question: "Other?", options: [], multiSelect: false),
            ]
        )

        store.applyServerMessageForTesting(.extensionUIRequest(request), target: target)

        #expect(store.currentAskRequest == nil)
    }

    private func makeTarget() -> MacSelectedSessionTarget {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(
            id: "session-1",
            workspaceId: "workspace-1",
            workspaceName: "Workspace",
            status: .busy,
            createdAt: now,
            lastActivity: now,
            model: "provider/model",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello"
        )
        return MacSelectedSessionTarget(
            workspaceId: "workspace-1",
            sessionId: "session-1",
            summary: SessionSummary(from: session)
        )
    }
}
