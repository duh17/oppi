import Foundation
import Testing
@testable import Oppi

@Suite("Desktop live view stream client")
struct DesktopLiveViewStreamClientTests {
    @Test @MainActor func upgradeHTTP404StopsWithFatalError() async {
        let client = makeClient(
            receive: { throw URLError(.badServerResponse) },
            status: 404
        )
        guard let client else {
            Issue.record("expected stream client")
            return
        }
        var events: [DesktopLiveViewStreamClient.Event] = []
        for await event in client.connect() {
            events.append(event)
        }
        guard case .error(let error) = events.first else {
            Issue.record("expected fatal error, got \(events)")
            return
        }
        #expect(error.fatal == true)
        #expect(events.count == 1)
    }

    @Test @MainActor func upgradeHTTP401RefreshesAndRetries() async {
        let tokens = TokenLog()
        let helloOnce = OnceFlag()
        let client = DesktopLiveViewStreamClient(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: "at_old",
            tlsCertFingerprint: nil,
            currentTokenProvider: { "at_old" },
            refreshTokenProvider: { "at_new" },
            webSocketFactory: { request in
                tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                if tokens.count == 1 {
                    return mockTransport(
                        receive: { throw URLError(.userAuthenticationRequired) },
                        send: { _ in },
                        status: 401
                    )
                }
                return mockTransport(
                    receive: {
                        if helloOnce.consume() {
                            return .string("""
                            {"type":"hello","version":1,"features":["h264-avcc"],"grantId":"g","deviceId":"d","surface":{"windowId":1,"title":"Notes"}}
                            """)
                        }
                        try await Task.sleep(for: .seconds(30))
                        throw CancellationError()
                    },
                    send: { _ in },
                    status: 101
                )
            }
        )
        guard let client else {
            Issue.record("expected stream client")
            return
        }
        var sawHello = false
        let consume = Task {
            for await event in client.connect() {
                if case .hello = event {
                    sawHello = true
                    break
                }
            }
        }
        await waitUntil(timeoutMs: 2000) { sawHello }
        consume.cancel()
        client.disconnect()
        #expect(sawHello)
        #expect(tokens.values.contains { $0.contains("at_old") })
        #expect(tokens.values.contains { $0.contains("at_new") })
    }

    @Test @MainActor func failedAckSendClosesNonFatally() async {
        let mediaOnce = OnceFlag()
        let client = makeClient(
            receive: {
                if mediaOnce.consume() {
                    return .data(DesktopViewMediaCodec.encodeFrame(
                        header: DesktopViewMediaHeader(
                            version: 1,
                            keyframe: true,
                            frameId: 1,
                            capturedAtMs: 1,
                            width: 16,
                            height: 9,
                            payloadBytes: 5
                        ),
                        payload: Data([0, 0, 0, 1, 0x65])
                    ))
                }
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            },
            send: { _ in throw URLError(.networkConnectionLost) },
            status: 101
        )
        guard let client else {
            Issue.record("expected stream client")
            return
        }
        var events: [DesktopLiveViewStreamClient.Event] = []
        for await event in client.connect() {
            events.append(event)
            if events.count > 4 { break }
        }
        client.disconnect()
        #expect(events.contains { if case .closed = $0 { true } else { false } })
        #expect(!events.contains { if case .error(let error) = $0 { error.fatal == true } else { false } })
    }
}

@MainActor
private func makeClient(
    receive: @escaping () async throws -> URLSessionWebSocketTask.Message,
    send: @escaping (URLSessionWebSocketTask.Message) async throws -> Void = { _ in },
    status: Int
) -> DesktopLiveViewStreamClient? {
    DesktopLiveViewStreamClient(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        token: "at_test",
        tlsCertFingerprint: nil,
        webSocketFactory: { _ in
            mockTransport(receive: receive, send: send, status: status)
        }
    )
}

@MainActor
private func mockTransport(
    receive: @escaping () async throws -> URLSessionWebSocketTask.Message,
    send: @escaping (URLSessionWebSocketTask.Message) async throws -> Void,
    status: Int
) -> DesktopLiveViewWebSocketTransport {
    let url = URL(string: "http://127.0.0.1:9/desktop/view/stream")!
    return DesktopLiveViewWebSocketTransport(
        resume: {},
        receive: receive,
        send: send,
        cancel: { _, _ in },
        response: {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        },
        closeCode: { .invalid },
        closeReason: { nil }
    )
}

@MainActor
private func waitUntil(timeoutMs: Int, _ condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}

private final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored.count
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}
