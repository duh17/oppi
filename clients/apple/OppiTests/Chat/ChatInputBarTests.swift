import SwiftUI
import Testing
@testable import Oppi

@Suite("ChatInputBar")
@MainActor
struct ChatInputBarTests {
    @Test("Tap-to-type remains enabled while voice is active")
    func tapToTypeRemainsEnabledDuringVoiceStates() {
        #expect(ChatInputBar<EmptyView>.allowKeyboardRestoreOnTap(voiceState: .recording))
        #expect(ChatInputBar<EmptyView>.allowKeyboardRestoreOnTap(voiceState: .preparingModel))
        #expect(ChatInputBar<EmptyView>.allowKeyboardRestoreOnTap(voiceState: .processing))
    }

    @Test("Tap-to-type remains enabled while idle or after errors")
    func tapToTypeRemainsEnabledOutsideVoiceStates() {
        #expect(ChatInputBar<EmptyView>.allowKeyboardRestoreOnTap(voiceState: .idle))
        #expect(ChatInputBar<EmptyView>.allowKeyboardRestoreOnTap(voiceState: .error("boom")))
    }

    @Test("Send while recording keeps keyboard suppressed")
    func sendWhileRecordingKeepsSuppressed() {
        let suppressed = ChatInputBar<EmptyView>.suppressKeyboardAfterSend(
            voiceState: .recording,
            wasSuppressed: true
        )

        #expect(suppressed)
    }

    @Test("Send while preparing keeps keyboard suppressed")
    func sendWhilePreparingKeepsSuppressed() {
        let suppressed = ChatInputBar<EmptyView>.suppressKeyboardAfterSend(
            voiceState: .preparingModel,
            wasSuppressed: true
        )

        #expect(suppressed)
    }

    @Test("Non-voice states preserve existing suppression value")
    func nonVoiceStatesPreserveSuppression() {
        let idleSuppressed = ChatInputBar<EmptyView>.suppressKeyboardAfterSend(
            voiceState: .idle,
            wasSuppressed: true
        )
        let processingUnsuppressed = ChatInputBar<EmptyView>.suppressKeyboardAfterSend(
            voiceState: .processing,
            wasSuppressed: false
        )

        #expect(idleSuppressed)
        #expect(!processingUnsuppressed)
    }

    @Test("ComposerShared prefers live transcript over stale stored text during dictation")
    func currentComposerTextPrefersLiveTranscript() {
        let displayText = ComposerShared.currentComposerText(
            storedText: "Yep, I think we should allow.",
            textBeforeRecording: "",
            liveTranscript: "Yep, I think we should allow. Dictation without."
        )

        #expect(displayText == "Yep, I think we should allow. Dictation without.")
    }

    @Test("ComposerShared preserves typed prefix across composer handoff")
    func currentComposerTextPreservesTypedPrefixAcrossComposerHandoff() {
        let displayText = ComposerShared.currentComposerText(
            storedText: "stale snapshot",
            textBeforeRecording: "Already typed. ",
            liveTranscript: "When I expand to full screen, it should stay blue only at the end."
        )

        #expect(displayText == "Already typed. When I expand to full screen, it should stay blue only at the end.")
    }

    @Test("ComposerShared falls back to stored text when not dictating")
    func currentComposerTextFallsBackToStoredText() {
        let displayText = ComposerShared.currentComposerText(
            storedText: "existing typed text",
            textBeforeRecording: nil,
            liveTranscript: "should not be used"
        )

        #expect(displayText == "existing typed text")
    }

    @Test("Expand affordance reserves only a tight trailing gutter")
    func expandAffordanceUsesTightTrailingGutter() {
        #expect(ChatInputBar<EmptyView>.composerTextTrailingPadding(showsExpandButton: false) == 0)
        #expect(ChatInputBar<EmptyView>.composerTextTrailingPadding(showsExpandButton: true) == 10)
    }

    @Test("Expand affordance no longer reserves a full button width")
    func expandAffordanceDoesNotReserveFullButtonWidth() {
        let reserved = ChatInputBar<EmptyView>.composerTextTrailingPadding(showsExpandButton: true)
        #expect(reserved < 20, "Trailing gutter should stay visually tight so wrapped text reaches near the send button")
    }
}
