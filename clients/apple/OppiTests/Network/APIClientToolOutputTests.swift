import Foundation
import Testing
@testable import Oppi

@Suite("APIClient tool-output sidecar", .serialized)
struct APIClientToolOutputTests {
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

    private func jsonResponse(status: Int = 200, json: String) -> (Data, HTTPURLResponse) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://localhost:7749")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    @Test func getNonEmptyFullToolOutputDecodesEntireJSONSidecar() async throws {
        let client = makeClient()
        defer { cleanup() }
        let sidecar = String(repeating: "line of bash output\n", count: 200)
        struct Payload: Encodable { let output: String }
        let payload = String(data: try JSONEncoder().encode(Payload(output: sidecar)), encoding: .utf8)!
        var decodedEntireBody = false

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/workspaces/ws-1/sessions/s1/tool-output/tc-1")
            #expect(request.url?.query == "full=true")
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            decodedEntireBody = true
            return self.jsonResponse(json: payload)
        }

        let output = try await client.getNonEmptyFullToolOutput(
            scope: .workspace("ws-1"),
            sessionId: "s1",
            toolCallId: "tc-1"
        )
        #expect(decodedEntireBody)
        #expect(output == sidecar)
    }

    @Test func openFullToolOutputSidecarUsesHeadAndFirstRangeWithoutDecodingEntireJSON() async throws {
        let client = makeClient()
        defer { cleanup() }
        let total = ToolOutputSidecarHTTP.firstWindowBytes + 64 * 1024
        let first = Data(repeating: 0x61, count: ToolOutputSidecarHTTP.firstWindowBytes)
        var methods: [String] = []
        var ranges: [String] = []
        var jsonDecoded = false

        MockURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if let range = request.value(forHTTPHeaderField: "Range") {
                ranges.append(range)
            }
            #expect(request.url?.path == "/workspaces/ws-1/sessions/s1/tool-output/tc-1")
            #expect(request.url?.query == "full=true")
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                        "Content-Length": String(total),
                    ]
                )!
                return (Data(), response)
            }
            if request.httpMethod == "GET", request.value(forHTTPHeaderField: "Range") != nil {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 206,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes 0-\(first.count - 1)/\(total)",
                        "Content-Length": String(first.count),
                    ]
                )!
                return (first, response)
            }
            jsonDecoded = true
            Issue.record("JSON full=true path should not run for a large sidecar")
            return self.jsonResponse(json: #"{"output":"should-not-decode-entire-sidecar"}"#)
        }

        let window = try await client.openFullToolOutputSidecar(
            scope: .workspace("ws-1"),
            sessionId: "s1",
            toolCallId: "tc-1"
        )
        #expect(methods == ["HEAD", "GET"])
        #expect(ranges == ["bytes=0-\(ToolOutputSidecarHTTP.firstWindowBytes - 1)"])
        #expect(!jsonDecoded)
        #expect(window?.text == String(repeating: "a", count: ToolOutputSidecarHTTP.firstWindowBytes))
        #expect(window?.endByteOffset == ToolOutputSidecarHTTP.firstWindowBytes)
        #expect(window?.totalBytes == total)
        #expect(window?.isComplete == false)
    }

    @Test func openFullToolOutputSidecarKeepsJSONForSmallOutput() async throws {
        let client = makeClient()
        defer { cleanup() }
        var methods: [String] = []

        MockURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                        "Content-Length": "5",
                    ]
                )!
                return (Data(), response)
            }
            return self.jsonResponse(json: #"{"output":"small"}"#)
        }

        let window = try await client.openFullToolOutputSidecar(
            scope: .workspace("ws-1"),
            sessionId: "s1",
            toolCallId: "tc-1"
        )
        #expect(methods == ["HEAD", "GET"])
        #expect(window?.text == "small")
        #expect(window?.isComplete == true)
    }
}
