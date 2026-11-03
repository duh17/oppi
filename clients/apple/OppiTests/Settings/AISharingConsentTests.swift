import Foundation
import Testing
import UIKit
@testable import Oppi

/// The one gating decision every send path asks before content leaves the device for a
/// model provider or voice backend (App Review 5.1.2(i)).
@Suite("AI sharing consent")
struct AISharingConsentTests {
    private let defaults: UserDefaults
    private let consent: AISharingConsent
    private let anthropic = AISharingConsent.Recipient.modelProvider("anthropic")

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "AISharingConsentTests.\(UUID().uuidString)"))
        consent = AISharingConsent(defaults: defaults)
    }

    @Test func anUnapprovedProviderIsAskedForInAppAndRefusedWhereNoSheetCanShow() throws {
        let provider = try #require(anthropic)

        #expect(consent.decide([provider], serverId: "s1", canAsk: true) == .ask(provider))
        guard case .refuse(let message) = consent.decide([provider], serverId: "s1", canAsk: false) else {
            Issue.record("Siri and Share must refuse, not send")
            return
        }
        #expect(message.contains("Anthropic"), "the refusal names who would have received it")
        #expect(consent.grants.isEmpty, "refusing never grants")
    }

    @Test func approvalSendsAndWithdrawalAsksAgain() throws {
        let provider = try #require(anthropic)
        consent.grant(provider, serverId: "s1")

        #expect(consent.decide([provider], serverId: "s1", canAsk: true) == .send)
        #expect(consent.decide([provider], serverId: "s1", canAsk: false) == .send)

        consent.withdraw(provider, serverId: "s1")
        #expect(consent.decide([provider], serverId: "s1", canAsk: true) == .ask(provider))
        if case .send = consent.decide([provider], serverId: "s1", canAsk: false) {
            Issue.record("a withdrawn provider must not be sent to from Siri or Share")
        }
    }

    @Test func aGrantCoversOnlyItsServerAndProvider() throws {
        let provider = try #require(anthropic)
        let other = try #require(AISharingConsent.Recipient.modelProvider("openrouter"))
        consent.grant(provider, serverId: "s1")

        #expect(consent.decide([provider], serverId: "s2", canAsk: true) == .ask(provider))
        #expect(consent.decide([other], serverId: "s1", canAsk: true) == .ask(other))
    }

    @Test func aProviderThatCannotBeNamedIsRefusedEvenInApp() {
        for canAsk in [true, false] {
            #expect(
                consent.decide([nil], serverId: "s1", canAsk: canAsk)
                    == .refuse(AISharingConsent.unknownProviderMessage)
            )
        }
    }

    @Test func liveVoiceNeedsBothTheModelProviderAndTheVoiceBackend() throws {
        let provider = try #require(anthropic)
        let voice = AISharingConsent.Recipient.voice(.liveVoice, target: "xAI")
        consent.grant(provider, serverId: "s1")

        #expect(consent.decide([provider, voice], serverId: "s1", canAsk: true) == .ask(voice))
        consent.grant(voice, serverId: "s1")
        #expect(consent.decide([provider, voice], serverId: "s1", canAsk: true) == .send)
    }

    @Test func switchingTheVoiceBackendAsksAgain() {
        let xai = AISharingConsent.Recipient.voice(.dictation, target: "xAI")
        let local = AISharingConsent.Recipient.voice(.dictation, target: "http://127.0.0.1:7936")
        consent.grant(xai, serverId: "s1")

        #expect(consent.decide([local], serverId: "s1", canAsk: true) == .ask(local))
        #expect(
            consent.decide([AISharingConsent.Recipient.voice(.liveVoice, target: "xAI")], serverId: "s1", canAsk: true)
                != .send,
            "dictation consent does not cover a Live Voice call"
        )
    }

    @Test func voiceBackendsAreNamedByWhereTheAudioGoes() {
        let xai = AISharingConsent.Recipient.voice(.liveVoice, target: "xAI")
        #expect(xai.name == "xAI")
        #expect(!xai.isOnServerComputer)

        for loopback in ["http://127.0.0.1:7936", "http://localhost:7936", "http://[::1]:7936"] {
            #expect(AISharingConsent.Recipient.voice(.dictation, target: loopback).isOnServerComputer, "\(loopback)")
        }

        let remote = AISharingConsent.Recipient.voice(.dictation, target: "https://asr.example.com")
        #expect(remote.name == "asr.example.com")
        #expect(!remote.isOnServerComputer)

        #expect(AISharingConsent.Recipient.voice(.dictation, target: nil).id == "server")
    }

    @Test func removingAServerDropsOnlyItsGrants() throws {
        let provider = try #require(anthropic)
        consent.grant(provider, serverId: "s1")
        consent.grant(provider, serverId: "s2")

        consent.withdrawAll(serverId: "s1")

        #expect(consent.decide([provider], serverId: "s1", canAsk: true) == .ask(provider))
        #expect(consent.decide([provider], serverId: "s2", canAsk: true) == .send)
    }

    @Test func theProviderIsTheChosenModelsOrElseTheServerDefault() {
        let catalog = [
            catalogModel("claude-sonnet", "anthropic", isDefault: true),
            // An OpenRouter id carries its own slash; its provider is the catalog's.
            catalogModel("openai/gpt-5", "openrouter"),
        ]

        #expect(provider(nil, catalog) == "anthropic")
        #expect(provider("openai/gpt-5", catalog) == "openrouter")
        #expect(provider("openrouter/openai/gpt-5", catalog) == "openrouter")
        #expect(provider("xai/grok-4", catalog) == "xai")
        #expect(provider(nil, []) == nil)
        #expect(provider("bare-model", []) == nil)
    }

    @Test func aShortIdSeveralProvidersServeNamesNoProvider() {
        // An older server lists short ids, and two of its providers serve this one.
        let older = [catalogModel("claude-sonnet-5", "anthropic"), catalogModel("claude-sonnet-5", "github-copilot")]
        #expect(provider("claude-sonnet-5", older) == nil, "either provider could get it, so neither is named")
        #expect(provider("github-copilot/claude-sonnet-5", older) == "github-copilot")
        #expect(provider("anthropic/claude-sonnet-5", older) == "anthropic")

        // Current servers list full ids: a short id is still only one provider's when no other serves it.
        let current = [
            catalogModel("anthropic/claude-sonnet-5", "anthropic"),
            catalogModel("github-copilot/claude-sonnet-5", "github-copilot"),
            catalogModel("openai/gpt-5", "openai"),
        ]
        #expect(provider("claude-sonnet-5", current) == nil)
        #expect(provider("gpt-5", current) == "openai")
        #expect(provider("github-copilot/claude-sonnet-5", current) == "github-copilot")
    }

    @Test func withNoModelChosenTheProviderIsTheServerDefaultsEvenWhenItsIdIsShared() {
        let catalog = [
            catalogModel("claude-sonnet-5", "anthropic"),
            catalogModel("claude-sonnet-5", "github-copilot", isDefault: true),
        ]
        let recipient = AISharingConsent.Recipient.modelProvider(modelId: nil, catalog: catalog)
        #expect(recipient?.id == "github-copilot")
        #expect(recipient?.name == "GitHub Copilot")
        #expect(provider(nil, [catalogModel("claude-sonnet-5", "anthropic")]) == nil, "no default listed")
    }

    @Test func aModelOnTheServersComputerIsNotCalledAThirdParty() throws {
        // The server reports a loopback model as `authKind: "local"`.
        let json = #"""
        [{"id":"omlx/glm-5","name":"GLM","provider":"omlx","contextWindow":1000,"authKind":"local","isDefault":true},
         {"id":"anthropic/claude-sonnet-5","name":"Sonnet","provider":"anthropic","contextWindow":1000,"authKind":"apiKey"}]
        """#
        let catalog = try JSONDecoder().decode([ModelInfo].self, from: Data(json.utf8))

        let local = try #require(AISharingConsent.Recipient.modelProvider(modelId: nil, catalog: catalog))
        #expect(local.isOnServerComputer)
        let localCopy = AISharingConsentSheetViewController.Copy.message(for: local)
        #expect(!localCopy.contains("third-party"))
        #expect(localCopy.contains("same computer as your server"))

        let cloud = try #require(AISharingConsent.Recipient.modelProvider(modelId: "anthropic/claude-sonnet-5", catalog: catalog))
        #expect(!cloud.isOnServerComputer)
        #expect(AISharingConsentSheetViewController.Copy.message(for: cloud).contains("third-party"))
    }

    /// A `GET /models` row, as the app decodes it.
    private func catalogModel(_ id: String, _ provider: String, isDefault: Bool = false) -> ModelInfo {
        ModelInfo(id: id, name: id, provider: provider, contextWindow: 200_000, isDefault: isDefault)
    }

    private func provider(_ modelId: String?, _ catalog: [ModelInfo]) -> String? {
        AISharingConsent.Recipient.modelProvider(modelId: modelId, catalog: catalog)?.id
    }
}

@MainActor
@Suite("Server dictation consent")
struct ServerDictationConsentTests {
    @Test func notNowRecordsNothingAndAllowRecords() async throws {
        for allowed in [false, true] {
            let systemAccess = MockVoiceInputSystemAccess()
            systemAccess.allowServerDictationResult = allowed
            let provider = MockVoiceProvider(id: .oppiServer, engine: .serverDictation)
            provider.makeSessionHandler = { _, _ in MockVoiceSession() }
            let manager = VoiceInputManager(
                providerRegistry: VoiceProviderRegistry(providers: [provider]),
                systemAccess: systemAccess
            )
            manager.setEngineMode(.remote)
            let connection = ServerConnection()
            connection.setSplitStreamCapabilitiesForTesting(dictationStream: true)
            manager.setServerConnection(connection)
            manager.setServerCredentials(ServerCredentials(
                host: "localhost", port: 7749, token: "test-token", name: "test", scheme: .http
            ))

            if allowed {
                try await manager.startRecording(source: "test")
                #expect(manager.isRecording)
                await manager.cancelRecording()
            } else {
                await #expect(throws: CancellationError.self) { try await manager.startRecording(source: "test") }
                #expect(!manager.isRecording)
                #expect(provider.makeSessionCallCount == 0, "no audio stream opens without consent")
            }
            #expect(systemAccess.allowServerDictationRequests.map(\.recipient.kind) == [.dictation])
        }
    }
}

/// Each in-app send that carries the person's content waits for the consent sheet: nothing
/// leaves before Allow, Not Now keeps what they entered, and Allow sends it. Driven through
/// the real screens in a window, with the sheet's own buttons.
@MainActor
@Suite("AI sharing consent before each send", .serialized)
struct AISharingConsentGateTests {
    @Test func quickSessionWithNoModelChosenNamesTheServerDefaultsProvider() async throws {
        let serverId = "sha256:consent-quick-\(UUID().uuidString)"
        defer { AISharingConsent.device.withdrawAll(serverId: serverId) }
        // Nothing may reach the server before Allow: a route it did not plan fails the test.
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        defer { routes.end() }
        let root = try await makeTestAppRoot(
            readyServerId: serverId,
            apiClient: makeTestURLProtocolClient(host: "consent-quick.test")
        )
        // An older server's short ids: two providers serve the default's.
        root.coordinator.activeConnection.chatState.cachedModels = [
            ModelInfo(id: "claude-sonnet-5", name: "Sonnet", provider: "anthropic", contextWindow: 200_000),
            ModelInfo(id: "claude-sonnet-5", name: "Sonnet", provider: "github-copilot", contextWindow: 200_000, isDefault: true),
        ]
        let model = QuickSessionModel(root: root)
        model.selectedWorkspace = makeTestWorkspace()
        model.text = "Plan the release"
        let window = ConsentWindow(UIViewController())
        defer { window.close() }

        model.handleSend()

        let sheet = try #require(await window.consentSheet())
        #expect(sheet.title == "Send to GitHub Copilot?", "the session goes to the server default's provider")
        sheet.answer(.notNow)
        #expect(await window.consentSheetCloses())
        #expect(model.text == "Plan the release")
        #expect(!model.isCreating)
    }

    @Test func anAnswerToAnExtensionQuestionWaitsForConsentAndNotNowKeepsIt() async throws {
        let fixture = try await ConsentChat()
        defer { fixture.close() }
        let ask = AskRequest(
            id: "ask-consent",
            sessionId: fixture.sessionId,
            questions: [AskQuestion(id: "q1", question: "Which branch?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        fixture.connection.askRequestStore.set(ask, for: fixture.sessionId)
        let input = try #require(await fixture.window.view(UITextView.self, "chat.input"))

        input.text = "the release branch"
        input.delegate?.textViewDidChange?(input)
        try #require(await fixture.window.view(UIButton.self, "chat.send")).sendActions(for: .touchUpInside)

        let sheet = try #require(await fixture.window.consentSheet())
        #expect(sheet.title == "Send to Anthropic?")
        #expect(fixture.answers.isEmpty, "nothing leaves before Allow")
        sheet.answer(.notNow)
        #expect(await fixture.window.consentSheetCloses())
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) { input.text == "the release branch" }, "Not Now puts the answer back")
        #expect(fixture.answers.isEmpty)

        try #require(await fixture.window.view(UIButton.self, "chat.send")).sendActions(for: .touchUpInside)
        try #require(await fixture.window.consentSheet()).answer(.allow)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { fixture.answers.map(\.id) == ["ask-consent"] })
        #expect(fixture.answers.first?.value == #"{"q1":"the release branch"}"#)
    }

    @Test func aComposerCommandThatSendsNothingToAModelDoesNotAsk() async throws {
        let fixture = try await ConsentChat()
        defer { fixture.close() }
        let input = try #require(await fixture.window.view(UITextView.self, "chat.input"))

        input.text = "/reload"
        input.delegate?.textViewDidChange?(input)
        try #require(await fixture.window.view(UIButton.self, "chat.send")).sendActions(for: .touchUpInside)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { fixture.reloads == 1 }, "/reload runs at once")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) {
            fixture.window.presentedConsentSheet == nil
        }, "/reload sends nothing to a model, so nothing asks")
    }

    @Test func aBranchSummaryWaitsForConsentAndNotNowKeepsItsInstructions() async throws {
        let fixture = try await ConsentChat()
        defer { fixture.close() }
        let outline = try #require(fixture.chat.makeOutlineController() as? SessionOutlineViewController)
        let sheet = RouterNavigationController(rootViewController: outline)
        fixture.host.present(sheet, animated: false)
        outline.loadViewIfNeeded()

        let layout = try #require(outline.view.allSubviews(of: UISegmentedControl.self).first)
        layout.selectedSegmentIndex = 1
        layout.sendActions(for: .valueChanged)
        let lists = outline.view.allSubviews(of: UICollectionView.self)
        let tree = try #require(lists.last)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            tree.numberOfSections > 0 && tree.numberOfItems(inSection: 0) > 0
        }, "the tree never loaded")
        outline.collectionView(tree, didSelectItemAt: IndexPath(item: 0, section: 0))
        let options = try #require(await fixture.window.presented(UIAlertController.self))
        try options.press("Summarize with custom instructions")

        let instructions = try #require(await fixture.window.presented(TreeSummaryInstructionsViewController.self))
        let field = try #require(await fixture.window.view(UITextView.self, "tree-summary-instructions"))
        field.insertText("Keep the TODOs")
        let navigate = try #require(instructions.navigationItem.rightBarButtonItem)
        navigate.primaryAction?.performWithSender(nil, target: nil)

        let consent = try #require(await fixture.window.consentSheet())
        #expect(fixture.navigations.isEmpty, "nothing leaves before Allow")
        consent.answer(.notNow)
        #expect(await fixture.window.consentSheetCloses())
        #expect(fixture.navigations.isEmpty)
        #expect(instructions.viewIfLoaded?.window != nil, "Not Now leaves the instructions on screen")
        #expect(field.text == "Keep the TODOs")

        navigate.primaryAction?.performWithSender(nil, target: nil)
        try #require(await fixture.window.consentSheet()).answer(.allow)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { fixture.navigations.count == 1 })
        #expect(fixture.navigations.first?.summarize == true)
        #expect(fixture.navigations.first?.instructions == "Keep the TODOs")
    }
}

/// A chat on a session whose model is Anthropic's, on a server this device has allowed
/// nothing on. Records what it sends and answers the tree commands.
@MainActor
private final class ConsentChat {
    let sessionId = "consent-chat-\(UUID().uuidString)"
    let serverId = "sha256:consent-chat-\(UUID().uuidString)"
    let connection: ServerConnection
    let chat: ChatViewController
    let host: UINavigationController
    let window: ConsentWindow
    private(set) var answers: [(id: String, value: String?)] = []
    private(set) var navigations: [(summarize: Bool, instructions: String?)] = []
    private(set) var reloads = 0

    init() async throws {
        let (connection, pipe) = await makeTestConnection(sessionId: sessionId, fingerprint: serverId)
        self.connection = connection
        connection.setAPIClientForTesting(nil)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready, model: "anthropic/claude-sonnet-5"))
        connection.chatState.cachedModels = [
            ModelInfo(id: "anthropic/claude-sonnet-5", name: "Sonnet", provider: "anthropic", contextWindow: 200_000),
            ModelInfo(id: "github-copilot/claude-sonnet-5", name: "Sonnet", provider: "github-copilot", contextWindow: 200_000, isDefault: true),
        ]
        let sessionId = sessionId
        chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: AppNavigation())
        host = UINavigationController(rootViewController: chat)
        window = ConsentWindow(host)
        connection._sendMessageForTesting = { [weak self] message in
            switch message {
            case .extensionUIResponse(let id, let value, _, _, _):
                self?.answers.append((id, value))
            case .getSessionTree(_, let requestId):
                pipe.handle(.commandResult(
                    command: "get_session_tree", requestId: requestId, success: true,
                    data: .object([
                        "leafId": .string("leaf"),
                        "nodes": .array([
                            Self.node("root", parent: nil, depth: 0, leaf: true, text: "Start here"),
                            Self.node("leaf", parent: "root", depth: 1, leaf: true, text: "Latest"),
                        ]),
                    ]),
                    error: nil
                ), sessionId: sessionId)
            case .reload(let requestId):
                self?.reloads += 1
                pipe.handle(.commandResult(
                    command: "reload", requestId: requestId, success: true, data: nil, error: nil
                ), sessionId: sessionId)
            case .navigateTree(_, let summarize, let instructions, _, _, let requestId):
                self?.navigations.append((summarize, instructions))
                pipe.handle(.commandResult(
                    command: "navigate_tree", requestId: requestId, success: true,
                    data: .object(["cancelled": .bool(false)]), error: nil
                ), sessionId: sessionId)
            default:
                break
            }
        }
        _ = connection.focusedSessionStore.focus(sessionId: sessionId)
    }

    func close() {
        AISharingConsent.device.withdrawAll(serverId: serverId)
        window.close()
    }

    private static func node(_ id: String, parent: String?, depth: Int, leaf: Bool, text: String) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("message"),
            "timestamp": .string("2026-01-01T00:00:00Z"),
            "depth": .number(Double(depth)),
            "isLeafPath": .bool(leaf),
            "role": .string("user"),
            "textPreview": .string(text),
        ]
        if let parent { fields["parentId"] = .string(parent) }
        return .object(fields)
    }
}

/// A key window in the test host's scene, and lookups for the consent sheet over it.
@MainActor
private final class ConsentWindow {
    let window: UIWindow

    init(_ root: UIViewController) {
        window = makeSceneWindow()
        window.traitOverrides.appRootEnvironment = makeTestAppRoot()
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
    }

    func close() {
        window.rootViewController?.dismiss(animated: false)
        hideTestWindow(window)
        window.rootViewController = nil
    }

    func presented<T: UIViewController>(_ type: T.Type) async -> T? { await ConsentSheet.presented(type, in: window) }

    func consentSheet() async -> ConsentSheet? { await ConsentSheet.find(in: window) }

    func consentSheetCloses() async -> Bool { await ConsentSheet.closes(in: window) }

    /// The consent sheet over the window right now, if any.
    var presentedConsentSheet: AISharingConsentSheetViewController? {
        var top = window.rootViewController
        while let next = top?.presentedViewController {
            if let sheet = next as? AISharingConsentSheetViewController { return sheet }
            top = next
        }
        return nil
    }

    /// A view with `identifier` anywhere in the window, presented screens included.
    func view<T: UIView>(_ type: T.Type, _ identifier: String) async -> T? {
        var found: T?
        _ = await waitForMainActorCondition(timeout: .seconds(5)) { [self] in
            window.layoutIfNeeded()
            found = window.allSubviews(of: type).last { $0.accessibilityIdentifier == identifier }
            return found != nil
        }
        return found
    }
}

/// The AI sharing consent sheet over a test window, answered with its own buttons.
@MainActor
struct ConsentSheet {
    enum Answer: String { case allow = "aiConsent.allow", notNow = "aiConsent.notNow" }

    let controller: AISharingConsentSheetViewController

    static func find(in window: UIWindow) async -> ConsentSheet? {
        await presented(AISharingConsentSheetViewController.self, in: window).map(ConsentSheet.init)
    }

    static func closes(in window: UIWindow) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) {
            var top = window.rootViewController
            while let next = top?.presentedViewController {
                if next is AISharingConsentSheetViewController { return false }
                top = next
            }
            return true
        }
    }

    /// The front-most presented controller of `type` over `window`, once it is on screen.
    static func presented<T: UIViewController>(_ type: T.Type, in window: UIWindow) async -> T? {
        var found: T?
        _ = await waitForMainActorCondition(timeout: .seconds(5)) {
            var top = window.rootViewController
            found = nil
            while let next = top?.presentedViewController {
                if let match = (next as? T) ?? ((next as? UINavigationController)?.topViewController as? T),
                   !next.isBeingPresented, next.viewIfLoaded?.window != nil {
                    found = match
                }
                top = next
            }
            return found != nil
        }
        return found
    }

    var title: String? {
        controller.view.allSubviews(of: UILabel.self).first { $0.accessibilityIdentifier == "aiConsent.title" }?.text
    }

    func answer(_ answer: Answer) {
        controller.view.allSubviews(of: UIButton.self)
            .first { $0.accessibilityIdentifier == answer.rawValue }?
            .sendActions(for: .primaryActionTriggered)
    }
}

private extension UIAlertController {
    /// Taps a button the way UIKit does: the alert closes, then its handler runs.
    func press(_ title: String) throws {
        let action = try #require(actions.first { $0.title == title }, "no \(title) button")
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let block = unsafeBitCast(try #require(action.value(forKey: "handler") as AnyObject?), to: Handler.self)
        dismiss(animated: false)
        block(action)
    }
}

private extension UIView {
    func allSubviews<T: UIView>(of type: T.Type) -> [T] {
        var found = (self as? T).map { [$0] } ?? []
        for subview in subviews { found += subview.allSubviews(of: type) }
        return found
    }
}
