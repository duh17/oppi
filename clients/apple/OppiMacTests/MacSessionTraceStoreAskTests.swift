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

        #expect(store.currentAskRequest == request.askRequest)
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

        #expect(store.currentAskRequest == request.askRequest)
        #expect(store.currentAskRequest?.responseEncoding == .extensionSelect)
        #expect(store.currentAskRequest?.questions.first?.id == ExtensionUIRequest.inlineQuestionId)
        #expect(store.currentAskRequest?.questions.first?.options.map(\.value) == ["fast", "careful"])
    }

    @Test func postsAttentionBannerWhenFocusedSessionAskArrivesWhileNotKey() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = false
        service.activeSessionId = "session-1"

        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)

        let request = ExtensionUIRequest(
            id: "ask-bg",
            sessionId: target.sessionId,
            method: "ask",
            askQuestions: [
                AskQuestion(id: "q", question: "Still there?", options: [], multiSelect: false),
            ]
        )
        store.applyServerMessageForTesting(.extensionUIRequest(request), target: target)

        #expect(service._lastScheduledPayloadForTesting?.identifier == "ask-session-1")
        #expect(service._lastScheduledPayloadForTesting?.body == "Still there?")
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

    @Test func editorBlocksLaterAskInServerOrder() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)
        store.applyLiveRuntimeMessage(.extensionUIRequest(ExtensionUIRequest(
            id: "editor", sessionId: target.sessionId, method: "editor", prefill: "Original"
        )), sessionId: target.sessionId)
        store.applyLiveRuntimeMessage(.extensionUIRequest(ExtensionUIRequest(
            id: "later", sessionId: target.sessionId, method: "confirm", title: "Continue?"
        )), sessionId: target.sessionId)
        #expect(store.currentAskRequest == nil, "The earlier editor must own the blocking presentation")
        store.applyLiveRuntimeMessage(.extensionUISettled(id: "editor", sessionId: target.sessionId), sessionId: target.sessionId)
        #expect(store.currentAskRequest?.id == "later")
    }

    @Test func editorHandoffReachesPaneWithoutSubmittingOrDiscardingUserText() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        let pane = MacSessionPaneRuntime(id: MacSessionPaneID(), target: target, traceStore: store)
        pane.composerState.draft = "User draft"
        let notification = ExtensionUINotification(
            method: "set_editor_text", message: nil, notifyType: nil, statusKey: nil,
            statusText: nil, title: nil, text: "Extension text", widgetKey: nil,
            widgetLines: nil, widgetPlacement: nil
        )
        store.applyLiveRuntimeMessage(.extensionUINotification(notification), sessionId: target.sessionId)
        #expect(pane.composerState.draft == "User draft\n\nExtension text")
        #expect(!store.isSending)
        #expect(store.items.isEmpty)
    }

    @Test func toolsExpandedEffectReachesMacRowConsumer() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)
        let notification = ExtensionUINotification(
            method: "setToolsExpanded", message: nil, notifyType: nil, statusKey: nil,
            statusText: nil, title: nil, text: nil, widgetKey: nil,
            widgetLines: nil, widgetPlacement: nil, toolsExpanded: true
        )
        store.applyLiveRuntimeMessage(.extensionUINotification(notification), sessionId: target.sessionId)
        #expect(store.isToolRowExpanded("future-row"))
        store.setToolRowExpanded("future-row", expanded: false)
        #expect(!store.isToolRowExpanded("future-row"), "Local row choice wins until the next extension expansion command")
    }

    @Test func sharedAskStoreRevisionFencesEveryQueueAndPartitionWriter() {
        let store = AskRequestStore()
        let ask = AskRequest(id: "A", sessionId: "s", questions: [], allowCustom: true, timeout: nil)
        let writes: [(String, () -> Void)] = [
            ("insert", { store.set(ask, for: "s") }),
            ("same-ID replay", { store.set(ask, for: "s") }),
            ("workspace snapshot", {
                store.applyWorkspaceSnapshot(workspaceId: "w", asks: [ask], workspaceSessionIds: ["s"])
            }),
            ("settlement", { store.remove(id: "A") }),
            ("session clear", { store.remove(for: "s") }),
            ("partition switch", { store.switchServer(to: "other") }),
        ]
        for (name, write) in writes {
            let revision = store.revision
            write()
            #expect(store.revision != revision, "Snapshot fence must advance after \(name)")
        }
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
