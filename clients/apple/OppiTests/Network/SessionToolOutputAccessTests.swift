import Foundation
import Testing
import UIKit
@testable import Oppi

/// Tool-output access wiring against a real `APIClient` whose transport records the
/// HTTP request that leaves the client. Loader retry/cancel/stale-row behavior and the
/// expand/copy fetch policy have their own suites; these prove which session, scope, and
/// client the capabilities are bound to and when none exists.
@MainActor
@Suite("Session tool-output access", .serialized)
struct SessionToolOutputAccessTests {
    init() { RecordingToolOutputProtocol.reset() }

    private func makeClient(host: String) throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingToolOutputProtocol.self]
        return APIClient(
            baseURL: (try #require(URL(string: "http://\(host):7749"))),
            token: "sk_test",
            configuration: config
        )
    }

    private func makeContent(client: APIClient?, polls: PollCounter = PollCounter()) -> SessionContentAccess {
        SessionContentAccess(
            apiClient: { _ = polls.next(); return client },
            serverId: { nil },
            sessionStore: SessionStore(),
            workspaceStore: WorkspaceStore(),
            readinessPoll: .milliseconds(1)
        )
    }

    private func signature(_ request: URLRequest) -> String {
        let url = request.url
        let query = url?.query.map { "?\($0)" } ?? ""
        return "\(request.httpMethod ?? "") \(url?.host ?? "")\(url?.path ?? "")\(query)"
    }

    @Test("Generated result disclosure uses the bound HTTP scope and preserves truncation warnings")
    func inputCardOutputUsesBoundScope() async throws {
        let content = makeContent(client: try makeClient(host: "server-a.test"))
        for scope in [SessionRouteScope.workspace("w1"), .control] {
            let fetch = try #require(content.inputCardOutputFetch(sessionId: "s1", routeScope: scope,
                output: .init(kind: "terminal", entryId: "42", command: nil, truncated: true)))
            let result = try await fetch()
            #expect(result.contains("Earlier output is unavailable"))
        }
        #expect(RecordingToolOutputProtocol.requests.map(signature) == [
            "GET server-a.test/workspaces/w1/sessions/s1/input-card-output/42",
            "GET server-a.test/control-sessions/s1/input-card-output/42"
        ])
        #expect(content.inputCardOutputFetch(sessionId: "s1", routeScope: nil,
            output: .init(kind: "terminal", entryId: "42", command: nil, truncated: nil)) == nil)
    }

    @Test("Expand, copy, and sidecar reads target the bound session, scope, and client")
    func operationsTargetBoundSessionAndScope() async throws {
        let content = makeContent(client: try makeClient(host: "server-a.test"))
        let workspace = try #require(content.toolOutputAccess(sessionId: "s1", routeScope: .workspace("w1")))
        let control = try #require(content.toolOutputAccess(sessionId: "s2", routeScope: .control))

        let expanded = try await workspace.fetchForExpand(availability: nil, toolCallId: "tc-1")
        #expect(expanded.text == "OUT")
        let copyFetch = try #require(control.completeOutputFetch(availability: .init(complete: false, source: "sidecar"), toolCallId: "tc-2", store: nil))
        #expect(try await copyFetch() == "OUT")
        let sidecar = workspace.sidecarSource(toolCallId: "tc-3")
        _ = try? await sidecar.loadFirst()
        _ = try? await sidecar.loadNext(42)

        let requests = RecordingToolOutputProtocol.requests
        #expect(requests.map(signature) == [
            "GET server-a.test/workspaces/w1/sessions/s1/tool-output/tc-1",
            "GET server-a.test/control-sessions/s2/tool-output/tc-2?full=true",
            "HEAD server-a.test/workspaces/w1/sessions/s1/tool-output/tc-3?full=true",
            "GET server-a.test/workspaces/w1/sessions/s1/tool-output/tc-3?full=true",
        ])
        #expect(requests.last?.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=42-") == true)
    }

    @Test("No capability without a current client or route scope, and no readiness wait")
    func absentClientOrScopeYieldsNoCapability() {
        let clientPolls = PollCounter()
        let noClient = makeContent(client: nil, polls: clientPolls)
        #expect(noClient.toolOutputAccess(sessionId: "s1", routeScope: .workspace("w1")) == nil)
        #expect(clientPolls.count == 1)

        let withClient = makeContent(client: try makeClient(host: "server-a.test"))
        #expect(withClient.toolOutputAccess(sessionId: "s1", routeScope: nil) == nil)
        #expect(RecordingToolOutputProtocol.requests.isEmpty)
    }

    @Test("Copy prefers complete stored output, refetches over a stored preview, and requires a producer sidecar fact")
    func copyFetchPolicy() async throws {
        let content = makeContent(client: try makeClient(host: "server-a.test"))
        let access = try #require(content.toolOutputAccess(sessionId: "s1", routeScope: .workspace("w1")))
        let store = ToolOutputStore()

        #expect(access.completeOutputFetch(availability: nil, toolCallId: "tc-1", store: store) == nil)

        store.replace("PREVIEW", for: "tc-1", previewOnly: true, totalBytes: 1_000_000)
        let fetch = try #require(access.completeOutputFetch(availability: .init(complete: false, source: "sidecar"), toolCallId: "tc-1", store: store))
        #expect(try await fetch() == "OUT")
        #expect(RecordingToolOutputProtocol.requests.count == 1)

        store.replace("COMPLETE", for: "tc-1")
        #expect(try await fetch() == "COMPLETE")
        #expect(RecordingToolOutputProtocol.requests.count == 1)
    }

    @Test("Timeline expand fetches through the connection's client for the timeline's session and scope")
    func timelineExpandUsesBoundSessionAndScope() async throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
        harness.connection.setAPIClientForTesting(try makeClient(host: "server-a.test"))
        let configuration = makeTimelineConfiguration(
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer,
            routeScope: .control
        )
        harness.coordinator.apply(configuration: configuration, to: harness.collectionView)

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            tool: "read",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForTimelineCondition(timeoutMs: 1_500) {
            await MainActor.run { harness.toolOutputStore.fullOutput(for: "tool-1") == "OUT" }
        })
        #expect(RecordingToolOutputProtocol.requests.map(signature) == [
            "GET server-a.test/control-sessions/session-a/tool-output/tool-1",
        ])
    }

    @Test("Timeline without a current API client starts no expand fetch")
    func timelineWithoutClientStartsNoFetch() {
        let harness = makeTimelineHarness(sessionId: "session-a")
        // Scope is present; only the client is missing.
        let configuration = makeTimelineConfiguration(
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer,
            routeScope: .control
        )
        harness.coordinator.apply(configuration: configuration, to: harness.collectionView)
        #expect(harness.connection.apiClient == nil)

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            tool: "read",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(harness.coordinator._toolOutputLoadTaskCountForTesting == 0)
        #expect(RecordingToolOutputProtocol.requests.isEmpty)
    }
}

@MainActor
private final class PollCounter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private final class RecordingToolOutputProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.lock.lock()
            Self.recorded.append(request)
            Self.lock.unlock()
            let body = request.httpMethod == "HEAD"
                ? Data()
                : Data(#"{"output":"OUT","isError":false}"#.utf8)
            let response = try #require(HTTPURLResponse(
                url: (try #require(request.url)),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "Content-Length": "\(body.count)"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
