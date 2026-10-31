import Testing
import UIKit
@testable import Oppi

/// The suites below share `AgentsURLProtocol.mode`, so they run one at a time.
@MainActor
@Suite("Agents and Pi load states", .serialized)
enum AgentsLoadStateTests {
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
    @Suite("A rejected server certificate is not a cancel")
    struct CertificateRejectionLoadTests {
        @Test("APIClient names a pin rejection; a real cancel stays a cancel")
        func apiClientNamesTheRejection() async throws {
            AgentsURLProtocol.reset()
            AgentsURLProtocol.mode = .certificateRejected
            let client = AgentsURLProtocol.makeClient()
            do {
                _ = try await client.listAgents()
                Issue.record("a rejected certificate must fail the request")
            } catch let error as URLError {
                #expect(error.code == .serverCertificateUntrusted)
                #expect(error.localizedDescription == "The server's certificate doesn't match the paired one.")
                #expect(!error.isLoadCancellation)
            }

            AgentsURLProtocol.mode = .cancelled
            do {
                _ = try await client.listAgents()
                Issue.record("a cancelled request must fail")
            } catch let error as URLError {
                #expect(error.code == .cancelled)
                #expect(error.isLoadCancellation)
            }
        }

        @Test("Agents shows the certificate failure with Retry instead of nothing")
        func agentsShowsTheRejection() async throws {
            AgentsURLProtocol.reset()
            AgentsURLProtocol.mode = .certificateRejected
            let root = makeTestAppRoot()
            root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
            let screen = AgentListViewController(root: root)
            let window = try AgentListViewControllerTests.show(screen)
            defer { AgentListViewControllerTests.hide(window) }

            var row: UIButton?
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
                screen.view.layoutIfNeeded()
                row = AgentListViewControllerTests.buttons("agents.state", in: screen.view)
                    .first { !$0.isHiddenInHierarchy && $0.accessibilityLabel == PinnedServerTrustDelegate.rejectionMessage }
                return row != nil
            })
            #expect(row?.accessibilityLabel == "The server's certificate doesn't match the paired one.")
            #expect(row?.accessibilityTraits.contains(.button) == true)
        }

        @Test("Pi shows the certificate failure with Retry instead of nothing")
        func piShowsTheRejection() async throws {
            AgentsURLProtocol.reset()
            AgentsURLProtocol.mode = .certificateRejected
            let root = makeTestAppRoot()
            root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
            let screen = PiAgentDetailViewController(root: root)
            let window = try AgentListViewControllerTests.show(screen)
            defer { AgentListViewControllerTests.hide(window) }

            var row: UIButton?
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
                screen.view.layoutIfNeeded()
                row = AgentListViewControllerTests.buttons("agents.pi.state", in: screen.view)
                    .first { !$0.isHiddenInHierarchy && $0.accessibilityLabel == PinnedServerTrustDelegate.rejectionMessage }
                return row != nil
            })
            #expect(row?.accessibilityLabel == "The server's certificate doesn't match the paired one.")
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

        @Test("coming back from Tools keeps the tools it saved, and a pull to refresh loads the server's")
        func returningFromToolsKeepsTheSavedTools() async throws {
            AgentsURLProtocol.reset()
            let root = makeTestAppRoot()
            root.coordinator.activeConnection.setAPIClientForTesting(AgentsURLProtocol.makeClient())
            let screen = PiAgentDetailViewController(root: root)
            let window = try AgentListViewControllerTests.show(screen)
            defer { AgentListViewControllerTests.hide(window) }

            func toolsValue() -> String? {
                screen.view.layoutIfNeeded()
                return AgentListViewControllerTests.button("agents.pi.tools", in: screen.view)?.accessibilityValue
            }
            // "Pi standard" is also what the row says before any load, so wait
            // for the prompt the fixture served: the tools are loaded by then.
            func hasLoaded() -> Bool {
                screen.view.layoutIfNeeded()
                return screen.view.allLabels().contains { $0.text == "You are a coding agent." }
            }
            let serverDefault = AgentManagementPresentation.piStandardToolsSummary
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) { hasLoaded() && toolsValue() == serverDefault })

            // The Tools page saved a change and Pi is back on screen: coming back
            // keeps what that page saved instead of loading over it.
            AgentsURLProtocol.defaultTools = ["+codemode"]
            screen.beginAppearanceTransition(true, animated: false)
            screen.endAppearanceTransition()
            #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) {
                toolsValue() == serverDefault
            }, "appearing again does not load Pi's tools")

            // A pull to refresh does load the server's.
            screen.collectionView.refreshControl?.sendActions(for: .valueChanged)
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
                toolsValue() == "\(serverDefault) +codemode"
            }, "a pull to refresh loads the tools the server has")
        }
    }
}

private extension UIView {
    /// Every label under this view, in view order.
    func allLabels() -> [UILabel] {
        var found = (self as? UILabel).map { [$0] } ?? []
        for subview in subviews { found += subview.allLabels() }
        return found
    }

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
    enum Mode { case available, failing, cancelled, certificateRejected, held }

    static let host = "agents-list.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentMode = Mode.available
    nonisolated(unsafe) private static var held: [AgentsURLProtocol] = []
    nonisolated(unsafe) private static var requests = 0
    /// Pi's default tools, as the server holds them for this run.
    nonisolated(unsafe) private static var currentDefaultTools: [String]?

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
            currentDefaultTools = nil
        }
    }

    /// Pi's default tools, as the server holds them.
    static var defaultTools: [String]? {
        get { lock.withLock { currentDefaultTools } }
        set { lock.withLock { currentDefaultTools = newValue } }
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

    /// What Pi's page asks for, when this is that request: its system prompt,
    /// its default tools (what a test set), or the server's tool catalog.
    private static func piBody(for path: String) -> Data? {
        if path.hasSuffix("/pi/system-prompt") {
            return Data(#"{"source":"default","path":"~/.pi/agent/SYSTEM.md","resolvedPath":null,"content":"You are a coding agent."}"#.utf8)
        }
        if path.hasSuffix("/pi/default-tools") {
            struct Body: Encodable { let defaultTools: [String]? }
            return (try? JSONEncoder().encode(Body(defaultTools: defaultTools))) ?? Data()
        }
        if path.hasSuffix("/server/resources/extensions") {
            return Data(#"{"extensions":[],"builtInTools":[],"optionalTools":[]}"#.utf8)
        }
        return nil
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
        case .certificateRejected: challengeServerTrust()
        case .available:
            // Pi's page loads three resources beside the saved Agents.
            respond(status: 200, body: Self.piBody(for: request.url?.path ?? "") ?? Self.agentsBody(id: "reviewer"))
        case .failing: respond(status: 500, body: Data(#"{"error":"agents are down"}"#.utf8))
        case .held: Self.lock.withLock { Self.held.append(self) }
        }
    }

    override func stopLoading() {}

    /// What URLSession does with a server whose certificate fails the pin: the
    /// connection asks the delegate to trust it, the delegate cancels the
    /// challenge, and the request ends as a cancelled one.
    private func challengeServerTrust() {
        let space = URLProtectionSpace(
            host: Self.host,
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: CancellingChallengeSender(owner: self)
        )
        client?.urlProtocol(self, didReceive: challenge)
    }

    private final class CancellingChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
        private let owner: AgentsURLProtocol
        init(owner: AgentsURLProtocol) { self.owner = owner }
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {
            owner.client?.urlProtocol(owner, didFailWithError: URLError(.cancelled))
        }
    }

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
