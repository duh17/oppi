import Foundation
import Speech
import SwiftUI
import Testing
@testable import Oppi

@Suite("Dictation hint extractor")
struct DictationHintExtractorTests {
    @Test func ranksBackticksThenWikiThenIdentifiers() {
        let phrases = DictationHintExtractor.extract(
            from: """
                Use `VoiceInputManager.shared` and `setContext` before start.
                See [[DictationHintExtractor.swift|Hint Extractor]].
                AnalysisContext.contextualStrings should include FooBar.
                """
        )

        #expect(phrases == [
            "VoiceInputManager.shared",
            "setContext",
            "Hint Extractor",
            "DictationHintExtractor.swift",
            "AnalysisContext.contextualStrings",
            "FooBar",
        ])
        #expect(!phrases.contains("Oppi"))
        #expect(!phrases.contains("Yuwp"))
    }

    @Test func capsExtractedPhrasesAt100() {
        let text = (0..<120).map { "`Token\($0)`" }.joined(separator: " ")
        let phrases = DictationHintExtractor.extract(from: text)

        #expect(phrases.count == DictationHintExtractor.maxPhraseCount)
        #expect(phrases.first == "Token0")
        #expect(phrases.last == "Token99")
        #expect(!phrases.contains("Token100"))
    }

    @Test func keepsShortBacktickPhrasesAndDropsPauseOrLongSpans() {
        let phrases = DictationHintExtractor.extract(
            from: """
                Prefer `contextual strings` and skip `please set the context before you start`.
                Also skip `hello, world` because of the pause.
                """
        )

        #expect(phrases.contains("contextual strings"))
        #expect(!phrases.contains("please set the context before you start"))
        #expect(!phrases.contains("hello, world"))
        #expect(!phrases.contains(where: { $0.contains(",") }))
    }

    @Test func extractsIdentifiersFromLongBacktickSpans() {
        let phrases = DictationHintExtractor.extract(
            from: "Call `AppleOnDeviceVoiceProvider.setContext before start` now."
        )

        #expect(phrases.contains("AppleOnDeviceVoiceProvider.setContext"))
        #expect(!phrases.contains("AppleOnDeviceVoiceProvider.setContext before start"))
    }

    @Test func ignoresGenericProseAndDoesNotInjectProductGlossary() {
        let phrases = DictationHintExtractor.extract(from: "Hello, how can I help you today?")
        #expect(phrases.isEmpty)
    }

    @Test func mergeKeepsPrimaryOrderDedupesAndCapsAt100() {
        let primary = (0..<90).map { "Primary\($0)" }
        let extra = ["Primary1", "ExtraA", "extraa", "ExtraB"] + (0..<20).map { "More\($0)" }
        let merged = DictationHintExtractor.merge(primary: primary, extra: extra)

        #expect(merged.count == 100)
        #expect(merged.prefix(90).elementsEqual(primary))
        #expect(merged[90] == "ExtraA")
        #expect(merged[91] == "ExtraB")
        #expect(!merged.contains { $0.caseInsensitiveCompare("extraa") == .orderedSame && $0 != "ExtraA" })
        #expect(merged.contains("More7"))
        #expect(!merged.contains("More8"))
    }

    @Test func truncatedSourceStripsFencedCodeAndCapsCharacters() {
        let source = """
            Keep VoiceInputManager.
            ```swift
            dump(theWholeToolTrace())
            ```
            """ + String(repeating: "x", count: 5_000)
        let truncated = DictationHintExtractor.truncatedSource(from: source)

        #expect(truncated.contains("VoiceInputManager"))
        #expect(!truncated.contains("dump(theWholeToolTrace())"))
        #expect(truncated.count <= DictationHintExtractor.maxFoundationModelCharacters)
    }

    @Test func lastAssistantMessageSkipsTrailingToolCalls() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "hi", timestamp: Date()),
            .assistantMessage(id: "a1", text: "Use `AlphaToken` here.", timestamp: Date()),
            .toolCall(
                id: "t1",
                tool: "read",
                argsSummary: "file",
                outputPreview: "huge tool trace",
                outputByteCount: 12,
                isError: false,
                isDone: true
            ),
        ]

        #expect(
            DictationHintExtractor.lastAssistantMessageText(in: items)
                == "Use `AlphaToken` here."
        )
        #expect(DictationHintExtractor.lastAssistantMessageText(in: []) == nil)
    }
}

@Suite("Dictation hint preferences", .serialized)
struct DictationHintPreferenceTests {
    @Test func foundationModelDictationHintsDefaultOff() {
        let key = AppPreferenceStore.Voice.foundationModelDictationHintsEnabledKey
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { restorePreference(original, forKey: key) }

        #expect(!AppPreferences.Voice.isFoundationModelDictationHintsEnabled)
        #expect(!AppPreferenceStore.Voice.isFoundationModelDictationHintsEnabled)
    }

    @Test func persistsFoundationModelDictationHintsChoice() {
        let key = AppPreferenceStore.Voice.foundationModelDictationHintsEnabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { restorePreference(original, forKey: key) }

        AppPreferences.Voice.setFoundationModelDictationHintsEnabled(true)
        #expect(AppPreferences.Voice.isFoundationModelDictationHintsEnabled)

        AppPreferences.Voice.setFoundationModelDictationHintsEnabled(false)
        #expect(!AppPreferences.Voice.isFoundationModelDictationHintsEnabled)
    }

