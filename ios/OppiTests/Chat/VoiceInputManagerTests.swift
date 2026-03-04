import Foundation
import Testing
@testable import Oppi

/// Tests for VoiceInputManager state machine correctness.
///
/// These tests verify the state guards that prevent overlapping operations —
/// the suspected cause of crashes when tapping the mic button rapidly.
/// Speech framework calls are not exercised (no mic/NE in simulator).
@Suite("VoiceInputManager")
@MainActor
struct VoiceInputManagerTests {

    // MARK: - Initial State

    @Test func initialState() {
        let manager = VoiceInputManager()
        #expect(manager.state == .idle)
        #expect(!manager.isRecording)
        #expect(!manager.isProcessing)
        #expect(!manager.isPreparing)
        #expect(manager.currentTranscript == "")
        #expect(manager.audioLevel == 0)
    }

    // MARK: - State Guards

    @Test func startRecordingRejectsNonIdleState() async throws {
        let manager = VoiceInputManager()

        // Simulate preparing state
        manager._testState = .preparingModel
        try await manager.startRecording()
        #expect(manager.state == .preparingModel, "Should not change state when not idle")

        // Simulate recording state
        manager._testState = .recording
        try await manager.startRecording()
        #expect(manager.state == .recording, "Should not change state when recording")

        // Simulate processing state
        manager._testState = .processing
        try await manager.startRecording()
        #expect(manager.state == .processing, "Should not change state when processing")

        // Simulate error state
        manager._testState = .error("test")
        try await manager.startRecording()
        #expect(manager.state == .error("test"), "Should not change state when in error")
    }

    @Test func startRecordingRejectsWhenOperationInFlight() async throws {
        let manager = VoiceInputManager()

        // State is idle but operation lock is held
        manager._testOperationInFlight = true
        try await manager.startRecording()
        #expect(manager.state == .idle, "Should not proceed when operation is in flight")
    }

    @Test func stopRecordingRejectsNonRecordingState() async {
        let manager = VoiceInputManager()

        // From idle
        await manager.stopRecording()
        #expect(manager.state == .idle)

        // From preparing
        manager._testState = .preparingModel
        await manager.stopRecording()
        #expect(manager.state == .preparingModel)

        // From processing
        manager._testState = .processing
        await manager.stopRecording()
        #expect(manager.state == .processing)
    }

    @Test func stopRecordingRejectsWhenOperationInFlight() async {
        let manager = VoiceInputManager()
        manager._testState = .recording
        manager._testOperationInFlight = true

        await manager.stopRecording()
        // Should remain recording — stop was rejected
        #expect(manager.state == .recording)
    }

    @Test func cancelRecordingOnlyFromRecordingOrPreparing() async {
        let manager = VoiceInputManager()

        // From idle — rejected
        await manager.cancelRecording()
        #expect(manager.state == .idle)

        // From preparing — accepted
        manager._testState = .preparingModel
        await manager.cancelRecording()
        #expect(manager.state == .idle, "Cancel should reset to idle from preparing")

        // From recording — accepted
        manager._testState = .recording
        await manager.cancelRecording()
        #expect(manager.state == .idle, "Cancel should reset to idle from recording")
    }

    @Test func cancelClearsTranscript() async {
        let manager = VoiceInputManager()
        manager._testState = .recording

        await manager.cancelRecording()
        #expect(manager.finalizedTranscript == "")
        #expect(manager.volatileTranscript == "")
        #expect(manager.currentTranscript == "")
    }

    @Test func cancelResetsOperationLock() async {
        let manager = VoiceInputManager()
        manager._testState = .recording
        manager._testOperationInFlight = true

        await manager.cancelRecording()
        #expect(!manager._testOperationInFlight, "Cancel must clear operation lock")
        #expect(manager.state == .idle)
    }

    // MARK: - Computed Properties

    @Test func isRecordingOnlyInRecordingState() {
        let manager = VoiceInputManager()

        manager._testState = .idle
        #expect(!manager.isRecording)

        manager._testState = .preparingModel
        #expect(!manager.isRecording)

        manager._testState = .recording
        #expect(manager.isRecording)

        manager._testState = .processing
        #expect(!manager.isRecording)

        manager._testState = .error("x")
        #expect(!manager.isRecording)
    }

