import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Agents list load states")
struct AgentListViewControllerTests {
    @Test("with no server the list shows one inline Server offline row, never an alert, and loads by itself when the server comes back")
    func offlineRowClearsWhenTheServerReturns() async throws {
        AgentsURLProtocol.reset()
        let root = makeTestAppRoot()
        let screen = AgentListViewController(root: root)
        let window = try Self.show(screen)
        defer { Self.hide(window) }

        let row = try #require(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Server offline" })
        #expect(row.accessibilityTraits.contains(.button))
        #expect(row.accessibilityHint == SettingsStateRowCell.retryTitle)
        #expect(Self.button("agents.row.pi", in: screen.view) != nil, "Pi stays listed")
        // An alert would present a run-loop turn after the update.
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            screen.presentedViewController == nil && window.rootViewController?.presentedViewController == nil
        }, "offline is a row, not an alert")

        // The connection recovers: nobody taps Retry, the row shows the load and then the list.
        AgentsURLProtocol.mode = .held
        root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
        let loading = try #require(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Loading saved Agents…" })
        #expect(!loading.accessibilityTraits.contains(.button), "a loading row is not a button")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { AgentsURLProtocol.hasHeldRequest })

        AgentsURLProtocol.releaseHeldRequest()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button("agents.row.reviewer", in: screen.view) != nil
        })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.buttons("agents.state", in: screen.view).allSatisfy(\.isHiddenInHierarchy)
        }, "the state row leaves once the list loads")
    }

    @Test("Retry keeps its row and shows loading, with the saved Agents listed or not, then recovers")
    func retryKeepsTheRowWhileLoading() async throws {
        AgentsURLProtocol.reset()
        AgentsURLProtocol.mode = .failing
        let root = makeTestAppRoot()
        root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
        let screen = AgentListViewController(root: root)
        let window = try Self.show(screen)
        defer { Self.hide(window) }

        // Nothing loaded yet: the failure says why and offers Retry.
        let retry = try #require(await waitForStateRow(in: screen) {
            $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.isEmpty == false
        })
        #expect(retry.accessibilityLabel != "Server offline", "a failed request says what failed")
        #expect(screen.presentedViewController == nil)

        AgentsURLProtocol.mode = .held
        retry.sendActions(for: .touchUpInside)
        let loading = try #require(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Loading saved Agents…" })
        #expect(loading === retry, "the same row, so VoiceOver focus stays on it")
        #expect(!loading.accessibilityTraits.contains(.button))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { AgentsURLProtocol.hasHeldRequest })
        AgentsURLProtocol.releaseHeldRequest()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button("agents.row.reviewer", in: screen.view) != nil
        })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.buttons("agents.state", in: screen.view).allSatisfy(\.isHiddenInHierarchy)
        })

        // The server drops: the loaded Agent stays and the row returns below it.
        AgentsURLProtocol.mode = .failing
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        let again = try #require(await waitForStateRow(in: screen) { $0.accessibilityTraits.contains(.button) })
        #expect(Self.button("agents.row.reviewer", in: screen.view) != nil)

        // Retry with Agents listed still shows the loading row, not an empty gap.
        AgentsURLProtocol.mode = .held
        again.sendActions(for: .touchUpInside)
        #expect(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Loading saved Agents…" } != nil)
        #expect(Self.button("agents.row.reviewer", in: screen.view) != nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { AgentsURLProtocol.hasHeldRequest })
        AgentsURLProtocol.releaseHeldRequest()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.buttons("agents.state", in: screen.view).allSatisfy(\.isHiddenInHierarchy)
        }, "a successful retry clears the row")
    }

    @Test("a load cancelled under the list shows no failure row and keeps what was listed")
    func cancelledLoadShowsNoFailure() async throws {
        AgentsURLProtocol.reset()
        AgentsURLProtocol.mode = .cancelled
        let root = makeTestAppRoot()
        root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
        let screen = AgentListViewController(root: root)
        let window = try Self.show(screen)
        defer { Self.hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { AgentsURLProtocol.requestCount > 0 })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) {
            screen.view.layoutIfNeeded()
            return Self.buttons("agents.state", in: screen.view).allSatisfy(\.isHiddenInHierarchy)
                && Self.button("agents.row.pi", in: screen.view) != nil
        }, "a cancel is not a failure to report")

        // Agents already listed stay listed when a later load is cancelled.
        AgentsURLProtocol.mode = .available
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button("agents.row.reviewer", in: screen.view) != nil
        })
        let before = AgentsURLProtocol.requestCount
        AgentsURLProtocol.mode = .cancelled
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { AgentsURLProtocol.requestCount > before })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) {
            screen.view.layoutIfNeeded()
            return Self.button("agents.row.reviewer", in: screen.view) != nil
                && Self.buttons("agents.state", in: screen.view).allSatisfy(\.isHiddenInHierarchy)
        })
    }

    @Test("a load that was running when the server went away neither sticks on loading nor shows its late answer")
    func serverChangeMidLoadDropsTheOldResult() async throws {
        AgentsURLProtocol.reset()
        AgentsURLProtocol.mode = .held
        let root = makeTestAppRoot()
        let connection = root.coordinator.activeConnection
        connection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
        let screen = AgentListViewController(root: root)
        let window = try Self.show(screen)
        defer { Self.hide(window) }

        #expect(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Loading saved Agents…" } != nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { AgentsURLProtocol.hasHeldRequest })

        connection.setAPIClientForTesting(nil)
        #expect(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Server offline" } != nil,
                "no client ends the load instead of leaving the row loading")

        AgentsURLProtocol.releaseHeldRequest(agentId: "stale")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) {
            screen.view.layoutIfNeeded()
            return Self.button("agents.row.stale", in: screen.view) == nil
                && Self.buttons("agents.state", in: screen.view).contains { !$0.isHiddenInHierarchy && $0.accessibilityLabel == "Server offline" }
        }, "the old server's answer is dropped")
    }

    // MARK: - Helpers

    private func waitForStateRow(
        in screen: AgentListViewController,
        where matches: (UIButton) -> Bool
    ) async -> UIButton? {
        var found: UIButton?
        _ = await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            found = Self.buttons("agents.state", in: screen.view).first { !$0.isHiddenInHierarchy && matches($0) }
            return found != nil
        }
        return found
    }

    fileprivate static func show(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        return window
    }

    fileprivate static func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    fileprivate static func button(_ identifier: String, in view: UIView) -> UIButton? {
        buttons(identifier, in: view).first
    }

    /// Every match, in view order: a recycled cell can leave a hidden one beside the live one.
    fileprivate static func buttons(_ identifier: String, in view: UIView) -> [UIButton] {
        var found: [UIButton] = []
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { found.append(button) }
        for subview in view.subviews {
            found += buttons(identifier, in: subview)
        }
        return found
    }
}

