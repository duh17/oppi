import Foundation
import Testing
@testable import Oppi

@Suite("MCP API probe deadline", .serialized)
struct McpAPIClientTests {
    @Test(arguments: ["list", "login", "add", "patch", "remove", "logout"])
    func liveProbeRequestsLeaveHeadroomUnderResourceDeadline(operation: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpDeadlineURLProtocol.self]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let baseURL = try #require(URL(string: "http://localhost:7749"))
        let client = APIClient(baseURL: baseURL, token: "test-token", configuration: configuration)
        defer { McpDeadlineURLProtocol.handler = nil }

        McpDeadlineURLProtocol.handler = { request in
            #expect(request.timeoutInterval == 25)
            #expect(request.timeoutInterval > 20)
            #expect(request.timeoutInterval < configuration.timeoutIntervalForResource)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let routes = [
                "list": ("GET", "/mcp/scopes/workspace-one/servers"),
                "login": ("POST", "/mcp/scopes/global/servers/echo/login"),
                "add": ("POST", "/mcp/scopes/workspace-one/servers"),
                "patch": ("PATCH", "/mcp/scopes/global/servers/echo"),
                "remove": ("DELETE", "/mcp/scopes/global/servers/echo"),
                "logout": ("POST", "/mcp/scopes/global/servers/echo/logout")
            ]
            #expect(request.httpMethod == routes[operation]?.0)
            #expect(request.url?.path == routes[operation]?.1)
            let response = try #require(HTTPURLResponse(
                url: baseURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            let json = operation == "list" ? #"{"scope":{"id":"workspace-one","title":"One","kind":"project","projectTrust":"ask","servers":[],"inherited":[],"errors":[]}}"# : #"{"flow":{"flowId":"pa_test","scopeId":"global","serverName":"echo","launchMode":"phone_browser","status":"pending","createdAt":1,"updatedAt":1,"expiresAt":2}}"#
            return (Data(json.utf8), response)
        }

        switch operation {
        case "list": #expect(try await client.listMcpServers(scopeId: "workspace-one").scope.id == "workspace-one")
        case "login": #expect(try await client.startMcpAuthFlow(scopeId: "global", name: "echo").flowId == "pa_test")
        case "add": try await client.addMcpServer(scopeId: "workspace-one", McpAddServerRequest(name: "echo", url: "https://example.test/mcp"))
        case "patch": try await client.patchMcpServer(scopeId: "global", name: "echo", patch: McpPatchServerRequest(enabled: false))
        case "remove": try await client.removeMcpServer(scopeId: "global", name: "echo")
        case "logout": try await client.logoutMcpServer(scopeId: "global", name: "echo")
        default: Issue.record("Unexpected operation")
        }
    }
}

// Keep this probe oracle independent of other API suites' shared protocol handler.
private final class McpDeadlineURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
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
