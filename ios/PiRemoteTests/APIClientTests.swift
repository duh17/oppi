import Testing
import Foundation
@testable import PiRemote

// MARK: - Mock URL Protocol

/// Intercepts URLSession requests and returns preset responses.
/// Configured per-test via `MockURLProtocol.handler`.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("APIClient", .serialized)
struct APIClientTests {

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
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

    // MARK: - Health

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

    // MARK: - me

    @Test func meDecodesUser() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: "{\"user\":\"u1\",\"name\":\"Chen\"}")
        }

        let user = try await client.me()
        #expect(user.user == "u1")
        #expect(user.name == "Chen")
    }

    // MARK: - Sessions

    @Test func listSessions() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"sessions":[
                {"id":"s1","userId":"u1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0},
                {"id":"s2","userId":"u1","status":"busy","createdAt":0,"lastActivity":0,"messageCount":5,"tokens":{"input":100,"output":50},"cost":0.01}
            ]}
            """)
        }

        let sessions = try await client.listSessions()
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "s1")
        #expect(sessions[1].status == .busy)
    }

    @Test func createSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path.hasSuffix("/sessions") == true)

            return self.mockResponse(json: """
            {"session":{"id":"new","userId":"u1","status":"starting","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
            """)
        }

        let session = try await client.createSession(name: "Test", model: "claude-sonnet-4-20250514")
        #expect(session.id == "new")
        #expect(session.status == .starting)
    }

    @Test func getSessionWithTrace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {
                "session":{"id":"s1","userId":"u1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
                "trace":[
                    {"id":"e1","type":"user","timestamp":"2025-01-01T00:00:00Z","text":"Hello"}
                ]
            }
            """)
        }

        let (session, trace) = try await client.getSession(id: "s1")
        #expect(session.id == "s1")
        #expect(trace.count == 1)
        #expect(trace[0].type == .user)
    }

    @Test func getSessionEventsDecodesSequencedCatchUp() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/sessions/s1/events") == true)
            #expect(request.url?.query == "since=5")
            return self.mockResponse(json: """
            {
              "events": [
                {"type":"agent_start","seq":6},
                {"type":"message_end","role":"assistant","content":"Recovered","seq":7},
                {"type":"agent_end","seq":8}
              ],
              "currentSeq": 8,
              "session": {"id":"s1","userId":"u1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
              "catchUpComplete": true
            }
            """)
        }

        let response = try await client.getSessionEvents(id: "s1", since: 5)
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

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"session":{"id":"s1","userId":"u1","status":"stopped","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
            """)
        }

        let session = try await client.stopSession(id: "s1")
        #expect(session.status == .stopped)
    }

    @Test func deleteSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            return self.mockResponse(json: "{}")
        }

        try await client.deleteSession(id: "s1")
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
            {"workspaces":[{"id":"w1","userId":"u1","name":"Dev","skills":[],"createdAt":0,"updatedAt":0}]}
            """)
        }

        let workspaces = try await client.listWorkspaces()
        #expect(workspaces.count == 1)
        #expect(workspaces[0].name == "Dev")
    }

    @Test func getWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"workspace":{"id":"w1","userId":"u1","name":"Dev","skills":["fetch"],"createdAt":0,"updatedAt":0}}
            """)
        }

        let ws = try await client.getWorkspace(id: "w1")
        #expect(ws.skills == ["fetch"])
    }

    @Test func createWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            return self.mockResponse(json: """
            {"workspace":{"id":"w2","userId":"u1","name":"New","skills":["searxng"],"createdAt":0,"updatedAt":0}}
            """)
        }

        let ws = try await client.createWorkspace(CreateWorkspaceRequest(name: "New", skills: ["searxng"]))
        #expect(ws.id == "w2")
    }

    @Test func updateWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "PUT")
            return self.mockResponse(json: """
            {"workspace":{"id":"w1","userId":"u1","name":"Updated","skills":[],"createdAt":0,"updatedAt":0}}
            """)
        }

        let ws = try await client.updateWorkspace(id: "w1", UpdateWorkspaceRequest(name: "Updated"))
        #expect(ws.name == "Updated")
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
            {"skills":[{"name":"fetch","description":"Fetch URLs","containerSafe":true,"hasScripts":false,"path":"/path"}]}
            """)
        }

        let skills = try await client.listSkills()
        #expect(skills.count == 1)
        #expect(skills[0].name == "fetch")
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
            {"extensions":[{"name":"memory","path":"/Users/me/.pi/agent/extensions/memory.ts","kind":"file"}]}
            """)
        }

        let extensions = try await client.listExtensions()
        #expect(extensions.count == 1)
        #expect(extensions[0].name == "memory")
        #expect(extensions[0].kind == "file")
    }

    // MARK: - Files + Query Paths

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

    @Test func getSessionFileUsesQueryString() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let pathQuery = components?.queryItems?.first(where: { $0.name == "path" })?.value

            #expect(request.url?.path == "/sessions/s1/files")
            #expect(pathQuery == "/tmp/main.swift")
            #expect(request.url?.absoluteString.contains("%3Fpath=") == false)

            let body = "print(\"hello\")".data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (body, response)
        }

        let content = try await client.getSessionFile(sessionId: "s1", path: "/tmp/main.swift")
        #expect(content == "print(\"hello\")")
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

    @Test func unregisterDeviceToken() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            return self.mockResponse(json: "{}")
        }

        try await client.unregisterDeviceToken("abc123")
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
        #expect(server.errorDescription?.contains("500") == true)
        #expect(server.errorDescription?.contains("Internal error") == true)
    }
}