    @Test func settingsExplainOnDeviceOnlyFoundationModelHints() throws {
        let settings = try appleSource("Oppi/Features/Settings/SettingsView.swift")
        #expect(settings.contains("Improve dictation with Foundation Model"))
        #expect(settings.contains("The Foundation Model runs on this iPhone"))
        #expect(settings.contains("Server dictation sends selected vocabulary"))
        #expect(settings.contains("isFoundationModelDictationHintsEnabled"))
        #expect(!settings.contains("never leaves this iPhone"))
    }

    @Test func chatPrecomputesHintsWhenAssistantMessageLands() throws {
        let chat = try appleSource("Oppi/Features/Chat/ChatView.swift")
        #expect(chat.contains("updateConversationHints("))
        #expect(chat.contains("fromAssistantMessage:"))
        #expect(chat.contains("reducer.renderVersion"))
        #expect(chat.contains("DictationHintExtractor.lastAssistantMessageText"))
        #expect(chat.contains("clearConversationHints(ifOwnedBy: oldId)"))
        #expect(chat.contains("clearConversationHints(ifOwnedBy: sessionId)"))
        #expect(chat.contains("ComposerShared.prepareConversationVoiceInput("))
        #expect(chat.contains("activateConversationComposer("))
        #expect(chat.contains("onPrepareVoiceInput: prepareChatVoiceInput"))
        let prepare = try sourceSlice(
            chat,
            start: "private func prepareChatVoiceInput(_ manager: VoiceInputManager) async throws {",
            end: "private func activateChatVoiceComposer(_ manager: VoiceInputManager) {"
        )
        #expect(prepare.contains("DictationHintExtractor.lastAssistantMessageText(in: reducer.items)"))
        #expect(prepare.contains("ComposerShared.prepareConversationVoiceInput("))
        #expect(!prepare.contains("activateChatVoiceComposer("))
        let refresh = try sourceSlice(
            chat,
            start: "private func refreshDictationHints() {",
            end: "private var chatDictationServerId: String? {"
        )
        #expect(!refresh.contains("activeSessionId = sessionId"))
        #expect(refresh.contains("serverId: serverId"))
    }

    @Test func startRecordingDoesNotExtractHints() throws {
        let source = try appleSource("Oppi/Core/Services/VoiceInputManager.swift")
        let body = try sourceSlice(
            source,
            start: "func startRecording(keyboardLanguage: String? = nil, source: String = \"unknown\") async throws {",
            end: "func stopRecording() async -> String {"
        )
        #expect(!body.contains("DictationHintExtractor"))
        #expect(!body.contains("updateConversationHints"))
        #expect(body.contains("freezeAuthorizedTake()"))
        #expect(body.contains("frozenTake.phrases"))
    }

    @Test func onDeviceSessionSetsContextBeforeStart() throws {
        let source = try appleSource("Oppi/Core/Services/AppleOnDeviceVoiceProvider.swift")
        let body = try sourceSlice(
            source,
            start: "func start() async throws -> VoiceSessionStartTimings {",
            end: "func stop() async {"
        )
        #expect(body.contains("setContext("))
        #expect(body.contains("start(inputSequence:"))
        let setContext = try #require(body.range(of: "setContext(")?.lowerBound)
        let start = try #require(body.range(of: "start(inputSequence:")?.lowerBound)
        #expect(setContext < start)
    }
}

@Suite("Dictation hint wiring", .serialized)
@MainActor
struct DictationHintWiringTests {
    @Test func analysisContextUsesGeneralTagAndCapsPhrases() {
        let overflow = (0..<120).map { "Hint\($0)" }
        let context = OnDeviceDictationAnalysisContext.make(phrases: overflow)
        let phrases = context.contextualStrings[.general] ?? []
        #expect(phrases.count == 100)
        #expect(phrases.first == "Hint0")
        #expect(phrases.last == "Hint99")
    }

