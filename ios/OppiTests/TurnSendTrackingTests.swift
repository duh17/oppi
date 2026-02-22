import Testing
import Foundation
@testable import Oppi

@Suite("TurnSendTracking")
struct TurnSendTrackingTests {

    // MARK: - PendingTurnSend

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
    @Test func waiterResolvesBeforeWait() async throws {
        let waiter = SendAckWaiter()

        // Resolve before anyone waits
        waiter.resolve(.success(()))

        // Wait should complete immediately
        try await waiter.wait()
    }

    @MainActor
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

    @MainActor
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
}
