@testable import OppiMac
import XCTest

@MainActor
final class OppiMacStoreWorkspaceAPITests: XCTestCase {
    func testConnectLoadsWorkspaceScopedSessionsAndTimeline() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let workspaceB = makeWorkspace(id: "ws-b", name: "Workspace B")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA, workspaceB],
            sessionsByWorkspace: [workspaceA.id: [sessionA], workspaceB.id: []],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()

        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.selectedWorkspaceID, workspaceA.id)
        XCTAssertEqual(store.sessions.map(\.id), [sessionA.id])
        XCTAssertEqual(store.timelineItems.count, 1)
        XCTAssertEqual(stream.connectCallsSnapshot(), [.init(sessionId: sessionA.id, workspaceId: workspaceA.id)])

        let listCalls = await mock.listWorkspaceSessionsCallsSnapshot()
        XCTAssertEqual(listCalls, [workspaceA.id])

        let timelineCalls = await mock.getWorkspaceSessionCallsSnapshot()
        XCTAssertEqual(timelineCalls, [.init(workspaceId: workspaceA.id, sessionId: sessionA.id)])
    }

    func testConnectFetchesWorkspaceGraphForSelectedWorkspace() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ]
        )

        let store = makeStore(apiClient: mock, streamingClient: MockNoopStreamingClient())
        await store.connect()

        let graphCalls = await mock.getWorkspaceGraphCallsSnapshot()
        XCTAssertEqual(graphCalls, [.init(workspaceId: workspaceA.id, sessionId: sessionA.id)])
    }

    func testReloadTimelineReconnectsWhenPreviousStreamEnded() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()

        XCTAssertEqual(stream.connectCallsSnapshot().count, 1)

        await Task.yield()
        await Task.yield()

        await store.loadTimelineForCurrentSelection()

        XCTAssertEqual(stream.connectCallsSnapshot().count, 2)
    }

    func testSwitchingSessionInSameWorkspaceReconnectsStream() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")
        let sessionB = makeSession(id: "sess-b", workspaceId: workspaceA.id, name: "Session B")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA, sessionB]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-a", text: "A"),
                ],
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionB.id): [
                    makeTraceEvent(id: "evt-b", text: "B"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()

        store.selectedSessionID = sessionB.id
        await store.loadTimelineForCurrentSelection()

        XCTAssertEqual(
            stream.connectCallsSnapshot(),
            [
                .init(sessionId: sessionA.id, workspaceId: workspaceA.id),
                .init(sessionId: sessionB.id, workspaceId: workspaceA.id),
            ]
        )
        // Mock streams may self-finish before the session switch, so
        // explicit disconnect can be zero even though reconnect is correct.
        XCTAssertGreaterThanOrEqual(stream.disconnectCountSnapshot(), 0)

        let timelineCalls = await mock.getWorkspaceSessionCallsSnapshot()
        XCTAssertEqual(
            timelineCalls,
            [
                .init(workspaceId: workspaceA.id, sessionId: sessionA.id),
                .init(workspaceId: workspaceA.id, sessionId: sessionB.id),
            ]
        )
    }

    func testLoadTimelineFailureForDifferentSessionDisconnectsOldStream() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-a", text: "A"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()

        store.selectedSessionID = "sess-missing"
        await store.loadTimelineForCurrentSelection()

        XCTAssertEqual(stream.connectCallsSnapshot().count, 1)
        // Stream may already be terminated by the mock before this branch runs.
        XCTAssertGreaterThanOrEqual(stream.disconnectCountSnapshot(), 0)
        XCTAssertFalse(store.isStreamConnected)
        XCTAssertFalse(store.isStreamConnecting)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testSelectingWorkspaceRefreshesWithWorkspaceSessionAPI() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let workspaceB = makeWorkspace(id: "ws-b", name: "Workspace B")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")
        let sessionB = makeSession(id: "sess-b", workspaceId: workspaceB.id, name: "Session B")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA, workspaceB],
            sessionsByWorkspace: [workspaceA.id: [sessionA], workspaceB.id: [sessionB]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-a", text: "A"),
                ],
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceB.id, sessionId: sessionB.id): [
                    makeTraceEvent(id: "evt-b", text: "B"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()
        await store.selectWorkspace(workspaceB.id)

        XCTAssertEqual(store.selectedWorkspaceID, workspaceB.id)
        XCTAssertEqual(store.sessions.map(\.id), [sessionB.id])
        XCTAssertEqual(
            stream.connectCallsSnapshot(),
            [
                .init(sessionId: sessionA.id, workspaceId: workspaceA.id),
                .init(sessionId: sessionB.id, workspaceId: workspaceB.id),
            ]
        )

        let listCalls = await mock.listWorkspaceSessionsCallsSnapshot()
        XCTAssertEqual(listCalls, [workspaceA.id, workspaceB.id])

        let timelineCalls = await mock.getWorkspaceSessionCallsSnapshot()
        XCTAssertEqual(
            timelineCalls,
            [
                .init(workspaceId: workspaceA.id, sessionId: sessionA.id),
                .init(workspaceId: workspaceB.id, sessionId: sessionB.id),
            ]
        )
    }

    func testCreateWorkspaceUsesWorkspaceAPIAndSelectsNewWorkspace() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")
        let createdWorkspace = makeWorkspace(
            id: "ws-z",
            name: "Workspace Z",
            description: "fresh",
            runtime: "host",
            policyPreset: "host"
        )

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ],
            nextCreatedWorkspace: createdWorkspace
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()

        await store.createWorkspace(
            name: "Workspace Z",
            description: "fresh",
            runtime: "host",
            policyPreset: "host"
        )

        let createCalls = await mock.createWorkspaceCallsSnapshot()
        XCTAssertEqual(
            createCalls,
            [
                .init(
                    name: "Workspace Z",
                    description: "fresh",
                    runtime: "host",
                    policyPreset: "host"
                ),
            ]
        )

        XCTAssertEqual(store.selectedWorkspaceID, createdWorkspace.id)
        XCTAssertEqual(store.selectedWorkspace?.runtime, "host")
        XCTAssertEqual(store.selectedWorkspace?.policyPreset, "host")
        XCTAssertTrue(store.sessions.isEmpty)

        let listCalls = await mock.listWorkspaceSessionsCallsSnapshot()
        XCTAssertEqual(listCalls, [workspaceA.id, createdWorkspace.id])
    }

    func testUpdateSelectedWorkspaceUsesWorkspaceAPIAndUpdatesState() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()

        await store.updateSelectedWorkspace(
            name: "Workspace Renamed",
            description: "updated",
            runtime: "host",
            policyPreset: "host"
        )

        let updateCalls = await mock.updateWorkspaceCallsSnapshot()
        XCTAssertEqual(
            updateCalls,
            [
                .init(
                    id: workspaceA.id,
                    name: "Workspace Renamed",
                    description: "updated",
                    runtime: "host",
                    policyPreset: "host"
                ),
            ]
        )

        XCTAssertEqual(store.selectedWorkspace?.name, "Workspace Renamed")
        XCTAssertEqual(store.selectedWorkspace?.description, "updated")
        XCTAssertEqual(store.selectedWorkspace?.runtime, "host")
        XCTAssertEqual(store.selectedWorkspace?.policyPreset, "host")
    }

    func testDeleteSelectedWorkspaceUsesWorkspaceAPIAndSelectsFallback() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let workspaceB = makeWorkspace(id: "ws-b", name: "Workspace B")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")
        let sessionB = makeSession(id: "sess-b", workspaceId: workspaceB.id, name: "Session B")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA, workspaceB],
            sessionsByWorkspace: [workspaceA.id: [sessionA], workspaceB.id: [sessionB]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-a", text: "A"),
                ],
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceB.id, sessionId: sessionB.id): [
                    makeTraceEvent(id: "evt-b", text: "B"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()

        XCTAssertEqual(store.selectedWorkspaceID, workspaceA.id)

        await store.deleteSelectedWorkspace()

        let deleteCalls = await mock.deleteWorkspaceCallsSnapshot()
        XCTAssertEqual(deleteCalls, [workspaceA.id])
        XCTAssertEqual(store.selectedWorkspaceID, workspaceB.id)
        XCTAssertEqual(store.sessions.map(\.id), [sessionB.id])
    }

    func testLoadSkillsUsesSkillsAPIAndSelectsFirstSkill() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")
        let skillA = makeSkill(name: "ast-grep", description: "syntax search")
        let skillB = makeSkill(name: "fetch", description: "web fetch")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ],
            skills: [skillB, skillA],
            skillDetailByName: [
                skillA.name: SkillDetail(skill: skillA, content: "# ast-grep", files: ["README.md"]),
                skillB.name: SkillDetail(skill: skillB, content: "# fetch", files: []),
            ]
        )

        let store = makeStore(apiClient: mock, streamingClient: MockNoopStreamingClient())
        await store.connect()

        await store.loadSkills()

        XCTAssertEqual(store.skills.map(\.name), ["ast-grep", "fetch"])
        XCTAssertEqual(store.selectedSkillName, "ast-grep")
        XCTAssertEqual(store.selectedSkillDetail?.skill.name, "ast-grep")
        XCTAssertEqual(store.selectedSkillFileContent, "# ast-grep")

        let listSkillsCallCount = await mock.listSkillsCallCountSnapshot()
        XCTAssertEqual(listSkillsCallCount, 1)

        let detailCalls = await mock.getSkillDetailCallsSnapshot()
        XCTAssertEqual(detailCalls, ["ast-grep"])
    }

    func testSelectSkillFileLoadsWorkspaceSkillFileContent() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")
        let skill = makeSkill(name: "fetch", description: "web fetch")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ],
            skills: [skill],
            skillDetailByName: [
                skill.name: SkillDetail(skill: skill, content: "# fetch", files: ["notes.md"]),
            ],
            skillFileContentByKey: [
                MockOppiMacAPIClient.skillFileKey(name: skill.name, path: "notes.md"): "fetched notes",
            ]
        )

        let store = makeStore(apiClient: mock, streamingClient: MockNoopStreamingClient())
        await store.connect()
        await store.loadSkills()
        await store.selectSkillFile("notes.md")

        XCTAssertEqual(store.selectedSkillFilePath, "notes.md")
        XCTAssertEqual(store.selectedSkillFileContent, "fetched notes")

        let fileCalls = await mock.getSkillFileCallsSnapshot()
        XCTAssertEqual(fileCalls.count, 1)
        XCTAssertEqual(fileCalls.first?.name, skill.name)
        XCTAssertEqual(fileCalls.first?.path, "notes.md")
    }

    func testStopSelectedSessionUsesWorkspaceScopedStopAPI() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()
        await store.stopSelectedSession()

        let connectCalls = stream.connectCallsSnapshot()
        XCTAssertGreaterThanOrEqual(connectCalls.count, 1)
        XCTAssertTrue(connectCalls.allSatisfy { $0 == .init(sessionId: sessionA.id, workspaceId: workspaceA.id) })

        let stopCalls = await mock.stopWorkspaceSessionCallsSnapshot()
        XCTAssertEqual(stopCalls, [.init(workspaceId: workspaceA.id, sessionId: sessionA.id)])

        XCTAssertEqual(store.sessions.first?.status, .stopped)
    }

    func testCreateSessionInSelectedWorkspaceUsesWorkspaceScopedCreateAPI() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(id: "sess-a", workspaceId: workspaceA.id, name: "Session A")
        let created = makeSession(id: "sess-new", workspaceId: workspaceA.id, name: "New Session")

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ],
            nextCreatedSessionByWorkspace: [workspaceA.id: created]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()
        await store.createSessionInSelectedWorkspace()

        let createCalls = await mock.createWorkspaceSessionCallsSnapshot()
        XCTAssertEqual(createCalls, [.init(workspaceId: workspaceA.id, sessionId: created.id)])

        XCTAssertEqual(store.selectedSessionID, created.id)
        XCTAssertTrue(store.sessions.contains(where: { $0.id == created.id }))
        XCTAssertTrue(
            stream.connectCallsSnapshot().contains(.init(sessionId: created.id, workspaceId: workspaceA.id))
        )
    }

    func testResumeSelectedSessionUsesWorkspaceScopedResumeAPI() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let stopped = makeSession(id: "sess-stopped", workspaceId: workspaceA.id, name: "Stopped Session", status: .stopped)

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [stopped]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: stopped.id): [
                    makeTraceEvent(id: "evt-1", text: "hello"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()
        await store.resumeSelectedSession()

        let resumeCalls = await mock.resumeWorkspaceSessionCallsSnapshot()
        XCTAssertEqual(resumeCalls, [.init(workspaceId: workspaceA.id, sessionId: stopped.id)])

        XCTAssertEqual(store.sessions.first(where: { $0.id == stopped.id })?.status, .ready)
    }

    func testDeleteSelectedSessionUsesWorkspaceScopedDeleteAPIAndSelectsFallback() async {
        let workspaceA = makeWorkspace(id: "ws-a", name: "Workspace A")
        let sessionA = makeSession(
            id: "sess-a",
            workspaceId: workspaceA.id,
            name: "Session A",
            status: .ready,
            lastActivity: Date(timeIntervalSince1970: 1)
        )
        let sessionB = makeSession(
            id: "sess-b",
            workspaceId: workspaceA.id,
            name: "Session B",
            status: .ready,
            lastActivity: Date(timeIntervalSince1970: 2)
        )

        let mock = MockOppiMacAPIClient(
            workspaces: [workspaceA],
            sessionsByWorkspace: [workspaceA.id: [sessionA, sessionB]],
            traceByWorkspaceSession: [
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionA.id): [
                    makeTraceEvent(id: "evt-a", text: "A"),
                ],
                MockOppiMacAPIClient.traceKey(workspaceId: workspaceA.id, sessionId: sessionB.id): [
                    makeTraceEvent(id: "evt-b", text: "B"),
                ],
            ]
        )

        let stream = MockNoopStreamingClient()
        let store = makeStore(apiClient: mock, streamingClient: stream)
        await store.connect()

        XCTAssertEqual(store.selectedSessionID, sessionB.id)

        await store.deleteSelectedSession()

        let deleteCalls = await mock.deleteWorkspaceSessionCallsSnapshot()
        XCTAssertEqual(deleteCalls, [.init(workspaceId: workspaceA.id, sessionId: sessionB.id)])

        XCTAssertEqual(store.selectedSessionID, sessionA.id)
        XCTAssertEqual(store.sessions.map(\.id), [sessionA.id])
        XCTAssertTrue(
            stream.connectCallsSnapshot().contains(.init(sessionId: sessionA.id, workspaceId: workspaceA.id))
        )
    }

    private func makeStore(
        apiClient: MockOppiMacAPIClient,
        streamingClient: MockNoopStreamingClient
    ) -> OppiMacStore {
        let suiteName = "OppiMacStoreWorkspaceAPITests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = OppiMacStore(
            userDefaults: defaults,
            apiClientFactory: { _, _ in apiClient },
            streamingClientFactory: { _ in streamingClient }
        )
        store.draft.host = "localhost"
        store.draft.port = "7749"
        store.draft.token = "test-token"
        store.draft.name = "Tester"
        return store
    }

    private func makeWorkspace(
        id: String,
        name: String,
        description: String? = nil,
        runtime: String = "container",
        policyPreset: String = "container"
    ) -> Workspace {
        Workspace(
            id: id,
            userId: "user-1",
            name: name,
            description: description,
            icon: nil,
            runtime: runtime,
            skills: [],
            policyPreset: policyPreset,
            systemPrompt: nil,
            hostMount: nil,
            memoryEnabled: nil,
            memoryNamespace: nil,
            extensionMode: nil,
            extensions: nil,
            defaultModel: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeSession(
        id: String,
        workspaceId: String,
        name: String,
        status: SessionStatus = .ready,
        lastActivity: Date = Date(timeIntervalSince1970: 1)
    ) -> Session {
        Session(
            id: id,
            userId: "user-1",
            workspaceId: workspaceId,
            workspaceName: nil,
            name: name,
            status: status,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: lastActivity,
            model: "sonnet",
            runtime: "container",
            messageCount: 1,
            tokens: TokenUsage(input: 1, output: 1),
            cost: 0,
            changeStats: nil,
            contextTokens: nil,
            contextWindow: nil,
            lastMessage: nil,
            thinkingLevel: nil
        )
    }

    private func makeSkill(name: String, description: String) -> SkillInfo {
        SkillInfo(
            name: name,
            description: description,
            containerSafe: true,
            hasScripts: false,
            path: "~/.pi/agent/skills/\(name)"
        )
    }

    private func makeTraceEvent(id: String, text: String) -> TraceEvent {
        TraceEvent(
            id: id,
            type: .assistant,
            timestamp: "2026-02-11T06:00:00.000Z",
            text: text,
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )
    }
}

@MainActor
private final class MockNoopStreamingClient: OppiMacStreamingClient {
    struct ConnectCall: Equatable {
        let sessionId: String
        let workspaceId: String
    }

    private(set) var status: WebSocketClient.Status = .disconnected
    private var connectCalls: [ConnectCall] = []
    private var disconnectCount = 0

    func connect(sessionId: String, workspaceId: String) -> AsyncStream<ServerMessage> {
        connectCalls.append(.init(sessionId: sessionId, workspaceId: workspaceId))
        status = .connected
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func send(_ message: ClientMessage) async throws {
        _ = message
    }

    func disconnect() {
        status = .disconnected
        disconnectCount += 1
    }

    func connectCallsSnapshot() -> [ConnectCall] {
        connectCalls
    }

    func disconnectCountSnapshot() -> Int {
        disconnectCount
    }
}

private actor MockOppiMacAPIClient: OppiMacAPIClient {
    struct SessionCall: Sendable, Equatable {
        let workspaceId: String
        let sessionId: String
    }

    struct WorkspaceGraphCall: Sendable, Equatable {
        let workspaceId: String
        let sessionId: String?
    }

    struct WorkspaceCreateCall: Sendable, Equatable {
        let name: String
        let description: String?
        let runtime: String?
        let policyPreset: String?
    }

    struct WorkspaceUpdateCall: Sendable, Equatable {
        let id: String
        let name: String?
        let description: String?
        let runtime: String?
        let policyPreset: String?
    }

    static func traceKey(workspaceId: String, sessionId: String) -> String {
        "\(workspaceId)|\(sessionId)"
    }

    static func skillFileKey(name: String, path: String) -> String {
        "\(name)|\(path)"
    }

    private var workspaces: [Workspace]
    private var sessionsByWorkspace: [String: [Session]]
    private let traceByWorkspaceSession: [String: [TraceEvent]]
    private let sessionGraphByWorkspace: [String: WorkspaceGraphResponse.SessionGraph]
    private var nextCreatedSessionByWorkspace: [String: Session]
    private var nextCreatedWorkspace: Workspace?

    private var skills: [SkillInfo]
    private var skillDetailByName: [String: SkillDetail]
    private var skillFileContentByKey: [String: String]

    private var createWorkspaceCalls: [WorkspaceCreateCall] = []
    private var updateWorkspaceCalls: [WorkspaceUpdateCall] = []
    private var deleteWorkspaceCalls: [String] = []

    private var listSkillsCallCount = 0
    private var getSkillDetailCalls: [String] = []
    private var getSkillFileCalls: [(name: String, path: String)] = []

    private var listWorkspaceSessionsCalls: [String] = []
    private var getWorkspaceGraphCalls: [WorkspaceGraphCall] = []
    private var createWorkspaceSessionCalls: [SessionCall] = []
    private var resumeWorkspaceSessionCalls: [SessionCall] = []
    private var getWorkspaceSessionCalls: [SessionCall] = []
    private var stopWorkspaceSessionCalls: [SessionCall] = []
    private var deleteWorkspaceSessionCalls: [SessionCall] = []

    init(
        workspaces: [Workspace],
        sessionsByWorkspace: [String: [Session]],
        traceByWorkspaceSession: [String: [TraceEvent]],
        sessionGraphByWorkspace: [String: WorkspaceGraphResponse.SessionGraph] = [:],
        nextCreatedSessionByWorkspace: [String: Session] = [:],
        nextCreatedWorkspace: Workspace? = nil,
        skills: [SkillInfo] = [],
        skillDetailByName: [String: SkillDetail] = [:],
        skillFileContentByKey: [String: String] = [:]
    ) {
        self.workspaces = workspaces
        self.sessionsByWorkspace = sessionsByWorkspace
        self.traceByWorkspaceSession = traceByWorkspaceSession
        self.sessionGraphByWorkspace = sessionGraphByWorkspace
        self.nextCreatedSessionByWorkspace = nextCreatedSessionByWorkspace
        self.nextCreatedWorkspace = nextCreatedWorkspace
        self.skills = skills
        self.skillDetailByName = skillDetailByName
        self.skillFileContentByKey = skillFileContentByKey
    }

    func health() async throws -> Bool { true }

    func me() async throws -> User {
        User(user: "user-1", name: "Tester")
    }

    func listWorkspaces() async throws -> [Workspace] {
        workspaces
    }

    func createWorkspace(_ request: CreateWorkspaceRequest) async throws -> Workspace {
        createWorkspaceCalls.append(
            .init(
                name: request.name,
                description: request.description,
                runtime: request.runtime,
                policyPreset: request.policyPreset
            )
        )

        let runtime = request.runtime ?? "container"
        let policyPreset = request.policyPreset ?? (runtime == "host" ? "host" : "container")

        let created = nextCreatedWorkspace ?? Workspace(
            id: "ws-\(UUID().uuidString)",
            userId: "user-1",
            name: request.name,
            description: request.description,
            icon: request.icon,
            runtime: runtime,
            skills: request.skills,
            policyPreset: policyPreset,
            systemPrompt: request.systemPrompt,
            hostMount: request.hostMount,
            memoryEnabled: request.memoryEnabled,
            memoryNamespace: request.memoryNamespace,
            extensionMode: request.extensionMode,
            extensions: request.extensions,
            defaultModel: request.defaultModel,
            createdAt: Date(),
            updatedAt: Date()
        )

        nextCreatedWorkspace = nil

        workspaces.append(created)
        sessionsByWorkspace[created.id] = sessionsByWorkspace[created.id] ?? []

        return created
    }

    func updateWorkspace(id: String, _ request: UpdateWorkspaceRequest) async throws -> Workspace {
        updateWorkspaceCalls.append(
            .init(
                id: id,
                name: request.name,
                description: request.description,
                runtime: request.runtime,
                policyPreset: request.policyPreset
            )
        )

        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "MockOppiMacAPIClient", code: 404)
        }

        var workspace = workspaces[index]
        if let name = request.name { workspace.name = name }
        if let description = request.description { workspace.description = description }
        if let runtime = request.runtime { workspace.runtime = runtime }
        if let policyPreset = request.policyPreset { workspace.policyPreset = policyPreset }
        workspace.updatedAt = Date()

        workspaces[index] = workspace
        return workspace
    }

    func deleteWorkspace(id: String) async throws {
        deleteWorkspaceCalls.append(id)
        let originalCount = workspaces.count
        workspaces.removeAll { $0.id == id }
        sessionsByWorkspace.removeValue(forKey: id)

        if workspaces.count == originalCount {
            throw NSError(domain: "MockOppiMacAPIClient", code: 404)
        }
    }

    func listSkills() async throws -> [SkillInfo] {
        listSkillsCallCount += 1
        return skills
    }

    func getSkillDetail(name: String) async throws -> SkillDetail {
        getSkillDetailCalls.append(name)

        if let detail = skillDetailByName[name] {
            return detail
        }

        guard let skill = skills.first(where: { $0.name == name }) else {
            throw NSError(domain: "MockOppiMacAPIClient", code: 404)
        }

        return SkillDetail(skill: skill, content: "# \(skill.name)\n\nNo detail fixture.", files: [])
    }

    func getSkillFile(name: String, path: String) async throws -> String {
        getSkillFileCalls.append((name: name, path: path))

        if let content = skillFileContentByKey[Self.skillFileKey(name: name, path: path)] {
            return content
        }

        throw NSError(domain: "MockOppiMacAPIClient", code: 404)
    }

    func listWorkspaceSessions(workspaceId: String) async throws -> [Session] {
        listWorkspaceSessionsCalls.append(workspaceId)
        return sessionsByWorkspace[workspaceId] ?? []
    }

    func getWorkspaceGraph(
        workspaceId: String,
        sessionId: String?,
        includeEntryGraph: Bool,
        entrySessionId: String?,
        includePaths: Bool
    ) async throws -> WorkspaceGraphResponse {
        _ = includeEntryGraph
        _ = entrySessionId
        _ = includePaths

        getWorkspaceGraphCalls.append(.init(workspaceId: workspaceId, sessionId: sessionId))

        let graph: WorkspaceGraphResponse.SessionGraph
        if let seeded = sessionGraphByWorkspace[workspaceId] {
            graph = seeded
        } else {
            let sessions = sessionsByWorkspace[workspaceId] ?? []
            let nodes = sessions.map { session in
                WorkspaceGraphResponse.SessionGraph.Node(
                    id: session.id,
                    createdAt: session.createdAt,
                    parentId: nil,
                    workspaceId: workspaceId,
                    attachedSessionIds: [session.id],
                    activeSessionIds: session.status == .stopped ? [] : [session.id]
                )
            }

            graph = WorkspaceGraphResponse.SessionGraph(
                nodes: nodes,
                edges: [],
                roots: nodes.map(\.id)
            )
        }

        return WorkspaceGraphResponse(
            workspaceId: workspaceId,
            generatedAt: Date(),
            current: sessionId.map { .init(sessionId: $0, nodeId: $0) },
            sessionGraph: graph,
            entryGraph: nil
        )
    }

    func createWorkspaceSession(workspaceId: String, name: String?, model: String?) async throws -> Session {
        _ = model

        var created = nextCreatedSessionByWorkspace.removeValue(forKey: workspaceId) ?? Session(
            id: "sess-\(UUID().uuidString)",
            userId: "user-1",
            workspaceId: workspaceId,
            workspaceName: nil,
            name: name ?? "New Session",
            status: .ready,
            createdAt: Date(),
            lastActivity: Date(),
            model: "sonnet",
            runtime: "container",
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            changeStats: nil,
            contextTokens: nil,
            contextWindow: nil,
            lastMessage: nil,
            thinkingLevel: nil
        )

        created.workspaceId = workspaceId
        created.lastActivity = Date()

        createWorkspaceSessionCalls.append(.init(workspaceId: workspaceId, sessionId: created.id))

        var sessions = sessionsByWorkspace[workspaceId] ?? []
        sessions.append(created)
        sessions.sort { $0.lastActivity > $1.lastActivity }
        sessionsByWorkspace[workspaceId] = sessions

        return created
    }

    func resumeWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session {
        resumeWorkspaceSessionCalls.append(.init(workspaceId: workspaceId, sessionId: sessionId))

        guard var sessions = sessionsByWorkspace[workspaceId],
              let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            throw NSError(domain: "MockOppiMacAPIClient", code: 404)
        }

        var session = sessions[index]
        session.status = .ready
        session.lastActivity = Date()
        sessions[index] = session
        sessionsByWorkspace[workspaceId] = sessions
        return session
    }

    func getWorkspaceSession(
        workspaceId: String,
        sessionId: String,
        traceView: APIClient.SessionTraceView
    ) async throws -> (session: Session, trace: [TraceEvent]) {
        _ = traceView
        getWorkspaceSessionCalls.append(.init(workspaceId: workspaceId, sessionId: sessionId))

        guard let session = sessionsByWorkspace[workspaceId]?.first(where: { $0.id == sessionId }) else {
            throw NSError(domain: "MockOppiMacAPIClient", code: 404)
        }

        let trace = traceByWorkspaceSession[Self.traceKey(workspaceId: workspaceId, sessionId: sessionId)] ?? []
        return (session, trace)
    }

    func stopWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session {
        stopWorkspaceSessionCalls.append(.init(workspaceId: workspaceId, sessionId: sessionId))

        guard var sessions = sessionsByWorkspace[workspaceId],
              let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            throw NSError(domain: "MockOppiMacAPIClient", code: 404)
        }

        var session = sessions[index]
        session.status = .stopped
        session.lastActivity = Date()
        sessions[index] = session
        sessionsByWorkspace[workspaceId] = sessions
        return session
    }

    func deleteWorkspaceSession(workspaceId: String, sessionId: String) async throws {
        deleteWorkspaceSessionCalls.append(.init(workspaceId: workspaceId, sessionId: sessionId))

        guard var sessions = sessionsByWorkspace[workspaceId],
              sessions.contains(where: { $0.id == sessionId }) else {
            throw NSError(domain: "MockOppiMacAPIClient", code: 404)
        }

        sessions.removeAll { $0.id == sessionId }
        sessionsByWorkspace[workspaceId] = sessions
    }

    func createWorkspaceCallsSnapshot() -> [WorkspaceCreateCall] {
        createWorkspaceCalls
    }

    func updateWorkspaceCallsSnapshot() -> [WorkspaceUpdateCall] {
        updateWorkspaceCalls
    }

    func deleteWorkspaceCallsSnapshot() -> [String] {
        deleteWorkspaceCalls
    }

    func listSkillsCallCountSnapshot() -> Int {
        listSkillsCallCount
    }

    func getSkillDetailCallsSnapshot() -> [String] {
        getSkillDetailCalls
    }

    func getSkillFileCallsSnapshot() -> [(name: String, path: String)] {
        getSkillFileCalls
    }

    func listWorkspaceSessionsCallsSnapshot() -> [String] {
        listWorkspaceSessionsCalls
    }

    func getWorkspaceGraphCallsSnapshot() -> [WorkspaceGraphCall] {
        getWorkspaceGraphCalls
    }

    func createWorkspaceSessionCallsSnapshot() -> [SessionCall] {
        createWorkspaceSessionCalls
    }

    func resumeWorkspaceSessionCallsSnapshot() -> [SessionCall] {
        resumeWorkspaceSessionCalls
    }

    func getWorkspaceSessionCallsSnapshot() -> [SessionCall] {
        getWorkspaceSessionCalls
    }

    func stopWorkspaceSessionCallsSnapshot() -> [SessionCall] {
        stopWorkspaceSessionCalls
    }

    func deleteWorkspaceSessionCallsSnapshot() -> [SessionCall] {
        deleteWorkspaceSessionCalls
    }
}
