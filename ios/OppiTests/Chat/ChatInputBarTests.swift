import SwiftUI
import Testing
@testable import Oppi

@Suite("ChatInputBar")
@MainActor
struct ChatInputBarTests {
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
}
