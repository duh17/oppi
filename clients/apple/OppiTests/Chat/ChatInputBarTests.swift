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
        #expect(ChatInputBar.allowKeyboardRestoreOnTap(voiceState: .recording))
        #expect(ChatInputBar.allowKeyboardRestoreOnTap(voiceState: .preparingModel))
        #expect(ChatInputBar.allowKeyboardRestoreOnTap(voiceState: .processing))
    }

    @Test("Tap-to-type remains enabled while idle or after errors")
    func tapToTypeRemainsEnabledOutsideVoiceStates() {
        #expect(ChatInputBar.allowKeyboardRestoreOnTap(voiceState: .idle))
        #expect(ChatInputBar.allowKeyboardRestoreOnTap(voiceState: .error("boom")))
    }

    @Test("Dictation focus expands composer action row")
    func dictationFocusExpandsActionRow() {
        #expect(ChatInputBar.shouldShowComposerActionRow(
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
        #expect(ChatInputBar.shouldShowComposerActionRow(
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
        #expect(!ChatInputBar.shouldShowComposerActionRow(
            alwaysShowActionRow: false,
            isBusy: false,
            isInputFocused: false,
            isKeyboardSuppressed: false,
            hasAttachments: false,
            hasRepoPointers: false
        ))
        #expect(!ChatInputBar.shouldShowComposerActionRow(
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
        let suppressed = ChatInputBar.suppressKeyboardAfterSend(
            voiceState: .recording,
            wasSuppressed: true
        )

        #expect(suppressed)
    }

    @Test("Send while preparing keeps keyboard suppressed")
    func sendWhilePreparingKeepsSuppressed() {
        let suppressed = ChatInputBar.suppressKeyboardAfterSend(
            voiceState: .preparingModel,
            wasSuppressed: true
        )

        #expect(suppressed)
    }

    @Test("Non-voice states preserve existing suppression value")
    func nonVoiceStatesPreserveSuppression() {
        let idleSuppressed = ChatInputBar.suppressKeyboardAfterSend(
            voiceState: .idle,
            wasSuppressed: true
        )
        let processingUnsuppressed = ChatInputBar.suppressKeyboardAfterSend(
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
        #expect(ChatInputBar.suppressKeyboardAfterSend(
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
        let finish = try chatInputBarSourceSlice(
            named: "func finishVoiceBeforeSubmit() async {",
            until: "func handlePastedImages(",
            in: source
        )

        #expect(slice.contains("finishVoiceBeforeSubmit()"))
        #expect(slice.contains("suppressKeyboardAfterSend("))
        #expect(finish.contains("restoreKeyboard: false"))
        #expect(!finish.contains("restoreKeyboard: true"))
        #expect(!slice.contains("restoreKeyboard: true"))
    }

    @Test("External dictation still starts from task(id:) once per request")
    func externalDictationStartsFromTaskIdentifier() throws {
        let source = try chatInputBarSource()
        #expect(source.contains(".task(id: externalDictationRequestID)"))
        let task = try chatInputBarSourceSlice(
            named: ".task(id: externalDictationRequestID) {",
            until: ".alert(\"Couldn't Start Dictation\"",
            in: source
        )
        #expect(task.contains("await startExternalDictationIfRequested()"))
        #expect(!task.contains("layoutRevision"))
    }

    @Test("Dictation failure Retry starts voice input")
    func dictationFailureRetryStartsVoiceInput() throws {
        let source = try chatInputBarSource()
        let retry = try chatInputBarSourceSlice(
            named: "Button(\"Retry dictation\") {",
            until: "ChatInputBarHost(",
            in: source
        )
        #expect(retry.contains("startOwnedVoiceInput(owner: .inlineComposer)"))
        let start = try chatInputBarSourceSlice(
            named: "private func startOwnedVoiceInput(owner: ComposerShared.VoiceInputOwner) async {",
            until: "static func askComposerTextFieldBinding(",
            in: source
        )
        #expect(start.contains("ComposerShared.startVoiceInput("))
        #expect(start.contains("owner: owner"))
        #expect(!start.contains("layoutRevision"))
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
            named: "static func dictationActivated() {", until: "static func selectionChanged() {", in: haptics
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
        #expect(presentation.voiceSpectrum == .zero)
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
        let maxLines = ChatInputBar.inlineTextMaxLines(
            hasAskRequest: true,
            hasAttachments: false,
            hasRepoPointers: false
        )

        #expect(maxLines == ComposerInputMetrics.inlineMaxLinesWithAttachments)
        #expect(maxLines < ComposerInputMetrics.inlineMaxLines)
    }

    @Test("Plain composer keeps the full inline input height")
    func plainComposerKeepsFullInlineInputHeight() {
        let maxLines = ChatInputBar.inlineTextMaxLines(
            hasAskRequest: false,
            hasAttachments: false,
            hasRepoPointers: false
        )

        #expect(maxLines == ComposerInputMetrics.inlineMaxLines)
    }

    @Test("Unfocused inline ask is a capped scrolling viewport, not an unbounded card")
    func unfocusedInlineAskIsCappedScrollingViewport() throws {
        let source = try chatInputBarSource()
        let cap = try chatInputBarSourceSlice(
            named: "private func applyAskViewport() {",
            until: "private func applyActionPills",
            in: source
        )

        #expect(cap.contains("ComposerInputMetrics.inlineAskCardMaxHeightWithKeyboard"))
        #expect(cap.contains("ExtensionNativeSurfaceLayout.expandedMaxHeight"))
        #expect(cap.contains("askScroll.isScrollEnabled"))
        #expect(source.contains("private let askScroll = UIScrollView()"))
        #expect(!source.contains("NativeSurfaceViewportScrollContainer"))
        #expect(ExtensionNativeSurfaceLayout.expandedMaxHeight == 260)
        #expect(ComposerInputMetrics.inlineAskCardMaxHeightWithKeyboard == 240)
        #expect(cap.contains("if slotChanged"))
        #expect(cap.contains("view.invalidateIntrinsicContentSize()"))
    }

    @Test("Composer apply does not layout the hosted Ask card")
    func composerApplyDoesNotLayoutHostedAskCard() throws {
        let controller = try composerSource(named: "ComposerBarController.swift")
        #expect(!controller.contains("capsuleStack.layoutIfNeeded()"))
        let visibility = try chatInputBarSourceSlice(
            named: "private func applyActionRowVisibility",
            until: "private func applyAskViewport",
            in: controller
        )
        #expect(visibility.contains("self.actionRowStack.layoutIfNeeded()"))
        #expect(!visibility.contains("capsuleStack.layoutIfNeeded()"))
        let layoutCalls = controller.components(separatedBy: "layoutIfNeeded()").count - 1
        #expect(layoutCalls == 1)
    }

    @Test("Expand affordance reserves only a tight trailing gutter")
    func expandAffordanceUsesTightTrailingGutter() {
        #expect(ChatInputBar.composerTextTrailingPadding(showsExpandButton: false) == 0)
        #expect(ChatInputBar.composerTextTrailingPadding(showsExpandButton: true) == 10)
    }

    @Test("Expand affordance no longer reserves a full button width")
    func expandAffordanceDoesNotReserveFullButtonWidth() {
        let reserved = ChatInputBar.composerTextTrailingPadding(showsExpandButton: true)
        #expect(reserved < 20, "Trailing gutter should stay visually tight so wrapped text reaches near the send button")
    }

    @Test("Composer capsule uses the live semantic themed panel contract")
    func composerCapsuleUsesLiveSemanticThemedPanel() throws {
        let source = try chatInputBarSource()
        let chrome = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Oppi/Features/Chat/Composer/ComposerBarChrome.swift"),
            encoding: .utf8
        )

        #expect(source.contains("ThemeSurfaceStyle.resolve(.elevatedPanel"))
        #expect(chrome.contains("cornerRadius: CGFloat = 20"))
        #expect(chrome.contains("UIGlassEffect(style: .regular)"))
        #expect(!source.contains(".glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20"))
    }

    @Test("Photo picker presentation stays on stable composer roots")
    func photoPickerPresentationStaysOnStableComposerRoots() throws {
        let inlineSource = try chatInputBarSource()
        let inlinePresent = try chatInputBarSourceSlice(
            named: "private func presentPhotoLibrary() {",
            until: "private func presentCamera()",
            in: inlineSource
        )
        let inlineAttachMenu = try chatInputBarSourceSlice(
            named: "private func attachmentMenu() -> UIMenu {",
            until: "private func presentPhotoLibrary()",
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

        #expect(inlinePresent.contains("presentPhotoLibrary()") || inlinePresent.contains("PhotoLibraryPicker"))
        #expect(inlinePresent.contains(".composerCover") || inlinePresent.contains("PHPickerViewController"))
        #expect(!inlineAttachMenu.contains("PhotoLibraryPicker"))
        #expect(!inlineAttachMenu.contains(".composerPhotoLibraryCover("))
        #expect(expandedRoot.contains(".composerPhotoLibraryCover("))
        #expect(!expandedAttachMenu.contains(".composerPhotoLibraryCover("))
        #expect(!expandedAttachMenu.contains("PhotoLibraryPicker"))
        #expect(!inlineSource.contains(".photosPicker("))
        #expect(!expandedRoot.contains(".photosPicker("))

        let pickerSource = try photoLibraryPickerSource()
        #expect(pickerSource.contains(".any(of: [.images, .videos])"))
        #expect(pickerSource.contains("preferredAssetRepresentationMode = .current"))
        #expect(pickerSource.contains("selectionLimit"))
    }

    @Test("Active asks can disable expanded composer routing")
    func activeAsksCanDisableExpandedComposerRouting() {
        #expect(!ChatInputBar.shouldShowExpandButton(
            allowsExpansion: false,
            visualLineCount: 8,
            threshold: 5,
            maxLines: 10
        ))
        #expect(ChatInputBar.shouldShowExpandButton(
            allowsExpansion: true,
            visualLineCount: 5,
            threshold: 5,
            maxLines: 10
        ))
    }

    @Test("Empty submit is opt-in")
    func emptySubmitIsOptIn() {
        #expect(!ChatInputBar.canSubmitMessage(
            allowsEmptySubmit: false,
            text: "   ",
            hasImages: false,
            hasFiles: false,
            hasReviewComments: false
        ))
        #expect(ChatInputBar.canSubmitMessage(
            allowsEmptySubmit: true,
            text: "   ",
            hasImages: false,
            hasFiles: false,
            hasReviewComments: false
        ))
    }

    @Test("Non-empty submit stays enabled")
    func nonEmptySubmitStaysEnabled() {
        #expect(ChatInputBar.canSubmitMessage(
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

        let placeholder = ChatInputBar.composerPlaceholder(
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

        let placeholder = ChatInputBar.composerPlaceholder(
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

        let placeholder = ChatInputBar.composerPlaceholder(
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

        let placeholder = ChatInputBar.composerPlaceholder(
            askRequest: request,
            pendingReviewCommentCount: 0,
            isBusy: true,
            busyStreamingBehavior: .steer
        )

        #expect(placeholder == "Select options…")
    }

    @Test("Review comment placeholder includes staged count")
    func reviewCommentPlaceholderIncludesStagedCount() {
        let singular = ChatInputBar.composerPlaceholder(
            askRequest: nil,
            pendingReviewCommentCount: 1,
            isBusy: false,
            busyStreamingBehavior: .steer
        )
        let plural = ChatInputBar.composerPlaceholder(
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
        #expect(ChatInputBar.canSubmitMessage(
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

        #expect(!source.contains("reviewCommentStashBar"))
        #expect(!source.contains("onReviewCommentsTap"))
        #expect(!source.contains("static func reviewCommentStashTitle"))
        #expect(source.contains("pendingReviewCommentCount"))
    }

    @Test("Busy ask with no custom answer uses ignore instead of stop")
    func busyAskWithoutAnswerUsesIgnoreInsteadOfStop() {
        let action = ChatInputBar.primaryActionKind(
            isBusy: true,
            canSend: false,
            isSending: false,
            hasAskRequest: true
        )

        #expect(action == .ignoreAsk)
    }

    @Test("Busy session without ask still uses stop")
    func busySessionWithoutAskStillUsesStop() {
        let action = ChatInputBar.primaryActionKind(
            isBusy: true,
            canSend: false,
            isSending: false,
            hasAskRequest: false
        )

        #expect(action == .stop)
    }

    @Test("Custom ask answer keeps send as the primary action")
    func customAskAnswerKeepsSendPrimaryAction() {
        let action = ChatInputBar.primaryActionKind(
            isBusy: true,
            canSend: true,
            isSending: false,
            hasAskRequest: true
        )

        #expect(action == .send)
    }

    @Test("Ask hides the busy steering mode selector")
    func askHidesBusyModeSelector() {
        #expect(!ChatInputBar.showsBusyModeSelector(isBusy: true, hasAskRequest: true))
        #expect(ChatInputBar.showsBusyModeSelector(isBusy: true, hasAskRequest: false))
        #expect(!ChatInputBar.showsBusyModeSelector(isBusy: false, hasAskRequest: false))
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

        let answers = try #require(ChatInputBar.customAskAnswers(request: request, text: "  we already got this from pi  "))
        #expect(answers == ["q1": .custom("we already got this from pi")])
    }

    @Test("Composer text falls through to normal send when no ask is active")
    func composerTextFallsThroughWithoutAsk() {
        #expect(ChatInputBar.customAskAnswers(request: nil, text: "steer the agent") == nil)
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

        #expect(ChatInputBar.customAskAnswers(request: request, text: "custom") == nil)
        #expect(ChatInputBar.customAskAnswers(request: request, text: "   ") == nil)
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

        let answers = try #require(ChatInputBar.customAskAnswers(
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

        #expect(!ChatInputBar.shouldSubmitAskResponseImmediately(request: request, currentPage: 0))
        #expect(ChatInputBar.shouldSubmitAskResponseImmediately(request: request, currentPage: 1))
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

        let transition = try #require(ChatInputBar.askComposerSendTransition(
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

        let transition = try #require(ChatInputBar.askComposerSendTransition(
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

        let transition = try #require(ChatInputBar.askComposerSendTransition(
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

        #expect(ChatInputBar.customAskText(answers: answers, questionID: "q1") == "saved first answer")
        #expect(ChatInputBar.customAskText(answers: answers, questionID: "q2").isEmpty)
        #expect(ChatInputBar.customAskText(answers: answers, questionID: nil).isEmpty)
    }

    @Test("Settled ask does not provide replacement composer text")
    func settledAskDoesNotReplaceRestoredMessageDraft() {
        let displayedText = ChatInputBar.composerTextForActiveAskQuestion(
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
        let displayedText = ChatInputBar.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: draftAnswers,
            keepComposerClearedForSubmittedRequestID: "ask-1"
        )

        #expect(displayedText?.isEmpty == true)
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
        let transition = try #require(ChatInputBar.askComposerSendTransition(
            request: request,
            currentPage: 0,
            draftAnswers: [:],
            text: submittedText
        ))

        #expect(transition.shouldSubmit)
        #expect(transition.nextComposerText.isEmpty)

        let whileVisible = ChatInputBar.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: transition.answers,
            keepComposerClearedForSubmittedRequestID: request.id
        )
        #expect(whileVisible?.isEmpty == true)

        let submission = AskResponseSubmission()
        submission.submit(requestID: request.id) { $0(.completed) }
        submission.applyRequestIDChange(nil)
        let retainedID = submission.submittedRequestID
        #expect(retainedID == request.id)

        let afterServerCleared = ChatInputBar.composerTextForActiveAskQuestion(
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
        #expect(ChatInputBar.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: ["q1": .custom(submittedText)],
            keepComposerClearedForSubmittedRequestID: submission.submittedRequestID
        )?.isEmpty == true)

        submission.applyRequestIDChange(nil)
        let retainedID = submission.submittedRequestID
        #expect(retainedID == request.id)

        let replacement = ChatInputBar.composerTextForActiveAskQuestion(
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
        let nextComposerText = ChatInputBar.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: state.draftAnswers,
            keepComposerClearedForSubmittedRequestID: state.submittedRequestID
        )
        #expect(nextComposerText?.isEmpty == true)
        #expect(state.submittedRequestID == request.id)

        state.applyRequestIDChange(nil)
        #expect(state.submittedRequestID == request.id)
        #expect(state.currentPage == 0)
        #expect(state.draftAnswers.isEmpty)
        #expect(nextComposerText?.isEmpty == true)

        let afterRequestCleared = ChatInputBar.composerTextForActiveAskQuestion(
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
        let displayedText = ChatInputBar.composerTextForActiveAskQuestion(
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

    @Test("Apply does not write voice or ask bindings during the SwiftUI update turn")
    func applyDoesNotWriteBindingsDuringUpdateTurn() throws {
        let bar = try composerSource(named: "ChatInputBar.swift")
        let controller = try composerSource(named: "ComposerBarController.swift")
        #expect(!bar.contains("voiceInputManager?.voiceSpectrum"))
        #expect(bar.contains(".onChange(of: voiceInputManager?.currentComposerCaptureFailure"))
        #expect(bar.contains(".onChange(of: voiceInputManager?.transcriptPresentationRevision"))
        #expect(bar.contains(".onChange(of: text)"))
        #expect(!controller.contains("host.discardFailedVoiceTake()"))
        #expect(!controller.contains("host.setSuppressKeyboard(true)"))
        #expect(!controller.contains("prefix + manager.currentTranscript"))

        let host = ComposerBarTestHost()
        host.text = "KEEP"
        host.textBeforeRecording = "KEEP"
        host.suppressKeyboard = false
        let barController = ComposerBarController()
        barController.host = host
        _ = barController.view
        barController.apply()
        #expect(host.setTextCount == 0)
        #expect(host.discardCount == 0)
        #expect(host.setSuppressCount == 0)
        #expect(host.text == "KEEP")
        #expect(host.textBeforeRecording == "KEEP")
    }

    @Test("Focus token stays pending until the field has a window and becomeFirstResponder succeeds")
    func focusRequestStaysPendingUntilWindowedBecomeFirstResponder() throws {
        let source = try composerSource(named: "ComposerBarController.swift")
        let attempt = try chatInputBarSourceSlice(
            named: "private func attemptFocusIfRequested() {",
            until: "private func applyTextHeight",
            in: source
        )
        #expect(attempt.contains("guard textView.window != nil else { return }"))
        #expect(attempt.contains("guard textView.becomeFirstResponder() else { return }"))
        #expect(attempt.contains("host.consumeFocusRequest()"))
        #expect(!attempt.contains("host?.consumeFocusRequest()\n            DispatchQueue.main.async"))

        let host = ComposerBarTestHost()
        host.content.focusRequestID = 7
        let controller = ComposerBarController()
        controller.host = host
        _ = controller.view
        controller.apply()
        #expect(host.consumedFocus == 0)
        #expect(host.content.focusRequestID == 7)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.apply()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if host.consumedFocus == 1 {
            #expect(host.content.focusRequestID == 0)
        } else {
            #expect(host.content.focusRequestID == 7)
            #expect(host.consumedFocus == 0)
        }
        window.rootViewController = nil
        window.isHidden = true
    }

    @Test("Applying twice keeps a presented picker source and updates the list")
    func applyTwiceKeepsPresentedPopoverSource() {
        let host = ComposerBarTestHost()
        var updated = 0
        func rows(selected: String) -> [ComposerOptionRow] {
            ["max", "high"].map { id in
                ComposerOptionRow(
                    id: id,
                    title: id == "max" ? "Max" : "High",
                    subtitle: nil,
                    icon: nil,
                    isSelected: id == selected,
                    accessibilityIdentifier: "session.toolbar.thinking.option.\(id)",
                    accessibilityLabel: nil
                )
            }
        }
        func picker(selected: String) -> ComposerAction {
            ComposerAction(
                id: "session.toolbar.thinking",
                icon: nil,
                title: selected,
                tint: nil,
                accessibilityLabel: "Thinking",
                accessibilityValue: selected,
                showsChevron: true,
                chrome: .toolbar,
                kind: .picker(ComposerActionPopover(
                    make: {
                        ComposerOptionListController(
                            rows: rows(selected: selected),
                            isLoading: false,
                            emptyMessage: "",
                            colors: .placeholder,
                            preferredWidth: 220,
                            onSelect: { _ in }
                        )
                    },
                    update: { screen in
                        updated += 1
                        (screen as? ComposerOptionListController)?.apply(
                            rows: rows(selected: selected),
                            isLoading: false,
                            emptyMessage: "",
                            onSelect: { _ in }
                        )
                    }
                ))
            )
        }
        host.content.alwaysShowActionRow = true
        host.content.actionRow = ComposerActionRow(trailing: [picker(selected: "off")])
        let controller = ComposerBarController()
        controller.host = host
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.apply()
        controller.view.layoutIfNeeded()
        let thinking = descendant(in: controller.view, identifier: "session.toolbar.thinking")
        #expect(thinking != nil)
        let identity = thinking.map(ObjectIdentifier.init)
        controller.presentActionForTesting(id: "session.toolbar.thinking")
        #expect(controller.presentedActionIDForTesting == "session.toolbar.thinking")
        host.content.actionRow = ComposerActionRow(trailing: [picker(selected: "high")])
        controller.apply()
        controller.apply()
        #expect(controller.presentedActionIDForTesting == "session.toolbar.thinking")
        let again = descendant(in: controller.view, identifier: "session.toolbar.thinking")
        #expect(again.map(ObjectIdentifier.init) == identity)
        #expect(updated >= 1)
        #expect(again?.superview != nil)
        controller.dismiss(animated: false)
        window.rootViewController = nil
        window.isHidden = true
    }

    @Test("Long Ask cards scroll inside a capped slot; short cards stay short")
    func askSlotScrollsWhenTallerThanCap() {
        let host = ComposerBarTestHost()
        host.content.askRequest = AskRequest(
            id: "ask", sessionId: "s", questions: [], allowCustom: true, timeout: nil
        )
        host.content.askHeight = 80
        let controller = ComposerBarController()
        controller.host = host
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.apply()
        controller.setAskHeight(80)
        controller.view.layoutIfNeeded()
        #expect(!controller.askScrollViewForTesting.isScrollEnabled)
        #expect(controller.askScrollViewForTesting.bounds.height <= 81)

        controller.setAskHeight(400)
        host.content.askHeight = 400
        controller.apply()
        controller.view.layoutIfNeeded()
        #expect(controller.askScrollViewForTesting.isScrollEnabled)
        #expect(
            controller.askScrollViewForTesting.bounds.height
                <= ExtensionNativeSurfaceLayout.expandedMaxHeight + 0.5
        )
        window.rootViewController = nil
        window.isHidden = true
    }

    private func descendant(in root: UIView, identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let match = descendant(in: child, identifier: identifier) { return match }
        }
        return nil
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
            until: "private func updateTip()",
            in: source
        )
        #expect(card.contains("submitAskResponse(request: request, answers:"))
        let marker = try chatInputBarSourceSlice(
            named: "func submitAskResponse(", until: "private func handleAlternateSend", in: source
        )
        #expect(marker.contains("guard host?.content.askRequest?.id == request.id else") || marker.contains("guard askRequest?.id == request.id else"))
        #expect(marker.contains("askClearing.submission.submit(requestID: request.id"))
        #expect(marker.contains("composerTextForActiveAskQuestion("))
        let delivery = try chatInputBarSourceSlice(
            named: "deliver: { complete in", until: "self.host?.setText(\"\")", in: marker
        )
        #expect(delivery.contains("submittedTextRevision = self.askClearing.textRevision") || delivery.contains("submittedTextRevision = askClearing.textRevision"))
        #expect(source.contains("askClearing.textRevision &+= 1"))
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
    let bar = try composerSource(named: "ChatInputBar.swift")
    let controller = try composerSource(named: "ComposerBarController.swift")
    return bar + "\n" + controller
}

