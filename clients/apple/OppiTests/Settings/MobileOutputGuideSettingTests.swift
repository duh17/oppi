import Foundation
import Testing
import UIKit
@testable import Oppi

/// The Mobile Output Guide is a declared server setting: its route, over the real
/// `APIClient` transport and a scripted server, and the Server Settings switch that
/// shows it. What the switch shows while the save is out, after a failure, and after a
/// revision conflict is the store's behavior for every declared setting.
@Suite("Mobile Output Guide setting", .serialized)
@MainActor
struct MobileOutputGuideSettingTests {
    private let guide = SettingsCatalog.mobileOutputGuideEnabled

    private func makeStore(_ server: ScriptedGuideServer) throws -> SettingsStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideURLProtocol.self]
        GuideURLProtocol.server = server
        let client = APIClient(baseURL: try #require(URL(string: "https://guide.test:7749")), token: "sk_test", configuration: configuration)
        return SettingsStore(serverId: "guide-server", server: ServerAdapter { _ in client })
    }

    private func loaded(_ store: SettingsStore) async {
        _ = store.read(guide)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { store.read(guide).current != nil })
    }

    @Test("The new value shows while the save is out, then the stored value with its revision")
    func savingShowsTheNewValueUntilItSettles() async throws {
        let server = ScriptedGuideServer(enabled: false, revision: 3)
        let store = try makeStore(server)
        await loaded(store)
        #expect(store.read(guide) == .value(false, revision: 3))

        server.holdSaves()
        let save = store.set(guide, true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { store.read(guide).isSaving })
        #expect(store.read(guide) == .saving(shown: true, previous: false))
        #expect(!store.read(guide).canBeginSaving)

        server.releaseSaves()
        let settled = await save.value
        #expect(server.saves == ["true@3"])
        #expect(settled == .value(true, revision: 4))
        #expect(store.read(guide) == .value(true, revision: 4))
    }

    @Test("A failed save puts the old value back with the reason, and Retry saves it again")
    func failedSaveRevertsAndRetries() async throws {
        let server = ScriptedGuideServer(enabled: false, revision: 3)
        let store = try makeStore(server)
        await loaded(store)
        server.failNextSave()

        let failed = await store.set(guide, true).value

        #expect(failed == .failed(last: false, reason: "The server said no."))
        #expect(store.canRetry(id: guide.id))
        await store.retry(id: guide.id).value
        #expect(store.read(guide) == .value(true, revision: 4))
        #expect(server.saves == ["true@3", "true@3"])
    }

    @Test("A revision conflict loads what another device stored, says so, and has nothing to retry")
    func conflictReloads() async throws {
        let server = ScriptedGuideServer(enabled: false, revision: 3)
        let store = try makeStore(server)
        await loaded(store)
        // Another device turned it on after this one loaded.
        server.changeElsewhere(enabled: true)

        let latest = await store.set(guide, false).value

        #expect(latest == .failed(last: true, reason: "Changed on another device; showing the latest."))
        #expect(!store.canRetry(id: guide.id))
        #expect(server.saves == ["false@3"])
        // The next save is based on the revision the reload brought.
        _ = await store.set(guide, false).value
        #expect(server.saves == ["false@3", "false@4"])
        #expect(store.read(guide) == .value(false, revision: 5))
    }

    // MARK: - The Server Settings switch

    private static func guideSwitch(in view: UIView) -> UISwitch? {
        if let toggle = view as? UISwitch, toggle.accessibilityIdentifier == "server.mobileOutputGuide.enabled" { return toggle }
        for subview in view.subviews {
            if let found = guideSwitch(in: subview) { return found }
        }
        return nil
    }

    @Test("Server Settings' switch saves through the page's own server store, against the loaded revision")
    func serverSettingsSwitchSaves() async throws {
        // The app's own refreshes once a server is connected are not what this test is
        // about; they answer as an unreachable server does, and anything else fails.
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        defer { routes.end() }
        let transport = FakeSettingsTransport(fields: ["enabled": false], revision: 4)
        let serverId = "guide-switch-server"
        let client = makeTestURLProtocolClient(host: "ready-server.test")
        let root = try await makeTestAppRoot(
            readyServerId: serverId,
            apiClient: client,
            serverSettings: { id in SettingsStore(serverId: id, server: ServerAdapter { _ in transport }) }
        )
        let server = try #require(root.coordinator.serverStore.server(for: serverId))
        let page = ServerSettingsViewController(server: server, root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2400)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return Self.guideSwitch(in: page.view)?.isEnabled == true
        })
        let toggle = try #require(Self.guideSwitch(in: page.view))
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !transport.saves.isEmpty })
        #expect(transport.saves.first == .init(endpoint: .mobileOutputGuide, fields: ["enabled": true], baseRevision: 4))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            root.coordinator.settings(for: serverId).read(SettingsCatalog.mobileOutputGuideEnabled) == .value(true, revision: 5)
        })
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
