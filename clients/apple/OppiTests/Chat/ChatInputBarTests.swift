import Foundation
import SwiftUI
import Testing
import UIKit
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

    @Test("Suppressed dictation focus does not expand composer action row")
    func suppressedDictationFocusDoesNotExpandActionRow() {
        #expect(!ChatInputBar<EmptyView>.shouldShowComposerActionRow(
            alwaysShowActionRow: false,
            isBusy: false,
            isInputFocused: true,
            isKeyboardSuppressed: true,
            hasAttachments: false,
            hasRepoPointers: false
        ))
    }

    @Test("Visible keyboard focus expands composer action row")
    func visibleKeyboardFocusExpandsActionRow() {
        #expect(ChatInputBar<EmptyView>.shouldShowComposerActionRow(
            alwaysShowActionRow: false,
            isBusy: false,
            isInputFocused: true,
            isKeyboardSuppressed: false,
            hasAttachments: false,
            hasRepoPointers: false
        ))
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

    @Test("Voice input suppresses keyboard before async prepare work")
    func voiceInputSuppressesKeyboardBeforePrepareWork() async {
        enum PrepareError: Error {
            case failed
        }

        let manager = VoiceInputManager()
        var textBeforeRecording: String?
        var suppressKeyboard = false
        var focusRequestID = 0
        var observedSuppressKeyboard = false
        var observedTextBeforeRecording: String?
        var observedFocusRequestID = 0
        var didThrow = false

        do {
            _ = try await ComposerShared.startVoiceInput(
                manager: manager,
                keyboardLanguage: nil,
                owner: .inlineComposer,
                baseText: "hello",
                textBeforeRecording: Binding(
                    get: { textBeforeRecording },
                    set: { textBeforeRecording = $0 }
                ),
                suppressKeyboard: Binding(
                    get: { suppressKeyboard },
                    set: { suppressKeyboard = $0 }
                ),
                focusRequestID: Binding(
                    get: { focusRequestID },
                    set: { focusRequestID = $0 }
                ),
                prepare: {
                    observedSuppressKeyboard = suppressKeyboard
                    observedTextBeforeRecording = textBeforeRecording
                    observedFocusRequestID = focusRequestID
                    throw PrepareError.failed
                }
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(observedSuppressKeyboard)
        #expect(observedTextBeforeRecording == "hello ")
        #expect(observedFocusRequestID == 1)
        #expect(!suppressKeyboard)
        #expect(textBeforeRecording == nil)
    }

    @Test("ComposerShared commits final dictation text before submit")
    func finishOwnedVoiceInputBeforeSubmitCommitsFinalTranscript() async throws {
        AppPreferences.Voice.setEngineMode(.onDevice)
        defer { AppPreferences.Voice.setEngineMode(.remote) }

        let (manager, session) = try await makeRecordingVoiceInputManager(source: .expandedComposer)
        session.yieldEvent(.replaceFinalTranscript("rough draft"))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript.contains("rough") })

        session.stopHandler = { @MainActor [weak session] in
            session?.yieldEvent(.replaceFinalTranscript("final draft"))
            session?.finishEvents()
        }

        var text = "typed rough draft"
        var textBeforeRecording: String? = "typed "
        var suppressKeyboard = true

        let didFinish = await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
            manager: manager,
            owner: .expandedComposer,
            text: Binding(get: { text }, set: { text = $0 }),
            textBeforeRecording: Binding(get: { textBeforeRecording }, set: { textBeforeRecording = $0 }),
            suppressKeyboard: Binding(get: { suppressKeyboard }, set: { suppressKeyboard = $0 })
        )

        #expect(didFinish)
        #expect(text == "typed final draft")
        #expect(textBeforeRecording == nil)
        #expect(!suppressKeyboard)
        #expect(manager.currentTranscript.isEmpty)
    }

    @Test("ComposerShared cancels owned dictation without committing transcript")
    func cancelOwnedVoiceInputClearsRecordingStateWithoutCommittingTranscript() async throws {
        AppPreferences.Voice.setEngineMode(.onDevice)
        defer { AppPreferences.Voice.setEngineMode(.remote) }

        let (manager, session) = try await makeRecordingVoiceInputManager(source: .inlineComposer)
        session.yieldEvent(.replaceFinalTranscript("dictated text"))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript.contains("dictated") })

        var text = "typed value"
        var textBeforeRecording: String? = "typed "
        var suppressKeyboard = true

        let didCancel = await ComposerShared.cancelOwnedVoiceInput(
            manager: manager,
            owner: .inlineComposer,
            textBeforeRecording: Binding(get: { textBeforeRecording }, set: { textBeforeRecording = $0 }),
            suppressKeyboard: Binding(get: { suppressKeyboard }, set: { suppressKeyboard = $0 })
        )

        #expect(didCancel)
        #expect(text == "typed value")
        #expect(textBeforeRecording == nil)
        #expect(!suppressKeyboard)
        #expect(manager._testState == .idle)
        #expect(session.cancelCallCount == 1)
    }

    @Test("Feature UI code routes voice lifecycle through ComposerShared")
    func featureUICodeRoutesVoiceLifecycleThroughComposerShared() throws {
        let appleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scannedRoots = [
            appleRoot.appending(path: "Oppi/App"),
            appleRoot.appending(path: "Oppi/Features"),
        ]
        let allowedDirectCallFiles: Set<String> = [
            "Oppi/Features/Chat/Composer/ComposerShared.swift",
        ]
        let bannedCalls = [".stopRecording(", ".cancelRecording("]
        let rootPath = appleRoot.standardizedFileURL.path
        var violations: [String] = []

        for root in scannedRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let standardized = fileURL.standardizedFileURL
                let fullPath = standardized.path
                let relativePath = if fullPath.hasPrefix(rootPath + "/") {
                    String(fullPath.dropFirst(rootPath.count + 1))
                } else {
                    fullPath
                }
                guard !allowedDirectCallFiles.contains(relativePath) else { continue }

                let contents = try String(contentsOf: standardized, encoding: .utf8)
                for bannedCall in bannedCalls where contents.contains(bannedCall) {
                    violations.append("\(relativePath) uses \(bannedCall)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "UI code must use ComposerShared.finishOwnedVoiceInputBeforeSubmit/cancelOwnedVoiceInput: \(violations.joined(separator: ", "))"
        )
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

    @Test("Shared input growth caps at configured max lines")
    func sharedInputGrowthCapsAtConfiguredMaxLines() {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        textView.text = (0..<20).map { "line \($0)" }.joined(separator: "\n")

        let growth = ComposerInputMetrics.textViewGrowth(
            for: textView,
            fittingWidth: 220,
            maxLines: ComposerInputMetrics.inlineMaxLines
        )
        let expectedMax = ComposerInputMetrics.maxTextHeight(
            font: textView.font ?? .preferredFont(forTextStyle: .body),
            textContainerInset: textView.textContainerInset,
            maxLines: ComposerInputMetrics.inlineMaxLines
        )

        #expect(growth.height == expectedMax)
        #expect(growth.isScrollEnabled)
    }

    @Test("Ask request constrains inline input height")
    func askRequestConstrainsInlineInputHeight() {
        let maxLines = ChatInputBar<EmptyView>.inlineTextMaxLines(
            hasAskRequest: true,
            hasAttachments: false,
            hasRepoPointers: false
        )

        #expect(maxLines == ComposerInputMetrics.inlineMaxLinesWithAttachments)
        #expect(maxLines < ComposerInputMetrics.inlineMaxLines)
    }

    @Test("Plain composer keeps the full inline input height")
    func plainComposerKeepsFullInlineInputHeight() {
        let maxLines = ChatInputBar<EmptyView>.inlineTextMaxLines(
            hasAskRequest: false,
            hasAttachments: false,
            hasRepoPointers: false
        )

        #expect(maxLines == ComposerInputMetrics.inlineMaxLines)
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

    @Test("Active asks can disable expanded composer routing")
    func activeAsksCanDisableExpandedComposerRouting() {
        #expect(!ChatInputBar<EmptyView>.shouldShowExpandButton(
            allowsExpansion: false,
            visualLineCount: 8,
            threshold: 5,
            maxLines: 10
        ))
        #expect(ChatInputBar<EmptyView>.shouldShowExpandButton(
            allowsExpansion: true,
            visualLineCount: 5,
            threshold: 5,
            maxLines: 10
        ))
    }

    @Test("Empty submit is opt-in")
    func emptySubmitIsOptIn() {
        #expect(!ChatInputBar<EmptyView>.canSubmitMessage(
            allowsEmptySubmit: false,
            text: "   ",
            hasImages: false,
            hasFiles: false,
            hasReviewComments: false
        ))
        #expect(ChatInputBar<EmptyView>.canSubmitMessage(
            allowsEmptySubmit: true,
            text: "   ",
            hasImages: false,
            hasFiles: false,
            hasReviewComments: false
        ))
    }

    @Test("Non-empty submit stays enabled")
    func nonEmptySubmitStaysEnabled() {
        #expect(ChatInputBar<EmptyView>.canSubmitMessage(
            allowsEmptySubmit: false,
            text: "hello",
            hasImages: false,
            hasFiles: false,
            hasReviewComments: false
        ))
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

    @Test("Ask without custom input prompts a decision instead of steering")
    func askWithoutCustomInputPromptsDecisionInsteadOfSteering() {
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

        #expect(placeholder == "Choose an option…")
    }

    @Test("Multi-select ask placeholder says to select options")
    func multiSelectAskPlaceholderSaysToSelectOptions() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Pick ready items", options: [], multiSelect: true)],
            allowCustom: true,
            timeout: nil
        )

        let placeholder = ChatInputBar<EmptyView>.composerPlaceholder(
            askRequest: request,
            pendingReviewCommentCount: 0,
            isBusy: true,
            busyStreamingBehavior: .steer
        )

        #expect(placeholder == "Select options or type…")
    }

    @Test("Multi-select ask without custom input keeps option wording")
    func multiSelectAskWithoutCustomInputKeepsOptionWording() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Pick ready items", options: [], multiSelect: true)],
            allowCustom: false,
            timeout: nil
        )

        let placeholder = ChatInputBar<EmptyView>.composerPlaceholder(
            askRequest: request,
            pendingReviewCommentCount: 0,
            isBusy: true,
            busyStreamingBehavior: .steer
        )

        #expect(placeholder == "Select options…")
    }

    @Test("Review comment placeholder includes staged count")
    func reviewCommentPlaceholderIncludesStagedCount() {
        let singular = ChatInputBar<EmptyView>.composerPlaceholder(
            askRequest: nil,
            pendingReviewCommentCount: 1,
            isBusy: false,
            busyStreamingBehavior: .steer
        )
        let plural = ChatInputBar<EmptyView>.composerPlaceholder(
            askRequest: nil,
            pendingReviewCommentCount: 3,
            isBusy: false,
            busyStreamingBehavior: .steer
        )

        #expect(singular == "Send 1 review comment…")
        #expect(plural == "Send 3 review comments…")
    }

    @Test("Review comment stash title includes staged count")
    func reviewCommentStashTitleIncludesStagedCount() {
        #expect(ChatInputBar<EmptyView>.reviewCommentStashTitle(count: 1) == "1 review comment staged")
        #expect(ChatInputBar<EmptyView>.reviewCommentStashTitle(count: 2) == "2 review comments staged")
    }

    @Test("Busy ask with no custom answer uses ignore instead of stop")
    func busyAskWithoutAnswerUsesIgnoreInsteadOfStop() {
        let action = ChatInputBar<EmptyView>.primaryActionKind(
            isBusy: true,
            canSend: false,
            isSending: false,
            hasAskRequest: true
        )

        #expect(action == .ignoreAsk)
    }

    @Test("Busy session without ask still uses stop")
    func busySessionWithoutAskStillUsesStop() {
        let action = ChatInputBar<EmptyView>.primaryActionKind(
            isBusy: true,
            canSend: false,
            isSending: false,
            hasAskRequest: false
        )

        #expect(action == .stop)
    }

    @Test("Custom ask answer keeps send as the primary action")
    func customAskAnswerKeepsSendPrimaryAction() {
        let action = ChatInputBar<EmptyView>.primaryActionKind(
            isBusy: true,
            canSend: true,
            isSending: false,
            hasAskRequest: true
        )

        #expect(action == .send)
    }

    @Test("Ask hides the busy steering mode selector")
    func askHidesBusyModeSelector() {
        #expect(!ChatInputBar<EmptyView>.showsBusyModeSelector(isBusy: true, hasAskRequest: true))
        #expect(ChatInputBar<EmptyView>.showsBusyModeSelector(isBusy: true, hasAskRequest: false))
        #expect(!ChatInputBar<EmptyView>.showsBusyModeSelector(isBusy: false, hasAskRequest: false))
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

    @Test("Ask composer send transition submits selected option on final page")
    func askComposerSendTransitionSubmitsSelectedFinalOption() throws {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [
                AskQuestion(id: "q1", question: "First?", options: [AskOption(value: "a", label: "A")], multiSelect: false),
                AskQuestion(id: "q2", question: "Second?", options: [AskOption(value: "b", label: "B")], multiSelect: false)
            ],
            allowCustom: false,
            timeout: nil
        )

        let transition = try #require(ChatInputBar<EmptyView>.askComposerSendTransition(
            request: request,
            currentPage: 1,
            draftAnswers: [
                "q1": .single("a"),
                "q2": .single("b")
            ],
            text: ""
        ))

        #expect(transition.nextPage == 1)
        #expect(transition.shouldSubmit)
        #expect(transition.answers == [
            "q1": .single("a"),
            "q2": .single("b")
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

    @Test("Settled ask does not provide replacement composer text")
    func settledAskDoesNotReplaceRestoredMessageDraft() {
        let displayedText = ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: nil,
            activeQuestionID: nil,
            draftAnswers: [:],
            keepComposerClearedForSubmittedRequestID: nil
        )

        #expect(displayedText == nil)
    }

    @Test("Submitted custom ask keeps the composer cleared until the request changes")
    func submittedCustomAskKeepsComposerCleared() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Why?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )

        let draftAnswers: [String: AskAnswer] = ["q1": .custom("because the larger tables should download")]
        let displayedText = ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: draftAnswers,
            keepComposerClearedForSubmittedRequestID: "ask-1"
        )

        #expect(displayedText == "")
    }

    @Test("Submitted custom ask stays cleared after the server drops the pending request")
    func submittedCustomAskStaysClearedAfterPendingRequestIsCleared() throws {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Why?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let submittedText = "because the larger tables should download"
        let transition = try #require(ChatInputBar<EmptyView>.askComposerSendTransition(
            request: request,
            currentPage: 0,
            draftAnswers: [:],
            text: submittedText
        ))

        #expect(transition.shouldSubmit)
        #expect(transition.nextComposerText.isEmpty)

        let whileVisible = ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: transition.answers,
            keepComposerClearedForSubmittedRequestID: request.id
        )
        #expect(whileVisible == "")

        let retainedID = ChatInputBar<EmptyView>.retainedSubmittedAskRequestID(
            current: request.id,
            incomingRequestID: nil
        )
        #expect(retainedID == request.id)

        let afterServerCleared = ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: nil,
            activeQuestionID: "q1",
            draftAnswers: transition.answers,
            keepComposerClearedForSubmittedRequestID: retainedID
        )
        #expect(afterServerCleared != submittedText)
        #expect(afterServerCleared != "because the larger tables should download")
    }

    @Test("Ask submit clearance empties composer and keeps the submitted mark after settle")
    func askSubmitClearanceEmptiesComposerAndRetainsSubmittedMark() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Why?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let submittedText = "typed custom answer"
        let clearance = ChatInputBar<EmptyView>.askComposerSubmitClearance(request: request)

        #expect(clearance.nextComposerText.isEmpty)
        #expect(clearance.submittedRequestID == request.id)

        let retainedID = ChatInputBar<EmptyView>.retainedSubmittedAskRequestID(
            current: clearance.submittedRequestID,
            incomingRequestID: nil
        )
        #expect(retainedID == request.id)

        let replacement = ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: nil,
            activeQuestionID: "q1",
            draftAnswers: ["q1": .custom(submittedText)],
            keepComposerClearedForSubmittedRequestID: retainedID
        )
        #expect(replacement != submittedText)
    }

    @Test(arguments: [
        (current: String?.some("ask-1"), incoming: String?.none, expected: String?.some("ask-1")),
        (current: String?.some("ask-1"), incoming: String?.some("ask-1"), expected: String?.some("ask-1")),
        (current: String?.some("ask-1"), incoming: String?.some("ask-2"), expected: String?.none),
        (current: String?.none, incoming: String?.some("ask-2"), expected: String?.none),
        (current: String?.none, incoming: String?.none, expected: String?.none),
    ])
    func submittedAskMarkSurvivesUntilADifferentAskArrives(
        current: String?,
        incoming: String?,
        expected: String?
    ) {
        #expect(
            ChatInputBar<EmptyView>.retainedSubmittedAskRequestID(
                current: current,
                incomingRequestID: incoming
            ) == expected
        )
    }

    @Test("Ask composer clearing state retains the submitted mark until a different ask arrives")
    func askComposerClearingStateRetainsSubmittedMarkUntilDifferentAsk() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Why?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let submittedText = "because the larger tables should download"
        var state = AskComposerClearingState(
            currentPage: 1,
            draftAnswers: ["q1": .custom(submittedText)]
        )

        let nextComposerText = state.markSubmitted(request: request)
        #expect(nextComposerText.isEmpty)
        #expect(state.submittedRequestID == request.id)

        state.applyRequestIDChange(nil)
        #expect(state.submittedRequestID == request.id)
        #expect(state.currentPage == 0)
        #expect(state.draftAnswers.isEmpty)
        #expect(nextComposerText.isEmpty)

        let afterRequestCleared = ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: nil,
            activeQuestionID: "q1",
            draftAnswers: state.draftAnswers,
            keepComposerClearedForSubmittedRequestID: state.submittedRequestID
        )
        #expect(afterRequestCleared != submittedText)

        state.applyRequestIDChange("ask-2")
        #expect(state.submittedRequestID == nil)
    }

    @Test("Unsubmitted custom ask restores the stored text for the active page")
    func unsubmittedCustomAskRestoresStoredText() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Why?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )

        let draftAnswers: [String: AskAnswer] = ["q1": .custom("because the larger tables should download")]
        let displayedText = ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: draftAnswers,
            keepComposerClearedForSubmittedRequestID: nil
        )

        #expect(displayedText == "because the larger tables should download")
    }

    @Test("Camera capture lets SwiftUI cover own dismissal")
    func cameraCaptureDoesNotSelfDismissPresenter() {
        let picker = DismissSpyImagePickerController()
        let image = makeTinyImage()
        var capturedImage: UIImage?
        var didCancel = false

        let coordinator = CameraPicker.Coordinator(
            onCapture: { capturedImage = $0 },
            onCancel: { didCancel = true }
        )

        coordinator.imagePickerController(
            picker,
            didFinishPickingMediaWithInfo: [.originalImage: image]
        )

        #expect(capturedImage === image)
        #expect(!didCancel)
        #expect(
            picker.dismissCallCount == 0,
            "CameraPicker must let composerCameraCover's binding dismiss only the camera cover; UIKit self-dismiss can also close the parent quick-session sheet."
        )
    }

    @Test("Camera cancel lets SwiftUI cover own dismissal")
    func cameraCancelDoesNotSelfDismissPresenter() {
        let picker = DismissSpyImagePickerController()
        var didCapture = false
        var didCancel = false

        let coordinator = CameraPicker.Coordinator(
            onCapture: { _ in didCapture = true },
            onCancel: { didCancel = true }
        )

        coordinator.imagePickerControllerDidCancel(picker)

        #expect(!didCapture)
        #expect(didCancel)
        #expect(
            picker.dismissCallCount == 0,
            "CameraPicker must let composerCameraCover's binding dismiss only the camera cover; UIKit self-dismiss can also close the parent quick-session sheet."
        )
    }

    private func makeTinyImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private func makeRecordingVoiceInputManager(
        source: ComposerShared.VoiceInputOwner
    ) async throws -> (VoiceInputManager, MockVoiceSession) {
        let systemAccess = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in session }

        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: systemAccess
        )
        try await manager.startRecording(keyboardLanguage: "en-US", source: source.rawValue)
        return (manager, session)
    }
}

private final class DismissSpyImagePickerController: UIImagePickerController {
    private(set) var dismissCallCount = 0

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissCallCount += 1
        completion?()
    }
}