private func expandedComposerSource() throws -> String {
    try composerSource(named: "ExpandedComposerView.swift")
}

private func photoLibraryPickerSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Oppi/Core/Views/PhotoLibraryPicker.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
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

@MainActor
private final class ComposerBarTestHost: ComposerBarHosting {
    var content = ComposerBarContent(
        text: "",
        textBeforeRecording: nil,
        pendingAttachments: [],
        pendingRepoPointers: [],
        isBusy: false,
        busyStreamingBehavior: .followUp,
        isSending: false,
        pendingReviewCommentCount: 0,
        placeholderOverride: nil,
        allowsEmptySubmit: false,
        sendProgressText: nil,
        isStopping: false,
        voiceInputManager: nil,
        showForceStop: false,
        isForceStopInFlight: false,
        askRequest: nil,
        slashCommands: [],
        fileSuggestions: [],
        appliesOuterPadding: false,
        alwaysShowActionRow: true,
        allowsExpansion: true,
        allowsAttachments: true,
        attachmentButtonPlacement: .leading,
        actionRowMinimumHeight: 0,
        showsAccessoryRow: true,
        autocorrectionEnabled: true,
        inputAccessibilityIdentifier: "chat.input",
        sendAccessibilityIdentifier: "chat.send",
        actionRow: .init(),
        colors: .placeholder,
        reduceMotion: true,
        suppressKeyboard: false,
        focusRequestID: 0,
        keyboardLanguage: nil,
        askHeight: 0,
        keyStripHeight: 0,
        mediaImportEpoch: 0
    )
    var text: String {
        get { content.text }
        set { content.text = newValue }
    }
    var textBeforeRecording: String? {
        get { content.textBeforeRecording }
        set { content.textBeforeRecording = newValue }
    }
    var suppressKeyboard: Bool {
        get { content.suppressKeyboard }
        set { content.suppressKeyboard = newValue }
    }
    var setTextCount = 0
    var discardCount = 0
    var setSuppressCount = 0
    var consumedFocus = 0

