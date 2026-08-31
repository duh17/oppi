import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session pane deck")
struct MacSessionPaneDeckTests {
    @Test func startsWithOneEmptyQuickSessionPane() throws {
        let deck = MacSessionPaneDeck()
        let runtime = try #require(deck.focusedRuntime)

        #expect(deck.layout != nil)
        #expect(deck.root == .pane(MacSessionPane(id: runtime.id, route: nil)))
        #expect(deck.focusedSessionID == nil)
        #expect(deck.visibleSessionIDs.isEmpty)
        #expect(deck.paneCount == 1)
        #expect(deck.canSplit)
        #expect(runtime.isEmpty)
        #expect(runtime.target == nil)
    }

    @Test func openOrFocusKeepsOneStableRuntimePerVisibleSession() throws {
        let factory = StoreFactoryRecorder()
        let deck = MacSessionPaneDeck(storeFactory: factory.make)
        let first = target(sessionID: "session-a", workspaceID: "workspace-a", status: .ready)

        let opened = try #require(deck.openOrFocus(first))
        let paneID = opened.id
        let composerState = opened.composerState
        composerState.draft = "Unsent prompt"
        let updated = target(sessionID: "session-a", workspaceID: "workspace-a", status: .busy)
        let reopened = try #require(deck.openOrFocus(updated))

        #expect(opened === reopened)
        #expect(reopened.id == paneID)
        #expect(reopened.traceStore === factory.stores[0])
        #expect(reopened.composerState === composerState)
        #expect(reopened.composerState.draft == "Unsent prompt")
        #expect(reopened.target?.summary.status == .busy)
        #expect(reopened.traceStore.session?.status == .busy)
        #expect(!reopened.traceStore._sessionRuntimeLoopRunningForTesting)
        #expect(factory.stores.count == 1)
        #expect(deck.paneCount == 1)
        #expect(deck.visibleSessionIDs == ["session-a"])
        #expect(deck.focusedSessionID == "session-a")
        #expect(deck.canSplit)
    }