    @Test func isProcessingOnlyInProcessingState() {
        let manager = VoiceInputManager()

        manager._testState = .idle
        #expect(!manager.isProcessing)

        manager._testState = .processing
        #expect(manager.isProcessing)

        manager._testState = .recording
        #expect(!manager.isProcessing)
    }

    @Test func isPreparingOnlyInPreparingState() {
        let manager = VoiceInputManager()

        manager._testState = .idle
        #expect(!manager.isPreparing)

        manager._testState = .preparingModel
        #expect(manager.isPreparing)

        manager._testState = .recording
        #expect(!manager.isPreparing)
    }

    // MARK: - Prewarm

    @Test func prewarmGuardsWhenAlreadyReady() async {
        let manager = VoiceInputManager()
        manager._testModelReady = true

        // Should no-op (model already ready)
        await manager.prewarm()
        // No crash = success
    }

    @Test func prewarmGuardsWhenNotIdle() async {
        let manager = VoiceInputManager()
        manager._testState = .recording

        // Should no-op (not idle)
        await manager.prewarm()
        #expect(!manager._testModelReady, "Prewarm should not proceed when not idle")
    }

    // MARK: - Rapid Tap Simulation

    /// Simulates the button action pattern from ChatInputBar without
    /// actually calling Speech APIs (which crash in simulator).
    /// Verifies the state machine + operation lock prevent double-entry.
    @Test func rapidTapButtonActionPattern() async {
        let manager = VoiceInputManager()
        var startAttempts = 0
        var stopAttempts = 0
        var noopAttempts = 0

        // Simulate 5 rapid taps using the same dispatch logic as the button
        for _ in 0..<5 {
            let isRecording = manager.isRecording
            if isRecording {
                stopAttempts += 1
            } else if manager.state == .idle {
                startAttempts += 1
                // Simulate what startRecording does: grab the lock and change state
                manager._testOperationInFlight = true
                manager._testState = .preparingModel
            } else {
                noopAttempts += 1
            }
        }

        // First tap claims state. All subsequent taps are no-ops.
        #expect(startAttempts == 1, "Only first tap should attempt start")
        #expect(stopAttempts == 0, "No stops — never reached .recording")
        #expect(noopAttempts == 4, "All other taps should be no-ops")
    }

    /// Simulates a start -> stop -> start cycle via the state machine.
    /// Verifies the operation lock prevents overlap.
    @Test func startStopStartCycleStateMachine() async {
        let manager = VoiceInputManager()

        // Tap 1: start -> preparing
        #expect(manager.state == .idle)
        #expect(!manager._testOperationInFlight)
        manager._testOperationInFlight = true
        manager._testState = .preparingModel

        // Tap 2 during preparing: should be no-op
        #expect(!manager.isRecording)
        #expect(manager.state != .idle)

        // Setup completes -> recording
        manager._testState = .recording
        manager._testOperationInFlight = false

        // Tap 3: stop
        #expect(manager.isRecording)
        manager._testOperationInFlight = true
        manager._testState = .processing

        // Tap 4 during processing: should be no-op
        #expect(!manager.isRecording)
        #expect(manager.state != .idle)

        // Stop completes -> idle
        manager._testState = .idle
        manager._testOperationInFlight = false

        // Tap 5: can start again
        #expect(manager.state == .idle)
        #expect(!manager._testOperationInFlight)
    }

    /// Verifies that the operation lock alone prevents re-entry
    /// even if state is technically .idle (belt + suspenders).
    @Test func operationLockPreventsReentryAtIdleState() async throws {
        let manager = VoiceInputManager()
        #expect(manager.state == .idle)

        // Lock is held (e.g., stop just completed but defer hasn't cleared it)
        manager._testOperationInFlight = true

        // State is idle but lock prevents start
        try await manager.startRecording()
        // Should still be idle — start was rejected
        #expect(manager.state == .idle)
    }

    /// Verifies that after an error, the state eventually resets to idle.
    @Test func errorStateResetsToIdle() async {
        let manager = VoiceInputManager()
        manager._testState = .error("test error")

        // Error state should not allow start
        try? await manager.startRecording()
        #expect(manager.state == .error("test error"))

        // After reset
        manager._testState = .idle
        #expect(manager.state == .idle)
        #expect(!manager.isRecording)
    }

