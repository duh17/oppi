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
        guard let owner, let handler = Self.handlers.withLockUnchecked({ $0[owner] }) else {
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
