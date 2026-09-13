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

    @Test("Dictation focus expands composer action row")
    func dictationFocusExpandsActionRow() {
        #expect(ChatInputBar<EmptyView>.shouldShowComposerActionRow(
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

    @Test("Unfocused composer hides plus model and thinking pills")
    func unfocusedComposerHidesActionRowEvenWhenBusy() {
        #expect(!ChatInputBar<EmptyView>.shouldShowComposerActionRow(
            alwaysShowActionRow: false,
            isBusy: false,
            isInputFocused: false,
            isKeyboardSuppressed: false,
            hasAttachments: false,
            hasRepoPointers: false
        ))
        #expect(!ChatInputBar<EmptyView>.shouldShowComposerActionRow(
            alwaysShowActionRow: false,
            isBusy: true,
            isInputFocused: false,
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

    @Test("Mic permission failure is not disguised as cancellation")
    func microphoneDenialSurfacesStartErrorAndRestoresTyping() async {
        let systemAccess = MockVoiceInputSystemAccess()
        systemAccess.hasMicPermission = false
        systemAccess.requestMicPermissionResult = false
        let provider = MockVoiceProvider(id: .appleModernSpeech, engine: .modernSpeech)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: systemAccess
        )
        manager.setEngineMode(.onDevice)
        var prefix: String?
        var suppressed = false
        var focus = 0
        var haptics = 0
        await #expect(throws: VoiceInputError.self) {
            try await ComposerShared.startVoiceInput(
                manager: manager,
                keyboardLanguage: "en-US",
                owner: .inlineComposer,
                baseText: "draft",
                textBeforeRecording: Binding(get: { prefix }, set: { prefix = $0 }),
                suppressKeyboard: Binding(get: { suppressed }, set: { suppressed = $0 }),
                focusRequestID: Binding(get: { focus }, set: { focus = $0 }),
                playActivationHaptic: { haptics += 1 }
            )
        }
        #expect(haptics == 0)
        #expect(manager.state == .error("Microphone permission denied"))
        #expect(!manager._testOperationInFlight)
        #expect(prefix == nil)
        #expect(!suppressed)
        #expect(provider.prepareSessionCallCount == 0)
    }

    @Test("Dictation haptic fires once after capture succeeds, including recovery", arguments: [false, true])
    func dictationActivationHapticFollowsCapture(retryCapture: Bool) async throws {
        let access = MockVoiceInputSystemAccess()
        let provider = MockVoiceProvider(id: .appleModernSpeech, engine: .modernSpeech)
        let first = MockVoiceSession()
        let recovered = MockVoiceSession()
        var haptics = 0
        first.startHandler = { #expect(haptics == 0) }
        recovered.startHandler = { #expect(haptics == 0) }
        if retryCapture { first.startError = TestVoiceError("route changed") }
        var sessions = [first, recovered]
        provider.makeSessionHandler = { _, _ in sessions.removeFirst() }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        manager.setEngineMode(.onDevice)
        var suppressed = false
        var focus = 0
        try await ComposerShared.startVoiceInput(
            manager: manager, keyboardLanguage: "en-US", owner: .inlineComposer, baseText: "",
            suppressKeyboard: Binding(get: { suppressed }, set: { suppressed = $0 }),
            focusRequestID: Binding(get: { focus }, set: { focus = $0 }),
            prepare: { #expect(haptics == 0) },
            playActivationHaptic: {
                #expect(manager.isRecording)
                #expect(manager.isActiveRecordingSource(ComposerShared.VoiceInputOwner.inlineComposer.rawValue))
                haptics += 1
            }
        )
        #expect(haptics == 1)
        #expect(provider.makeSessionCallCount == (retryCapture ? 2 : 1))
        await manager.cancelRecording()
    }

    @Test("Cancelled dictation does not play an activation haptic")
    func cancelledDictationHasNoActivationHaptic() async {
        let access = MockVoiceInputSystemAccess()
        let provider = MockVoiceProvider(id: .appleModernSpeech, engine: .modernSpeech)
        let session = MockVoiceSession()
        session.startError = CancellationError()
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        manager.setEngineMode(.onDevice)
        var haptics = 0
        await #expect(throws: CancellationError.self) {
            try await ComposerShared.startVoiceInput(
                manager: manager, keyboardLanguage: "en-US", owner: .inlineComposer, baseText: "",
                suppressKeyboard: .constant(false), focusRequestID: .constant(0),
                playActivationHaptic: { haptics += 1 }
            )
        }
        #expect(haptics == 0)
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

    @Test("Send can commit dictation without restoring a suppressed keyboard")
    func finishOwnedVoiceInputBeforeSubmitCanKeepKeyboardSuppressed() async throws {
        AppPreferences.Voice.setEngineMode(.onDevice)
        defer { AppPreferences.Voice.setEngineMode(.remote) }

        let (manager, session) = try await makeRecordingVoiceInputManager(source: .inlineComposer)
        session.yieldEvent(.replaceFinalTranscript("rough draft"))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript.contains("rough") })

        session.stopHandler = { @MainActor [weak session] in
            session?.yieldEvent(.replaceFinalTranscript("final draft"))
            session?.finishEvents()
        }

        var text = "typed rough draft"
        var textBeforeRecording: String? = "typed "
        var suppressKeyboard = true
        let voiceStateBeforeFinish = manager.state

        let didFinish = await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
            manager: manager,
            owner: .inlineComposer,
            text: Binding(get: { text }, set: { text = $0 }),
            textBeforeRecording: Binding(get: { textBeforeRecording }, set: { textBeforeRecording = $0 }),
            suppressKeyboard: Binding(get: { suppressKeyboard }, set: { suppressKeyboard = $0 }),
            restoreKeyboard: false
        )

        #expect(didFinish)
        #expect(text == "typed final draft")
        #expect(textBeforeRecording == nil)
        #expect(suppressKeyboard)
        #expect(ChatInputBar<EmptyView>.suppressKeyboardAfterSend(
            voiceState: voiceStateBeforeFinish,
            wasSuppressed: true
        ))
        #expect(manager.currentTranscript.isEmpty)
    }

    @Test("Inline send finishes dictation without restoring the keyboard")
    func inlineSendFinishesDictationWithoutRestoringKeyboard() throws {
        let source = try chatInputBarSource()
        let slice = try chatInputBarSourceSlice(
            named: "private func handleSend() {",
            until: "private func submitCurrentComposerAction()",
            in: source
        )

        #expect(slice.contains("restoreKeyboard: false"))
        #expect(slice.contains("suppressKeyboardAfterSend("))
        #expect(!slice.contains("restoreKeyboard: true"))
    }

    @Test("Stashing a review comment plays the same success haptic as full-screen save")
    func reviewCommentSavePlaysSuccessHaptic() throws {
        let chatViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Oppi/Features/Chat/ChatView.swift")
        let chatView = try String(contentsOf: chatViewURL, encoding: .utf8)
        let saveSlice = try chatInputBarSourceSlice(
            named: "private func saveReviewComment(body: String, request: ReviewCommentSelectionRequest) -> Bool {",
            until: "private func deleteReviewComment(_ comment: ReviewComment) {",
            in: chatView
        )
        let presenterURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Oppi/Features/Chat/ReviewComments/ReviewCommentInlineDraftPresenter.swift")
        let presenter = try String(contentsOf: presenterURL, encoding: .utf8)
        let presenterSave = try chatInputBarSourceSlice(
            named: "private func saveCurrentBody() {",
            until: "private func updateSaveButton() {",
            in: presenter
        )

        #expect(saveSlice.contains("AppHaptics.success()"))
        #expect(!presenterSave.contains("AppHaptics.success()"))

        let hapticsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Oppi/Core/Services/AppHaptics.swift")
        let haptics = try String(contentsOf: hapticsURL, encoding: .utf8)
        let activation = try chatInputBarSourceSlice(
            named: "static func dictationActivated() {", until: "static func longPressThreshold() {", in: haptics
        )
        #expect(activation.contains("success()"), "Dictation must use the same feedback as comment saving")
        #expect(!activation.contains("impact(style:"))
        #expect(activation.contains("setAllowHapticsAndSystemSoundsDuringRecording(true)"))
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

    @Test("Expanded tap-to-type stops inline-started dictation")
    func expandedTapToTypeStopsInlineStartedDictation() async throws {
        AppPreferences.Voice.setEngineMode(.onDevice)
        defer { AppPreferences.Voice.setEngineMode(.remote) }

        let (manager, session) = try await makeRecordingVoiceInputManager(source: .inlineComposer)
        session.stopHandler = { @MainActor [weak session] in
            session?.finishEvents()
        }
        var textBeforeRecording: String? = "typed "
        var suppressKeyboard = true

        ComposerShared.handleKeyboardRestore(
            suppressKeyboard: Binding(get: { suppressKeyboard }, set: { suppressKeyboard = $0 }),
            textBeforeRecording: Binding(get: { textBeforeRecording }, set: { textBeforeRecording = $0 }),
            voiceInputManager: manager,
            expectedOwner: .expandedComposer
        )

        #expect(!suppressKeyboard)
        #expect(textBeforeRecording == nil)
        #expect(await waitForMainActorCondition { manager._testState == .idle })
        #expect(session.stopCallCount == 1)
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

    @Test("Inline dictation remains owned and controllable after expanding")
    func inlineDictationRemainsOwnedByExpandedComposer() {
        let manager = VoiceInputManager()
        manager._testState = .recording
        manager._testActiveRecordingSource = ComposerShared.VoiceInputOwner.inlineComposer.rawValue

        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .expandedComposer)

        #expect(ComposerShared.ownsVoiceInput(manager, owner: .expandedComposer))
        #expect(ComposerShared.canControlVoiceInput(manager, owner: .expandedComposer))
        #expect(ComposerShared.shouldSuppressKeyboardForActiveVoiceInput(manager, owner: .expandedComposer))
        #expect(presentation.isRecording)
        #expect(presentation.isEnabled)
        #expect(!presentation.isBlockedByOtherOwner)
    }

    @Test("Expanded dictation remains owned and controllable after collapsing")
    func expandedDictationRemainsOwnedByInlineComposer() {
        let manager = VoiceInputManager()
        manager._testState = .recording
        manager._testActiveRecordingSource = ComposerShared.VoiceInputOwner.expandedComposer.rawValue

        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .inlineComposer)

        #expect(ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer))
        #expect(ComposerShared.canControlVoiceInput(manager, owner: .inlineComposer))
        #expect(presentation.isRecording)
        #expect(presentation.isEnabled)
        #expect(!presentation.isBlockedByOtherOwner)
    }

    @Test("Inbox dictation remains owned by the message composer")
    func inboxDictationRemainsOwnedByInlineComposer() {
        let manager = VoiceInputManager()
        manager._testState = .recording
        manager._testActiveRecordingSource = ComposerShared.VoiceInputOwner.inboxComposer.rawValue

        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .inlineComposer)

        #expect(ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer))
        #expect(ComposerShared.ownsVoiceInput(manager, owner: .inboxComposer))
        #expect(ComposerShared.canControlVoiceInput(manager, owner: .inlineComposer))
        #expect(ComposerShared.shouldSuppressKeyboardForActiveVoiceInput(manager, owner: .inlineComposer))
        #expect(presentation.isRecording)
        #expect(presentation.isEnabled)
        #expect(!presentation.isBlockedByOtherOwner)
    }

    @Test("Review comment dictation remains isolated from message composers")
    func reviewCommentDictationStillBlocksMessageComposers() {
        let manager = VoiceInputManager()
        manager._testState = .recording
        manager._testActiveRecordingSource = ComposerShared.VoiceInputOwner.reviewCommentInline.rawValue

        #expect(!ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer))
        #expect(!ComposerShared.ownsVoiceInput(manager, owner: .expandedComposer))
        #expect(!ComposerShared.canControlVoiceInput(manager, owner: .inlineComposer))
        #expect(!ComposerShared.canControlVoiceInput(manager, owner: .expandedComposer))
    }

    @Test("Failed dictation start stays tappable so the mic can retry")
    func failedDictationStartStaysTappable() {
        let manager = VoiceInputManager()
        manager._testState = .error("NSError")
        manager._testActiveRecordingSource = nil

        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .inlineComposer)

        #expect(ComposerShared.micTapAction(for: manager.state) == .start)
        #expect(ComposerShared.canControlVoiceInput(manager, owner: .inlineComposer))
        #expect(presentation.isEnabled)
        #expect(!presentation.isBlockedByOtherOwner)
    }

    @Test("Preparing dictation shows listening chrome without a spinner or fake waveform")
    func preparingDictationShowsListeningChrome() {
        let manager = VoiceInputManager()
        manager._testState = .preparingModel
        manager._testActiveRecordingSource = ComposerShared.VoiceInputOwner.inlineComposer.rawValue

        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .inlineComposer)

        #expect(presentation.isPreparing)
        #expect(presentation.showsListeningChrome)
        #expect(!presentation.isRecording)
        #expect(!presentation.isProcessing)
        #expect(presentation.audioLevel == 0)
        #expect(presentation.accessibilityLabel == "Cancel voice input")
    }

    @Test("Dictation tap haptic fires before capture; activation haptic still waits for recording")
    func dictationTapHapticFiresBeforeCapture() async throws {
        let access = MockVoiceInputSystemAccess()
        let provider = MockVoiceProvider(id: .appleModernSpeech, engine: .modernSpeech)
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        manager.setEngineMode(.onDevice)
        var taps = 0
        var activations = 0
        var tapsBeforeStart = 0
        provider.makeSessionHandler = { _, _ in
            tapsBeforeStart = taps
            return MockVoiceSession()
        }
        try await ComposerShared.startVoiceInput(
            manager: manager, keyboardLanguage: "en-US", owner: .inlineComposer, baseText: "",
            suppressKeyboard: .constant(false), focusRequestID: .constant(0),
            playTapHaptic: { taps += 1 },
            playActivationHaptic: {
                #expect(manager.isRecording)
                activations += 1
            }
        )
        #expect(taps == 1)
        #expect(tapsBeforeStart == 1)
        #expect(activations == 1)
        await manager.cancelRecording()
    }

    @Test("Expanded composer mirrors live and settled inline transcript presentation")
    func expandedComposerMirrorsInlineTranscriptPresentation() async throws {
        AppPreferences.Voice.setEngineMode(.onDevice)
        defer { AppPreferences.Voice.setEngineMode(.remote) }

        let (manager, session) = try await makeRecordingVoiceInputManager(source: .inlineComposer)
        session.yieldEvent(.replaceFinalTranscript(
            "live words",
            committedText: "",
            activeText: "live words"
        ))
        #expect(await waitForMainActorCondition { manager.finalizedTranscript == "live words" })
        manager.typewriterAnimator.commitCurrentAnimation()

        #expect(ComposerShared.currentComposerText(
            storedText: "stale",
            textBeforeRecording: "Typed ",
            manager: manager,
            owner: .expandedComposer
        ) == "Typed live words")
        #expect(ComposerShared.volatileSuffixLength(
            manager: manager,
            owner: .expandedComposer
        ) == "live words".count)

        let liveRevision = manager.transcriptPresentationRevision
        session.yieldEvent(.replaceFinalTranscript(
            "live words",
            snap: true,
            committedText: "live words",
            activeText: ""
        ))
        #expect(await waitForMainActorCondition {
            manager.transcriptPresentationRevision == liveRevision + 1
        })
        #expect(ComposerShared.volatileSuffixLength(
            manager: manager,
            owner: .expandedComposer
        ) == 0)

        await manager.cancelRecording()
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

    @Test("Unfocused inline ask is a capped scrolling viewport, not an unbounded card")
    func unfocusedInlineAskIsCappedScrollingViewport() throws {
        let source = try chatInputBarSource()
        let capsule = try chatInputBarSourceSlice(
            named: "private var composerCapsule: some View {",
            until: "private func askCard(request: AskRequest) -> some View {",
            in: source
        )

        #expect(capsule.contains("ScrollView(.vertical, showsIndicators: true)"))
        #expect(capsule.contains("ExtensionNativeSurfaceLayout.expandedMaxHeight"))
        #expect(capsule.contains("ComposerInputMetrics.inlineAskCardMaxHeightWithKeyboard"))
        #expect(!capsule.contains("NativeSurfaceViewportScrollContainer"))
        #expect(capsule.components(separatedBy: "askCard(request: askRequest)").count - 1 == 1)
        #expect(ExtensionNativeSurfaceLayout.expandedMaxHeight == 260)
        #expect(ComposerInputMetrics.inlineAskCardMaxHeightWithKeyboard == 240)
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

    @Test("Composer capsule uses the live semantic themed panel contract")
    func composerCapsuleUsesLiveSemanticThemedPanel() throws {
        let source = try chatInputBarSource()
        let slice = try chatInputBarSourceSlice(
            named: "private var composerCapsule: some View {",
            until: "private func askCard",
            in: source
        )

        #expect(slice.contains(".themedSurface("))
        #expect(slice.contains(".elevatedPanel"))
        #expect(slice.contains("RoundedRectangle(cornerRadius: 20, style: .continuous)"))
        #expect(!slice.contains(".glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20"))
    }

    @Test("Photo picker presentation stays on stable composer roots")
    func photoPickerPresentationStaysOnStableComposerRoots() throws {
        let inlineSource = try chatInputBarSource()
        let inlineRoot = try chatInputBarSourceSlice(
            named: "var body: some View {",
            until: "// MARK: - Subviews",
            in: inlineSource
        )
        let inlineAttachButton = try chatInputBarSourceSlice(
            named: "private var attachButton: some View {",
            until: "private var busyModeSelector",
            in: inlineSource
        )

        let expandedSource = try expandedComposerSource()
        let expandedRoot = try chatInputBarSourceSlice(
            named: "var body: some View {",
            until: "// MARK: - Subviews",
            in: expandedSource
        )
        let expandedAttachMenu = try chatInputBarSourceSlice(
            named: "private var attachMenu: some View {",
            until: "// MARK: - Mic Button",
            in: expandedSource
        )

        #expect(inlineRoot.contains(".photosPicker("))
        #expect(!inlineAttachButton.contains(".photosPicker("))
        #expect(expandedRoot.contains(".photosPicker("))
        #expect(!expandedAttachMenu.contains(".photosPicker("))
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

    @Test("Staged review comments enable send with an empty composer")
    func stagedReviewCommentsEnableSendWithEmptyComposer() {
        #expect(ChatInputBar<EmptyView>.canSubmitMessage(
            allowsEmptySubmit: false,
            text: "   ",
            hasImages: false,
            hasFiles: false,
            hasReviewComments: true
        ))
    }

    @Test("Composer capsule no longer hosts the staged review comment bar")
    func composerCapsuleNoLongerHostsStagedReviewCommentBar() throws {
        let source = try chatInputBarSource()
        let capsule = try chatInputBarSourceSlice(
            named: "private var composerCapsule: some View {",
            until: "private func askCard(request: AskRequest) -> some View {",
            in: source
        )

        #expect(!capsule.contains("reviewCommentStashBar"))
        #expect(!capsule.contains("Text(\"Review\")"))
        #expect(!source.contains("private var reviewCommentStashBar"))
        #expect(!source.contains("onReviewCommentsTap"))
        #expect(!source.contains("static func reviewCommentStashTitle"))
        #expect(source.contains("pendingReviewCommentCount"))
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

        let submission = AskResponseSubmission()
        submission.submit(requestID: request.id) { $0(.completed) }
        submission.applyRequestIDChange(nil)
        let retainedID = submission.submittedRequestID
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
        let submission = AskResponseSubmission()
        submission.submit(requestID: request.id) { $0(.completed) }
        #expect(submission.submittedRequestID == request.id)
        #expect(ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: ["q1": .custom(submittedText)],
            keepComposerClearedForSubmittedRequestID: submission.submittedRequestID
        ) == "")

        submission.applyRequestIDChange(nil)
        let retainedID = submission.submittedRequestID
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
        let submission = AskResponseSubmission()
        if let current {
            submission.submit(requestID: current) { $0(.completed) }
        }
        submission.applyRequestIDChange(incoming)
        #expect(submission.submittedRequestID == expected)
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

        state.submission.submit(requestID: request.id) { $0(.completed) }
        let nextComposerText = ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: state.draftAnswers,
            keepComposerClearedForSubmittedRequestID: state.submittedRequestID
        )
        #expect(nextComposerText == "")
        #expect(state.submittedRequestID == request.id)

        state.applyRequestIDChange(nil)
        #expect(state.submittedRequestID == request.id)
        #expect(state.currentPage == 0)
        #expect(state.draftAnswers.isEmpty)
        #expect(nextComposerText == "")

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

