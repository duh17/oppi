import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Extensions list screen")
struct ServerExtensionsViewControllerTests {
    private let serverId = "extensions-list-server"

    @Test("a row is one button that opens its detail through AppNavigation")
    func rowOpensDetailRoute() async throws {
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        defer { routes.end() }
        let root = try await makeRoot()
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
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        defer { routes.end() }
        let root = try await makeTestTwoServerRoot(firstId: serverId, otherId: "extensions-list-other")
        let coordinator = root.coordinator
        let servers = coordinator.serverStore.servers
        let first = try #require(servers.first)
        let other = try #require(servers.dropFirst().first)
        let firstConnection = try #require(coordinator.connection(for: first.id))
        let otherConnection = try #require(coordinator.connection(for: other.id))

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
        // The refresh the list starts loads both catalogs, and ends with this test.
        #expect(await routes.settle(), "a request outlived the test that answered it")
    }

    @Test("Retry on an unavailable catalog sends one new request and loads the catalog")
    func retryReloadsAnUnavailableCatalog() async throws {
        // A fresh server id: the shared cache holds no catalog for it, and the
        // catalog this test loads is removed again at the end.
        let serverId = UUID().uuidString
        let catalog = MissingRouteThenAvailable(
            availableJSON: try String(
                decoding: JSONEncoder().encode(ServerExtensionCatalog(
                    extensions: [
                        ServerExtensionSummary(
                            id: "workflow", name: "workflow", description: "Coordinates local automation.",
                            kind: .file, provenance: .init(kind: .piAgent, label: "~/.pi/agent/extensions"),
                            path: nil, state: .on, loadError: nil, warnings: [], isRemovable: true
                        ),
                    ],
                    builtInTools: [],
                    optionalTools: []
                )),
                as: UTF8.self
            )
        )
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard request.url?.path.hasSuffix("/server/resources/extensions") == true else { return nil }
            return try catalog.answer(for: request)
        })
        defer { routes.end() }
        let root = try await makeTestAppRoot(
            readyServerId: serverId,
            apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
        let screen = ServerExtensionsViewController(root: root)
        let window = try show(UINavigationController(rootViewController: screen))
        defer { hide(window) }

        // The failed row, not the loading row that shares its identifier.
        func failedRow() -> ListStateRow? {
            guard case .failed = screen.sections().first(where: { $0.id == .state })?.state?.state else { return nil }
            return screen.sections().first(where: { $0.id == .state })?.state
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(10)) { failedRow() != nil })
        let row = try #require(failedRow())
        guard case .failed(let title, let reason, let retryAction) = row.state else {
            Issue.record("the row is not a failure: \(row.state.rowText)")
            return
        }
        #expect(title == "Couldn't Load Extensions")
        #expect(reason == String(localized: "The selected server has no cached Extensions catalog."))
        #expect(retryAction != nil, "the row offers the page's Retry")
        #expect(Self.button(withIdentifier: "extensions.row.workflow", in: screen.view) == nil)

        // The server comes back, but nothing reloads by itself.
        let settled = catalog.requests
        catalog.makeAvailable()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            failedRow() != nil && catalog.requests == settled
        })

        let retry = try #require(Self.button(withIdentifier: "extensions.state", in: screen.view))
        retry.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: "extensions.row.workflow", in: screen.view) != nil
        })
        #expect(catalog.requests == settled + 1)
        // The replaced state row leaves the screen (a recycled cell may linger, hidden).
        // The screen itself stays in its window, so a button without one was removed.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return screen.view.window != nil
                && Self.buttons(withIdentifier: "extensions.state", in: screen.view).allSatisfy(\.isHiddenInHierarchy)
        })
        await Self.removeCachedCatalog(of: serverId)
    }

    @Test("plugins list with their badges, a broken one needs attention, and Reload reports and refreshes the list")
    func pluginRowsAndReload() async throws {
        let serverId = UUID().uuidString
        let answers = PluginCatalogAnswers()
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in try answers.answer(for: request) })
        defer { routes.end() }
        let root = try await makeTestAppRoot(
            readyServerId: serverId,
            apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
        let screen = ServerExtensionsViewController(root: root)
        let window = try show(UINavigationController(rootViewController: screen))
        defer { hide(window) }

        var control: UIButton?
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            control = Self.button(withIdentifier: "extensions.row.control", in: screen.view)
            return control != nil
        })
        #expect(answers.listQueries.allSatisfy { $0 == "plugins=true" }, "the page asks for plugin rows")
        // A row speaks its kinds, source, and state from its fields; a runtime built-in says it
        // is always on, and only an optional row is merely enabled.
        let controlLabel = control?.accessibilityLabel ?? ""
        #expect(["Enabled", "always on"].allSatisfy(controlLabel.contains))
        #expect(!controlLabel.contains("Required"))
        let bothLabel = Self.button(withIdentifier: "extensions.row.both", in: screen.view)?.accessibilityLabel ?? ""
        #expect(["Plugin", "Pi extension", "Enabled"].allSatisfy(bothLabel.contains))
        #expect(!bothLabel.contains("always on"))
        let sections = screen.sections()
        let builtIn = sections.first { $0.id == .kind(.builtIn) }
        #expect(builtIn?.items == [.row("control")])
        #expect(builtIn?.footer != nil, "the built-in section says what its plugins are")
        #expect(sections.first { $0.id == .kind(.needsAttention) }?.items == [.row("broken")])
        #expect(sections.first { $0.id == .notice }?.items == [.pluginsUnavailable])

        let reload = try #require(screen.navigationItem.rightBarButtonItems?.first {
            $0.accessibilityIdentifier == "extensions.reload"
        })
        #expect(reload.isEnabled)
        screen.reloadPlugins()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return screen.sections().first { $0.id == .reload }?.items.contains(.reloadLine("kept.broken")) == true
        }, "the report lists the plugin whose previous code still runs")
        #expect(answers.reloads == 1)
        // A report row's identifier keys on the file that failed, never on its message.
        let errorIds = screen.collectionView.visibleCells.compactMap(\.accessibilityIdentifier)
            .filter { $0.hasPrefix("extensions.reload.error.") }
        #expect(errorIds == ["extensions.reload.error./plugins/broken/server.ts"])
        // The reload changed the server's plugins: the list asks again and drops the stale note.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return screen.sections().first { $0.id == .notice } == nil
        })
        #expect(screen.sections().first { $0.id == .reload }?.items.first == .reloadLine("loaded"))
        #expect(reload.isEnabled, "a finished reload can run again")
        #expect(await routes.settle(), "a request outlived the test that answered it")
        await Self.removeCachedCatalog(of: serverId)
    }

    private static func removeCachedCatalog(of serverId: String) async {
        TimelineCache.shared.markRemoved(serverId)
        await TimelineCache.shared.removeServer(serverId)
    }

    private func makeRoot() async throws -> AppRootEnvironment {
        try await makeTestAppRoot(
            readyServerId: serverId,
            apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
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

/// A server with plugins: a required built-in, a package that is both kinds, and a broken owner
/// plugin. Its first list says the plugins could not all load; after a reload it does not.
private final class PluginCatalogAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String?] = []
    private var reloadCount = 0

    var listQueries: [String?] { lock.withLock { queries } }
    var reloads: Int { lock.withLock { reloadCount } }

    func answer(for request: URLRequest) throws -> (Data, HTTPURLResponse)? {
        let path = request.url?.path ?? ""
        if request.httpMethod == "POST", path.hasSuffix("/server/resources/extensions/reload") {
            lock.withLock { reloadCount += 1 }
            return try mockJSONResponse(encoding: ServerPluginReloadReport(
                loaded: [.init(name: "oppi-control", entry: "/server/plugins/control/server.ts")],
                kept: [.init(name: "broken", entry: "/plugins/broken/server.ts")],
                removed: [],
                skipped: [],
                errors: [.init(entry: "/plugins/broken/server.ts", message: "Unexpected token", plugin: "broken")]
            ), for: request)
        }
        guard request.httpMethod == "GET", path.hasSuffix("/server/resources/extensions") else { return nil }
        let reloaded = lock.withLock {
            queries.append(request.url?.query)
            return reloadCount > 0
        }
        return try mockJSONResponse(encoding: ServerExtensionCatalog(
            extensions: Self.rows,
            pluginsUnavailable: reloaded ? nil : "Oppi's built-in plugins failed to load"
        ), for: request)
    }

    private static let rows: [ServerExtensionSummary] = {
        func plugin(required: Bool = false, loadError: String? = nil) -> ServerPluginSummary {
            ServerPluginSummary(
                extensionName: "plugin", required: required, enabled: loadError == nil, runtimes: ["host"],
                tools: ["tool"], hooks: [], sections: [], wraps: [], tasks: [], loadError: loadError,
                kept: loadError != nil
            )
        }
        return [
            ServerExtensionSummary(
                id: "control", name: "oppi-control", description: nil, kind: .builtIn,
                provenance: .init(kind: .builtIn, label: "Oppi"), path: nil, state: .on, loadError: nil,
                warnings: [], isRemovable: false, kinds: [.plugin], source: .builtIn, plugin: plugin(required: true)
            ),
            ServerExtensionSummary(
                id: "both", name: "both", description: nil, kind: .directory,
                provenance: .init(kind: .piAgent, label: "~/.pi/agent/extensions"), path: nil, state: .on,
                loadError: nil, warnings: [], isRemovable: false, kinds: [.plugin, .piExtension], source: .owner,
                plugin: plugin()
            ),
            ServerExtensionSummary(
                id: "broken", name: "broken", description: nil, kind: .directory,
                provenance: .init(kind: .piAgent, label: "~/.pi/agent/plugins"), path: nil, state: .error,
                loadError: "Unexpected token", warnings: [], isRemovable: false, kinds: [.plugin], source: .owner,
                plugin: plugin(loadError: "Unexpected token")
            ),
        ]
    }()
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
