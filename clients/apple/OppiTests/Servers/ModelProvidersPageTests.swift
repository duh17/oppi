import Foundation
import Testing
import UIKit
@testable import Oppi

/// Model Providers and its two sheets, on the list kit: the rows each page
/// draws, what it loads when it appears, and what a host switch does to them.
@Suite("Model providers page")
@MainActor
struct ModelProvidersPageTests {
    private let serverId = "providers-server"

    private func provider(
        _ id: String, name: String, authenticated: Bool, apiKey: Bool = true, oauth: Bool = false
    ) -> ProviderAuthProviderStatus {
        ProviderAuthProviderStatus(
            id: id,
            name: name,
            supportsApiKey: apiKey,
            oauth: oauth ? ProviderAuthOAuthCapabilities(
                flowType: .oauth, supportsServerBrowserLaunch: true, supportsPhoneBrowserLaunch: true,
                supportsManualCodeInput: false, mayPromptForInput: false
            ) : nil,
            authenticated: authenticated,
            credentialType: authenticated ? .apiKey : nil,
            expiresAt: nil,
            maskedKey: authenticated ? "sk-…abcd" : nil
        )
    }

    private func makeRoot() throws -> AppRootEnvironment {
        try makeTestAppRoot(
            readyServerId: serverId,
            apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
    }

    /// Answers each host's provider routes, over the app's own refreshes; a route this test
    /// did not plan fails it, through the scope `useAnswers` returns.
    private static func useAnswers(_ hosts: [String: ProviderHostAnswers]) -> TestURLProtocol.RouteScope {
        TestURLProtocol.routeScope(mockPageRoutes { request in
            try hosts[request.url?.host ?? ""]?.answer(for: request)
        })
    }

    @Test("the page loads the visible server's providers when it appears")
    func providersLoadOnFirstAppearance() async throws {
        let routes = Self.useAnswers(["ready-server.test": ProviderHostAnswers(providers: [
            provider("claude", name: "Claude", authenticated: true),
            provider("gemini", name: "Gemini", authenticated: false, oauth: true),
        ])])
        defer { routes.end() }
        let root = try makeRoot()
        let page = ModelProvidersViewController(target: ModelProvidersNavTarget(serverId: serverId), root: root)
        let window = try show(page)
        defer { hide(window) }

        // No `updateProperties` of our own: the appearance is what loads, and the
        // page takes the server that pass would have taken.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.shownItems.count == 2
        }, "the appearance must load the visible server's providers")
        #expect(page.shownItems == [.provider("claude"), .provider("gemini")])
        #expect(page.sections().map(\.header) == ["Connected", "Available"])
    }

    @Test("a load whose request ends as a cancel keeps its providers and reports no failure")
    func cancelledLoadKeepsProviders() async throws {
        let answers = ProviderHostAnswers(providers: [provider("claude", name: "Claude", authenticated: true)])
        let routes = Self.useAnswers(["ready-server.test": answers])
        defer { routes.end() }
        let root = try makeRoot()
        let page = ModelProvidersViewController(target: ModelProvidersNavTarget(serverId: serverId), root: root)
        let window = try show(page)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.shownItems.contains(.provider("claude"))
        })

        // The next load's request ends as a cancel — what leaving the page, or a
        // refresh replacing this one, produces. That is control flow: the rows
        // this server already showed stay, and nothing is reported as failed.
        let before = answers.statusRequests
        answers.cancelNextStatusRequest()
        page.setNeedsRefresh()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            answers.statusRequests == before + 1
        }, "the second load asked the server")
        // Its answer lands on the main actor a moment later.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!page.sections().contains { $0.id == .error }, "a cancelled request is not a failure to report")
        #expect(page.shownItems.contains(.provider("claude")), "the providers it had stay on screen")
    }

    @Test("a host switch drops the old server's providers and shows the new one's")
    func hostSwitchReloadsTheNewServer() async throws {
        let routes = Self.useAnswers([
            "first-providers.test": ProviderHostAnswers(providers: [provider("claude", name: "Claude", authenticated: true)]),
            "second-providers.test": ProviderHostAnswers(providers: [provider("gemini", name: "Gemini", authenticated: true)]),
        ])
        defer { routes.end() }
        let root = try makeTestAppRoot(readyServers: [
            TestReadyServer(
                id: "providers-first", name: "First", host: "first-providers.test",
                client: makeTestURLProtocolClient(host: "first-providers.test")
            ),
            TestReadyServer(
                id: "providers-second", name: "Second", host: "second-providers.test",
                client: makeTestURLProtocolClient(host: "second-providers.test")
            ),
        ])
        let coordinator = root.coordinator
        let servers = coordinator.serverStore.servers
        let first = try #require(servers.first)
        let second = try #require(servers.dropFirst().first)

        let page = ModelProvidersViewController(target: ModelProvidersNavTarget(serverId: first.id), root: root)
        let window = try show(page)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.shownItems.contains(.provider("claude"))
        }, "the first server's providers load on appearance")

        // The host switcher makes another server active while the page is showing.
        #expect(coordinator.restoreActiveServer(second.id))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.shownItems.contains(.provider("gemini")) && !page.shownItems.contains(.provider("claude"))
        }, "the page follows the switch and loads the new server instead of keeping the old rows")
    }

    @Test("the API key sheet saves the trimmed key and refuses to be swiped away with one typed")
    func apiKeySheetSavesTheTrimmedKey() async throws {
        let routes = Self.useAnswers(["ready-server.test": ProviderHostAnswers(providers: [])])
        defer { routes.end() }
        let root = try makeRoot()
        var saved: String?
        let sheet = ProviderAPIKeyViewController(
            provider: provider("claude", name: "Claude", authenticated: true), root: root
        ) { saved = $0 }
        let window = try show(sheet)
        defer { hide(window) }
        sheet.updateProperties()

        var found: UITextField?
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            sheet.view.layoutIfNeeded()
            found = Self.textField(withIdentifier: "server.modelProviders.apiKey.field", in: sheet.view)
            return found != nil
        }, "the field row appears with the page")
        let field = try #require(found)
        field.text = "  sk-live-key  "
        field.sendActions(for: .editingChanged)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            sheet.navigationItem.rightBarButtonItem?.isEnabled == true
        }, "a key typed is Save's to take")
        #expect(sheet.isModalInPresentation, "a draft must not be swiped away by accident")

        let save = try #require(sheet.navigationItem.rightBarButtonItem)
        try #require(save.primaryAction).performWithSender(save, target: nil)
        #expect(saved == "sk-live-key")
    }

    @Test("a prompt's options show once each, so the list has no repeated row")
    func signInPromptOptionsAreUnique() {
        let attempt = ProviderAuthFlowAttempt(
            flow: ProviderAuthFlowSnapshot(
                flowId: "pa_2", providerId: "claude", flowType: .oauth, launchMode: .none,
                status: .awaitingPrompt,
                auth: nil,
                prompt: ProviderAuthFlowSnapshot.Prompt(
                    message: "Pick one", placeholder: nil, allowEmpty: false,
                    options: [
                        .init(id: "a", label: "A"),
                        .init(id: "a", label: "A again"),
                        .init(id: "b", label: "B"),
                    ]
                ),
                lastProgress: nil, error: nil, createdAt: 0, updatedAt: 1, expiresAt: 600_000
            ),
            client: RefusingProviderAuthClient(),
            serverId: serverId, serverName: "Studio", providerName: "Claude"
        )
        let sheet = ProviderSignInViewController(
            attempt: attempt, root: makeTestAppRoot(), visibleServerId: { nil }, onDone: {}, onCancel: {}
        )
        sheet.loadViewIfNeeded()
        sheet.updateProperties()

        let items = sheet.sections().first(where: { $0.id == .prompt })?.items
        #expect(items == [.option("a"), .option("b")], "a repeated option id would trap the diffable list")
    }

    private func show(_ screen: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        return window
    }

    private func hide(_ window: UIWindow) {
        hideTestWindow(window)
        window.rootViewController = nil
    }

    private static func textField(withIdentifier identifier: String, in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.accessibilityIdentifier == identifier { return field }
        for subview in view.subviews {
            if let found = textField(withIdentifier: identifier, in: subview) { return found }
        }
        return nil
    }
}

