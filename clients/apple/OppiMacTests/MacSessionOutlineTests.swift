import Foundation
import Testing
@testable import Oppi

@Suite("Session outline projection")
struct SessionOutlineProjectionTests {
    @Test func allFilterDropsEntriesThatFailTheAllGate() {
        let displayed = SessionOutlineProjection.displayedEntries(
            Self.entries,
            filter: .all,
            query: ""
        )
        #expect(displayed.map(\.id) == ["user-1", "assistant-1", "tool-1", "compaction-1"])
    }

    @Test func messagesFilterKeepsOnlyMessageRows() {
        let displayed = SessionOutlineProjection.displayedEntries(
            Self.entries,
            filter: .messages,
            query: ""
        )
        #expect(displayed.map(\.id) == ["user-1", "assistant-1"])
    }

    @Test func toolsFilterKeepsOnlyToolRows() {
        let displayed = SessionOutlineProjection.displayedEntries(
            Self.entries,
            filter: .tools,
            query: ""
        )
        #expect(displayed.map(\.id) == ["tool-1"])
    }

    @Test func searchMatchesSummaryAndToolName() {
        let bySummary = SessionOutlineProjection.displayedEntries(
            Self.entries,
            filter: .all,
            query: "  hello "
        )
        #expect(bySummary.map(\.id) == ["user-1"])

        let byTool = SessionOutlineProjection.displayedEntries(
            Self.entries,
            filter: .all,
            query: "BASH"
        )
        #expect(byTool.map(\.id) == ["tool-1"])
    }

    @Test func emptySearchDoesNotWidenPastTheActiveFilter() {
        let displayed = SessionOutlineProjection.displayedEntries(
            Self.entries,
            filter: .tools,
            query: "   "
        )
        #expect(displayed.map(\.id) == ["tool-1"])
    }

    @Test func filterTitlesAreAllMessagesTools() {
        #expect(SessionOutlineFilter.allCases.map(\.rawValue) == [
            "All", "Messages", "Tools",
        ])
    }

    private static let entries: [SessionOutlineEntrySnapshot] = [
        .init(
            id: "user-1",
            kind: "user",
            summary: "Hello from the user",
            timestamp: "2026-08-28T20:00:00.000Z",
            isMessage: true,
            isTool: false,
            passesAllFilter: true,
            isForkable: true,
            tool: nil,
            isError: nil
        ),
        .init(
            id: "assistant-1",
            kind: "assistant",
            summary: "I can help with that.",
            timestamp: "2026-08-28T20:00:01.000Z",
            isMessage: true,
            isTool: false,
            passesAllFilter: true,
            isForkable: nil,
            tool: nil,
            isError: nil
        ),
        .init(
            id: "tool-1",
            kind: "tool",
            summary: "$ ls",
            timestamp: "2026-08-28T20:00:02.000Z",
            isMessage: false,
            isTool: true,
            passesAllFilter: true,
            isForkable: nil,
            tool: "bash",
            isError: false
        ),
        .init(
            id: "system-1",
            kind: "system",
            summary: "Session started",
            timestamp: "2026-08-28T19:59:00.000Z",
            isMessage: false,
            isTool: false,
            passesAllFilter: false,
            isForkable: nil,
            tool: nil,
            isError: nil
        ),
        .init(
            id: "compaction-1",
            kind: "compaction",
            summary: "Context compacted",
            timestamp: "2026-08-28T20:00:03.000Z",
            isMessage: false,
            isTool: false,
            passesAllFilter: true,
            isForkable: nil,
            tool: nil,
            isError: nil
        ),
    ]
}

