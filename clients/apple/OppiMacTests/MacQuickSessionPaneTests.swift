import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Oppi

@MainActor
@Suite("Mac Quick Session pane launch")
struct MacQuickSessionPaneTests {
    @Test func launcherCreatesAPlainPiSessionOnTheOwnerSocket() async throws {
        let transport = RecordingLocalHTTPTransport(response: plainPiResponse())
        let client = makeClient(transport)
        let attempt = try MacQuickSessionPaneState().launchAttempt(
            for: quickRequest(prompt: "")
        ).get()

        let target = try await MacQuickSessionLauncher.launch(attempt: attempt, client: client)

        #expect(target.sessionId == "session-new")
        #expect(target.workspaceId == "ws-1")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/workspaces/ws-1/sessions")
    }

    @Test func launcherUsesAgentSessionsWhenAnAgentIsSelected() async throws {
        let transport = RecordingLocalHTTPTransport(response: agentResponse())
        let client = makeClient(transport)
        let attempt = try MacQuickSessionPaneState().launchAttempt(
            for: quickRequest(
                worktreeId: "wt_feature",
                agentId: "reviewer",
                prompt: "Review the mux"
            )
        ).get()

        let target = try await MacQuickSessionLauncher.launch(attempt: attempt, client: client)

        #expect(target.sessionId == "session-agent")
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/agents/reviewer/sessions")
    }

    @Test func plainPiRetryReusesFrozenFieldsAndIdempotencyKey() async throws {
        let transport = FailFirstQuickSessionTransport(response: plainPiResponse())
        let client = makeClient(transport)
        let state = MacQuickSessionPaneState()
        let request = quickRequest(prompt: "  Keep this exact Pi request  ")
        let firstAttempt = try state.launchAttempt(for: request).get()

        await #expect(throws: MacLocalHTTPError.timeout) {
            try await MacQuickSessionLauncher.launch(attempt: firstAttempt, client: client)
        }