    @Test func startRecordingFeedsPrecomputedHintsToProviderContext() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)
        manager.activateTestChat()
        manager.updateTestHints("Wire `UniqueHintToken` into AnalysisContext.")

        #expect(manager._testConversationHints.contains("UniqueHintToken"))
        try await manager.startRecording(source: "test")

        #expect(classicProvider.lastContext?.contextualStrings.contains("UniqueHintToken") == true)
        await manager.cancelRecording()
    }

    @Test func startRecordingCancelsInFlightFoundationModelExtract() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let gate = AsyncGate()
        let systemAccess = MockVoiceInputSystemAccess()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)
        AppPreferences.Voice.setFoundationModelDictationHintsEnabled(true)
        manager._testFoundationModelExtract = { _ in
            await gate.wait()
            return ["beta token"]
        }

        manager.activateTestChat()
        manager.updateTestHints("Use `AlphaToken` next.")
        #expect(manager._testConversationHints == ["AlphaToken"])

        try await manager.startRecording(source: "test")
        #expect(classicProvider.lastContext?.contextualStrings == ["AlphaToken"])
        #expect(!manager._testConversationHints.contains("beta token"))
        await manager.cancelRecording()

        await gate.open()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            !manager._testConversationHints.contains("beta token")
        })
        #expect(manager._testConversationHints.contains("AlphaToken"))
    }

    @Test func foundationModelMergeAppliesWhenIdle() async {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let gate = AsyncGate()
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [
                MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation),
            ]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        AppPreferences.Voice.setFoundationModelDictationHintsEnabled(true)
        manager._testFoundationModelExtract = { _ in
            await gate.wait()
            return ["beta token"]
        }

        manager.activateTestChat()
        manager.updateTestHints("Use `AlphaToken` next.")
        await gate.open()
        #expect(await waitForMainActorCondition {
            manager._testConversationHints.contains("beta token")
        })
        #expect(manager._testConversationHints.contains("AlphaToken"))
    }

    @Test func newerAssistantMessageDropsInFlightFoundationModelExtra() async {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let gate = AsyncGate()
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [
                MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation),
            ]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        AppPreferences.Voice.setFoundationModelDictationHintsEnabled(true)
        manager._testFoundationModelExtract = { truncated in
            if truncated.contains("AlphaToken") {
                await gate.wait()
                return ["stale extra"]
            }
            return ["fresh extra"]
        }

        manager.activateTestChat()
        manager.updateTestHints("Use `AlphaToken` next.")
        manager.updateTestHints("Now prefer `GammaToken`.")
        #expect(manager._testConversationHints.contains("GammaToken"))
        #expect(await waitForMainActorCondition {
            manager._testConversationHints.contains("fresh extra")
        })

        await gate.open()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            !manager._testConversationHints.contains("stale extra")
        })
    }

    @Test func clearConversationHintsOnlyWhenSessionOwnsTheManager() {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [
                MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation),
            ]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.activateTestChat(sessionId: "session-a")
        manager.updateTestHints("Use `AlphaToken` next.", sessionId: "session-a")
        #expect(manager._testConversationHints == ["AlphaToken"])

        manager.clearConversationHints(ifOwnedBy: "session-b")
        #expect(manager._testConversationHints == ["AlphaToken"])

        manager.clearConversationHints(ifOwnedBy: "session-a")
        #expect(manager._testConversationHints.isEmpty)
    }

    @Test func foundationModelExtractDoesNotRunWhenSettingIsOff() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        var hookCalls = 0
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [
                MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation),
            ]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        AppPreferences.Voice.setFoundationModelDictationHintsEnabled(false)
        manager._testFoundationModelExtract = { _ in
            hookCalls += 1
            return ["should not appear"]
        }

        manager.activateTestChat()
        manager.updateTestHints("Use `AlphaToken` next.")
        await Task.yield()
        #expect(hookCalls == 0)
        #expect(manager._testConversationHints == ["AlphaToken"])
        #expect(!manager._testConversationHints.contains("should not appear"))
    }

    @Test func backgroundHintRefreshDoesNotStealVisibleComposer() {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [
                MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation),
            ]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.activateTestChat(sessionId: "session-a")
        manager.updateTestHints("Use `AlphaToken` next.", sessionId: "session-a")
        #expect(manager._testConversationHints == ["AlphaToken"])

        manager.activeSessionId = "session-b"
        manager.updateTestHints("Use `OtherToken` next.", sessionId: "session-b")
        #expect(manager._testConversationHints == ["AlphaToken"])
    }

    @Test func standaloneComposerDoesNotTransmitConversationHints() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)
        manager.activateTestChat(sessionId: "session-a")
        manager.updateTestHints("Use `AlphaToken` next.", sessionId: "session-a")
        #expect(manager._testConversationHints == ["AlphaToken"])

        let standaloneGeneration = manager.beginStandaloneComposer(
            serverId: "server-a",
            credentials: nil,
            connection: nil
        )
        try await manager.startRecording(source: "test")
        #expect(classicProvider.lastContext?.contextualStrings.isEmpty == true)
        await manager.cancelRecording()

        manager.endComposer(generation: standaloneGeneration)
        manager.activateTestChat(sessionId: "session-a")
        try await manager.startRecording(source: "test")
        #expect(classicProvider.lastContext?.contextualStrings == ["AlphaToken"])
        await manager.cancelRecording()
    }

    @Test func restoredChatUsesItsServerAfterDifferentServerStandalone() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)
        let chatCreds = testCredentials(host: "chat.example")
        let qsCreds = testCredentials(host: "qs.example")
        manager.activateTestChat(serverId: "chat", sessionId: "s1", credentials: chatCreds)
        manager.updateTestHints("Use `AlphaToken` next.", serverId: "chat", sessionId: "s1")

        let generation = manager.beginStandaloneComposer(
            serverId: "qs",
            credentials: qsCreds,
            connection: nil
        )
        try await manager.startRecording(source: "qs")
        #expect(classicProvider.lastContext?.serverCredentials?.host == "qs.example")
        #expect(classicProvider.lastContext?.contextualStrings.isEmpty == true)
        await manager.cancelRecording()

        manager.endComposer(generation: generation)
        manager.activateTestChat(serverId: "chat", sessionId: "s1", credentials: chatCreds)
        try await manager.startRecording(source: "chat")
        #expect(classicProvider.lastContext?.serverCredentials?.host == "chat.example")
        #expect(classicProvider.lastContext?.contextualStrings == ["AlphaToken"])
        await manager.cancelRecording()
    }

    @Test func startRecordingFreezesPhrasesBeforePermissionWait() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let gate = AsyncGate()
        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.hasMicPermission = false
        systemAccess.requestMicPermissionHandler = {
            await gate.wait()
            return true
        }
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)
        manager.activateTestChat(sessionId: "session-a")
        manager.updateTestHints("Use `AlphaToken` next.", sessionId: "session-a")

        let startTask = Task { @MainActor in
            try await manager.startRecording(source: "test")
        }
        #expect(await waitForMainActorCondition {
            systemAccess.requestMicPermissionCallCount == 1
        })
        _ = manager.beginStandaloneComposer(serverId: "qs", credentials: nil, connection: nil)
        manager.updateTestHints("Use `OtherToken` next.", sessionId: "session-b")
        await gate.open()
        try await startTask.value
        #expect(classicProvider.lastContext?.contextualStrings == ["AlphaToken"])
        await manager.cancelRecording()
    }

    @Test func dismissedInitializeDoesNotClaimAfterAwait() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let gate = AsyncGate()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)
        manager.activateTestChat(sessionId: "session-a")
        manager.updateTestHints("Use `AlphaToken` next.", sessionId: "session-a")

        var dismissed = false
        var claimedGeneration: Int?
        let initTask = Task { @MainActor in
            await gate.wait()
            if dismissed { return }
            claimedGeneration = manager.beginStandaloneComposer(
                serverId: "qs",
                credentials: nil,
                connection: nil
            )
        }
        dismissed = true
        await gate.open()
        await initTask.value
        #expect(claimedGeneration == nil)

        try await manager.startRecording(source: "chat")
        #expect(classicProvider.lastContext?.contextualStrings == ["AlphaToken"])
        await manager.cancelRecording()
    }

    @Test func endComposerIsGenerationGuarded() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)
        manager.activateTestChat(sessionId: "session-a")
        manager.updateTestHints("Use `AlphaToken` next.", sessionId: "session-a")
        let first = manager.beginStandaloneComposer(serverId: "qs", credentials: nil, connection: nil)
        let second = manager.beginStandaloneComposer(serverId: "qs2", credentials: nil, connection: nil)
        manager.endComposer(generation: first)
        try await manager.startRecording(source: "qs")
        #expect(classicProvider.lastContext?.contextualStrings.isEmpty == true)
        await manager.cancelRecording()
        manager.endComposer(generation: second)
        manager.activateTestChat(sessionId: "session-a")
        try await manager.startRecording(source: "chat")
        #expect(classicProvider.lastContext?.contextualStrings == ["AlphaToken"])
        await manager.cancelRecording()
    }

    @Test func extensionEditorPrepareOmitsChatVocabularyAndUsesEditorTarget() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)

        let chat = testDictationServer(host: "chat.example")
        let editor = testDictationServer(host: "editor.example")
        manager.activateTestChat(
            serverId: "server-a",
            sessionId: "session-a",
            credentials: chat.credentials,
            connection: chat.connection
        )
        manager.updateTestHints("Use `AlphaToken` next.", serverId: "server-a", sessionId: "session-a")
        manager.setServerDictationTarget(
            ServerDictationTarget(workspaceId: "ws-a", sessionId: "session-a")
        )

        try await manager.startRecording(source: "negative_control")
        #expect(classicProvider.lastContext?.contextualStrings == ["AlphaToken"])
        #expect(classicProvider.lastContext?.serverCredentials?.host == "chat.example")
        #expect(classicProvider.lastContext?.serverConnection === chat.connection)
        #expect(classicProvider.lastContext?.serverDictationTarget?.sessionId == "session-a")
        await manager.cancelRecording()

        var textBeforeRecording: String?
        var suppressKeyboard = false
        var focusRequestID = 0
        try await ComposerShared.startVoiceInput(
            manager: manager,
            keyboardLanguage: nil,
            owner: .expandedComposer,
            baseText: "",
            textBeforeRecording: Binding(
                get: { textBeforeRecording },
                set: { textBeforeRecording = $0 }
            ),
            suppressKeyboard: Binding(
                get: { suppressKeyboard },
                set: { suppressKeyboard = $0 }
            ),
            focusRequestID: Binding(
                get: { focusRequestID },
                set: { focusRequestID = $0 }
            ),
            prepare: {
                _ = ComposerShared.prepareStandaloneVoiceInput(
                    manager: manager,
                    serverId: "server-b",
                    credentials: editor.credentials,
                    connection: editor.connection,
                    playbackInterrupter: nil
                )
            }
        )

        #expect(classicProvider.lastContext?.contextualStrings.isEmpty == true)
        #expect(classicProvider.lastContext?.serverCredentials?.host == "editor.example")
        #expect(classicProvider.lastContext?.serverConnection === editor.connection)
        #expect(classicProvider.lastContext?.serverDictationTarget == nil)
        #expect(
            classicProvider.lastContext?.source
                == ComposerShared.VoiceInputOwner.expandedComposer.rawValue
        )
        #expect(
            manager._testComposerOwner
                == VoiceComposerOwner(serverId: "server-b", kind: .standalone)
        )
        #expect(manager._testConversationHints == ["AlphaToken"])
        #expect(manager.activeSessionId == nil)
        await manager.cancelRecording()
    }

    @Test func chatMicPrepareReconcilesReducerAfterStandaloneModal() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)
        let chat = testDictationServer(host: "chat.example")

        manager.activateTestChat(
            serverId: "chat",
            sessionId: "s1",
            credentials: chat.credentials,
            connection: chat.connection
        )
        var items: [ChatItem] = [
            .assistantMessage(id: "a1", text: "Use `AlphaToken` here.", timestamp: Date()),
        ]
        manager.updateConversationHints(
            fromAssistantMessage: DictationHintExtractor.lastAssistantMessageText(in: items),
            serverId: "chat",
            sessionId: "s1"
        )
        #expect(manager._testConversationHints == ["AlphaToken"])

        let modalGeneration = manager.beginStandaloneComposer(
            serverId: "qs",
            credentials: chat.credentials,
            connection: chat.connection
        )
        items = [
            .assistantMessage(id: "a1", text: "Use `AlphaToken` here.", timestamp: Date()),
            .assistantMessage(id: "a2", text: "Now prefer `BetaToken`.", timestamp: Date()),
        ]
        manager.updateConversationHints(
            fromAssistantMessage: DictationHintExtractor.lastAssistantMessageText(in: items),
            serverId: "chat",
            sessionId: "s1"
        )
        #expect(manager._testConversationHints == ["AlphaToken"])
        manager.endComposer(generation: modalGeneration)

        var textBeforeRecording: String?
        var suppressKeyboard = false
        var focusRequestID = 0
        try await ComposerShared.startVoiceInput(
            manager: manager,
            keyboardLanguage: nil,
            owner: .inlineComposer,
            baseText: "",
            textBeforeRecording: Binding(
                get: { textBeforeRecording },
                set: { textBeforeRecording = $0 }
            ),
            suppressKeyboard: Binding(
                get: { suppressKeyboard },
                set: { suppressKeyboard = $0 }
            ),
            focusRequestID: Binding(
                get: { focusRequestID },
                set: { focusRequestID = $0 }
            ),
            prepare: {
                ComposerShared.prepareConversationVoiceInput(
                    manager: manager,
                    serverId: "chat",
                    sessionId: "s1",
                    credentials: chat.credentials,
                    connection: chat.connection,
                    assistantMessage: DictationHintExtractor.lastAssistantMessageText(in: items),
                    playbackInterrupter: nil
                )
            }
        )

        #expect(classicProvider.lastContext?.contextualStrings == ["BetaToken"])
        #expect(classicProvider.lastContext?.contextualStrings.contains("AlphaToken") != true)
        #expect(
            classicProvider.lastContext?.source
                == ComposerShared.VoiceInputOwner.inlineComposer.rawValue
        )
        #expect(
            manager._testComposerOwner
                == VoiceComposerOwner(serverId: "chat", kind: .conversation(sessionId: "s1"))
        )
        await manager.cancelRecording()
    }

    @Test func queuedDismissCancelDoesNotCancelNewerTake() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let dismissGate = AsyncGate()
        let prepareGate = AsyncGate()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.prepareSessionHandler = { _ in
            await prepareGate.wait()
            return VoiceProviderPreparation(
                audioFormat: nil,
                pathTag: "mock",
                setupMetricTags: [:]
            )
        }
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)

        let oldGeneration = manager.beginStandaloneComposer(
            serverId: "old",
            credentials: nil,
            connection: nil
        )
        let oldIdentity = ComposerShared.takeIdentityForDismissedComposer(
            manager: manager,
            generation: oldGeneration
        )
        #expect(oldIdentity == nil)
        manager.endComposer(generation: oldGeneration)

        let deferredDismiss = Task { @MainActor in
            await dismissGate.wait()
            await ComposerShared.cancelVoiceInputOnDismiss(
                manager: manager,
                matching: oldIdentity
            )
        }

        let newOwner = VoiceComposerOwner(serverId: "new", kind: .standalone)
        let newGeneration = manager.beginStandaloneComposer(
            serverId: "new",
            credentials: nil,
            connection: nil
        )
        let startTask = Task { @MainActor in
            try await manager.startRecording(
                source: ComposerShared.VoiceInputOwner.inboxComposer.rawValue
            )
        }
        #expect(await waitForMainActorCondition {
            manager.state == .preparingModel && classicProvider.prepareSessionCallCount == 1
        })
        let newIdentity = manager.currentCaptureTakeIdentity()
        #expect(newIdentity != nil)
        #expect(manager._testComposerOwner == newOwner)

        let delayedOldIdentity = ComposerShared.takeIdentityForDismissedComposer(
            manager: manager,
            generation: oldGeneration
        )
        #expect(delayedOldIdentity == nil)
        #expect(delayedOldIdentity != newIdentity)

        await dismissGate.open()
        await deferredDismiss.value
        await ComposerShared.cancelVoiceInputOnDismiss(
            manager: manager,
            matching: delayedOldIdentity
        )
        #expect(manager.state == .preparingModel)
        #expect(classicProvider.cancelPreparationCallCount == 0)
        #expect(session.cancelCallCount == 0)
        #expect(manager.currentCaptureTakeIdentity() == newIdentity)
        #expect(manager._testComposerOwner == newOwner)

        await prepareGate.open()
        try await startTask.value
        #expect(manager.state == .recording)
        #expect(
            classicProvider.lastContext?.source
                == ComposerShared.VoiceInputOwner.inboxComposer.rawValue
        )
        #expect(session.cancelCallCount == 0)
        #expect(manager._testComposerGeneration == newGeneration)
        await manager.cancelRecording()
    }

    @Test func matchingDismissCancelStillCancelsTheRetiringTake() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)
        let generation = manager.beginStandaloneComposer(serverId: "old", credentials: nil, connection: nil)
        try await manager.startRecording(source: ComposerShared.VoiceInputOwner.inboxComposer.rawValue)
        let identity = ComposerShared.takeIdentityForDismissedComposer(
            manager: manager,
            generation: generation
        )
        #expect(identity != nil)
        #expect(identity?.composerGeneration == generation)

        await ComposerShared.cancelVoiceInputOnDismiss(manager: manager, matching: identity)
        #expect(manager.state == .idle)
        #expect(session.cancelCallCount == 1)
        #expect(manager.currentCaptureTakeIdentity() == nil)
    }

    @Test func deferredDismissCancelsActiveTakeAfterLaterOwnerClaimsWithoutStarting() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let dismissGate = AsyncGate()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)

        let oldGeneration = manager.beginStandaloneComposer(
            serverId: "old",
            credentials: nil,
            connection: nil
        )
        try await manager.startRecording(
            source: ComposerShared.VoiceInputOwner.inboxComposer.rawValue
        )
        let oldIdentity = ComposerShared.takeIdentityForDismissedComposer(
            manager: manager,
            generation: oldGeneration
        )
        #expect(oldIdentity != nil)
        #expect(oldIdentity?.composerGeneration == oldGeneration)
        manager.endComposer(generation: oldGeneration)

        let deferredDismiss = Task { @MainActor in
            await dismissGate.wait()
            await ComposerShared.cancelVoiceInputOnDismiss(
                manager: manager,
                matching: oldIdentity
            )
        }

        let newOwner = VoiceComposerOwner(
            serverId: "chat",
            kind: .conversation(sessionId: "s1")
        )
        _ = manager.activateConversationComposer(
            serverId: "chat",
            sessionId: "s1",
            credentials: nil,
            connection: nil
        )
        #expect(manager.state == .recording)
        #expect(manager._testComposerOwner == newOwner)
        #expect(manager._testComposerGeneration != oldGeneration)
        #expect(manager.currentCaptureTakeIdentity() == oldIdentity)
        #expect(
            ComposerShared.takeIdentityForDismissedComposer(
                manager: manager,
                generation: oldGeneration
            ) == oldIdentity
        )

        await dismissGate.open()
        await deferredDismiss.value
        #expect(manager.state == .idle)
        #expect(session.cancelCallCount == 1)
        #expect(manager.currentCaptureTakeIdentity() == nil)
        #expect(manager._testComposerOwner == newOwner)
    }

    @Test func deferredDismissCancelsPreparingTakeAfterLaterOwnerClaimsWithoutStarting() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let dismissGate = AsyncGate()
        let prepareGate = AsyncGate()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.prepareSessionHandler = { _ in
            await prepareGate.wait()
            return VoiceProviderPreparation(
                audioFormat: nil,
                pathTag: "mock",
                setupMetricTags: [:]
            )
        }
        classicProvider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)

        let oldGeneration = manager.beginStandaloneComposer(
            serverId: "old",
            credentials: nil,
            connection: nil
        )
        let startTask = Task { @MainActor in
            try await manager.startRecording(
                source: ComposerShared.VoiceInputOwner.inboxComposer.rawValue
            )
        }
        #expect(await waitForMainActorCondition {
            manager.state == .preparingModel && classicProvider.prepareSessionCallCount == 1
        })
        let oldIdentity = ComposerShared.takeIdentityForDismissedComposer(
            manager: manager,
            generation: oldGeneration
        )
        #expect(oldIdentity != nil)
        manager.endComposer(generation: oldGeneration)

        let deferredDismiss = Task { @MainActor in
            await dismissGate.wait()
            await ComposerShared.cancelVoiceInputOnDismiss(
                manager: manager,
                matching: oldIdentity
            )
        }

        _ = manager.activateConversationComposer(
            serverId: "chat",
            sessionId: "s1",
            credentials: nil,
            connection: nil
        )
        #expect(manager.state == .preparingModel)
        #expect(manager._testComposerGeneration != oldGeneration)
        #expect(manager.currentCaptureTakeIdentity() == oldIdentity)

        await dismissGate.open()
        await deferredDismiss.value
        #expect(manager.state == .idle)
        #expect(classicProvider.cancelPreparationCallCount == 1)
        #expect(session.cancelCallCount == 0)
        #expect(manager.currentCaptureTakeIdentity() == nil)

        await prepareGate.open()
        try await startTask.value
        #expect(manager.state == .idle)
        #expect(session.startCallCount == 0)
    }

    @Test func nilClaimedTargetDoesNotInheritPreviousOwnerTarget() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)
        let previous = testDictationServer(host: "old.example")
        manager.activateTestChat(
            serverId: "old",
            sessionId: "session-old",
            credentials: previous.credentials,
            connection: previous.connection
        )
        manager.setServerDictationTarget(
            ServerDictationTarget(workspaceId: "ws-old", sessionId: "session-old")
        )

        _ = manager.beginStandaloneComposer(
            serverId: "new",
            credentials: nil,
            connection: nil
        )
        try await manager.startRecording(source: ComposerShared.VoiceInputOwner.inboxComposer.rawValue)

        #expect(classicProvider.lastContext?.serverCredentials == nil)
        #expect(classicProvider.lastContext?.serverConnection == nil)
        #expect(classicProvider.lastContext?.serverDictationTarget == nil)
        #expect(
            manager._testComposerOwner
                == VoiceComposerOwner(serverId: "new", kind: .standalone)
        )
        await manager.cancelRecording()
    }

    @Test func frozenTakeValidationIgnoresLiveMutationDuringPermissionWait() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let gate = AsyncGate()
        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.hasMicPermission = false
        systemAccess.requestMicPermissionHandler = {
            await gate.wait()
            return true
        }
        let serverProvider = MockVoiceProvider(id: .oppiServer, engine: .serverDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [serverProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.remote)

        let original = testDictationServer(host: "frozen.example")
        let mutated = testDictationServer(host: "mutated.example")
        manager.activateTestChat(
            serverId: "frozen",
            sessionId: "s1",
            credentials: original.credentials,
            connection: original.connection
        )
        manager.setServerDictationTarget(
            ServerDictationTarget(workspaceId: "ws-frozen", sessionId: "s1")
        )

        let startTask = Task { @MainActor in
            try await manager.startRecording(
                source: ComposerShared.VoiceInputOwner.inlineComposer.rawValue
            )
        }
        #expect(await waitForMainActorCondition {
            systemAccess.requestMicPermissionCallCount == 1
        })
        manager.setServerCredentials(mutated.credentials)
        manager.setServerConnection(nil)
        manager.setServerDictationTarget(
            ServerDictationTarget(workspaceId: "ws-mutated", sessionId: "s-mutated")
        )
        await gate.open()
        try await startTask.value

        #expect(serverProvider.prepareSessionCallCount == 1)
        #expect(serverProvider.lastContext?.serverCredentials?.host == "frozen.example")
        #expect(serverProvider.lastContext?.serverConnection === original.connection)
        #expect(serverProvider.lastContext?.serverDictationTarget?.workspaceId == "ws-frozen")
        #expect(serverProvider.lastContext?.serverDictationTarget?.sessionId == "s1")
        #expect(manager.state == .recording)
        await manager.cancelRecording()
    }

    @Test func quickSessionReconfigureWhileRecordingStillDismissesTheActiveTake() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)

        var voiceComposerGeneration: Int? = configureQuickSessionVoiceInput(
            manager: manager,
            serverId: "qs-1",
            ownedGeneration: nil
        )
        try await manager.startRecording(
            source: ComposerShared.VoiceInputOwner.inlineComposer.rawValue
        )
        #expect(manager.state == .recording)
        let takeBeforeReconfigure = manager.currentCaptureTakeIdentity()
        #expect(takeBeforeReconfigure != nil)
        #expect(takeBeforeReconfigure?.composerGeneration == voiceComposerGeneration)

        // Production selectWorkspace → configureVoiceInputForSelectedServer.
        // Must use the view's stored generation, not a stashed G1 copy.
        voiceComposerGeneration = configureQuickSessionVoiceInput(
            manager: manager,
            serverId: "qs-2",
            ownedGeneration: voiceComposerGeneration
        )

        await dismissQuickSessionComposer(
            manager: manager,
            generation: &voiceComposerGeneration
        )
        #expect(manager.state == .idle)
        #expect(session.cancelCallCount == 1)
        #expect(manager.currentCaptureTakeIdentity() == nil)
        #expect(classicProvider.lastContext?.source == ComposerShared.VoiceInputOwner.inlineComposer.rawValue)
    }

    @Test func quickSessionReconfigureWhilePreparingStillDismissesTheActiveTake() async throws {
        resetHintPreferences()
        defer { resetHintPreferences() }

        let prepareGate = AsyncGate()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.prepareSessionHandler = { _ in
            await prepareGate.wait()
            return VoiceProviderPreparation(
                audioFormat: nil,
                pathTag: "mock",
                setupMetricTags: [:]
            )
        }
        classicProvider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)

        var voiceComposerGeneration: Int? = configureQuickSessionVoiceInput(
            manager: manager,
            serverId: "qs-1",
            ownedGeneration: nil
        )
        let startTask = Task { @MainActor in
            try await manager.startRecording(
                source: ComposerShared.VoiceInputOwner.inlineComposer.rawValue
            )
        }
        #expect(await waitForMainActorCondition {
            manager.state == .preparingModel && classicProvider.prepareSessionCallCount == 1
        })
        let takeBeforeReconfigure = manager.currentCaptureTakeIdentity()
        #expect(takeBeforeReconfigure != nil)
        #expect(takeBeforeReconfigure?.composerGeneration == voiceComposerGeneration)

        voiceComposerGeneration = configureQuickSessionVoiceInput(
            manager: manager,
            serverId: "qs-2",
            ownedGeneration: voiceComposerGeneration
        )

        await dismissQuickSessionComposer(
            manager: manager,
            generation: &voiceComposerGeneration
        )
        #expect(manager.state == .idle)
        #expect(classicProvider.cancelPreparationCallCount == 1)
        #expect(session.startCallCount == 0)
        #expect(session.cancelCallCount == 0)
        #expect(manager.currentCaptureTakeIdentity() == nil)

        await prepareGate.open()
        try? await startTask.value
        #expect(manager.state == .idle)
        #expect(session.startCallCount == 0)
        await manager.cancelRecording()
    }
}

