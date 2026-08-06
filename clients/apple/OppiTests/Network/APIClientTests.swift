import Testing
import Foundation
@testable import Oppi

// swiftlint:disable force_unwrapping non_optional_string_data_conversion

// MARK: - Mock URL Protocol

/// Backward-compatible alias. Shared implementation lives in Support/TestDoubles.swift.
typealias MockURLProtocol = TestURLProtocol

private actor BootstrapDeadlineGate {
    private var expired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !expired else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func expire() {
        expired = true
        continuation?.resume()
        continuation = nil
    }
}

private actor BootstrapRequestProbe {
    private var started = false
    private var cancelled = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?

    func requestDidStart() {
        started = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func requestDidCancel() {
        cancelled = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitForCancellation() async {
        guard !cancelled else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
        }
    }
}

private final class BlockingBootstrapURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var probe: BootstrapRequestProbe?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let probe = Self.probe {
            Task { await probe.requestDidStart() }
        }
    }

    override func stopLoading() {
        if let probe = Self.probe {
            Task { await probe.requestDidCancel() }
        }
    }
}

private actor AvailabilityFailureRecorder {
    private var recorded: [APIClientAvailabilityFailure] = []

    func record(_ failure: APIClientAvailabilityFailure) {
        recorded.append(failure)
    }

    func failures() -> [APIClientAvailabilityFailure] {
        recorded
    }

    /// Availability observers are fire-and-forget from APIClient.
    func waitForFailures(
        count: Int,
        timeoutMs: Int = 1_000
    ) async -> [APIClientAvailabilityFailure] {
        let attempts = max(1, timeoutMs / 5)
        for _ in 0..<attempts {
            if recorded.count >= count { return recorded }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return recorded
    }
}

@Suite("APIClient", .serialized)
struct APIClientTests {

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let environment = OppiClientEnvironment(
            baseURL: URL(string: "http://localhost:7749")!,
            bearerToken: "sk_test"
        )
        return APIClient(
            environment: environment,
            configuration: config
        )
    }

    private func cleanup() {
        MockURLProtocol.handler = nil
    }

    private func mockResponse(status: Int = 200, json: String) -> (Data, HTTPURLResponse) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://localhost:7749")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    private struct UploadCreateRequestBody: Decodable {
        let name: String
        let mimeType: String
        let sizeBytes: Int
        let purpose: String
    }

    private func requestBodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(read))
        }

        return data
    }

    // MARK: - Health

    @Test func serverInfoBootstrapUsesAuthenticatedRequestAndDecodesResponse() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/server/info")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
            return self.mockResponse(json: """
            {"name":"Test","version":"1.0","uptime":1,"os":"darwin","arch":"arm64","hostname":"test","nodeVersion":"22","piVersion":"1","configVersion":1,"stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}
            """)
        }

        let info = try await client.serverInfo(bootstrapDeadline: .after(.seconds(1)))
        #expect(info.name == "Test")
    }

    @Test func bootstrapDeadlineCancelsItsURLSessionRequestAndReportsTimeout() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingBootstrapURLProtocol.self]
        let probe = BootstrapRequestProbe()
        let deadlineGate = BootstrapDeadlineGate()
        let recorder = AvailabilityFailureRecorder()
        BlockingBootstrapURLProtocol.probe = probe
        defer { BlockingBootstrapURLProtocol.probe = nil }

        let client = APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "http://localhost:7749")!,
                bearerToken: "sk_test"
            ),
            configuration: configuration,
            availabilityObserver: { failure in
                await recorder.record(failure)
            }
        )
        let request = Task {
            try await client.serverInfo(bootstrapDeadline: .init(wait: {
                await deadlineGate.wait()
            }))
        }

        await probe.waitForStart()
        await deadlineGate.expire()

        await #expect(throws: URLError.self) {
            _ = try await request.value
        }
        await probe.waitForCancellation()
        #expect(await recorder.waitForFailures(count: 1) == [.timedOut])
    }

    @Test(arguments: [
        (URLError.Code.timedOut, APIClientAvailabilityFailure.timedOut),
        (.cannotFindHost, .cannotFindHost),
        (.cannotConnectToHost, .cannotConnectToHost),
        (.networkConnectionLost, .networkConnectionLost),
        (.notConnectedToInternet, .notConnectedToInternet),
        (.dnsLookupFailed, .dnsLookupFailed),
        (.cannotLoadFromNetwork, .cannotLoadFromNetwork),
    ])
    func availabilityClassifierRecognizesOnlyRoutingFailures(
        code: URLError.Code,
        expected: APIClientAvailabilityFailure
    ) {
        #expect(APIClientAvailabilityFailure(error: URLError(code)) == expected)
    }

    @Test(arguments: [
        URLError.Code.cancelled,
        .secureConnectionFailed,
        .serverCertificateHasBadDate,
        .serverCertificateUntrusted,
    ])
    func availabilityClassifierIgnoresCancellationAndTLSFailures(code: URLError.Code) {
        #expect(APIClientAvailabilityFailure(error: URLError(code)) == nil)
    }

    @Test func availabilityObserverIgnoresHTTPStatusAndDecodingFailures() async throws {
        let recorder = AvailabilityFailureRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "http://localhost:7749")!,
                bearerToken: "sk_test"
            ),
            configuration: configuration,
            availabilityObserver: { failure in
                await recorder.record(failure)
            }
        )
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(status: 503, json: "{\"error\":\"unavailable\"}")
        }
        await #expect(throws: APIError.self) {
            _ = try await client.me()
        }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: "{\"not\":\"a user\"}")
        }
        await #expect(throws: DecodingError.self) {
            _ = try await client.me()
        }

        #expect(await recorder.failures().isEmpty)
    }

    @Test func availabilityObserverReportsNetworkFailureOnce() async throws {
        let recorder = AvailabilityFailureRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "http://localhost:7749")!,
                bearerToken: "sk_test"
            ),
            configuration: configuration,
            availabilityObserver: { failure in
                await recorder.record(failure)
            }
        )
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        await #expect(throws: URLError.self) {
            _ = try await client.me()
        }
        #expect(await recorder.waitForFailures(count: 1) == [.cannotConnectToHost])
    }

    @Test func healthReturnsTrue() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: "{\"status\":\"ok\"}")
        }

        let result = try await client.health()
        #expect(result == true)
    }

    @Test func healthReturnsFalseOnNon200() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(status: 503, json: "{\"error\":\"down\"}")
        }

        let result = try await client.health()
        #expect(result == false)
    }

    @Test func pairResponseRetainsConfirmedCredentialGrant() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let body = try #require(
                JSONSerialization.jsonObject(with: self.requestBodyData(request)) as? [String: Any]
            )
            #expect(body["clientNodeId"] as? String == "stable-apple-node")
            return self.mockResponse(json: #"{"deviceToken":"dt_bound","credentialTransports":["http","iroh"]}"#)
        }

        let response = try await client.pairDevice(
            pairingToken: "pt_dual",
            deviceName: nil,
            clientNodeId: "stable-apple-node"
        )

        #expect(response.credentialGrant == [.http, .iroh])
    }

    // MARK: - me

    @Test func meDecodesUser() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: "{\"user\":\"u1\",\"name\":\"Test User\"}")
        }

        let user = try await client.me()
        #expect(user.user == "u1")
        #expect(user.name == "Test User")
    }

    // MARK: - Sessions

    @Test func searchSessionsUsesQueryItemsAndDecodesResults() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            #expect(components?.path == "/sessions/search")
            #expect(components?.queryItems?.first(where: { $0.name == "q" })?.value == "launch bug")
            #expect(components?.queryItems?.first(where: { $0.name == "workspaceId" })?.value == "ws-1")
            #expect(components?.queryItems?.first(where: { $0.name == "limit" })?.value == "7")
            return self.mockResponse(json: """
            {
              "results": [
                {
                  "sessionId": "sess-1",
                  "workspaceId": "ws-1",
                  "title": "Launch bug",
                  "snippet": "Fixed <b>launch</b> flash",
                  "rank": 0.25,
                  "session": null
                }
              ],
              "query": "launch bug",
              "totalResults": 1
            }
            """)
        }

        let response = try await client.searchSessions(query: "launch bug", workspaceId: "ws-1", limit: 7)

        #expect(response.query == "launch bug")
        #expect(response.totalResults == 1)
        #expect(response.results.map(\.sessionId) == ["sess-1"])
        #expect(response.results.first?.snippet == "Fixed <b>launch</b> flash")
    }

    @Test func listRecentWorkspaceSessionSummariesUsesAggregatedEndpoint() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/sessions/recent")
            #expect(request.url?.query == "recentDays=3")
            return self.mockResponse(json: """
            {"sessions":[
                {"id":"s2","workspaceId":"w2","status":"busy","createdAt":0,"lastActivity":2000,"currentTurnStartedAt":1500,"messageCount":5,"tokens":{"input":100,"output":50},"cost":0.01,"pendingAskCount":1},
                {"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"pendingAskCount":0}
            ]}
            """)
        }

        let summaries = try await client.listRecentWorkspaceSessionSummaries(recentDays: 3)
        #expect(summaries.count == 2)
        #expect(summaries[0].id == "s2")
        #expect(summaries[1].id == "s1")
        #expect(summaries[0].status == .busy)
        #expect(summaries[0].pendingAskCount == 1)
        #expect(summaries[1].pendingAskCount == 0)
    }

    @Test func listSessionsFromWorkspacesUsesAggregatedEndpoint() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/sessions/recent")
            #expect(request.url?.query == "recentDays=3")
            return self.mockResponse(json: """
            {"sessions":[
                {"id":"s2","workspaceId":"w2","status":"busy","createdAt":0,"lastActivity":2000,"currentTurnStartedAt":1500,"messageCount":5,"tokens":{"input":100,"output":50},"cost":0.01},
                {"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}
            ]}
            """)
        }

        let sessions = try await client.listSessionsFromWorkspaces()
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "s2")
        #expect(sessions[1].id == "s1")
        #expect(sessions[0].status == .busy)
        #expect(sessions[0].currentTurnStartedAt == Date(timeIntervalSince1970: 1.5))
    }

    @Test func getWorkspaceSessionListUsesResourceEndpoints() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/workspaces/w1/sessions":
                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
                #expect(query["status"] == "active,stopped")
                #expect(query["sinceMs"] == "1000")
                #expect(query["untilMs"] == "2000")
                return self.mockResponse(json: """
                {
                  "workspaceId":"w1",
                  "sinceMs":1000,
                  "untilMs":2000,
                  "serverNow":3000,
                  "active":[
                    {"id":"active","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":1500,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0}
                  ],
                  "stopped":[
                    {"id":"stopped","workspaceId":"w1","status":"stopped","createdAt":0,"lastActivity":1400,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0},
                    {"id":"/tmp/local.jsonl","source":"tui","status":"stopped","workspaceId":"w1","path":"/tmp/local.jsonl","piSessionId":"pi-1","cwd":"/work","messageCount":3,"createdAt":0,"lastModified":1300,"lastActivity":1300,"tokens":{"input":0,"output":0},"cost":0}
                  ]
                }
                """)

            case "/workspaces/w1/session-buckets":
                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
                #expect(query["status"] == "stopped")
                #expect(query["beforeMs"] == "1000")
                return self.mockResponse(json: """
                {"workspaceId":"w1","status":"stopped","beforeMs":1000,"serverNow":3000,"buckets":[{"bucketId":"day:2026-05-10","bucketKind":"day","startMs":0,"endMs":86400000,"itemCount":1,"managedStoppedCount":1,"importableLocalCount":0}]}
                """)

            case "/workspaces/w1/attention":
                return self.mockResponse(json: """
                {"workspaceId":"w1","serverNow":3000,"attention":{"permissions":[],"asks":[]}}
                """)

            default:
                Issue.record("Unexpected path: \(request.url?.path ?? "nil")")
                return self.mockResponse(status: 404, json: "{\"error\":\"not found\"}")
            }
        }

        let response = try await client.getWorkspaceSessionList(
            workspace: Workspace(id: "w1", name: "Dev", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)),
            since: Date(timeIntervalSince1970: 1),
            until: Date(timeIntervalSince1970: 2)
        )

        #expect(response.workspace.id == "w1")
        #expect(response.serverNow == 3000)
        #expect(response.sessionSummaries.map(\.id) == ["active", "stopped"])
        #expect(response.importableSessions.map(\.path) == ["/tmp/local.jsonl"])
        #expect(response.archiveBuckets.map(\.id) == ["day:2026-05-10"])
    }

    @Test func getWorkspaceSessionListBucketRequestsStoppedSessionCollection() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/sessions")
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
            #expect(query["status"] == "stopped")
            #expect(query["sinceMs"] == "1000")
            #expect(query["untilMs"] == "2000")
            return self.mockResponse(json: """
            {
              "workspaceId":"w1",
              "sinceMs":1000,
              "untilMs":2000,
              "serverNow":3000,
              "stopped":[
                {"id":"s1","workspaceId":"w1","status":"stopped","createdAt":0,"lastActivity":1500,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0},
                {"id":"/tmp/local.jsonl","source":"tui","status":"stopped","workspaceId":"w1","path":"/tmp/local.jsonl","piSessionId":"pi-1","cwd":"/work","messageCount":3,"createdAt":0,"lastModified":1600,"lastActivity":1600,"tokens":{"input":0,"output":0},"cost":0}
              ]
            }
            """)
        }

        let response = try await client.getWorkspaceSessionListBucket(
            workspaceId: "w1",
            since: Date(timeIntervalSince1970: 1),
            until: Date(timeIntervalSince1970: 2)
        )

        #expect(response.sessionSummaries.map(\.id) == ["s1"])
        #expect(response.importableSessions.map(\.path) == ["/tmp/local.jsonl"])
    }

    @Test func sessionScopedAttachmentUploadUsesSessionRoutes() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces/w1/sessions/s1/attachments"):
                let body = try JSONDecoder().decode(UploadCreateRequestBody.self, from: self.requestBodyData(request))
                #expect(body.name == "note.txt")
                #expect(body.mimeType == "text/plain")
                #expect(body.sizeBytes == 5)
                return self.mockResponse(status: 201, json: """
                {"uploadId":"upl_123","attachmentId":"upl_123","contentUrl":"/workspaces/w1/sessions/s1/attachments/upl_123/content","maxFileBytes":1000,"expiresAt":2000}
                """)

            case ("PUT", "/workspaces/w1/sessions/s1/attachments/upl_123/content"):
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
                #expect(self.requestBodyData(request) == Data("hello".utf8))
                return self.mockResponse(json: """
                {"attachment":{"type":"attachment","id":"upl_123","source":"upload","name":"note.txt","mimeType":"text/plain","sizeBytes":5,"sha256":"abc","kind":"text"}}
                """)

            default:
                Issue.record("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return self.mockResponse(status: 404, json: "{\"error\":\"not found\"}")
            }
        }

        let upload = try await client.createSessionAttachmentUpload(
            workspaceId: "w1",
            sessionId: "s1",
            name: "note.txt",
            mimeType: "text/plain",
            sizeBytes: 5
        )
        #expect(upload.uploadId == "upl_123")

        let attachment = try await client.uploadSessionAttachmentContent(
            workspaceId: "w1",
            sessionId: "s1",
            attachmentId: upload.uploadId,
            data: Data("hello".utf8),
            contentType: "text/plain"
        )
        #expect(attachment.id == "upl_123")
        #expect(attachment.source == .upload)
    }

    @Test func createSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/workspaces":
                return self.mockResponse(json: """
                {"workspaces":[{"id":"w1","name":"Dev","skills":[],"createdAt":0,"updatedAt":0}]}
                """)

            case "/workspaces/w1/sessions":
                #expect(request.httpMethod == "POST")
                return self.mockResponse(json: """
                {"session":{"id":"new","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
                """)

            default:
                Issue.record("Unexpected path: \(request.url?.path ?? "nil")")
                return self.mockResponse(status: 404, json: "{\"error\":\"not found\"}")
            }
        }

        let session = try await client.createSession(name: "Test", model: "claude-sonnet-4-20250514")
        #expect(session.id == "new")
        #expect(session.status == .ready)
        #expect(session.workspaceId == "w1")
    }

    @Test func createWorkspaceSessionIncognitoEncodesEphemeral() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/w1/sessions")

            let body = self.requestBodyData(request)
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                #expect(json["ephemeral"] as? Bool == true)
            } else {
                Issue.record("Expected JSON body")
            }

            return self.mockResponse(json: """
            {"session":{"id":"new","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"ephemeral":true}}
            """)
        }

        let response = try await client.createWorkspaceSession(workspaceId: "w1", ephemeral: true)
        #expect(response.session.id == "new")
        #expect(response.session.ephemeral == true)
    }

    @Test func forkWorkspaceSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/w1/sessions/s1/fork")

            let body = self.requestBodyData(request)
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                #expect(json["entryId"] as? String == "entry-123")
                #expect(json["name"] as? String == "Fork: feature branch")
            } else {
                Issue.record("Expected JSON body")
            }

            return self.mockResponse(json: """
            {"session":{"id":"forked-1","workspaceId":"w1","name":"Fork: feature branch","status":"ready","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
            """)
        }

        let session = try await client.forkWorkspaceSession(
            workspaceId: "w1",
            sessionId: "s1",
            entryId: "entry-123",
            name: "Fork: feature branch"
        )

        #expect(session.id == "forked-1")
        #expect(session.workspaceId == "w1")
        #expect(session.name == "Fork: feature branch")
    }

    @Test func getSessionWithTrace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/sessions/s1")
            #expect(request.url?.query == "view=context")
            return self.mockResponse(json: """
            {
                "session":{"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
                "trace":[
                    {"id":"e1","type":"user","timestamp":"2025-01-01T00:00:00Z","text":"Hello"}
                ]
            }
            """)
        }

        let (session, trace) = try await client.getWorkspaceSession(workspaceId: "w1", sessionId: "s1")
        #expect(session.id == "s1")
        #expect(trace.count == 1)
        #expect(trace[0].type == .user)
    }

    @Test func getSessionWithFullTraceViewUsesQuery() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/sessions/s1")
            #expect(request.url?.query == "view=full")
            return self.mockResponse(json: """
            {
                "session":{"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
                "trace":[
                    {"id":"e1","type":"user","timestamp":"2025-01-01T00:00:00Z","text":"Hello"}
                ]
            }
            """)
        }

        let (_, trace) = try await client.getWorkspaceSession(workspaceId: "w1", sessionId: "s1", traceView: .full)
        #expect(trace.count == 1)
    }

    @Test func getSessionTracePageDecodesPageMetadataAndPreviewFields() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/sessions/s1/trace-page")
            #expect(request.url?.query == "presentation=mobile&cursor=older-1&previewBytes=4096")
            return self.mockResponse(json: """
            {
                "session":{"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
                "trace":[
                    {"id":"tc1","type":"toolCall","timestamp":"2025-01-01T00:00:00Z","tool":"bash","args":{"command":"echo hi"}},
                    {"id":"result-r1","type":"toolResult","timestamp":"2025-01-01T00:00:01Z","toolCallId":"tc1","toolName":"bash","output":"preview","outputTruncated":true,"outputPreviewBytes":4096,"outputTotalBytes":9000}
                ],
                "page":{"hasOlder":true,"olderCursor":"older-2","traceVersion":"123:456","previewBytes":4096,"staleCursor":false},
                "metrics":{"rawEntryCount":10,"traceEventCount":2,"selectedRawEntryCount":2,"jsonlBytes":123,"scannedBytes":123,"readMs":1,"parseMs":2,"selectMs":3,"formatMs":4,"previewMs":5,"jsonBytes":456,"gzipBytes":78,"stringifyMs":1,"gzipMs":2}
            }
            """)
        }

        let response = try await client.getWorkspaceSessionTracePage(
            workspaceId: "w1",
            sessionId: "s1",
            cursor: "older-1",
            previewBytes: 4096
        )

        #expect(response.session.id == "s1")
        #expect(response.trace.map(\.id) == ["tc1", "result-r1"])
        #expect(response.trace[1].outputTruncated == true)
        #expect(response.trace[1].outputPreviewBytes == 4096)
        #expect(response.trace[1].outputTotalBytes == 9000)
        #expect(response.page.hasOlder)
        #expect(response.page.olderCursor == "older-2")
        #expect(response.metrics.traceEventCount == 2)
        #expect(response.metrics.scannedBytes == 123)
    }

    @Test func getSessionTracePageCanRequestAroundEntryPage() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/sessions/s1/trace-page")
            #expect(request.url?.query == "presentation=mobile&aroundEntryId=a1-text-0&previewBytes=4096")
            return self.mockResponse(json: """
            {
                "session":{"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
                "trace":[
                    {"id":"a1-text-0","type":"assistant","timestamp":"2025-01-01T00:00:00Z","text":"Found it"}
                ],
                "page":{"hasOlder":true,"olderCursor":"older-1","traceVersion":"123:456","previewBytes":4096,"staleCursor":false},
                "metrics":{"rawEntryCount":3,"traceEventCount":1,"selectedRawEntryCount":1,"jsonlBytes":123,"scannedBytes":123,"readMs":1,"parseMs":2,"selectMs":3,"formatMs":4,"previewMs":5,"jsonBytes":456,"gzipBytes":78,"stringifyMs":1,"gzipMs":2}
            }
            """)
        }

        let response = try await client.getWorkspaceSessionTracePage(
            workspaceId: "w1",
            sessionId: "s1",
            aroundEntryId: "a1-text-0",
            previewBytes: 4096
        )

        #expect(response.trace.map(\.id) == ["a1-text-0"])
        #expect(response.page.olderCursor == "older-1")
    }

    @Test func getSessionEventsDecodesSequencedCatchUp() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/workspaces/w1/sessions/s1/events") == true)
            #expect(request.url?.query == "since=5")
            return self.mockResponse(json: """
            {
              "events": [
                {"type":"agent_start","seq":6},
                {"type":"message_end","role":"assistant","content":"Recovered","seq":7},
                {"type":"agent_end","seq":8}
              ],
              "currentSeq": 8,
              "session": {"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
              "catchUpComplete": true
            }
            """)
        }

        let response = try await client.getSessionEvents(workspaceId: "w1", id: "s1", since: 5)
        #expect(response.currentSeq == 8)
        #expect(response.catchUpComplete)
        #expect(response.events.count == 3)
        #expect(response.events.map(\.seq) == [6, 7, 8])

        guard case .messageEnd(_, let content) = response.events[1].message else {
            Issue.record("Expected message_end in second event")
            return
        }
        #expect(content == "Recovered")
    }

    @Test func stopSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/sessions/s1/stop")
            return self.mockResponse(json: """
            {"session":{"id":"s1","workspaceId":"w1","status":"stopped","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
            """)
        }

        let session = try await client.stopWorkspaceSession(workspaceId: "w1", sessionId: "s1")
        #expect(session.status == .stopped)
    }

    @Test func deleteSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/workspaces/w1/sessions/s1")
            return self.mockResponse(json: "{}")
        }

        try await client.deleteWorkspaceSession(workspaceId: "w1", sessionId: "s1")
    }

    // getSessionTrace removed — merged into getSession.

    // MARK: - Models

    @Test func listModels() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"models":[{"id":"claude-sonnet-4-20250514","name":"Claude Sonnet 4","provider":"anthropic","contextWindow":200000}]}
            """)
        }

        let models = try await client.listModels()
        #expect(models.count == 1)
        #expect(models[0].id == "claude-sonnet-4-20250514")
    }

    // MARK: - Workspaces

    @Test func listWorkspaces() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {
              "serverNow": 1700000000000,
              "workspaces":[{"id":"w1","name":"Dev","skills":[],"createdAt":0,"updatedAt":0}],
              "summaries":[{"workspaceId":"w1","activeCount":1,"stoppedCount":2,"hasAttention":true,"hasErrorRoot":false,"latestActivity":1500}]
            }
            """)
        }

        let workspaces = try await client.listWorkspaces()
        #expect(workspaces.count == 1)
        #expect(workspaces[0].name == "Dev")
    }

    @Test func listWorkspaceCatalogDecodesSummaries() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces")
            return self.mockResponse(json: """
            {
              "serverNow": 1700000000000,
              "workspaces":[{"id":"w1","name":"Dev","skills":[],"createdAt":0,"updatedAt":0}],
              "summaries":[{"workspaceId":"w1","activeCount":1,"stoppedCount":2,"hasAttention":true,"hasErrorRoot":false,"latestActivity":1500}]
            }
            """)
        }

        let catalog = try await client.listWorkspaceCatalog()
        #expect(catalog.serverNow == 1700000000000)
        #expect(catalog.workspaces.map(\.id) == ["w1"])
        #expect(catalog.summaries?.count == 1)
        #expect(catalog.summaries?.first?.workspaceId == "w1")
        #expect(catalog.summaries?.first?.activeCount == 1)
        #expect(catalog.summaries?.first?.latestActivity == Date(timeIntervalSince1970: 1.5))
    }

    @Test func getWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"workspace":{"id":"w1","name":"Dev","skills":["fetch"],"createdAt":0,"updatedAt":0}}
            """)
        }

        let ws = try await client.getWorkspace(id: "w1")
        #expect(ws.id == "w1")
    }

    @Test func createWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            return self.mockResponse(json: """
            {"workspace":{"id":"w2","name":"New","skills":["searxng"],"createdAt":0,"updatedAt":0}}
            """)
        }

        let ws = try await client.createWorkspace(CreateWorkspaceRequest(name: "New"))
        #expect(ws.id == "w2")
    }

    @Test func updateWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "PUT")

            let body = self.requestBodyData(request)
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                #expect(json["name"] as? String == "Updated")
            } else {
                Issue.record("Expected JSON body")
            }

            return self.mockResponse(json: """
            {"workspace":{"id":"w1","name":"Updated","skills":[],"createdAt":0,"updatedAt":0}}
            """)
        }

        let ws = try await client.updateWorkspace(id: "w1", UpdateWorkspaceRequest(name: "Updated"))
        #expect(ws.name == "Updated")
    }

    @Test func updateWorkspaceEncodesNullForClearedPrompt() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/workspaces/w1")

            let body = self.requestBodyData(request)
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                Issue.record("Expected JSON body")
                return self.mockResponse(status: 400, json: "{\"error\":\"bad request\"}")
            }

            #expect(json["systemPrompt"] is NSNull)
            #expect(json["systemPromptMode"] as? String == "append")

            return self.mockResponse(json: """
            {"workspace":{"id":"w1","name":"Updated","skills":[],"createdAt":0,"updatedAt":0}}
            """)
        }

        _ = try await client.updateWorkspace(
            id: "w1",
            UpdateWorkspaceRequest(systemPrompt: .null, systemPromptMode: .append)
        )
    }

    @Test func deleteWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            return self.mockResponse(json: "{}")
        }

        try await client.deleteWorkspace(id: "w1")
    }

    // MARK: - Skills

    @Test func listSkills() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"skills":[{"name":"fetch","description":"Fetch URLs","path":"/path"}]}
            """)
        }

        let skills = try await client.listSkills()
        #expect(skills.count == 1)
        #expect(skills[0].name == "fetch")
    }

    @Test func listSkillsForWorkspaceAddsWorkspaceScope() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let workspaceId = components?.queryItems?.first(where: { $0.name == "workspaceId" })?.value
            #expect(workspaceId == "sandbox-workspace")
            #expect(components?.queryItems?.contains(where: { $0.name == "cwd" }) == false)
            return self.mockResponse(json: """
            {"skills":[]}
            """)
        }

        let skills = try await client.listSkills(workspaceId: "sandbox-workspace")
        #expect(skills.isEmpty)
    }

    @Test func setPiResourceEnabledUsesWorkspaceScope() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let body = self.requestBodyData(request)
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["workspaceId"] as? String == "sandbox-workspace")
            #expect(json?["cwd"] == nil)
            return self.mockResponse(json: "{\"ok\":true}")
        }

        try await client.setPiResourceEnabled(
            type: "skills",
            path: "/path/to/skill",
            workspaceId: "sandbox-workspace",
            enabled: false
        )
    }

    @Test func rescanSkills() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"skills":[]}
            """)
        }

        let skills = try await client.rescanSkills()
        #expect(skills.isEmpty)
    }

    @Test func listExtensions() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/extensions")
            return self.mockResponse(json: """
            {"extensions":[{"name":"memory","path":"/Users/me/.pi/agent/extensions/memory.ts","kind":"file","source":"pi"}]}
            """)
        }

        let extensions = try await client.listExtensions()
        #expect(extensions.count == 1)
        #expect(extensions[0].name == "memory")
        #expect(extensions[0].kind == "file")
        #expect(extensions[0].source == "pi")
    }

    @Test func listExtensionsWithCwdAddsQueryParam() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/extensions")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let cwd = components?.queryItems?.first(where: { $0.name == "cwd" })?.value
            #expect(cwd == "~/workspace/oppi")
            return self.mockResponse(json: """
            {"extensions":[]}
            """)
        }

        let extensions = try await client.listExtensions(cwd: "~/workspace/oppi")
        #expect(extensions.isEmpty)
    }

    @Test func getHostPathStatusUsesQueryString() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/host/path/status")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let path = components?.queryItems?.first(where: { $0.name == "path" })?.value
            #expect(path == "~/workspace/new project")
            return self.mockResponse(json: """
            {"status":{"path":"~/workspace/new project","resolvedPath":"/Users/me/workspace/new project","exists":false,"isDirectory":false,"isFile":false,"issue":"missing","message":"Path does not exist"}}
            """)
        }

        let status = try await client.getHostPathStatus(path: "~/workspace/new project")
        #expect(status.issue == "missing")
        #expect(status.userMessage == "Path doesn’t exist")
    }

    @Test func completeHostPathUsesPrefixQuery() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/host/path/completions")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            #expect(components?.queryItems?.first(where: { $0.name == "prefix" })?.value == "~/workspace/op")
            #expect(components?.queryItems?.first(where: { $0.name == "limit" })?.value == "8")
            return self.mockResponse(json: """
            {"completions":[{"path":"~/workspace/oppi","name":"oppi"}]}
            """)
        }

        let completions = try await client.completeHostPath(prefix: "~/workspace/op", limit: 8)
        #expect(completions.map(\.path) == ["~/workspace/oppi"])
    }

    @Test func createHostPathPostsConfirmedBody() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/host/path/create")
            let body = try! JSONSerialization.jsonObject(with: self.requestBodyData(request)) as? [String: Any]
            #expect(body?["path"] as? String == "~/workspace/new-project")
            #expect(body?["confirmed"] as? Bool == true)
            return self.mockResponse(json: """
            {"created":true,"status":{"path":"~/workspace/new-project","resolvedPath":"/Users/me/workspace/new-project","exists":true,"isDirectory":true,"isFile":false}}
            """)
        }

        let result = try await client.createHostPath(path: "~/workspace/new-project")
        #expect(result.created)
        #expect(result.status.isValidWorkspaceDirectory)
    }

    // MARK: - Files + Query Paths

    @Test func gitStatusUsesResourceRoute() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/workspaces/w1/git/status")
            return self.mockResponse(json: """
            {"isGitRepo":true,"branch":"main","headSha":"abc123","ahead":0,"behind":0,"dirtyCount":0,"untrackedCount":0,"stagedCount":0,"files":[],"totalFiles":0,"addedLines":0,"removedLines":0,"stashCount":0,"lastCommitMessage":null,"lastCommitDate":null,"recentCommits":[]}
            """)
        }

        let status = try await client.getGitStatus(workspaceId: "w1")
        #expect(status.branch == "main")
    }

    @Test func getSkillFileUsesQueryString() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let pathQuery = components?.queryItems?.first(where: { $0.name == "path" })?.value

            #expect(request.url?.path == "/skills/fetch/file")
            #expect(pathQuery == "nested dir/SKILL.md")
            #expect(request.url?.absoluteString.contains("%3Fpath=") == false)
            return self.mockResponse(json: "{\"content\":\"ok\"}")
        }

        let content = try await client.getSkillFile(name: "fetch", path: "nested dir/SKILL.md")
        #expect(content == "ok")
    }

    @Test func getSessionFileUsesWorkspaceRelativeSessionRawRoute() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)

            #expect(
                components?.percentEncodedPath ==
                    "/workspaces/w1/sessions/s1/raw/Sources%2Fmain.swift"
            )
            #expect(components?.percentEncodedQuery == nil)

            let body = "print(\"hello\")".data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (body, response)
        }

        let content = try await client.getSessionFile(workspaceId: "w1", sessionId: "s1", path: "Sources/main.swift")
        #expect(content == "print(\"hello\")")
    }

    @Test func sessionRawFileSendsAbsoluteReportedPath() async throws {
        let client = makeClient()
        defer { cleanup() }
        MockURLProtocol.handler = { request in
            #expect(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ==
                    "/workspaces/w1/sessions/s1/raw/%2Ftmp%2Fmain.swift"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (Data("preview".utf8), response)
        }

        let data = try await client.getSessionFileData(
            workspaceId: "w1",
            sessionId: "s1",
            path: "/tmp/main.swift"
        )
        #expect(String(data: data, encoding: .utf8) == "preview")
    }

    @Test func sessionRawFilePreservesExactReportedPathWhitespace() async throws {
        let client = makeClient()
        defer { cleanup() }
        MockURLProtocol.handler = { request in
            #expect(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ==
                    "/workspaces/w1/sessions/s1/raw/%20%2Ftmp%2Fmovie.mp4%20"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (Data(), response)
        }

        _ = try await client.getSessionFileData(
            workspaceId: "w1",
            sessionId: "s1",
            path: " /tmp/movie.mp4 "
        )
    }

    @Test func fileEndpointsPercentEncodePathSegmentsAndUseStructuredQueries() async throws {
        let client = makeClient()
        defer { cleanup() }

        let workspacePath = "folder one/plus+?hash#percent%&/日本語 image.png"
        let directoryPath = "folder one/日本語 #?/"
        let expectedRawPath = "/workspaces/w1/raw/folder%20one%2Fplus%2B%3Fhash%23percent%25%26%2F%E6%97%A5%E6%9C%AC%E8%AA%9E%20image.png"
        let expectedDirectoryPath = "/workspaces/w1/contents/folder%20one/%E6%97%A5%E6%9C%AC%E8%AA%9E%20%23%3F/"
        var step = 0

        MockURLProtocol.handler = { request in
            step += 1
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            switch step {
            case 1:
                #expect(components?.percentEncodedPath == expectedRawPath)
                #expect(components?.queryItems?.isEmpty ?? true)
            case 2:
                #expect(components?.percentEncodedPath == expectedRawPath)
                #expect(components?.queryItems?.isEmpty ?? true)
            case 3:
                #expect(components?.percentEncodedPath == expectedDirectoryPath)
                #expect(components?.queryItems?.isEmpty ?? true)
            default:
                Issue.record("Unexpected request count: \(step)")
            }
            return self.mockResponse(json: "{\"path\":\"/\",\"entries\":[],\"truncated\":false}")
        }

        _ = try await client.fetchWorkspaceFile(workspaceID: "w1", path: workspacePath)
        _ = try await client.browseWorkspaceFile(workspaceId: "w1", path: workspacePath)
        _ = try await client.listWorkspaceDirectory(workspaceId: "w1", path: directoryPath)
        #expect(step == 3)
    }

    @Test func workspaceFileEndpointsAppendWorktreeQueryWhenProvided() async throws {
        let client = makeClient()
        defer { cleanup() }
        var step = 0

        MockURLProtocol.handler = { request in
            step += 1
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            switch step {
            case 1:
                #expect(components?.percentEncodedPath == "/workspaces/w1/contents/src/")
            case 2:
                #expect(components?.percentEncodedPath == "/workspaces/w1/raw/src%2Fmain.swift")
            case 3:
                #expect(components?.percentEncodedPath == "/workspaces/w1/paths")
            default:
                Issue.record("Unexpected request count: \(step)")
            }
            #expect(components?.queryItems?.first(where: { $0.name == "worktreeId" })?.value == "wt_feature")
            if step == 3 {
                return self.mockResponse(json: "{\"paths\":[],\"truncated\":false}")
            }
            return self.mockResponse(json: "{\"path\":\"/\",\"entries\":[],\"truncated\":false}")
        }

        _ = try await client.listWorkspaceDirectory(workspaceId: "w1", path: "src/", worktreeId: "wt_feature")
        _ = try await client.browseWorkspaceFile(workspaceId: "w1", path: "src/main.swift", worktreeId: "wt_feature")
        _ = try await client.fetchFileIndex(workspaceId: "w1", worktreeId: "wt_feature")
        #expect(step == 3)
    }

    @Test func workspaceMediaSourceUsesEncodedPathSegmentsAndBearerAuth() async throws {
        let client = makeClient()
        let source = try await client.makeWorkspaceMediaSource(
            workspaceId: "w1",
            path: "clips/space +?#%&/日本語 sample.mov",
            contentTypeHint: "video/quicktime",
            sourceFileExtension: "mov"
        )

        let components = URLComponents(url: source.url, resolvingAgainstBaseURL: false)
        #expect(
            components?.percentEncodedPath ==
                "/workspaces/w1/raw/clips%2Fspace%20%2B%3F%23%25%26%2F%E6%97%A5%E6%9C%AC%E8%AA%9E%20sample.mov"
        )
        #expect(components?.queryItems?.isEmpty ?? true)
        #expect(source.url.absoluteString.contains("sk_test") == false)
        #expect(source.identity.contains("sk_test") == false)
        #expect(source.authorizationHeaderValue == "Bearer sk_test")
        #expect(source.contentTypeHint == "video/quicktime")
        #expect(source.sourceFileExtension == "mov")
    }

    @Test func sessionFileMediaSourceUsesSessionRawRouteForExternalPath() async throws {
        let client = makeClient()
        let source = try await client.makeSessionFileMediaSource(
            workspaceId: "w1",
            sessionId: "s1",
            path: "/tmp/movie clip.mp4",
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4"
        )

        let components = URLComponents(url: source.url, resolvingAgainstBaseURL: false)
        #expect(
            components?.percentEncodedPath ==
                "/workspaces/w1/sessions/s1/raw/%2Ftmp%2Fmovie%20clip.mp4"
        )
        #expect(source.authorizationHeaderValue == "Bearer sk_test")
        #expect(source.contentTypeHint == "video/mp4")
        #expect(source.sourceFileExtension == "mp4")
    }

    @Test func sessionAttachmentMediaSourceUsesEncodedPathSegmentsAndBearerAuth() async throws {
        let client = makeClient()
        let source = try await client.makeSessionAttachmentMediaSource(
            sessionId: "s1",
            attachmentId: "att_space +?#%& 日本語",
            contentTypeHint: "audio/wav",
            sourceFileExtension: "wav"
        )

        let components = URLComponents(url: source.url, resolvingAgainstBaseURL: false)
        #expect(
            components?.percentEncodedPath ==
                "/sessions/s1/attachments/att_space%20%2B%3F%23%25%26%20%E6%97%A5%E6%9C%AC%E8%AA%9E"
        )
        #expect(components?.queryItems?.isEmpty ?? true)
        #expect(source.url.absoluteString.contains("sk_test") == false)
        #expect(source.identity.contains("sk_test") == false)
        #expect(source.authorizationHeaderValue == "Bearer sk_test")
        #expect(source.contentTypeHint == "audio/wav")
        #expect(source.sourceFileExtension == "wav")
    }

    @Test func fetchSessionAttachmentBypassesCacheAndRejectsShortBody() async throws {
        let client = makeClient()
        defer { cleanup() }

        var sawRequest = false
        MockURLProtocol.handler = { request in
            sawRequest = true
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            #expect(request.url?.path == "/sessions/s1/attachments/att-image")

            let data = Data([0xFF, 0xD8, 0xFF])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "4", "Content-Type": "image/jpeg"]
            )!
            return (data, response)
        }

        do {
            _ = try await client.fetchSessionAttachment(
                sessionId: "s1",
                attachmentId: "att-image"
            )
            Issue.record("Expected short attachment body to throw")
        } catch APIError.server(let status, let message) {
            #expect(status == 200)
            #expect(message.contains("incomplete"))
        }

        #expect(sawRequest)
    }

    @Test func authenticatedMediaResponseValidatorAcceptsMatchingPartialContent() {
        let range = AuthenticatedMediaRequestedRange(start: 1_024, end: 2_047)
        let error = AuthenticatedMediaResponseValidator.errorMessage(
            statusCode: 206,
            requestedRange: range,
            contentRange: "bytes 1024-2047/4096"
        )
        #expect(error == nil)
    }

    @Test func authenticatedMediaResponseValidatorAcceptsClampedFinalPartialContent() {
        let range = AuthenticatedMediaRequestedRange(start: 4_096, end: 5_119)
        let error = AuthenticatedMediaResponseValidator.errorMessage(
            statusCode: 206,
            requestedRange: range,
            contentRange: "bytes 4096-4999/5000"
        )
        #expect(error == nil)
    }

    @Test func authenticatedMediaResponseValidatorRejectsRangeRequestWithFullResponse() {
        let range = AuthenticatedMediaRequestedRange(start: 1_024, end: 2_047)
        let error = AuthenticatedMediaResponseValidator.errorMessage(
            statusCode: 200,
            requestedRange: range,
            contentRange: nil
        )
        #expect(error != nil)
    }

    @Test func authenticatedMediaResponseValidatorRejectsMismatchedContentRange() {
        let range = AuthenticatedMediaRequestedRange(start: 1_024, end: 2_047)
        let error = AuthenticatedMediaResponseValidator.errorMessage(
            statusCode: 206,
            requestedRange: range,
            contentRange: "bytes 0-1023/4096"
        )
        #expect(error != nil)
    }

    @Test func authenticatedMediaResponseValidatorRejectsMissingContentRange() {
        let range = AuthenticatedMediaRequestedRange(start: 1_024, end: 2_047)
        let error = AuthenticatedMediaResponseValidator.errorMessage(
            statusCode: 206,
            requestedRange: range,
            contentRange: nil
        )
        #expect(error != nil)
    }

    @Test func authenticatedMediaResponseValidatorRejectsMalformedContentRange() {
        let range = AuthenticatedMediaRequestedRange(start: 1_024, end: 2_047)
        let error = AuthenticatedMediaResponseValidator.errorMessage(
            statusCode: 206,
            requestedRange: range,
            contentRange: "bytes 1024-2047/not-a-size"
        )
        #expect(error != nil)
    }

    @Test func sessionAndSkillFileURLsUseQueryItemsForSpecialCharacters() async throws {
        let client = makeClient()
        defer { cleanup() }

        let specialPath = "Sources/space +?#%&=/日本語.swift"
        let specialSkillPath = "nested dir/+?#%&=/日本語.md"
        var step = 0

        MockURLProtocol.handler = { request in
            step += 1
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let pathQuery = components?.queryItems?.first(where: { $0.name == "path" })?.value
            if step == 1 {
                #expect(
                    components?.percentEncodedPath ==
                        "/workspaces/w1/sessions/s1/raw/Sources%2Fspace%20%2B%3F%23%25%26=%2F%E6%97%A5%E6%9C%AC%E8%AA%9E.swift"
                )
                #expect(components?.percentEncodedQuery == nil)
            } else if step == 2 {
                let encodedQuery = components?.percentEncodedQuery ?? ""
                #expect(encodedQuery.contains("%2B"))
                #expect(encodedQuery.contains("%26"))
                #expect(encodedQuery.contains("%3D"))
                #expect(encodedQuery.contains("+") == false)
                #expect(components?.percentEncodedPath == "/skills/fetch/file")
                #expect(pathQuery == specialSkillPath)
            } else {
                Issue.record("Unexpected request count: \(step)")
            }
            return self.mockResponse(json: step == 1 ? "{}" : "{\"content\":\"ok\"}")
        }

        _ = try await client.browseSessionTouchedFile(workspaceId: "w1", sessionId: "s1", path: specialPath)
        let content = try await client.getSkillFile(name: "fetch", path: specialSkillPath)
        #expect(content == "ok")
        #expect(step == 2)
    }

    @Test func sessionChangesAndDiffUseResourceShapedRoutes() async throws {
        let client = makeClient()
        defer { cleanup() }

        var step = 0
        MockURLProtocol.handler = { request in
            step += 1
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            if step == 1 {
                #expect(request.httpMethod == "GET")
                #expect(components?.percentEncodedPath == "/workspaces/w1/sessions/s1/changes")
                return self.mockResponse(json: """
                {"workspaceId":"w1","sessionId":"s1","files":[{"path":"Sources/App.swift"}],"changedFileCount":1,"changedFilesOverflow":0}
                """)
            }

            #expect(request.httpMethod == "GET")
            #expect(components?.percentEncodedPath == "/workspaces/w1/sessions/s1/diff")
            #expect(components?.queryItems?.first(where: { $0.name == "path" })?.value == "Sources/App.swift")
            return self.mockResponse(json: """
            {"workspaceId":"w1","path":"Sources/App.swift","baselineText":"old","currentText":"new","addedLines":1,"removedLines":1,"hunks":[]}
            """)
        }

        let changes = try await client.listSessionChanges(workspaceId: "w1", sessionId: "s1")
        #expect(changes.files.map(\.path) == ["Sources/App.swift"])

        let diff = try await client.getSessionDiff(workspaceId: "w1", sessionId: "s1", path: "Sources/App.swift")
        #expect(diff.path == "Sources/App.swift")
        #expect(step == 2)
    }

    // MARK: - Device Token

    @Test func registerDeviceToken() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path.hasSuffix("/me/device-token") == true)
            return self.mockResponse(json: "{}")
        }

        try await client.registerDeviceToken("abc123")
    }

    // MARK: - Diagnostics

    @Test func uploadChatMetricsUsesSharedPostPathWithSortedTags() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/telemetry/chat-metrics")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = self.requestBodyData(request)
            let bodyText = String(data: body, encoding: .utf8) ?? ""
            #expect(bodyText.contains(#""tags":{"a":"first","z":"last"}"#))

            return self.mockResponse(json: "{\"ok\":true,\"accepted\":1,\"windowStartMs\":1,\"windowEndMs\":1}")
        }

        try await client.uploadChatMetrics(
            request: ChatMetricUploadRequest(
                generatedAt: 1,
                appVersion: "1.0",
                buildNumber: "1",
                osVersion: "test-os",
                deviceModel: "test-device",
                samples: [
                    ChatMetricSample(
                        ts: 1,
                        metric: .timelineApplyMs,
                        value: 3,
                        unit: .ms,
                        sessionId: "s1",
                        workspaceId: "w1",
                        tags: ["z": "last", "a": "first"]
                    ),
                ]
            )
        )
    }

    @Test func clientLogRedactorRemovesSensitiveKeysAndValues() {
        let metadata = ClientLogRedactor.redactedMetadata([
            "accessToken": "plain-token-that-does-not-match-value-regex",
            "apiKey": "unpatterned-api-key",
            "authPresent": "true",
            "tokenCount": "42",
            "url": "https://example.test/path?token=secret-token",
        ])

        #expect(metadata["accessToken"] == ClientLogRedactor.redacted)
        #expect(metadata["apiKey"] == ClientLogRedactor.redacted)
        #expect(metadata["authPresent"] == "true")
        #expect(metadata["tokenCount"] == "42")
        #expect(metadata["url"] == "https://example.test/path?token=[REDACTED]")
        #expect(ClientLogRedactor.redactedText("Authorization: Bearer abcdefghi") == "Authorization: Bearer [REDACTED]")
    }

    @Test func uploadClientLogsUsesTelemetryPostPathWithSortedMetadata() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/telemetry/client-logs")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = self.requestBodyData(request)
            let bodyText = String(data: body, encoding: .utf8) ?? ""
            #expect(bodyText.contains(#""metadata":{"a":"first","z":"last"}"#))

            return self.mockResponse(json: "{\"ok\":true,\"accepted\":1,\"windowStartMs\":1,\"windowEndMs\":1}")
        }

        try await client.uploadClientLogs(
            request: ClientLogUploadRequest(
                generatedAt: 1,
                appVersion: "1.0",
                buildNumber: "1",
                osVersion: "test-os",
                deviceModel: "test-device",
                clientKind: .ios,
                appInstanceId: "app-1",
                bootId: "boot-1",
                droppedCount: nil,
                entries: [
                    ClientLogUploadEntry(
                        ts: 1,
                        seq: 1,
                        level: .warn,
                        category: "Network",
                        message: "Stream reconnect",
                        metadata: ["z": "last", "a": "first"],
                        sessionId: "s1",
                        workspaceId: "w1"
                    ),
                ]
            )
        )
    }

    // MARK: - Error handling

    @Test func serverErrorExtractsMessage() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(status: 401, json: "{\"error\":\"Invalid token\"}")
        }

        do {
            _ = try await client.me()
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .server(let status, let msg) = error else {
                Issue.record("Expected server error")
                return
            }
            #expect(status == 401)
            #expect(msg == "Invalid token")
        }
    }

    @Test func serverErrorRetainsMachineReadableTunnelCode() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(
                status: 403,
                json: #"{"error":"forbidden","code":"binding_missing"}"#
            )
        }

        do {
            _ = try await client.me()
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .codedServer(let status, let message, let code) = error else {
                Issue.record("Expected coded server error")
                return
            }
            #expect(status == 403)
            #expect(message == "forbidden")
            #expect(code == .bindingMissing)
        }
    }

    @Test func serverErrorFallsBackToBody() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(status: 500, json: "raw error text")
        }

        do {
            _ = try await client.me()
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .server(let status, let msg) = error else {
                Issue.record("Expected server error")
                return
            }
            #expect(status == 500)
            #expect(msg == "raw error text")
        }
    }

    @Test func authorizationHeaderSet() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            #expect(auth == "Bearer sk_test")
            return self.mockResponse(json: "{\"user\":\"u1\",\"name\":\"Test\"}")
        }

        _ = try await client.me()
    }

    // MARK: - APIError descriptions

    @Test func apiErrorDescriptions() {
        let invalid = APIError.invalidResponse
        #expect(invalid.errorDescription?.contains("Invalid") == true)

        let server = APIError.server(status: 500, message: "Internal error")
        #expect(server.errorDescription == "Internal error")
    }
}
