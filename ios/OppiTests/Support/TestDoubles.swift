import Foundation
@testable import Oppi

/// Shared URLProtocol test double for intercepting URLSession traffic.
/// Configure per-test via `TestURLProtocol.handler`.
class TestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
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
            if streamsCreated >= expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
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
