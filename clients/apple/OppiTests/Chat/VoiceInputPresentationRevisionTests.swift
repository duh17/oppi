import Testing
@testable import Oppi

@Suite("Voice input presentation revision")
@MainActor
struct VoiceInputPresentationRevisionTests {
    @Test("Same-text segment commit advances presentation revision")
    func sameTextSegmentCommitAdvancesPresentationRevision() async throws {
        AppPreferences.Voice.setEngineMode(.auto)
        defer { AppPreferences.Voice.setEngineMode(.auto) }

        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let classicProvider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        classicProvider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [classicProvider]),
            systemAccess: systemAccess
        )

        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")
        #expect(manager.transcriptPresentationRevision == 0)

        session.yieldEvent(.replaceFinalTranscript(
            "Hello world.",
            committedText: "",
            activeText: "Hello world."
        ))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "Hello world." })
        manager.typewriterAnimator.commitCurrentAnimation()

        let previewRevision = manager.transcriptPresentationRevision
        #expect(previewRevision > 0)
        #expect(manager.currentTranscript == "Hello world.")
        #expect(manager.currentTranscriptVolatileSuffixLength == "Hello world.".count)

        session.yieldEvent(.replaceFinalTranscript(
            "Hello world.",
            snap: true,
            committedText: "Hello world.",
            activeText: ""
        ))

        #expect(await waitForMainActorCondition {
            manager.transcriptPresentationRevision == previewRevision + 1
        }, "Same-text settle events must still trigger a presentation refresh")
        #expect(manager.currentTranscript == "Hello world.")
        #expect(manager.currentTranscriptVolatileSuffixLength == 0)

        await manager.cancelRecording()
    }
}