@MainActor
@Suite("Pi page load states")
struct PiAgentDetailLoadStateTests {
    private func hasAlert(_ screen: UIViewController, _ window: UIWindow) -> Bool {
        screen.presentedViewController != nil || window.rootViewController?.presentedViewController != nil
    }

    private func waitForStateRow(
        in screen: UIViewController,
        where matches: (UIButton) -> Bool
    ) async -> UIButton? {
        var found: UIButton?
        _ = await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            found = AgentListViewControllerTests.buttons("agents.pi.state", in: screen.view)
                .first { !$0.isHiddenInHierarchy && matches($0) }
            return found != nil
        }
        return found
    }

    @Test("a load that was cancelled under the page shows no alert and no failure")
    func cancelledLoadIsSilent() async throws {
        AgentsURLProtocol.reset()
        AgentsURLProtocol.mode = .cancelled
        let root = makeTestAppRoot()
        root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
        let screen = PiAgentDetailViewController(root: root)
        let window = try AgentListViewControllerTests.show(screen)
        defer { AgentListViewControllerTests.hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { AgentsURLProtocol.requestCount > 0 })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) {
            screen.view.layoutIfNeeded()
            return !hasAlert(screen, window)
                && AgentListViewControllerTests.buttons("agents.pi.state", in: screen.view).allSatisfy(\.isHiddenInHierarchy)
        }, "a cancelled load is not a failure to report")
    }

    @Test("a failed load is an inline row with Retry, never an alert; Retry shows loading in the same row")
    func failedLoadIsAnInlineRow() async throws {
        AgentsURLProtocol.reset()
        AgentsURLProtocol.mode = .failing
        let root = makeTestAppRoot()
        root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
        let screen = PiAgentDetailViewController(root: root)
        let window = try AgentListViewControllerTests.show(screen)
        defer { AgentListViewControllerTests.hide(window) }

        let failure = try #require(await waitForStateRow(in: screen) {
            $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.isEmpty == false
        })
        #expect(!hasAlert(screen, window))

        AgentsURLProtocol.mode = .held
        failure.sendActions(for: .touchUpInside)
        let loading = try #require(await waitForStateRow(in: screen) { !$0.accessibilityTraits.contains(.button) })
        #expect(loading === failure, "the same row, so VoiceOver focus stays on it")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { AgentsURLProtocol.hasHeldRequest })
        AgentsURLProtocol.failHeldRequests()
        #expect(await waitForStateRow(in: screen) { $0.accessibilityTraits.contains(.button) } != nil)
        #expect(!hasAlert(screen, window))
    }

    @Test("with no server the page says Server offline in a row")
    func offlineIsAnInlineRow() async throws {
        AgentsURLProtocol.reset()
        let root = makeTestAppRoot()
        let screen = PiAgentDetailViewController(root: root)
        let window = try AgentListViewControllerTests.show(screen)
        defer { AgentListViewControllerTests.hide(window) }

        #expect(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Server offline" } != nil)
        #expect(!hasAlert(screen, window))
    }
}

