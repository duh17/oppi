import Foundation
import Testing
@testable import Oppi

@Suite("MCP API probe deadline", .serialized)
struct McpAPIClientTests {
    @Test(arguments: ["list", "login"])
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
            #expect(request.httpMethod == (operation == "list" ? "GET" : "POST"))
            #expect(request.url?.path == (operation == "list"
                ? "/mcp/servers" : "/mcp/scopes/global/servers/echo/login"))
            let response = try #require(HTTPURLResponse(
                url: baseURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            let json = operation == "list" ? #"{"scopes":[]}"# : #"{"flow":{"flowId":"pa_test","scopeId":"global","serverName":"echo","launchMode":"phone_browser","status":"pending","createdAt":1,"updatedAt":1,"expiresAt":2}}"#
            return (Data(json.utf8), response)
        }

        if operation == "list" {
            #expect(try await client.listMcpServers().scopes.isEmpty)
        } else {
            #expect(try await client.startMcpAuthFlow(scopeId: "global", name: "echo").flowId == "pa_test")
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
