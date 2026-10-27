import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Extensions list screen")
struct ServerExtensionsViewControllerTests {
    private let serverId = "extensions-list-server"

    @Test("a row is one button that opens its detail through AppNavigation")
    func rowOpensDetailRoute() async throws {
        let root = try makeRoot()
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.serverResourceStore.replaceExtensions(
            [
                ServerExtensionSummary(
                    id: "workflow", name: "workflow", description: "Coordinates local automation.",
                    kind: .file, provenance: .init(kind: .piAgent, label: "~/.pi/agent/extensions"), path: nil,
                    state: .on, loadError: nil, warnings: [], isRemovable: true
                ),
            ],
            serverId: serverId
        )

        let screen = ServerExtensionsViewController(root: root)
        let window = try show(UINavigationController(rootViewController: screen))
        defer { hide(window) }

        var row: UIButton?
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            row = Self.button(withIdentifier: "extensions.row.workflow", in: screen.view)
            return row != nil
        })
        let button = try #require(row)
        #expect(button.accessibilityLabel == "workflow, ~/.pi/agent/extensions, Enabled")
        #expect(button.accessibilityTraits.contains(.button))

        button.sendActions(for: .touchUpInside)
        #expect(root.navigation.workspaceStackRouteElements == [
            .serverResourceDetail(ServerResourceDetailNavTarget(serverId: serverId, kind: .extension, resourceId: "workflow")),
        ])
    }

    @Test("the screen follows the active server and loads its catalog only while it is showing")
    func reloadsWhenActiveServerChanges() async throws {
        let root = try makeRoot()
        let coordinator = root.coordinator
        let first = try #require(coordinator.serverStore.servers.first)
        let other = try #require(PairedServer(
            from: ServerCredentials(
                host: "other-server.test", port: 7749, token: "sk_test", name: "Other", scheme: .https,
                serverFingerprint: "extensions-list-other"
            ),
            sortOrder: 1
        ))
        coordinator.serverStore.replaceServersForPreview([first, other])
        let firstConnection = try #require(coordinator.connection(for: first.id))
        let otherConnection = coordinator.ensureConnection(for: other)
        otherConnection.setAPIClientForTesting(try makeClient())

        // The stores already name their own server from setup; a marker makes each
        // wait below see only a load the screen itself starts.
        firstConnection.serverResourceStore.switchServer(to: "marker")

        let screen = ServerExtensionsViewController(root: root)
        let navigation = UINavigationController(rootViewController: screen)
        let window = try show(navigation)
        defer { hide(window) }

        // With several servers the row is the switcher menu; it shows the active one.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: "serverCatalog.server.menu", in: screen.view)?
                .accessibilityLabel == "Current server: Ready"
        })
        // Showing the screen loads the active server's catalog.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            firstConnection.serverResourceStore.activeServerId == first.id
        })

        // Another server becomes active (the pill, a link): its catalog loads.
        otherConnection.serverResourceStore.switchServer(to: "marker")
        #expect(coordinator.restoreActiveServer(other.id))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            otherConnection.serverResourceStore.activeServerId == other.id
        })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: "serverCatalog.server.menu", in: screen.view)?
                .accessibilityLabel == "Current server: Other"
        })

        // A page above the list: a switch meanwhile loads nothing until it returns.
        Router.push(UIViewController(), from: screen)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            navigation.transitionCoordinator == nil && navigation.topViewController !== screen
        })
        firstConnection.serverResourceStore.switchServer(to: "marker")
        #expect(coordinator.restoreActiveServer(first.id))
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) {
            firstConnection.serverResourceStore.activeServerId == "marker"
        }, "a covered list must not load")

        navigation.popViewController(animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            firstConnection.serverResourceStore.activeServerId == first.id
        }, "the list loads the active server when it shows again")
    }

    @Test("Retry on an unavailable catalog sends one new request and loads the catalog")
    func retryReloadsAnUnavailableCatalog() async throws {
        ExtensionsCatalogURLProtocol.reset()
        // A fresh server id: the shared cache holds no catalog for it, and the
        // catalog this test loads is removed again at the end.
        let serverId = UUID().uuidString
        let root = try makeTestAppRoot(
            readyServerId: serverId,
            apiClient: ExtensionsCatalogURLProtocol.makeClient()
        )
        let screen = ServerExtensionsViewController(root: root)
        let window = try show(UINavigationController(rootViewController: screen))
        defer { hide(window) }

        var retryButton: UIButton?
        #expect(await waitForMainActorCondition(timeout: .seconds(10)) {
            screen.view.layoutIfNeeded()
            retryButton = Self.button(withIdentifier: "extensions.retry", in: screen.view)
            return retryButton != nil
        })
        guard let retry = retryButton else {
            await Self.removeCachedCatalog(of: serverId)
            return
        }
        #expect(Self.button(withIdentifier: "extensions.row.workflow", in: screen.view) == nil)

        // The server comes back, but nothing reloads by itself.
        let settled = ExtensionsCatalogURLProtocol.extensionsRequests
        ExtensionsCatalogURLProtocol.catalogAvailable = true
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: "extensions.retry", in: screen.view) != nil
                && ExtensionsCatalogURLProtocol.extensionsRequests == settled
        })

        let before = ExtensionsCatalogURLProtocol.extensionsRequests
        retry.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: "extensions.row.workflow", in: screen.view) != nil
        })
        #expect(ExtensionsCatalogURLProtocol.extensionsRequests == before + 1)
        // The replaced state row leaves the screen (a recycled cell may linger, hidden).
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.buttons(withIdentifier: "extensions.retry", in: screen.view).allSatisfy(\.isHiddenInHierarchy)
        })
        await Self.removeCachedCatalog(of: serverId)
    }

    private static func removeCachedCatalog(of serverId: String) async {
        TimelineCache.shared.markRemoved(serverId)
        await TimelineCache.shared.removeServer(serverId)
    }

    private func makeClient() throws -> APIClient {
        APIClient(
            baseURL: try #require(URL(string: "https://ready-server.test:7749")),
            token: "sk_test"
        )
    }

    private func makeRoot() throws -> AppRootEnvironment {
        try makeTestAppRoot(readyServerId: serverId, apiClient: makeClient())
    }

    private func show(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func button(withIdentifier identifier: String, in view: UIView) -> UIButton? {
        buttons(withIdentifier: identifier, in: view).first
    }

    /// Every match, in view order: a recycled cell can leave a hidden one beside the live one.
    private static func buttons(withIdentifier identifier: String, in view: UIView) -> [UIButton] {
        var found: [UIButton] = []
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { found.append(button) }
        for subview in view.subviews {
            found += buttons(withIdentifier: identifier, in: subview)
        }
        return found
    }
}

