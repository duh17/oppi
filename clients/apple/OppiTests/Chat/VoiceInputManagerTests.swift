import AVFoundation
import Foundation
import SwiftUI
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

    @Test func composerMicRetriesImmediatelyAfterAudioActivationFailure() async throws {
        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.activateAudioSessionError = TestVoiceError("Audio activation failed")
        let session = MockVoiceSession()
        let provider = MockVoiceProvider(id: .appleModernSpeech, engine: .modernSpeech)
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)
        var prefix: String?
        var suppressed = false
        var focus = 0
        func tapMic() async throws {
            try await ComposerShared.startVoiceInput(
                manager: manager,
                keyboardLanguage: "en-US",
                owner: .inlineComposer,
                baseText: "Keep draft",
                textBeforeRecording: Binding(get: { prefix }, set: { prefix = $0 }),
                suppressKeyboard: Binding(get: { suppressed }, set: { suppressed = $0 }),
                focusRequestID: Binding(get: { focus }, set: { focus = $0 })
            )
        }

        await #expect(throws: TestVoiceError.self) { try await tapMic() }
        #expect(manager.state == .error("Audio activation failed"))
        #expect(!manager._testOperationInFlight)
        #expect(prefix == nil)
        #expect(!suppressed)
        #expect(session.startCallCount == 0)

        systemAccess.activateAudioSessionError = nil
        try await tapMic()
        #expect(manager.state == .recording)
        #expect(manager.isActiveRecordingSource("inline_mic_tap"))
        #expect(systemAccess.activateAudioSessionCallCount == 2)
        #expect(session.startCallCount == 1)
        #expect(prefix == "Keep draft ")
        #expect(suppressed)
        #expect(focus == 2)
        await manager.cancelRecording()
    }

    // MARK: - Initial State

    @Test func productionSurfacesShareOneCaptureOwner() {
        #expect(VoiceInputManager.shared === VoiceInputManager.shared)
        #expect(VoiceInputManager() !== VoiceInputManager.shared)
    }

    @Test func initialState() {
        let manager = VoiceInputManager()
        #expect(manager.state == .idle)
        #expect(!manager.isRecording)
        #expect(!manager.isProcessing)
        #expect(!manager.isPreparing)
        #expect(manager.currentTranscript.isEmpty)
        #expect(manager.audioLevel == 0)
    }

    // MARK: - State Guards

    @Test func startRecordingRejectsActiveStateWithExplicitError() async {
        let manager = VoiceInputManager()
        for state: VoiceInputManager.State in [.preparingModel, .recording, .processing] {
            manager._testState = state
            await #expect(throws: VoiceInputError.self) { try await manager.startRecording() }
            #expect(manager.state == state)
        }
    }

    @Test func startRecordingRejectsWhenOperationInFlight() async throws {
        let manager = VoiceInputManager()

        // State is idle but operation lock is held
        manager._testOperationInFlight = true
        await #expect(throws: VoiceInputError.self) { try await manager.startRecording() }
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
        #expect(manager.finalizedTranscript.isEmpty)
        #expect(manager.volatileTranscript.isEmpty)
        #expect(manager.currentTranscript.isEmpty)
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

    @Test func prewarmRemoteModeDoesNotCrash() async {
        let manager = VoiceInputManager()
        manager.setEngineMode(.remote)

        await manager.prewarm(source: "test")
        #expect(manager.state == .idle)
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

        // State is idle but lock prevents start, explicitly rather than silently.
        await #expect(throws: VoiceInputError.self) { try await manager.startRecording() }
        // Should still be idle — start was rejected
        #expect(manager.state == .idle)
    }

    @Test func errorRetryDoesNotBypassOperationLock() async {
        let manager = VoiceInputManager()
        manager._testState = .error("test error")
        manager._testOperationInFlight = true
        await #expect(throws: VoiceInputError.self) { try await manager.startRecording() }
        #expect(manager.state == .error("test error"))
        #expect(manager._testOperationInFlight)
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
        AppPreferences.Keyboard.save("zh-Hans")
        let locale = VoiceInputManager.resolvedLocale(keyboardLanguage: nil)
        #expect(locale.language.languageCode?.identifier == "zh",
                "Should fall back to persisted keyboard language")

        // Clean up
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).keyboardLanguage")
    }

    @Test func resolvedLocaleIgnoresPseudoKeyboardLanguage() {
        AppPreferences.Keyboard.save("en-US")

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
        AppPreferences.Keyboard.save("zh-Hans")
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

    @Test func preferredEngineUsesModernSpeechForAllLocales() {
        #expect(VoiceInputManager.preferredEngine(for: Locale(identifier: "en-US")) == .modernSpeech)
        #expect(VoiceInputManager.preferredEngine(for: Locale(identifier: "zh-Hans")) == .modernSpeech)
        #expect(VoiceInputManager.preferredEngine(for: Locale(identifier: "ja-JP")) == .modernSpeech)
        #expect(VoiceInputManager.preferredEngine(for: Locale(identifier: "ko-KR")) == .modernSpeech)
        #expect(VoiceInputManager.preferredEngine(for: Locale(identifier: "fr-FR")) == .modernSpeech)
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

    // MARK: - AppPreferences.Keyboard Persistence

    private let testKey = "\(AppIdentifiers.subsystem).keyboardLanguage"

    @Test func keyboardLanguageStoreSaveAndRead() {
        // Clean slate
        UserDefaults.standard.removeObject(forKey: testKey)
        #expect(AppPreferences.Keyboard.lastLanguage == nil)

        AppPreferences.Keyboard.save("zh-Hans")
        #expect(AppPreferences.Keyboard.lastLanguage == "zh-Hans")

        AppPreferences.Keyboard.save("en-US")
        #expect(AppPreferences.Keyboard.lastLanguage == "en-US")

        // Clean up
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test func keyboardLanguageStoreIgnoresNil() {
        UserDefaults.standard.removeObject(forKey: testKey)
        AppPreferences.Keyboard.save("zh-Hans")
        AppPreferences.Keyboard.save(nil)
        #expect(AppPreferences.Keyboard.lastLanguage == "zh-Hans",
                "Saving nil should not clear persisted value")

        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test func keyboardLanguageStoreIgnoresDuplicate() {
        UserDefaults.standard.removeObject(forKey: testKey)
        AppPreferences.Keyboard.save("en-US")
        // Saving same value again is a no-op (tested via coverage, not assertion)
        AppPreferences.Keyboard.save("en-US")
        #expect(AppPreferences.Keyboard.lastLanguage == "en-US")

        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test func keyboardLanguageStoreIgnoresPseudoLanguages() {
        UserDefaults.standard.removeObject(forKey: testKey)
        AppPreferences.Keyboard.save("en-US")

        AppPreferences.Keyboard.save("dictation")
        #expect(AppPreferences.Keyboard.lastLanguage == "en-US")

        AppPreferences.Keyboard.save("emoji")
        #expect(AppPreferences.Keyboard.lastLanguage == "en-US")

        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test func keyboardLanguageNormalizeRejectsMalformedValues() {
        #expect(AppPreferences.Keyboard.normalize(nil) == nil)
        #expect(AppPreferences.Keyboard.normalize("") == nil)
        #expect(AppPreferences.Keyboard.normalize(" ") == nil)
        #expect(AppPreferences.Keyboard.normalize("1") == nil)
        #expect(AppPreferences.Keyboard.normalize("x") == nil)
        #expect(AppPreferences.Keyboard.normalize("emoji") == nil)
        #expect(AppPreferences.Keyboard.normalize("en-US") == "en-US")
        #expect(AppPreferences.Keyboard.normalize("zh-Hans") == "zh-Hans")
    }

    // MARK: - Full Fallback Chain

    @Test func localeResolutionFallbackChain() {
        UserDefaults.standard.removeObject(forKey: testKey)

        // 1. Active keyboard wins
        AppPreferences.Keyboard.save("zh-Hans")
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

    // MARK: - Orchestration

    @Test func recordingAudioSessionPolicySupportsBidirectionalBluetoothHFP() {
        #if os(iOS)
        #expect(VoiceInputSystemAccess.recordingCategory == .playAndRecord)
        #expect(VoiceInputSystemAccess.recordingMode == .default)
        let options = VoiceInputSystemAccess.recordingCategoryOptions
        #expect(options.contains(.allowBluetoothHFP))
        #expect(!options.contains(.allowBluetoothA2DP))
        #expect(!options.contains(.defaultToSpeaker))
        if #available(iOS 26.2, *) {
            #expect(!options.contains(.farFieldInput))
        }
        if #available(iOS 26.0, *) {
            #expect(!options.contains(.bluetoothHighQualityRecording))
        }
        #endif
    }

    @Test func bluetoothRouteLossAbandonsActiveCapture() {
        #if os(iOS)
        #expect(
            VoiceInputManager.shouldAbandonCaptureForRouteChange(
                reason: .oldDeviceUnavailable,
                previousHadBluetooth: true
            )
        )
        #expect(
            !VoiceInputManager.shouldAbandonCaptureForRouteChange(
                reason: .oldDeviceUnavailable,
                previousHadBluetooth: false
            )
        )
        #expect(
            !VoiceInputManager.shouldAbandonCaptureForRouteChange(
                reason: .newDeviceAvailable,
                previousHadBluetooth: true
            )
        )
        #endif
    }

    @Test func bluetoothRouteLossSurfacesFailureAndAllowsExplicitRetry() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }
        let access = MockVoiceInputSystemAccess()
        let playback = MockVoicePlaybackInterrupter()
        let session = MockVoiceSession()
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        manager.setPlaybackInterrupter(playback)
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")
        await manager.handleLostBluetoothRoute(
            rawReason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            previousHadBluetooth: true
        )
        if case .error(let message) = manager.state {
            #expect(message.contains("Bluetooth"))
            #expect(message.contains("try"))
            #expect(message.contains("discarded"))
        } else {
            Issue.record("Lost capture must end in an explicit error, got \(manager.state)")
        }
        #expect(session.cancelCallCount == 1)
        #expect(access.deactivateAudioSessionCallCount == 1)
        #expect(playback.endCaptureInterruptionCallCount == 1)
        #expect(manager.activeRecordingSource == nil)
        #expect(!manager._testOperationInFlight)
        let retry = MockVoiceSession()
        provider.makeSessionHandler = { _, _ in retry }
        try await manager.startRecording(keyboardLanguage: "en-US", source: "retry")
        #expect(manager.state == .recording)
        await manager.cancelRecording()
    }

    @Test func routeLossDuringStartupCannotBecomeRecordingOrFallback() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }
        let access = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let entered = AsyncGate()
        let resume = AsyncGate()
        session.startHandler = { await entered.open(); await resume.wait() }
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        let start = Task { try await manager.startRecording(keyboardLanguage: "en-US", source: "test") }
        await entered.wait()
        await manager.handleLostBluetoothRoute(
            rawReason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            previousHadBluetooth: true
        )
        await resume.open()
        _ = try? await start.value
        if case .error = manager.state {} else { Issue.record("Route loss was hidden: \(manager.state)") }
        #expect(session.cancelCallCount == 1)
        #expect(access.activateBuiltInAudioSessionCallCount == 0)
        #expect(!manager._testOperationInFlight)
    }

    @Test func routeLossOwnsCleanupUntilCancelledAndIgnoresDuplicateNotification() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }
        let access = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let cancelEntered = AsyncGate()
        let finishCancel = AsyncGate()
        session.cancelHandler = { await cancelEntered.open(); await finishCancel.wait() }
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")
        let loss = Task {
            await manager.handleLostBluetoothRoute(
                rawReason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                previousHadBluetooth: true
            )
        }
        await cancelEntered.wait()
        #expect(manager.ownsCaptureAudioSession)
        #expect(access.deactivateAudioSessionCallCount == 0)
        await #expect(throws: VoiceInputError.self) {
            try await manager.startRecording(keyboardLanguage: "en-US", source: "too-early")
        }
        await manager.handleLostBluetoothRoute(
            rawReason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            previousHadBluetooth: true
        )
        #expect(session.cancelCallCount == 1)
        await finishCancel.open()
        await loss.value
        #expect(!manager.ownsCaptureAudioSession)
        #expect(access.deactivateAudioSessionCallCount == 1)
        if case .error = manager.state {} else { Issue.record("Lost route must stay explicit") }
    }

    @Test func retiredStartupCannotOverwriteRetryAfterRouteLoss() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }
        let access = MockVoiceInputSystemAccess()
        let old = MockVoiceSession()
        let entered = AsyncGate()
        let resume = AsyncGate()
        old.startHandler = { await entered.open(); await resume.wait() }
        old.startError = TestVoiceError("late old capture failure")
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in old }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        let start = Task { try await manager.startRecording(keyboardLanguage: "en-US", source: "old") }
        await entered.wait()
        await manager.handleLostBluetoothRoute(
            rawReason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            previousHadBluetooth: true
        )
        let retry = MockVoiceSession()
        provider.makeSessionHandler = { _, _ in retry }
        try await manager.startRecording(keyboardLanguage: "en-US", source: "retry")
        await resume.open()
        _ = try? await start.value
        #expect(manager.state == .recording)
        #expect(manager.activeRecordingSource == "retry")
        #expect(retry.cancelCallCount == 0)
        #expect(access.activateBuiltInAudioSessionCallCount == 0)
        #expect(access.deactivateAudioSessionCallCount == 1)
        await manager.cancelRecording()
    }

    @Test func startRecordingStopsActivePlaybackBeforeAudioSessionActivationAndCapture() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        var events: [String] = []
        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.onActivateAudioSession = { events.append("activate") }

        let playback = MockVoicePlaybackInterrupter()
        playback.hasActivePlayback = true
        playback.onStop = { events.append("stopPlayback") }

        let session = MockVoiceSession()
        session.startHandler = { events.append("startCapture") }

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setPlaybackInterrupter(playback)

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        #expect(manager.state == .recording)
        #expect(playback.stopCallCount == 1)
        #expect(events == ["stopPlayback", "activate", "startCapture"])
    }

    @Test func startRecordingDoesNotStopIdlePlaybackInterrupter() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let playback = MockVoicePlaybackInterrupter()
        playback.hasActivePlayback = false

        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setPlaybackInterrupter(playback)

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        #expect(manager.state == .recording)
        #expect(playback.stopCallCount == 0)
        #expect(systemAccess.activateAudioSessionCallCount == 1)
        #expect(session.startCallCount == 1)
    }

    @Test func activeRecordingSourceTracksCurrentOwner() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        #expect(manager.activeRecordingSource == nil)
        #expect(!manager.isActiveRecordingSource(ComposerShared.VoiceInputOwner.reviewCommentInline.rawValue))

        try await manager.startRecording(
            keyboardLanguage: "en-US",
            source: ComposerShared.VoiceInputOwner.reviewCommentInline.rawValue
        )

        #expect(manager.isActiveRecordingSource(ComposerShared.VoiceInputOwner.reviewCommentInline.rawValue))
        #expect(!manager.isActiveRecordingSource(ComposerShared.VoiceInputOwner.inlineComposer.rawValue))

        _ = await manager.stopRecording()

        #expect(manager.activeRecordingSource == nil)
        #expect(!manager.isActiveRecordingSource(ComposerShared.VoiceInputOwner.reviewCommentInline.rawValue))
    }

    @Test func micPresentationBlocksNonOwningInputs() {
        let manager = VoiceInputManager()
        manager._testState = .recording
        manager._testActiveRecordingSource = ComposerShared.VoiceInputOwner.reviewCommentInline.rawValue

        let ownerPresentation = ComposerShared.micButtonPresentation(for: manager, owner: .reviewCommentInline)
        let otherPresentation = ComposerShared.micButtonPresentation(for: manager, owner: .inlineComposer)

        #expect(ownerPresentation.isRecording)
        #expect(ownerPresentation.isEnabled)
        #expect(!otherPresentation.isRecording)
        #expect(!otherPresentation.isEnabled)
        #expect(otherPresentation.isBlockedByOtherOwner)
    }

    @Test func capturePlaybackSuppressionCoversRecordingAndStopsOnTeardown() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let playback = MockVoicePlaybackInterrupter()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setPlaybackInterrupter(playback)

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        #expect(manager.state == .recording)
        #expect(playback.beginCaptureInterruptionCallCount == 1)
        #expect(playback.endCaptureInterruptionCallCount == 0)

        _ = await manager.stopRecording()

        #expect(manager.state == .idle)
        #expect(playback.endCaptureInterruptionCallCount == 1)
    }

    @Test func startRecordingProcessesSessionLifecycle() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        #expect(manager.state == .recording)
        #expect(manager.activeEngine == .classicDictation)
        #expect(manager.activeLanguageLabel == "EN")
        #expect(manager.routeIndicator == .onDevice)
        #expect(systemAccess.activateAudioSessionCallCount == 1)
        #expect(session.startCallCount == 1)

        session.yieldAudioLevel(0.6)
        session.yieldEvent(.partialTranscript("hel"))
        session.yieldEvent(.appendFinalTranscript("hello"))

        #expect(await waitForMainActorCondition { manager.audioLevel == 0.6 })
        #expect(await waitForMainActorCondition { manager.currentTranscript == "hello" })

        await manager.stopRecording()

        #expect(manager.state == .idle)
        #expect(manager.audioLevel == 0)
        #expect(manager.activeEngine == nil)
        #expect(manager.activeLanguageLabel == nil)
        #expect(systemAccess.deactivateAudioSessionCallCount == 1)
        #expect(session.stopCallCount == 1)
    }

    @Test func startRecordingWithOnDeviceOnlyRequestsMicPermission() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.hasPermissions = false
        systemAccess.hasMicPermission = true
        systemAccess.requestPermissionsResult = false

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)

        try await manager.startRecording(source: "test")

        #expect(systemAccess.requestMicPermissionCallCount == 0)
        #expect(systemAccess.requestPermissionsCallCount == 0)
        #expect(classicProvider.prepareSessionCallCount == 1)
        #expect(manager.state == .recording)
    }

    @Test func startRecordingWithOnDeviceHandlesMicDenial() async {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.hasPermissions = false
        systemAccess.hasMicPermission = false
        systemAccess.requestMicPermissionResult = false

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)

        try? await manager.startRecording(source: "test")

        #expect(systemAccess.requestMicPermissionCallCount == 1)
        #expect(systemAccess.requestPermissionsCallCount == 0)
        #expect(manager.state == .error("Microphone permission denied"))
        #expect(classicProvider.prepareSessionCallCount == 0)
    }

    @Test func startRecordingWithServerDictationOnlyRequestsMicPermission() async {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.hasPermissions = true
        systemAccess.hasMicPermission = false
        systemAccess.requestMicPermissionResult = false

        let serverProvider = MockVoiceProvider(id: .oppiServer, engine: .serverDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [serverProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.remote)
        let conn = ServerConnection()
        conn.setServerDictationAvailableForTesting(true)
        manager.setServerConnection(conn)

        try? await manager.startRecording(source: "test")

        #expect(systemAccess.requestMicPermissionCallCount == 1)
        #expect(systemAccess.requestPermissionsCallCount == 0)
        #expect(manager.state == .error("Microphone permission denied"))
        #expect(serverProvider.prepareSessionCallCount == 0)
    }

    @Test func cancelDuringPreparingCancelsProviderPreparationAndPreventsStaleRecording() async {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let session = MockVoiceSession()
        let gate = AsyncGate()

        classicProvider.prepareSessionHandler = { _ in
            await gate.wait()
            return VoiceProviderPreparation(audioFormat: nil, pathTag: "gate", setupMetricTags: [:])
        }
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        let startTask = Task {
            try? await manager.startRecording(source: "test")
        }

        #expect(await waitForMainActorCondition { manager.state == .preparingModel })
        await manager.cancelRecording()
        await gate.open()
        await startTask.value

        #expect(manager.state == .idle)
        #expect(classicProvider.cancelPreparationCallCount == 1)
        #expect(session.startCallCount == 0)
        #expect(manager.activeEngine == nil)
    }

    @Test func resultsStreamFailureTransitionsToErrorAndCleansUpSession() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(source: "test")
        session.yieldEvent(.replaceFinalTranscript("hello"))
        session.finishEvents(throwing: TestVoiceError("stream blew up"))

        #expect(await waitForMainActorCondition {
            if case .error("stream blew up") = manager.state {
                return true
            }
            return false
        })
        #expect(systemAccess.deactivateAudioSessionCallCount == 1)
        #expect(manager.currentTranscript.isEmpty)
        #expect(manager.activeEngine == nil)
    }

    @Test func startRecordingFailureCleansUpAudioSessionAndRethrows() async {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        session.startError = TestVoiceError("start failed")

        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        await #expect(throws: TestVoiceError.self) {
            try await manager.startRecording(source: "test")
        }

        #expect(systemAccess.activateAudioSessionCallCount == 2)
        #expect(systemAccess.deactivateAudioSessionCallCount == 2)
        #expect(manager.activeEngine == nil)
        #expect(manager.activeLanguageLabel == nil)
        #expect(manager.audioLevel == 0)
        #expect({
            if case .error("start failed") = manager.state {
                return true
            }
            return false
        }())
    }

    @Test(arguments: [true, false])
    func serverCaptureStartFailureRetriesWithFreshPreparation(engineThrew: Bool) async throws {
        let systemAccess = MockVoiceInputSystemAccess()
        let firstSession = MockVoiceSession()
        // Both a throwing engine and one that silently stops without PCM must
        // reach the built-in safety net after the same-route restart is exhausted.
        firstSession.startError = engineThrew
            ? NSError(domain: "com.apple.coreaudio.avfaudio", code: 1936094051)
            : VoiceInputError.audioCaptureUnavailable
        let secondSession = MockVoiceSession()
        var sessions = [firstSession, secondSession]
        let provider = MockVoiceProvider(id: .oppiServer, engine: .serverDictation)
        provider.makeSessionHandler = { _, _ in sessions.removeFirst() }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.remote)
        manager.setServerCredentials(ServerCredentials(
            host: "localhost", port: 7749, token: "test-token", name: "test", scheme: .http
        ))
        manager.setServerConnection(ServerConnection())

        try await manager.startRecording(keyboardLanguage: "en-US", source: "inline_mic_tap")

        #expect(manager.state == .recording)
        #expect(manager.activeEngine == .serverDictation)
        #expect(systemAccess.activateBuiltInAudioSessionCallCount == 1)
        #expect(provider.prepareSessionCallCount == 2, "A cancelled remote take cannot reuse its readiness task or stream")
        #expect(provider.makeSessionCallCount == 2)
        #expect(firstSession.cancelCallCount == 1)
        #expect(secondSession.startCallCount == 1)
        #expect(systemAccess.activateAudioSessionCallCount == 2)
        #expect(systemAccess.deactivateAudioSessionCallCount == 1)
        await manager.cancelRecording()
    }

    @Test(arguments: [true, false])
    func remoteCaptureRetryIsBoundedAndDoesNotRetryNetworkErrors(isAudioError: Bool) async {
        let systemAccess = MockVoiceInputSystemAccess()
        let provider = MockVoiceProvider(id: .oppiServer, engine: .serverDictation)
        provider.makeSessionHandler = { _, _ in
            let session = MockVoiceSession()
            session.startError = isAudioError
                ? NSError(domain: "com.apple.coreaudio.avfaudio", code: 1936094051)
                : NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            return session
        }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.remote)
        manager.setServerCredentials(ServerCredentials(
            host: "localhost", port: 7749, token: "test-token", name: "test", scheme: .http
        ))
        manager.setServerConnection(ServerConnection())
        await #expect(throws: NSError.self) { try await manager.startRecording(source: "test") }
        #expect(provider.prepareSessionCallCount == (isAudioError ? 2 : 1))
        #expect(provider.makeSessionCallCount == (isAudioError ? 2 : 1))
        #expect(systemAccess.activateBuiltInAudioSessionCallCount == (isAudioError ? 1 : 0))
        #expect(!manager.isRecording)
        #expect(!manager._testOperationInFlight)
        #expect(manager.activeRecordingSource == nil)
    }

    @Test func cancelledCaptureStartDoesNotRetry() async throws {
        let systemAccess = MockVoiceInputSystemAccess()
        let provider = MockVoiceProvider(id: .appleModernSpeech, engine: .modernSpeech)
        provider.makeSessionHandler = { _, _ in
            let session = MockVoiceSession()
            session.startError = CancellationError()
            return session
        }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)
        try await manager.startRecording(source: "test")
        #expect(manager.state == .idle)
        #expect(provider.makeSessionCallCount == 1)
        #expect(systemAccess.activateBuiltInAudioSessionCallCount == 0)
        #expect(!manager._testOperationInFlight)
    }

    @Test func startRecordingRetriesOnDeviceSessionStartAfterAudioReset() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let firstSession = MockVoiceSession()
        firstSession.startError = TestVoiceError("first start failed")
        let secondSession = MockVoiceSession()
        var sessions = [firstSession, secondSession]

        let modernProvider = MockVoiceProvider(id: .appleModernSpeech, engine: .modernSpeech)
        modernProvider.makeSessionHandler = { _, _ in
            sessions.removeFirst()
        }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [modernProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)

        try await manager.startRecording(source: "test")

        #expect(manager.state == .recording)
        #expect(manager.activeEngine == .modernSpeech)
        #expect(modernProvider.makeSessionCallCount == 2)
        #expect(firstSession.startCallCount == 1)
        #expect(firstSession.cancelCallCount == 1)
        #expect(secondSession.startCallCount == 1)
        #expect(systemAccess.activateAudioSessionCallCount == 2)
        #expect(systemAccess.deactivateAudioSessionCallCount == 1)
    }

    /// Remote mode without server dictation available fails clearly instead of falling back.
    @Test func remoteModeWithoutAsrFailsClearly() async {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let onDeviceProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let serverProvider = MockVoiceProvider(id: .oppiServer, engine: .serverDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [onDeviceProvider, serverProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.remote)
        // No connection / no serverDictationAvailable — should fail clearly.

        try? await manager.startRecording(source: "test")

        #expect(serverProvider.prepareSessionCallCount == 0)
        #expect(onDeviceProvider.prepareSessionCallCount == 0)
        #expect(manager.state == .error("Server dictation is not connected. Connect to an Oppi server first."))
    }

    /// Credentials + a connection are enough for remote mode to try the server-bound
    /// `/dictation/stream` endpoint. Availability errors should come from that stream,
    /// not from a stale capability preflight.
    @Test func remoteModeWithCredentialsAttemptsServerProviderWithoutCapabilityPreflight() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let onDeviceProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let serverProvider = MockVoiceProvider(id: .oppiServer, engine: .serverDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [onDeviceProvider, serverProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.remote)
        let credentials = ServerCredentials(
            host: "localhost", port: 7749,
            token: "test-token",
            name: "test-server",
            scheme: .http
        )
        manager.setServerCredentials(credentials)
        let conn = ServerConnection()
        _ = conn.configure(credentials: credentials)
        manager.setServerConnection(conn)

        try await manager.startRecording(source: "test")

        #expect(serverProvider.prepareSessionCallCount == 1)
        #expect(onDeviceProvider.prepareSessionCallCount == 0)
        #expect(manager.state == .recording)
    }

    @Test func remoteModeWithExplicitTargetStillUsesServerProvider() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let serverProvider = MockVoiceProvider(id: .oppiServer, engine: .serverDictation)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [serverProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.remote)
        manager.setServerCredentials(ServerCredentials(
            host: "localhost", port: 7749,
            token: "test-token",
            name: "test-server",
            scheme: .http
        ))

        let conn = ServerConnection()
        _ = conn.configure(credentials: ServerCredentials(
            host: "localhost", port: 7749,
            token: "test-token",
            name: "test-server",
            scheme: .http
        ))
        manager.setServerConnection(conn)
        manager.setServerDictationTarget(ServerDictationTarget(workspaceId: "ws-1", sessionId: "dictation-1"))

        try await manager.startRecording(source: "test")

        #expect(serverProvider.prepareSessionCallCount == 1)
        #expect(serverProvider.lastContext?.serverDictationTarget?.workspaceId == "ws-1")
        #expect(serverProvider.lastContext?.serverDictationTarget?.sessionId == "dictation-1")
        #expect(manager.state == .recording)
    }

    /// server dictation advertised but remote setup fails — remote mode should surface the
    /// server failure instead of silently retrying on-device.
    @Test func remoteModeWithAsrAvailableButServerSetupFailureFailsClearly() async {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let onDeviceProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        let serverProvider = MockVoiceProvider(id: .oppiServer, engine: .serverDictation)
        serverProvider.prepareSessionHandler = { _ in
            throw VoiceInputError.remoteRequestTimedOut
        }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [onDeviceProvider, serverProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.remote)
        manager.setServerCredentials(ServerCredentials(
            host: "localhost", port: 7749,
            token: "test-token",
            name: "test-server",
            scheme: .http
        ))

        let conn = ServerConnection()
        conn.setServerDictationAvailableForTesting(true)
        manager.setServerConnection(conn)

        try? await manager.startRecording(source: "test")

        #expect(serverProvider.prepareSessionCallCount == 1)
        #expect(onDeviceProvider.prepareSessionCallCount == 0)
        #expect(manager.state == .error("Remote ASR request timed out. Check server load or network latency."))
        #expect(manager.activeEngine == nil)
    }

    // MARK: - Send-while-recording: stop awaits final transcript

    /// Verifies that stopRecording() waits for the final transcript event
    /// before returning. This is critical for send-while-recording: the caller
    /// must see the corrected transcript before sending the message.
    @Test func stopRecordingAwaitsServerFinalTranscript() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        // Simulate streaming partial results (append doesn't trigger typewriter)
        session.yieldEvent(.appendFinalTranscript("hello world"))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "hello world" })

        // Configure stop to simulate server delay: yield corrected final transcript,
        // then finish the event stream (mimics dictation_final arrival).
        session.stopHandler = { @MainActor [weak session] in
            guard let session else { return }
            session.yieldEvent(.replaceFinalTranscript("Hello, world!"))
            session.finishEvents()
        }

        // stopRecording returns the corrected transcript captured before teardown
        let finalTranscript = await manager.stopRecording()

        #expect(finalTranscript == "Hello, world!",
                "stopRecording must wait for final transcript before returning")
        // After teardown, transcript state is cleared to prevent stale observations
        #expect(manager.currentTranscript.isEmpty,
                "currentTranscript must be empty after stop to prevent onChange leaks")
        #expect(manager.state == .idle)
    }

    /// Verifies that the transcript seen after stopRecording() includes
    /// the replaceFinalTranscript event, not just the last partial.
    @Test func stopRecordingReplacesStreamingTextWithFinal() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        // Streaming text preview (use append to avoid typewriter)
        session.yieldEvent(.appendFinalTranscript("switching back to and we'll see"))
        #expect(await waitForMainActorCondition {
            manager.finalizedTranscript == "switching back to and we'll see"
        })

        // Stop yields the final transcript (replace overwrites the append)
        session.stopHandler = { @MainActor [weak session] in
            guard let session else { return }
            session.yieldEvent(.replaceFinalTranscript(
                "switching back to English, and we'll see"
            ))
            session.finishEvents()
        }

        let finalTranscript = await manager.stopRecording()

        #expect(finalTranscript == "switching back to English, and we'll see",
                "Final transcript must replace streaming text")
        #expect(manager.currentTranscript.isEmpty,
                "currentTranscript must be empty after stop")
    }

    /// Verifies that typewriter animation is committed during stop so
    /// currentTranscript returns the full text, not a partial reveal.
    /// This ensures send-while-animating captures the complete transcript.
    @Test func stopRecordingCommitsAnimationBeforeFinalTranscript() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        // Trigger typewriter animation via replaceFinalTranscript during recording
        session.yieldEvent(.replaceFinalTranscript("hello world this is a longer sentence"))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript.contains("hello") })

        // Typewriter might still be animating — displayText could be partial
        let preStop = manager.typewriterAnimator.isAnimating

        session.stopHandler = { @MainActor [weak session] in
            guard let session else { return }
            session.yieldEvent(.replaceFinalTranscript("Hello world, this is a longer sentence."))
            session.finishEvents()
        }

        let finalTranscript = await manager.stopRecording()

        // After stop: no animation, return value has full corrected text
        #expect(!manager.typewriterAnimator.isAnimating,
                "Animation must be finished after stop")
        #expect(finalTranscript == "Hello world, this is a longer sentence.",
                "Final corrected text must be returned by stopRecording")
        #expect(manager.currentTranscript.isEmpty,
                "currentTranscript must be empty after stop")
    }

    // MARK: - Send-while-recording: transcript clearing prevents stale observation

    /// Regression test for the send-while-dictating bug.
    ///
    /// When the user taps send during voice recording, handleSend() sets
    /// textBeforeRecording = nil (disabling onChange sync), then awaits
    /// stopRecording(), then calls onSend() which asynchronously clears text.
    ///
    /// Without the fix, currentTranscript retained the final value after stop,
    /// and a late SwiftUI onChange could re-populate the text field after clearing.
    ///
    /// The fix: teardownSession() clears finalizedTranscript and volatileTranscript,
    /// so currentTranscript is empty after stop. No late observation can leak.
    @Test func sendWhileRecordingClearsTranscriptToPreventStaleObservation() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        // Simulate streaming dictation updates
        session.yieldEvent(.replaceFinalTranscript("hello world"))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript.contains("hello") })

        // Stop yields the final transcript (like dictation_final)
        session.stopHandler = { @MainActor [weak session] in
            guard let session else { return }
            session.yieldEvent(.replaceFinalTranscript("Hello, world!"))
            session.finishEvents()
        }

        // Simulate the handleSend() flow: stop then check state
        let finalTranscript = await manager.stopRecording()

        // The return value has the corrected transcript
        #expect(finalTranscript == "Hello, world!")

        // Critical assertion: currentTranscript must be empty after stop.
        // This prevents any late SwiftUI onChange(of: currentTranscript) from
        // re-populating a text field that was cleared by onSend().
        #expect(manager.currentTranscript.isEmpty,
                "currentTranscript must be empty after stop to prevent text field re-population")
        #expect(manager.finalizedTranscript.isEmpty,
                "finalizedTranscript must be cleared by teardown")
        #expect(manager.volatileTranscript.isEmpty,
                "volatileTranscript must be cleared by teardown")

        // Simulate what onSend does: clear a text binding
        var textBinding = "Hello, world!"
        textBinding = ""  // onSend clears

        // Wait to verify no late transcript update re-populates
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(100)) {
            manager.currentTranscript.isEmpty
        }, "currentTranscript must stay empty after stop — no late updates")

        // The text binding stays cleared
        #expect(textBinding.isEmpty, "Text must stay cleared after send")
    }

    /// Verifies that stopRecording returns the correct transcript even when
    /// the typewriter animator was mid-animation at the time of stop.
    @Test func stopRecordingReturnValueIncludesAnimatedText() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        // Trigger typewriter animation (replace during recording starts animation)
        session.yieldEvent(.replaceFinalTranscript("a]longer sentence that takes time to animate"))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript.contains("longer") })

        // Stop without a corrective final — just finish the stream.
        // The committed animation text should be returned.
        session.stopHandler = { @MainActor [weak session] in
            guard let session else { return }
            session.finishEvents()
        }

        let result = await manager.stopRecording()

        #expect(result == "a]longer sentence that takes time to animate",
                "Return value must contain committed animation text")
        #expect(manager.currentTranscript.isEmpty)
    }

    /// When the server does NOT provide committedText/activeText, the manager
    /// must infer the split from the previous committedText state using the
    /// splitActiveText heuristic. This is the path non-Oppi providers use.
    @Test func replaceTranscriptInfersSplitFromPreviousStateWithoutExplicitFields() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        // First replace without explicit split — no prior committedText,
        // so the entire text becomes volatile (heuristic else branch).
        session.yieldEvent(.replaceFinalTranscript("Hello world."))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "Hello world." })
        manager.typewriterAnimator.commitCurrentAnimation()
        #expect(manager.currentTranscriptVolatileSuffixLength == "Hello world.".count,
                "Before any snap, the full visible transcript should stay volatile")

        // Snap without explicit split — settles everything.
        session.yieldEvent(.replaceFinalTranscript("Hello world.", snap: true))
        #expect(await waitForMainActorCondition { manager.currentTranscriptVolatileSuffixLength == 0 },
                "A snap should settle the visible text immediately")

        // Second replace without explicit split — heuristic should detect that
        // "Hello world." is already committed and treat "testing now" as active.
        session.yieldEvent(.replaceFinalTranscript("Hello world. testing now"))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "Hello world. testing now" })
        manager.typewriterAnimator.commitCurrentAnimation()
        #expect(manager.currentTranscriptVolatileSuffixLength == "testing now".count,
                "Heuristic split should keep only the new tail volatile")

        await manager.cancelRecording()
    }

    @Test func replaceTranscriptUsesExplicitCommittedAndActiveSplitFromProxy() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        session.yieldEvent(.replaceFinalTranscript(
            "Hello world.",
            committedText: "",
            activeText: "Hello world."
        ))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "Hello world." })
        manager.typewriterAnimator.commitCurrentAnimation()
        #expect(manager.currentTranscriptVolatileSuffixLength == "Hello world.".count,
                "Before the first segment commit, the full visible transcript should stay volatile")

        session.yieldEvent(.replaceFinalTranscript(
            "Hello world.",
            snap: true,
            committedText: "Hello world.",
            activeText: ""
        ))
        #expect(await waitForMainActorCondition { manager.currentTranscriptVolatileSuffixLength == 0 },
                "A snap/segment commit should settle the visible text immediately")

        session.yieldEvent(.replaceFinalTranscript(
            "Hello world. testing now",
            committedText: "Hello world.",
            activeText: "testing now"
        ))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "Hello world. testing now" })
        manager.typewriterAnimator.commitCurrentAnimation()
        #expect(manager.currentTranscriptVolatileSuffixLength == "testing now".count,
                "With an explicit proxy split, only the active tail should stay volatile")

        await manager.cancelRecording()
    }

    @Test func replaceTranscriptDoesNotBleedCommittedTextWhenHeuristicSplitFailsAfterChunkCommit() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        session.yieldEvent(.replaceFinalTranscript(
            "Hello wurld.",
            snap: true,
            committedText: "Hello wurld.",
            activeText: ""
        ))
        #expect(await waitForMainActorCondition { manager.currentTranscriptVolatileSuffixLength == 0 })

        session.yieldEvent(.replaceFinalTranscript("Hello world. testing now"))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "Hello world. testing now" })
        manager.typewriterAnimator.commitCurrentAnimation()
        #expect(manager.currentTranscriptVolatileSuffixLength == "testing now".count,
                "A corrected committed chunk must stay settled when the heuristic split fails")

        await manager.cancelRecording()
    }

    @Test func replaceTranscriptDoesNotBleedCommittedTextWhenExplicitSplitRetreats() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        session.yieldEvent(.replaceFinalTranscript(
            "Hello world.",
            snap: true,
            committedText: "Hello world.",
            activeText: ""
        ))
        #expect(await waitForMainActorCondition { manager.currentTranscriptVolatileSuffixLength == 0 })

        session.yieldEvent(.replaceFinalTranscript(
            "Hello world. testing now",
            committedText: "Hello",
            activeText: "world. testing now"
        ))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "Hello world. testing now" })
        manager.typewriterAnimator.commitCurrentAnimation()
        #expect(manager.currentTranscriptVolatileSuffixLength == "testing now".count,
                "Once a chunk is committed, later proxy splits must not repaint it as volatile")

        await manager.cancelRecording()
    }

    @Test func replaceTranscriptDoesNotBleedCommittedTextWhenCorrectionChangesCommittedPrefixLength() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        session.yieldEvent(.replaceFinalTranscript(
            "screen recording stopped",
            snap: true,
            committedText: "screen recording stopped",
            activeText: ""
        ))
        #expect(await waitForMainActorCondition { manager.currentTranscriptVolatileSuffixLength == 0 })

        session.yieldEvent(.replaceFinalTranscript("screen recording randomly stopped testing now"))
        #expect(await waitForMainActorCondition {
            manager.finalizedTranscript == "screen recording randomly stopped testing now"
        })
        manager.typewriterAnimator.commitCurrentAnimation()
        #expect(manager.currentTranscriptVolatileSuffixLength == "testing now".count,
                "Committed text that is corrected to a different length must stay settled")

        await manager.cancelRecording()
    }

    @Test func retiredPreparingStartDoesNotEraseNewerStartOwnership() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let gateA = AsyncGate()
        let gateB = AsyncGate()
        let sessionB = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.prepareSessionHandler = { _ in
            if classicProvider.prepareSessionCallCount == 1 {
                await gateA.wait()
            } else {
                await gateB.wait()
            }
            return VoiceProviderPreparation(
                audioFormat: nil,
                pathTag: "mock",
                setupMetricTags: [:]
            )
        }
        classicProvider.makeSessionHandler = { _, _ in sessionB }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)

        let startA = Task { @MainActor in
            try? await manager.startRecording(source: "take-a")
        }
        #expect(await waitForMainActorCondition {
            manager.state == .preparingModel && classicProvider.prepareSessionCallCount == 1
        })
        let identityA = manager.currentCaptureTakeIdentity()
        #expect(identityA != nil)

        await manager.cancelRecording()
        #expect(manager.state == .idle)
        #expect(manager.currentCaptureTakeIdentity() == nil)
        #expect(!manager._testOperationInFlight)

        let startB = Task { @MainActor in
            try await manager.startRecording(source: "take-b")
        }
        #expect(await waitForMainActorCondition {
            manager.state == .preparingModel && classicProvider.prepareSessionCallCount == 2
        })
        let identityB = manager.currentCaptureTakeIdentity()
        #expect(identityB != nil)
        #expect(identityB != identityA)
        #expect(manager._testOperationInFlight)

        await gateA.open()
        await startA.value

        #expect(manager.state == .preparingModel)
        #expect(manager.currentCaptureTakeIdentity() == identityB)
        #expect(manager._testOperationInFlight)
        #expect(sessionB.cancelCallCount == 0)
        #expect(classicProvider.lastContext?.source == "take-b")

        await gateB.open()
        try await startB.value
        #expect(manager.state == .recording)
        #expect(manager.currentCaptureTakeIdentity() == identityB)
        #expect(sessionB.startCallCount == 1)
        #expect(sessionB.cancelCallCount == 0)
        await manager.cancelRecording()
    }

    @Test func failedStartCleanupAwaitDoesNotEraseNewerStartOwnership() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let cancelEntered = AsyncGate()
        let cancelHold = AsyncGate()
        let gateB = AsyncGate()
        let sessionA = MockVoiceSession()
        sessionA.cancelHandler = {
            await cancelEntered.open()
            await cancelHold.wait()
        }
        let sessionB = MockVoiceSession()
        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.activateAudioSessionError = TestVoiceError("audio session failed")
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.prepareSessionHandler = { _ in
            if classicProvider.prepareSessionCallCount > 1 {
                await gateB.wait()
            }
            return VoiceProviderPreparation(
                audioFormat: nil,
                pathTag: "mock",
                setupMetricTags: [:]
            )
        }
        classicProvider.makeSessionHandler = { _, _ in
            classicProvider.makeSessionCallCount == 1 ? sessionA : sessionB
        }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)

        let startA = Task { @MainActor in
            try? await manager.startRecording(source: "take-a")
        }
        await cancelEntered.wait()
        let identityA = manager.currentCaptureTakeIdentity()
        #expect(identityA != nil)
        #expect(manager.state == .preparingModel)
        #expect(sessionA.cancelCallCount == 1)

        await manager.cancelRecording(matching: identityA)
        #expect(manager.state == .idle)
        #expect(manager.currentCaptureTakeIdentity() == nil)
        #expect(!manager._testOperationInFlight)

        systemAccess.activateAudioSessionError = nil
        let startB = Task { @MainActor in
            try await manager.startRecording(source: "take-b")
        }
        #expect(await waitForMainActorCondition {
            manager.state == .preparingModel && classicProvider.prepareSessionCallCount == 2
        })
        let identityB = manager.currentCaptureTakeIdentity()
        #expect(identityB != nil)
        #expect(identityB != identityA)
        #expect(manager._testOperationInFlight)

        await cancelHold.open()
        await startA.value

        #expect(manager.state == .preparingModel)
        #expect(manager.currentCaptureTakeIdentity() == identityB)
        #expect(manager._testOperationInFlight)
        #expect(sessionB.cancelCallCount == 0)
        #expect(classicProvider.lastContext?.source == "take-b")

        await gateB.open()
        try await startB.value
        #expect(manager.state == .recording)
        #expect(manager.currentCaptureTakeIdentity() == identityB)
        #expect(sessionB.startCallCount == 1)
        #expect(sessionB.cancelCallCount == 0)
        await manager.cancelRecording()
    }

    @Test func failedStartCleanupAwaitDoesNotWipeNewerBoundSession() async throws {
        resetVoicePreferences()
        defer { resetVoicePreferences() }

        let cancelEntered = AsyncGate()
        let cancelHold = AsyncGate()
        let sessionA = MockVoiceSession()
        sessionA.cancelHandler = {
            await cancelEntered.open()
            await cancelHold.wait()
        }
        let sessionB = MockVoiceSession()
        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.activateAudioSessionError = TestVoiceError("audio session failed")
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in
            classicProvider.makeSessionCallCount == 1 ? sessionA : sessionB
        }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)

        let startA = Task { @MainActor in
            try? await manager.startRecording(source: "take-a")
        }
        await cancelEntered.wait()
        let identityA = manager.currentCaptureTakeIdentity()
        #expect(identityA != nil)
        #expect(manager.state == .preparingModel)
        #expect(sessionA.cancelCallCount == 1)

        await manager.cancelRecording(matching: identityA)
        #expect(manager.state == .idle)
        #expect(manager.currentCaptureTakeIdentity() == nil)
        #expect(!manager._testOperationInFlight)

        systemAccess.activateAudioSessionError = nil
        try await manager.startRecording(source: "take-b")
        #expect(manager.state == .recording)
        #expect(sessionB.startCallCount == 1)
        #expect(sessionB.cancelCallCount == 0)
        let identityB = manager.currentCaptureTakeIdentity()
        #expect(identityB != nil)
        #expect(identityB != identityA)

        await cancelHold.open()
        await startA.value

        #expect(manager.state == .recording)
        #expect(manager.currentCaptureTakeIdentity() == identityB)
        #expect(sessionB.cancelCallCount == 0)
        #expect(sessionB.startCallCount == 1)

        sessionB.yieldAudioLevel(0.5)
        #expect(await waitForMainActorCondition { manager.audioLevel == 0.5 })
        sessionB.yieldEvent(.partialTranscript("keep-b"))
        #expect(await waitForMainActorCondition { manager.volatileTranscript == "keep-b" })

        await manager.cancelRecording()
        #expect(sessionB.cancelCallCount == 1)
        #expect(manager.state == .idle)
    }

    private func resetVoicePreferences() {
        AppPreferences.Voice.setEngineMode(.onDevice)
    }
}
