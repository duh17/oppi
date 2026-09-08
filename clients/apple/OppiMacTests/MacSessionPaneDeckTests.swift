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
        #expect(!deck.canSplit)
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
        #expect(!deck.canSplit)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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

    @Test func fiveAndSixPanesHaveNoSpecialCountCliff() throws {
        let factory = StoreFactoryRecorder()
        let deck = MacSessionPaneDeck(storeFactory: factory.make)
        noteKnownWindow(deck)
        _ = deck.openOrFocus(target(sessionID: "session-0", workspaceID: "workspace"))
        for index in 1..<6 {
            _ = try #require(splitAnAdmissiblePane(
                deck,
                with: target(sessionID: "session-\(index)", workspaceID: "workspace")
            ))
        }

        #expect(deck.paneCount == 6)
        #expect(factory.stores.count == 6)
        #expect(deck.runtimeCensus.liveRuntimeCount == 0)
        #expect(deck.splitRejectionMessage == nil)
        #expect(deck.runtimeCensus.reducerItemCount == 0)
        #expect(deck.runtimeCensus.liveUpdateCount == 0)
    }

    @Test func aMeasuredLeafDoesNotInheritWindowSizeForAdmission() throws {
        let deck = MacSessionPaneDeck()
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 2_400, height: 1_400))
        _ = deck.openOrFocus(target(sessionID: "session-0", workspaceID: "workspace"))
        _ = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-1", workspaceID: "workspace")
        ))
        deck.notePaneSize(
            MacSessionPaneMeasuredSize(width: 500, height: 700),
            for: try #require(deck.focusedPaneID)
        )

        #expect(deck.splitFocusedRight(
            with: target(sessionID: "session-2", workspaceID: "workspace")
        ) == nil)
        #expect(deck.paneCount == 2)
        #expect(deck.lastSplitRejection == .paneTooSmall)
    }

    @Test func repeatedNewestPaneSplitsUsePaintedLeafSizeNotTheWholeWindow() throws {
        let deck = MacSessionPaneDeck()
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 2_400, height: 1_400))
        _ = deck.openOrFocus(target(sessionID: "session-0", workspaceID: "workspace"))
        var paneCount = 1
        while paneCount < 8,
              deck.splitFocusedRight(
                with: target(sessionID: "session-\(paneCount)", workspaceID: "workspace")
              ) != nil {
            paneCount += 1
        }

        #expect(paneCount < 6)
        #expect(deck.paneCount == paneCount)
        #expect(deck.lastSplitRejection == .paneTooSmall)
    }

    @Test func concurrentPanesKeepIndependentRuntimesDraftsAndCensusAboveFour() async throws {
        let factory = StoreFactoryRecorder()
        let deck = MacSessionPaneDeck(storeFactory: factory.make)
        noteKnownWindow(deck)
        var panes: [MacSessionPaneRuntime] = []
        let first = try #require(deck.openOrFocus(
            target(sessionID: "session-0", workspaceID: "workspace", status: .ready)
        ))
        panes.append(first)
        for index in 1..<6 {
            panes.append(try #require(splitAnAdmissiblePane(
                deck,
                with: target(sessionID: "session-\(index)", workspaceID: "workspace", status: .ready)
            )))
        }
        #expect(panes.count == 6)
        #expect(Set(panes.map(\.id)).count == 6)

        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-pane-census.sock",
            token: "sk_owner",
            transport: RecordingLocalHTTPTransport(response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("{}".utf8)
            ))
        )
        var streamsByIndex: [PaneScriptedStreamFactory] = []
        var sentCommands: [String: Int] = [:]
        defer {
            for streams in streamsByIndex {
                streams.finish(index: 0)
            }
            for pane in panes {
                pane.traceStore.clearSelection()
            }
        }
        for (index, pane) in panes.enumerated() {
            let sessionID = "session-\(index)"
            pane.composerState.draft = "Draft \(index)"
            pane.presentation.isInspectorPresented = index.isMultiple(of: 2)
            pane.presentation.isLiveTailAttached = index != 2
            await pane.traceStore.installSessionRuntimeForTesting(client: client)
            let manager = try #require(pane.traceStore._chatSessionManagerForTesting)
            let session = try #require(pane.traceStore.session)
            let streams = PaneScriptedStreamFactory(session: session)
            streamsByIndex.append(streams)
            manager._loadHistoryForTesting = { _, _ in nil }
            manager._streamEventsForTesting = streams.makeStream
            pane.traceStore._sendLiveMessageForTesting = { _ in
                sentCommands[sessionID, default: 0] += 1
                return true
            }
            pane.traceStore.startSessionRuntimeLoopForTesting()
            #expect(await streams.waitForCreated(1))
            streams.yieldConnected(index: 0)
            #expect(await waitUntilStreaming { manager.entryState == .streaming })
            #expect(pane.traceStore.hasLiveRuntime)

            _ = manager.reducer.appendUserMessage("Stream \(index)")
            pane.traceStore.applyServerMessageForTesting(
                .extensionUIRequest(ExtensionUIRequest(
                    id: "ask-\(index)",
                    sessionId: sessionID,
                    method: "ask",
                    timeout: 30_000,
                    workspaceId: "workspace",
                    askQuestions: [
                        AskQuestion(
                            id: "q-\(index)",
                            question: "Choose \(index)?",
                            options: [AskOption(value: "yes", label: "Yes")],
                            multiSelect: false
                        ),
                    ],
                    allowCustom: false
                )),
                target: try #require(pane.target)
            )
        }

        #expect(deck.paneCount == 6)
        #expect(factory.stores.count == 6)
        #expect(panes.filter(\.traceStore.hasLiveRuntime).count == 6)
        #expect(deck.runtimeCensus.liveRuntimeCount == 6)
        #expect(deck.runtimeCensus.reducerItemCount >= 6)
        #expect(Set(panes.map { $0.traceStore.items.map(\.id) }).count == 6)
        #expect(panes.map(\.composerState.draft) == (0..<6).map { "Draft \($0)" })
        #expect(panes.map { $0.traceStore.currentAskRequest?.id } == (0..<6).map { "ask-\($0)" })
        #expect(panes[2].presentation.isLiveTailAttached == false)
        #expect(panes[0].presentation.isInspectorPresented)
        #expect(panes[0].traceStore !== panes[5].traceStore)

        #expect(deck.focus(paneID: panes[4].id))
        #expect(deck.focusedRuntime === panes[4])
        let sent = await panes[4].traceStore.sendPrompt(
            "from pane four",
            target: try #require(panes[4].target),
            client: client
        )
        #expect(sent)
        #expect(sentCommands["session-4"] == 1)
        #expect(sentCommands["session-0"] == nil)
        #expect(sentCommands["session-5"] == nil)

        #expect(deck.close(paneID: panes[5].id))
        #expect(panes[5].traceStore.selectedTarget == nil)
        #expect(!panes[5].traceStore.hasLiveRuntime)
        #expect(deck.runtimeCensus.liveRuntimeCount == 5)
        #expect(deck.paneCount == 5)
    }

    @Test func geometryRejectsASplitAndExplainsThePaneIsTooSmall() throws {
        let deck = MacSessionPaneDeck()
        _ = deck.openOrFocus(target(sessionID: "session-0", workspaceID: "workspace"))
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_200, height: 800))
        deck.notePaneSize(
            MacSessionPaneMeasuredSize(width: 500, height: 700),
            for: try #require(deck.focusedPaneID)
        )

        #expect(deck.splitFocusedRight(
            with: target(sessionID: "session-1", workspaceID: "workspace")
        ) == nil)
        #expect(deck.paneCount == 1)
        #expect(deck.lastSplitRejection == .paneTooSmall)
        #expect(deck.splitRejectionMessage == "This pane is too small to split.")
        #expect(!(deck.splitRejectionMessage?.contains("4") ?? false))
        #expect(!(deck.splitRejectionMessage?.contains("four") ?? false))
    }

    @Test func closeClearsItsStoreAndReturnsTheLastPaneToQuickSession() throws {
        let deck = MacSessionPaneDeck()
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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
        noteKnownWindow(deck)
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

    @Test func restoringLayoutKeepsUnavailableSessionsWithoutDroppingNeighbors() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        let paneC = MacSessionPaneID(rawValue: "pane-c")
        var restored = MacSessionPaneLayout(initialRoute: routeLayout(0), paneID: paneA)
        try restored.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: routeLayout(1),
            newPaneID: paneB,
            paneSize: MacSessionPaneMeasuredSize(width: 2_400, height: 1_400),
            windowSize: MacSessionPaneMeasuredSize(width: 2_400, height: 1_400)
        )
        try restored.split(
            paneID: paneB,
            axis: .vertical,
            newRoute: routeLayout(2),
            newPaneID: paneC,
            fraction: 0.4,
            paneSize: MacSessionPaneMeasuredSize(width: 2_400, height: 1_400),
            windowSize: MacSessionPaneMeasuredSize(width: 2_400, height: 1_400)
        )
        let defaults = UserDefaults(suiteName: "pane-mux-restore-\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        let persistence = MacSessionPaneLayoutPersistence(
            windowID: "main",
            defaults: defaults
        )
        persistence.save(restored)

        let deck = MacSessionPaneDeck(
            persistence: persistence,
            resolveRestoredRoute: { route in
                route.sessionID == "session-1"
                    ? nil
                    : target(sessionID: route.sessionID, workspaceID: "workspace-\(route.sessionID.suffix(1))")
            }
        )

        #expect(deck.paneCount == 3)
        #expect(deck.runtime(for: paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: paneB)?.restorationError == "This session is no longer available.")
        #expect(deck.runtime(for: paneC)?.target?.sessionId == "session-2")
        #expect(deck.layout?.split(id: try #require(rootSplitID(deck.root)))?.fraction == 0.5)

        #expect(deck.setFraction(0.32, for: try #require(rootSplitID(deck.root))))
        let reloaded = MacSessionPaneLayoutPersistence(windowID: "main", defaults: defaults).load()
        #expect(reloaded?.split(id: try #require(rootSplitID(reloaded?.root)))?.fraction == 0.32)
    }

    @Test func productionLookupRestoresAnOldStoppedSessionMissingFromRecent()
    async throws {
        let panes = try persistedThreePaneLayout()
        let reload = ReloadRecorder()
        let deck = MacSessionPaneDeck(
            reloadTarget: reload.reload,
            persistence: panes.persistence,
            resolveRestoredRoute: { route in
                route.sessionID == "session-1"
                    ? nil
                    : target(
                        sessionID: route.sessionID,
                        workspaceID: "workspace-\(route.sessionID.suffix(1))"
                    )
            },
            unresolvedRestoredRoute: .lookup
        )

        #expect(deck.runtime(for: panes.paneB)?.restorationError
            == MacSessionPaneRuntime.pendingRestorationMessage)
        #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")

        await deck.resolvePendingRestoredSessions { route in
            #expect(route.sessionID == "session-1")
            return .found(
                target(
                    sessionID: "session-1",
                    workspaceID: "workspace-1",
                    status: .stopped
                )
            )
        }

        let restored = try #require(deck.runtime(for: panes.paneB))
        #expect(restored.target?.sessionId == "session-1")
        #expect(restored.target?.summary.status == .stopped)
        #expect(restored.restorationError == nil)
        #expect(!restored.traceStore.isResumingSession)
        #expect(reload.targets.isEmpty)
        #expect(deck.runtime(for: panes.paneA)?.id == panes.paneA)
        #expect(deck.runtime(for: panes.paneC)?.id == panes.paneC)
        #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
    }

    @Test func productionLookupKeepsConfirmedNotFoundDistinctFromOffline()
    async throws {
        let missing = try persistedThreePaneLayout()
        let missingDeck = MacSessionPaneDeck(
            persistence: missing.persistence,
            resolveRestoredRoute: { route in
                route.sessionID == "session-1" ? nil : target(
                    sessionID: route.sessionID,
                    workspaceID: "workspace-\(route.sessionID.suffix(1))"
                )
            },
            unresolvedRestoredRoute: .lookup
        )
        await missingDeck.resolvePendingRestoredSessions { _ in .unavailable }
        #expect(
            missingDeck.runtime(for: missing.paneB)?.restorationError
                == MacSessionPaneRuntime.unavailableRestorationMessage
        )
        #expect(missingDeck.runtime(for: missing.paneA)?.target?.sessionId == "session-0")
        #expect(missingDeck.runtime(for: missing.paneC)?.target?.sessionId == "session-2")

        let offline = try persistedThreePaneLayout()
        let offlineDeck = MacSessionPaneDeck(
            persistence: offline.persistence,
            resolveRestoredRoute: { route in
                route.sessionID == "session-1" ? nil : target(
                    sessionID: route.sessionID,
                    workspaceID: "workspace-\(route.sessionID.suffix(1))"
                )
            },
            unresolvedRestoredRoute: .lookup
        )
        await offlineDeck.resolvePendingRestoredSessions { _ in .disconnected }
        #expect(
            offlineDeck.runtime(for: offline.paneB)?.restorationError
                == MacSessionPaneRuntime.disconnectedRestorationMessage
        )
        #expect(
            offlineDeck.runtime(for: offline.paneB)?.restorationError
                != MacSessionPaneRuntime.unavailableRestorationMessage
        )
        #expect(offlineDeck.runtime(for: offline.paneA)?.target?.sessionId == "session-0")
    }

    @Test func lateRestoreLookupDoesNotOverwriteARepurposedPane() async throws {
        let outcomes: [MacSessionPaneRestoredLookup] = [
            .found(target(sessionID: "session-1", workspaceID: "workspace-1", status: .stopped)),
            .unavailable,
            .disconnected,
        ]
        for outcome in outcomes {
            let panes = try persistedThreePaneLayout()
            let deck = lookupDeck(persistence: panes.persistence)
            let origin = try #require(deck.runtime(for: panes.paneB))
            let park = LaunchPark()
            let task = Task {
                await deck.resolvePendingRestoredSessions { _ in
                    await park.park()
                    return outcome
                }
            }
            await park.waitUntilParked()
            let replaced = try #require(deck.replace(
                paneID: panes.paneB,
                with: target(sessionID: "session-b", workspaceID: "workspace-b")
            ))
            replaced.composerState.draft = "Keep B's draft"
            await park.release()
            await task.value

            #expect(deck.runtime(for: panes.paneB) === origin)
            #expect(origin.target?.sessionId == "session-b")
            #expect(origin.composerState.draft == "Keep B's draft")
            #expect(origin.restorationError == nil)
            #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
            #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
        }
    }

    @Test func lateRestoreLookupDoesNotReopenAClosedPane() async throws {
        let panes = try persistedThreePaneLayout()
        let deck = lookupDeck(persistence: panes.persistence)
        let park = LaunchPark()
        let task = Task {
            await deck.resolvePendingRestoredSessions { _ in
                await park.park()
                return .found(
                    target(sessionID: "session-1", workspaceID: "workspace-1", status: .stopped)
                )
            }
        }
        await park.waitUntilParked()
        #expect(deck.close(paneID: panes.paneB))
        await park.release()
        await task.value

        #expect(deck.runtime(for: panes.paneB) == nil)
        #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
    }

    @Test func cancelledRestoreLookupDoesNotApplyALaterResult() async throws {
        let panes = try persistedThreePaneLayout()
        let deck = lookupDeck(persistence: panes.persistence)
        let origin = try #require(deck.runtime(for: panes.paneB))
        let park = LaunchPark()
        let task = Task { @MainActor in
            await deck.resolvePendingRestoredSessions { _ in
                await park.park()
                return .found(
                    target(sessionID: "session-1", workspaceID: "workspace-1", status: .stopped)
                )
            }
        }
        await park.waitUntilParked()
        task.cancel()
        await park.release()
        await task.value

        #expect(deck.runtime(for: panes.paneB) === origin)
        #expect(origin.restorationError == MacSessionPaneRuntime.pendingRestorationMessage)
        #expect(origin.target?.sessionId == "session-1")
        #expect(origin.target?.summary.session.messageCount == 0)
        #expect(origin.target?.summary.session.name == nil)
        #expect(!origin.traceStore.isResumingSession)
        #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
    }

    @Test func catalogHitDuringRestoreLookupStaysAuthoritative() async throws {
        let panes = try persistedThreePaneLayout()
        let deck = lookupDeck(persistence: panes.persistence)
        let origin = try #require(deck.runtime(for: panes.paneB))
        let park = LaunchPark()
        let task = Task {
            await deck.resolvePendingRestoredSessions { _ in
                await park.park()
                return .unavailable
            }
        }
        await park.waitUntilParked()
        #expect(deck.updateOpenTarget(
            target(sessionID: "session-1", workspaceID: "workspace-1", status: .stopped)
        ))
        await park.release()
        await task.value

        #expect(deck.runtime(for: panes.paneB) === origin)
        #expect(origin.target?.sessionId == "session-1")
        #expect(origin.target?.summary.status == .stopped)
        #expect(origin.restorationError == nil)
        #expect(!origin.traceStore.isResumingSession)
    }

    @Test func cancelledFoundLookupDoesNotPublishThroughCatalogObserver() async throws {
        let panes = try persistedThreePaneLayout()
        let deck = lookupDeck(persistence: panes.persistence)
        let origin = try #require(deck.runtime(for: panes.paneB))
        let catalog = MacWorkspaceSnapshotStore()
        let park = LaunchPark()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-restore-catalog-cancel.sock",
            token: "sk_owner",
            transport: ParkingSessionRecordTransport(
                park: park,
                response: sessionRecordResponse(sessionID: "session-1", workspaceID: "workspace-1")
            )
        )

        let task = Task { @MainActor in
            await MacSessionRestorationCatalog.resolvePending(
                deck: deck,
                catalog: catalog,
                client: client
            )
            MacSessionRestorationCatalog.apply(catalog, to: deck)
        }
        await park.waitUntilParked()
        task.cancel()
        await park.release()
        await task.value

        #expect(catalog.target(for: "session-1") == nil)
        #expect(deck.runtime(for: panes.paneB) === origin)
        #expect(origin.restorationError == MacSessionPaneRuntime.pendingRestorationMessage)
        #expect(origin.target?.sessionId == "session-1")
        #expect(origin.target?.summary.session.messageCount == 0)
        #expect(origin.target?.summary.session.name == nil)
        #expect(!origin.traceStore.isResumingSession)
        #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
    }

    @Test func olderFoundLookupDoesNotReplaceNewerSameSessionCatalogState() async throws {
        let panes = try persistedThreePaneLayout()
        let deck = lookupDeck(persistence: panes.persistence)
        let origin = try #require(deck.runtime(for: panes.paneB))
        let catalog = MacWorkspaceSnapshotStore()
        let park = LaunchPark()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-restore-catalog-newer.sock",
            token: "sk_owner",
            transport: ParkingSessionRecordTransport(
                park: park,
                response: sessionRecordResponse(sessionID: "session-1", workspaceID: "workspace-1")
            )
        )
        let newer = catalogTarget(
            sessionID: "session-1",
            workspaceID: "workspace-1",
            name: "Newer",
            messageCount: 9,
            pendingAskCount: 3
        )

        let task = Task { @MainActor in
            await MacSessionRestorationCatalog.resolvePending(
                deck: deck,
                catalog: catalog,
                client: client
            )
            MacSessionRestorationCatalog.apply(catalog, to: deck)
        }
        await park.waitUntilParked()
        catalog.noteOpenedSession(newer)
        MacSessionRestorationCatalog.apply(catalog, to: deck)
        await park.release()
        await task.value

        #expect(catalog.target(for: "session-1")?.summary.pendingAskCount == 3)
        #expect(catalog.target(for: "session-1")?.summary.name == "Newer")
        #expect(catalog.target(for: "session-1")?.summary.messageCount == 9)
        #expect(deck.runtime(for: panes.paneB) === origin)
        #expect(origin.target?.summary.pendingAskCount == 3)
        #expect(origin.target?.summary.name == "Newer")
        #expect(origin.target?.summary.messageCount == 9)
        #expect(origin.restorationError == nil)
        #expect(!origin.traceStore.isResumingSession)
        #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
    }

    @Test func acceptedFoundLookupPublishesThroughCatalogObserverAfterDeckAccepts() async throws {
        let panes = try persistedThreePaneLayout()
        let deck = lookupDeck(persistence: panes.persistence)
        let origin = try #require(deck.runtime(for: panes.paneB))
        let catalog = MacWorkspaceSnapshotStore()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-restore-catalog-accept.sock",
            token: "sk_owner",
            transport: ImmediateSessionRecordTransport(
                response: sessionRecordResponse(sessionID: "session-1", workspaceID: "workspace-1")
            )
        )

        await MacSessionRestorationCatalog.resolvePending(
            deck: deck,
            catalog: catalog,
            client: client
        )
        MacSessionRestorationCatalog.apply(catalog, to: deck)

        #expect(catalog.target(for: "session-1")?.summary.name == "Old")
        #expect(catalog.target(for: "session-1")?.summary.messageCount == 1)
        #expect(deck.runtime(for: panes.paneB) === origin)
        #expect(origin.target?.summary.name == "Old")
        #expect(origin.target?.summary.messageCount == 1)
        #expect(origin.restorationError == nil)
        #expect(!origin.traceStore.isResumingSession)
        #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
    }

    @Test func laterParkedLookupDoesNotRepublishAnOlderAcceptedSameSessionSnapshot() async throws {
        let panes = try persistedThreePaneLayout()
        let deck = twoPendingLookupDeck(persistence: panes.persistence)
        let catalog = MacWorkspaceSnapshotStore()
        let park = LaunchPark()
        let transport = FirstImmediateThenParkSessionRecordTransport(park: park)
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-restore-catalog-two-pending.sock",
            token: "sk_owner",
            transport: transport
        )

        let task = Task { @MainActor in
            await MacSessionRestorationCatalog.resolvePending(
                deck: deck,
                catalog: catalog,
                client: client
            )
            MacSessionRestorationCatalog.apply(catalog, to: deck)
        }
        await park.waitUntilParked()
        let firstID = try #require(await transport.firstSessionID())
        let firstWorkspaceID = "workspace-\(firstID.suffix(1))"
        let newer = catalogTarget(
            sessionID: firstID,
            workspaceID: firstWorkspaceID,
            name: "Newer",
            messageCount: 9,
            pendingAskCount: 3
        )
        catalog.noteOpenedSession(newer)
        MacSessionRestorationCatalog.apply(catalog, to: deck)
        await park.release()
        await task.value

        let secondID = firstID == "session-0" ? "session-1" : "session-0"
        #expect(catalog.target(for: firstID)?.summary.pendingAskCount == 3)
        #expect(catalog.target(for: firstID)?.summary.name == "Newer")
        #expect(catalog.target(for: firstID)?.summary.messageCount == 9)
        #expect(deck.runtime(forSessionID: firstID)?.target?.summary.pendingAskCount == 3)
        #expect(deck.runtime(forSessionID: firstID)?.target?.summary.name == "Newer")
        #expect(catalog.target(for: secondID)?.summary.name == "Old")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
    }

    @Test func disconnectedRestoredRouteRetriesThroughVisibleEntryWithoutResume() async throws {
        let panes = try persistedThreePaneLayout()
        let reload = ReloadRecorder()
        let deck = MacSessionPaneDeck(
            reloadTarget: reload.reload,
            persistence: panes.persistence,
            resolveRestoredRoute: { route in
                route.sessionID == "session-1"
                    ? nil
                    : target(
                        sessionID: route.sessionID,
                        workspaceID: "workspace-\(route.sessionID.suffix(1))"
                    )
            },
            unresolvedRestoredRoute: .lookup
        )
        await deck.resolvePendingRestoredSessions { _ in .disconnected }
        #expect(
            deck.runtime(for: panes.paneB)?.restorationError
                == MacSessionPaneRuntime.disconnectedRestorationMessage
        )

        await deck.retryDisconnectedRestoredSessions { route in
            #expect(route.sessionID == "session-1")
            return .found(
                target(sessionID: "session-1", workspaceID: "workspace-1", status: .stopped)
            )
        }

        let restored = try #require(deck.runtime(for: panes.paneB))
        #expect(restored.target?.sessionId == "session-1")
        #expect(restored.target?.summary.status == .stopped)
        #expect(restored.restorationError == nil)
        #expect(!restored.traceStore.isResumingSession)
        #expect(reload.targets.isEmpty)
        #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
    }

    @Test func sessionRecordHTTPClassificationKeeps404DistinctFromOffline() async {
        let missing = await MacSessionPaneRestoredLookup.fromSessionRecord {
            throw MacWorkspaceClientError.server(status: 404, message: "missing")
        }
        let offline = await MacSessionPaneRestoredLookup.fromSessionRecord {
            throw MacLocalHTTPError.connectionFailed("offline")
        }
        let timeout = await MacSessionPaneRestoredLookup.fromSessionRecord {
            throw MacLocalHTTPError.timeout
        }
        #expect(missing == .unavailable)
        #expect(offline == .disconnected)
        #expect(timeout == .disconnected)
    }

    @Test func disconnectedRetryUsesGetSessionRecordWithoutResume() async throws {
        let panes = try persistedThreePaneLayout()
        let reload = ReloadRecorder()
        let transport = FailThenSucceedSessionRecordTransport(
            response: sessionRecordResponse(sessionID: "session-1", workspaceID: "workspace-1")
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-restore-retry.sock",
            token: "sk_owner",
            transport: transport
        )
        let deck = MacSessionPaneDeck(
            reloadTarget: reload.reload,
            persistence: panes.persistence,
            resolveRestoredRoute: { route in
                route.sessionID == "session-1"
                    ? nil
                    : target(
                        sessionID: route.sessionID,
                        workspaceID: "workspace-\(route.sessionID.suffix(1))"
                    )
            },
            unresolvedRestoredRoute: .lookup
        )

        await deck.resolvePendingRestoredSessions { route in
            await MacSessionPaneRestoredLookup.fromSessionRecord {
                try await client.getSessionRecord(sessionId: route.sessionID)
            }
        }
        #expect(
            deck.runtime(for: panes.paneB)?.restorationError
                == MacSessionPaneRuntime.disconnectedRestorationMessage
        )

        await deck.retryDisconnectedRestoredSessions { route in
            await MacSessionPaneRestoredLookup.fromSessionRecord {
                try await client.getSessionRecord(sessionId: route.sessionID)
            }
        }

        let restored = try #require(deck.runtime(for: panes.paneB))
        #expect(restored.target?.sessionId == "session-1")
        #expect(restored.target?.summary.status == .stopped)
        #expect(restored.restorationError == nil)
        #expect(!restored.traceStore.isResumingSession)
        #expect(reload.targets.isEmpty)
        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.method == "GET" && $0.path.contains("/sessions/session-1") })
        #expect(deck.runtime(for: panes.paneA)?.target?.sessionId == "session-0")
        #expect(deck.runtime(for: panes.paneC)?.target?.sessionId == "session-2")
    }

    @Test func emptyPanesCanKeepSplittingWhenTheWindowIsLargeEnough() throws {
        let deck = MacSessionPaneDeck()
        noteKnownWindow(deck)
        _ = deck.openOrFocus(target(sessionID: "session-0", workspaceID: "workspace"))
        for _ in 1..<6 {
            _ = try #require(splitAnAdmissiblePane(deck))
        }

        #expect(deck.paneCount == 6)
        #expect(deck.visibleSessionIDs == ["session-0"])
    }

    @Test func unknownGeometryDoesNotAdmitASplit() throws {
        let deck = MacSessionPaneDeck()
        _ = deck.openOrFocus(target(sessionID: "session-0", workspaceID: "workspace"))

        #expect(!deck.canSplit)
        #expect(deck.splitFocusedRight(
            with: target(sessionID: "session-1", workspaceID: "workspace")
        ) == nil)
        #expect(deck.paneCount == 1)
        #expect(deck.lastSplitRejection == .paneTooSmall)
    }

    @Test func staleParentMeasurementDoesNotAuthorizeAnUndersizedLeaf() throws {
        let deck = MacSessionPaneDeck()
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 800, height: 700))
        let paneA = try #require(deck.openOrFocus(
            target(sessionID: "session-0", workspaceID: "workspace")
        ))
        deck.notePaneSize(
            MacSessionPaneMeasuredSize(width: 800, height: 700),
            for: paneA.id
        )
        _ = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-1", workspaceID: "workspace")
        ))

        #expect(deck.focus(paneID: paneA.id))
        #expect(deck.splitFocusedRight(
            with: target(sessionID: "session-2", workspaceID: "workspace")
        ) == nil)
        #expect(deck.paneCount == 2)
        #expect(deck.lastSplitRejection == .paneTooSmall)
    }

    @Test func aShrunkWindowRejectsASplitBeforeTheLeafRemeasures() throws {
        let deck = MacSessionPaneDeck()
        let paneA = try #require(deck.openOrFocus(
            target(sessionID: "session-0", workspaceID: "workspace")
        ))
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_200, height: 800))
        deck.notePaneSize(
            MacSessionPaneMeasuredSize(width: 1_200, height: 800),
            for: paneA.id
        )

        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 500, height: 800))

        #expect(deck.splitFocusedRight(
            with: target(sessionID: "session-1", workspaceID: "workspace")
        ) == nil)
        #expect(deck.paneCount == 1)
        #expect(deck.lastSplitRejection == .windowTooSmall)
        #expect(deck.splitRejectionMessage == "This window is too small to split.")
        #expect(!(deck.splitRejectionMessage?.contains("4") ?? false))
        #expect(!(deck.splitRejectionMessage?.contains("four") ?? false))
    }

    @Test func detachedTimelineViewportSurvivesAnActualRetile() throws {
        let deck = MacSessionPaneDeck()
        noteKnownWindow(deck)
        let paneA = try #require(deck.openOrFocus(
            target(sessionID: "session-a", workspaceID: "workspace")
        ))
        paneA.presentation.isLiveTailAttached = false
        paneA.presentation.timelineViewport = MacSessionTimelineViewport(
            offsetY: 420,
            anchorID: "row-8"
        )

        let paneB = try #require(deck.splitFocusedRight(
            with: target(sessionID: "session-b", workspaceID: "workspace")
        ))

        #expect(deck.runtime(for: paneA.id) === paneA)
        #expect(paneA.presentation.isLiveTailAttached == false)
        #expect(paneA.presentation.timelineViewport.offsetY == 420)
        #expect(paneA.presentation.timelineViewport.anchorID == "row-8")
        let remountTarget = MacSessionTimelineAutoFollow.remountScrollTarget(
            isAttached: paneA.presentation.isLiveTailAttached,
            viewport: paneA.presentation.timelineViewport
        )
        #expect(remountTarget == .anchor("row-8", offsetY: 420))
        #expect(
            MacSessionTimelineAutoFollow.restoreCommand(for: remountTarget)
                == .contentOffset(420)
        )
        #expect(paneB.presentation.isLiveTailAttached)
        #expect(paneB.presentation.timelineViewport == MacSessionTimelineViewport())
    }

    private func routeLayout(_ index: Int) -> MacSessionPaneRoute {
        .workspace(workspaceID: "workspace-\(index)", sessionID: "session-\(index)")
    }

    private func lookupDeck(
        persistence: MacSessionPaneLayoutPersistence
    ) -> MacSessionPaneDeck {
        MacSessionPaneDeck(
            persistence: persistence,
            resolveRestoredRoute: { route in
                route.sessionID == "session-1"
                    ? nil
                    : target(
                        sessionID: route.sessionID,
                        workspaceID: "workspace-\(route.sessionID.suffix(1))"
                    )
            },
            unresolvedRestoredRoute: .lookup
        )
    }

    private func twoPendingLookupDeck(
        persistence: MacSessionPaneLayoutPersistence
    ) -> MacSessionPaneDeck {
        MacSessionPaneDeck(
            persistence: persistence,
            resolveRestoredRoute: { route in
                route.sessionID == "session-2"
                    ? target(
                        sessionID: route.sessionID,
                        workspaceID: "workspace-\(route.sessionID.suffix(1))"
                    )
                    : nil
            },
            unresolvedRestoredRoute: .lookup
        )
    }

    private func persistedThreePaneLayout() throws -> (
        paneA: MacSessionPaneID,
        paneB: MacSessionPaneID,
        paneC: MacSessionPaneID,
        persistence: MacSessionPaneLayoutPersistence
    ) {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        let paneC = MacSessionPaneID(rawValue: "pane-c")
        var restored = MacSessionPaneLayout(initialRoute: routeLayout(0), paneID: paneA)
        try restored.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: routeLayout(1),
            newPaneID: paneB,
            paneSize: MacSessionPaneMeasuredSize(width: 2_400, height: 1_400),
            windowSize: MacSessionPaneMeasuredSize(width: 2_400, height: 1_400)
        )
        try restored.split(
            paneID: paneB,
            axis: .vertical,
            newRoute: routeLayout(2),
            newPaneID: paneC,
            fraction: 0.4,
            paneSize: MacSessionPaneMeasuredSize(width: 2_400, height: 1_400),
            windowSize: MacSessionPaneMeasuredSize(width: 2_400, height: 1_400)
        )
        let defaults = UserDefaults(suiteName: "pane-mux-restore-\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        let persistence = MacSessionPaneLayoutPersistence(
            windowID: "main",
            defaults: defaults
        )
        persistence.save(restored)
        return (paneA, paneB, paneC, persistence)
    }

    @Test func focusAdjacentMovesBetweenEmptyAndSessionPanes() throws {
        let deck = MacSessionPaneDeck()
        noteKnownWindow(deck)
        let paneA = try #require(deck.openOrFocus(target(sessionID: "session-a", workspaceID: "workspace")))
        let empty = try #require(deck.splitFocusedRight())

        #expect(deck.focusAdjacent(.left))
        #expect(deck.focusedPaneID == paneA.id)
        #expect(deck.focusAdjacent(.right))
        #expect(deck.focusedPaneID == empty.id)
        #expect(!deck.focusAdjacent(.right))
    }

    private func noteKnownWindow(_ deck: MacSessionPaneDeck) {
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 2_400, height: 1_400))
    }

    @discardableResult
    private func splitAnAdmissiblePane(
        _ deck: MacSessionPaneDeck,
        with target: MacSelectedSessionTarget? = nil
    ) -> MacSessionPaneRuntime? {
        guard let layout = deck.layout, let window = deck.measuredWindowSize else {
            return nil
        }
        for pane in layout.panes {
            let painted = layout.paintedSize(of: pane.id, in: window)
            if MacSessionPaneSplitAdmission.evaluate(
                paneSize: painted,
                windowSize: window,
                axis: .horizontal
            ) == nil {
                _ = deck.focus(paneID: pane.id)
                if let target {
                    return deck.splitFocusedRight(with: target)
                }
                return deck.splitFocusedRight()
            }
            if MacSessionPaneSplitAdmission.evaluate(
                paneSize: painted,
                windowSize: window,
                axis: .vertical
            ) == nil {
                _ = deck.focus(paneID: pane.id)
                if let target {
                    return deck.splitFocusedBelow(with: target)
                }
                return deck.splitFocusedBelow()
            }
        }
        return nil
    }

    private func rootSplitID(_ root: MacSessionPaneNode?) -> MacSessionPaneSplitID? {
        guard case .split(let split) = root else { return nil }
        return split.id
    }

    private func catalogTarget(
        sessionID: String,
        workspaceID: String,
        name: String,
        messageCount: Int,
        pendingAskCount: Int
    ) -> MacSelectedSessionTarget {
        let session = Session(
            id: sessionID,
            workspaceId: workspaceID,
            workspaceName: workspaceID,
            name: name,
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_001),
            messageCount: messageCount,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        var summary = SessionSummary(from: session)
        summary.pendingAskCount = pendingAskCount
        return MacSelectedSessionTarget(
            workspaceId: workspaceID,
            sessionId: sessionID,
            summary: summary
        )
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

@MainActor
private func waitUntilStreaming(
    timeout: Duration = .seconds(2),
    _ predicate: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }
    return predicate()
}

