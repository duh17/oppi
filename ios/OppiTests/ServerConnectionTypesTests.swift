import Testing

@testable import Oppi

@MainActor
@Suite("ServerConnectionTypes")
struct ServerConnectionTypesTests {

    // MARK: - RPCResultWaiter

    @Test("RPCResultWaiter resolves with success")
    func waiterResolveSuccess() async throws {
        let waiter = RPCResultWaiter()

        Task {
            try await Task.sleep(for: .milliseconds(10))
            waiter.resolve(.success(RPCResultPayload(data: .string("hello"))))
        }

        let result = try await waiter.wait()
        #expect(result.data?.stringValue == "hello")
    }

    @Test("RPCResultWaiter resolves with error")
    func waiterResolveError() async {
        let waiter = RPCResultWaiter()
        waiter.resolve(.failure(RPCRequestError.timeout(command: "test")))

        do {
            _ = try await waiter.wait()
            Issue.record("Expected error")
        } catch {
            #expect(error is RPCRequestError)
        }
    }

    @Test("RPCResultWaiter resolves eagerly before wait")
    func waiterEagerResolve() async throws {
        let waiter = RPCResultWaiter()
        waiter.resolve(.success(RPCResultPayload(data: .number(42))))

        let result = try await waiter.wait()
        #expect(result.data?.numberValue == 42)
    }

    // MARK: - PendingRPCRequest

    @Test("PendingRPCRequest stores command and requestId")
    func pendingRPCInit() {
        let pending = PendingRPCRequest(command: "fork", requestId: "req-1")
        #expect(pending.command == "fork")
        #expect(pending.requestId == "req-1")
    }

    // MARK: - Error Types

    @Test("RPCRequestError.timeout description")
    func rpcTimeoutError() {
        let error = RPCRequestError.timeout(command: "get_fork_messages")
        #expect(error.errorDescription?.contains("timed out") == true)
    }

    @Test("RPCRequestError.rejected description with reason")
    func rpcRejectedError() {
        let error = RPCRequestError.rejected(command: "fork", reason: "no messages")
        #expect(error.errorDescription?.contains("no messages") == true)
    }

    @Test("RPCRequestError.rejected description without reason")
    func rpcRejectedNoReason() {
        let error = RPCRequestError.rejected(command: "fork", reason: nil)
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

    // MARK: - Registration Helpers

    @Test("register and unregister pending RPC request")
    func rpcRegistration() {
        let conn = ServerConnection()
        let pending = PendingRPCRequest(command: "test", requestId: "r1")

        conn.registerPendingRPCRequest(pending)
        #expect(conn.pendingRPCRequestsByRequestId["r1"] != nil)

        conn.unregisterPendingRPCRequest(requestId: "r1")
        #expect(conn.pendingRPCRequestsByRequestId["r1"] == nil)
    }

    @Test("failPendingRPCRequests clears all")
    func failAllRPC() async {
        let conn = ServerConnection()
        let p1 = PendingRPCRequest(command: "a", requestId: "r1")
        let p2 = PendingRPCRequest(command: "b", requestId: "r2")
        conn.registerPendingRPCRequest(p1)
        conn.registerPendingRPCRequest(p2)

        #expect(conn.pendingRPCRequestsByRequestId.count == 2)

        struct TestError: Error {}
        conn.failPendingRPCRequests(error: TestError())

        #expect(conn.pendingRPCRequestsByRequestId.isEmpty)
    }

    @Test("isReconnectableSendError identifies WebSocket errors")
    func reconnectableErrors() {
        #expect(ServerConnection.isReconnectableSendError(WebSocketError.notConnected))
        #expect(ServerConnection.isReconnectableSendError(WebSocketError.sendTimeout))
        #expect(ServerConnection.isReconnectableSendError(SendAckError.timeout(command: "prompt")))
        #expect(!ServerConnection.isReconnectableSendError(SendAckError.rejected(command: "prompt", reason: "bad")))
    }
}
