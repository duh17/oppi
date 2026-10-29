import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Agents list load states")
struct AgentListViewControllerTests {
    @Test("with no server the list shows one inline Server offline row, never an alert; Retry loads once the server is back")
    func offlineRowRetriesIntoTheList() async throws {
        AgentsURLProtocol.reset()
        let root = makeTestAppRoot()
        let screen = AgentListViewController(root: root)
        let window = try show(screen)
        defer { hide(window) }

        let retry = try #require(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Server offline" })
        #expect(retry.accessibilityTraits.contains(.button))
        #expect(retry.accessibilityHint == SettingsStateRowCell.retryTitle)
        #expect(Self.button("agents.row.pi", in: screen.view) != nil, "Pi stays listed")
        // An alert would present a run-loop turn after the update.
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            screen.presentedViewController == nil && window.rootViewController?.presentedViewController == nil
        }, "offline is a row, not an alert")

        // Retry while still offline stays offline.
        retry.sendActions(for: .touchUpInside)
        #expect(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Server offline" } != nil)
        #expect(screen.presentedViewController == nil)

        // Back online: Retry shows loading, then the list.
        root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
        AgentsURLProtocol.mode = .held
        let current = try #require(Self.button("agents.state", in: screen.view))
        current.sendActions(for: .touchUpInside)
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

    @Test("a failed load keeps the saved Agents and adds a Retry row; Retry recovers")
    func failedLoadRetries() async throws {
        AgentsURLProtocol.reset()
        AgentsURLProtocol.mode = .failing
        let root = makeTestAppRoot()
        root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
        let screen = AgentListViewController(root: root)
        let window = try show(screen)
        defer { hide(window) }

        let retry = try #require(await waitForStateRow(in: screen) {
            $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.isEmpty == false
        })
        #expect(retry.accessibilityLabel != "Server offline", "a failed request says what failed")
        #expect(screen.presentedViewController == nil)

        AgentsURLProtocol.mode = .available
        retry.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button("agents.row.reviewer", in: screen.view) != nil
        })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.buttons("agents.state", in: screen.view).allSatisfy(\.isHiddenInHierarchy)
        })

        // The server drops again: the loaded Agent stays, and the row returns below it.
        AgentsURLProtocol.mode = .failing
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        #expect(await waitForStateRow(in: screen) { $0.accessibilityTraits.contains(.button) } != nil)
        #expect(Self.button("agents.row.reviewer", in: screen.view) != nil)
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

    private func show(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        return window
    }

    private func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func button(_ identifier: String, in view: UIView) -> UIButton? {
        buttons(identifier, in: view).first
    }

    /// Every match, in view order: a recycled cell can leave a hidden one beside the live one.
    private static func buttons(_ identifier: String, in view: UIView) -> [UIButton] {
        var found: [UIButton] = []
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { found.append(button) }
        for subview in view.subviews {
            found += buttons(identifier, in: subview)
        }
        return found
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

/// Answers `GET /agents` by mode: `.held` parks the request until the test
/// releases it, `.failing` is a 500, `.available` one saved Agent.
private final class AgentsURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case available, failing, held }

    static let host = "agents-list.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentMode = Mode.available
    nonisolated(unsafe) private static var held: AgentsURLProtocol?

    static var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }

    static var hasHeldRequest: Bool { lock.withLock { held != nil } }

    static func reset() {
        lock.withLock {
            currentMode = .available
            held = nil
        }
    }

    static func releaseHeldRequest() {
        let request = lock.withLock { () -> AgentsURLProtocol? in
            defer { held = nil }
            return held
        }
        request?.respond(status: 200, body: agentsBody)
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

    private static var agentsBody: Data {
        let agent = AgentDefinitionSummary(
            id: "reviewer",
            name: "Reviewer",
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
        switch Self.mode {
        case .available: respond(status: 200, body: Self.agentsBody)
        case .failing: respond(status: 500, body: Data(#"{"error":"agents are down"}"#.utf8))
        case .held: Self.lock.withLock { Self.held = self }
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
