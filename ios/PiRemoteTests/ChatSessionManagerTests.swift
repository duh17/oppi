import Foundation
import Testing
@testable import PiRemote

@Suite("ChatSessionManager")
struct ChatSessionManagerTests {

    @MainActor
    @Test func initialState() {
        let manager = ChatSessionManager(sessionId: "test-123")
        #expect(manager.sessionId == "test-123")
        #expect(manager.connectionGeneration == 0)
        #expect(!manager.hasAppeared)
        #expect(!manager.needsInitialScroll)
    }

    @MainActor
    @Test func firstAppearDoesNotBumpGeneration() {
        let manager = ChatSessionManager(sessionId: "s1")
        #expect(manager.connectionGeneration == 0)
        #expect(!manager.hasAppeared)

        manager.markAppeared()

        #expect(manager.hasAppeared)
        #expect(manager.connectionGeneration == 0, "First appear should not bump generation")
    }

    @MainActor
    @Test func subsequentAppearBumpsGeneration() {
        let manager = ChatSessionManager(sessionId: "s1")
        manager.markAppeared()
        #expect(manager.connectionGeneration == 0)

        manager.markAppeared()
        #expect(manager.connectionGeneration == 1, "Second appear should bump generation")

        manager.markAppeared()
        #expect(manager.connectionGeneration == 2, "Third appear should bump again")
    }

    @MainActor
    @Test func reconnectBumpsGeneration() {
        let manager = ChatSessionManager(sessionId: "s1")
        #expect(manager.connectionGeneration == 0)

        manager.reconnect()
        #expect(manager.connectionGeneration == 1)

        manager.reconnect()
        #expect(manager.connectionGeneration == 2)
    }

    @MainActor
    @Test func unexpectedConnectedStreamExitSchedulesReconnect() async {
        let sessionId = "auto-reconnect"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeCredentials())

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeSession(id: sessionId)))
        streams.finish(index: 0)
        await connectTask.value

        #expect(await waitForCondition(timeoutMs: 1_000) {
            await MainActor.run { manager.connectionGeneration == 1 }
        })

        manager.cleanup()
    }

    @MainActor
    @Test func cancelledStreamExitDoesNotScheduleReconnect() async {
        let manager = ChatSessionManager(sessionId: "cancelled-exit")
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeCredentials())

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))

        connectTask.cancel()
        streams.finish(index: 0)
        await connectTask.value

        #expect(manager.connectionGeneration == 0)

        manager.cleanup()
    }

    @MainActor
    @Test func stoppedSessionExitDoesNotScheduleReconnect() async {
        let sessionId = "stopped-session"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeCredentials())

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()
        sessionStore.upsert(makeSession(id: sessionId, status: .stopped))

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeSession(id: sessionId, status: .stopped)))
        streams.finish(index: 0)
        await connectTask.value

        #expect(manager.connectionGeneration == 0)

        manager.cleanup()
    }

    // MARK: - Lifecycle race harness

    @MainActor
    @Test func staleGenerationCleanupDoesNotDisconnectNewerReconnectStream() async {
        let manager = ChatSessionManager(sessionId: "s1")
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeCredentials())

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let firstConnect = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        let firstReady = await streams.waitForCreated(1)
        #expect(firstReady)
        connection.wsClient?._setConnectedSessionIdForTesting("s1")

        manager.reconnect()
        #expect(manager.connectionGeneration == 1)

        let secondConnect = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        let secondReady = await streams.waitForCreated(2)
        #expect(secondReady)
        connection.wsClient?._setConnectedSessionIdForTesting("s1")

        // Force-drop stale stream #1 while stream #2 is active.
        streams.finish(index: 0)
        await firstConnect.value

        #expect(
            connection.wsClient?.connectedSessionId == "s1",
            "Stale generation cleanup must not disconnect newer stream"
        )

        streams.finish(index: 1)
        await secondConnect.value

        #expect(
            connection.wsClient?.connectedSessionId == nil,
            "Current generation should disconnect on normal loop exit"
        )
    }

    @MainActor
    @Test func staleCleanupSkipsDisconnectWhenSocketOwnershipMoved() async {
        let manager = ChatSessionManager(sessionId: "s1")
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeCredentials())

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        let ready = await streams.waitForCreated(1)
        #expect(ready)

        // Simulate another session taking ownership before stale cleanup runs.
        connection.wsClient?._setConnectedSessionIdForTesting("s2")

        streams.finish(index: 0)
        await connectTask.value

        #expect(
            connection.wsClient?.connectedSessionId == "s2",
            "Cleanup must not disconnect socket owned by a different session"
        )
    }

    @MainActor
    @Test func reconnectReloadUsesLatestTraceSignature() async {
        let sessionId = "sig-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        let tracker = HistoryReloadTracker()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { cachedEventCount, cachedLastEventId in
            let callIndex = await tracker.recordCall(
                cachedEventCount: cachedEventCount,
                cachedLastEventId: cachedLastEventId
            )

            if callIndex == 1 {
                return (eventCount: 200, lastEventId: "evt-200")
            }
            return (eventCount: 200, lastEventId: "evt-200")
        }

        let connection = ServerConnection()
        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        #expect(await tracker.waitForCalls(1))

        let session = makeSession(id: sessionId)
        streams.yield(index: 0, message: .connected(session: session))
        streams.yield(index: 0, message: .connected(session: session))

        #expect(await tracker.waitForCalls(2))

        streams.finish(index: 0)
        await connectTask.value

        let snapshot = await tracker.snapshot()
        #expect(snapshot.calls.count == 2)
        #expect(snapshot.calls[0].cachedEventCount == nil)
        #expect(snapshot.calls[0].cachedLastEventId == nil)
        #expect(snapshot.calls[1].cachedEventCount == 200)
        #expect(snapshot.calls[1].cachedLastEventId == "evt-200")
    }

    @MainActor
    @Test func reconnectReloadCancelsStaleInFlightTasks() async {
        let sessionId = "cancel-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        let tracker = HistoryReloadTracker()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { cachedEventCount, cachedLastEventId in
            let callIndex = await tracker.recordCall(
                cachedEventCount: cachedEventCount,
                cachedLastEventId: cachedLastEventId
            )

            do {
                try await Task.sleep(for: .milliseconds(200))
                await tracker.recordCompletion()
                return (eventCount: callIndex, lastEventId: "evt-\(callIndex)")
            } catch {
                await tracker.recordCancellation()
                return nil
            }
        }

        let connection = ServerConnection()
        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        #expect(await tracker.waitForCalls(1))

        let session = makeSession(id: sessionId)
        streams.yield(index: 0, message: .connected(session: session))
        streams.yield(index: 0, message: .connected(session: session))
        try? await Task.sleep(for: .milliseconds(20))
        streams.yield(index: 0, message: .connected(session: session))

        #expect(await tracker.waitForCalls(3))

        try? await Task.sleep(for: .milliseconds(260))

        let snapshot = await tracker.snapshot()
        #expect(snapshot.cancellations >= 2)
        #expect(snapshot.completions == 1)

        streams.finish(index: 0)
        await connectTask.value
    }

    @MainActor
    @Test func stateSyncRequestedOnConnectedMessagesOnly() async {
        let sessionId = "state-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        let counter = StateSyncCounter()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        connection._sendMessageForTesting = { message in
            await counter.record(message: message)
        }

        let reducer = TimelineReducer()
        let sessionStore = SessionStore()

        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await counter.count() == 0)

        let session = makeSession(id: sessionId)
        streams.yield(index: 0, message: .connected(session: session))
        #expect(await waitForCondition(timeoutMs: 500) { await counter.count() == 1 })

        streams.yield(index: 0, message: .connected(session: session))
        #expect(await waitForCondition(timeoutMs: 500) { await counter.count() == 2 })

        streams.finish(index: 0)
        await connectTask.value
    }

    @MainActor
    @Test func cleanupIsSafe() {
        let manager = ChatSessionManager(sessionId: "s1")
        manager.cleanup()
        manager.cleanup() // idempotent
    }

    @MainActor
    @Test func cancelReconciliationIsSafe() {
        let manager = ChatSessionManager(sessionId: "s1")
        manager.cancelReconciliation()
        manager.cancelReconciliation() // idempotent
    }

    // MARK: - Helpers

    private func makeCredentials() -> ServerCredentials {
        .init(host: "localhost", port: 7749, token: "sk_test", name: "Test")
    }

    private func makeSession(id: String, status: SessionStatus = .ready) -> Session {
        let now = Date()
        return Session(
            id: id,
            userId: "u1",
            workspaceId: nil,
            workspaceName: nil,
            name: "Session",
            status: status,
            createdAt: now,
            lastActivity: now,
            model: nil,
            runtime: nil,
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            contextTokens: nil,
            contextWindow: nil,
            lastMessage: nil,
            thinkingLevel: nil
        )
    }
}

