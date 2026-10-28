import Foundation
import Testing
@testable import Oppi

/// The store over the real `APIClient` transport and a scripted HTTP server:
/// what goes on the wire, and what a 409 `revision_conflict` does to the row.
@Suite("Settings over the real transport", .serialized)
@MainActor
struct SettingsServerTransportTests {
    private let model = SettingsCatalog.autoNameServerModel
    private let enabled = SettingsCatalog.autoNameServerEnabled

    private func makeStore(_ server: ScriptedAutoTitleServer) -> SettingsStore {
        let client = ScriptedAutoTitleServer.makeClient(server)
        return SettingsStore(
            device: DeviceAdapter(defaults: makeSettingsDefaults()),
            server: ServerAdapter { _ in client }
        )
    }

    @Test("A 409 revision_conflict reloads the setting instead of failing it")
    func conflictReloadsTheStoredValue() async {
        let server = ScriptedAutoTitleServer(enabled: false, model: "anthropic/claude-haiku-5", revision: 4)
        let store = makeStore(server)
        store.attach(serverId: "s1")
        _ = store.read(model)
        #expect(await waitForMainActorCondition { store.read(model).current != nil })
        #expect(store.read(model) == .value("anthropic/claude-haiku-5", revision: 4))

        // Another device saves between this device's load and its save.
        server.changeElsewhere(model: "openai/gpt-5")
        await store.set(model, "google/gemini-2.5-pro").value

        #expect(store.read(model) == .value("openai/gpt-5", revision: 5))
        #expect(store.failureReason(id: model.id) == nil)
        #expect(server.log == [
            "GET", "PUT base=4 model=google/gemini-2.5-pro", "GET",
        ])
    }

    @Test("A save sends the revision it loaded, only its own field, and takes the revision the server answers")
    func saveSendsTheLoadedRevision() async {
        let server = ScriptedAutoTitleServer(enabled: false, model: "anthropic/claude-haiku-5", revision: 4)
        let store = makeStore(server)
        store.attach(serverId: "s1")
        _ = (store.read(enabled), store.read(model))
        #expect(await waitForMainActorCondition { store.read(enabled).current != nil })

        await store.set(enabled, true).value
        await store.set(model, "openai/gpt-5-mini").value

        #expect(server.log == ["GET", "PUT base=4 enabled=true", "PUT base=5 model=openai/gpt-5-mini"])
        #expect(store.read(enabled) == .value(true, revision: 6))
        #expect(store.read(model) == .value("openai/gpt-5-mini", revision: 6))
    }

    @Test("A server that sends no revision is written without one")
    func unrevisionedServer() async {
        let server = ScriptedAutoTitleServer(enabled: false, model: "anthropic/claude-haiku-5", revision: nil)
        let store = makeStore(server)
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        #expect(await waitForMainActorCondition { store.read(enabled).current != nil })

        await store.set(enabled, true).value

        #expect(server.log == ["GET", "PUT enabled=true"])
        #expect(store.read(enabled) == .value(true, revision: nil))
    }
}

/// `GET`/`PUT /server/auto-title` with optimistic concurrency, as the server
/// does it: a `baseRevision` that is not the stored revision is a 409. The
/// script is the server's state and a log of the requests it saw.
private final class ScriptedAutoTitleServer: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var model: String
    private var revision: Int?
    private var requests: [String] = []

    init(enabled: Bool, model: String, revision: Int?) {
        self.enabled = enabled
        self.model = model
        self.revision = revision
        AutoTitleURLProtocol.server = self
    }

    /// One line per request: `GET`, or `PUT` with what it carried.
    var log: [String] { lock.withLock { requests } }

    func changeElsewhere(model: String) {
        lock.withLock {
            self.model = model
            revision = (revision ?? 0) + 1
        }
    }

    static func makeClient(_ server: ScriptedAutoTitleServer) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AutoTitleURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(AutoTitleURLProtocol.host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    /// The answer to one request: a status and a JSON body.
    func answer(method: String?, body: Data) -> (status: Int, json: [String: Any]) {
        lock.withLock {
            if method == "PUT" {
                let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let base = sent["baseRevision"] as? Int
                var entry = "PUT"
                if let base { entry += " base=\(base)" }
                if let value = sent["enabled"] as? Bool { entry += " enabled=\(value)" }
                if let value = sent["model"] as? String { entry += " model=\(value)" }
                requests.append(entry)
                if let base, base != revision {
                    var current: [String: Any] = ["enabled": enabled, "model": model]
                    if let revision { current["revision"] = revision }
                    return (409, ["error": "settings revision conflict", "code": "revision_conflict", "current": current])
                }
                if let value = sent["enabled"] as? Bool { enabled = value }
                if let value = sent["model"] as? String { model = value }
                if let revision { self.revision = revision + 1 }
            } else {
                requests.append("GET")
            }
            var json: [String: Any] = ["enabled": enabled, "model": model]
            if let revision { json["revision"] = revision }
            return (200, json)
        }
    }
}

private final class AutoTitleURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "auto-title.test"
    nonisolated(unsafe) static var server: ScriptedAutoTitleServer?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, json) = Self.server?.answer(method: request.httpMethod, body: Self.bodyData(request)) ?? (500, [:])
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
