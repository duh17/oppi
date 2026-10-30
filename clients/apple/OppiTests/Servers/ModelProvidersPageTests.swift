import Foundation
import Testing
import UIKit
@testable import Oppi

/// Model Providers and its two sheets, on the list kit: the rows each page
/// draws, what it loads when it appears, and what a host switch does to them.
@Suite("Model providers page", .serialized)
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

    private func makeRoot(providers: [ProviderAuthProviderStatus]) throws -> AppRootEnvironment {
        try makeTestAppRoot(
            readyServerId: serverId,
            apiClient: ProvidersURLProtocol.makeClient(providers: providers)
        )
    }

    @Test("the page loads the visible server's providers when it appears")
    func providersLoadOnFirstAppearance() async throws {
        let root = try makeRoot(providers: [
            provider("claude", name: "Claude", authenticated: true),
            provider("gemini", name: "Gemini", authenticated: false, oauth: true),
        ])
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
        let root = try makeRoot(providers: [provider("claude", name: "Claude", authenticated: true)])
        let page = ModelProvidersViewController(target: ModelProvidersNavTarget(serverId: serverId), root: root)
        let window = try show(page)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.shownItems.contains(.provider("claude"))
        })

        // The next load's request ends as a cancel — what leaving the page, or a
        // refresh replacing this one, produces. That is control flow: the rows
        // this server already showed stay, and nothing is reported as failed.
        let before = ProvidersURLProtocol.statusRequests
        ProvidersURLProtocol.cancelNextStatusRequest()
        page.setNeedsRefresh()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            ProvidersURLProtocol.statusRequests == before + 1
        }, "the second load asked the server")
        // Its answer lands on the main actor a moment later.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!page.sections().contains { $0.id == .error }, "a cancelled request is not a failure to report")
        #expect(page.shownItems.contains(.provider("claude")), "the providers it had stay on screen")
    }

    @Test("a host switch drops the old server's providers and shows the new one's")
    func hostSwitchReloadsTheNewServer() async throws {
        let serverStore = ServerStore()
        let first = try #require(PairedServer(
            from: ServerCredentials(
                host: ProvidersURLProtocol.firstHost, port: 7749, token: "sk_test", name: "First",
                scheme: .https, serverFingerprint: "providers-first"
            ),
            sortOrder: 0
        ))
        let second = try #require(PairedServer(
            from: ServerCredentials(
                host: ProvidersURLProtocol.secondHost, port: 7749, token: "sk_test", name: "Second",
                scheme: .https, serverFingerprint: "providers-second"
            ),
            sortOrder: 1
        ))
        serverStore.replaceServersForPreview([first, second])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        coordinator.ensureConnection(for: first).setAPIClientForTesting(ProvidersURLProtocol.makeClient(
            host: ProvidersURLProtocol.firstHost,
            providers: [provider("claude", name: "Claude", authenticated: true)],
            quotas: ProviderQuotasInfo(providers: [], fetchedAt: 0)
        ))
        coordinator.ensureConnection(for: second).setAPIClientForTesting(ProvidersURLProtocol.makeClient(
            host: ProvidersURLProtocol.secondHost,
            providers: [provider("gemini", name: "Gemini", authenticated: true)],
            quotas: ProviderQuotasInfo(providers: [], fetchedAt: 0)
        ))
        #expect(coordinator.restoreActiveServer(first.id))
        let root = makeTestAppRoot(coordinator: coordinator)

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
        let root = try makeRoot(providers: [])
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

/// Answers the provider status and quota requests per host, so a test can tell
/// one server's rows from another's, and can answer the next status request as
/// a cancel, the way a request cancelled under its page arrives.
private final class ProvidersURLProtocol: URLProtocol, @unchecked Sendable {
    static let firstHost = "first-providers.test"
    static let secondHost = "second-providers.test"

    private struct Envelope<Value: Encodable>: Encodable { let providers: Value }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: (providers: [ProviderAuthProviderStatus], quotas: ProviderQuotasInfo)] = [:]
    nonisolated(unsafe) private static var cancelsStatus = false
    nonisolated(unsafe) private static var statusRequestCount = 0

    static func makeClient(
        host: String = "ready-server.test",
        providers: [ProviderAuthProviderStatus],
        quotas: ProviderQuotasInfo = ProviderQuotasInfo(providers: [], fetchedAt: 0)
    ) -> APIClient {
        lock.lock()
        answers[host] = (providers, quotas)
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProvidersURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host):7749") ?? URL(fileURLWithPath: "/"),
            token: "sk_test",
            configuration: configuration
        )
    }

    static var statusRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return statusRequestCount
    }

    /// The next status request answers as a cancelled request, once.
    static func cancelNextStatusRequest() {
        lock.lock()
        cancelsStatus = true
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        [firstHost, secondHost, "ready-server.test"].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let isStatus = url.path.hasSuffix("/provider-auth/status")
        if isStatus { Self.statusRequestCount += 1 }
        let cancels = isStatus && Self.cancelsStatus
        if cancels { Self.cancelsStatus = false }
        let answer = Self.answers[host]
        Self.lock.unlock()
        if cancels {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        var body = Data(#"{"error":"not found"}"#.utf8)
        var status = 404
        if let answer {
            if url.path.hasSuffix("/provider-auth/status") {
                body = (try? JSONEncoder().encode(Envelope(providers: answer.providers))) ?? body
                status = 200
            } else if url.path.hasSuffix("/server/provider-quotas") {
                body = (try? JSONEncoder().encode(answer.quotas)) ?? body
                status = 200
            }
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
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
