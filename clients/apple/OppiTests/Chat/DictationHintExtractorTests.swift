import Foundation
import Speech
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
        #expect(settings.contains("never leaves this iPhone"))
        #expect(settings.contains("on-device"))
        #expect(settings.contains("isFoundationModelDictationHintsEnabled"))
    }

    @Test func chatPrecomputesHintsWhenAssistantMessageLands() throws {
        let chat = try appleSource("Oppi/Features/Chat/ChatView.swift")
        #expect(chat.contains("updateConversationHints("))
        #expect(chat.contains("fromAssistantMessage:"))
        #expect(chat.contains("reducer.renderVersion"))
        #expect(chat.contains("DictationHintExtractor.lastAssistantMessageText"))
        #expect(chat.contains("clearConversationHints(ifOwnedBy: oldId)"))
        #expect(chat.contains("clearConversationHints(ifOwnedBy: sessionId)"))
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
        #expect(body.contains("contextualStrings: conversationHintPhrases"))
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
        manager.updateConversationHints(
            fromAssistantMessage: "Wire `UniqueHintToken` into AnalysisContext."
        )

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

        manager.updateConversationHints(fromAssistantMessage: "Use `AlphaToken` next.")
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

        manager.updateConversationHints(fromAssistantMessage: "Use `AlphaToken` next.")
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

        manager.updateConversationHints(fromAssistantMessage: "Use `AlphaToken` next.")
        manager.updateConversationHints(fromAssistantMessage: "Now prefer `GammaToken`.")
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
        manager.activeSessionId = "session-a"
        manager.updateConversationHints(fromAssistantMessage: "Use `AlphaToken` next.")
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

        manager.updateConversationHints(fromAssistantMessage: "Use `AlphaToken` next.")
        await Task.yield()
        #expect(hookCalls == 0)
        #expect(manager._testConversationHints == ["AlphaToken"])
        #expect(!manager._testConversationHints.contains("should not appear"))
    }
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
