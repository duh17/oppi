import Testing
import UIKit
@testable import Oppi

@Suite("Voice input correction highlight")
@MainActor
struct VoiceInputCorrectionHighlightTests {
    @Test("Segment commit highlights corrected committed words briefly")
    func segmentCommitHighlightsCorrectedWordsBriefly() async throws {
        AppPreferences.Voice.setEngineMode(.onDevice)
        defer { AppPreferences.Voice.setEngineMode(.onDevice) }

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
            committedText: "",
            activeText: "Hello wurld."
        ))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "Hello wurld." })

        session.yieldEvent(.replaceFinalTranscript(
            "Hello world.",
            snap: true,
            committedText: "Hello world.",
            activeText: ""
        ))

        #expect(await waitForMainActorCondition {
            !manager.currentTranscriptCorrectionRanges.isEmpty
        })

        let highlighted = manager.currentTranscriptCorrectionRanges
        let transcript = manager.currentTranscript as NSString
        let highlightedText = highlighted.map { transcript.substring(with: $0) }
        #expect(highlightedText.contains(where: { $0.localizedCaseInsensitiveContains("world") }))

        #expect(await waitForMainActorCondition(timeout: .seconds(1), poll: .milliseconds(20)) {
            manager.currentTranscriptCorrectionRanges.isEmpty
        }, "Correction underline should fade out quickly")

        await manager.cancelRecording()
    }

    @Test("Pure append does not create a correction highlight")
    func pureAppendDoesNotCreateCorrectionHighlight() async throws {
        AppPreferences.Voice.setEngineMode(.onDevice)
        defer { AppPreferences.Voice.setEngineMode(.onDevice) }

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
            committedText: "Hello world.",
            activeText: "testing now"
        ))
        #expect(await waitForMainActorCondition {
            manager.finalizedTranscript == "Hello world. testing now"
        })
        #expect(manager.currentTranscriptCorrectionRanges.isEmpty)

        await manager.cancelRecording()
    }
}

@Suite("Pastable text view correction underline")
@MainActor
struct PastableTextViewCorrectionUnderlineTests {
    @Test("Correction ranges render an orange underline without changing base color")
    func correctionRangesRenderUnderline() {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        let text = "Hello world"
        let correctionRange = NSRange(location: 6, length: 5)

        textView.applyStyledText(
            text,
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue,
            correctionRanges: [correctionRange],
            correctionUnderlineColor: .systemOrange
        )

        let attributed = textView.attributedText ?? NSAttributedString()
        let stableUnderline = attributed.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        let correctedUnderline = attributed.attribute(.underlineStyle, at: 8, effectiveRange: nil) as? Int
        let correctedUnderlineColor = attributed.attribute(.underlineColor, at: 8, effectiveRange: nil) as? UIColor
        let correctedForeground = attributed.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? UIColor

        #expect(stableUnderline == nil)
        #expect(correctedUnderline == NSUnderlineStyle.single.rawValue)
        #expect(correctedUnderlineColor?.isEqual(UIColor.systemOrange) == true)
        #expect(correctedForeground?.isEqual(UIColor.label) == true)
    }
}
