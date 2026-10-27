import Foundation
import Testing
@testable import Oppi

/// Answers every request through `handler` and keeps what it saw. Own state, so
/// suites that share the global mock protocol cannot interleave with it.
private final class UploaderURLProtocol: URLProtocol, @unchecked Sendable {
    struct Seen {
        let path: String
        let body: Data
    }

    nonisolated(unsafe) static var handler: (@Sendable (Int) -> (Int, String))?
    nonisolated(unsafe) static var seen: [Seen] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping @Sendable (Int) -> (Int, String)) {
        lock.withLock {
            seen = []
            Self.handler = handler
        }
    }

    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        let (index, handler) = Self.lock.withLock { () -> (Int, (@Sendable (Int) -> (Int, String))?) in
            Self.seen.append(Seen(path: request.url?.path ?? "", body: body))
            return (Self.seen.count, Self.handler)
        }
        let (status, json) = handler?(index) ?? (500, "")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class DropRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [([String: Int], Int)] = []

    func record(_ response: TelemetryEventUploadResponse, batchSize: Int) {
        lock.withLock { recorded.append((response.dropped, batchSize)) }
    }

    var drops: [([String: Int], Int)] { lock.withLock { recorded } }
}

@Suite("Telemetry event uploader", .serialized)
struct TelemetryEventUploaderTests {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploaderURLProtocol.self]
        return APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "http://localhost:7749")!,
                bearerToken: "sk_test"
            ),
            configuration: config
        )
    }

    private func makeUploader(drops: DropRecorder = DropRecorder()) -> TelemetryEventUploader {
        TelemetryEventUploader(
            isUploadAllowed: { true },
            onDrops: { response, batchSize in drops.record(response, batchSize: batchSize) },
            flushInterval: .seconds(3_600)
        )
    }

    private func event(_ index: Int) -> TelemetryEventPayload {
        TelemetryEventPayload(
            AppTimelineApply(durationMs: 6, items: index, changed: 1),
            ts: 1_793_000_000_000 + Int64(index),
            sessionId: "s1"
        )
    }

    private static func events(in body: Data) -> NSArray? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["events"] as? NSArray
    }

    @Test func postsBufferedEventsToTheEventsEndpoint() async throws {
        UploaderURLProtocol.reset { _ in (200, #"{"ok":true,"accepted":2,"dropped":{}}"#) }
        let uploader = makeUploader()
        await uploader.setUploadClient(makeClient())
        await uploader.enqueue(event(1))
        await uploader.enqueue(event(2))

        await uploader.flush()

        let requests = UploaderURLProtocol.requests
        #expect(requests.count == 1)
        #expect(requests.first?.path == "/telemetry/events")
        let requestBody = try #require(requests.first?.body)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect((body["events"] as? [Any])?.count == 2)
        #expect((body["client"] as? [String: Any])?["kind"] as? String == "ios")
        #expect(await uploader.pendingCount == 0)
    }

    @Test func eventsTheServerRefusedAreReportedAndNotResent() async {
        UploaderURLProtocol.reset { _ in (200, #"{"ok":true,"accepted":1,"dropped":{"unknown_event":2}}"#) }
        let drops = DropRecorder()
        let uploader = makeUploader(drops: drops)
        await uploader.setUploadClient(makeClient())
        for index in 1...3 { await uploader.enqueue(event(index)) }

        await uploader.flush()
        await uploader.flush()

        #expect(drops.drops.count == 1)
        #expect(drops.drops.first?.0 == ["unknown_event": 2])
        #expect(drops.drops.first?.1 == 3)
        #expect(UploaderURLProtocol.requests.count == 1)
        #expect(await uploader.pendingCount == 0)
    }

    @Test func aFailedUploadKeepsTheBatchForTheNextFlush() async {
        UploaderURLProtocol.reset { index in
            index == 1 ? (500, #"{"error":"down"}"#) : (200, #"{"ok":true,"accepted":2,"dropped":{}}"#)
        }
        let uploader = makeUploader()
        await uploader.setUploadClient(makeClient())
        await uploader.enqueue(event(1))
        await uploader.enqueue(event(2))

        await uploader.flush()
        #expect(await uploader.pendingCount == 2)

        await uploader.flush()
        #expect(await uploader.pendingCount == 0)
        let requests = UploaderURLProtocol.requests
        #expect(requests.count == 2)
        #expect(Self.events(in: requests[0].body) == Self.events(in: requests[1].body))
    }

    /// The accepted events are already stored; requeueing them would duplicate them.
    @Test func aSuccessfulUploadWithAnUnreadableBodyIsNotRequeued() async {
        UploaderURLProtocol.reset { _ in (200, "not json") }
        let uploader = makeUploader()
        await uploader.setUploadClient(makeClient())
        await uploader.enqueue(event(1))

        await uploader.flush()
        await uploader.flush()

        #expect(UploaderURLProtocol.requests.count == 1)
        #expect(await uploader.pendingCount == 0)
    }

    @Test func nothingIsBufferedWhileUploadsAreNotAllowed() async {
        UploaderURLProtocol.reset { _ in (200, #"{"ok":true,"accepted":0,"dropped":{}}"#) }
        let uploader = TelemetryEventUploader(isUploadAllowed: { false })
        await uploader.setUploadClient(makeClient())
        await uploader.enqueue(event(1))

        await uploader.flush()

        #expect(await uploader.pendingCount == 0)
        #expect(UploaderURLProtocol.requests.isEmpty)
    }
}