    @Test func replacingTheFocusedTargetReusesItsPaneRuntimeAndStore() throws {
        let factory = StoreFactoryRecorder()
        let deck = MacSessionPaneDeck(storeFactory: factory.make)
        let runtime = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace-a")))
        let paneID = runtime.id
        let store = runtime.traceStore
        let composerState = runtime.composerState
        composerState.draft = "Belongs to session A"

        let replaced = try #require(deck.replaceFocused(
            with: target(sessionID: "session-b", workspaceID: "workspace-b")
        ))

        #expect(replaced === runtime)
        #expect(replaced.id == paneID)
        #expect(replaced.traceStore === store)
        #expect(replaced.composerState === composerState)
        #expect(replaced.composerState.draft.isEmpty)
        #expect(store.selectedTarget?.sessionId == "session-b")
        #expect(deck.visibleSessionIDs == ["session-b"])
        #expect(deck.focusedSessionID == "session-b")
        #expect(factory.stores.count == 1)
    }

    @Test func splitFocusedRightAndBelowBuildTheExpectedTree() throws {
        let factory = StoreFactoryRecorder()
        let deck = MacSessionPaneDeck(storeFactory: factory.make)
        let paneA = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))
        let paneB = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-b", workspaceID: "workspace")
        ))
        paneA.composerState.draft = "Pane A draft"
        #expect(deck.layout?.split(id: try #require(rootSplitID(deck.root)))?.axis == .horizontal)

        #expect(deck.focus(paneID: paneA.id))
        let paneC = try #require(deck.splitFocusedBelow(
            with: target(sessionID: "session-c", workspaceID: "workspace")
        ))

        #expect(deck.visibleSessionIDs == ["session-a", "session-c", "session-b"])
        #expect(deck.focusedSessionID == "session-c")
        #expect(deck.runtime(for: paneA.id) === paneA)
        #expect(paneA.composerState.draft == "Pane A draft")
        #expect(deck.runtime(for: paneB.id) === paneB)
        #expect(deck.runtime(for: paneC.id) === paneC)
        #expect(factory.stores.count == 3)

        guard case .split(let root) = deck.root,
              case .split(let below) = root.first else {
            Issue.record("Expected a horizontal root with a vertical split in its first pane")
            return
        }
        #expect(root.axis == .horizontal)
        #expect(below.axis == .vertical)
    }

    @Test func splittingKeepsLiveDictationWithItsStablePaneRuntime() async throws {
        let composerFactory = PaneComposerFactoryRecorder()
        let deck = MacSessionPaneDeck(composerStateFactory: composerFactory.make)
        let paneA = try #require(deck.openOrFocus(
            target(sessionID: "session-a", workspaceID: "workspace")
        ))
        try await composerFactory.harnesses[0].controller.start(
            baseText: "Pane A",
            endpoint: Self.dictationEndpoint
        )

        _ = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-b", workspaceID: "workspace")
        ))

        #expect(deck.runtime(for: paneA.id) === paneA)
        #expect(paneA.composerState === composerFactory.harnesses[0].state)
        #expect(paneA.composerState.dictation.isLive)
        #expect(composerFactory.harnesses[0].transport.controls.map(\.typeLabel) == [
            "dictation_start",
        ])
        await paneA.composerState.dictation.cancel()
    }

    @Test func leavingSessionHomeCancelsEveryLivePaneWithoutClearingDraftsOrLayout() async throws {
        let composerFactory = PaneComposerFactoryRecorder()
        let deck = MacSessionPaneDeck(composerStateFactory: composerFactory.make)
        let paneA = try #require(deck.openOrFocus(
            target(sessionID: "session-a", workspaceID: "workspace")
        ))
        let paneB = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-b", workspaceID: "workspace")
        ))
        paneA.composerState.draft = "Keep pane A"
        paneB.composerState.draft = "Keep pane B"
        for harness in composerFactory.harnesses {
            try await harness.controller.start(
                baseText: harness.state.draft,
                endpoint: Self.dictationEndpoint
            )
        }
        let root = deck.root

        deck.cancelAllLiveDictation()

        #expect(await waitUntil {
            composerFactory.harnesses.allSatisfy { !$0.controller.isLive }
        })
        #expect(await waitUntil {
            composerFactory.harnesses.allSatisfy { harness in
                harness.transport.controls.map(\.typeLabel) == [
                    "dictation_start", "dictation_cancel",
                ]
            }
        })
        #expect(paneA.composerState.draft == "Keep pane A")
        #expect(paneB.composerState.draft == "Keep pane B")
        #expect(deck.root == root)
        #expect(deck.paneCount == 2)
    }

    @Test func suspendingEveryPaneRuntimePreservesTargetsLayoutAndDrafts() async throws {
        let factory = StoreFactoryRecorder()
        let deck = MacSessionPaneDeck(storeFactory: factory.make)
        let paneA = try #require(deck.openOrFocus(
            target(sessionID: "session-a", workspaceID: "workspace", status: .stopped)
        ))
        let paneB = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-b", workspaceID: "workspace", status: .stopped)
        ))
        paneA.composerState.draft = "Keep pane A"
        paneB.composerState.draft = "Keep pane B"
        let attachment = try MacPendingAttachment(
            id: "pane-a-attachment",
            url: URL(fileURLWithPath: "/tmp/pane-a-notes.md"),
            displayName: "pane-a-notes.md",
            mimeType: "text/markdown",
            sizeBytes: 42
        )
        paneA.composerState.pendingAttachments = [attachment]
        let root = deck.root
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-pane-runtime.sock",
            token: "sk_owner",
            transport: RecordingLocalHTTPTransport(response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("{}".utf8)
            ))
        )
        await paneA.traceStore.installSessionRuntimeForTesting(client: client)
        await paneB.traceStore.installSessionRuntimeForTesting(client: client)
        let managerA = try #require(paneA.traceStore._chatSessionManagerForTesting)
        let managerB = try #require(paneB.traceStore._chatSessionManagerForTesting)

        deck.suspendAllSessionRuntimes()
        deck.suspendAllSessionRuntimes()

        #expect(paneA.traceStore._chatSessionManagerForTesting == nil)
        #expect(paneB.traceStore._chatSessionManagerForTesting == nil)
        #expect(paneA.traceStore.selectedTarget?.sessionId == "session-a")
        #expect(paneB.traceStore.selectedTarget?.sessionId == "session-b")
        #expect(paneA.composerState.draft == "Keep pane A")
        #expect(paneB.composerState.draft == "Keep pane B")
        #expect(paneA.composerState.pendingAttachments == [attachment])
        #expect(deck.root == root)
        #expect(deck.paneCount == 2)

        await paneA.traceStore.installSessionRuntimeForTesting(client: client)
        await paneB.traceStore.installSessionRuntimeForTesting(client: client)

        #expect(paneA.traceStore._chatSessionManagerForTesting !== managerA)
        #expect(paneB.traceStore._chatSessionManagerForTesting !== managerB)
        #expect(paneA.traceStore.selectedTarget?.sessionId == "session-a")
        #expect(paneB.traceStore.selectedTarget?.sessionId == "session-b")
        #expect(paneA.composerState.draft == "Keep pane A")
        #expect(paneB.composerState.draft == "Keep pane B")
        #expect(paneA.composerState.pendingAttachments == [attachment])
        #expect(deck.root == root)
    }

    @Test func focusAndRetilingDoNotReplaceExistingPaneRuntimes() async throws {
        let deck = MacSessionPaneDeck()
        let paneA = try #require(deck.openOrFocus(
            target(sessionID: "session-a", workspaceID: "workspace", status: .stopped)
        ))
        let paneB = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-b", workspaceID: "workspace", status: .stopped)
        ))
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-pane-runtime.sock",
            token: "sk_owner",
            transport: RecordingLocalHTTPTransport(response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("{}".utf8)
            ))
        )
        await paneA.traceStore.installSessionRuntimeForTesting(client: client)
        await paneB.traceStore.installSessionRuntimeForTesting(client: client)
        let managerA = try #require(paneA.traceStore._chatSessionManagerForTesting)
        let managerB = try #require(paneB.traceStore._chatSessionManagerForTesting)

        #expect(deck.focus(paneID: paneA.id))
        _ = try #require(deck.splitFocusedBelow(
            with: target(sessionID: "session-c", workspaceID: "workspace", status: .stopped)
        ))
        #expect(deck.focus(paneID: paneB.id))

        #expect(paneA.traceStore._chatSessionManagerForTesting === managerA)
        #expect(paneB.traceStore._chatSessionManagerForTesting === managerB)
    }

    @Test func splittingAnAlreadyVisibleSessionOnlyFocusesItsExistingPane() throws {
        let factory = StoreFactoryRecorder()
        let deck = MacSessionPaneDeck(storeFactory: factory.make)
        let paneA = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))
        let paneB = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-b", workspaceID: "workspace")
        ))
        #expect(deck.focus(paneID: paneA.id))

        let duplicate = try #require(deck.splitFocusedBelow(
            with: target(sessionID: "session-b", workspaceID: "workspace", status: .busy)
        ))

        #expect(duplicate === paneB)
        #expect(duplicate.target?.summary.status == .busy)
        #expect(deck.focusedSessionID == "session-b")
        #expect(deck.paneCount == 2)
        #expect(factory.stores.count == 2)
    }

    @Test func fourPaneLimitRejectsOnlyNewSessions() throws {
        let factory = StoreFactoryRecorder()
        let deck = MacSessionPaneDeck(storeFactory: factory.make)
        _ = deck.openOrFocus(target(sessionID: "session-0", workspaceID: "workspace"))
        for index in 1..<MacSessionPaneLayout.maximumPaneCount {
            _ = try #require(deck.splitFocusedRight(
                with: target(sessionID: "session-\(index)", workspaceID: "workspace")
            ))
        }

        #expect(deck.paneCount == MacSessionPaneLayout.maximumPaneCount)
        #expect(!deck.canSplit)
        #expect(deck.splitFocusedBelow(
            with: target(sessionID: "session-4", workspaceID: "workspace")
        ) == nil)
        #expect(factory.stores.count == MacSessionPaneLayout.maximumPaneCount)

        let existing = try #require(deck.splitFocusedBelow(
            with: target(sessionID: "session-0", workspaceID: "workspace")
        ))
        #expect(existing.target?.sessionId == "session-0")
        #expect(deck.focusedSessionID == "session-0")
        #expect(deck.paneCount == MacSessionPaneLayout.maximumPaneCount)
    }

    @Test func closeClearsItsStoreAndReturnsTheLastPaneToQuickSession() throws {
        let deck = MacSessionPaneDeck()
        let paneA = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))
        let paneB = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-b", workspaceID: "workspace")
        ))

        #expect(deck.close(paneID: paneB.id))
        #expect(paneB.traceStore.selectedTarget == nil)
        #expect(deck.focusedSessionID == "session-a")
        #expect(deck.runtime(for: paneB.id) == nil)
        #expect(deck.paneCount == 1)

        #expect(deck.closeFocused())
        #expect(paneA.traceStore.selectedTarget == nil)
        #expect(deck.layout != nil)
        let replacement = try #require(deck.focusedRuntime)
        #expect(replacement !== paneA)
        #expect(replacement.id != paneA.id)
        #expect(deck.root == .pane(MacSessionPane(id: replacement.id, route: nil)))
        #expect(replacement.isEmpty)
        #expect(deck.visibleSessionIDs.isEmpty)
        #expect(deck.paneCount == 1)
    }

    @Test func removingSessionOrWorkspaceClearsOnlyMatchingPaneStores() throws {
        let deck = MacSessionPaneDeck()
        let workspaceAPane1 = try #require(deck.openOrFocus(
            target(sessionID: "session-a1", workspaceID: "workspace-a")
        ))
        let workspaceBPane = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-b", workspaceID: "workspace-b")
        ))
        let workspaceAPane2 = try #require(deck.splitFocusedBelow(
            with: target(sessionID: "session-a2", workspaceID: "workspace-a")
        ))

        #expect(deck.remove(sessionID: "session-b"))
        #expect(workspaceBPane.traceStore.selectedTarget == nil)
        #expect(deck.visibleSessionIDs == ["session-a1", "session-a2"])
        #expect(deck.remove(workspaceID: "workspace-a") == 2)
        #expect(workspaceAPane1.traceStore.selectedTarget == nil)
        #expect(workspaceAPane2.traceStore.selectedTarget == nil)
        #expect(deck.layout != nil)
        #expect(deck.paneCount == 1)
        #expect(deck.focusedRuntime?.isEmpty == true)
        #expect(deck.remove(sessionID: "missing") == false)
        #expect(deck.remove(workspaceID: "missing") == 0)
    }

    @Test func updateAndReloadOpenTargetPreservesRuntimeAndUsesInjectedLoader() async throws {
        let recorder = ReloadRecorder()
        let deck = MacSessionPaneDeck(reloadTarget: recorder.reload)
        let runtime = try #require(deck.openOrFocus(
            target(sessionID: "session-a", workspaceID: "workspace", status: .ready)
        ))
        let updated = target(
            sessionID: "session-a",
            workspaceID: "workspace",
            status: .busy,
            name: "Updated title"
        )

        #expect(deck.updateOpenTarget(updated))
        #expect(deck.runtime(forSessionID: "session-a") === runtime)
        #expect(runtime.target?.summary.name == "Updated title")
        #expect(runtime.traceStore.session?.status == .busy)
        #expect(await deck.reloadOpenTarget(updated))
        #expect(recorder.targets.map(\.sessionId) == ["session-a"])
        #expect(recorder.stores.first === runtime.traceStore)
        #expect(!runtime.traceStore._sessionRuntimeLoopRunningForTesting)

        let missing = target(sessionID: "missing", workspaceID: "workspace")
        #expect(!deck.updateOpenTarget(missing))
        #expect(!(await deck.reloadOpenTarget(missing)))
        #expect(recorder.targets.count == 1)
    }

    @Test func splitFocusedRightCreatesAnEmptyQuickSessionPane() throws {
        let factory = StoreFactoryRecorder()
        let deck = MacSessionPaneDeck(storeFactory: factory.make)
        let paneA = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))

        let empty = try #require(deck.splitFocusedRight())

        #expect(empty.id != paneA.id)
        #expect(empty.isEmpty)
        #expect(empty.target == nil)
        #expect(deck.focusedPaneID == empty.id)
        #expect(deck.focusedSessionID == nil)
        #expect(deck.visibleSessionIDs == ["session-a"])
        #expect(deck.paneCount == 2)
        #expect(factory.stores.count == 2)
        #expect(deck.layout?.split(id: try #require(rootSplitID(deck.root)))?.axis == .horizontal)
    }

    @Test func sessionListClickFillsTheEmptyFocusedPane() throws {
        let deck = MacSessionPaneDeck()
        let paneA = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))
        let empty = try #require(deck.splitFocusedBelow())
        let emptyID = empty.id

        let filled = try #require(deck.openOrFocus(target(sessionID: "session-b", workspaceID: "workspace")))

        #expect(filled === empty)
        #expect(filled.id == emptyID)
        #expect(filled.target?.sessionId == "session-b")
        #expect(deck.focusedSessionID == "session-b")
        #expect(deck.runtime(for: paneA.id) === paneA)
        #expect(deck.paneCount == 2)
    }

    @Test func launchingIntoEmptyPaneKeepsTheSamePaneIdentity() throws {
        let deck = MacSessionPaneDeck()
        _ = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))
        let empty = try #require(deck.splitFocusedRight())
        let paneID = empty.id

        let launched = try #require(deck.replaceFocused(
            with: target(sessionID: "session-new", workspaceID: "workspace")
        ))

        #expect(launched.id == paneID)
        #expect(launched === empty)
        #expect(launched.target?.sessionId == "session-new")
        #expect(deck.focusedSessionID == "session-new")
    }

    @Test func completingLaunchAfterFocusMovesReplacesTheOriginatingPane() async throws {
        let deck = MacSessionPaneDeck()
        let paneA = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))
        let empty = try #require(deck.splitFocusedRight())
        let originatingID = empty.id
        let launchedTarget = target(sessionID: "session-new", workspaceID: "workspace")
        let park = LaunchPark()

        let task = Task { @MainActor in
            await park.park()
            return deck.replace(paneID: originatingID, with: launchedTarget)
        }
        await park.waitUntilParked()
        #expect(deck.focus(paneID: paneA.id))
        #expect(deck.focusedPaneID == paneA.id)
        await park.release()

        let launched = try #require(await task.value)
        #expect(launched.id == originatingID)
        #expect(launched === empty)
        #expect(launched.target?.sessionId == "session-new")
        #expect(deck.runtime(for: paneA.id)?.target?.sessionId == "session-a")
        #expect(deck.focusedSessionID == "session-a")
    }

    @Test func completingLaunchDoesNothingIfTheOriginatingPaneClosed() throws {
        let deck = MacSessionPaneDeck()
        let paneA = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))
        let empty = try #require(deck.splitFocusedRight())
        let originatingID = empty.id
        #expect(deck.close(paneID: originatingID))
        #expect(deck.focusedPaneID == paneA.id)

        let launched = deck.replace(
            paneID: originatingID,
            with: target(sessionID: "session-new", workspaceID: "workspace")
        )

        #expect(launched == nil)
        #expect(deck.runtime(for: paneA.id)?.target?.sessionId == "session-a")
        #expect(deck.focusedSessionID == "session-a")
        #expect(deck.paneCount == 1)
        #expect(deck.visibleSessionIDs == ["session-a"])
    }

    @Test func emptyPanesCountTowardTheFourPaneCap() throws {
        let deck = MacSessionPaneDeck()
        _ = deck.openOrFocus(target(sessionID: "session-0", workspaceID: "workspace"))
        for _ in 1..<MacSessionPaneLayout.maximumPaneCount {
            _ = try #require(deck.splitFocusedRight())
        }

        #expect(deck.paneCount == MacSessionPaneLayout.maximumPaneCount)
        #expect(!deck.canSplit)
        #expect(deck.splitFocusedBelow() == nil)
        #expect(deck.visibleSessionIDs == ["session-0"])
    }

    @Test func focusAdjacentMovesBetweenEmptyAndSessionPanes() throws {
        let deck = MacSessionPaneDeck()
        let paneA = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))
        let empty = try #require(deck.splitFocusedRight())

        #expect(deck.focusAdjacent(.left))
        #expect(deck.focusedPaneID == paneA.id)
        #expect(deck.focusAdjacent(.right))
        #expect(deck.focusedPaneID == empty.id)
        #expect(!deck.focusAdjacent(.right))
    }

    private func rootSplitID(_ root: MacSessionPaneNode?) -> MacSessionPaneSplitID? {
        guard case .split(let split) = root else { return nil }
        return split.id
    }

    private func target(
        sessionID: String,
        workspaceID: String,
        status: SessionStatus = .ready,
        name: String? = nil
    ) -> MacSelectedSessionTarget {
        let session = Session(
            id: sessionID,
            workspaceId: workspaceID,
            workspaceName: workspaceID,
            name: name,
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_001),
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        return MacSelectedSessionTarget(
            workspaceId: workspaceID,
            sessionId: sessionID,
            summary: SessionSummary(from: session)
        )
    }

    private static let dictationEndpoint = MacDictationEndpoint(
        socketPath: "/tmp/oppi-pane-dictation.sock",
        token: "sk_test"
    )
}