@Suite("Ask submission wiring")
@MainActor
struct AskSubmissionWiringTests {
    @Test func repeatedSubmissionClaimsOnlyForwardOnceUntilADifferentRequestArrives() {
        var state = AskComposerClearingState()
        let request = AskRequest(
            id: "ask-final", sessionId: "session", questions: [], allowCustom: true, timeout: nil
        )
        var forwarded = 0
        for _ in 0..<3 {
            state.submission.submit(requestID: request.id) { _ in forwarded += 1 }
        }
        #expect(forwarded == 1)
        #expect(state.submittedRequestID == request.id)
        state.applyRequestIDChange(nil)
        state.submission.submit(requestID: request.id) { _ in forwarded += 1 }
        #expect(forwarded == 1, "Settlement must not rearm stale callbacks")

        let next = AskRequest(
            id: "ask-next", sessionId: "session", questions: [], allowCustom: true, timeout: nil
        )
        state.applyRequestIDChange(next.id)
        state.submission.submit(requestID: next.id) { _ in forwarded += 1 }
        state.submission.submit(requestID: next.id) { _ in forwarded += 1 }
        #expect(forwarded == 2)
    }

    @Test func inlineCallbacksRejectAlreadySubmittedRequestsBeforeForwarding() throws {
        let source = try chatInputBarSource()
        let card = try chatInputBarSourceSlice(
            named: "private func askCard(request: AskRequest)",
            until: "private var attachButton",
            in: source
        )
        #expect(card.components(separatedBy: "submitAskResponse(request: request, answers:").count - 1 == 2)
        let marker = try chatInputBarSourceSlice(
            named: "private func submitAskResponse(", until: "private func handleAlternateSend", in: source
        )
        #expect(marker.contains("guard askRequest?.id == request.id else"))
        #expect(marker.contains("askClearing.submission.submit(requestID: request.id"))
        #expect(marker.contains("Self.restoreFailedAskComposerText("))
        let delivery = try chatInputBarSourceSlice(
            named: "deliver: { complete in", until: "text = \"\"", in: marker
        )
        #expect(delivery.contains("submittedTextRevision = askClearing.textRevision"))
        let binding = try chatInputBarSourceSlice(
            named: "private var textFieldBinding:", until: "static func askComposerTextFieldBinding", in: source
        )
        #expect(binding.contains("Self.askComposerTextFieldBinding(text: $text, clearing: $askClearing)"))
    }

