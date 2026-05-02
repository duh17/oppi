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

    @Test("Ask with custom input updates the composer placeholder")
    func askWithCustomInputUpdatesComposerPlaceholder() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "What context?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )

        let placeholder = ChatInputBar<EmptyView>.composerPlaceholder(
            askRequest: request,
            pendingReviewCommentCount: 0,
            isBusy: true,
            busyStreamingBehavior: .steer
        )

        #expect(placeholder == "Type answer…")
    }

    @Test("Ask without custom input keeps busy placeholder behavior")
    func askWithoutCustomInputKeepsBusyPlaceholderBehavior() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Pick one", options: [], multiSelect: false)],
            allowCustom: false,
            timeout: nil
        )

        let placeholder = ChatInputBar<EmptyView>.composerPlaceholder(
            askRequest: request,
            pendingReviewCommentCount: 0,
            isBusy: true,
            busyStreamingBehavior: .steer
        )

        #expect(placeholder == "Steer agent…")
    }

    @Test("Composer text answers ask instead of becoming steering or follow-up")
    func composerTextBuildsCustomAskAnswer() throws {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "What context?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )

        let answers = try #require(ChatInputBar<EmptyView>.customAskAnswers(request: request, text: "  we already got this from pi  "))
        #expect(answers == ["q1": .custom("we already got this from pi")])
    }

    @Test("Composer text falls through to normal send when no ask is active")
    func composerTextFallsThroughWithoutAsk() {
        #expect(ChatInputBar<EmptyView>.customAskAnswers(request: nil, text: "steer the agent") == nil)
    }

    @Test("Composer text does not answer asks that disallow custom input")
    func composerTextIgnoresAskWithoutCustomInput() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Pick", options: [], multiSelect: false)],
            allowCustom: false,
            timeout: nil
        )

        #expect(ChatInputBar<EmptyView>.customAskAnswers(request: request, text: "custom") == nil)
        #expect(ChatInputBar<EmptyView>.customAskAnswers(request: request, text: "   ") == nil)
    }

    @Test("Composer text answers the active page in a multi-question ask")
    func composerTextAnswersActiveMultiQuestionPage() throws {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [
                AskQuestion(id: "q1", question: "First?", options: [], multiSelect: false),
                AskQuestion(id: "q2", question: "Second?", options: [], multiSelect: false)
            ],
            allowCustom: true,
            timeout: nil
        )

        let answers = try #require(ChatInputBar<EmptyView>.customAskAnswers(
            request: request,
            activeQuestionID: "q2",
            draftAnswers: ["q1": .single("a")],
            text: "  answer the visible page  "
        ))

        #expect(answers == [
            "q1": .single("a"),
            "q2": .custom("answer the visible page")
        ])
    }

    @Test("Custom ask send advances instead of submitting on non-final page")
    func customAskSendAdvancesOnNonFinalPage() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [
                AskQuestion(id: "q1", question: "First?", options: [], multiSelect: false),
                AskQuestion(id: "q2", question: "Second?", options: [], multiSelect: false)
            ],
            allowCustom: true,
            timeout: nil
        )

        #expect(!ChatInputBar<EmptyView>.shouldSubmitAskResponseImmediately(request: request, currentPage: 0))
        #expect(ChatInputBar<EmptyView>.shouldSubmitAskResponseImmediately(request: request, currentPage: 1))
    }

    @Test("Ask composer send transition advances and keeps prior answers")
    func askComposerSendTransitionAdvancesAndKeepsPriorAnswers() throws {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [
                AskQuestion(id: "q1", question: "First?", options: [], multiSelect: false),
                AskQuestion(id: "q2", question: "Second?", options: [], multiSelect: false)
            ],
            allowCustom: true,
            timeout: nil
        )

        let transition = try #require(ChatInputBar<EmptyView>.askComposerSendTransition(
            request: request,
            currentPage: 0,
            draftAnswers: ["q2": .custom("saved second")],
            text: " first custom answer "
        ))

        #expect(transition.nextPage == 1)
        #expect(!transition.shouldSubmit)
        #expect(transition.answers == [
            "q1": .custom("first custom answer"),
            "q2": .custom("saved second")
        ])
        #expect(transition.nextComposerText == "saved second")
    }

    @Test("Ask composer send transition submits on final page")
    func askComposerSendTransitionSubmitsOnFinalPage() throws {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [
                AskQuestion(id: "q1", question: "First?", options: [], multiSelect: false),
                AskQuestion(id: "q2", question: "Second?", options: [], multiSelect: false)
            ],
            allowCustom: true,
            timeout: nil
        )

        let transition = try #require(ChatInputBar<EmptyView>.askComposerSendTransition(
            request: request,
            currentPage: 1,
            draftAnswers: ["q1": .single("picked")],
            text: " second custom answer "
        ))

        #expect(transition.nextPage == 1)
        #expect(transition.shouldSubmit)
        #expect(transition.answers == [
            "q1": .single("picked"),
            "q2": .custom("second custom answer")
        ])
        #expect(transition.nextComposerText.isEmpty)
    }

    @Test("Stored custom ask text can be restored when revisiting a page")
    func storedCustomAskTextRestoresForPage() {
        let answers: [String: AskAnswer] = [
            "q1": .custom("saved first answer"),
            "q2": .single("picked option")
        ]

        #expect(ChatInputBar<EmptyView>.customAskText(answers: answers, questionID: "q1") == "saved first answer")
        #expect(ChatInputBar<EmptyView>.customAskText(answers: answers, questionID: "q2") == "")
        #expect(ChatInputBar<EmptyView>.customAskText(answers: answers, questionID: nil) == "")
    }
}
