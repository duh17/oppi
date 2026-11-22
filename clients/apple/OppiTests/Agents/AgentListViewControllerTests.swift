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
        @Test("with no server the list shows one inline Server is offline row, never an alert, and loads by itself when the server comes back")
        func offlineRowClearsWhenTheServerReturns() async throws {
            AgentsURLProtocol.reset()
            let root = makeTestAppRoot()
            let screen = AgentListViewController(root: root)
            let window = try Self.show(screen)
            defer { Self.hide(window) }

            let row = try #require(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Server is offline" })
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

            // The page's subject is the server and the client serving it, so a
            // client that goes away is another subject: the load for it is
            // cancelled and the page ends in the offline row, not loading.
            connection.setAPIClientForTesting(nil)
            #expect(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Server is offline" } != nil,
                    "no client ends the load instead of leaving the row loading")

            AgentsURLProtocol.releaseHeldRequest(agentId: "stale")
            #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) {
                screen.view.layoutIfNeeded()
                return Self.button("agents.row.stale", in: screen.view) == nil
                    && Self.buttons("agents.state", in: screen.view).contains { !$0.isHiddenInHierarchy && $0.accessibilityLabel == "Server is offline" }
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
        /// Every string a page draws: labels, text views, and accessibility labels.
        fileprivate static func labelTexts(in view: UIView) -> [String] {
            var texts: [String] = []
            if let label = view as? UILabel, let text = label.text { texts.append(text) }
            if let textView = view as? UITextView, let text = textView.text { texts.append(text) }
            if let label = view.accessibilityLabel { texts.append(label) }
            for subview in view.subviews { texts.append(contentsOf: labelTexts(in: subview)) }
            return texts
        }

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
                    .first { !$0.isHiddenInHierarchy && $0.accessibilityLabel?.contains(PinnedServerTrustDelegate.rejectionMessage) == true }
                return row != nil
            })
            #expect(row?.accessibilityLabel == "Couldn't Load Agents. The server's certificate doesn't match the paired one.",
                    "the page's title over the request's reason")
            #expect(row?.accessibilityTraits.contains(.button) == true)
        }
    }

    @MainActor
    @Suite("Pi page load states")
    struct PiAgentDetailLoadStateTests {
        @Test("a selectable text row is keyed by what it shows, so a pass leaves a selection alone")
        func aSelectableTextRowKeepsItsKey() {
            let root = makeTestAppRoot()
            let agent = AgentDetailViewController(root: root, agentId: "reviewer") { _ in }
            // The row's value is a text view: the same words are the same key, so
            // a pass that changed nothing else leaves a selection and its copy
            // menu where they are.
            #expect(agent.inputs(of: .value(title: "Name", value: "Reviewer"))
                == agent.inputs(of: .value(title: "Name", value: "Reviewer")))
            #expect(agent.inputs(of: .value(title: "Name", value: "Reviewer"))
                != agent.inputs(of: .value(title: "Name", value: "Other")))
            #expect(agent.inputs(of: .block(title: "Description", value: "A"))
                != agent.inputs(of: .block(title: "Description", value: "B")))
            #expect(agent.inputs(of: .resourceList(title: "Skills", value: "A"))
                != agent.inputs(of: .resourceList(title: "Skills", value: "B")))
            let pi = PiAgentDetailViewController(root: root)
            #expect(pi.inputs(of: .file) == pi.inputs(of: .file))
        }

        /// An older server keeps the old Agent shape, so the app does not offer an editor whose
        /// Save it would refuse: the page says to update the server and Edit stays disabled.
        @Test("an older server's Agent page says to update the server, and Edit is disabled")
        func olderServerShowsReadOnlyAgent() async throws {
            AgentDetailSkillsURLProtocol.reset()
            defer { AgentDetailSkillsURLProtocol.reset() }
            AgentDetailSkillsURLProtocol.storedAgent = StoredAgentDefinition(
                id: "legacy-agent",
                name: "Legacy",
                icon: .defaultValue,
                description: nil,
                status: .active,
                version: 1,
                definition: AgentDefinition(name: "Legacy", icon: .defaultValue),
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                archivedAt: nil
            )
            let root = try await makeTestAppRoot(
                readyServerId: "agent-detail-legacy-\(UUID().uuidString)",
                apiClient: AgentDetailSkillsURLProtocol.makeClient()
            )
            // `/server/info` has arrived and advertises no `agentCapabilities`.
            root.coordinator.activeConnection.setAgentCapabilitiesForTesting(false)
            let screen = AgentDetailViewController(root: root, agentId: "legacy-agent") { _ in }
            let window = try AgentListViewControllerTests.show(screen)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 2600)
            defer { AgentListViewControllerTests.hide(window) }

            // The sentence holds wherever the page draws it, visible or not.
            var caption: String?
            _ = await waitForMainActorCondition(timeout: .seconds(5)) {
                screen.view.layoutIfNeeded()
                caption = AgentListViewControllerTests.labelTexts(in: screen.view)
                    .first { $0.hasPrefix("Update this server") }
                return caption != nil
            }
            #expect(
                caption == "Update this server to see and edit this Agent’s tools, plugins, MCP servers, and context."
            )
            #expect(
                AgentListViewControllerTests.labelTexts(in: screen.view).contains("Pi Tools") == false,
                "no capability rows for a server that cannot store them"
            )
            let edit = try #require(
                screen.navigationItem.rightBarButtonItems?
                    .first { $0.accessibilityIdentifier == "agents.detail.edit" }
            )
            #expect(!edit.isEnabled, "an older server cannot save the v2 editor")
        }

        @Test("a server that advertises the capability offers the editor")
        func currentServerOffersTheEditor() async throws {
            AgentDetailSkillsURLProtocol.reset()
            defer { AgentDetailSkillsURLProtocol.reset() }
            AgentDetailSkillsURLProtocol.storedAgent = StoredAgentDefinition(
                id: "current-agent",
                name: "Current",
                icon: .defaultValue,
                description: nil,
                status: .active,
                version: 1,
                definition: AgentDefinition(
                    name: "Current",
                    icon: .defaultValue,
                    capabilities: AgentCapabilities(plugins: [], mcp: [:])
                ),
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                archivedAt: nil
            )
            let root = try await makeTestAppRoot(
                readyServerId: "agent-detail-current-\(UUID().uuidString)",
                apiClient: AgentDetailSkillsURLProtocol.makeClient()
            )
            root.coordinator.activeConnection.setAgentCapabilitiesForTesting(true)
            let screen = AgentDetailViewController(root: root, agentId: "current-agent") { _ in }
            let window = try AgentListViewControllerTests.show(screen)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 2600)
            defer { AgentListViewControllerTests.hide(window) }

            let values = await waitForValues(
                ["Pi Tools", "Edits files", "Plugins", "MCP Servers"],
                in: screen
            )
            #expect(values["Pi Tools"] == "Pi standard", "no tool set follows the Pi Tools setting")
            #expect(values["Edits files"] == "Yes")
            #expect(values["Plugins"] == "None")
            #expect(values["MCP Servers"] == "None")
            let edit = try #require(
                screen.navigationItem.rightBarButtonItems?
                    .first { $0.accessibilityIdentifier == "agents.detail.edit" }
            )
            #expect(edit.isEnabled)
        }

        @Test("Agent detail shows the saved capabilities read-only, the same rows the editor writes")
        func agentDetailShowsCapabilities() async throws {
            AgentDetailSkillsURLProtocol.reset()
            defer { AgentDetailSkillsURLProtocol.reset() }
            AgentDetailSkillsURLProtocol.storedAgent = StoredAgentDefinition(
                id: "nanny-agent",
                name: "Nanny",
                icon: .defaultValue,
                description: nil,
                status: .active,
                version: 1,
                definition: AgentDefinition(
                    name: "Nanny",
                    icon: .defaultValue,
                    capabilities: AgentCapabilities(
                        tools: ["read", "bash"],
                        ask: true,
                        notify: false,
                        subagent: false,
                        plugins: ["notebook"],
                        mcp: ["gmail": .tools(["search", "read"]), "coros": .all]
                    ),
                    context: AgentContext(skills: ["nanny"], contextFiles: false)
                ),
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                archivedAt: nil
            )

            let root = try await makeTestAppRoot(
                readyServerId: "agent-detail-capabilities-\(UUID().uuidString)",
                apiClient: AgentDetailSkillsURLProtocol.makeClient()
            )
            // `/server/info` advertises the v2 Agent shape here, as a current server does.
            root.coordinator.activeConnection.setAgentCapabilitiesForTesting(true)
            let screen = AgentDetailViewController(root: root, agentId: "nanny-agent") { _ in }
            let window = try AgentListViewControllerTests.show(screen)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 2000)
            defer { AgentListViewControllerTests.hide(window) }

            let values = await waitForValues(
                ["Pi Tools", "Edits files", "Ask me", "Notify me", "Delegate", "Plugins",
                 "MCP Servers", "Read AGENTS.md", "Read past sessions", "Skills"],
                in: screen
            )
            #expect(values["Pi Tools"] == "read, bash")
            #expect(values["Edits files"] == "No")
            #expect(values["Ask me"] == "Yes")
            #expect(values["Notify me"] == "No")
            #expect(values["Delegate"] == "No")
            #expect(values["Plugins"] == "notebook")
            #expect(values["MCP Servers"] == "coros: all tools, gmail: 2 tools")
            #expect(values["Read AGENTS.md"] == "No")
            #expect(values["Read past sessions"] == "Yes")
            #expect(values["Skills"] == "nanny")
        }

        /// Each row's value, once the page has loaded and drawn the row.
        private func waitForValues(
            _ titles: [String],
            in screen: AgentDetailViewController
        ) async -> [String: String] {
            var values: [String: String] = [:]
            _ = await waitForMainActorCondition(timeout: .seconds(5)) {
                screen.view.layoutIfNeeded()
                let rows = screen.collectionView.visibleCells
                    .flatMap { $0.allAccessibilityElements() }
                for title in titles where values[title] == nil {
                    if let value = rows.first(where: { $0.accessibilityLabel == title })?.accessibilityValue {
                        values[title] = value
                    }
                }
                return values.count == titles.count
            }
            return values
        }

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

        @Test("with no server the page says Server is offline in a row")
        func offlineIsAnInlineRow() async throws {
            AgentsURLProtocol.reset()
            let root = makeTestAppRoot()
            let screen = PiAgentDetailViewController(root: root)
            let window = try AgentListViewControllerTests.show(screen)
            defer { AgentListViewControllerTests.hide(window) }

            #expect(await waitForStateRow(in: screen) { $0.accessibilityLabel == "Server is offline" } != nil)
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

    func allAccessibilityElements() -> [UIView] {
        var found = isAccessibilityElement ? [self] : []
        for subview in subviews { found += subview.allAccessibilityElements() }
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
            // The extension list as a server that predates plugins answers it: a query is
            // refused. Pi's page reads only its tool catalogs, so it must not send one.
            if request.url?.path.hasSuffix("/server/resources/extensions") == true, request.url?.query != nil {
                respond(status: 400, body: Data(#"{"error":"This server-global route accepts no query"}"#.utf8))
                return
            }
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

/// Serves an Agent definition for `AgentDetailViewController` capability tests without
/// contending with `AgentsURLProtocol`.
private final class AgentDetailSkillsURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "agent-detail-skills.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var agentValue: StoredAgentDefinition?

    static var storedAgent: StoredAgentDefinition? {
        get { lock.withLock { agentValue } }
        set { lock.withLock { agentValue = newValue } }
    }

    static func reset() {
        lock.withLock { agentValue = nil }
    }

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentDetailSkillsURLProtocol.self]
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
        let path = request.url?.path ?? ""
        let body: Data?
        if path.hasSuffix("/server/resources/extensions") {
            body = Data(#"{"extensions":[],"builtInTools":[],"optionalTools":[]}"#.utf8)
        } else if path.contains("/agents/"), let agent = Self.storedAgent {
            body = try? JSONEncoder().encode(["agent": agent])
        } else {
            body = nil
        }
        guard let url = request.url, let body, let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
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
