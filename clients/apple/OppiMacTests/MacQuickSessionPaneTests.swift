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

        #expect(try await launch.value == nil)
        #expect(deck.runtime(for: origin.id) == nil)
        #expect(deck.focusedPaneID == first.id)
        #expect(first.target?.sessionId == "session-a")
    }

    @Test func focusingQuickSessionInputActivatesItsPane() async throws {
        let deck = MacSessionPaneDeck()
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
        await Task.yield()

        #expect(deck.focusedPaneID == quickSession.id)
        #expect(quickSession.composerState.isComposerFirstResponder)
    }

    private func quickRequest(
        worktreeId: String = "main",
        agentId: String? = nil,
        prompt: String
    ) -> QuickSessionLaunchRequest {
        QuickSessionLaunchRequest(
            workspaceId: "ws-1",
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

    private func agentResponse() -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 201,
            headers: ["content-type": "application/json"],
            body: Data(#"{"receipt":{"accepted":true,"agentId":"reviewer","sessionId":"session-agent","promptDispatch":"delivered"},"session":{"id":"session-agent","workspaceId":"ws-1","name":"Review","status":"busy","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0}}"#.utf8)
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
