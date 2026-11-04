import Foundation
import Testing
import UIKit
@testable import Oppi

/// A page caught by a route rebuild loads again by itself once the connection has
/// an API client, and says it is reconnecting while it waits. The kit owns that:
/// a page hands it the connection with `loadConnection()` and takes the client
/// with `requireAPIClient()`, so no page needs its own Retry-for-a-connection.
@Suite("List screen connection recovery", .serialized)
@MainActor
struct ListScreenConnectionRecoveryTests {
    @Test("A page caught mid-rebuild says it is reconnecting and loads by itself once the route commits")
    func aRebuildHealsThePageWithoutAnAsk() async throws {
        let connection = ServerConnection()
        #expect(await configureTestConnection(connection), "a route is up before the rebuild")
        let page = ConnectionPage(connection: connection)
        let window = try show(page)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["Loaded"] })
        #expect(page.loads == 1)

        // A rebuild holds between its teardown and its next commit: no API client,
        // and the route is on its way back.
        let gate = RebuildGate()
        let rebuild = Task { [credentials = makeTestCredentials()] in
            await connection.route.reconfigureForExplicitRetry(
                credentials: credentials,
                apiClientFactory: { _, _ in makeTestURLProtocolClient(host: credentials.host) },
                serverInfoBootstrap: { _, _ in
                    await gate.wait()
                    return makeTestServerInfo()
                }
            )
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            connection.apiClient == nil && connection.route.isTransportDemoting
        })

        // A load asked for now cannot run, and says why in the connection's words.
        page.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.loadFailure?.title == "Reconnecting to the server…"
        }, "a rebuild is reconnecting, not offline")

        // The commit installs the client: the page that failed waiting for one loads
        // again with no pull and no Retry. The rows it kept from before the rebuild
        // are not the answer: the load that ran is.
        gate.open()
        _ = await rebuild.value
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loads == 3 },
                "the appearance, the ask mid-rebuild, and the recovery")
        #expect(page.loadFailure == nil, "the recovery load cleared the failure")
        #expect(page.rows == ["Loaded"])
    }

    @Test("A connection that failed terminally says the server is offline and is not reloaded")
    func aTerminalFailureSaysTheServerIsOffline() async throws {
        let connection = ServerConnection()
        #expect(await configureTestConnection(connection))
        let page = ConnectionPage(connection: connection)
        let window = try show(page)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["Loaded"] })

        connection.failTransportTerminallyForTesting()
        #expect(connection.apiClient == nil)
        page.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.loadFailure?.title == "Server is offline"
        }, "a connection that gave up is offline, not reconnecting")

        // Nothing brings a client back on its own: the page keeps its Retry.
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { page.loads == 2 })
        #expect(page.loadFailure?.title == "Server is offline")
    }

    @Test("A recovery while the page is covered loads it once when it appears again")
    func aCoveredPageLoadsOnceWhenItAppears() async throws {
        let connection = ServerConnection()
        #expect(await configureTestConnection(connection))
        let page = ConnectionPage(connection: connection)
        let window = try show(page)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["Loaded"] })

        // The page fails for lack of a client, then is covered while the route
        // commits: the recovery is not a load the person asked for, and the page is
        // not on screen to draw it.
        let gate = RebuildGate()
        let rebuild = Task { [credentials = makeTestCredentials()] in
            await connection.route.reconfigureForExplicitRetry(
                credentials: credentials,
                apiClientFactory: { _, _ in makeTestURLProtocolClient(host: credentials.host) },
                serverInfoBootstrap: { _, _ in
                    await gate.wait()
                    return makeTestServerInfo()
                }
            )
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            connection.apiClient == nil && connection.route.isTransportDemoting
        })
        page.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.loadFailure?.title == "Reconnecting to the server…"
        })
        window.rootViewController = UIViewController()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !page.isShowing })

        gate.open()
        _ = await rebuild.value
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { connection.apiClient != nil })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { page.loads == 2 },
                "a covered page is not loaded behind the screen that covered it")

        window.rootViewController = UINavigationController(rootViewController: page)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.isShowing })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loads == 3 },
                "one appearance load, the ask, and one load on returning")
        #expect(page.triggers == [.appearance, .ask, .appearance],
                "the returning load is the appearance, not a recovery behind the covered page")
        #expect(page.loadFailure == nil)
        #expect(page.rows == ["Loaded"])
    }

    @Test("A rebuild that failed with no attempt pending says the server is offline, and heals when a client lands")
    func aFailedRebuildWithNothingPendingSaysTheServerIsOffline() async throws {
        let connection = ServerConnection()
        #expect(await configureTestConnection(connection))
        let page = ConnectionPage(connection: connection)
        let window = try show(page)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["Loaded"] })

        // A rebuild that ends on an answer waiting does not clear: no timer retries
        // it, and the next attempt is a path or a foreground boundary.
        await failRebuildOf(connection, status: 401)
        #expect(connection.apiClient == nil)
        #expect(!connection.route.isTransportDemoting)
        #expect(!connection.route.canRetryInitialTransportOnTimer)

        // A load asked for now cannot run, and says so without promising an attempt
        // that neither the route nor its own Retry starts.
        page.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.loadFailure?.title == "Server is offline"
        }, "nothing is pending, so the page is offline, not reconnecting")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { page.loads == 2 },
                "nothing reloads a page whose client is not on its way")

        // The next boundary brings a client back: the page still heals by itself.
        #expect(await configureTestConnection(connection))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.rows == ["Loaded"] && page.loadFailure == nil
        }, "the page reloads on the pass that sees the client arrive")
        #expect(page.loads == 3)
    }

    @Test("A rebuild that failed in a way its timer retries says it is reconnecting")
    func aRebuildItsTimerRetriesSaysItIsReconnecting() async throws {
        let connection = ServerConnection()
        #expect(await configureTestConnection(connection))
        let page = ConnectionPage(connection: connection)
        let window = try show(page)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["Loaded"] })

        // A 5xx is a failure waiting clears, so the route's own timer keeps trying.
        await failRebuildOf(connection, status: 503)
        #expect(connection.apiClient == nil)
        #expect(connection.route.canRetryInitialTransportOnTimer)

        page.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.loadFailure?.title == "Reconnecting to the server…"
        }, "an attempt is scheduled, so the page says it is reconnecting")
    }

    @Test("A pull to refresh and a Retry each load a page that failed for lack of a client")
    func anAskStillLoadsAPageThatFailedWaiting() async throws {
        let page = OfflinePage()
        let window = try show(page)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.loadFailure?.title == "Server is offline"
        })
        #expect(page.rows.isEmpty)

        // The connection came back while the page has no connection to observe: the
        // person's pull is what loads it.
        page.hasClient = true
        page.collectionView.refreshControl?.sendActions(for: .valueChanged)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["Loaded"] })
        #expect(page.loads == 2, "a pull to refresh loads the page that failed waiting")

        // And a Retry asks the same way.
        page.hasClient = false
        page.clearRows()
        page.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loadFailure?.title == "Server is offline" })
        page.hasClient = true
        page.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["Loaded"] })
        #expect(page.loads == 4)
    }

    // MARK: - Helpers

    /// A boundary rebuild whose bootstrap answers `status`: the composition is torn
    /// down, the pass fails, and the route keeps the failure for the next boundary.
    private func failRebuildOf(_ connection: ServerConnection, status: Int) async {
        let credentials = makeTestCredentials()
        _ = await connection.route.configureForUse(
            credentials: credentials,
            apiClientFactory: { _, _ in makeTestURLProtocolClient(host: credentials.host) },
            serverInfoBootstrap: { _, _ in
                throw APIError.server(status: status, message: "test rebuild failure")
            }
        )
        await connection.route.reevaluateNetworkEndpointAtBoundary()
    }

    private func show(_ page: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        return window
    }

    private func hide(_ window: UIWindow) {
        hideTestWindow(window)
        window.rootViewController = nil
    }
}