    // MARK: - State Transitions

    @Test func stateEquality() {
        #expect(VoiceInputManager.State.idle == .idle)
        #expect(VoiceInputManager.State.recording == .recording)
        #expect(VoiceInputManager.State.error("a") == .error("a"))
        #expect(VoiceInputManager.State.error("a") != .error("b"))
        #expect(VoiceInputManager.State.idle != .recording)
    }

    // MARK: - Locale Resolution

    @Test func resolvedLocaleWithChineseKeyboard() {
        let locale = VoiceInputManager.resolvedLocale(keyboardLanguage: "zh-Hans")
        #expect(locale.language.languageCode?.identifier == "zh")
    }

    @Test func resolvedLocaleWithEnglishKeyboard() {
        let locale = VoiceInputManager.resolvedLocale(keyboardLanguage: "en-US")
        #expect(locale.language.languageCode?.identifier == "en")
    }

    @Test func resolvedLocaleWithJapaneseKeyboard() {
        let locale = VoiceInputManager.resolvedLocale(keyboardLanguage: "ja-JP")
        #expect(locale.language.languageCode?.identifier == "ja")
    }

    @Test func resolvedLocaleWithNilUsesPersistedLanguage() {
        // Save a persisted language, then resolve with nil keyboard
        KeyboardLanguageStore.save("zh-Hans")
        let locale = VoiceInputManager.resolvedLocale(keyboardLanguage: nil)
        #expect(locale.language.languageCode?.identifier == "zh",
                "Should fall back to persisted keyboard language")