private struct HistoryReloadCall: Equatable, Sendable {
    let cachedEventCount: Int?
    let cachedLastEventId: String?
}

private actor HistoryReloadTracker {
    private var calls: [HistoryReloadCall] = []
    private var cancellations = 0
    private var completions = 0

    func recordCall(cachedEventCount: Int?, cachedLastEventId: String?) -> Int {
        calls.append(.init(cachedEventCount: cachedEventCount, cachedLastEventId: cachedLastEventId))
        return calls.count
    }

    func recordCancellation() {
        cancellations += 1
    }

    func recordCompletion() {
        completions += 1
    }

    func snapshot() -> (calls: [HistoryReloadCall], cancellations: Int, completions: Int) {
        (calls, cancellations, completions)
    }

    func waitForCalls(_ expected: Int, timeoutMs: Int = 1_000) async -> Bool {
        let attempts = max(1, timeoutMs / 20)
        for _ in 0..<attempts {
            if calls.count >= expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private actor StateSyncCounter {
    private var value = 0

    func record(message: ClientMessage) {
        if case .getState = message {
            value += 1
        }
    }

    func count() -> Int {
        value
    }
}

private func waitForCondition(
    timeoutMs: Int = 1_000,
    pollMs: Int = 20,
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    let attempts = max(1, timeoutMs / max(1, pollMs))
    for _ in 0..<attempts {
        if await predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(pollMs))
    }
    return await predicate()
}

@MainActor
private final class ScriptedStreamFactory {
    private(set) var streamsCreated = 0
    private var continuations: [AsyncStream<ServerMessage>.Continuation] = []

    func makeStream() -> AsyncStream<ServerMessage> {
        let index = streamsCreated
        streamsCreated += 1

        return AsyncStream { continuation in
            if index < self.continuations.count {
                self.continuations[index] = continuation
            } else {
                self.continuations.append(continuation)
            }
        }
    }

    func yield(index: Int, message: ServerMessage) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(message)
    }

    func finish(index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func waitForCreated(_ expected: Int, timeoutMs: Int = 1_000) async -> Bool {
        let attempts = max(1, timeoutMs / 20)
        for _ in 0..<attempts {
            if streamsCreated >= expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