/// A rebuild's bootstrap, held open until the test lets it answer.
@MainActor
private final class RebuildGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

/// A page that loads through a connection: the client it needs is the connection's,
/// and the page says what the kit says when there is none.
private final class ConnectionPage: ListScreenController<ConnectionPage.Section, String> {
    enum Section: Hashable, Sendable { case only }

    private let connection: ServerConnection
    private(set) var loads = 0
    /// Why each load ran, in order: an appearance load and a recovery reload look
    /// the same to a count.
    private(set) var triggers: [LoadTrigger] = []
    private(set) var rows: [String] = []

    init(connection: ServerConnection) {
        self.connection = connection
        super.init(title: "Connection", listIdentifier: "test.connection.list")
    }

    override var loadPolicy: LoadPolicy { .eachAppearance }

    override func loadConnection() -> ServerConnection? { connection }

    override func load() async throws {
        loads += 1
        triggers.append(loadTrigger)
        _ = try requireAPIClient()
        rows = ["Loaded"]
        setNeedsUpdateProperties()
    }

    override func sections() -> [ListSection<Section, String>] {
        [ListSection(.only, items: rows)]
    }
}

/// A page with no connection to observe: only an ask loads it, which is the
/// pull-to-refresh and Retry path on its own.
private final class OfflinePage: ListScreenController<OfflinePage.Section, String> {
    enum Section: Hashable, Sendable { case only }

    var hasClient = false
    private(set) var loads = 0
    private(set) var rows: [String] = []

    init() {
        super.init(title: "Offline", listIdentifier: "test.offline.list")
    }

    override var loadPolicy: LoadPolicy { .eachAppearance }

    override func load() async throws {
        loads += 1
        guard hasClient else { throw noConnectionFailure() }
        rows = ["Loaded"]
        setNeedsUpdateProperties()
    }

    /// The server's answer is gone, as it is after a reload that dropped it.
    func clearRows() {
        rows = []
        setNeedsUpdateProperties()
    }

    override func sections() -> [ListSection<Section, String>] {
        [ListSection(.only, items: rows)]
    }
}
