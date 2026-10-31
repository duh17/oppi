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
        var roster: DeviceRosterAnswers
        /// The app's own connected-server refreshes, answered for this test only.
        var routes: TestURLProtocol.RouteScope
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
    private func makeHarness(failRevokes: Bool = false, failReads: Bool = false) async throws -> Harness {
        let roster = DeviceRosterAnswers(failRevokes: failRevokes, failReads: failReads)
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            try roster.answer(for: request)
        })
        let serverA = try makeServer("server-a", order: 0, deviceId: "dev-me")
        let serverB = try makeServer("server-b", order: 1, deviceId: nil)
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([serverA, serverB])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        for server in [serverA, serverB] {
            coordinator.ensureConnection(for: server).setAPIClientForTesting(
                makeTestURLProtocolClient(host: "\(server.id).devices.test")
            )
        }
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
        return Harness(root: root, page: page, model: model, window: window, roster: roster, routes: routes)
    }

    private func hide(_ harness: Harness) {
        harness.window.isHidden = true
        harness.window.rootViewController = nil
        harness.routes.end()
    }

    private struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }

    private func row(_ id: String, in h: Harness) throws -> PairedDeviceRoster.Row {
        let rows = PairedDeviceRoster.rows(from: h.model.pairedDevices ?? [], currentDeviceId: "dev-me")
        return try #require(rows.first { $0.id == id })
    }

    @Test("A device list that cannot be read says so once, in the list's own row")
    func offlineSaysItOnce() async throws {
        let h = try await makeHarness(failReads: true)
        defer { hide(h) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !h.page.isLoading })
        #expect(h.page.collectionView.numberOfItems(inSection: 0) == 1, "one row: the list's state")
        #expect(h.page.shownItems.isEmpty, "the failure is not a page item")
        let state = try #require(h.page.sections().first?.state)
        guard case .failed(let title, let reason, let retry) = state.state else {
            throw TestFailure("the offline list is not the failed row")
        }
        #expect(title == "Couldn't Load Devices")
        #expect(reason == "Server is offline")
        #expect(retry != nil)
        #expect(state.identifier == "server.pairedDevices.state")
    }

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

        let confirmation = ServerPairedDevicesViewController.revocation(for: other)
        let alert = confirmation.present(from: h.page, anchor: nil) {}

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
        #expect(h.roster.revokes.isEmpty)
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

        #expect(h.roster.revokes == ["server-a.devices.test DELETE /auth/devices/dev-1"])
        let rows = PairedDeviceRoster.rows(from: h.model.pairedDevices ?? [], currentDeviceId: "dev-me")
        #expect(rows.map(\.id) == ["dev-me", "dev-2"])
        #expect(h.model.pairedDevicesError == nil)
    }

    @Test("A model never revokes this device, even when asked to")
    func modelRefusesThisDevice() async throws {
        let h = try await makeHarness()
        defer { hide(h) }

        await h.model.revokeDevice(try row("dev-me", in: h))

        #expect(h.roster.revokes.isEmpty)
    }

    @Test("A refused Revoke keeps the device listed and says why")
    func refusedRevokeSaysWhy() async throws {
        let h = try await makeHarness(failRevokes: true)
        defer { hide(h) }

        await h.page.revoke(try row("dev-1", in: h))

        let rows = PairedDeviceRoster.rows(from: h.model.pairedDevices ?? [], currentDeviceId: "dev-me")
        #expect(rows.map(\.id).contains("dev-1"))
        #expect(h.model.pairedDevicesError == "Not allowed.")
        // A load still in flight would show its loading row instead, so the page has
        // to have settled before its row says why.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            !h.page.isLoading && !h.model.isLoadingPairedDevices
        })
        // The refusal is the list's own failed row, over the devices it kept.
        let state = try #require(h.page.sections().first?.state)
        guard case .failed(let title, let reason, let retry) = state.state else {
            throw TestFailure("the refusal is not the failed row")
        }
        #expect(title == "Couldn't Load Devices")
        #expect(reason == "Not allowed.")
        #expect(retry != nil, "the row offers a Retry")
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

/// `GET /auth/devices` and `DELETE /auth/devices/<id>` per test, logging each revoke by
/// host, so one test's roster is never another's.
private final class DeviceRosterAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private let failing: Bool
    private let failsReads: Bool
    private var log: [String] = []
    private var deleted: Set<String> = []

    init(failRevokes: Bool, failReads: Bool) {
        failing = failRevokes
        failsReads = failReads
    }

    var revokes: [String] { lock.withLock { log } }

    func answer(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        guard request.httpMethod == "DELETE" else {
            guard !failsReads else {
                return try mockJSONResponse(status: 500, json: #"{"error":"Server is offline"}"#, for: request)
            }
            let gone = lock.withLock { deleted }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let rows = [
                Row(id: "dev-me", name: "This phone", createdAt: now - 9_000, lastUsedAt: now, keyEnrolled: true),
                Row(id: "dev-1", name: "Chen's iPad", createdAt: now - 30_000, lastUsedAt: now - 5_000, keyEnrolled: true),
                Row(id: "dev-2", name: "oppi CLI", createdAt: now - 60_000, lastUsedAt: nil, keyEnrolled: false),
            ].filter { !gone.contains($0.id) }
            return try mockJSONResponse(encoding: Roster(devices: rows), for: request)
        }
        let id = url.lastPathComponent
        let refuse = lock.withLock {
            log.append("\(url.host ?? "") DELETE \(url.path)")
            guard !failing else { return true }
            deleted.insert(id)
            return false
        }
        guard !refuse else {
            return try mockJSONResponse(status: 403, json: #"{"error":"Not allowed."}"#, for: request)
        }
        return try mockJSONResponse(status: 200, json: "{}", for: request)
    }

    private struct Roster: Encodable {
        let devices: [Row]
    }

    private struct Row: Encodable {
        let id: String
        let name: String
        let scope = "device"
        let createdAt: Int64
        let lastUsedAt: Int64?
        let keyEnrolled: Bool
    }
}
