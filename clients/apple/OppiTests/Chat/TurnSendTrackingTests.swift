import Testing
import Foundation
@testable import Oppi

@Suite("TurnSendTracking")
@MainActor
struct TurnSendTrackingTests {

    // MARK: - PendingTurnSend

    @Test func pendingTurnSendTracksStages() {
        var observedStages: [TurnAckStage] = []
        let turn = PendingTurnSend(
            command: "prompt",
            requestId: "req1",
            clientTurnId: "turn1",
            onAckStage: { stage in observedStages.append(stage) }
        )

        #expect(turn.latestStage == nil)

        turn.latestStage = .accepted
        turn.notifyStage(.accepted)

        turn.latestStage = .dispatched
        turn.notifyStage(.dispatched)

        #expect(observedStages == [.accepted, .dispatched])
    }

    @Test func pendingTurnSendProperties() {
        let turn = PendingTurnSend(
            command: "steer",
            requestId: "req2",
            clientTurnId: "turn2",
            onAckStage: nil
        )

        #expect(turn.command == "steer")
        #expect(turn.requestId == "req2")
        #expect(turn.clientTurnId == "turn2")
    }

    @Test func resetWaiterCreatesNewWaiter() {
        let turn = PendingTurnSend(
            command: "prompt",
            requestId: "req1",
            clientTurnId: "turn1",
            onAckStage: nil
        )

        let waiter1 = turn.waiter
        turn.resetWaiter()
        let waiter2 = turn.waiter

        #expect(waiter1 !== waiter2)
    }

    // MARK: - SendAckWaiter

    @Test func waiterResolvesBeforeWait() async throws {
        let waiter = SendAckWaiter()

        // Resolve before anyone waits
        waiter.resolve(.success(()))

        // Wait should complete immediately
        try await waiter.wait()
    }

    @Test func waiterResolvesAfterWait() async throws {
        let waiter = SendAckWaiter()

        // Start waiting in a task
        let task = Task { @MainActor in
            try await waiter.wait()
        }

        // Give the wait a moment to register
        try await Task.sleep(for: .milliseconds(10))

        // Resolve
        waiter.resolve(.success(()))

        // Should complete without error
        try await task.value
    }

    @Test func waiterPropagatesError() async {
        let waiter = SendAckWaiter()

        waiter.resolve(.failure(SendAckError.timeout(command: "prompt")))

        do {
            try await waiter.wait()
            Issue.record("Expected error")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
        }
    }

    // MARK: - SendAckError

    @Test func timeoutErrorDescription() {
        let error = SendAckError.timeout(command: "prompt")
        #expect(error.errorDescription == "prompt acknowledgement timed out")
    }

    @Test func rejectedErrorWithReason() {
        let error = SendAckError.rejected(command: "steer", reason: "session not found")
        #expect(error.errorDescription == "steer rejected: session not found")
    }

    @Test func rejectedErrorWithoutReason() {
        let error = SendAckError.rejected(command: "steer", reason: nil)
        #expect(error.errorDescription == "steer rejected")
    }

    @Test func rejectedErrorWithEmptyReason() {
        let error = SendAckError.rejected(command: "prompt", reason: "")
        #expect(error.errorDescription == "prompt rejected")
    }

    @Test func notSubscribedPromptRejectionIsRetryable() {
        let error = SendAckError.rejected(
            command: "prompt",
            reason: "Session WTKeS0ND is not subscribed at level=full"
        )

        #expect(MessageSender.isRetryableTurnSendError(error))
    }

    @Test func ordinaryPromptRejectionIsNotRetryable() {
        let error = SendAckError.rejected(command: "prompt", reason: "session is stopped")

        #expect(!MessageSender.isRetryableTurnSendError(error))
    }

    @Test func notSubscribedPromptWaitsForRecoveryBeforeRetry() async throws {
        let sender = MessageSender()
        sender._sendAckTimeoutForTesting = .seconds(1)

        let harness = NotSubscribedRetryHarness(sender: sender)
        sender.recoverNotSubscribedBeforeRetry = harness.recover(sessionId:)
        sender._sendMessageForTesting = harness.send(message:)

        try await sender.sendPrompt("use gpt-5.4-mini", sessionIdOverride: "child")

        #expect(harness.sentRequestIds.count == 2)
        #expect(harness.recoveryStarted)
        #expect(harness.recoveryFinished)
    }
}

@MainActor
private final class NotSubscribedRetryHarness {
    let sender: MessageSender
    var sentRequestIds: [String] = []
    var recoveryStarted = false
    var recoveryFinished = false

    init(sender: MessageSender) {
        self.sender = sender
    }

    func recover(sessionId: String?) async -> Bool {
        #expect(sessionId == "child")
        recoveryStarted = true
        try? await Task.sleep(for: .milliseconds(50))
        recoveryFinished = true
        return true
    }

    func send(message: ClientMessage) async throws {
        let requestId: String
        switch message {
        case .prompt(_, _, _, let id, _):
            guard let id else {
                Issue.record("Expected prompt requestId")
                return
            }
            requestId = id
        default:
            Issue.record("Expected prompt message")
            return
        }

        sentRequestIds.append(requestId)
        let attempt = sentRequestIds.count
        if attempt == 1 {
            _ = sender.commands.resolveTurnCommandResult(
                command: "prompt",
                requestId: requestId,
                success: false,
                error: "Session child is not subscribed at level=full"
            )
        } else {
            #expect(recoveryStarted)
            #expect(recoveryFinished)
            _ = sender.commands.resolveTurnCommandResult(
                command: "prompt",
                requestId: requestId,
                success: true,
                error: nil
            )
        }
    }
}