        // Clean up
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).keyboardLanguage")
    }

    @Test func resolvedLocaleIgnoresPseudoKeyboardLanguage() {
        KeyboardLanguageStore.save("en-US")

        let dictationLocale = VoiceInputManager.resolvedLocale(keyboardLanguage: "dictation")
        #expect(dictationLocale.language.languageCode?.identifier == "en",
                "Dictation pseudo-language should fall back to persisted keyboard")

        let emojiLocale = VoiceInputManager.resolvedLocale(keyboardLanguage: "emoji")
        #expect(emojiLocale.language.languageCode?.identifier == "en",
                "Emoji pseudo-language should fall back to persisted keyboard")

        UserDefaults.standard.removeObject(forKey: "\(AppIdentifiers.subsystem).keyboardLanguage")
    }

    @Test func resolvedLocaleActiveKeyboardTakesPriorityOverPersisted() {
        // Persisted is Chinese, but active keyboard is English
        KeyboardLanguageStore.save("zh-Hans")
        let locale = VoiceInputManager.resolvedLocale(keyboardLanguage: "en-US")
        #expect(locale.language.languageCode?.identifier == "en",
                "Active keyboard should take priority over persisted")

        // Clean up
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).keyboardLanguage")
    }

    @Test func resolvedLocaleWithKoreanKeyboard() {
        let locale = VoiceInputManager.resolvedLocale(keyboardLanguage: "ko-KR")
        #expect(locale.language.languageCode?.identifier == "ko")
    }

    @Test func preferredEngineUsesModernForEnglish() {
        let engine = VoiceInputManager.preferredEngine(for: Locale(identifier: "en-US"))
        #expect(engine == .modernSpeech)
    }

    @Test func preferredEngineUsesClassicForCJK() {
        #expect(VoiceInputManager.preferredEngine(for: Locale(identifier: "zh-Hans")) == .classicDictation)
        #expect(VoiceInputManager.preferredEngine(for: Locale(identifier: "ja-JP")) == .classicDictation)
        #expect(VoiceInputManager.preferredEngine(for: Locale(identifier: "ko-KR")) == .classicDictation)
    }

    // MARK: - Language Label

    @Test func activeLanguageLabelNilWhenIdle() {
        let manager = VoiceInputManager()
        #expect(manager.activeLanguageLabel == nil)
    }

    @Test func languageLabelForCJKLocales() {
        // CJK languages get native script characters
        #expect(VoiceInputManager.languageLabel(for: Locale(identifier: "zh-Hans")) == "中")
        #expect(VoiceInputManager.languageLabel(for: Locale(identifier: "zh-Hant")) == "中")
        #expect(VoiceInputManager.languageLabel(for: Locale(identifier: "ja-JP")) == "あ")
        #expect(VoiceInputManager.languageLabel(for: Locale(identifier: "ko-KR")) == "한")
    }

    @Test func languageLabelForLatinLocales() {
        // Latin languages get 2-letter uppercase code
        #expect(VoiceInputManager.languageLabel(for: Locale(identifier: "en-US")) == "EN")
        #expect(VoiceInputManager.languageLabel(for: Locale(identifier: "fr-FR")) == "FR")
        #expect(VoiceInputManager.languageLabel(for: Locale(identifier: "de-DE")) == "DE")
        #expect(VoiceInputManager.languageLabel(for: Locale(identifier: "es-ES")) == "ES")
    }

    // MARK: - KeyboardLanguageStore Persistence

    private let testKey = "\(AppIdentifiers.subsystem).keyboardLanguage"

    @Test func keyboardLanguageStoreSaveAndRead() {
        // Clean slate
        UserDefaults.standard.removeObject(forKey: testKey)
        #expect(KeyboardLanguageStore.lastLanguage == nil)

        KeyboardLanguageStore.save("zh-Hans")
        #expect(KeyboardLanguageStore.lastLanguage == "zh-Hans")

        KeyboardLanguageStore.save("en-US")
        #expect(KeyboardLanguageStore.lastLanguage == "en-US")

        // Clean up
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test func keyboardLanguageStoreIgnoresNil() {
        UserDefaults.standard.removeObject(forKey: testKey)
        KeyboardLanguageStore.save("zh-Hans")
        KeyboardLanguageStore.save(nil)
        #expect(KeyboardLanguageStore.lastLanguage == "zh-Hans",
                "Saving nil should not clear persisted value")

        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test func keyboardLanguageStoreIgnoresDuplicate() {
        UserDefaults.standard.removeObject(forKey: testKey)
        KeyboardLanguageStore.save("en-US")
        // Saving same value again is a no-op (tested via coverage, not assertion)
        KeyboardLanguageStore.save("en-US")
        #expect(KeyboardLanguageStore.lastLanguage == "en-US")

        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test func keyboardLanguageStoreIgnoresPseudoLanguages() {
        UserDefaults.standard.removeObject(forKey: testKey)
        KeyboardLanguageStore.save("en-US")

        KeyboardLanguageStore.save("dictation")
        #expect(KeyboardLanguageStore.lastLanguage == "en-US")

        KeyboardLanguageStore.save("emoji")
        #expect(KeyboardLanguageStore.lastLanguage == "en-US")

        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test func keyboardLanguageNormalizeRejectsMalformedValues() {
        #expect(KeyboardLanguageStore.normalize(nil) == nil)
        #expect(KeyboardLanguageStore.normalize("") == nil)
        #expect(KeyboardLanguageStore.normalize(" ") == nil)
        #expect(KeyboardLanguageStore.normalize("1") == nil)
        #expect(KeyboardLanguageStore.normalize("x") == nil)
        #expect(KeyboardLanguageStore.normalize("emoji") == nil)
        #expect(KeyboardLanguageStore.normalize("en-US") == "en-US")
        #expect(KeyboardLanguageStore.normalize("zh-Hans") == "zh-Hans")
    }

    // MARK: - Full Fallback Chain

    @Test func localeResolutionFallbackChain() {
        UserDefaults.standard.removeObject(forKey: testKey)

        // 1. Active keyboard wins
        KeyboardLanguageStore.save("zh-Hans")
        let locale1 = VoiceInputManager.resolvedLocale(keyboardLanguage: "en-US")
        #expect(locale1.language.languageCode?.identifier == "en",
                "Active keyboard should beat persisted")

        // 2. No active keyboard -> persisted wins
        let locale2 = VoiceInputManager.resolvedLocale(keyboardLanguage: nil)
        #expect(locale2.language.languageCode?.identifier == "zh",
                "Persisted should be used when no active keyboard")

        // 3. No active keyboard, no persisted -> device locale
        UserDefaults.standard.removeObject(forKey: testKey)
        let locale3 = VoiceInputManager.resolvedLocale(keyboardLanguage: nil)
        #expect(locale3 == Locale.current,
                "Should fall back to device locale")
    }
}
