import Foundation
import Testing
@testable import Oppi

@Suite("MCP API probe deadline", .serialized)
struct McpAPIClientTests {
    @Test func liveProbeRequestLeavesHeadroomUnderResourceDeadline() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpDeadlineURLProtocol.self]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let baseURL = testUnwrap(URL(string: "http://localhost:7749"))
        let client = APIClient(baseURL: baseURL, token: "test-token", configuration: configuration)
        defer { McpDeadlineURLProtocol.handler = nil }

        McpDeadlineURLProtocol.handler = { request in
            #expect(request.timeoutInterval == 25)
            #expect(request.timeoutInterval > 20)
            #expect(request.timeoutInterval < configuration.timeoutIntervalForResource)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/mcp/scopes/workspace-one/servers")
            let response = try #require(HTTPURLResponse(
                url: baseURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            let json = #"{"scope":{"id":"workspace-one","title":"One","kind":"sandbox","servers":[],"errors":[]}}"#
            return (Data(json.utf8), response)
        }

        #expect(try await client.listMcpServers(scopeId: "workspace-one").scope.id == "workspace-one")
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