/// A sign-in client no test in this file lets a call through.
private final class RefusingProviderAuthClient: ProviderAuthFlowClient, @unchecked Sendable {
    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot {
        throw APIError.invalidResponse
    }

    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot {
        throw APIError.invalidResponse
    }

    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot {
        throw APIError.invalidResponse
    }

    func cancelProviderAuthFlow(flowId: String, reason: String?) async throws -> ProviderAuthFlowSnapshot {
        throw APIError.invalidResponse
    }
}

/// What one host's provider routes answer: the status rows and the quota windows,
/// with a status request that can be made to end as a cancel, the way a request
/// cancelled under its page arrives. Counts the status requests, so a test can tell
/// the one a refresh sent from one it did not.
private final class ProviderHostAnswers: @unchecked Sendable {
    private struct Envelope<Value: Encodable>: Encodable { let providers: Value }

    private let providers: [ProviderAuthProviderStatus]
    private let quotas: ProviderQuotasInfo
    private let lock = NSLock()
    private var cancelsNextStatus = false
    private var statusCount = 0

    init(
        providers: [ProviderAuthProviderStatus],
        quotas: ProviderQuotasInfo = ProviderQuotasInfo(providers: [], fetchedAt: 0)
    ) {
        self.providers = providers
        self.quotas = quotas
    }

    var statusRequests: Int { lock.withLock { statusCount } }

    func cancelNextStatusRequest() { lock.withLock { cancelsNextStatus = true } }

    func answer(for request: URLRequest) throws -> (Data, HTTPURLResponse)? {
        switch request.url?.path {
        case let path? where path.hasSuffix("/provider-auth/status"):
            let cancels = lock.withLock {
                statusCount += 1
                defer { cancelsNextStatus = false }
                return cancelsNextStatus
            }
            if cancels { throw URLError(.cancelled) }
            return try mockJSONResponse(encoding: Envelope(providers: providers), for: request)
        case let path? where path.hasSuffix("/server/provider-quotas"):
            return try mockJSONResponse(encoding: quotas, for: request)
        default:
            return nil
        }
    }
}