@MainActor
private final class StoreFactoryRecorder {
    private(set) var stores: [MacSessionTraceStore] = []

    func make() -> MacSessionTraceStore {
        let store = MacSessionTraceStore()
        stores.append(store)
        return store
    }
}

@MainActor
private final class ReloadRecorder {
    private(set) var stores: [MacSessionTraceStore] = []
    private(set) var targets: [MacSelectedSessionTarget] = []

    func reload(store: MacSessionTraceStore, target: MacSelectedSessionTarget) async {
        stores.append(store)
        targets.append(target)
    }
}

@MainActor
private final class PaneComposerFactoryRecorder {
    private(set) var harnesses: [PaneDictationHarness] = []

    func make() -> MacSessionComposerState {
        let harness = PaneDictationHarness()
        harnesses.append(harness)
        return harness.state
    }
}

@MainActor
private final class PaneDictationHarness {
    let transport = PaneDictationTransport()
    let audio = PaneDictationAudioCapture()
    let controller: MacComposerDictationController
    let state: MacSessionComposerState

    init() {
        controller = MacComposerDictationController(
            microphone: PaneDictationMicrophone(),
            makeTransport: { [transport] _ in transport },
            makeAudioCapture: { [audio] in audio },
            readyTimeout: .seconds(2),
            finalTimeout: .seconds(2)
        )
        state = MacSessionComposerState(dictation: controller)
    }
}

