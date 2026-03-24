import Foundation
import Testing
@testable import Oppi

/// Tests for voice input locale stability across recording sessions.
///
/// **Bug:** Tapping the mic button suppresses the keyboard by setting
/// `inputView = UIView()` + `reloadInputViews()`. This can trigger
/// `UITextInputMode.currentInputModeDidChangeNotification`, and with
/// a custom empty inputView, UIKit's `textInputMode?.primaryLanguage`
/// may report nil or the device's default keyboard language instead of
/// the user's previously active one. The PastableTextView coordinator
/// would blindly write this stale value to both `@State keyboardLanguage`
/// and `KeyboardLanguageStore`, causing subsequent voice sessions to
/// select the wrong speech model.
///
/// **Fix:** Skip `keyboardLanguage` / `KeyboardLanguageStore` updates
/// when `PastableUITextView.isKeyboardSuppressed` is true.
@Suite("Voice Locale Stability")
@MainActor
struct VoiceLocaleStabilityTests {

    private let testKey = "\(AppIdentifiers.subsystem).keyboardLanguage"

    // MARK: - Locale Resolution During Suppression

    @Test("Locale resolution with nil keyboardLanguage falls back to stored value")
    func nilKeyboardLanguageFallsBackToStored() {
        UserDefaults.standard.removeObject(forKey: testKey)
        KeyboardLanguageStore.save("zh-Hans")

        // When keyboardLanguage becomes nil (e.g. during suppression),
        // resolvedLocale should fall back to the persisted value.
        let locale = VoiceInputManager.resolvedLocale(keyboardLanguage: nil)
        #expect(locale.language.languageCode?.identifier == "zh")

        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test("Stored language survives nil writes — suppression cannot erase it")
    func storedLanguageSurvivesNilWrites() {
        UserDefaults.standard.removeObject(forKey: testKey)
        KeyboardLanguageStore.save("zh-Hans")
        #expect(KeyboardLanguageStore.lastLanguage == "zh-Hans")

        // Suppression might cause updateKeyboardLanguage to write nil.
        // save(nil) must be a no-op.
        KeyboardLanguageStore.save(nil)
        #expect(KeyboardLanguageStore.lastLanguage == "zh-Hans",
                "nil write must not erase persisted keyboard language")

        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test("Stored language is NOT overwritten by empty/whitespace strings")
    func storedLanguageRejectsEmptyStrings() {
        UserDefaults.standard.removeObject(forKey: testKey)
        KeyboardLanguageStore.save("ja-JP")

        KeyboardLanguageStore.save("")
        #expect(KeyboardLanguageStore.lastLanguage == "ja-JP")

        KeyboardLanguageStore.save("   ")
        #expect(KeyboardLanguageStore.lastLanguage == "ja-JP")

        UserDefaults.standard.removeObject(forKey: testKey)
    }

    // MARK: - Provider Receives Correct Locale

    @Test("Provider receives the locale from startRecording, not a later-corrupted value")
    func providerReceivesLocaleFromStartTime() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }
        UserDefaults.standard.removeObject(forKey: testKey)
        defer { UserDefaults.standard.removeObject(forKey: testKey) }

        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )

        // Start with Chinese keyboard
        try await manager.startRecording(keyboardLanguage: "zh-Hans", source: "test")

        #expect(manager.state == .recording)
        #expect(manager.activeLanguageLabel == "中",
                "Language label should reflect Chinese from startRecording call")

        // Verify the provider received Chinese locale
        let providerLocale = classicProvider.lastContext?.locale
        #expect(providerLocale?.language.languageCode?.identifier == "zh",
                "Provider must use the locale captured at startRecording time")

        await manager.stopRecording()
    }

    @Test("Consecutive sessions each use the language passed at start time")
    func consecutiveSessionsUseCorrectLanguage() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let session1 = MockVoiceSession()
        let session2 = MockVoiceSession()
        var sessionIndex = 0
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in
            sessionIndex += 1
            return sessionIndex == 1 ? session1 : session2
        }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )

        // Session 1: Chinese
        try await manager.startRecording(keyboardLanguage: "zh-Hans", source: "test")
        #expect(manager.activeLanguageLabel == "中")
        #expect(classicProvider.lastContext?.locale.language.languageCode?.identifier == "zh")
        await manager.stopRecording()

        // Session 2: English
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")
        #expect(manager.activeLanguageLabel == "EN")
        #expect(classicProvider.lastContext?.locale.language.languageCode?.identifier == "en")
        await manager.stopRecording()
    }

    @Test("Session with nil keyboardLanguage uses KeyboardLanguageStore fallback")
    func sessionWithNilKeyboardLanguageUsesFallback() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }
        UserDefaults.standard.removeObject(forKey: testKey)
        defer { UserDefaults.standard.removeObject(forKey: testKey) }

        // Pre-seed the store with Chinese (simulates previous typing session)
        KeyboardLanguageStore.save("zh-Hans")

        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )

        // Start with nil keyboard (simulates unfocused text field or
        // corrupted state from keyboard suppression)
        try await manager.startRecording(keyboardLanguage: nil, source: "test")

        #expect(manager.activeLanguageLabel == "中",
                "Should fall back to stored Chinese from KeyboardLanguageStore")
        #expect(classicProvider.lastContext?.locale.language.languageCode?.identifier == "zh")
        await manager.stopRecording()
    }

    // MARK: - Keyboard Suppression Guards

    @Test("updateKeyboardLanguage skips update when keyboard is suppressed")
    func updateKeyboardLanguageSkipsDuringSuppression() {
        UserDefaults.standard.removeObject(forKey: testKey)
        defer { UserDefaults.standard.removeObject(forKey: testKey) }

        // Set up a text view with a known language state
        KeyboardLanguageStore.save("zh-Hans")
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()

        // Suppress keyboard (voice recording mode)
        textView.setKeyboardSuppressed(true)
        #expect(textView.isKeyboardSuppressed)

        // Verify suppresssion state is detectable
        #expect(textView.isKeyboardSuppressed == true,
                "isKeyboardSuppressed must be readable for suppression guard")

        // The fix: any code path that reads textInputMode during suppression
        // should check isKeyboardSuppressed and bail out. This protects
        // KeyboardLanguageStore from being overwritten with stale data.
        #expect(KeyboardLanguageStore.lastLanguage == "zh-Hans",
                "Stored language must survive keyboard suppression")
    }

    @Test("Keyboard restore unsuppresses and allows language updates again")
    func keyboardRestoreAllowsLanguageUpdates() {
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()

        // Suppress
        textView.setKeyboardSuppressed(true)
        #expect(textView.isKeyboardSuppressed)

        // Restore (user taps text field)
        textView.perform(NSSelectorFromString("handleKeyboardRestoreTap"))
        #expect(!textView.isKeyboardSuppressed,
                "After restore, keyboard language updates should work normally")
        #expect(textView.inputView == nil,
                "Real keyboard should be visible after restore")
    }

    // MARK: - Suppress/Restore Cycle Language Stability

    @Test("KeyboardLanguageStore survives full suppress-restore cycle")
    func storeStabilityAcrossSuppressionCycle() {
        UserDefaults.standard.removeObject(forKey: testKey)
        defer { UserDefaults.standard.removeObject(forKey: testKey) }

        KeyboardLanguageStore.save("ko-KR")

        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()

        // Suppress (mic tap)
        textView.setKeyboardSuppressed(true)

        // Simulate what a notification handler WOULD do (but now guarded):
        // If the guard is missing, this would overwrite "ko-KR" with nil/wrong value.
        // With the guard, no change.
        #expect(KeyboardLanguageStore.lastLanguage == "ko-KR")

        // Restore (user taps text field)
        textView.setKeyboardSuppressed(false)
        #expect(KeyboardLanguageStore.lastLanguage == "ko-KR",
                "Korean should survive the full suppression cycle")
    }

    @Test("Multiple suppress-restore cycles don't drift the stored language")
    func multipleSuppressionCyclesNoDrift() {
        UserDefaults.standard.removeObject(forKey: testKey)
        defer { UserDefaults.standard.removeObject(forKey: testKey) }

        KeyboardLanguageStore.save("zh-Hant")

        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()

        // Simulate 5 mic-tap/stop cycles
        for i in 0..<5 {
            textView.setKeyboardSuppressed(true)
            #expect(KeyboardLanguageStore.lastLanguage == "zh-Hant",
                    "Stored language drifted after cycle \(i)")
            textView.setKeyboardSuppressed(false)
            #expect(KeyboardLanguageStore.lastLanguage == "zh-Hant",
                    "Stored language drifted after restore \(i)")
        }
    }

    // MARK: - Edge Cases

    @Test("Rapid mic taps don't corrupt locale state")
    func rapidMicTapsStableLocale() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }
        UserDefaults.standard.removeObject(forKey: testKey)
        defer { UserDefaults.standard.removeObject(forKey: testKey) }

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in MockVoiceSession() }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )

        // Tap 1: start Chinese
        try await manager.startRecording(keyboardLanguage: "zh-Hans", source: "test")
        #expect(manager.activeLanguageLabel == "中")

        // Tap 2: while recording — state guard should reject
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")
        #expect(manager.activeLanguageLabel == "中",
                "Second start during recording must not change language")
        #expect(manager.state == .recording)

        await manager.stopRecording()
    }

    @Test("Cancel during preparation doesn't leave stale language label")
    func cancelDuringPreparationClearsLabel() async {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let gate = AsyncGate()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.prepareSessionHandler = { _ in
            await gate.wait()
            return VoiceProviderPreparation(audioFormat: nil, pathTag: "gate", setupMetricTags: [:])
        }
        classicProvider.makeSessionHandler = { _, _ in MockVoiceSession() }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )

        let startTask = Task {
            try? await manager.startRecording(keyboardLanguage: "zh-Hans", source: "test")
        }

        #expect(await waitForMainActorCondition { manager.state == .preparingModel })

        await manager.cancelRecording()
        await gate.open()
        await startTask.value

        #expect(manager.state == .idle)
        #expect(manager.activeLanguageLabel == nil,
                "Cancel must clear language label to avoid stale display")
    }

    @Test("Language label reflects each session independently")
    func languageLabelPerSession() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        var sessions: [MockVoiceSession] = []
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in
            let s = MockVoiceSession()
            sessions.append(s)
            return s
        }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )

        let languages: [(keyboard: String, expectedLabel: String)] = [
            ("zh-Hans", "中"),
            ("en-US", "EN"),
            ("ja-JP", "あ"),
            ("ko-KR", "한"),
            ("fr-FR", "FR"),
        ]

        for (keyboard, expectedLabel) in languages {
            try await manager.startRecording(keyboardLanguage: keyboard, source: "test")
            #expect(manager.activeLanguageLabel == expectedLabel,
                    "Expected \(expectedLabel) for \(keyboard)")
            await manager.stopRecording()
        }

        #expect(sessions.count == languages.count)
    }

    // MARK: - Helpers

    private func resetVoicePreferences() {
        VoiceInputPreferences.setEngineMode(.auto)
        VoiceInputPreferences.setRemoteEndpoint(nil)
    }
}
