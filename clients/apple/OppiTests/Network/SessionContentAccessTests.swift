import Foundation
import Testing
@testable import Oppi

/// Session content access wiring against a real `ServerConnection` and a real
/// `APIClient` whose transport is a recording URLProtocol. The oracle is the
/// HTTP request that leaves the client, so these prove readiness, cancellation,
/// and source identity without asserting how call sites are spelled.
@MainActor
@Suite("Session content access", .serialized)
struct SessionContentAccessTests {
    init() { RecordingContentProtocol.reset() }

    @Test("Session file waits for client and workspace metadata, then reads the bound session")
    func sessionFileWaitsForClientAndWorkspace() async throws {
        let sessionStore = SessionStore()
        let polls = PollCounter()
        let client = makeClient(host: "server-a.test")
        // Client is ready on poll 2 but the session's workspace only arrives on
        // poll 4: a cached row must keep waiting instead of guessing a workspace.
        let content = SessionContentAccess(
            apiClient: {
                let poll = polls.next()
                if poll == 4 {
                    sessionStore.upsert(makeTestSession(id: "s-bound", workspaceId: "w1"))
                }
                return poll >= 2 ? client : nil
            },
            serverId: { nil },
            sessionStore: sessionStore,
            workspaceStore: WorkspaceStore(),
            readinessPoll: .milliseconds(1)
        )

        let data = try await content.fetchSessionFileData(
            workspaceId: nil,
            sessionId: "s-bound",
            path: "notes/a.txt"
        )

        // The request could only leave after the workspace resolved.
        #expect(polls.count == 5)
        let request = try #require(RecordingContentProtocol.requests.first)
        #expect(RecordingContentProtocol.requests.count == 1)
        #expect(request.url?.host == "server-a.test")
        #expect(request.url?.path == "/workspaces/w1/sessions/s-bound/raw/notes/a.txt")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
        #expect(String(data: data, encoding: .utf8) == request.url?.absoluteString)
    }

    @Test("Connection supplies its current client and server-scoped workspace catalog")
    func connectionSuppliesCurrentClientAndCatalog() async throws {
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials(fingerprint: "server-a"))
        connection.setAPIClientForTesting(makeClient(host: "old-server.test"))
        connection.setAPIClientForTesting(makeClient(host: "new-server.test"))
        // Only the connected server's partition knows this sandbox workspace.
        var sandbox = makeTestWorkspace(id: "w1")
        sandbox.runtime = .sandbox
        connection.workspaceStore.upsert(sandbox, serverId: "server-a")

        _ = try await connection.sessionContent.fetchHostFile(
            path: "/tmp/a.png",
            workspaceId: "w1",
            sessionId: "s-bound",
            worktreeId: nil
        )