private struct PaneDictationMicrophone: MacDictationMicrophoneAuthorizing {
    func requestAccess() async -> Bool { true }
}

@MainActor
private final class PaneDictationAudioCapture: MacDictationAudioCapturing {
    private var continuation: AsyncStream<Data>.Continuation?

    func start() throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
private final class PaneDictationTransport: MacDictationTransporting {
    private(set) var controls: [ClientMessage] = []
    private var waiters: [CheckedContinuation<ServerMessage, Error>] = []
    private var isClosed = false

    func connect() async throws {}

    func sendControl(_ message: ClientMessage) async throws {
        controls.append(message)
    }

    func sendAudio(_: Data) async throws {}

    func receive() async throws -> ServerMessage {
        try await withCheckedThrowingContinuation { continuation in
            guard !isClosed else {
                continuation.resume(throwing: WebSocketTransportError.cancelled)
                return
            }
            waiters.append(continuation)
        }
    }

    func close() {
        isClosed = true
        let waiters = waiters
        self.waiters = []
        waiters.forEach { $0.resume(throwing: WebSocketTransportError.cancelled) }
    }
}

@MainActor
private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        await Task.yield()
    }
    return false
}

/// Parks an in-flight launch so the test can change focus during the await.
private actor LaunchPark {
    private var go: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func park() async {
        await withCheckedContinuation { continuation in
            go = continuation
            ready?.resume()
            ready = nil
        }
    }

    func waitUntilParked() async {
        if go != nil { return }
        await withCheckedContinuation { continuation in
            ready = continuation
        }
    }

    func release() {
        go?.resume()
        go = nil
    }
}
