import Testing
@testable import Oppi

@Suite("AudioTimelinePresentationAdapter")
struct AudioTimelinePresentationAdapterTests {
    @Test func streamingTranscriptMapsToCompactVoiceMessage() throws {
        let content = AudioTimelinePresentationAdapter.expandedContent(
            from: .streamingTranscript(text: "Projected transcript", playbackBehavior: .playNow),
            fallback: .text(text: "raw fallback", language: nil)
        )

        guard case .audioMessage(let text, let attachmentId, let mimeType, _, let playbackBehavior) = content else {
            Issue.record("Expected projected voice message content")
            return
        }
        #expect(text == "Projected transcript")
        #expect(attachmentId == "")
        #expect(mimeType == "audio/wav")
        #expect(playbackBehavior == .playNow)
    }

    @Test func finalCardMapsToReplayableVoiceMessage() throws {
        let content = AudioTimelinePresentationAdapter.expandedContent(
            from: .finalCard(transcript: "new", attachmentID: "new-att", replayState: .idle),
            fallback: .audioMessage(
                text: "old",
                attachmentId: "old-att",
                mimeType: "audio/wav",
                durationSeconds: nil,
                playbackBehavior: .tapToPlay
            )
        )

        guard case .audioMessage(let text, let attachmentId, _, _, _) = content else {
            Issue.record("Expected projected final voice card")
            return
        }
        #expect(text == "new")
        #expect(attachmentId == "new-att")
    }

    @Test func hiddenPresentationKeepsFallback() throws {
        let content = AudioTimelinePresentationAdapter.expandedContent(
            from: .hidden,
            fallback: .text(text: "fallback", language: nil)
        )

        guard case .text(let text, _) = content else {
            Issue.record("Expected fallback text content")
            return
        }
        #expect(text == "fallback")
    }

    @Test func errorPresentationMapsToStatus() throws {
        let content = AudioTimelinePresentationAdapter.expandedContent(
            from: .error(message: "Playback failed"),
            fallback: nil
        )

        guard case .status(let message) = content else {
            Issue.record("Expected status content")
            return
        }
        #expect(message == "Playback failed")
    }
}