@MainActor
private final class PaneScriptedStreamFactory {
    private let session: Session
    private(set) var createCount = 0
    private var continuations: [Int: AsyncStream<SessionStreamEvent>.Continuation] = [:]

    init(session: Session) {
        self.session = session
    }

    func makeStream(sessionId: String) -> AsyncStream<SessionStreamEvent> {
        let index = createCount
        createCount += 1
        return AsyncStream { continuation in
            self.continuations[index] = continuation
        }
    }

    func waitForCreated(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if createCount >= count { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return createCount >= count
    }

    func yieldConnected(index: Int) {
        continuations[index]?.yield(
            SessionStreamEvent(
                sessionId: session.id,
                message: .connected(session: session),
                meta: nil
            )
        )
    }

    func finish(index: Int) {
        continuations[index]?.finish()
        continuations[index] = nil
    }
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

private actor FirstImmediateThenParkSessionRecordTransport: MacLocalHTTPPerforming {
    private let park: LaunchPark
    private var requests: [MacLocalHTTPRequest] = []

    init(park: LaunchPark) {
        self.park = park
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        if requests.count > 1 {
            await park.park()
        }
        let sessionID = request.path.split(separator: "/").last.map(String.init) ?? "unknown"
        return sessionRecordResponse(
            sessionID: sessionID,
            workspaceID: "workspace-\(sessionID.suffix(1))"
        )
    }

    func firstSessionID() -> String? {
        requests.first.flatMap { $0.path.split(separator: "/").last.map(String.init) }
    }
}

private actor ParkingSessionRecordTransport: MacLocalHTTPPerforming {
    private let park: LaunchPark
    private let response: MacLocalHTTPResponse

    init(park: LaunchPark, response: MacLocalHTTPResponse) {
        self.park = park
        self.response = response
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        await park.park()
        return response
    }
}

private actor ImmediateSessionRecordTransport: MacLocalHTTPPerforming {
    private let response: MacLocalHTTPResponse

    init(response: MacLocalHTTPResponse) {
        self.response = response
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        response
    }
}

private actor FailThenSucceedSessionRecordTransport: MacLocalHTTPPerforming {
    private var requests: [MacLocalHTTPRequest] = []
    private let response: MacLocalHTTPResponse

    init(response: MacLocalHTTPResponse) {
        self.response = response
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        if requests.count == 1 {
            throw MacLocalHTTPError.connectionFailed("offline")
        }
        return response
    }

    func recordedRequests() -> [MacLocalHTTPRequest] {
        requests
    }
}

private func sessionRecordResponse(sessionID: String, workspaceID: String) -> MacLocalHTTPResponse {
    let body = """
    {"session":{"id":"\(sessionID)","workspaceId":"\(workspaceID)","name":"Old","status":"stopped","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0}}
    """
    return MacLocalHTTPResponse(
        statusCode: 200,
        headers: ["content-type": "application/json"],
        body: Data(body.utf8)
    )
}