        let request = try #require(RecordingContentProtocol.requests.first)
        #expect(RecordingContentProtocol.requests.count == 1)
        #expect(request.url?.host == "new-server.test")
        expectPath(request, prefix: "/workspaces/w1/sessions/s-bound/raw/", file: "tmp/a.png")
    }

    @Test("Stored attachments keep session versus control-session origin")
    func attachmentOriginFollowsRouteScope() async throws {
        let connection = ServerConnection()
        connection.setAPIClientForTesting(makeClient(host: "server-a.test"))
        let content = connection.sessionContent

        _ = try await content.fetchSessionAttachment(sessionId: "s1", attachmentId: "a1")
        _ = try await content.fetchSessionAttachment(
            sessionId: "s1",
            attachmentId: "a2",
            routeScope: .workspace("w1")
        )
        _ = try await content.fetchSessionAttachment(
            sessionId: "s1",
            attachmentId: "a3",
            routeScope: .control
        )
        let source = try await content.makeSessionAttachmentMediaSource(
            sessionId: "s1",
            attachmentId: "a4",
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4",
            routeScope: .control
        )

        #expect(RecordingContentProtocol.requests.compactMap { $0.url?.path } == [
            "/sessions/s1/attachments/a1",
            "/sessions/s1/attachments/a2",
            "/control-sessions/s1/attachments/a3",
        ])
        #expect(source.url.path == "/control-sessions/s1/attachments/a4")
        #expect(source.contentTypeHint == "video/mp4")
    }

    @Test("Cancelling a waiting request throws cancellation and never sends a request")
    func cancellationWhileWaitingSendsNothing() async {
        let polls = PollCounter()
        let cancelHandle = TaskHandle()
        let client = makeClient(host: "server-a.test")
        let content = SessionContentAccess(
            apiClient: {
                if polls.next() == 2 { cancelHandle.cancel() }
                // A client that would arrive later must not resurrect the request.
                return polls.count > 2 ? client : nil
            },
            serverId: { nil },
            sessionStore: SessionStore(),
            workspaceStore: WorkspaceStore(),
            readinessPoll: .milliseconds(1)
        )
        let task = Task { @MainActor in
            try await content.fetchHostFile(
                path: "/tmp/a.png",
                workspaceId: nil,
                sessionId: nil,
                worktreeId: nil
            )
        }
        cancelHandle.task = task
        let result = await task.result

        guard case .failure(let error) = result else {
            Issue.record("expected cancellation, got \(result)")
            return
        }
        #expect(error is CancellationError)
        #expect(polls.count == 2)
        #expect(RecordingContentProtocol.requests.isEmpty)
    }

    @Test("Readiness is bounded: no client yields the documented 503")
    func missingClientTimesOut() async {
        let polls = PollCounter()
        let content = SessionContentAccess(
            apiClient: { _ = polls.next(); return nil },
            serverId: { nil },
            sessionStore: SessionStore(),
            workspaceStore: WorkspaceStore(),
            readinessPoll: .milliseconds(1)
        )

        await expectServerError(status: 503, message: "Server client is not ready") {
            _ = try await content.fetchSessionAttachment(sessionId: "s1", attachmentId: "a1")
        }
        #expect(polls.count == 50)
        await expectServerError(status: 503, message: "Session file client is not ready") {
            _ = try await content.fetchSessionFileData(
                workspaceId: "w1",
                sessionId: "s1",
                path: "a.txt"
            )
        }
        #expect(RecordingContentProtocol.requests.isEmpty)
    }

    @Test("Host-path fetch prefers the current catalog runtime over a stale captured one")
    func hostFileRuntimePrecedenceAndOrigins() async throws {
        let connection = ServerConnection()
        connection.setAPIClientForTesting(makeClient(host: "server-a.test"))
        let content = connection.sessionContent

        // Unknown runtime: owner-host read.
        _ = try await content.fetchHostFile(
            path: "/tmp/a.png",
            workspaceId: "w1",
            sessionId: "s1",
            worktreeId: nil
        )

        var sandbox = makeTestWorkspace(id: "w1")
        sandbox.runtime = .sandbox
        connection.workspaceStore.upsert(sandbox)

        // Current sandbox runtime wins over the captured host snapshot, and a
        // source session keeps the guest path off the owner-host origin.
        _ = try await content.fetchHostFile(
            path: "/tmp/b.png",
            workspaceId: "w1",
            sessionId: "s1",
            worktreeId: nil,
            workspaceRuntime: .host
        )
        // Without a source session the workspace origin carries the worktree.
        _ = try await content.fetchHostFile(
            path: "/tmp/c.png",
            workspaceId: "w1",
            sessionId: nil,
            worktreeId: "wt_feature"
        )

        let requests = RecordingContentProtocol.requests
        #expect(requests.count == 3)
        #expect(requests[0].url?.path == "/files/raw")
        #expect(query(requests[0], "path") == "/tmp/a.png")
        expectPath(requests[1], prefix: "/workspaces/w1/sessions/s1/raw/", file: "tmp/b.png")
        expectPath(requests[2], prefix: "/workspaces/w1/raw/", file: "tmp/c.png")
        #expect(query(requests[2], "worktreeId") == "wt_feature")
    }

    @Test("Sandbox host path without workspace or session is unavailable, not a host read")
    func sandboxHostPathWithoutOriginIsUnavailable() async throws {
        let connection = ServerConnection()
        connection.setAPIClientForTesting(makeClient(host: "server-a.test"))

        await expectServerError(status: 404, message: "Host image is unavailable") {
            _ = try await connection.sessionContent.fetchHostFile(
                path: "/tmp/a.png",
                workspaceId: nil,
                sessionId: nil,
                worktreeId: nil,
                workspaceRuntime: .sandbox
            )
        }
        #expect(RecordingContentProtocol.requests.isEmpty)
    }

    @Test("Markdown video resolves current sandbox runtime into session or workspace origin")
    func markdownVideoUsesCurrentRuntime() async throws {
        let connection = ServerConnection()
        connection.setAPIClientForTesting(makeClient(host: "server-a.test"))
        let content = connection.sessionContent
        var sandbox = makeTestWorkspace(id: "w1")
        sandbox.runtime = .sandbox
        connection.workspaceStore.upsert(sandbox)
        let embed = try makeVideoEmbed("![[/tmp/demo.mov]]")

        let source = try await content.makeMarkdownVideoMediaSource(
            embed: embed,
            workspaceId: "w1",
            sessionId: "s-source",
            worktreeId: nil,
            workspaceRuntime: nil
        )
        expectPath(source.url, prefix: "/workspaces/w1/sessions/s-source/raw/", file: "tmp/demo.mov")
        #expect(source.contentTypeHint == MediaMimeType.videoMimeType(forPathExtension: "mov"))
        #expect(source.sourceFileExtension == "mov")

        // Without a source session the bound checkout selects the workspace origin.
        let workspaceSource = try await content.makeMarkdownVideoMediaSource(
            embed: embed,
            workspaceId: "w1",
            sessionId: nil,
            worktreeId: "wt_bound",
            workspaceRuntime: nil
        )
        expectPath(workspaceSource.url, prefix: "/workspaces/w1/raw/", file: "tmp/demo.mov")
        #expect(URLComponents(url: workspaceSource.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "worktreeId" })?.value == "wt_bound")
    }

    @Test("Session-file media source resolves the workspace from the cached session")
    func sessionFileMediaSourceResolvesWorkspaceFromSession() async throws {
        let connection = ServerConnection()
        connection.setAPIClientForTesting(makeClient(host: "server-a.test"))
        connection.sessionStore.upsert(makeTestSession(id: "s-bound", workspaceId: "w1"))

        let source = try await connection.sessionContent.makeSessionFileMediaSource(
            workspaceId: nil,
            sessionId: "s-bound",
            path: "clips/a.mp4",
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4"
        )

        #expect(source.url.host == "server-a.test")
        #expect(source.url.path == "/workspaces/w1/sessions/s-bound/raw/clips/a.mp4")
        #expect(source.contentTypeHint == "video/mp4")
    }

    // MARK: - Helpers

    private func makeClient(host: String) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingContentProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://\(host):7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    /// Absolute guest/host paths may carry a doubled slash after the route
    /// prefix; the contract is the origin prefix plus the file path.
    private func expectPath(
        _ request: URLRequest,
        prefix: String,
        file: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let url = request.url else {
            Issue.record("request has no URL", sourceLocation: sourceLocation)
            return
        }
        expectPath(url, prefix: prefix, file: file, sourceLocation: sourceLocation)
    }

    private func expectPath(
        _ url: URL,
        prefix: String,
        file: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(url.path.hasPrefix(prefix), sourceLocation: sourceLocation)
        #expect(url.path.hasSuffix(file), sourceLocation: sourceLocation)
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        return items.first(where: { $0.name == name })?.value
    }

    private func makeVideoEmbed(_ markdown: String) throws -> MarkdownVideoEmbed {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let result = FlatSegment.buildWithSourceLineRanges(
            from: parseCommonMarkLocated(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "w1",
            sessionID: "s-source",
            serverBaseURL: baseURL,
            mergeAdjacentTextSegments: false
        )
        return try #require(result.segments.compactMap { segment -> MarkdownVideoEmbed? in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }.first)
    }

    private func expectServerError(
        status expectedStatus: Int,
        message expectedMessage: String,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("expected APIError.server(\(expectedStatus))")
        } catch let APIError.server(status, message) {
            #expect(status == expectedStatus)
            #expect(message == expectedMessage)
        } catch {
            Issue.record("unexpected error \(error)")
        }
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

@MainActor
private final class TaskHandle {
    var task: Task<Data, Error>?
    func cancel() { task?.cancel() }
}

/// Records every request and answers with the request URL as the body so tests
/// can prove which bytes came from which route.
private final class RecordingContentProtocol: URLProtocol, @unchecked Sendable {
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
        Self.lock.lock()
        Self.recorded.append(request)
        Self.lock.unlock()
        let body = Data((request.url?.absoluteString ?? "").utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "\(body.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
