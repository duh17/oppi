import Foundation
import Testing
import UIKit
@testable import Oppi

/// Paired Devices: Revoke asks first, then reaches exactly the device the person
/// chose on the server the page is pinned to, and this device never offers it.
@Suite("Paired Devices page", .serialized)
@MainActor
struct ServerPairedDevicesPageTests {
    private struct Harness {
        var root: AppRootEnvironment
        var page: ServerPairedDevicesViewController
        var model: ServerSettingsModel
        var window: UIWindow
    }

    private func makeServer(_ id: String, order: Int, deviceId: String?) throws -> PairedServer {
        var server = try #require(PairedServer(
            from: ServerCredentials(host: "\(id).devices.test", port: 7749, token: "sk_test", name: id, scheme: .https, serverFingerprint: id),
            sortOrder: order
        ))
        if let deviceId {
            server.deviceCredential = DeviceCredential(
                deviceId: deviceId, accessToken: "tok", expiresAt: Int64.max, refreshChallenge: nil
            )
        }
        return server
    }

    /// Two paired servers; the page is for `server-a`, whose own device is `dev-me`.
    private func makeHarness(failRevokes: Bool = false) async throws -> Harness {
        let serverA = try makeServer("server-a", order: 0, deviceId: "dev-me")
        let serverB = try makeServer("server-b", order: 1, deviceId: nil)
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([serverA, serverB])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceRosterProtocol.self]
        for server in [serverA, serverB] {
            coordinator.ensureConnection(for: server).setAPIClientForTesting(APIClient(
                baseURL: try #require(URL(string: "https://\(server.id).devices.test:7749")),
                token: "sk_test",
                configuration: configuration
            ))
        }
        DeviceRosterProtocol.reset(failRevokes: failRevokes)
        let root = makeTestAppRoot(coordinator: coordinator)
        let model = ServerSettingsModel(coordinator: coordinator, serverId: serverA.id)
        await model.reloadPairedDevices()
        let page = ServerPairedDevicesViewController(model: model, server: serverA, root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        page.view.layoutIfNeeded()
        return Harness(root: root, page: page, model: model, window: window)
    }

    private func hide(_ harness: Harness) {
        DeviceRosterProtocol.reset(failRevokes: false)
        harness.window.isHidden = true
        harness.window.rootViewController = nil
    }

    private func row(_ id: String, in h: Harness) throws -> PairedDeviceRoster.Row {
        guard case .loaded(let rows, _) = h.model.pairedDevicesState(currentDeviceId: "dev-me") else {
            throw TestFailure("roster not loaded")
        }
        return try #require(rows.first { $0.id == id })
    }

    private struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }

    @Test("This device is marked and offers no Revoke; every other device does")
    func thisDeviceOffersNoRevoke() async throws {
        let h = try await makeHarness()
        defer { hide(h) }

        let me = try row("dev-me", in: h)
        let other = try row("dev-1", in: h)
        #expect(me.isThisDevice && !me.canRevoke)
        #expect(other.canRevoke)
        #expect(h.page.trailingSwipeActions(for: .device("dev-me")) == nil)
        let swipe = try #require(h.page.trailingSwipeActions(for: .device("dev-1")))
        #expect(swipe.actions.map(\.title) == ["Revoke"])
        #expect(!swipe.performsFirstActionWithFullSwipe)

        // The visible Revoke buttons: one per other device, none for this one.
        let ids = Self.buttonIdentifiers(in: h.page.view)
        #expect(ids.contains("server.pairedDevices.revoke.dev-1"))
        #expect(ids.contains("server.pairedDevices.revoke.dev-2"))
        #expect(!ids.contains("server.pairedDevices.revoke.dev-me"))
    }

    @Test("The sheet names the device and offers a destructive Revoke and a Cancel")
    func theSheetAsksBeforeRevoking() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        let other = try row("dev-1", in: h)

        let alert = ServerPairedDevicesViewController.revocationAlert(for: other) {}

        #expect(alert.title == "Revoke Chen's iPad?")
        #expect(alert.message == "Chen's iPad will lose access immediately. Pair it again to restore access.")
        #expect(alert.actions.map(\.title) == ["Revoke", "Cancel"])
        #expect(alert.actions.map(\.style) == [.destructive, .cancel])
    }

    @Test("Asking to revoke presents the sheet and sends nothing")
    func askingSendsNothing() async throws {
        let h = try await makeHarness()
        defer { hide(h) }

        h.page.confirmRevoke(try row("dev-1", in: h), from: nil)

        let sheet = try #require(h.page.presentedViewController as? UIAlertController)
        #expect(sheet.title == "Revoke Chen's iPad?")
        #expect(DeviceRosterProtocol.revokes.isEmpty)
        // This device's row never asks.
        sheet.dismiss(animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.page.presentedViewController == nil })
        h.page.confirmRevoke(try row("dev-me", in: h), from: nil)
        #expect(h.page.presentedViewController == nil)
    }

    @Test("A confirmed Revoke deletes that device on this page's server only, and the roster drops it")
    func revokeTargetsThePinnedServersDevice() async throws {
        let h = try await makeHarness()
        defer { hide(h) }

        await h.page.revoke(try row("dev-1", in: h))

        #expect(DeviceRosterProtocol.revokes == ["server-a.devices.test DELETE /auth/devices/dev-1"])
        guard case .loaded(let rows, let error) = h.model.pairedDevicesState(currentDeviceId: "dev-me") else {
            throw TestFailure("roster not loaded")
        }
        #expect(rows.map(\.id) == ["dev-me", "dev-2"])
        #expect(error == nil)
    }

    @Test("A model never revokes this device, even when asked to")
    func modelRefusesThisDevice() async throws {
        let h = try await makeHarness()
        defer { hide(h) }

        await h.model.revokeDevice(try row("dev-me", in: h))

        #expect(DeviceRosterProtocol.revokes.isEmpty)
    }

    @Test("A refused Revoke keeps the device listed and says why")
    func refusedRevokeSaysWhy() async throws {
        let h = try await makeHarness(failRevokes: true)
        defer { hide(h) }

        await h.page.revoke(try row("dev-1", in: h))

        guard case .loaded(let rows, let error) = h.model.pairedDevicesState(currentDeviceId: "dev-me") else {
            throw TestFailure("roster not loaded")
        }
        #expect(rows.map(\.id).contains("dev-1"))
        #expect(error == "Not allowed.")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.page.view.layoutIfNeeded()
            return h.page.dataSource?.snapshot().itemIdentifiers.contains(.error) == true
        })
    }

    private static func buttonIdentifiers(in view: UIView) -> Set<String> {
        var found = Set<String>()
        func walk(_ view: UIView) {
            if view is UIButton, let id = view.accessibilityIdentifier { found.insert(id) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
}

/// `GET /auth/devices` and `DELETE /auth/devices/<id>` for the `*.devices.test` hosts,
/// logging each revoke by host.
private final class DeviceRosterProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    nonisolated(unsafe) private static var deleted: Set<String> = []
    nonisolated(unsafe) private static var failing = false

    static var revokes: [String] { lock.withLock { log } }

    static func reset(failRevokes: Bool) {
        lock.withLock {
            log = []
            deleted = []
            failing = failRevokes
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".devices.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let method = request.httpMethod ?? "GET"
        var status = 200
        var body = Data("{}".utf8)
        if method == "DELETE" {
            let id = url.lastPathComponent
            let refuse = Self.lock.withLock {
                Self.log.append("\(url.host ?? "") DELETE \(url.path)")
                if Self.failing { return true }
                Self.deleted.insert(id)
                return false
            }
            if refuse {
                status = 403
                body = Data(#"{"error":"Not allowed."}"#.utf8)
            }
        } else {
            let gone = Self.lock.withLock { Self.deleted }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let devices: [[String: Any]] = [
                ["id": "dev-me", "name": "This phone", "scope": "device", "createdAt": now - 9_000, "lastUsedAt": now, "keyEnrolled": true],
                ["id": "dev-1", "name": "Chen's iPad", "scope": "device", "createdAt": now - 30_000, "lastUsedAt": now - 5_000, "keyEnrolled": true],
                ["id": "dev-2", "name": "oppi CLI", "scope": "device", "createdAt": now - 60_000, "keyEnrolled": false],
            ].filter { !gone.contains($0["id"] as? String ?? "") }
            body = (try? JSONSerialization.data(withJSONObject: ["devices": devices])) ?? body
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
