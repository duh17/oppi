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
/// A test keeps its handler for its lifetime through `routeScope(_:)`, which is what ends
/// it: a request that outlives its test then finds no handler, instead of being answered
/// by a stale one.
class TestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Data, HTTPURLResponse)

    /// A handler's answer for a route it did not plan: `startLoading` reports it to the
    /// owning test rather than failing the run from URLSession's thread.
    struct UnplannedRoute: Error {
        let route: String
    }

    private static let ownerHeader = "X-Oppi-Test-Handler-Owner"
    private static let handlers = OSAllocatedUnfairLock(uncheckedState: [String: Handler]())
    /// Rows a handler left unanswered, per test, for the scope that installed it to report.
    private static let unplanned = OSAllocatedUnfairLock(uncheckedState: [String: [String]]())
    /// Tests that hold a scope, so a route with nobody to report it still fails the run.
    private static let scoped = OSAllocatedUnfairLock(uncheckedState: Set<String>())
    /// When each test's last request arrived, for `RouteScope.settle(quiet:)`.
    private static let lastRequest = OSAllocatedUnfairLock(uncheckedState: [String: ContinuousClock.Instant]())

    /// The handler of the running test (and of tasks it starts).
    static var handler: Handler? {
        get { handlers.withLockUnchecked { $0[currentOwner] } }
        set { handlers.withLockUnchecked { $0[currentOwner] = newValue } }
    }

    /// Answers this test's requests with `handler` until `end()`: the scope is what clears
    /// the handler, so no request outlives it, and it fails the test, on the test's own
    /// thread, for every route the handler did not plan.
    static func routeScope(_ handler: @escaping Handler) -> RouteScope {
        let owner = currentOwner
        Self.handler = handler
        unplanned.withLockUnchecked { $0[owner] = [] }
        lastRequest.withLockUnchecked { $0[owner] = nil }
        scoped.withLockUnchecked { $0.insert(owner) }
        return RouteScope(owner: owner)
    }

    /// Holds only its owner's name and touches `TestURLProtocol`'s locks, so a test can
    /// carry it across an `await`.
    final class RouteScope: Sendable {
        private let owner: String

        fileprivate init(owner: String) {
            self.owner = owner
        }

        /// Ends the scope: from here no handler answers this test's requests, and a route
        /// the handler left unanswered fails the test with the routes named.
        func end() {
            TestURLProtocol.handlers.withLockUnchecked { $0[owner] = nil }
            TestURLProtocol.scoped.withLockUnchecked { $0.remove(owner) }
            TestURLProtocol.lastRequest.withLockUnchecked { $0[owner] = nil }
            let routes = TestURLProtocol.unplanned.withLockUnchecked { $0.removeValue(forKey: owner) ?? [] }
            #expect(routes.isEmpty, "the handler did not answer \(routes.joined(separator: ", "))")
        }

        /// Waits until nothing new has reached this scope for `quiet`, and never less than
        /// `quiet` from the call itself: work a test just started (a load its screen triggers
        /// on the way out) has time to ask, so none of it outlives the handler that answers it.
        func settle(quiet: Duration = .milliseconds(400), timeout: Duration = .seconds(5)) async -> Bool {
            let started = ContinuousClock.now
            let deadline = started.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if ContinuousClock.now - started >= quiet, TestURLProtocol.isQuiet(owner, for: quiet) {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return TestURLProtocol.isQuiet(owner, for: quiet)
        }
    }

    /// Whether this test's requests have stopped for `duration`.
    private static func isQuiet(_ owner: String, for duration: Duration) -> Bool {
        guard let last = lastRequest.withLockUnchecked({ $0[owner] }) else { return true }
        return ContinuousClock.now - last >= duration
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
        Self.lastRequest.withLockUnchecked { $0[owner] = .now }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch let unplanned as UnplannedRoute {
            Self.report(unplanned.route, to: owner)
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// A route nobody planned belongs to the test whose session asked: its scope fails with
    /// it. A test that installed a handler without a scope has nobody to report to, so the
    /// route fails the run here rather than passing silently.
    private static func report(_ route: String, to owner: String) {
        let hasScope = scoped.withLockUnchecked { $0.contains(owner) }
        guard hasScope else {
            Issue.record(Comment(rawValue: "unexpected request: \(route) (install handlers with TestURLProtocol.routeScope)"))
            return
        }
        unplanned.withLockUnchecked { $0[owner, default: []].append(route) }
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

/// The answer to `GET …/trace-page`: `trace` as the only page of `session`'s history.
func mockTracePageResponse(
    session: Session,
    trace: [TraceEvent],
    for request: URLRequest
) throws -> (Data, HTTPURLResponse) {
    struct Payload: Encodable {
        let session: Session
        let trace: [TraceEvent]
        let page: TracePageMetadata
        let metrics: TracePageMetrics
    }
    return try mockJSONResponse(
        encoding: Payload(
            session: session,
            trace: trace,
            page: TracePageMetadata(
                hasOlder: false,
                olderCursor: nil,
                traceVersion: "v1",
                previewBytes: 4_096,
                staleCursor: false
            ),
            metrics: TracePageMetrics(
                rawEntryCount: trace.count,
                traceEventCount: trace.count,
                selectedRawEntryCount: trace.count,
                jsonlBytes: 1,
                scannedBytes: 1,
                readMs: 0,
                parseMs: 0,
                selectMs: 0,
                formatMs: 0,
                previewMs: 0,
                jsonBytes: nil,
                gzipBytes: nil,
                stringifyMs: nil,
                gzipMs: nil
            )
        ),
        for: request
    )
}

/// `body` with `status` and `contentType`, the answer to one request: for a route that
/// serves bytes rather than JSON.
func mockBinaryResponse(
    status: Int = 200,
    contentType: String,
    body: Data,
    for request: URLRequest
) throws -> (Data, HTTPURLResponse) {
    let response = (try #require(HTTPURLResponse(
        url: request.url ?? URL(fileURLWithPath: "/"),
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": contentType, "Content-Length": "\(body.count)"]
    )))
    return (body, response)
}

/// A page test's routes, over the app's own refreshes: `answer` gets the routes the test
/// scripts, the ones it leaves out answer as an unreachable server does, and a route
/// outside both throws `UnplannedRoute`, which the test's `TestURLProtocol.routeScope`
/// fails with. `{ _ in nil }` is a server that refuses everything.
func mockPageRoutes(
    _ answer: @escaping (URLRequest) throws -> (Data, HTTPURLResponse)?
) -> TestURLProtocol.Handler {
    { request in
        if let answered = try answer(request) { return answered }
        if let background = try unreachableBackgroundAnswer(request) { return background }
        throw TestURLProtocol.UnplannedRoute(
            route: "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "no url")"
        )
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
        "/models",
        "/agents",
    ].contains(path)
        || path.hasSuffix("/git/status")
        || path.hasSuffix("/paths")
        || path.hasSuffix("/trace-page")
        || path.hasSuffix("/server/resources/skills")
        || path.hasSuffix("/server/resources/extensions")
    guard isBackground else { return nil }
    throw URLError(.cannotConnectToHost)
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