private extension UIView {
    var isHiddenInHierarchy: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.window == nil { return true }
            view = current.superview
        }
        return false
    }
}

/// Answers the Extensions catalog request with a 404 until `catalogAvailable`,
/// then with one `workflow` extension; every other request gets a 404. Counts the
/// catalog requests, so a test can tell a request Retry sent from one it did not.
private final class ExtensionsCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "extensions-catalog.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var available = false

    static var extensionsRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static var catalogAvailable: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return available
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            available = newValue
        }
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        requests = 0
        available = false
    }

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExtensionsCatalogURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var body = Data(#"{"error":"not found"}"#.utf8)
        var status = 404
        if url.path.hasSuffix("/server/resources/extensions") {
            Self.lock.lock()
            Self.requests += 1
            let isAvailable = Self.available
            Self.lock.unlock()
            if isAvailable {
                let catalog = ServerExtensionCatalog(
                    extensions: [
                        ServerExtensionSummary(
                            id: "workflow", name: "workflow", description: "Coordinates local automation.",
                            kind: .file, provenance: .init(kind: .piAgent, label: "~/.pi/agent/extensions"), path: nil,
                            state: .on, loadError: nil, warnings: [], isRemovable: true
                        ),
                    ],
                    builtInTools: [],
                    optionalTools: []
                )
                body = (try? JSONEncoder().encode(catalog)) ?? body
                status = 200
            }
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
