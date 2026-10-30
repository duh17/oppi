import Foundation
import Testing
@testable import Oppi

/// The store over the real `APIClient` transport and a scripted HTTP server:
/// what goes on the wire for Server Metrics, and what a 409 `revision_conflict`
/// does to the row.
@Suite("Settings over the real transport", .serialized)
@MainActor
struct SettingsServerTransportTests {
    private let enabled = SettingsCatalog.serverMetricsEnabled

    private func makeStore(_ server: ScriptedMetricsServer) -> SettingsStore {
        let client = ScriptedMetricsServer.makeClient()
        return SettingsStore(serverId: "s1", server: ServerAdapter { _ in client })
    }

    @Test("A 409 revision_conflict reloads the setting and says it changed elsewhere, with nothing to retry")
    func conflictReloadsTheStoredValue() async {
        let server = ScriptedMetricsServer(enabled: false, revision: 4)
        let store = makeStore(server)
        _ = store.read(enabled)
        #expect(await waitForMainActorCondition { store.read(enabled).current != nil })
        #expect(store.read(enabled) == .value(false, revision: 4))

        // Another device saves between this device's load and its save.
        server.changeElsewhere()
        let latest = await store.set(enabled, true).value

        #expect(latest == .failed(last: false, reason: "Changed on another device; showing the latest."))
        #expect(!store.canRetry(id: enabled.id))
        #expect(server.log == ["GET", "PUT base=4 enabled=true", "GET"])
    }

    @Test("A save sends the revision it loaded and takes the revision the server answers")
    func saveSendsTheLoadedRevision() async {
        let server = ScriptedMetricsServer(enabled: false, revision: 4)
        let store = makeStore(server)
        _ = store.read(enabled)
        #expect(await waitForMainActorCondition { store.read(enabled).current != nil })

        _ = await store.set(enabled, true).value
        _ = await store.set(enabled, false).value

        #expect(server.log == ["GET", "PUT base=4 enabled=true", "PUT base=5 enabled=false"])
        #expect(store.read(enabled) == .value(false, revision: 6))
    }

    @Test("A server that sends no revision is written without one")
    func unrevisionedServer() async {
        let server = ScriptedMetricsServer(enabled: false, revision: nil)
        let store = makeStore(server)
        _ = store.read(enabled)
        #expect(await waitForMainActorCondition { store.read(enabled).current != nil })

        _ = await store.set(enabled, true).value

        #expect(server.log == ["GET", "PUT enabled=true"])
        #expect(store.read(enabled) == .value(true, revision: nil))
    }

    @Test("Durable Sessions saves on its own route, and a 409 there reloads it too")
    func durableSessionsRoute() async {
        let durable = SettingsCatalog.durableSessionsEnabled
        let server = ScriptedMetricsServer(enabled: false, revision: 2)
        let store = makeStore(server)
        _ = store.read(durable)
        #expect(await waitForMainActorCondition { store.read(durable).current != nil })

        _ = await store.set(durable, true).value
        server.changeElsewhere()
        let latest = await store.set(durable, false).value

        #expect(server.log == ["GET", "PUT base=2 enabled=true", "PUT base=3 enabled=false", "GET"])
        #expect(Set(server.paths) == ["/server/durable-sessions/settings"])
        #expect(latest == .failed(last: true, reason: "Changed on another device; showing the latest."))
    }
}

/// `GET`/`PUT /server/metrics/settings` with optimistic concurrency, as the
/// server does it: a `baseRevision` that is not the stored revision is a 409.
/// The script is the server's state and a log of the requests it saw.
private final class ScriptedMetricsServer: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var revision: Int?
    private var requests: [String] = []
    private var requestPaths: [String] = []

    init(enabled: Bool, revision: Int?) {
        self.enabled = enabled
        self.revision = revision
        MetricsURLProtocol.server = self
    }

    /// One line per request: `GET`, or `PUT` with what it carried.
    var log: [String] { lock.withLock { requests } }
    /// The path of every request, in order.
    var paths: [String] { lock.withLock { requestPaths } }

    /// Another device saves: the revision moves on.
    func changeElsewhere() {
        lock.withLock { revision = (revision ?? 0) + 1 }
    }

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetricsURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(MetricsURLProtocol.host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    /// The answer to one request: a status and a JSON body.
    func answer(method: String?, path: String, body: Data) -> (status: Int, json: [String: Any]) {
        lock.withLock {
            requestPaths.append(path)
            if method == "PUT" {
                let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let base = sent["baseRevision"] as? Int
                var entry = "PUT"
                if let base { entry += " base=\(base)" }
                if let value = sent["enabled"] as? Bool { entry += " enabled=\(value)" }
                requests.append(entry)
                if let base, base != revision {
                    var current: [String: Any] = ["enabled": enabled]
                    if let revision { current["revision"] = revision }
                    return (409, ["error": "settings revision conflict", "code": "revision_conflict", "current": current])
                }
                if let value = sent["enabled"] as? Bool { enabled = value }
                if let revision { self.revision = revision + 1 }
            } else {
                requests.append("GET")
            }
            var json: [String: Any] = ["enabled": enabled]
            if let revision { json["revision"] = revision }
            return (200, json)
        }
    }
}

private final class MetricsURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "metrics-settings.test"
    nonisolated(unsafe) static var server: ScriptedMetricsServer?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, json) = Self.server?.answer(method: request.httpMethod, path: request.url?.path ?? "", body: Self.bodyData(request)) ?? (500, [:])
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol a request body as a stream.
    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