@Suite("Dictation contextual string bounds")
struct DictationContextualStringBoundsTests {
    @Test func preparedKeepsSpacedPhrasesAndDropsIllegalOnes() {
        let prepared = DictationContextualStrings.prepared([
            "  Foo Bar  ",
            "",
            "   ",
            "ok\nbad",
            "Alpha\n",
            "\u{FEFF}",
            "\u{200B}",
            "\u{00A0}",
            "Yuwp",
        ])
        #expect(prepared == ["Foo Bar", "Yuwp"])
    }

    @Test func preparedTrimsSharedBlankPolicyAndKeepsMixedPhrases() {
        #expect(DictationContextualStrings.prepared(["\u{FEFF}Foo\u{FEFF}"]) == ["Foo"])
        #expect(DictationContextualStrings.prepared(["Foo\u{00A0}Bar"]) == ["Foo\u{00A0}Bar"])
    }

    @Test func preparedCapsPhraseCountAndUTF8Budget() {
        let overflow = (0..<120).map { "p\($0)" }
        #expect(DictationContextualStrings.prepared(overflow).count == 100)

        let tooLong = String(repeating: "é", count: 129)
        #expect(tooLong.utf8.count == 258)
        #expect(DictationContextualStrings.prepared([tooLong, "ok"]).contains("ok"))
        #expect(!DictationContextualStrings.prepared([tooLong, "ok"]).contains(tooLong))
    }

