import Foundation
import os
import Testing
@testable import Oppi

/// Shared URLProtocol test double for intercepting URLSession traffic.
///
/// Swift Testing runs suites in parallel, so the handler is kept per test, not in one
/// process-wide slot. `handler` reads and writes the running test's slot, and a session
/// must be built with `install(in:)` so its requests name the test whose handler
/// answers them. Build sessions with `install(in:)`, never by assigning `protocolClasses`.
class TestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Data, HTTPURLResponse)

    private static let ownerHeader = "X-Oppi-Test-Handler-Owner"
    private static let handlers = OSAllocatedUnfairLock(uncheckedState: [String: Handler]())

    /// The handler of the running test (and of tasks it starts).
    static var handler: Handler? {
        get { handlers.withLockUnchecked { $0[currentOwner] } }
        set { handlers.withLockUnchecked { $0[currentOwner] = newValue } }
    }

    /// Routes `configuration`'s requests to this test's `handler`.
    static func install(in configuration: URLSessionConfiguration) {
        configuration.protocolClasses = [TestURLProtocol.self]
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[ownerHeader] = currentOwner
        configuration.httpAdditionalHeaders = headers
    }

    private static var currentOwner: String {
        Test.current.map { String(describing: $0.id) } ?? "outside a test"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        let owner = request.value(forHTTPHeaderField: Self.ownerHeader)
        request.setValue(nil, forHTTPHeaderField: Self.ownerHeader)
        guard let owner else {
            fail("\(request.url?.absoluteString ?? "request") names no owning test: build the session with TestURLProtocol.install(in:)")
            return
        }
        guard let handler = Self.handlers.withLockUnchecked({ $0[owner] }) else {
            fail("\(request.url?.absoluteString ?? "request") reached TestURLProtocol with no handler set by \(owner)")
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

    /// A setup mistake is not a server answer: it fails with its own error, and the run,
    /// so it can never satisfy a test that expects the request to fail.
    private func fail(_ message: String) {
        Issue.record(Comment(rawValue: message))
        client?.urlProtocol(self, didFailWithError: NSError(
            domain: "TestURLProtocol", code: 1, userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }

    override func stopLoading() {}
}

/// An `APIClient` whose requests reach `TestURLProtocol`, so the running test's handler
/// answers them: no test talks to a host that does not exist.
func makeTestURLProtocolClient(
    host: String = "127.0.0.1",
    port: Int = 7749,
    scheme: String = "https"
) -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    TestURLProtocol.install(in: configuration)
    return APIClient(
        baseURL: URL(string: "\(scheme)://\(host):\(port)") ?? URL(fileURLWithPath: "/"),
        token: "sk_test",
        configuration: configuration
    )
}

/// The answer to one request: `json` with `status`, so a handler says what a route
/// returns without building the response by hand.
func mockJSONResponse(
    status: Int = 200,
    json: String,
    for request: URLRequest
) throws -> (Data, HTTPURLResponse) {
    try mockJSONResponse(status: status, data: #require(json.data(using: .utf8)), for: request)
}

/// `value` as JSON, the answer to one request.
func mockJSONResponse(
    status: Int = 200,
    encoding value: some Encodable,
    for request: URLRequest
) throws -> (Data, HTTPURLResponse) {
    try mockJSONResponse(status: status, data: try JSONEncoder().encode(value), for: request)
}

private func mockJSONResponse(
    status: Int,
    data: Data,
    for request: URLRequest
) throws -> (Data, HTTPURLResponse) {
    let response = (try #require(HTTPURLResponse(
        url: request.url ?? URL(fileURLWithPath: "/"),
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )))
    return (data, response)
}

/// A handler for the routes a test answers: a request outside them is a route the test
/// did not plan, so it records an issue and fails the test instead of answering 404.
private func mockRoutes(
    _ answer: @escaping (URLRequest) throws -> (Data, HTTPURLResponse)?
) -> TestURLProtocol.Handler {
    { request in
        guard let answer = try answer(request) else {
            let route = "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "no url")"
            Issue.record(Comment(rawValue: "unexpected request: \(route)"))
            throw URLError(.unsupportedURL)
        }
        return answer
    }
}

/// The routes the app refreshes on its own once a server is connected: its info, the
/// metrics setting and history, provider status, paired devices, both server resource
/// catalogs, a workspace's git status and file index, and a session's trace page. They
/// answer as a server that is not reachable does, and anything else is a route this
/// helper does not know.
private func unreachableBackgroundAnswer(_ request: URLRequest) throws -> (Data, HTTPURLResponse)? {
    let path = request.url?.path ?? ""
    let isBackground = [
        "/server/info",
        "/server/metrics",
        "/server/metrics/settings",
        "/provider-auth/status",
        "/auth/devices",
    ].contains(path)
        || path.hasSuffix("/git/status")
        || path.hasSuffix("/paths")
        || path.hasSuffix("/trace-page")
        || path.hasSuffix("/server/resources/skills")
        || path.hasSuffix("/server/resources/extensions")
    guard isBackground else { return nil }
    throw URLError(.cannotConnectToHost)
}

/// The app's own refreshes, answered as an unreachable server does: for a page test that is
/// not about them, and a request outside them fails the test.
func mockUnreachableBackgroundRoutes() -> TestURLProtocol.Handler {
    mockRoutes { request in try unreachableBackgroundAnswer(request) }
}

/// A page test's own routes over the app's own refreshes: `answer` gets the routes the test
/// scripts, the ones it leaves out answer as an unreachable server does, and a request
/// outside both fails the test.
func mockPageRoutes(
    _ answer: @escaping (URLRequest) throws -> (Data, HTTPURLResponse)?
) -> TestURLProtocol.Handler {
    mockRoutes { request in try answer(request) ?? unreachableBackgroundAnswer(request) }
}

/// A route a page finds missing until the test says the server is back: 404 until
/// `makeAvailable()`, then `availableJSON`. Counts its requests, so a test can tell the
/// request Retry sent from one it did not.
final class MissingRouteThenAvailable: @unchecked Sendable {
    private let lock = NSLock()
    private let availableJSON: String
    private var isAvailable = false
    private var requestCount = 0

    init(availableJSON: String) {
        self.availableJSON = availableJSON
    }

    var requests: Int { lock.withLock { requestCount } }

    func makeAvailable() { lock.withLock { isAvailable = true } }

    func answer(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let available = lock.withLock {
            requestCount += 1
            return isAvailable
        }
        return available
            ? try mockJSONResponse(json: availableJSON, for: request)
            : try mockJSONResponse(status: 404, json: #"{"error":"not found"}"#, for: request)
    }
}

@MainActor
final class ScriptedStreamFactory {
    private(set) var streamsCreated = 0
    private var continuations: [AsyncStream<ServerMessage>.Continuation] = []

    func makeStream() -> AsyncStream<ServerMessage> {
        let index = streamsCreated
        streamsCreated += 1

        return AsyncStream { continuation in
            if index < self.continuations.count {
                self.continuations[index] = continuation
            } else {
                self.continuations.append(continuation)
            }
        }
    }

    func yield(index: Int, message: ServerMessage) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(message)
    }

    func finish(index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func waitForCreated(_ expected: Int, timeoutMs: Int = 1_000) async -> Bool {
        let attempts = max(1, timeoutMs / 20)
        for _ in 0..<attempts {
            if streamsCreated >= expected, continuations.count >= expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

@MainActor
final class ScriptedFrameStreamFactory {
    private(set) var streamsCreated = 0
    private var continuations: [AsyncStream<StreamFrameEvent>.Continuation] = []

    func makeStream() -> AsyncStream<StreamFrameEvent> {
        let index = streamsCreated
        streamsCreated += 1

        return AsyncStream { continuation in
            if index < self.continuations.count {
                self.continuations[index] = continuation
            } else {
                self.continuations.append(continuation)
            }
        }
    }

    func yield(index: Int, event: StreamFrameEvent) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(event)
    }

    func finish(index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func waitForCreated(_ expected: Int, timeoutMs: Int = 1_000) async -> Bool {
        let attempts = max(1, timeoutMs / 20)
        for _ in 0..<attempts {
            if streamsCreated >= expected, continuations.count >= expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

func makeCancellableNeverCompletingTaskForTesting() -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

func suspendUntilCancelledForTesting() async throws {
    while true {
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Non-macro unwrap for values nested inside `#require`. Nested `#require`
/// macros expand recursively and do not compile.
func testUnwrap<T>(_ value: T?, function: StaticString = #function, line: UInt = #line) -> T {
    guard let value else {
        preconditionFailure("Unexpected nil in \(function):\(line)")
    }
    return value
}

actor MessageCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func count() -> Int {
        value
    }
}