        let retryAttempt = try state.launchAttempt(for: request).get()
        #expect(retryAttempt == firstAttempt)
        _ = try await MacQuickSessionLauncher.launch(attempt: retryAttempt, client: client)

        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        let firstBody = try jsonBody(requests[0])
        let secondBody = try jsonBody(requests[1])
        #expect(firstBody as NSDictionary == secondBody as NSDictionary)
        #expect(firstBody["idempotencyKey"] as? String == firstAttempt.idempotencyKey)
        #expect(firstBody["prompt"] as? String == "Keep this exact Pi request")
        #expect(firstBody["worktreeId"] as? String == "main")
    }

    @Test func agentRetryReusesFrozenFieldsAndIdempotencyKey() async throws {
        let transport = FailFirstQuickSessionTransport(response: agentResponse())
        let client = makeClient(transport)
        let state = MacQuickSessionPaneState()
        let request = quickRequest(
            worktreeId: "wt_feature",
            agentId: "reviewer",
            prompt: "  Review this exact Agent request  "
        )
        let firstAttempt = try state.launchAttempt(for: request).get()

        await #expect(throws: MacLocalHTTPError.timeout) {
            try await MacQuickSessionLauncher.launch(attempt: firstAttempt, client: client)
        }

        let retryAttempt = try state.launchAttempt(for: request).get()
        #expect(retryAttempt == firstAttempt)
        _ = try await MacQuickSessionLauncher.launch(attempt: retryAttempt, client: client)

        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        let firstBody = try jsonBody(requests[0])
        let secondBody = try jsonBody(requests[1])
        #expect(firstBody as NSDictionary == secondBody as NSDictionary)
        #expect(firstBody["idempotencyKey"] as? String == firstAttempt.idempotencyKey)
        #expect((firstBody["prompt"] as? [String: Any])?["text"] as? String
            == "Review this exact Agent request")
        #expect((firstBody["target"] as? [String: Any])?["worktreeId"] as? String == "wt_feature")
    }

    @Test func changedOrCompletedRequestGetsANewLaunchKey() throws {
        let state = MacQuickSessionPaneState()
        let first = try state.launchAttempt(for: quickRequest(prompt: "Original")).get()

        let changed = try state.launchAttempt(for: quickRequest(prompt: "Changed")).get()
        #expect(changed.idempotencyKey != first.idempotencyKey)
        #expect(changed.plan.prompt == "Changed")

        state.markLaunchSucceeded(idempotencyKey: changed.idempotencyKey)
        let afterSuccess = try state.launchAttempt(for: quickRequest(prompt: "Changed")).get()
        #expect(afterSuccess.idempotencyKey != changed.idempotencyKey)
    }

    @Test func zeroPaneLaunchReusesStartupPaneIdentityForCreatedSession() async throws {
        let transport = RecordingLocalHTTPTransport(response: plainPiResponse())
        let client = makeClient(transport)
        let deck = MacSessionPaneDeck()
        let origin = try #require(deck.focusedRuntime)
        let paneID = origin.id
        let attempt = try origin.quickSession.launchAttempt(
            for: quickRequest(prompt: "Start from the empty home")
        ).get()

        let launched = try await MacQuickSessionLauncher.launchIntoOriginatingPane(
            attempt: attempt,
            originatingRuntime: origin,
            deck: deck,
            client: client
        )

        #expect(launched?.sessionId == "session-new")
        #expect(deck.paneCount == 1)
        #expect(deck.focusedPaneID == paneID)
        #expect(deck.focusedRuntime === origin)
        #expect(deck.runtime(for: paneID) === origin)
        #expect(origin.target?.sessionId == "session-new")
        #expect(origin.quickSession.pendingLaunchAttempt == nil)
        #expect((await transport.requests).count == 1)
    }

    @Test func launchCompletionReplacesItsOriginAfterFocusMoves() async throws {
        let transport = SuspendedQuickSessionTransport(response: plainPiResponse())
        let client = makeClient(transport)
        let deck = MacSessionPaneDeck()
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_200, height: 800))
        let first = try #require(deck.openOrFocus(target(sessionID: "session-a")))
        let origin = try #require(deck.splitFocusedRight())
        let attempt = try origin.quickSession.launchAttempt(
            for: quickRequest(prompt: "Create in the right pane")
        ).get()

        let launch = Task {
            try await MacQuickSessionLauncher.launchIntoOriginatingPane(
                attempt: attempt,
                originatingRuntime: origin,
                deck: deck,
                client: client
            )
        }
        await transport.waitUntilRequested()
        #expect(deck.focus(paneID: first.id))
        await transport.complete()

        let launched = try await launch.value
        #expect(launched?.sessionId == "session-new")
        #expect(deck.runtime(for: origin.id) === origin)
        #expect(origin.target?.sessionId == "session-new")
        #expect(deck.focusedPaneID == first.id)
        #expect(first.target?.sessionId == "session-a")
    }

    @Test func launchCompletionDoesNothingWhenItsOriginWasClosed() async throws {
        let transport = SuspendedQuickSessionTransport(response: plainPiResponse())
        let client = makeClient(transport)
        let deck = MacSessionPaneDeck()
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_200, height: 800))
        let first = try #require(deck.openOrFocus(target(sessionID: "session-a")))
        let origin = try #require(deck.splitFocusedRight())
        let attempt = try origin.quickSession.launchAttempt(
            for: quickRequest(prompt: "May finish after close")
        ).get()

        let launch = Task {
            try await MacQuickSessionLauncher.launchIntoOriginatingPane(
                attempt: attempt,
                originatingRuntime: origin,
                deck: deck,
                client: client
            )
        }
        await transport.waitUntilRequested()
        #expect(deck.close(paneID: origin.id))
        await transport.complete()

        let launched = try await launch.value
        #expect(launched?.sessionId == "session-new")
        #expect(deck.runtime(for: origin.id) == nil)
        #expect(deck.focusedPaneID == first.id)
        #expect(first.target?.sessionId == "session-a")
    }

    @Test func latePiCreateDoesNotOverwriteARepurposedSamePane()
    async throws {
        try await assertLateCreateDoesNotOverwriteARepurposedSamePane(
            response: plainPiResponse(),
            createdSessionID: "session-new"
        )
    }

    @Test func lateAgentCreateDoesNotOverwriteARepurposedSamePane()
    async throws {
        try await assertLateCreateDoesNotOverwriteARepurposedSamePane(
            response: agentResponse(),
            createdSessionID: "session-agent",
            request: quickRequest(
                worktreeId: "wt_feature",
                agentId: "reviewer",
                prompt: "Review the mux"
            )
        )
    }

    @Test func lateWorkspaceAListDoesNotReplaceWorkspaceBOrItsCreatePayload()
    async throws {
        let listing = MacQuickSessionWorktreeListing()
        let state = MacQuickSessionPaneState()
        let treesA = [
            worktree(id: "main", isMain: true),
            worktree(id: "wt_a", isMain: false),
        ]
        let treesB = [
            worktree(id: "main", isMain: true),
            worktree(id: "wt_b", isMain: false),
        ]

        let generationA = listing.beginLoad(workspaceId: "ws-a")
        let generationB = listing.beginLoad(workspaceId: "ws-b")
        state.workspaceId = "ws-b"
        state.worktreeId = "wt_b"

        listing.applySuccess(workspaceId: "ws-b", generation: generationB, worktrees: treesB)
        listing.applySuccess(workspaceId: "ws-a", generation: generationA, worktrees: treesA)

        #expect(listing.workspaceId == "ws-b")
        #expect(listing.worktrees.map(\.id) == ["main", "wt_b"])
        #expect(state.worktreeId == "wt_b")
        #expect(listing.launchWorktreeId(selectedId: state.worktreeId) == "wt_b")

        let attempt = try state.launchAttempt(
            for: quickRequest(worktreeId: listing.launchWorktreeId(selectedId: state.worktreeId), prompt: "From B")
        ).get()
        #expect(attempt.plan.worktreeId == "wt_b")

        let transport = RecordingLocalHTTPTransport(response: plainPiResponse())
        _ = try await MacQuickSessionLauncher.launch(attempt: attempt, client: makeClient(transport))
        let body = try jsonBody(try #require(await transport.requests.first))
        #expect(body["worktreeId"] as? String == "wt_b")
    }

    @Test func agentWorkspaceSwitchResetsCheckoutAndKeepsSameWorkspaceSelection() async throws {
        let state = MacQuickSessionPaneState()
        let listing = state.worktreeListing
        let treesA = [
            worktree(id: "main", isMain: true),
            worktree(id: "wt_a", isMain: false),
        ]
        let treesB = [
            worktree(id: "main", isMain: true),
            worktree(id: "wt_b", isMain: false),
        ]
        state.workspaceId = "ws-a"
        let generationA = listing.beginLoad(workspaceId: "ws-a")
        listing.applySuccess(workspaceId: "ws-a", generation: generationA, worktrees: treesA)
        state.worktreeId = "wt_a"
        state.agentId = "reviewer"

        let stillCompatibleWithA = ["ws-a", "ws-b"]
        if let workspaceId = state.workspaceId, stillCompatibleWithA.contains(workspaceId) {
            // keep
        } else {
            state.workspaceId = stillCompatibleWithA.first
        }
        #expect(state.workspaceId == "ws-a")
        #expect(state.worktreeId == "wt_a")
        #expect(listing.workspaceId == "ws-a")

        // Composer onChange of compatible workspaces only assigns workspaceId.
        let compatibleIDs = ["ws-b"]
        if let workspaceId = state.workspaceId, compatibleIDs.contains(workspaceId) {
            // keep
        } else {
            state.workspaceId = compatibleIDs.first
        }

        #expect(state.workspaceId == "ws-b")
        #expect(state.worktreeId != "wt_a")
        #expect(listing.workspaceId == "ws-b")
        #expect(!listing.worktrees.map(\.id).contains("wt_a"))

        let generationB = listing.beginLoad(workspaceId: "ws-b")
        listing.applySuccess(workspaceId: "ws-b", generation: generationB, worktrees: treesB)
        #expect(state.worktreeId == nil || state.worktreeId == "wt_b" || state.worktreeId == "main")
        let resolved = listing.launchWorktreeId(selectedId: state.worktreeId)
        #expect(resolved != "wt_a")
        #expect(["main", "wt_b"].contains(resolved))

        let attempt = try state.launchAttempt(
            for: quickRequest(
                workspaceId: state.workspaceId,
                worktreeId: resolved,
                agentId: state.agentId,
                prompt: "Review B"
            )
        ).get()
        #expect(attempt.plan.workspaceId == "ws-b")
        #expect(attempt.plan.worktreeId != "wt_a")

        let transport = RecordingLocalHTTPTransport(response: agentResponse(workspaceId: "ws-b"))
        _ = try await MacQuickSessionLauncher.launch(attempt: attempt, client: makeClient(transport))
        let body = try jsonBody(try #require(await transport.requests.first))
        let target = try #require(body["target"] as? [String: Any])
        #expect(target["workspaceId"] as? String == "ws-b")
        #expect(target["worktreeId"] as? String != "wt_a")
    }

    @Test func failedRefreshKeepsExplicitNonMainCheckoutInTheCreatePayload()
    async throws {
        let listing = MacQuickSessionWorktreeListing()
        let state = MacQuickSessionPaneState()
        let treesB = [
            worktree(id: "main", isMain: true),
            worktree(id: "wt_b", isMain: false),
        ]
        let loaded = listing.beginLoad(workspaceId: "ws-b")
        listing.applySuccess(workspaceId: "ws-b", generation: loaded, worktrees: treesB)
        state.workspaceId = "ws-b"
        state.worktreeId = "wt_b"

        let refresh = listing.beginLoad(workspaceId: "ws-b")
        listing.applySuccess(workspaceId: "ws-b", generation: refresh, worktrees: [])

        #expect(state.worktreeId == "wt_b")
        #expect(listing.launchWorktreeId(selectedId: state.worktreeId) == "wt_b")
        let attempt = try state.launchAttempt(
            for: quickRequest(
                worktreeId: listing.launchWorktreeId(selectedId: state.worktreeId),
                prompt: "Keep B checkout"
            )
        ).get()
        #expect(attempt.plan.worktreeId == "wt_b")

        let transport = RecordingLocalHTTPTransport(response: plainPiResponse())
        _ = try await MacQuickSessionLauncher.launch(attempt: attempt, client: makeClient(transport))
        let body = try jsonBody(try #require(await transport.requests.first))
        #expect(body["worktreeId"] as? String == "wt_b")
    }

    @Test func focusingQuickSessionInputActivatesItsPane() async throws {
        let deck = MacSessionPaneDeck()
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_200, height: 800))
        let first = try #require(deck.openOrFocus(target(sessionID: "session-a")))
        let quickSession = try #require(deck.splitFocusedRight())
        #expect(deck.focus(paneID: first.id))

        let root = MacSessionPaneDeckView(
            deck: deck,
            workspaces: [workspace()],
            isStoppingSession: { _ in false },
            stopTarget: { _ in },
            loadWorktrees: { _ in [] },
            launchQuickSession: { _, _ in },
            loadsSessionsOnMount: false
        )
        .environment(\.theme, AppTheme.dark)
        .environment(\.themeID, ThemeID.dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let inputs = descendants(of: host, type: MacComposerPasteTextView.self)
        let rightmostInput = try #require(inputs.max { lhs, rhs in
            lhs.convert(lhs.bounds, to: nil).midX < rhs.convert(rhs.bounds, to: nil).midX
        })
        #expect(window.makeFirstResponder(rightmostInput))
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            await Task.yield()
            if deck.focusedPaneID == quickSession.id,
               quickSession.composerState.isComposerFirstResponder {
                break
            }
        }

        #expect(deck.focusedPaneID == quickSession.id)
        #expect(quickSession.composerState.isComposerFirstResponder)
    }

    private func assertLateCreateDoesNotOverwriteARepurposedSamePane(
        response: MacLocalHTTPResponse,
        createdSessionID: String,
        request: QuickSessionLaunchRequest? = nil
    ) async throws {
        let transport = SuspendedQuickSessionTransport(response: response)
        let client = makeClient(transport)
        let deck = MacSessionPaneDeck()
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_200, height: 800))
        let origin = try #require(deck.focusedRuntime)
        let paneID = origin.id
        let attempt = try origin.quickSession.launchAttempt(
            for: request ?? quickRequest(prompt: "Create while I keep typing")
        ).get()

        let launch = Task {
            try await MacQuickSessionLauncher.launchIntoOriginatingPane(
                attempt: attempt,
                originatingRuntime: origin,
                deck: deck,
                client: client
            )
        }
        await transport.waitUntilRequested()
        let sessionB = try #require(deck.replace(
            paneID: paneID,
            with: target(sessionID: "session-b")
        ))
        sessionB.composerState.draft = "Keep B's draft"
        #expect(sessionB === origin)
        #expect(origin.target?.sessionId == "session-b")
        await transport.complete()

        let launched = try await launch.value
        #expect(launched?.sessionId == createdSessionID)
        #expect(deck.runtime(for: paneID) === origin)
        #expect(origin.target?.sessionId == "session-b")
        #expect(origin.composerState.draft == "Keep B's draft")
        #expect(deck.focusedPaneID == paneID)
        #expect(origin.quickSession.pendingLaunchAttempt == nil)
    }

    private func quickRequest(
        workspaceId: String? = "ws-1",
        worktreeId: String = "main",
        agentId: String? = nil,
        prompt: String
    ) -> QuickSessionLaunchRequest {
        QuickSessionLaunchRequest(
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            agentId: agentId,
            prompt: prompt,
            hasAttachments: false,
            hasRepoReferences: false
        )
    }

    private func makeClient(_ transport: any MacLocalHTTPPerforming) -> MacWorkspaceClient {
        MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
    }

    private func jsonBody(_ request: MacLocalHTTPRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func target(sessionID: String) -> MacSelectedSessionTarget {
        let session = Session(
            id: sessionID,
            workspaceId: "ws-1",
            workspaceName: "Oppi",
            name: sessionID,
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_001),
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        return MacSelectedSessionTarget(
            workspaceId: "ws-1",
            sessionId: sessionID,
            summary: SessionSummary(from: session)
        )
    }

    private func worktree(id: String, isMain: Bool) -> WorkspaceWorktree {
        WorkspaceWorktree(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            branch: isMain ? "main" : id,
            headSha: nil,
            isMain: isMain,
            isGitRepo: true,
            sessionCount: nil
        )
    }

    private func workspace() -> Workspace {
        Workspace(
            id: "ws-1",
            name: "Oppi",
            description: nil,
            icon: .symbol("folder"),
            systemPrompt: nil,
            hostMount: "/tmp/oppi",
            tools: nil,
            gitStatusEnabled: nil,
            runtime: .host,
            sandboxConfig: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func plainPiResponse() -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(#"{"session":{"id":"session-new","workspaceId":"ws-1","worktreeId":"main","name":"New","status":"ready","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0},"prompted":true}"#.utf8)
        )
    }

    private func agentResponse(workspaceId: String = "ws-1") -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 201,
            headers: ["content-type": "application/json"],
            body: Data(#"{"receipt":{"accepted":true,"agentId":"reviewer","sessionId":"session-agent","promptDispatch":"delivered"},"session":{"id":"session-agent","workspaceId":"WORKSPACE","name":"Review","status":"busy","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0}}"#.replacingOccurrences(of: "WORKSPACE", with: workspaceId).utf8)
        )
    }
}

private actor FailFirstQuickSessionTransport: MacLocalHTTPPerforming {
    private var requests: [MacLocalHTTPRequest] = []
    private let response: MacLocalHTTPResponse

    init(response: MacLocalHTTPResponse) {
        self.response = response
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        if requests.count == 1 {
            throw MacLocalHTTPError.timeout
        }
        return response
    }

    func recordedRequests() -> [MacLocalHTTPRequest] {
        requests
    }
}

private actor SuspendedQuickSessionTransport: MacLocalHTTPPerforming {
    private var requests: [MacLocalHTTPRequest] = []
    private var continuation: CheckedContinuation<MacLocalHTTPResponse, Never>?
    private let response: MacLocalHTTPResponse

    init(response: MacLocalHTTPResponse) {
        self.response = response
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        while requests.isEmpty {
            await Task.yield()
        }
    }

    func complete() {
        continuation?.resume(returning: response)
        continuation = nil
    }
}

@MainActor
private func descendants<T: NSView>(of root: NSView, type: T.Type) -> [T] {
    var matches: [T] = []
    if let match = root as? T {
        matches.append(match)
    }
    for subview in root.subviews {
        matches.append(contentsOf: descendants(of: subview, type: type))
    }
    return matches
}
