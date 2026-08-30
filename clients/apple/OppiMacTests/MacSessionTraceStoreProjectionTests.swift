import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session trace projection")
struct MacSessionTraceStoreProjectionTests {
    @Test func liveMessagesDoNotProjectSession() {
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .ready)
        store.select(target)

        store.applyServerMessageForTesting(
            .connected(session: makeSession(id: "selected-session", status: .busy)),
            target: target
        )
        store.applyServerMessageForTesting(
            .state(session: makeSession(id: "selected-session", status: .busy)),
            target: target
        )
        store.applyServerMessageForTesting(
            .sessionSummary(SessionSummary(from: makeSession(id: "selected-session", status: .error))),
            target: target
        )

        #expect(store.session?.id == "selected-session")
        #expect(store.session?.status == .ready)
    }

    @Test func liveMessagesDoNotFinalizeTerminalArtifacts() async throws {
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .busy)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: Self.makeClient())
        defer { store.clearSelection() }

        let manager = try #require(store._chatSessionManagerForTesting)
        manager.reducer.process(
            .toolStart(
                sessionId: target.sessionId,
                toolEventId: "tool-live",
                tool: "bash",
                args: [:]
            )
        )

        store.applyServerMessageForTesting(
            .state(session: makeSession(id: target.sessionId, status: .ready)),
            target: target
        )

        guard case .toolCall(_, _, _, _, _, _, let isDone) = store.items.first(where: { $0.id == "tool-live" }) else {
            Issue.record("Expected in-progress toolCall")
            return
        }
        #expect(!isDone)
        #expect(!manager.reducer.isToolInterrupted("tool-live"))
        #expect(store.session?.status == .busy)
    }

    @Test func interruptedToolStateIsExposedReadOnlyFromReducer() async throws {
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .busy)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: Self.makeClient())
        defer { store.clearSelection() }

        let manager = try #require(store._chatSessionManagerForTesting)
        manager.reducer.process(
            .toolStart(
                sessionId: target.sessionId,
                toolEventId: "tool-interrupted",
                tool: "bash",
                args: [:]
            )
        )
        #expect(!store.isToolInterrupted("tool-interrupted"))

        manager.reducer.finalizeTerminalArtifactsAsInterrupted()

        #expect(store.isToolInterrupted("tool-interrupted"))
    }

    @Test func toolHeaderMetadataIsExposedReadOnlyFromReducer() async throws {
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .busy)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: Self.makeClient())
        defer { store.clearSelection() }

        let manager = try #require(store._chatSessionManagerForTesting)
        let callSegments = [
            StyledSegment(text: "lookup", style: .bold),
            StyledSegment(text: " theme", style: .accent),
        ]
        let resultSegments = [
            StyledSegment(text: "3 matches", style: .success),
        ]
        manager.reducer.process(
            .toolStart(
                sessionId: target.sessionId,
                toolEventId: "tool-metadata",
                tool: "extensions.lookup",
                args: ["query": .string("theme")],
                callSegments: callSegments
            )
        )

        #expect(store.toolCallSegments(for: "tool-metadata") == callSegments)
        #expect(store.toolResultSegments(for: "tool-metadata") == nil)
        #expect(store.toolStartTime(for: "tool-metadata") != nil)
        #expect(store.toolElapsed(for: "tool-metadata") == nil)

        manager.reducer.process(
            .toolEnd(
                sessionId: target.sessionId,
                toolEventId: "tool-metadata",
                resultSegments: resultSegments
            )
        )

        #expect(store.toolResultSegments(for: "tool-metadata") == resultSegments)
        #expect(store.toolElapsed(for: "tool-metadata") != nil)
    }

    @Test func adapterUpsertProjectsSelectedSession() async throws {
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .ready)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: Self.makeClient())
        defer { store.clearSelection() }

        let adapter = try #require(store._runtimeAdapterForTesting)
        let connected = adapter.applySharedStoreUpdate(
            for: .connected(session: makeSession(id: target.sessionId, status: .busy, model: "connected/model")),
            sessionId: target.sessionId
        )
        #expect(!connected.didTransitionOutOfRunning)
        #expect(store.session?.status == .busy)
        #expect(store.session?.model == "connected/model")

        let ready = makeSession(id: target.sessionId, status: .ready, model: "state/model")
        let state = adapter.applySharedStoreUpdate(
            for: .state(session: ready),
            sessionId: target.sessionId
        )
        #expect(state.didTransitionOutOfRunning)
        #expect(store.session?.status == .ready)
        #expect(store.session?.model == "state/model")

        let summary = adapter.applySharedStoreUpdate(
            for: .sessionSummary(SessionSummary(from: makeSession(id: target.sessionId, status: .error))),
            sessionId: target.sessionId
        )
        #expect(!summary.didTransitionOutOfRunning)
        #expect(store.session?.status == .error)
    }

    @Test func adapterUpsertIgnoresOtherSessions() async throws {
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .ready)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: Self.makeClient())
        defer { store.clearSelection() }

        let adapter = try #require(store._runtimeAdapterForTesting)
        let other = makeSession(id: "other-session", status: .busy)
        adapter.upsert(other)
        _ = adapter.applySharedStoreUpdate(
            for: .connected(session: other),
            sessionId: other.id
        )

        #expect(store.session?.id == "selected-session")
        #expect(store.session?.status == .ready)
        #expect(adapter.session(id: other.id)?.status == .busy)
    }

    @Test func historyReloadProjectsSessionThroughUpsert() async throws {
        let client = Self.makeClient()
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .ready)
        store.select(target)
        await store.installSessionRuntimeForTesting(client: client)
        defer { store.clearSelection() }

        let manager = try #require(store._chatSessionManagerForTesting)
        let fetched = makeSession(id: target.sessionId, status: .busy, model: "fetched/model")
        manager._fetchSessionTraceForTesting = { _, _ in
            (fetched, [])
        }

        await store.load(target: target, client: client)

        #expect(store.session?.id == target.sessionId)
        #expect(store.session?.status == .busy)
        #expect(store.session?.model == "fetched/model")
        #expect(store._chatSessionManagerForTesting === manager)
    }

    @Test func optimisticThinkingLevelWritesSession() async {
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .ready)
        store.select(target)
        store._sendLiveMessageForTesting = { _ in true }

        await store.setThinkingLevel(
            .high,
            target: target,
            client: Self.makeClient()
        )

        #expect(store.session?.thinkingLevel == ThinkingLevel.high.rawValue)
        #expect(store.thinkingLevel == .high)
    }

    @Test func opensFocusedStreamAfterHistoryRefreshUnlessStillStopped() {
        #expect(MacSessionTraceStore._shouldOpenFocusedStreamForTesting(.ready))
        #expect(MacSessionTraceStore._shouldOpenFocusedStreamForTesting(.busy))
        #expect(MacSessionTraceStore._shouldOpenFocusedStreamForTesting(.error))
        #expect(!MacSessionTraceStore._shouldOpenFocusedStreamForTesting(.stopped))
    }

    private static func makeClient() -> MacWorkspaceClient {
        MacWorkspaceClient(
            socketPath: "/tmp/oppi-mac-projection.sock",
            token: "sk_owner",
            transport: RecordingLocalHTTPTransport(response: Self.json("{}"))
        )
    }

    private static func json(_ body: String) -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
    }

    private func makeTarget(sessionId: String, status: SessionStatus) -> MacSelectedSessionTarget {
        let session = makeSession(id: sessionId, status: status)
        return MacSelectedSessionTarget(
            workspaceId: "workspace-projection",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }

    private func makeSession(
        id: String,
        status: SessionStatus,
        model: String = "provider/model"
    ) -> Session {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return Session(
            id: id,
            workspaceId: "workspace-projection",
            workspaceName: "Workspace",
            status: status,
            createdAt: now,
            lastActivity: now,
            model: model,
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello"
        )
    }
}