@Suite("Session outline snapshot decode")
struct SessionOutlineSnapshotDecodeTests {
    @Test func decodesTraceOutlinePayload() throws {
        let data = try #"""
        {
          "traceVersion": "abc123",
          "entries": [
            {
              "id": "user-1",
              "kind": "user",
              "summary": "Hello",
              "timestamp": "2026-08-28T20:00:00.000Z",
              "isMessage": true,
              "isTool": false,
              "passesAllFilter": true,
              "isForkable": true
            },
            {
              "id": "tool-1",
              "kind": "tool",
              "summary": "$ ls",
              "timestamp": "2026-08-28T20:00:01.000Z",
              "isMessage": false,
              "isTool": true,
              "passesAllFilter": true,
              "tool": "bash",
              "isError": false
            }
          ],
          "itemCount": 2,
          "sourceCount": 1,
          "jsonlBytes": 4096
        }
        """#.data(using: .utf8).unwrap()

        let snapshot = try JSONDecoder().decode(SessionOutlineSnapshot.self, from: data)
        #expect(snapshot.traceVersion == "abc123")
        #expect(snapshot.itemCount == 2)
        #expect(snapshot.sourceCount == 1)
        #expect(snapshot.jsonlBytes == 4096)
        #expect(snapshot.entries.map(\.id) == ["user-1", "tool-1"])
        #expect(snapshot.entries[0].isForkable == true)
        #expect(snapshot.entries[1].tool == "bash")
        #expect(snapshot.entries[1].isError == false)
    }
}

@Suite("Mac session outline chrome")
struct MacSessionOutlineChromeTests {
    @Test func outlineLivesInTheToolbarNotInspectorOrTimeline() {
        #expect(MacSessionChromeItem.outline.region == .toolbar)
        #expect(MacSessionWindowChrome.items(in: .toolbar).contains(.outline))
        #expect(!MacSessionWindowChrome.items(in: .inspector).contains(.outline))
        #expect(!MacSessionWindowChrome.items(in: .timeline).contains(.outline))
        #expect(!MacSessionWindowChrome.items(in: .composer).contains(.outline))
        #expect(MacSessionChromeItem.outline.composerSlot == nil)
    }
}

@Suite("Mac session outline client")
struct MacSessionOutlineClientTests {
    @Test func getWorkspaceSessionTraceOutlineUsesOwnerUnixSocket() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(Self.outlineResponseJSON.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let outline = try await client.getWorkspaceSessionTraceOutline(
            workspaceId: "ws-1",
            sessionId: "sess-1"
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/workspaces/ws-1/sessions/sess-1/trace-outline")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("sk_"))
        #expect(outline.entries.map(\.id) == ["user-1"])
        #expect(outline.itemCount == 1)
    }

    private static let outlineResponseJSON = """
    {
      "session": {
        "id": "sess-1",
        "workspaceId": "ws-1",
        "status": "ready",
        "createdAt": 0,
        "lastActivity": 0,
        "messageCount": 1,
        "tokens": {"input": 0, "output": 0},
        "cost": 0
      },
      "outline": {
        "traceVersion": "v1",
        "entries": [
          {
            "id": "user-1",
            "kind": "user",
            "summary": "Hello",
            "timestamp": "2026-08-28T20:00:00.000Z",
            "isMessage": true,
            "isTool": false,
            "passesAllFilter": true
          }
        ],
        "itemCount": 1,
        "sourceCount": 1,
        "jsonlBytes": 128
      }
    }
    """
}

@MainActor
@Suite("Mac session outline store")
struct MacSessionOutlineStoreTests {
    @Test func loadStoresDecodedOutlineFromWorkspaceClient() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(MacSessionOutlineClientTestsSupport.outlineResponseJSON.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacSessionTraceStore()
        let target = makeOutlineTarget()
        store.select(target)

        await store.loadSessionOutline(target: target, client: client)

        let request = try #require(await transport.requests.first)
        #expect(request.path == "/workspaces/workspace-outline/sessions/session-outline/trace-outline")
        #expect(store.sessionOutline?.entries.map(\.id) == ["user-1"])
        #expect(store.sessionOutlineError == nil)
        #expect(!store.isLoadingSessionOutline)
    }

    @Test func jumpSetsScrollTargetWithoutOpeningTheDocumentColumn() async {
        let store = MacSessionTraceStore()
        store.select(makeOutlineTarget())

        await store.jumpToOutlineEntry("user-1")

        #expect(store.scrollTargetID == "user-1")
        #expect(store.openToolDocumentID == nil)
        store.clearScrollTarget()
        #expect(store.scrollTargetID == nil)
    }

    @Test func selectingAnotherSessionClearsOutlineAndScrollTarget() async {
        let store = MacSessionTraceStore()
        store.select(makeOutlineTarget())
        await store.jumpToOutlineEntry("user-1")

        store.select(makeOutlineTarget(sessionId: "other-session"))

        #expect(store.sessionOutline == nil)
        #expect(store.scrollTargetID == nil)
        #expect(store.sessionOutlineError == nil)
    }

    @Test func staleOutlineFailureCannotReplaceTheNewSessionsResult() async {
        let deferredTransport = DeferredOutlineTransport()
        let deferredClient = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: deferredTransport
        )
        let currentTransport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: MacSessionOutlineClientTestsSupport.response(
                    sessionId: "session-b",
                    entryId: "user-b"
                )
            )
        )
        let currentClient = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: currentTransport
        )
        let store = MacSessionTraceStore()
        let targetA = makeOutlineTarget(sessionId: "session-a")
        let targetB = makeOutlineTarget(sessionId: "session-b")
        store.select(targetA)

        let staleLoad = Task {
            await store.loadSessionOutline(target: targetA, client: deferredClient)
        }
        await deferredTransport.waitUntilRequested()
        #expect(store.isLoadingSessionOutline)

        store.select(targetB)
        await store.loadSessionOutline(target: targetB, client: currentClient)
        #expect(store.sessionOutline?.entries.map(\.id) == ["user-b"])
        #expect(!store.isLoadingSessionOutline)

        await deferredTransport.fail(MacLocalHTTPError.connectionFailed("stale session A"))
        await staleLoad.value

        #expect(store.selectedTarget == targetB)
        #expect(store.sessionOutline?.entries.map(\.id) == ["user-b"])
        #expect(store.sessionOutlineError == nil)
        #expect(!store.isLoadingSessionOutline)
    }
}

@Suite("Mac session timeline outline jump follow")
struct MacSessionTimelineOutlineJumpTests {
    @Test func jumpingToANonLatestRowDetachesAutoFollow() {
        #expect(
            !MacSessionTimelineAutoFollow.shouldAttachToLatestAfterJump(
                targetID: "user-1",
                latestItemID: "assistant-9"
            )
        )
    }

    @Test func jumpingToTheLatestRowStaysAttached() {
        #expect(
            MacSessionTimelineAutoFollow.shouldAttachToLatestAfterJump(
                targetID: "assistant-9",
                latestItemID: "assistant-9"
            )
        )
    }
}

private enum MacSessionOutlineClientTestsSupport {
    static let outlineResponseJSON = """
    {
      "session": {
        "id": "session-outline",
        "workspaceId": "workspace-outline",
        "status": "ready",
        "createdAt": 0,
        "lastActivity": 0,
        "messageCount": 1,
        "tokens": {"input": 0, "output": 0},
        "cost": 0
      },
      "outline": {
        "traceVersion": "v1",
        "entries": [
          {
            "id": "user-1",
            "kind": "user",
            "summary": "Hello",
            "timestamp": "2026-08-28T20:00:00.000Z",
            "isMessage": true,
            "isTool": false,
            "passesAllFilter": true
          }
        ],
        "itemCount": 1,
        "sourceCount": 1,
        "jsonlBytes": 128
      }
    }
    """

    static func response(sessionId: String, entryId: String) -> Data {
        Data(
            """
            {
              "session": {
                "id": "\(sessionId)",
                "workspaceId": "workspace-outline",
                "status": "ready",
                "createdAt": 0,
                "lastActivity": 0,
                "messageCount": 1,
                "tokens": {"input": 0, "output": 0},
                "cost": 0
              },
              "outline": {
                "traceVersion": "v1",
                "entries": [
                  {
                    "id": "\(entryId)",
                    "kind": "user",
                    "summary": "Hello",
                    "timestamp": "2026-08-28T20:00:00.000Z",
                    "isMessage": true,
                    "isTool": false,
                    "passesAllFilter": true
                  }
                ],
                "itemCount": 1,
                "sourceCount": 1,
                "jsonlBytes": 128
              }
            }
            """.utf8
        )
    }
}

private actor DeferredOutlineTransport: MacLocalHTTPPerforming {
    private var requestStarted = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<MacLocalHTTPResponse, Error>?

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requestStarted = true
        requestWaiter?.resume()
        requestWaiter = nil
        return try await withCheckedThrowingContinuation { continuation in
            responseWaiter = continuation
        }
    }

    func waitUntilRequested() async {
        if requestStarted { return }
        await withCheckedContinuation { continuation in
            if requestStarted {
                continuation.resume()
            } else {
                requestWaiter = continuation
            }
        }
    }

    func fail(_ error: Error) {
        responseWaiter?.resume(throwing: error)
        responseWaiter = nil
    }
}

private func makeOutlineTarget(sessionId: String = "session-outline") -> MacSelectedSessionTarget {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = Session(
        id: sessionId,
        workspaceId: "workspace-outline",
        workspaceName: "Workspace",
        status: .ready,
        createdAt: now,
        lastActivity: now,
        model: "provider/model",
        messageCount: 1,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0,
        firstMessage: "Hello"
    )
    return MacSelectedSessionTarget(
        workspaceId: "workspace-outline",
        sessionId: sessionId,
        summary: SessionSummary(from: session)
    )
}

private extension Optional where Wrapped == Data {
    func unwrap() throws -> Data {
        guard let self else { throw OutlineTestDataError.invalidUTF8 }
        return self
    }
}

private enum OutlineTestDataError: Error {
    case invalidUTF8
}
