import Foundation
import Testing
@testable import Oppi

/// Focused-stream ownership and pre-send readiness.
///
/// Regression for the send/draft bounce: a stale chat runtime for session X,
/// released after a newer chat re-entered X, tore down the newer chat's stream
/// and focus. The visible chat then failed its next send with
/// "WebSocket not connected" and restored the draft.
@Suite("Chat focus ownership", .serialized)
@MainActor
struct ChatFocusOwnershipTests {

    // MARK: - Ownership

    @Test func staleSameSessionReleaseKeepsNewerRuntimeStream() async {
        let sessionId = "same-session-\(UUID().uuidString)"
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let oldManager = ChatSessionManager(sessionId: sessionId)
        var oldLease: ChatSessionManagerLease? = ChatSessionManagerLease(manager: oldManager)
        let oldStreams = ScriptedStreamFactory()
        oldManager._streamSessionForTesting = { _ in oldStreams.makeStream() }
        oldManager._loadHistoryForTesting = { _, _ in nil }
        oldManager.markAppeared()
        oldManager.ensureConnected(connection: connection, sessionStore: sessionStore)
        #expect(await oldStreams.waitForCreated(1))
        oldStreams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { oldManager.entryState == .streaming }
        })

        // Leave: onDisappear cleanup releases the old runtime's own claim.
        oldManager.cleanup()
        oldStreams.finish(index: 0)
        #expect(connection.focusedSessionId == nil)

        // Re-enter the same session with a new runtime.
        let newManager = ChatSessionManager(sessionId: sessionId)
        let newStreams = ScriptedStreamFactory()
        newManager._streamSessionForTesting = { _ in newStreams.makeStream() }
        newManager._loadHistoryForTesting = { _, _ in nil }
        newManager.markAppeared()
        newManager.ensureConnected(connection: connection, sessionStore: sessionStore)
        #expect(await newStreams.waitForCreated(1))
        newStreams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { newManager.entryState == .streaming }
        })
        let newClaim = connection.focusedSessionStore.focused

        // SwiftUI releases the stale chat late: lease deinit runs cleanup() again,
        // then a third explicit cleanup for good measure.
        oldLease = nil
        oldManager.cleanup()

        #expect(connection.focusedSessionStore.focused == newClaim, "Stale release must not touch the newer owner")
        #expect(newManager.ownsFocusClaim)

        // The newer owner still auto-reconnects when its own socket really ends.
        newStreams.finish(index: 0)
        #expect(await newStreams.waitForCreated(2, timeoutMs: 2_000), "Owner must reconnect after a real stream end")

        newManager.cleanup()
        connection.disconnectStream()
        _ = oldLease
    }

    /// A superseded runtime whose stream tail ends after the newer owner bound
    /// must not clear the owner's watchdog reconnect handler, reconnect itself,
    /// or release the owner's focus.
    @Test func supersededStreamTailLeavesNewerOwnerSharedStateIntact() async {
        let sessionId = "tail-\(UUID().uuidString)"
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        func startStreaming(_ manager: ChatSessionManager, _ streams: ScriptedStreamFactory, index: Int) async {
            manager._streamSessionForTesting = { _ in streams.makeStream() }
            manager._loadHistoryForTesting = { _, _ in nil }
            manager.markAppeared()
            manager.ensureConnected(connection: connection, sessionStore: sessionStore)
            _ = await streams.waitForCreated(index + 1)
            streams.yield(index: index, message: .connected(session: makeTestSession(id: sessionId)))
            _ = await waitForTestCondition(timeoutMs: 1_000) {
                await MainActor.run { manager.entryState == .streaming }
            }
        }

        let oldManager = ChatSessionManager(sessionId: sessionId)
        let oldStreams = ScriptedStreamFactory()
        await startStreaming(oldManager, oldStreams, index: 0)
        #expect(connection.silenceWatchdog.onReconnect != nil)

        // A new chat for the same session claims while the old loop is still live.
        let newManager = ChatSessionManager(sessionId: sessionId)
        let newStreams = ScriptedStreamFactory()
        await startStreaming(newManager, newStreams, index: 0)
        let ownerClaim = connection.focusedSessionStore.focused
        #expect(newManager.ownsFocusClaim)
        #expect(!oldManager.ownsFocusClaim)

        // The old stream's tail runs now.
        oldStreams.finish(index: 0)
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                if case .disconnected = oldManager.entryState { return true }
                return false
            }
        })
        try? await Task.sleep(for: .milliseconds(400))

        #expect(connection.silenceWatchdog.onReconnect != nil, "Stale tail must not clear the owner's handler")
        #expect(connection.focusedSessionStore.focused == ownerClaim)
        #expect(oldStreams.streamsCreated == 1, "A superseded runtime must not auto-reconnect")
        #expect(newStreams.streamsCreated == 1)
        #expect(newManager.entryState == .streaming)

        oldManager.cleanup()
        #expect(connection.focusedSessionStore.focused == ownerClaim)
        newManager.cleanup()
        connection.disconnectStream()
    }

    @Test func releaseOnlyHonorsTheCurrentClaimOnce() {
        let (connection, _) = makeTestConnection(sessionId: "other")
        connection._sendMessageForTesting = { _ in }

        let first = connection.claimFocusedSession("s1")
        #expect(first != nil)
        // Routine same-session routing (stream open, re-entry) keeps the claim.
        connection.focusSession("s1")
        #expect(connection.focusedSessionStore.focused == first)

        let second = connection.claimFocusedSession("s1")
        #expect(second != first, "A new owner of the same session supersedes the old claim")

        if let first { connection.releaseFocusedSession(first) }
        #expect(connection.focusedSessionStore.focused == second, "Superseded same-session claim is a no-op")

        if let second {
            connection.releaseFocusedSession(second)
            #expect(connection.focusedSessionId == nil)
            connection.focusSession("s2")
            connection.releaseFocusedSession(second)
        }
        #expect(connection.focusedSessionId == "s2", "Repeated release must not close a later focus")
    }

    /// A bind that resumes after another runtime took focus (same or different
    /// session) is refused before the endpoint is rebound or the socket opened.
    @Test(arguments: [true, false])
    func staleOpenAfterAwaitNeverConnectsTheSharedSocket(sameSession: Bool) async {
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        defer { connection.disconnectStream() }
        connection.setAPIClientForTesting(nil)
        connection._focusedStreamReadinessPollForTesting = .milliseconds(5)
        var connectCalls = 0
        connection._connectStreamForTesting = {
            connectCalls += 1
            return AsyncStream { $0.finish() }
        }
        var waiting = false
        connection._onFocusedStreamReadinessWaitForTesting = { waiting = true }

        guard let staleClaim = connection.claimFocusedSession("s1") else {
            Issue.record("Expected claim")
            return
        }
        async let opened = connection.streamSession("s1", routeScope: .workspace("w1"), claim: staleClaim)
        #expect(await waitForMainActorCondition { waiting })

        let holder = connection.claimFocusedSession(sameSession ? "s1" : "s2")
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)

        #expect(await opened == nil)
        #expect(connectCalls == 0, "Stale open must not reconnect the shared socket")
        #expect(connection.focusedSessionStore.focused == holder)
        #expect(connection.focusedSessionStreamURLForTesting == nil)
    }

    /// v3 review P1a: the claim moves after `streamSession`'s own check, inside
    /// the bind stretch (endpoint arbitration), before the coordinator's focus,
    /// continuation attach, and connect. None of those may run for the stale claim.
    @Test(arguments: [true, false])
    func claimLostInsideBindStretchNeverRetargetsSocketOrConsumer(sameSession: Bool) async {
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        defer { connection.disconnectStream() }
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        var connectCalls = 0
        connection._connectStreamForTesting = {
            connectCalls += 1
            return AsyncStream { $0.finish() }
        }

        guard let staleClaim = connection.claimFocusedSession("s1") else {
            Issue.record("Expected claim")
            return
        }
        var holder: FocusedSessionContext?
        connection._onFocusArbitrationForTesting = { outcome, metadata in
            guard holder == nil, outcome == "requested", metadata["context"] == "stream_bind" else { return }
            holder = connection.claimFocusedSession(sameSession ? "s1" : "s2")
        }

        let opened = await connection.streamSession("s1", routeScope: .workspace("w1"), claim: staleClaim)

        #expect(holder != nil, "Claim must move inside the bind stretch")
        #expect(opened == nil)
        #expect(connectCalls == 0, "Stale open must not reconnect the shared socket")
        #expect(connection.focusedSessionStore.focused == holder, "Stale open must not refocus")
        #expect(connection.sessionEventContinuations["s1"] == nil, "Stale open must not attach a consumer")
    }

    /// v3 review P1b: a runtime cleaned up while its connect was starting must
    /// never claim focus over the chat that is now on screen.
    @Test func cleanedUpRuntimeNeverClaimsOverTheVisibleChat() async {
        let harness = await makeStreamingManager()
        let ownerClaim = harness.connection.focusedSessionStore.focused

        let stale = ChatSessionManager(sessionId: harness.sessionId)
        let staleStreams = ScriptedStreamFactory()
        stale._streamSessionForTesting = { _ in staleStreams.makeStream() }
        stale._loadHistoryForTesting = { _, _ in nil }
        stale.markAppeared()
        stale.cleanup()
        await stale.connect(connection: harness.connection, sessionStore: harness.sessionStore)

        #expect(harness.connection.focusedSessionStore.focused == ownerClaim)
        #expect(harness.manager.ownsFocusClaim)
        #expect(!stale.ownsFocusClaim)
        #expect(staleStreams.streamsCreated == 0)
        harness.tearDown()
    }

    @Test func deferredLiveAudioReleaseSparesNewerSameSessionOwner() async {
        let sessionId = "audio-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: "other")
        connection._sendMessageForTesting = { _ in }

        guard let stale = connection.claimFocusedSession(sessionId) else {
            Issue.record("Expected claim")
            return
        }
        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: sessionId)
        connection.releaseFocusedSession(stale)
        #expect(connection.focusedSessionStore.focused == stale, "Live audio defers the release")

        let newer = connection.claimFocusedSession(sessionId)
        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: sessionId, receivedDone: true)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(connection.focusedSessionStore.focused == newer, "Drained audio must not close the newer owner")

        // With no newer owner, the deferred release really happens after drain.
        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: sessionId)
        if let newer { connection.releaseFocusedSession(newer) }
        #expect(connection.focusedSessionStore.focused == newer, "Still deferred while audio plays")
        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: sessionId, receivedDone: true)
        #expect(await waitForMainActorCondition { connection.focusedSessionStore.focused == nil })

        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: nil)
        connection.disconnectStream()
    }

    /// A layout swap (iPad rotation into the split shell) mounts a transient
    /// duplicate chat for the visible session. It claims focus over the visible
    /// chat and is torn down moments later. The visible chat must get the
    /// stream back instead of staying disconnected with no live output.
    /// `transientBound`: the duplicate opened its stream (replacing the visible
    /// chat's consumer) before leaving, versus leaving before it bound.
    @Test(arguments: [false, true])
    func transientSameSessionChatLeavingHandsStreamBackToVisibleChat(transientBound: Bool) async {
        let sessionId = "remount-\(UUID().uuidString)"
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let visible = ChatSessionManager(sessionId: sessionId)
        let visibleStreams = ScriptedStreamFactory()
        visible._streamSessionForTesting = { _ in visibleStreams.makeStream() }
        visible._loadHistoryForTesting = { _, _ in nil }
        visible._focusedStreamLivenessForTesting = { .connected }
        visible.markAppeared()
        visible.claimFocusOnAppear(connection: connection, sessionStore: sessionStore)
        let visibleClaim = connection.focusedSessionStore.focused

        let transient = ChatSessionManager(sessionId: sessionId)
        let transientStreams = ScriptedStreamFactory()
        transient._streamSessionForTesting = { _ in transientStreams.makeStream() }
        transient._loadHistoryForTesting = { _, _ in nil }

        if transientBound {
            visible.ensureConnected(connection: connection, sessionStore: sessionStore)
            #expect(await visibleStreams.waitForCreated(1))
            visibleStreams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
            #expect(await waitForTestCondition(timeoutMs: 1_000) {
                await MainActor.run { visible.entryState == .streaming }
            })
            transient.markAppeared()
            transient.claimFocusOnAppear(connection: connection, sessionStore: sessionStore)
            transient.ensureConnected(connection: connection, sessionStore: sessionStore)
            #expect(await transientStreams.waitForCreated(1))
            // Binding the same session replaces the visible chat's consumer.
            visibleStreams.finish(index: 0)
        } else {
            transient.markAppeared()
            transient.claimFocusOnAppear(connection: connection, sessionStore: sessionStore)
            // The visible chat's connect runs while the duplicate owns focus.
            visible.ensureConnected(connection: connection, sessionStore: sessionStore)
        }
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                if case .disconnected = visible.entryState { return true }
                return false
            }
        })
        let streamsBeforeLeave = visibleStreams.streamsCreated

        // The duplicate is torn down.
        transient.cleanup()

        #expect(connection.focusedSessionStore.focused == visibleClaim, "Focus returns to the visible chat's claim")
        #expect(visible.ownsFocusClaim)
        #expect(
            await visibleStreams.waitForCreated(streamsBeforeLeave + 1, timeoutMs: 2_000),
            "The visible chat must rebind its stream"
        )
        visibleStreams.yield(index: streamsBeforeLeave, message: .connected(session: makeTestSession(id: sessionId)))
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { visible.isReadyForTurnDispatch }
        })

        // Leaving the visible chat afterwards still closes the session stream.
        visible.cleanup()
        #expect(connection.focusedSessionId == nil)
        connection.disconnectStream()
    }

    /// Handing focus back never reaches a chat for another session (a covered
    /// background chat) or a chat that already released its claim.
    @Test func releaseNeverHandsFocusToAnotherSessionOrAReleasedChat() async {
        let harness = await makeStreamingManager()
        let background = harness.manager

        let other = ChatSessionManager(sessionId: "other-\(UUID().uuidString)")
        let otherStreams = ScriptedStreamFactory()
        other._streamSessionForTesting = { _ in otherStreams.makeStream() }
        other._loadHistoryForTesting = { _, _ in nil }
        other.markAppeared()
        other.claimFocusOnAppear(connection: harness.connection, sessionStore: harness.sessionStore)
        other.ensureConnected(connection: harness.connection, sessionStore: harness.sessionStore)
        #expect(await otherStreams.waitForCreated(1))
        harness.streams.finish(index: 0)
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                if case .disconnected = background.entryState { return true }
                return false
            }
        })

        other.cleanup()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(harness.connection.focusedSessionId == nil, "Another session's chat must not take the stream")
        #expect(!background.ownsFocusClaim)
        #expect(harness.streams.streamsCreated == 1)

        // Same session: a released chat's claim is forgotten, never handed back.
        var regained: [String] = []
        let olderRuntime = NSObject()
        let newerRuntime = NSObject()
        let older = harness.connection.claimFocusedSession(
            "s1",
            holder: FocusClaimHolder(id: ObjectIdentifier(olderRuntime)) { regained.append("older") }
        )
        let newer = harness.connection.claimFocusedSession(
            "s1",
            holder: FocusClaimHolder(id: ObjectIdentifier(newerRuntime)) { regained.append("newer") }
        )
        if let older { harness.connection.releaseFocusedSession(older) }
        if let newer { harness.connection.releaseFocusedSession(newer) }
        #expect(regained.isEmpty)
        #expect(harness.connection.focusedSessionId == nil)

        harness.tearDown()
    }

    /// A chat released while live audio drains keeps focus only for the
    /// deferred close; its runtime is gone. Re-entering the same session must
    /// not keep that released runtime for hand-back, so the next leave closes
    /// the stream instead of restoring a claim nobody holds.
    /// `audioEndsFirst`: audio drains before the newer chat leaves, versus the
    /// newer chat leaving while audio still plays (defer, then close).
    @Test(arguments: [true, false])
    func chatReleasedDuringLiveAudioIsNeverHandedFocusBack(audioEndsFirst: Bool) async {
        let sessionId = "audio-holder-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: "other")
        connection._sendMessageForTesting = { _ in }
        var regained: [String] = []
        let releasedRuntime = NSObject()
        let newerRuntime = NSObject()

        guard let released = connection.claimFocusedSession(
            sessionId,
            holder: FocusClaimHolder(id: ObjectIdentifier(releasedRuntime)) { regained.append("released") }
        ) else {
            Issue.record("Expected claim")
            return
        }
        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: sessionId)
        connection.releaseFocusedSession(released)
        #expect(connection.focusedSessionStore.focused == released, "Live audio defers the release")

        // Re-enter the same session before audio drains.
        let newer = connection.claimFocusedSession(
            sessionId,
            holder: FocusClaimHolder(id: ObjectIdentifier(newerRuntime)) { regained.append("newer") }
        )

        if audioEndsFirst {
            connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: sessionId, receivedDone: true)
            connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: nil)
            if let newer { connection.releaseFocusedSession(newer) }
            #expect(connection.focusedSessionId == nil, "Leaving the newer chat closes the stream")
        } else {
            if let newer { connection.releaseFocusedSession(newer) }
            #expect(connection.focusedSessionStore.focused == newer, "Still deferred while audio plays")
            connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: sessionId, receivedDone: true)
            #expect(await waitForMainActorCondition { connection.focusedSessionStore.focused == nil })
        }
        #expect(regained.isEmpty, "A released chat must never be handed focus")

        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: nil)
        connection.disconnectStream()
    }

    // MARK: - Send readiness

    /// Exercise the manager -> iOS adapter -> focused socket binding, not a
    /// scripted runtime stream: the live first socket never sends `connected`.
    @Test(arguments: [false, true])
    func readinessRebindsALiveLoopThatMissedConnectedWithoutLeavingChat(superseded: Bool) async throws {
        let sessionId = "missed-bootstrap-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.setAPIClientForTesting(nil)
        let session = makeTestSession(id: sessionId, workspaceId: "w1", status: .ready)
        connection.sessionStore.upsert(session)
        let manager = ChatSessionManager(sessionId: sessionId)
        defer {
            manager.cleanup()
            connection.disconnectStream()
        }
        manager._loadHistoryForTesting = { _, _ in nil }
        manager._fetchSessionTraceForTesting = { _, _ in (session, []) }
        var opens = 0
        connection._connectStreamForTesting = {
            opens += 1
            connection.wsClient?._setStatusForTesting(.connected)
            return AsyncStream { continuation in
                if opens == 2 {
                    continuation.yield(StreamFrameEvent(
                        sessionId: sessionId, message: .connected(session: session), meta: nil
                    ))
                }
            }
        }
        manager.markAppeared()
        manager.ensureConnected(connection: connection, sessionStore: connection.sessionStore)
        #expect(await waitForMainActorCondition {
            manager.entryState == .awaitingConnected(workspaceId: "w1")
        })
        #expect(opens == 1)
        #expect(connection.focusedStreamLiveness(sessionId: sessionId) == .connected)
        #expect(!manager.isReadyForTurnDispatch)
        let claim = connection.focusedSessionStore.focused
        let generation = manager.connectionGeneration
        let consumption = try #require(connection.streamConsumptionTask)
        if superseded {
            let newClaim = connection.claimFocusedSession(sessionId)
            do {
                try await manager.ensureReadyForSend(timeout: .seconds(2))
                Issue.record("A superseded awaitingConnected runtime must fail readiness")
            } catch let error as ChatSessionSendReadinessError {
                #expect(error == .notConnected)
            }
            #expect(opens == 1, "A superseded runtime must not reopen the shared socket")
            #expect(!consumption.isCancelled)
            #expect(manager.connectionGeneration == generation)
            #expect(connection.focusedSessionStore.focused == newClaim)
            return
        }

        // Concurrent sends share the single restart; no disappear/re-appear.
        let first = Task { try await manager.ensureReadyForSend(timeout: .seconds(2)) }
        let second = Task { try await manager.ensureReadyForSend(timeout: .seconds(2)) }
        try await first.value
        try await second.value
        #expect(manager.isReadyForTurnDispatch)
        #expect(manager.connectionGeneration == generation + 1)
        #expect(opens == 2, "Exactly one socket reopen must recover the missing bootstrap")
        #expect(consumption.isCancelled)
        #expect(connection.focusedSessionStore.focused == claim)
    }

    /// Send replaces a cancelled cache load while retaining the same focus
    /// claim. Releasing the old load after the replacement binds must be inert.
    @Test func cancelledCacheLoadCannotOverwriteSendReadinessReplacement() async throws {
        let sessionId = "cancelled-cache-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.setAPIClientForTesting(nil)
        let session = makeTestSession(id: sessionId, workspaceId: "w1", status: .ready)
        connection.sessionStore.upsert(session)
        let adapter = IOSChatSessionRuntimeAdapter()
        adapter.bind(connection: connection, sessionStore: connection.sessionStore)
        let history = SuspendedCacheHistory(adapter: adapter)
        let manager = ChatSessionManager(
            sessionId: sessionId,
            historyPort: history,
            focusedStreamPort: adapter,
            effectsStatePort: adapter,
            reducer: TimelineReducer(),
            coalescer: DeltaCoalescer()
        )
        var replacement: Task<Void, Never>?
        defer {
            history.release()
            replacement?.cancel()
            manager.cleanup()
            connection.disconnectStream()
        }
        manager._loadHistoryForTesting = { _, _ in nil }
        var opens = 0
        connection._connectStreamForTesting = {
            opens += 1
            connection.wsClient?._setStatusForTesting(.connected)
            return AsyncStream { continuation in
                continuation.yield(StreamFrameEvent(
                    sessionId: sessionId, message: .connected(session: session), meta: nil
                ))
            }
        }
        manager.markAppeared()
        let oldConnect = Task { await manager.connect() }
        #expect(await waitForMainActorCondition { history.isSuspended })
        let claim = connection.focusedSessionStore.focused
        // Use the existing externally-owned loop callback so the old task's
        // completion can be awaited explicitly after releasing the cache gate.
        manager.onReconnect = {
            oldConnect.cancel()
            replacement = Task { await manager.connect() }
        }
        try await manager.ensureReadyForSend(timeout: .seconds(2))
        #expect(oldConnect.isCancelled)
        #expect(manager.connectionGeneration == 1)
        #expect(manager.entryState == .streaming)
        let consumption = try #require(connection.streamConsumptionTask)
        #expect(connection.silenceWatchdog.onReconnect != nil)

        history.release()
        await oldConnect.value

        #expect(manager.entryState == .streaming, "Old cache completion must not overwrite the replacement")
        #expect(manager.isReadyForTurnDispatch)
        #expect(connection.wsClient?.status == .connected)
        #expect(!consumption.isCancelled, "Old connect must not disconnect the replacement socket")
        #expect(opens == 1, "Old connect must not open another socket")
        #expect(connection.silenceWatchdog.onReconnect != nil)
        #expect(connection.focusedSessionStore.focused == claim)
    }

    /// Readiness cancellation is distinct from focus supersession: the same
    /// claim can remain current, but the cancelled opener must not attach and
    /// trigger the missing-bootstrap socket reopen.
    @Test func cancelledReadinessWaitCannotReopenTheStillOwnedSocket() async throws {
        let (connection, _) = makeTestConnection(sessionId: "s1")
        defer { connection.disconnectStream() }
        connection.setAPIClientForTesting(nil)
        connection._focusedStreamReadinessPollForTesting = .seconds(10)
        var waiting = false
        connection._onFocusedStreamReadinessWaitForTesting = { waiting = true }
        var opens = 0
        connection._connectStreamForTesting = {
            opens += 1
            return AsyncStream { $0.finish() }
        }
        let claim = try #require(connection.claimFocusedSession("s1"))
        let sentinel = Task<Void, Never> { }
        connection.streamConsumptionTask = sentinel
        connection.wsClient?._setStatusForTesting(.connected)
        let oldOpen = Task {
            await connection.streamSession("s1", routeScope: .workspace("w1"), claim: claim)
        }
        #expect(await waitForMainActorCondition { waiting })
        oldOpen.cancel()
        // Route becomes ready before the cancelled waiter resumes; claim and
        // socket are unchanged, and no connected bootstrap is parked.
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        #expect(await oldOpen.value == nil)
        #expect(opens == 0)
        #expect(!sentinel.isCancelled)
        #expect(connection.wsClient?.status == .connected)
        #expect(connection.focusedSessionStreamURLForTesting == nil)
        #expect(connection.sessionEventContinuations["s1"] == nil)
        #expect(connection.focusedSessionStore.focused == claim)
    }

    @Test func readinessRestartsADroppedSocketOnceAndWaitsForTheBoundStream() async throws {
        let harness = await makeStreamingManager()
        let manager = harness.manager
        var liveness = FocusedStreamLiveness.down
        manager._focusedStreamLivenessForTesting = { liveness }

        // Entry state still says streaming, but the socket is gone.
        #expect(manager.entryState == .streaming)
        #expect(!manager.isReadyForTurnDispatch)

        let generationBefore = manager.connectionGeneration
        // Both senders start before the first one's restarted loop runs; the
        // second joins the in-flight readiness pass instead of reconnecting.
        let first = Task { try await manager.ensureReadyForSend(timeout: .seconds(3)) }
        let second = Task { try await manager.ensureReadyForSend(timeout: .seconds(3)) }
        #expect(await harness.streams.waitForCreated(2))
        let generationAfterRestart = manager.connectionGeneration
        #expect(
            generationAfterRestart == generationBefore + 1,
            "Exactly one readiness reconnect; a second would cancel the first loop"
        )
        #expect(manager.entryState != .streaming)

        // A later sender, after the restarted loop opened its stream, joins too.
        let third = Task { try await manager.ensureReadyForSend(timeout: .seconds(3)) }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(manager.connectionGeneration == generationAfterRestart, "Joining senders must not reconnect again")
        #expect(harness.streams.streamsCreated == 2)

        liveness = .connected
        harness.streams.yield(index: 1, message: .connected(session: makeTestSession(id: harness.sessionId)))

        try await first.value
        try await second.value
        try await third.value
        #expect(manager.isReadyForTurnDispatch)
        #expect(manager.connectionGeneration == generationAfterRestart)
        #expect(harness.streams.streamsCreated == 2)

        harness.tearDown()
    }

    /// Once a newer chat for the same session claims focus, the old runtime can
    /// neither reconnect (watchdog, timer, Resume, Send failure) nor become
    /// send-ready, including a Send already waiting when the claim moved.
    @Test func supersededRuntimeNeverReconnectsOrBecomesSendReady() async {
        let harness = await makeStreamingManager()
        let stale = harness.manager
        stale._focusedStreamLivenessForTesting = { .recovering }
        let waitingSend = Task { try await stale.ensureReadyForSend(timeout: .seconds(3)) }
        try? await Task.sleep(for: .milliseconds(50))

        let newer = ChatSessionManager(sessionId: harness.sessionId)
        let newerStreams = ScriptedStreamFactory()
        newer._streamSessionForTesting = { _ in newerStreams.makeStream() }
        newer._loadHistoryForTesting = { _, _ in nil }
        newer._focusedStreamLivenessForTesting = { .connected }
        newer.markAppeared()
        newer.claimFocusOnAppear(connection: harness.connection, sessionStore: harness.sessionStore)
        newer.ensureConnected(connection: harness.connection, sessionStore: harness.sessionStore)
        #expect(await newerStreams.waitForCreated(1))
        newerStreams.yield(index: 0, message: .connected(session: makeTestSession(id: harness.sessionId)))
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { newer.entryState == .streaming }
        })
        let newerClaim = harness.connection.focusedSessionStore.focused
        #expect(!stale.ownsFocusClaim)

        for send in [waitingSend, Task { try await stale.ensureReadyForSend(timeout: .seconds(1)) }] {
            do {
                try await send.value
                Issue.record("A superseded runtime must not become send-ready")
            } catch let error as ChatSessionSendReadinessError {
                #expect(error == .notConnected)
            } catch {
                Issue.record("Unexpected error \(error)")
            }
        }

        stale.reconnect()
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                if case .disconnected = stale.entryState { return true }
                return false
            }
        })
        try? await Task.sleep(for: .milliseconds(150))

        #expect(harness.connection.focusedSessionStore.focused == newerClaim)
        #expect(newer.isReadyForTurnDispatch)
        #expect(harness.streams.streamsCreated == 1, "Superseded runtime must not open a stream")
        #expect(newerStreams.streamsCreated == 1)

        newer.cleanup()
        harness.tearDown()
    }

    /// Round-2 P2: the owner's own stream end must not vacate focus, so a
    /// stale runtime parked in a bind retry can never take it during the
    /// owner's reconnect delay.
    @Test func ownerStreamEndNeverVacatesFocus() async {
        let sessionId = "vacancy-\(UUID().uuidString)"
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        connection.setAPIClientForTesting(nil)
        connection._focusedStreamReadinessPollForTesting = .milliseconds(1)
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        // Stale runtime claims first, fails to bind, and parks in a retry sleep.
        let stale = ChatSessionManager(sessionId: sessionId)
        var staleOpenAttempts = 0
        stale._streamSessionForTesting = { _ in
            staleOpenAttempts += 1
            return nil
        }
        stale._loadHistoryForTesting = { _, _ in nil }
        stale._focusedStreamSetupRetryDelayForTesting = .milliseconds(400)
        stale.markAppeared()
        stale.ensureConnected(connection: connection, sessionStore: sessionStore)
        #expect(await waitForMainActorCondition { staleOpenAttempts >= 1 })

        // The visible chat appears, claims, and streams.
        let owner = ChatSessionManager(sessionId: sessionId)
        let ownerStreams = ScriptedStreamFactory()
        owner._streamSessionForTesting = { _ in ownerStreams.makeStream() }
        owner._loadHistoryForTesting = { _, _ in nil }
        owner.markAppeared()
        owner.claimFocusOnAppear(connection: connection, sessionStore: sessionStore)
        owner.ensureConnected(connection: connection, sessionStore: sessionStore)
        #expect(await ownerStreams.waitForCreated(1))
        ownerStreams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { owner.entryState == .streaming }
        })
        let ownerClaim = connection.focusedSessionStore.focused
        #expect(ownerClaim != nil)

        // The owner's socket ends; its auto-reconnect is scheduled.
        ownerStreams.finish(index: 0)
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                if case .disconnected = owner.entryState { return true }
                return owner.entryState != .streaming
            }
        })
        #expect(connection.focusedSessionStore.focused == ownerClaim, "Stream end must not vacate focus")

        #expect(await ownerStreams.waitForCreated(2, timeoutMs: 2_000), "Owner reconnects as the same owner")
        #expect(connection.focusedSessionStore.focused == ownerClaim)
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                if case .disconnected = stale.entryState { return true }
                return false
            }
        })
        #expect(!stale.ownsFocusClaim)
        #expect(staleOpenAttempts == 1, "Stale runtime must not bind again once superseded")
        #expect(connection.focusedSessionStore.focused == ownerClaim)

        stale.cleanup()
        owner.cleanup()
        connection.disconnectStream()
    }

    @Test func readinessWaitsForASelfRecoveringSocketWithoutRestarting() async throws {
        let harness = await makeStreamingManager()
        let manager = harness.manager
        var liveness = FocusedStreamLiveness.recovering
        manager._focusedStreamLivenessForTesting = { liveness }

        let ready = Task { try await manager.ensureReadyForSend(timeout: .seconds(2)) }
        try? await Task.sleep(for: .milliseconds(250))
        #expect(harness.streams.streamsCreated == 1, "A transport reconnecting on its own is awaited, not restarted")
        liveness = .connected

        try await ready.value
        #expect(harness.streams.streamsCreated == 1)
        harness.tearDown()
    }

    @Test func readinessTimesOutWithinItsBound() async {
        let harness = await makeStreamingManager()
        harness.manager._focusedStreamLivenessForTesting = { .down }

        let start = ContinuousClock.now
        do {
            try await harness.manager.ensureReadyForSend(timeout: .milliseconds(400))
            Issue.record("Expected readiness timeout")
        } catch let error as ChatSessionSendReadinessError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        harness.tearDown()
    }

    @Test func readinessKeepsStoppedSessionsHistoryOnly() async {
        let sessionId = "stopped-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        var streamsOpened = 0
        manager._streamSessionForTesting = { _ in
            streamsOpened += 1
            return AsyncStream { $0.finish() }
        }
        manager._loadHistoryForTesting = { _, _ in nil }
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .stopped))
        manager.markAppeared()
        await manager.connect(connection: connection, sessionStore: sessionStore)
        #expect(manager.entryState == .stopped(historyLoaded: true))

        do {
            try await manager.ensureReadyForSend(connection: connection, sessionStore: sessionStore, timeout: .seconds(1))
            Issue.record("Stopped session must not become send-ready")
        } catch let error as ChatSessionSendReadinessError {
            #expect(error == .sessionStopped)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(streamsOpened == 0, "Readiness must not resume a stopped session")

        manager.cleanup()
        connection.disconnectStream()
    }

    // MARK: - Send path

    @Test func sendWaitsForReadinessShowingConnectingThenDispatchesOnce() async {
        let harness = await makeStreamingManager()
        var liveness = FocusedStreamLiveness.down
        harness.manager._focusedStreamLivenessForTesting = { liveness }
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let pipe = TestEventPipeline(sessionId: harness.sessionId, connection: harness.connection)
        var dispatched: [String] = []
        harness.connection._sendMessageForTesting = { message in
            guard case .prompt(let text, _, _, let requestId, let clientTurnId) = message,
                  let requestId, let clientTurnId else { return }
            dispatched.append(text)
            pipe.handle(
                .turnAck(command: "prompt", clientTurnId: clientTurnId, stage: .dispatched, requestId: requestId, duplicate: false),
                sessionId: harness.sessionId
            )
        }
        var succeeded = false

        _ = handler.sendPrompt(
            text: "hello after drop",
            attachments: [],
            isBusy: false,
            connection: harness.connection,
            reducer: reducer,
            sessionId: harness.sessionId,
            sessionStore: harness.sessionStore,
            sessionManager: harness.manager,
            onSendSucceeded: { succeeded = true }
        )

        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { handler.sendProgressText == "Connecting…" }
        })
        #expect(dispatched.isEmpty, "Nothing is dispatched before the stream is ready")
        #expect(Self.userMessages(in: reducer).isEmpty, "No optimistic bubble while connecting")

        #expect(await harness.streams.waitForCreated(2))
        liveness = .connected
        harness.streams.yield(index: 1, message: .connected(session: makeTestSession(id: harness.sessionId)))

        #expect(await waitForTestCondition(timeoutMs: 2_000) {
            await MainActor.run { succeeded && !handler.isSending }
        })
        #expect(dispatched == ["hello after drop"])
        #expect(handler.sendProgressText == nil)
        #expect(Self.userMessages(in: reducer) == ["hello after drop"])
        harness.tearDown()
    }

    @Test func readinessFailureRestoresDraftWithoutBubbleOrDispatch() async {
        let harness = await makeStreamingManager()
        harness.manager._focusedStreamLivenessForTesting = { .down }
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        var dispatchCount = 0
        harness.connection._sendMessageForTesting = { _ in dispatchCount += 1 }
        var restoredText: String?

        // A stopped session never becomes ready and is not resumed by sending.
        harness.sessionStore.upsert(makeTestSession(id: harness.sessionId, status: .stopped))
        harness.streams.finish(index: 0)
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                if case .disconnected = harness.manager.entryState { return true }
                return harness.manager.entryState == .stopped(historyLoaded: true)
            }
        })

        _ = handler.sendPrompt(
            text: "keep me",
            attachments: [],
            isBusy: false,
            connection: harness.connection,
            reducer: reducer,
            sessionId: harness.sessionId,
            sessionStore: harness.sessionStore,
            sessionManager: harness.manager,
            onAsyncFailure: { text, _ in restoredText = text }
        )

        #expect(await waitForTestCondition(timeoutMs: 12_000) {
            await MainActor.run { restoredText != nil && !handler.isSending }
        })
        #expect(restoredText == "keep me")
        #expect(dispatchCount == 0)
        #expect(Self.userMessages(in: reducer).isEmpty)
        #expect(reducer.items.contains { item in
            if case .error(_, let message) = item { return message.hasPrefix("Not sent:") }
            return false
        })
        harness.tearDown()
    }

    @Test func unconfirmedResendReusesTheSameTurnOnlyForIdenticalContent() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let (connection, _) = makeTestConnection(sessionId: "s1")
        connection._sendAckTimeoutForTesting = .milliseconds(60)
        connection._turnSendRetryDelayForTesting = .milliseconds(1)
        var turnIdsByText: [String: Set<String>] = [:]
        connection._sendMessageForTesting = { message in
            if case .prompt(let text, _, _, _, let clientTurnId) = message, let clientTurnId {
                turnIdsByText[text, default: []].insert(clientTurnId)
            }
        }

        for text in ["same text", "same text", "different text"] {
            _ = handler.sendPrompt(
                text: text,
                attachments: [],
                isBusy: false,
                connection: connection,
                reducer: reducer,
                sessionId: "s1"
            )
            #expect(await waitForTestCondition(timeoutMs: 1_000) {
                await MainActor.run { !handler.isSending }
            })
        }

        #expect(turnIdsByText["same text"]?.count == 1, "Identical resend after lost ack reuses its turn id")
        #expect(turnIdsByText["different text"]?.isDisjoint(with: turnIdsByText["same text"] ?? []) == true)
        let errors = reducer.items.compactMap { item -> String? in
            if case .error(_, let message) = item { return message }
            return nil
        }
        #expect(errors.allSatisfy { $0.hasPrefix("Couldn't confirm your message was delivered") })
        #expect(Self.userMessages(in: reducer).isEmpty)
    }

    // MARK: - Helpers

    @MainActor
    private final class SuspendedCacheHistory: ChatSessionHistoryPort {
        let adapter: IOSChatSessionRuntimeAdapter
        private var gate: CheckedContinuation<Void, Never>?
        private var loads = 0
        var isSuspended: Bool { gate != nil }
        var canFetchRemoteHistory: Bool { adapter.canFetchRemoteHistory }
        var canFetchCatchUp: Bool { adapter.canFetchCatchUp }

        init(adapter: IOSChatSessionRuntimeAdapter) { self.adapter = adapter }

        func release() {
            gate?.resume()
            gate = nil
        }

        func loadCachedTrace(sessionId: String) async -> ChatSessionCachedTrace? {
            loads += 1
            if loads == 1 {
                // Cache IO need not stop when the awaiting connect is cancelled.
                await withCheckedContinuation { gate = $0 }
            }
            return nil
        }

        func saveCachedTrace(sessionId: String, events: [TraceEvent], page: TracePageMetadata?) async {
            await adapter.saveCachedTrace(sessionId: sessionId, events: events, page: page)
        }

        func fetchLatestTrace(scope: SessionRouteScope, sessionId: String, previewBytes: Int) async throws -> ChatSessionTraceSnapshot {
            try await adapter.fetchLatestTrace(scope: scope, sessionId: sessionId, previewBytes: previewBytes)
        }

        func fetchOlderTracePage(scope: SessionRouteScope, sessionId: String, cursor: String, previewBytes: Int) async throws -> ChatSessionTraceSnapshot {
            try await adapter.fetchOlderTracePage(scope: scope, sessionId: sessionId, cursor: cursor, previewBytes: previewBytes)
        }

        func fetchTracePageAround(scope: SessionRouteScope, sessionId: String, entryId: String, previewBytes: Int) async throws -> ChatSessionTraceSnapshot {
            try await adapter.fetchTracePageAround(scope: scope, sessionId: sessionId, entryId: entryId, previewBytes: previewBytes)
        }

        func fetchCatchUp(scope: SessionRouteScope, sessionId: String, since: Int) async throws -> ChatSessionCatchUpResponse {
            try await adapter.fetchCatchUp(scope: scope, sessionId: sessionId, since: since)
        }
    }

    private struct StreamingHarness {
        let sessionId: String
        let manager: ChatSessionManager
        let streams: ScriptedStreamFactory
        let connection: ServerConnection
        let sessionStore: SessionStore

        @MainActor func tearDown() {
            manager.cleanup()
            connection.disconnectStream()
        }
    }

    private func makeStreamingManager() async -> StreamingHarness {
        let sessionId = "ready-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }
        manager._focusedStreamLivenessForTesting = { .connected }
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))
        manager.markAppeared()
        manager.ensureConnected(connection: connection, sessionStore: sessionStore)
        _ = await streams.waitForCreated(1)
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId)))
        _ = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { manager.entryState == .streaming }
        }
        return StreamingHarness(
            sessionId: sessionId,
            manager: manager,
            streams: streams,
            connection: connection,
            sessionStore: sessionStore
        )
    }

    private static func userMessages(in reducer: TimelineReducer) -> [String] {
        reducer.items.compactMap { item in
            if case .userMessage(_, let text, _, _) = item { return text }
            return nil
        }
    }
}
