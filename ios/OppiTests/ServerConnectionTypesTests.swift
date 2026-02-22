import Testing

@testable import Oppi

@MainActor
@Suite("ServerConnectionTypes")
struct ServerConnectionTypesTests {

    // MARK: - CommandResultWaiter

    @Test("CommandResultWaiter resolves with success")
    func waiterResolveSuccess() async throws {
        let waiter = CommandResultWaiter()

        Task {
            try await Task.sleep(for: .milliseconds(10))
            waiter.resolve(.success(CommandResultPayload(data: .string("hello"))))
        }

        let result = try await waiter.wait()
        #expect(result.data?.stringValue == "hello")
    }

    @Test("CommandResultWaiter resolves with error")
    func waiterResolveError() async {
        let waiter = CommandResultWaiter()
        waiter.resolve(.failure(CommandRequestError.timeout(command: "test")))

        do {
            _ = try await waiter.wait()
            Issue.record("Expected error")
        } catch {
            #expect(error is CommandRequestError)
        }
    }

    @Test("CommandResultWaiter resolves eagerly before wait")
    func waiterEagerResolve() async throws {
        let waiter = CommandResultWaiter()
        waiter.resolve(.success(CommandResultPayload(data: .number(42))))

        let result = try await waiter.wait()
        #expect(result.data?.numberValue == 42)
    }

    // MARK: - PendingCommand

    @Test("PendingCommand stores command and requestId")
    func pendingCommandInit() {
        let pending = PendingCommand(command: "fork", requestId: "req-1")
        #expect(pending.command == "fork")
        #expect(pending.requestId == "req-1")
    }

    // MARK: - Error Types

    @Test("CommandRequestError.timeout description")
    func commandTimeoutError() {
        let error = CommandRequestError.timeout(command: "get_fork_messages")
        #expect(error.errorDescription?.contains("timed out") == true)
    }

    @Test("CommandRequestError.rejected description with reason")
    func commandRejectedError() {
        let error = CommandRequestError.rejected(command: "fork", reason: "no messages")
        #expect(error.errorDescription?.contains("no messages") == true)
    }

    @Test("CommandRequestError.rejected description without reason")
    func commandRejectedNoReason() {
        let error = CommandRequestError.rejected(command: "fork", reason: nil)
        #expect(error.errorDescription == "fork rejected")
    }

    @Test("ForkRequestError descriptions")
    func forkErrors() {
        #expect(ForkRequestError.turnInProgress.errorDescription?.contains("finish") == true)
        #expect(ForkRequestError.noForkableMessages.errorDescription?.contains("No user messages") == true)
        #expect(ForkRequestError.entryNotForkable.errorDescription?.contains("cannot be forked") == true)
    }

    // MARK: - ForkMessage

    @Test("ForkMessage equality")
    func forkMessageEquality() {
        let a = ForkMessage(entryId: "e1", text: "hello")
        let b = ForkMessage(entryId: "e1", text: "hello")
        let c = ForkMessage(entryId: "e2", text: "hello")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - CommandTracker

    @Test("register and unregister pending command")
    func commandRegistration() {
        let tracker = CommandTracker()
        let pending = PendingCommand(command: "test", requestId: "r1")

        tracker.registerCommand(pending)
        #expect(tracker.pendingCommandsByRequestId["r1"] != nil)

        tracker.unregisterCommand(requestId: "r1")
        #expect(tracker.pendingCommandsByRequestId["r1"] == nil)
    }

    @Test("failAllCommands clears all")
    func failAllCommands() async {
        let tracker = CommandTracker()
        let p1 = PendingCommand(command: "a", requestId: "r1")
        let p2 = PendingCommand(command: "b", requestId: "r2")
        tracker.registerCommand(p1)
        tracker.registerCommand(p2)

        #expect(tracker.pendingCommandsByRequestId.count == 2)

        struct TestError: Error {}
        tracker.failAllCommands(error: TestError())

        #expect(tracker.pendingCommandsByRequestId.isEmpty)
    }

    @Test("isReconnectableSendError identifies WebSocket errors")
    func reconnectableErrors() {
        #expect(CommandTracker.isReconnectableSendError(WebSocketError.notConnected))
        #expect(CommandTracker.isReconnectableSendError(WebSocketError.sendTimeout))
        #expect(CommandTracker.isReconnectableSendError(SendAckError.timeout(command: "prompt")))
        #expect(!CommandTracker.isReconnectableSendError(SendAckError.rejected(command: "prompt", reason: "bad")))
    }
}