    @Test func conversationFreeComposersClaimStandaloneHints() throws {
        let quick = try appleSource("Oppi/Features/QuickSession/QuickSessionSheet.swift")
        #expect(quick.contains("ComposerShared.prepareStandaloneVoiceInput("))
        #expect(quick.contains("ownedGeneration: voiceComposerGeneration"))
        #expect(quick.contains("endComposer(generation:"))
        #expect(quick.contains("Task.isCancelled"))
        #expect(quick.contains("takeIdentityForDismissedComposer("))
        #expect(quick.contains("matching: takeIdentity"))
        let control = try appleSource("Oppi/Features/ControlSessions/GuidedControlSessionComposer.swift")
        #expect(control.contains("ComposerShared.prepareStandaloneVoiceInput("))
        #expect(control.contains("ownedGeneration: voiceComposerGeneration"))
        #expect(control.contains("endComposer(generation:"))
        #expect(control.contains("Task.isCancelled"))
        #expect(control.contains("takeIdentityForDismissedComposer("))
        #expect(control.contains("matching: takeIdentity"))
        let editor = try appleSource("Oppi/App/ContentView.swift")
        #expect(editor.contains("ComposerShared.prepareStandaloneVoiceInput("))
        #expect(editor.contains("ownedGeneration: editorVoiceComposerGeneration"))
        #expect(editor.contains("onPrepareVoiceInput: prepareEditorVoiceInput"))
        #expect(!editor.contains("manager.activeSessionId = request.sessionId"))
        #expect(editor.contains("takeIdentityForDismissedComposer("))
        #expect(editor.contains("matching: takeIdentity"))
        let shared = try appleSource("Oppi/Features/Chat/Composer/ComposerShared.swift")
        #expect(shared.contains("beginStandaloneComposer("))
        #expect(shared.contains("ownedGeneration"))
        #expect(shared.contains("activateConversationComposer("))
        #expect(shared.contains("updateConversationHints("))
        #expect(shared.contains("cancelRecording(matching:"))
        #expect(shared.contains("takeIdentityForDismissedComposer("))
    }
}

