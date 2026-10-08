import Foundation
import Testing
import UIKit
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

    private func jsonResponse(status: Int = 200, json: String) throws -> (Data, HTTPURLResponse) {
        let data = (try #require(json.data(using: .utf8)))
        let response = (try #require(HTTPURLResponse(
            url: URL(string: "http://localhost:7749")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )))
        return (data, response)
    }

    @Test(arguments: [SessionRouteScope.workspace("ws-1"), .control])
    func sidecarRawRangeRequestsExactBytes(_ scope: SessionRouteScope) async throws {
        let client = makeClient()
        defer { cleanup() }
        let bytes = Data([0xFF, 0xC3, 0x28, 0x1B])
        var requests = 0
        MockURLProtocol.handler = { request in
            requests += 1
            #expect(request.httpMethod == "GET")
            #expect(request.url?.query == "full=true")
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=6-9")
            #expect(request.url?.path == (scope == .control
                ? "/control-sessions/s1/tool-output/tc-1" : "/workspaces/ws-1/sessions/s1/tool-output/tc-1"))
            return (bytes, (try #require(HTTPURLResponse(url: (testUnwrap(request.url)), statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 6-9/10"]))))
        }
        let range = try await client.getTerminalOutputRange(scope: scope, sessionId: "s1", toolCallId: "tc-1", range: 6..<10)
        #expect(requests == 1)
        #expect(range.start == 6)
        #expect(range.end == 10)
        #expect(range.data == bytes) // invalid UTF-8 must not be re-encoded
    }

    @Test(arguments: [false, true]) @MainActor
    func completedTerminalHistoryUsesRawHTTPBytes(large: Bool) async throws {
        let client = makeClient()
        defer { cleanup() }
        // C1 erase-display distinguishes raw VT interpretation from U+FFFD.
        // Include an invalid lead and an incomplete UTF-8 sequence at EOF.
        // Large raw input with a small resolved screen isolates byte paging
        // from virtualized history (covered by the terminal-window suite).
        let padding = large ? String(repeating: "\u{1B}[32m", count: 30_000) : ""
        let raw = Data((padding + "earlier\n").utf8)
            + Data([0x9B, 0x33, 0x4A, 0x9B, 0x32, 0x4A])
            + Data("visible\n".utf8) + Data([0xFF, 0xE2, 0x82])
        var ranges: [String] = []
        var jsonRequests = 0
        MockURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                return (Data(), try #require(HTTPURLResponse(url: (testUnwrap(request.url)), statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Length": "\(raw.count)"])))
            }
            if let range = request.value(forHTTPHeaderField: "Range") {
                ranges.append(range)
                let bounds = range.dropFirst(6).split(separator: "-")
                let start = (try #require(Int(bounds[0])))
                let end = min((try #require(Int(bounds[1]))) + 1, raw.count)
                return (raw.subdata(in: start..<end), (try #require(HTTPURLResponse(url: (testUnwrap(request.url)), statusCode: 206,
                    httpVersion: nil, headerFields: ["Content-Range": "bytes \(start)-\(end - 1)/\(raw.count)"]))))
            }
            jsonRequests += 1
            let data = try JSONEncoder().encode(["output": String(decoding: raw, as: UTF8.self)])
            return (data, (try #require(HTTPURLResponse(url: (testUnwrap(request.url)), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))))
        }
        let access = SessionToolOutputAccess(apiClient: client, scope: .control, sessionId: "s1")
        let body = NativeFullScreenTerminalBody(
            content: "held preview\n",
            command: nil,
            stream: nil,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            sidecarSource: access.sidecarSource(toolCallId: "tc-1")
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        let reference = try TerminalLogEngine()
        try reference.feed(raw)
        let expected = ANSIParser.strip(try reference.paint())
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            func painted(_ view: UIView) -> Bool {
                if let text = view as? UITextView, text.textStorage.string == expected { return true }
                return view.subviews.contains { painted($0) }
            }
            return painted(body)
        })
        #expect(await body.resolvedCopyText() == expected)
        #expect(jsonRequests == 0)
        #expect(!ranges.isEmpty)
        if large { #expect(ranges.contains { $0.hasPrefix("bytes=131072-") }) }
    }

    @Test func terminalRecoveryRejectsUnrangedResponse() async throws {
        let client = makeClient()
        defer { cleanup() }
        MockURLProtocol.handler = { request in
            (Data([65]), (try #require(HTTPURLResponse(url: (testUnwrap(request.url)), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 0-0/1"]))))
        }
        do {
            _ = try await client.getTerminalOutputRange(scope: .control, sessionId: "s1", toolCallId: "tc-1", range: 0..<1)
            Issue.record("Expected an invalid ranged response to fail")
        } catch {
            guard case APIError.invalidResponse = error else { Issue.record("Unexpected error: \(error)"); return }
        }
    }

    @Test func getNonEmptyFullToolOutputDecodesEntireJSONSidecar() async throws {
        let client = makeClient()
        defer { cleanup() }
        let sidecar = String(repeating: "line of bash output\n", count: 200)
        struct Payload: Encodable { let output: String }
        let payload = (try #require(String(data: try JSONEncoder().encode(Payload(output: sidecar)), encoding: .utf8)))
        var decodedEntireBody = false

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/workspaces/ws-1/sessions/s1/tool-output/tc-1")
            #expect(request.url?.query == "full=true")
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            decodedEntireBody = true
            return try self.jsonResponse(json: payload)
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
                let response = (try #require(HTTPURLResponse(
                    url: (testUnwrap(request.url)),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                        "Content-Length": String(total),
                    ]
                )))
                return (Data(), response)
            }
            if request.httpMethod == "GET", request.value(forHTTPHeaderField: "Range") != nil {
                let response = (try #require(HTTPURLResponse(
                    url: (testUnwrap(request.url)),
                    statusCode: 206,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes 0-\(first.count - 1)/\(total)",
                        "Content-Length": String(first.count),
                    ]
                )))
                return (first, response)
            }
            jsonDecoded = true
            Issue.record("JSON full=true path should not run for a large sidecar")
            return try self.jsonResponse(json: #"{"output":"should-not-decode-entire-sidecar"}"#)
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
                let response = (try #require(HTTPURLResponse(
                    url: (testUnwrap(request.url)),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                        "Content-Length": "5",
                    ]
                )))
                return (Data(), response)
            }
            return try self.jsonResponse(json: #"{"output":"small"}"#)
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

    @Test func openFullToolOutputSidecarUsesRangeWhenHeadHasNoContentLength() async throws {
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
            #expect(request.url?.query == "full=true")
            if request.httpMethod == "HEAD" {
                let response = (try #require(HTTPURLResponse(
                    url: (testUnwrap(request.url)),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                    ]
                )))
                return (Data(), response)
            }
            if request.httpMethod == "GET", request.value(forHTTPHeaderField: "Range") != nil {
                let response = (try #require(HTTPURLResponse(
                    url: (testUnwrap(request.url)),
                    statusCode: 206,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes 0-\(first.count - 1)/\(total)",
                        "Content-Length": String(first.count),
                    ]
                )))
                return (first, response)
            }
            jsonDecoded = true
            Issue.record("HEAD-nil expand must not JSON-decode the entire sidecar")
            return try self.jsonResponse(json: #"{"output":"should-not-decode-entire-sidecar"}"#)
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
        #expect(window?.isComplete == false)
        #expect(window?.totalBytes == total)

        jsonDecoded = false
        methods.removeAll()
        ranges.removeAll()
        let fetched = try await ExpandedToolOutputFetch.fetchForExpand(
            availability: .init(complete: false, source: "sidecar"),
            apiClient: client,
            scope: .workspace("ws-1"),
            sessionId: "s1",
            toolCallId: "tc-1"
        )
        #expect(!jsonDecoded)
        #expect(fetched.previewOnly)
        #expect(fetched.totalBytes == total)
        #expect(!ToolOutputSidecarWindow(
            text: fetched.text,
            endByteOffset: fetched.text.utf8.count,
            totalBytes: total
        ).isComplete)
    }

    @Test func expandFetchForLargeBashUsesHeadAndRangeNotFullJSON() async throws {
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
            #expect(request.url?.query == "full=true")
            if request.httpMethod == "HEAD" {
                let response = (try #require(HTTPURLResponse(
                    url: (testUnwrap(request.url)),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                        "Content-Length": String(total),
                    ]
                )))
                return (Data(), response)
            }
            if request.httpMethod == "GET", request.value(forHTTPHeaderField: "Range") != nil {
                let response = (try #require(HTTPURLResponse(
                    url: (testUnwrap(request.url)),
                    statusCode: 206,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes 0-\(first.count - 1)/\(total)",
                        "Content-Length": String(first.count),
                    ]
                )))
                return (first, response)
            }
            jsonDecoded = true
            Issue.record("expand must not JSON-decode the entire sidecar")
            return try self.jsonResponse(json: #"{"output":"should-not-decode-entire-sidecar"}"#)
        }

        let fetched = try await ExpandedToolOutputFetch.fetchForExpand(
            availability: .init(complete: false, source: "sidecar"),
            apiClient: client,
            scope: .workspace("ws-1"),
            sessionId: "s1",
            toolCallId: "tc-1"
        )
        #expect(methods == ["HEAD", "GET"])
        #expect(ranges == ["bytes=0-\(ToolOutputSidecarHTTP.firstWindowBytes - 1)"])
        #expect(!jsonDecoded)
        #expect(fetched.text == String(repeating: "a", count: ToolOutputSidecarHTTP.firstWindowBytes))
        #expect(fetched.text.utf8.count == ToolOutputSidecarHTTP.firstWindowBytes)
        #expect(fetched.previewOnly)
        #expect(fetched.totalBytes == total)
        #expect(!ToolOutputSidecarWindow(
            text: fetched.text,
            endByteOffset: fetched.text.utf8.count,
            totalBytes: total
        ).isComplete)
    }

    @Test func copyFetchForLargeBashStillDecodesFullJSON() async throws {
        let client = makeClient()
        defer { cleanup() }
        let sidecar = String(repeating: "a", count: ToolOutputSidecarHTTP.firstWindowBytes + 64)
        struct Payload: Encodable { let output: String }
        let payload = (try #require(String(data: try JSONEncoder().encode(Payload(output: sidecar)), encoding: .utf8)))
        var decodedEntireBody = false
        var usedRange = false

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.query == "full=true")
            if request.value(forHTTPHeaderField: "Range") != nil {
                usedRange = true
            }
            decodedEntireBody = true
            return try self.jsonResponse(json: payload)
        }

        let output = try await ExpandedToolOutputFetch.fetchForCopy(
            apiClient: client,
            scope: .workspace("ws-1"),
            sessionId: "s1",
            toolCallId: "tc-1"
        )
        #expect(decodedEntireBody)
        #expect(!usedRange)
        #expect(output == sidecar)
    }
}
