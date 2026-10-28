import Foundation
import Testing
@testable import Oppi

/// Mobile Output Guide's save on a server's `ServerSettingsModel`: what the switch shows
/// while the save is out, after a failure, and after a revision conflict.
@Suite("Server Settings model: Mobile Output Guide", .serialized)
@MainActor
struct ServerSettingsModelTests {
    private func makeModel(_ server: ScriptedGuideServer) throws -> ServerSettingsModel {
        let paired = try #require(PairedServer(
            from: ServerCredentials(host: "guide.test", port: 7749, token: "sk_test", name: "guide", scheme: .https, serverFingerprint: "guide-server"),
            sortOrder: 0
        ))
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([paired])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideURLProtocol.self]
        GuideURLProtocol.server = server
        coordinator.ensureConnection(for: paired).setAPIClientForTesting(
            APIClient(baseURL: try #require(URL(string: "https://guide.test:7749")), token: "sk_test", configuration: configuration)
        )
        return ServerSettingsModel(coordinator: coordinator, serverId: paired.id)
    }

    @Test("The new value shows disabled while the save is out, then the stored value with its revision")
    func savingShowsTheNewValueUntilItSettles() async throws {
        let server = ScriptedGuideServer(enabled: false, revision: 3)
        let model = try makeModel(server)
        await model.reloadMobileOutputGuide()
        #expect(model.mobileOutputGuideState == .available(enabled: false, revision: 3, error: nil))

        server.holdSaves()
        let save = Task { await model.setMobileOutputGuide(true) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { model.isSavingMobileOutputGuide })
        #expect(model.pendingMobileOutputGuide == true)
        // A second tap while it saves is ignored.
        await model.setMobileOutputGuide(false)

        server.releaseSaves()
        await save.value
        #expect(server.saves == ["true@3"])
        #expect(!model.isSavingMobileOutputGuide)
        #expect(model.pendingMobileOutputGuide == nil)
        #expect(model.mobileOutputGuideState == .available(enabled: true, revision: 4, error: nil))
    }

    @Test("A failed save puts the old value back and keeps the reason")
    func failedSaveReverts() async throws {
        let server = ScriptedGuideServer(enabled: false, revision: 3)
        let model = try makeModel(server)
        await model.reloadMobileOutputGuide()
        server.failNextSave()

        await model.setMobileOutputGuide(true)

        #expect(model.pendingMobileOutputGuide == nil)
        #expect(!model.isSavingMobileOutputGuide)
        #expect(model.mobileOutputGuideState == .available(enabled: false, revision: 3, error: "The server said no."))
    }

    @Test("A revision conflict loads what another device stored and clears the pending value")
    func conflictReloads() async throws {
        let server = ScriptedGuideServer(enabled: false, revision: 3)
        let model = try makeModel(server)
        await model.reloadMobileOutputGuide()
        // Another device turned it on after this one loaded.
        server.changeElsewhere(enabled: true)

        await model.setMobileOutputGuide(false)

        #expect(model.pendingMobileOutputGuide == nil)
        #expect(!model.isSavingMobileOutputGuide)
        #expect(model.mobileOutputGuideState == .available(enabled: true, revision: 4, error: nil))
        #expect(server.saves == ["false@3"])
    }
}

/// `GET`/`PUT /server/mobile-output-guide` with a revision, as the server answers it.
private final class ScriptedGuideServer: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var revision: Int
    private var failing = false
    private var held: [GuideURLProtocol] = []
    private var isHolding = false
    private var log: [String] = []

    init(enabled: Bool, revision: Int) {
        self.enabled = enabled
        self.revision = revision
    }

    var saves: [String] { lock.withLock { log } }
    func failNextSave() { lock.withLock { failing = true } }
    func holdSaves() { lock.withLock { isHolding = true } }
    func changeElsewhere(enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            revision += 1
        }
    }

    func releaseSaves() {
        let waiting = lock.withLock {
            isHolding = false
            defer { held = [] }
            return held
        }
        for request in waiting { request.answer() }
    }

    /// Whether a PUT waits for `releaseSaves`.
    func hold(_ request: GuideURLProtocol) -> Bool {
        lock.withLock {
            guard isHolding else { return false }
            held.append(request)
            return true
        }
    }

    func respond(method: String?, body: Data) -> (status: Int, json: [String: Any]) {
        lock.withLock {
            guard method == "PUT" else { return (200, ["enabled": enabled, "revision": revision]) }
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let base = sent["baseRevision"] as? Int ?? -1
            let value = sent["enabled"] as? Bool ?? false
            log.append("\(value)@\(base)")
            if failing {
                failing = false
                return (500, ["error": "The server said no."])
            }
            if base != revision {
                return (409, ["error": "revision conflict", "code": "revision_conflict"])
            }
            enabled = value
            revision += 1
            return (200, ["enabled": enabled, "revision": revision])
        }
    }
}

private final class GuideURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: ScriptedGuideServer?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "guide.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.httpMethod == "PUT", Self.server?.hold(self) == true { return }
        answer()
    }

    override func stopLoading() {}

    func answer() {
        let (status, json) = Self.server?.respond(method: request.httpMethod, body: Self.bodyData(request)) ?? (500, [:])
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

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
