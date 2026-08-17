import Foundation
import Testing
@testable import Oppi

@Suite("ServerMessageEffects")
struct ServerMessageEffectsTests {
    @Test func terminalStateClearsFocusedSessionUI() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .state(session: makeTestSession(id: "s1", status: .stopped)),
            routedSessionId: "s1",
            isFocusedSession: true
        )

        #expect(effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds == ["s1"])
        #expect(effects.clearExtensionDialogSessionIds == ["s1"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["s1"])
        #expect(effects.clearMessageQueueSessionIds.isEmpty)
    }

    @Test func errorStateClearsUnanswerableUI() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .state(session: makeTestSession(id: "s1", status: .error)),
            routedSessionId: "s1",
            isFocusedSession: true
        )

        #expect(effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds == ["s1"])
        #expect(effects.clearExtensionDialogSessionIds == ["s1"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["s1"])
    }

    @Test func terminalStateForInactiveSessionDoesNotStopFocusedSilenceWatchdog() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .state(session: makeTestSession(id: "s2", status: .stopped)),
            routedSessionId: "s2",
            isFocusedSession: false
        )

        #expect(!effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds == ["s2"])
        #expect(effects.clearExtensionDialogSessionIds == ["s2"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["s2"])
    }

    @Test func terminalStateRoutedThroughParentClearsOnlyPayloadSessionUI() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .state(session: makeTestSession(id: "child", status: .stopped)),
            routedSessionId: "parent",
            isFocusedSession: true
        )

        #expect(!effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds == ["child"])
        #expect(effects.clearExtensionDialogSessionIds == ["child"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["child"])
        #expect(!effects.clearExtensionSurfaceSessionIds.contains("parent"))
    }

    @Test func readyStateKeepsPendingUserInputAndPersistentExtensionSurfaces() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .state(session: makeTestSession(id: "s1", status: .ready)),
            routedSessionId: "s1",
            isFocusedSession: true
        )

        #expect(effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds.isEmpty)
        #expect(effects.clearExtensionDialogSessionIds.isEmpty)
        #expect(effects.clearExtensionSurfaceSessionIds.isEmpty)
    }

    @Test func readySessionSummaryKeepsPendingUserInputAndPersistentExtensionSurfaces() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .sessionSummary(SessionSummary(from: makeTestSession(id: "summary-s1", status: .ready))),
            routedSessionId: "summary-s1",
            isFocusedSession: false
        )

        #expect(effects.clearAskSessionIds.isEmpty)
        #expect(effects.clearExtensionDialogSessionIds.isEmpty)
        #expect(effects.clearExtensionSurfaceSessionIds.isEmpty)
    }

    @Test func terminalSessionSummaryClearsPersistentExtensionSurfaces() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .sessionSummary(SessionSummary(from: makeTestSession(id: "summary-s1", status: .stopped))),
            routedSessionId: "broadcast-key",
            isFocusedSession: false
        )

        #expect(effects.clearAskSessionIds == ["summary-s1"])
        #expect(effects.clearExtensionDialogSessionIds == ["summary-s1"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["summary-s1"])
    }

    @Test func sessionEndedHasFocusedAndInactiveVariants() {
        let focused = ServerMessageEffects.cleanupEffects(
            for: .sessionEnded(reason: "done"),
            routedSessionId: "s1",
            isFocusedSession: true
        )
        #expect(focused.stopSilenceWatchdog)
        #expect(focused.clearAskSessionIds == ["s1"])
        #expect(focused.clearExtensionDialogSessionIds == ["s1"])
        #expect(focused.clearExtensionSurfaceSessionIds == ["s1"])
        #expect(focused.clearMessageQueueSessionIds == ["s1"])

        let inactive = ServerMessageEffects.cleanupEffects(
            for: .sessionEnded(reason: "done"),
            routedSessionId: "s2",
            isFocusedSession: false
        )
        #expect(!inactive.stopSilenceWatchdog)
        #expect(inactive.clearAskSessionIds == ["s2"])
        #expect(inactive.clearExtensionDialogSessionIds == ["s2"])
        #expect(inactive.clearExtensionSurfaceSessionIds == ["s2"])
        #expect(inactive.clearMessageQueueSessionIds.isEmpty)
    }

    @Test func sessionDeletedUsesDeletedSessionId() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .sessionDeleted(sessionId: "deleted"),
            routedSessionId: "broadcast-key",
            isFocusedSession: true
        )

        #expect(effects.clearAskSessionIds == ["deleted"])
        #expect(effects.clearExtensionDialogSessionIds == ["deleted"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["deleted"])
        #expect(effects.clearMessageQueueSessionIds == ["deleted"])
    }

    @Test func stopConfirmedClearsBlockingExtensionDialog() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .stopConfirmed(source: .user, reason: nil),
            routedSessionId: "s1",
            isFocusedSession: true
        )

        #expect(effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds == ["s1"])
        #expect(effects.clearExtensionDialogSessionIds == ["s1"])
        #expect(effects.clearExtensionSurfaceSessionIds.isEmpty)
        #expect(effects.clearMessageQueueSessionIds.isEmpty)
    }

    @Test func appEventStopConfirmedClearsSurfacesAndQueue() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .stopConfirmed(
                sessionId: "s2",
                workspaceId: "w1",
                emittedAt: 1,
                source: "user",
                reason: nil
            )
        )

        #expect(!effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds == ["s2"])
        #expect(effects.clearExtensionDialogSessionIds == ["s2"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["s2"])
        #expect(effects.clearMessageQueueSessionIds == ["s2"])
    }

    @Test func appEventSessionEndedClearsSurfacesAndQueue() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .sessionEnded(
                sessionId: "s2",
                workspaceId: "w1",
                emittedAt: 1,
                reason: "done"
            )
        )

        #expect(!effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds == ["s2"])
        #expect(effects.clearExtensionDialogSessionIds == ["s2"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["s2"])
        #expect(effects.clearMessageQueueSessionIds == ["s2"])
    }

    @Test func appEventSessionDeletedClearsSurfacesAndQueue() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .sessionDeleted(sessionId: "deleted", workspaceId: "w1", emittedAt: 1)
        )

        #expect(effects.clearAskSessionIds == ["deleted"])
        #expect(effects.clearExtensionDialogSessionIds == ["deleted"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["deleted"])
        #expect(effects.clearMessageQueueSessionIds == ["deleted"])
    }

    @Test func appEventFatalErrorClearsSurfacesAndQueue() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .sessionError(
                sessionId: "s2",
                workspaceId: "w1",
                emittedAt: 1,
                message: "boom",
                code: nil,
                fatal: true
            )
        )

        #expect(effects.clearAskSessionIds == ["s2"])
        #expect(effects.clearExtensionDialogSessionIds == ["s2"])
        #expect(effects.clearExtensionSurfaceSessionIds == ["s2"])
        #expect(effects.clearMessageQueueSessionIds == ["s2"])
    }

    @Test func appEventNonFatalErrorKeepsSessionScopedUI() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .sessionError(
                sessionId: "s2",
                workspaceId: "w1",
                emittedAt: 1,
                message: "retry",
                code: nil,
                fatal: false
            )
        )

        #expect(!effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds.isEmpty)
        #expect(effects.clearExtensionDialogSessionIds.isEmpty)
        #expect(effects.clearExtensionSurfaceSessionIds.isEmpty)
        #expect(effects.clearMessageQueueSessionIds.isEmpty)
    }

    @Test func appEventTerminalSummaryDoesNotClearSessionScopedUI() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .sessionSummary(
                sessionId: "s2",
                workspaceId: "w1",
                emittedAt: 1,
                summary: SessionSummary(from: makeTestSession(id: "s2", status: .stopped))
            )
        )

        #expect(effects.clearAskSessionIds.isEmpty)
        #expect(effects.clearExtensionDialogSessionIds.isEmpty)
        #expect(effects.clearExtensionSurfaceSessionIds.isEmpty)
        #expect(effects.clearMessageQueueSessionIds.isEmpty)
    }

    @Test func appEventExtensionUISettledClearsMatchingPendingInteraction() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .extensionUISettled(id: "ui-1", sessionId: "s2", workspaceId: "w1", emittedAt: 2)
        )

        #expect(effects.clearAskRequestIds == ["ui-1"])
        #expect(effects.clearExtensionDialogRequestIds == ["ui-1"])
        #expect(effects.clearAskSessionIds.isEmpty)
        #expect(effects.clearExtensionDialogSessionIds.isEmpty)
        #expect(effects.clearExtensionSurfaceSessionIds.isEmpty)
        #expect(effects.clearMessageQueueSessionIds.isEmpty)
    }

    @Test func extensionUISettledClearsMatchingPendingInteraction() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .extensionUISettled(id: "ui-1", sessionId: "s1"),
            routedSessionId: "s1",
            isFocusedSession: true
        )

        #expect(!effects.stopSilenceWatchdog)
        #expect(effects.clearAskRequestIds == ["ui-1"])
        #expect(effects.clearExtensionDialogRequestIds == ["ui-1"])
        #expect(effects.clearAskSessionIds.isEmpty)
        #expect(effects.clearExtensionDialogSessionIds.isEmpty)
    }

    @Test func simpleMessagesMapToTimelineEvents() {
        #expect(ServerMessageEffects.timelineEvents(for: .agentStart, sessionId: "s1").first?.typeLabel == "agentStart")
        #expect(ServerMessageEffects.timelineEvents(for: .textDelta(delta: "hi"), sessionId: "s1").first?.typeLabel == "textDelta")
        #expect(ServerMessageEffects.timelineEvents(for: .sessionEnded(reason: "done"), sessionId: "s1").first?.typeLabel == "sessionEnded")
    }

    @Test func userMessageEndDoesNotMapToCoalescerEvent() {
        let events = ServerMessageEffects.timelineEvents(
            for: .messageEnd(role: "user", content: "hello"),
            sessionId: "s1"
        )

        #expect(events.isEmpty)
    }

    @Test func extensionRequestMapsToUIEffect() {
        let request = ExtensionUIRequest(
            id: "ext-1",
            sessionId: "s1",
            method: "confirm",
            title: "Title"
        )

        let effects = ServerMessageEffects.uiEffects(
            for: .extensionUIRequest(request),
            isFocusedSession: true
        )

        #expect(effects.extensionRequest?.id == "ext-1")
        #expect(effects.extensionNotification == nil)
        #expect(effects.isFocusedSession)
    }

    @Test func extensionNotificationMapsFocusedFlag() {
        let notification = ExtensionUINotification(
            method: "notify",
            message: "hello",
            notifyType: nil,
            statusKey: nil,
            statusText: nil,
            title: nil,
            text: nil,
            widgetKey: nil,
            widgetLines: nil,
            widgetPlacement: nil
        )

        let effects = ServerMessageEffects.uiEffects(
            for: .extensionUINotification(notification),
            isFocusedSession: false
        )

        #expect(effects.extensionRequest == nil)
        #expect(effects.extensionNotification?.method == "notify")
        #expect(!effects.isFocusedSession)
    }

    @Test func queueStateMapsToQueueApplyEffect() {
        let queue = MessageQueueState(
            version: 2,
            steering: [MessageQueueItem(id: "q1", message: "steer", createdAt: 10)],
            followUp: []
        )

        let effects = ServerMessageEffects.queueEffects(for: .queueState(queue: queue))

        #expect(effects.applyQueueState == queue)
        #expect(effects.queueItemStarted == nil)
    }

    @Test func queueItemStartedMapsToStartedEffect() {
        let item = MessageQueueItem(id: "q1", message: "go", createdAt: 10)

        let effects = ServerMessageEffects.queueEffects(
            for: .queueItemStarted(kind: .steer, item: item, queueVersion: 3)
        )

        #expect(effects.applyQueueState == nil)
        #expect(effects.queueItemStarted?.kind == .steer)
        #expect(effects.queueItemStarted?.item == item)
        #expect(effects.queueItemStarted?.queueVersion == 3)
    }

    @Test func queueCommandResultMapsDecodedQueue() {
        let data: JSONValue = [
            "version": 4,
            "steering": [
                ["id": "q1", "message": "read", "createdAt": 11]
            ],
            "followUp": [],
        ]

        let effects = ServerMessageEffects.queueEffectsForCommandResult(
            command: "get_queue",
            success: true,
            data: data
        )

        #expect(effects.applyQueueState?.version == 4)
        #expect(effects.applyQueueState?.steering.first?.id == "q1")
        #expect(effects.applyQueueState?.steering.first?.message == "read")
    }

    @Test func malformedQueueCommandResultHasNoQueueEffect() {
        let data: JSONValue = ["version": 4, "steering": "bad", "followUp": []]

        let effects = ServerMessageEffects.queueEffectsForCommandResult(
            command: "get_queue",
            success: true,
            data: data
        )

        #expect(effects.isEmpty)
    }

    @Test func nonCleanupMessageHasNoEffects() {
        let effects = ServerMessageEffects.cleanupEffects(
            for: .agentStart,
            routedSessionId: "s1",
            isFocusedSession: true
        )

        #expect(!effects.stopSilenceWatchdog)
        #expect(effects.clearAskSessionIds.isEmpty)
        #expect(effects.clearAskRequestIds.isEmpty)
        #expect(effects.clearExtensionDialogSessionIds.isEmpty)
        #expect(effects.clearExtensionDialogRequestIds.isEmpty)
        #expect(effects.clearExtensionSurfaceSessionIds.isEmpty)
        #expect(effects.clearMessageQueueSessionIds.isEmpty)
    }
}