@MainActor
private extension VoiceInputManager {
    func activateTestChat(
        serverId: String = "server-a",
        sessionId: String = "session-a",
        credentials: ServerCredentials? = nil,
        connection: ServerConnection? = nil
    ) {
        _ = activateConversationComposer(
            serverId: serverId,
            sessionId: sessionId,
            credentials: credentials,
            connection: connection
        )
    }

    func updateTestHints(
        _ text: String?,
        serverId: String = "server-a",
        sessionId: String = "session-a"
    ) {
        updateConversationHints(
            fromAssistantMessage: text,
            serverId: serverId,
            sessionId: sessionId
        )
    }
}

private func testCredentials(host: String) -> ServerCredentials {
    ServerCredentials(host: host, port: 7749, token: "tok", name: host)
}

@MainActor
private func testDictationServer(host: String) -> (credentials: ServerCredentials, connection: ServerConnection) {
    let credentials = testCredentials(host: host)
    let connection = ServerConnection()
    _ = connection.configure(credentials: credentials)
    return (credentials, connection)
}

private func resetHintPreferences() {
    AppPreferences.Voice.setEngineMode(.onDevice)
    AppPreferences.Voice.setFoundationModelDictationHintsEnabled(false)
}

private func restorePreference(_ value: Any?, forKey key: String) {
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Production Quick Session configureVoiceInputForSelectedServer bookkeeping.
/// Passes the view's stored generation through the standalone claim helper.
@MainActor
private func configureQuickSessionVoiceInput(
    manager: VoiceInputManager,
    serverId: String,
    ownedGeneration: Int?
) -> Int {
    ComposerShared.prepareStandaloneVoiceInput(
        manager: manager,
        serverId: serverId,
        credentials: nil,
        connection: nil,
        playbackInterrupter: nil,
        ownedGeneration: ownedGeneration
    )
}

/// Production Quick Session onDisappear identity path.
@MainActor
private func dismissQuickSessionComposer(
    manager: VoiceInputManager,
    generation: inout Int?
) async {
    let takeIdentity = ComposerShared.takeIdentityForDismissedComposer(
        manager: manager,
        generation: generation
    )
    if let current = generation {
        manager.endComposer(generation: current)
        generation = nil
    }
    await ComposerShared.cancelVoiceInputOnDismiss(
        manager: manager,
        matching: takeIdentity
    )
}

private func appleSource(_ relativePath: String) throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: relativePath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func sourceSlice(_ source: String, start: String, end: String) throws -> String {
    guard let startRange = source.range(of: start) else {
        Issue.record("Missing source start \(start)")
        throw SourceSliceError.missingMarker(start)
    }
    guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        Issue.record("Missing source end \(end)")
        throw SourceSliceError.missingMarker(end)
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private enum SourceSliceError: Error {
    case missingMarker(String)
}
