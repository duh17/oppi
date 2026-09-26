import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

/// Own protocol class so this suite never races the shared `TestURLProtocol` handler.
private final class EditURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let ifMatch: String?
        let body: Data
    }

    nonisolated(unsafe) static var handler: ((Recorded) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var recorded: [Recorded] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readStream(request.httpBodyStream)
        let record = Recorded(
            method: request.httpMethod ?? "",
            url: request.url!,
            ifMatch: request.value(forHTTPHeaderField: "If-Match"),
            body: body
        )
        Self.lock.lock()
        Self.recorded.append(record)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, headers, data) = try handler(record)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func reset() {
        lock.lock()
        handler = nil
        recorded = []
        lock.unlock()
    }
}

@Suite("APIClient workspace file editing", .serialized)
struct APIClientWorkspaceFileEditingTests {
    private static let tag = "\"sha256-\(String(repeating: "a", count: 64))\""
    private static let newTag = "\"sha256-\(String(repeating: "b", count: 64))\""

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EditURLProtocol.self]
        return APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "http://localhost:7749")!,
                bearerToken: "sk_test"
            ),
            configuration: config
        )
    }

    private func serverInfo(_ capabilities: String) -> Data {
        Data("""
        {"name":"Test","version":"1.0","uptime":1,"os":"darwin","arch":"arm64","hostname":"test","nodeVersion":"22","piVersion":"1","configVersion":1,"capabilities":\(capabilities),"stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}
        """.utf8)
    }

    private func loadCapabilities(_ client: APIClient, _ capabilities: String) async throws {
        EditURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], self.serverInfo(capabilities)) }
        _ = try await client.serverInfo()
        EditURLProtocol.reset()
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func missingCapabilityIsReadOnlyAndSendsNoRequest() async throws {
        defer { EditURLProtocol.reset() }
        for capabilities in [
            #"{"currentFiles":{"version":1}}"#,
            // Editing without currentFiles would need a legacy route; stay read-only.
            #"{"workspaceFileEditing":{"version":1,"maxBytes":1048576}}"#,
        ] {
            let client = makeClient()
            try await loadCapabilities(client, capabilities)
            #expect(await client.workspaceFileEditingCapability() == nil)
            let outcome = await client.writeWorkspaceFile(
                workspaceId: "w1", path: "notes.md", worktreeId: nil,
                bytes: Data("x".utf8), ifMatch: Self.tag
            )
            guard case .rejected = outcome else {
                Issue.record("expected rejected, got \(outcome)")
                continue
            }
            await #expect(throws: CocoaError.self) {
                _ = try await client.readWorkspaceFileForEditing(workspaceId: "w1", path: "notes.md")
            }
            #expect(EditURLProtocol.recorded.isEmpty, "a read-only server must never receive a write or edit read")
        }
    }

    @Test func putTargetsCurrentFileWorkspaceOriginWithExactBytesAndTag() async throws {
        defer { EditURLProtocol.reset() }
        let client = makeClient()
        try await loadCapabilities(
            client,
            #"{"currentFiles":{"version":1},"workspaceFileEditing":{"version":1,"maxBytes":1048576}}"#
        )
        #expect(await client.workspaceFileEditingCapability()?.maxBytes == 1_048_576)

        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\u{0065}\u{0301}".utf8)
        EditURLProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"], Data(#"{"etag":\#(Self.newTagJSON),"size":9,"mtimeMs":1}"#.utf8))
        }
        let outcome = await client.writeWorkspaceFile(
            workspaceId: "w1", path: "docs/a b.md", worktreeId: "wt-1",
            bytes: bytes, ifMatch: Self.tag
        )
        #expect(outcome == .saved(etag: Self.newTag))
        let request = try #require(EditURLProtocol.recorded.first)
        #expect(EditURLProtocol.recorded.count == 1)
        #expect(request.method == "PUT")
        #expect(request.url.path == "/files/current")
        #expect(query(request.url) == [
            "origin": "workspace", "workspaceId": "w1", "worktreeId": "wt-1", "path": "docs/a b.md",
        ])
        #expect(request.ifMatch == Self.tag)
        #expect(request.body == bytes)
    }

    private static var newTagJSON: String { "\"\\\"sha256-\(String(repeating: "b", count: 64))\\\"\"" }

    @Test func putStatusesMapToTypedOutcomes() async throws {
        defer { EditURLProtocol.reset() }
        let client = makeClient()
        try await loadCapabilities(
            client,
            #"{"currentFiles":{"version":1},"workspaceFileEditing":{"version":1,"maxBytes":1048576}}"#
        )
        let cases: [(Int, WorkspaceFileWriteOutcome)] = [
            (412, .stale),
            (404, .missing),
            (413, .rejected(status: 413, message: "File too large (max 1MB)")),
            (415, .rejected(status: 415, message: "File too large (max 1MB)")),
        ]
        for (status, expected) in cases {
            EditURLProtocol.handler = { _ in (status, [:], Data(#"{"error":"File too large (max 1MB)"}"#.utf8)) }
            let outcome = await client.writeWorkspaceFile(
                workspaceId: "w1", path: "a.md", worktreeId: nil, bytes: Data("x".utf8), ifMatch: Self.tag
            )
            #expect(outcome == expected)
        }

        EditURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await client.writeWorkspaceFile(
            workspaceId: "w1", path: "a.md", worktreeId: nil, bytes: Data("x".utf8), ifMatch: Self.tag
        ) == .notSent)
        EditURLProtocol.handler = { _ in throw URLError(.timedOut) }
        #expect(await client.writeWorkspaceFile(
            workspaceId: "w1", path: "a.md", worktreeId: nil, bytes: Data("x".utf8), ifMatch: Self.tag
        ) == .unknown)
        EditURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        #expect(await client.writeWorkspaceFile(
            workspaceId: "w1", path: "a.md", worktreeId: nil, bytes: Data("x".utf8), ifMatch: Self.tag
        ) == .unknown)
        // Every write, including failures, used the one current-file route.
        #expect(EditURLProtocol.recorded.allSatisfy { $0.method == "PUT" && $0.url.path == "/files/current" })
    }

    @Test func editReadReturnsExactBytesAndETagFromTheSameResponse() async throws {
        defer { EditURLProtocol.reset() }
        let client = makeClient()
        try await loadCapabilities(
            client,
            #"{"currentFiles":{"version":1},"workspaceFileEditing":{"version":1,"maxBytes":1048576}}"#
        )
        let bytes = Data("{\n  \"a\": 1\n}".utf8)
        EditURLProtocol.handler = { record in
            #expect(record.method == "GET")
            #expect(record.url.path == "/files/current")
            return (200, ["ETag": Self.tag, "Content-Type": "application/json"], bytes)
        }
        let snapshot = try await client.readWorkspaceFileForEditing(workspaceId: "w1", path: "a.json", worktreeId: "wt-2")
        #expect(snapshot == WorkspaceFileDiskSnapshot(bytes: bytes, etag: Self.tag))
        #expect(query(EditURLProtocol.recorded[0].url)["worktreeId"] == "wt-2")

        EditURLProtocol.handler = { _ in (404, [:], Data(#"{"error":"File not found"}"#.utf8)) }
        #expect(await client.readWorkspaceFileForEditingOutcome(workspaceId: "w1", path: "a.json", worktreeId: nil) == .missing)
    }
}