private extension UIView {
    var isHiddenInHierarchy: Bool {
        if window == nil { return true }
        var view: UIView? = self
        while let current = view {
            if current.isHidden { return true }
            view = current.superview
        }
        return false
    }
}

/// Answers every request by mode: `.held` parks requests until the test
/// releases them, `.failing` is a 500, `.cancelled` fails like a URLSession
/// task that was cancelled under the caller, `.available` one saved Agent.
private final class AgentsURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case available, failing, cancelled, held }

    static let host = "agents-list.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentMode = Mode.available
    nonisolated(unsafe) private static var held: [AgentsURLProtocol] = []
    nonisolated(unsafe) private static var requests = 0

    static var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }

    static var hasHeldRequest: Bool { lock.withLock { !held.isEmpty } }

    static var requestCount: Int { lock.withLock { requests } }

    static func reset() {
        lock.withLock {
            currentMode = .available
            held = []
            requests = 0
        }
    }

    static func releaseHeldRequest(agentId: String = "reviewer") {
        for request in takeHeld() { request.respond(status: 200, body: agentsBody(id: agentId)) }
    }

    static func failHeldRequests() {
        for request in takeHeld() { request.respond(status: 500, body: Data(#"{"error":"down"}"#.utf8)) }
    }

    private static func takeHeld() -> [AgentsURLProtocol] {
        lock.withLock {
            defer { held = [] }
            return held
        }
    }

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentsURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    private static func agentsBody(id: String) -> Data {
        let agent = AgentDefinitionSummary(
            id: id,
            name: id.capitalized,
            icon: .defaultValue,
            description: "Reviews diffs.",
            status: .active,
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            archivedAt: nil
        )
        return (try? JSONEncoder().encode(["agents": [agent]])) ?? Data()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        switch Self.mode {
        case .cancelled: client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case .available: respond(status: 200, body: Self.agentsBody(id: "reviewer"))
        case .failing: respond(status: 500, body: Data(#"{"error":"agents are down"}"#.utf8))
        case .held: Self.lock.withLock { Self.held.append(self) }
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, body: Data) {
        guard let url = request.url, let response = HTTPURLResponse(
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
}
