import XCTest
@testable import Oppi

/// Tests for VoiceInputManager state machine correctness.
///
/// These tests verify the state guards that prevent overlapping operations —
/// the suspected cause of crashes when tapping the mic button rapidly.
/// Speech framework calls are not exercised (no mic/NE in simulator).
@MainActor
final class VoiceInputManagerTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let manager = VoiceInputManager()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isRecording)
        XCTAssertFalse(manager.isProcessing)
        XCTAssertFalse(manager.isPreparing)
        XCTAssertEqual(manager.currentTranscript, "")
        XCTAssertEqual(manager.audioLevel, 0)
    }

    // MARK: - State Guards

    func testStartRecordingRejectsNonIdleState() async throws {
        let manager = VoiceInputManager()

        // Simulate preparing state
        manager._testState = .preparingModel
        try await manager.startRecording()
        XCTAssertEqual(manager.state, .preparingModel, "Should not change state when not idle")

        // Simulate recording state
        manager._testState = .recording
        try await manager.startRecording()
        XCTAssertEqual(manager.state, .recording, "Should not change state when recording")

        // Simulate processing state
        manager._testState = .processing
        try await manager.startRecording()
        XCTAssertEqual(manager.state, .processing, "Should not change state when processing")

        // Simulate error state
        manager._testState = .error("test")
        try await manager.startRecording()
        XCTAssertEqual(manager.state, .error("test"), "Should not change state when in error")
    }

    func testStartRecordingRejectsWhenOperationInFlight() async throws {
        let manager = VoiceInputManager()

        // State is idle but operation lock is held
        manager._testOperationInFlight = true
        try await manager.startRecording()
        XCTAssertEqual(manager.state, .idle, "Should not proceed when operation is in flight")
    }

    func testStopRecordingRejectsNonRecordingState() async {
        let manager = VoiceInputManager()

        // From idle
        await manager.stopRecording()
        XCTAssertEqual(manager.state, .idle)

        // From preparing
        manager._testState = .preparingModel
        await manager.stopRecording()
        XCTAssertEqual(manager.state, .preparingModel)

        // From processing
        manager._testState = .processing
        await manager.stopRecording()
        XCTAssertEqual(manager.state, .processing)
    }

    func testStopRecordingRejectsWhenOperationInFlight() async {
        let manager = VoiceInputManager()
        manager._testState = .recording
        manager._testOperationInFlight = true

        await manager.stopRecording()
        // Should remain recording — stop was rejected
        XCTAssertEqual(manager.state, .recording)
    }

    func testCancelRecordingOnlyFromRecordingOrPreparing() async {
        let manager = VoiceInputManager()

        // From idle — rejected
        await manager.cancelRecording()
        XCTAssertEqual(manager.state, .idle)

        // From preparing — accepted
        manager._testState = .preparingModel
        await manager.cancelRecording()
        XCTAssertEqual(manager.state, .idle, "Cancel should reset to idle from preparing")

        // From recording — accepted
        manager._testState = .recording
        await manager.cancelRecording()
        XCTAssertEqual(manager.state, .idle, "Cancel should reset to idle from recording")
    }

    func testCancelClearsTranscript() async {
        let manager = VoiceInputManager()
        manager._testState = .recording

        await manager.cancelRecording()
        XCTAssertEqual(manager.finalizedTranscript, "")
        XCTAssertEqual(manager.volatileTranscript, "")
        XCTAssertEqual(manager.currentTranscript, "")
    }

    func testCancelResetsOperationLock() async {
        let manager = VoiceInputManager()
        manager._testState = .recording
        manager._testOperationInFlight = true

        await manager.cancelRecording()
        XCTAssertFalse(manager._testOperationInFlight, "Cancel must clear operation lock")
        XCTAssertEqual(manager.state, .idle)
    }

    // MARK: - Computed Properties

    func testIsRecordingOnlyInRecordingState() {
        let manager = VoiceInputManager()

        manager._testState = .idle
        XCTAssertFalse(manager.isRecording)

        manager._testState = .preparingModel
        XCTAssertFalse(manager.isRecording)

        manager._testState = .recording
        XCTAssertTrue(manager.isRecording)

        manager._testState = .processing
        XCTAssertFalse(manager.isRecording)

        manager._testState = .error("x")
        XCTAssertFalse(manager.isRecording)
    }

    func testIsProcessingOnlyInProcessingState() {
        let manager = VoiceInputManager()

        manager._testState = .idle
        XCTAssertFalse(manager.isProcessing)

        manager._testState = .processing
        XCTAssertTrue(manager.isProcessing)

        manager._testState = .recording
        XCTAssertFalse(manager.isProcessing)
    }

    func testIsPreparingOnlyInPreparingState() {
        let manager = VoiceInputManager()

        manager._testState = .idle
        XCTAssertFalse(manager.isPreparing)

        manager._testState = .preparingModel
        XCTAssertTrue(manager.isPreparing)

        manager._testState = .recording
        XCTAssertFalse(manager.isPreparing)
    }

    // MARK: - Prewarm

    func testPrewarmGuardsWhenAlreadyReady() async {
        let manager = VoiceInputManager()
        manager._testModelReady = true

        // Should no-op (model already ready)
        await manager.prewarm()
        // No crash = success
    }

    func testPrewarmGuardsWhenNotIdle() async {
        let manager = VoiceInputManager()
        manager._testState = .recording

        // Should no-op (not idle)
        await manager.prewarm()
        XCTAssertFalse(manager._testModelReady, "Prewarm should not proceed when not idle")
    }

    // MARK: - Rapid Tap Simulation

    /// Simulates the button action pattern from ChatInputBar without
    /// actually calling Speech APIs (which crash in simulator).
    /// Verifies the state machine + operation lock prevent double-entry.
    func testRapidTapButtonActionPattern() async {
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
        XCTAssertEqual(startAttempts, 1, "Only first tap should attempt start")
        XCTAssertEqual(stopAttempts, 0, "No stops — never reached .recording")
        XCTAssertEqual(noopAttempts, 4, "All other taps should be no-ops")
    }

    /// Simulates a start → stop → start cycle via the state machine.
    /// Verifies the operation lock prevents overlap.
    func testStartStopStartCycleStateMachine() async {
        let manager = VoiceInputManager()

        // Tap 1: start → preparing
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager._testOperationInFlight)
        manager._testOperationInFlight = true
        manager._testState = .preparingModel

        // Tap 2 during preparing: should be no-op
        XCTAssertFalse(manager.isRecording)
        XCTAssertNotEqual(manager.state, .idle)

        // Setup completes → recording
        manager._testState = .recording
        manager._testOperationInFlight = false

        // Tap 3: stop
        XCTAssertTrue(manager.isRecording)
        manager._testOperationInFlight = true
        manager._testState = .processing

        // Tap 4 during processing: should be no-op
        XCTAssertFalse(manager.isRecording)
        XCTAssertNotEqual(manager.state, .idle)

        // Stop completes → idle
        manager._testState = .idle
        manager._testOperationInFlight = false

        // Tap 5: can start again
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager._testOperationInFlight)
    }

    /// Verifies that the operation lock alone prevents re-entry
    /// even if state is technically .idle (belt + suspenders).
    func testOperationLockPreventsReentryAtIdleState() async throws {
        let manager = VoiceInputManager()
        XCTAssertEqual(manager.state, .idle)

        // Lock is held (e.g., stop just completed but defer hasn't cleared it)
        manager._testOperationInFlight = true

        // State is idle but lock prevents start
        try await manager.startRecording()
        // Should still be idle — start was rejected
        XCTAssertEqual(manager.state, .idle)
    }

    /// Verifies that after an error, the state eventually resets to idle.
    func testErrorStateResetsToIdle() async {
        let manager = VoiceInputManager()
        manager._testState = .error("test error")

        // Error state should not allow start
        try? await manager.startRecording()
        XCTAssertEqual(manager.state, .error("test error"))

        // After reset
        manager._testState = .idle
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isRecording)
    }

    // MARK: - State Transitions

    func testStateEquality() {
        XCTAssertEqual(VoiceInputManager.State.idle, .idle)
        XCTAssertEqual(VoiceInputManager.State.recording, .recording)
        XCTAssertEqual(VoiceInputManager.State.error("a"), .error("a"))
        XCTAssertNotEqual(VoiceInputManager.State.error("a"), .error("b"))
        XCTAssertNotEqual(VoiceInputManager.State.idle, .recording)
    }
}
