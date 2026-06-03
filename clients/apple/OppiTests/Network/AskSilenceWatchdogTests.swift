import Testing
import Foundation
@testable import Oppi

/// Tests that the silence watchdog does not trigger reconnects while an ask
/// request is pending. The agent blocks waiting for user input, so silence
/// is expected and should not be treated as a broken connection.
@Suite("Ask Card Silence Watchdog")
@MainActor
struct AskSilenceWatchdogTests {

    // MARK: - Helpers

    /// Build an `extensionUIRequest` message with method "ask".
    private func makeAskMessage(
        id: String = "ask-1",
        sessionId: String = "s1"
    ) -> ServerMessage {
        .extensionUIRequest(ExtensionUIRequest(
            id: id,
            sessionId: sessionId,
            method: "ask",
            askQuestions: [
                AskQuestion(
                    id: "q1",
                    question: "Which approach?",
                    options: [
                        AskOption(value: "a", label: "Option A"),
                        AskOption(value: "b", label: "Option B"),
                    ],
                    multiSelect: false
                ),
            ],
            allowCustom: true
        ))
    }

    // MARK: - Tests

    @Test func askRequestStopsSilenceWatchdog() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        // Simulate agent start — watchdog is running
        conn.handleActiveSessionUI(.agentStart, sessionId: "s1")
        #expect(conn.silenceWatchdog.lastEventTime != nil, "Watchdog should be running after agentStart")

        // Receive an ask extensionUIRequest
        conn.handleActiveSessionUI(makeAskMessage(), sessionId: "s1")

        // The ask card should be set
        #expect(conn.activeAskRequest != nil)
        #expect(conn.activeAskRequest?.id == "ask-1")

        // The silence watchdog should be stopped — silence is expected during ask
        #expect(conn.silenceWatchdog.lastEventTime == nil,
                "Watchdog should be stopped when ask is pending (silence is expected)")
    }

    @Test func blockingExtensionRequestStopsWatchdog() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        // Simulate agent start — watchdog is running
        conn.handleActiveSessionUI(.agentStart, sessionId: "s1")
        #expect(conn.silenceWatchdog.lastEventTime != nil)

        // Receive a blocking non-ask extension request (e.g. "select")
        let selectRequest = ExtensionUIRequest(
            id: "ext-1",
            sessionId: "s1",
            method: "select",
            title: "Choose",
            options: ["A", "B"]
        )
        conn.handleActiveSessionUI(.extensionUIRequest(selectRequest), sessionId: "s1")

        // The extension dialog waits for user input, so silence is expected.
        #expect(conn.silenceWatchdog.lastEventTime == nil,
                "Watchdog should stop while a blocking extension request is pending")
    }

    @Test func sessionEndedClearsAskAndStopsWatchdog() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        // Set up running state with ask
        conn.handleActiveSessionUI(.agentStart, sessionId: "s1")
        conn.handleActiveSessionUI(makeAskMessage(), sessionId: "s1")
        #expect(conn.activeAskRequest != nil)

        // Session ends
        conn.handleActiveSessionUI(.sessionEnded(reason: ""), sessionId: "s1")

        #expect(conn.activeAskRequest == nil)
        #expect(conn.silenceWatchdog.lastEventTime == nil)
    }

    @Test func foregroundRecoveryStashesAskBeforeClearing() async {
        let conn = ServerConnection()
        conn.configure(credentials: makeTestCredentials())
        conn._setActiveSessionIdForTesting("s1")
        conn.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1", status: .busy))

        // Set up a pending ask on the active session
        let ask = AskRequest(
            id: "ask-stash",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Q", options: [
                AskOption(value: "a", label: "A"),
            ], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        conn.activeAskRequest = ask
        conn.askRequestStore.set(ask, for: "s1")

        // Simulate foreground recovery with dead stream.
        // reconnectIfNeeded clears activeAskRequest but should stash it first.
        await conn.reconnectIfNeeded()

        // activeAskRequest is cleared during reconnect
        #expect(conn.activeAskRequest == nil)

        // But the ask should be stashed so focusSession() can restore it
        #expect(conn.pendingAskRequests["s1"] != nil,
                "Ask should be stashed in pendingAskRequests during foreground recovery")
        #expect(conn.pendingAskRequests["s1"]?.id == "ask-stash")
        #expect(conn.askRequestStore.pending(for: "s1")?.id == "ask-stash")
    }

    @Test func terminalStateClearsAskAndStopsWatchdog() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        // Set up running state with ask
        conn.handleActiveSessionUI(.agentStart, sessionId: "s1")
        conn.handleActiveSessionUI(makeAskMessage(), sessionId: "s1")
        #expect(conn.activeAskRequest != nil)

        conn.applyFetchedSessionState(makeTestSession(id: "s1", status: .ready))

        #expect(conn.activeAskRequest == nil)
        #expect(conn.silenceWatchdog.lastEventTime == nil)
    }

    @Test func stopConfirmedClearsAskAndStopsWatchdog() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        // Set up running state with ask
        conn.handleActiveSessionUI(.agentStart, sessionId: "s1")
        conn.handleActiveSessionUI(makeAskMessage(), sessionId: "s1")
        #expect(conn.activeAskRequest != nil)

        // Stop confirmed
        conn.handleActiveSessionUI(.stopConfirmed(source: .user, reason: nil), sessionId: "s1")

        #expect(conn.activeAskRequest == nil)
    }
}
