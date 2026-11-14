import Foundation
import Testing
@testable import Oppi

/// The Godot pane's player link: it attaches first, then renews its access on
/// the open socket as the app's other streams do, and the server's answer
/// goes to the renewer, never to the pane as a link event.
@MainActor
@Suite("GodotPlayerLink")
struct GodotPlayerLinkTests {
    @Test func attachesThenRenewsItsAccessOnTheOpenLink() async throws {
        let clock = ManualRenewalClock()
        let tokens = RenewalTokenSource(expiries: ["at_open": clock.now.addingTimeInterval(600)], fresh: ["at_renewed"])
        let renewer = StreamAuthRenewer(source: tokens.source, streamRole: "test", now: { clock.now }, sleep: clock.sleep)
        let factory = ScriptedGodotLinkSocketFactory()
        let link = GodotPlayerLink(
            url: try #require(URL(string: "wss://studio.example/godot/tide-3fa9c2b1/link?role=player")),
            token: { "at_open" },
            renewer: renewer,
            tlsCertFingerprint: nil,
            tlsServerName: nil,
            tailnetRoute: .direct,
            webSocketFactory: factory.makeTransport
        )
        link.attachment = {
            GodotLinkPlayerMessage.Attach(capabilities: [ClientCapability.godotPane], device: nil, runtimes: [], state: nil)
        }
        var events = 0
        link.onEvent = { _ in events += 1 }
        link.start()
        defer { link.stop() }

        #expect(await waitForMainActorCondition { factory.sockets.count == 1 })
        let socket = try #require(factory.sockets.first)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_open")
        #expect(await waitForMainActorCondition { socket.sentTexts.first?.contains(#""type":"attach""#) == true })

        // A minute before the token expires, the renewal goes out on this socket.
        #expect(await waitForMainActorCondition { clock.sleeps == [540] })
        clock.elapse()
        #expect(await waitForMainActorCondition {
            socket.sentTexts.contains { $0.contains(#""type":"auth_renew""#) && $0.contains("at_renewed") }
        })

        let expiresAtMs = Int64(clock.now.addingTimeInterval(600).timeIntervalSince1970 * 1_000)
        socket.yield(#"{"type":"auth_renew_result","ok":true,"expiresAt":\#(expiresAtMs)}"#)
        #expect(await waitForMainActorCondition { clock.sleeps == [540, StreamAuthRenewer.retryDelay, 540] })
        #expect(events == 0, "The renewal's answer is the renewer's, not a link event")
    }
}

@MainActor
private final class ScriptedGodotLinkSocketFactory {
    private(set) var requests: [URLRequest] = []
    private(set) var sockets: [ScriptedGodotLinkSocket] = []

    func makeTransport(for request: URLRequest) -> PersistentWebSocketTransport {
        let socket = ScriptedGodotLinkSocket()
        requests.append(request)
        sockets.append(socket)
        return socket.transport
    }
}

/// A socket that records what is sent and answers `receive` with what the test yields.
@MainActor
private final class ScriptedGodotLinkSocket {
    private var queued: [String] = []
    private var pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var closed = false
    private(set) var sentTexts: [String] = []

    lazy var transport = PersistentWebSocketTransport(
        identity: self,
        resume: {},
        receive: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.receive()
        },
        send: { [weak self] message in
            if case .string(let text) = message { self?.sentTexts.append(text) }
        },
        cancel: { [weak self] _, _ in self?.close() },
        response: { nil },
        closeCode: { .invalid }
    )

    func yield(_ text: String) {
        if let pending {
            self.pending = nil
            pending.resume(returning: .string(text))
        } else {
            queued.append(text)
        }
    }

    private func receive() async throws -> URLSessionWebSocketTask.Message {
        if closed { throw URLError(.cancelled) }
        if !queued.isEmpty { return .string(queued.removeFirst()) }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    private func close() {
        closed = true
        pending?.resume(throwing: URLError(.cancelled))
        pending = nil
    }
}