    @Test func finalPageSendIsDisabledAndSubmissionIsGuarded() throws {
        let source = try composerSource(named: "AskCard.swift")
        let footer = try chatInputBarSourceSlice(named: "private func questionFooter", until: "// MARK: - Page Indicator", in: source)
        #expect(footer.components(separatedBy: ".disabled(isAskSubmitted)").count - 1 == 2)
        for (start, end) in [("private func submitAnswers", "private func ignoreAll"),
                             ("private func ignoreAll", "private func recordResponseMetric")] {
            let action = try chatInputBarSourceSlice(named: start, until: end, in: source)
            #expect(action.contains("guard !isAskSubmitted else { return }"))
        }
    }
}

private func chatInputBarSource() throws -> String {
    try composerSource(named: "ChatInputBar.swift")
}

private func expandedComposerSource() throws -> String {
    try composerSource(named: "ExpandedComposerView.swift")
}

private func composerSource(named fileName: String) throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Oppi/Features/Chat/Composer/\(fileName)")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func chatInputBarSourceSlice(
    named marker: String,
    until endMarker: String,
    in source: String
) throws -> String {
    guard let start = source.range(of: marker) else {
        Issue.record("Missing source marker \(marker)")
        throw ChatInputBarSourceSliceError.missingMarker(marker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        Issue.record("Missing source end marker \(endMarker)")
        throw ChatInputBarSourceSliceError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum ChatInputBarSourceSliceError: Error {
    case missingMarker(String)
}

private final class DismissSpyImagePickerController: UIImagePickerController {
    private(set) var dismissCallCount = 0

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissCallCount += 1
        completion?()
    }
}
