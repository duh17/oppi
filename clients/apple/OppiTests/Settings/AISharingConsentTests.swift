import Foundation
import Testing
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
        let catalog: [AISharingConsent.CatalogModel] = [
            .init(id: "claude-sonnet", provider: "anthropic", isDefault: true),
            // An OpenRouter id carries its own slash; its provider is the catalog's.
            .init(id: "openai/gpt-5", provider: "openrouter"),
        ]

        #expect(AISharingConsent.modelProviderKey(modelId: nil, catalog: catalog) == "anthropic")
        #expect(AISharingConsent.modelProviderKey(modelId: "openai/gpt-5", catalog: catalog) == "openrouter")
        #expect(AISharingConsent.modelProviderKey(modelId: "openrouter/openai/gpt-5", catalog: catalog) == "openrouter")
        #expect(AISharingConsent.modelProviderKey(modelId: "xai/grok-4", catalog: catalog) == "xai")
        #expect(AISharingConsent.modelProviderKey(modelId: nil, catalog: []) == nil)
        #expect(AISharingConsent.modelProviderKey(modelId: "bare-model", catalog: []) == nil)
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
