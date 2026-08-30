import Foundation
import Testing
@testable import Oppi

@Suite("Mac local HTTP")
struct MacLocalHTTPTests {
    @Test func preferredSocketPathStaysUnderDataDir() {
        let dataDir = "/Users/chenda/.config/oppi"
        #expect(MacLocalAPISocket.path(dataDir: dataDir) == "/Users/chenda/.config/oppi/run/oppi.sock")
    }

    @Test func deepDataDirUsesBoundedTmpFallback() {
        let dataDir = "/tmp/oppi-deep-data/" + String(repeating: "x", count: 180)
        let path = MacLocalAPISocket.path(dataDir: dataDir)
        #expect(path.utf8.count <= MacLocalAPISocket.maxPathBytes)
        #expect(path.hasPrefix("/tmp/oppi-"))
        #expect(path.hasSuffix(".sock"))
        #expect(!path.contains(String(repeating: "x", count: 100)))
        #expect(MacLocalAPISocket.path(dataDir: dataDir) == path)
    }

    @Test func encodeIncludesBearerAndDoesNotUseHTTPS() {
        let request = macLocalAuthenticatedRequest(
            method: "GET",
            path: "/workspaces",
            token: "sk_test"
        )
        let encoded = String(data: MacLocalHTTPCodec.encode(request), encoding: .utf8) ?? ""
        #expect(encoded.hasPrefix("GET /workspaces HTTP/1.1\r\n"))
        #expect(encoded.contains("Authorization: Bearer sk_test"))
        #expect(encoded.contains("Host: localhost"))
        #expect(!encoded.contains("https://"))
        #expect(!encoded.contains("7749"))
    }

    @Test func parseChunkedJSONBody() throws {
        let payload = #"{"error":"Unauthorized"}"#
        var raw = Data("HTTP/1.1 401 Unauthorized\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        raw.append(Data("\(String(payload.utf8.count, radix: 16))\r\n".utf8))
        raw.append(Data(payload.utf8))
        raw.append(Data("\r\n0\r\n\r\n".utf8))
        let response = try #require(try MacLocalHTTPCodec.parse(raw, connectionClosed: false))
        #expect(response.statusCode == 401)
        #expect(String(data: response.body, encoding: .utf8) == payload)
    }

    @Test func parseUnauthorizedJSON() throws {
        let raw = Data("HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 24\r\n\r\n{\"error\":\"Unauthorized\"}".utf8)
        let response = try #require(try MacLocalHTTPCodec.parse(raw, connectionClosed: false))
        #expect(response.statusCode == 401)
        #expect(String(data: response.body, encoding: .utf8) == #"{"error":"Unauthorized"}"#)
    }

    @Test func listRecentSessionsUsesAggregatedEndpoint() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"sessions":[{"id":"s1","workspaceId":"ws-1","status":"ready","createdAt":0,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}]}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let summaries = try await client.listRecentSessions()

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/sessions/recent?recentDays=3")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(summaries.map(\.id) == ["s1"])
        #expect(await transport.requests.count == 1)
        #expect(await transport.requests.allSatisfy { !$0.path.contains("/workspaces/") })
    }

    @Test func workspaceCatalogUsesOwnerSocketNotHTTPS() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"workspaces":[{"id":"ws-1","name":"Oppi","createdAt":1,"updatedAt":1}],"summaries":[]}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let catalog = try await client.listWorkspaceCatalog()

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/workspaces")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(catalog.workspaces.map(\.id) == ["ws-1"])
        #expect(await transport.requests.count == 1)
    }

    @Test func listWorkspaceCatalogAgainstLiveOwnerSocket() async throws {
        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        let socketPath = MacLocalAPISocket.path(dataDir: dataDir)
        guard FileManager.default.fileExists(atPath: socketPath),
              let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else {
            return
        }

        let client = MacWorkspaceClient(socketPath: socketPath, token: token)
        let catalog = try await client.listWorkspaceCatalog()
        #expect(!catalog.workspaces.isEmpty)
    }

    @Test func opensStoppedSessionTraceAgainstLiveOwnerSocket() async throws {
        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        let socketPath = MacLocalAPISocket.path(dataDir: dataDir)
        guard FileManager.default.fileExists(atPath: socketPath),
              let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else {
            return
        }

        let client = MacWorkspaceClient(socketPath: socketPath, token: token)
        let summaries = try await client.listRecentSessions(recentDays: 3)
        guard let summary = summaries.first(where: {
            $0.status == .stopped && ($0.workspaceId?.isEmpty == false)
        }), let workspaceId = summary.workspaceId else {
            return
        }

        let page = try await client.getWorkspaceSessionTracePage(
            workspaceId: workspaceId,
            sessionId: summary.id
        )
        #expect(page.session.id == summary.id)
        #expect(!page.trace.isEmpty)
    }

    @Test func workspaceCatalogSurfacesUnixSocket401() async {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 401,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":"Unauthorized"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        do {
            _ = try await client.listWorkspaceCatalog()
            Issue.record("Expected 401 to throw")
        } catch let error as MacWorkspaceClientError {
            #expect(error == .server(status: 401, message: #"{"error":"Unauthorized"}"#))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func serverInfoUsesOwnerSocketNotHTTPS() async {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"version":"1.2.3","serverUrl":"https://localhost:7749","uptime":60,"name":"local"}"#.utf8)
            )
        )
        let client = MacAPIClient(
            baseURL: URL(string: "https://localhost:7749")!,
            token: "sk_owner",
            socketPath: "/tmp/oppi-test.sock",
            transport: transport
        )

        let info = await client.fetchServerInfo()

        #expect(info?.version == "1.2.3")
        let request = await transport.requests.first
        #expect(request?.method == "GET")
        #expect(request?.path == "/server/info")
        #expect(request?.headers["Authorization"] == "Bearer sk_owner")
    }
}

actor RecordingLocalHTTPTransport: MacLocalHTTPPerforming {
    private(set) var requests: [MacLocalHTTPRequest] = []
    private let response: MacLocalHTTPResponse

    init(response: MacLocalHTTPResponse) {
        self.response = response
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        return response
    }
}