    func setText(_ text: String) {
        setTextCount += 1
        content.text = text
    }
    func setTextBeforeRecording(_ value: String?) { content.textBeforeRecording = value }
    func setPendingAttachments(_ value: [PendingAttachment]) { content.pendingAttachments = value }
    func setPendingRepoPointers(_ value: [PendingFileReference]) { content.pendingRepoPointers = value }
    func setBusyStreamingBehavior(_ value: StreamingBehavior) { content.busyStreamingBehavior = value }
    func setSuppressKeyboard(_ value: Bool) {
        setSuppressCount += 1
        content.suppressKeyboard = value
    }
    func consumeFocusRequest() {
        consumedFocus += 1
        content.focusRequestID = 0
    }
    func setKeyboardLanguage(_ value: String?) { content.keyboardLanguage = value }
    func setInputFocused(_ value: Bool) {}
    func performSend() {}
    func performStop() {}
    func performForceStop() {}
    func performExpand() {}
    func submitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) { completion(.completed) }
    func ignoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {
        completion(.completed)
    }
    func startVoice(
        keyboardLanguage: String?,
        owner: ComposerShared.VoiceInputOwner,
        baseText: String
    ) async throws {}
    func stopVoice() async {}
    func cancelVoice() async {}
    func finishVoiceBeforeSubmit() async {}
    func handlePastedImages(_ images: [UIImage]) {}
    func insertSlashCommand(_ command: SlashCommand) {}
    func insertFileSuggestion(_ suggestion: FileSuggestion) {}
    func removeAttachment(id: String) {}
    func removeRepoPointer(id: String) {}
    func importPhotoProviders(
        _ providers: [NSItemProvider],
        capturedGate: UInt64,
        capturedLocal: UInt64,
        currentLocal: @escaping () -> UInt64,
        onFailure: @escaping (String) -> Void
    ) {}
    func addCapturedImage(_ image: UIImage) {}
    func applyCanvas(
        attachment: PendingAttachment,
        recognizedText: String,
        replacingAttachmentID: String?
    ) -> Bool { true }
    func loadSelectedFiles(
        _ result: Result<[URL], Error>,
        capturedGate: UInt64,
        capturedLocal: UInt64,
        currentLocal: @escaping () -> UInt64,
        onFailure: @escaping (String) -> Void
    ) {}
    func notifyFileSuggestionContext(for text: String) {}
    func discardFailedVoiceTake() { discardCount += 1 }
    func restoreKeyboardFromSuppression() {}
}

private final class DismissSpyImagePickerController: UIImagePickerController {
    private(set) var dismissCallCount = 0

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissCallCount += 1
        completion?()
    }
}
