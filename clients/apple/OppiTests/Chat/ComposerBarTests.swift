import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Composer bar")
@MainActor
struct ComposerBarTests {
    @Test("Live Voice entry ends a recording or preparing dictation take first")
    func liveVoiceEntryEndsDictation() async {
        for state: VoiceInputManager.State in [.recording, .preparingModel] {
            let manager = VoiceInputManager()
            manager._testState = state
            await ComposerShared.stopDictationBeforeLiveVoice(manager: manager)
            #expect(manager.state == .idle)
            #expect(!manager.isRecording)
            #expect(!manager.isPreparing)
        }
    }

    /// Chrome updates run inside a rotation's animation. Empty updates that
    /// hide an already hidden panel must not keep it hidden once it has rows.
    @Test("Suggestion panel shows on the first update after animated empty updates")
    func suggestionPanelShowsAfterAnimatedEmptyUpdates() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        let panel = ComposerSuggestionPanelView()
        let stack = UIStackView(arrangedSubviews: [panel])
        stack.axis = .vertical
        stack.frame = window.bounds
        host.view.addSubview(stack)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let colors = ComposerThemeColors(palette: ThemeRuntimeState.currentThemeID().palette)
        panel.apply(content: .empty, colors: colors)
        for _ in 0..<2 {
            UIView.animate(withDuration: 0.3) { panel.apply(content: .empty, colors: colors) }
            try await Task.sleep(for: .milliseconds(600))
        }
        let command = SlashCommand(name: "compact", description: "Compact the session", source: .extension)
        panel.apply(content: .slash([command]), colors: colors)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!panel.isHidden, "the first update with rows shows the panel")
    }

    @Test("Tap-to-type remains enabled while voice is active")
    func tapToTypeRemainsEnabledDuringVoiceStates() {
        #expect(ComposerPolicy.allowKeyboardRestoreOnTap(voiceState: .recording))
        #expect(ComposerPolicy.allowKeyboardRestoreOnTap(voiceState: .preparingModel))
        #expect(ComposerPolicy.allowKeyboardRestoreOnTap(voiceState: .processing))
    }

    @Test("Tap-to-type remains enabled while idle or after errors")
    func tapToTypeRemainsEnabledOutsideVoiceStates() {
        #expect(ComposerPolicy.allowKeyboardRestoreOnTap(voiceState: .idle))
        #expect(ComposerPolicy.allowKeyboardRestoreOnTap(voiceState: .error("boom")))
    }

    @Test("Dictation focus expands composer action row")
    func dictationFocusExpandsActionRow() {
        #expect(ComposerPolicy.shouldShowComposerActionRow(
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
        #expect(ComposerPolicy.shouldShowComposerActionRow(
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
        #expect(!ComposerPolicy.shouldShowComposerActionRow(
            alwaysShowActionRow: false,
            isBusy: false,
            isInputFocused: false,
            isKeyboardSuppressed: false,
            hasAttachments: false,
            hasRepoPointers: false
        ))
        #expect(!ComposerPolicy.shouldShowComposerActionRow(
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
        let suppressed = ComposerPolicy.suppressKeyboardAfterSend(
            voiceState: .recording,
            wasSuppressed: true
        )

        #expect(suppressed)
    }

    @Test("Send while preparing keeps keyboard suppressed")
    func sendWhilePreparingKeepsSuppressed() {
        let suppressed = ComposerPolicy.suppressKeyboardAfterSend(
            voiceState: .preparingModel,
            wasSuppressed: true
        )

        #expect(suppressed)
    }

    @Test("Non-voice states preserve existing suppression value")
    func nonVoiceStatesPreserveSuppression() {
        let idleSuppressed = ComposerPolicy.suppressKeyboardAfterSend(
            voiceState: .idle,
            wasSuppressed: true
        )
        let processingUnsuppressed = ComposerPolicy.suppressKeyboardAfterSend(
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
        #expect(ComposerPolicy.suppressKeyboardAfterSend(
            voiceState: voiceStateBeforeFinish,
            wasSuppressed: true
        ))
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
        let maxLines = ComposerPolicy.inlineTextMaxLines(
            hasAskRequest: true,
            hasAttachments: false,
            hasRepoPointers: false
        )

        #expect(maxLines == ComposerInputMetrics.inlineMaxLinesWithAttachments)
        #expect(maxLines < ComposerInputMetrics.inlineMaxLines)
    }

    @Test("Plain composer keeps the full inline input height")
    func plainComposerKeepsFullInlineInputHeight() {
        let maxLines = ComposerPolicy.inlineTextMaxLines(
            hasAskRequest: false,
            hasAttachments: false,
            hasRepoPointers: false
        )

        #expect(maxLines == ComposerInputMetrics.inlineMaxLines)
    }

    @Test("Expand affordance reserves only a tight trailing gutter")
    func expandAffordanceUsesTightTrailingGutter() {
        #expect(ComposerPolicy.composerTextTrailingPadding(showsExpandButton: false) == 0)
        #expect(ComposerPolicy.composerTextTrailingPadding(showsExpandButton: true) == 10)
    }

    @Test("Expand affordance no longer reserves a full button width")
    func expandAffordanceDoesNotReserveFullButtonWidth() {
        let reserved = ComposerPolicy.composerTextTrailingPadding(showsExpandButton: true)
        #expect(reserved < 20, "Trailing gutter should stay visually tight so wrapped text reaches near the send button")
    }

    @Test("Active asks can disable expanded composer routing")
    func activeAsksCanDisableExpandedComposerRouting() {
        #expect(!ComposerPolicy.shouldShowExpandButton(
            allowsExpansion: false,
            visualLineCount: 8,
            threshold: 5,
            maxLines: 10
        ))
        #expect(ComposerPolicy.shouldShowExpandButton(
            allowsExpansion: true,
            visualLineCount: 5,
            threshold: 5,
            maxLines: 10
        ))
    }

    @Test("Empty submit is opt-in")
    func emptySubmitIsOptIn() {
        #expect(!ComposerPolicy.canSubmitMessage(
            allowsEmptySubmit: false,
            text: "   ",
            hasImages: false,
            hasFiles: false,
            hasReviewComments: false
        ))
        #expect(ComposerPolicy.canSubmitMessage(
            allowsEmptySubmit: true,
            text: "   ",
            hasImages: false,
            hasFiles: false,
            hasReviewComments: false
        ))
    }

    @Test("Non-empty submit stays enabled")
    func nonEmptySubmitStaysEnabled() {
        #expect(ComposerPolicy.canSubmitMessage(
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

        let placeholder = ComposerPolicy.composerPlaceholder(
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

        let placeholder = ComposerPolicy.composerPlaceholder(
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

        let placeholder = ComposerPolicy.composerPlaceholder(
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

        let placeholder = ComposerPolicy.composerPlaceholder(
            askRequest: request,
            pendingReviewCommentCount: 0,
            isBusy: true,
            busyStreamingBehavior: .steer
        )

        #expect(placeholder == "Select options…")
    }

    @Test("Review comment placeholder includes staged count")
    func reviewCommentPlaceholderIncludesStagedCount() {
        let singular = ComposerPolicy.composerPlaceholder(
            askRequest: nil,
            pendingReviewCommentCount: 1,
            isBusy: false,
            busyStreamingBehavior: .steer
        )
        let plural = ComposerPolicy.composerPlaceholder(
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
        #expect(ComposerPolicy.canSubmitMessage(
            allowsEmptySubmit: false,
            text: "   ",
            hasImages: false,
            hasFiles: false,
            hasReviewComments: true
        ))
    }

    @Test("Busy ask with no custom answer uses ignore instead of stop")
    func busyAskWithoutAnswerUsesIgnoreInsteadOfStop() {
        let action = ComposerPolicy.primaryActionKind(
            isBusy: true,
            canSend: false,
            isSending: false,
            hasAskRequest: true
        )

        #expect(action == .ignoreAsk)
    }

    @Test("Busy session without ask still uses stop")
    func busySessionWithoutAskStillUsesStop() {
        let action = ComposerPolicy.primaryActionKind(
            isBusy: true,
            canSend: false,
            isSending: false,
            hasAskRequest: false
        )

        #expect(action == .stop)
    }

    @Test("Custom ask answer keeps send as the primary action")
    func customAskAnswerKeepsSendPrimaryAction() {
        let action = ComposerPolicy.primaryActionKind(
            isBusy: true,
            canSend: true,
            isSending: false,
            hasAskRequest: true
        )

        #expect(action == .send)
    }

    @Test("Ask hides the busy steering mode selector")
    func askHidesBusyModeSelector() {
        #expect(!ComposerPolicy.showsBusyModeSelector(isBusy: true, hasAskRequest: true))
        #expect(ComposerPolicy.showsBusyModeSelector(isBusy: true, hasAskRequest: false))
        #expect(!ComposerPolicy.showsBusyModeSelector(isBusy: false, hasAskRequest: false))
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

        let answers = try #require(ComposerPolicy.customAskAnswers(request: request, text: "  we already got this from pi  "))
        #expect(answers == ["q1": .custom("we already got this from pi")])
    }

    @Test("Composer text falls through to normal send when no ask is active")
    func composerTextFallsThroughWithoutAsk() {
        #expect(ComposerPolicy.customAskAnswers(request: nil, text: "steer the agent") == nil)
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

        #expect(ComposerPolicy.customAskAnswers(request: request, text: "custom") == nil)
        #expect(ComposerPolicy.customAskAnswers(request: request, text: "   ") == nil)
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

        let answers = try #require(ComposerPolicy.customAskAnswers(
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

        #expect(!ComposerPolicy.shouldSubmitAskResponseImmediately(request: request, currentPage: 0))
        #expect(ComposerPolicy.shouldSubmitAskResponseImmediately(request: request, currentPage: 1))
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

        let transition = try #require(ComposerPolicy.askComposerSendTransition(
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

        let transition = try #require(ComposerPolicy.askComposerSendTransition(
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

        let transition = try #require(ComposerPolicy.askComposerSendTransition(
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

        #expect(ComposerPolicy.customAskText(answers: answers, questionID: "q1") == "saved first answer")
        #expect(ComposerPolicy.customAskText(answers: answers, questionID: "q2").isEmpty)
        #expect(ComposerPolicy.customAskText(answers: answers, questionID: nil).isEmpty)
    }

    @Test("Settled ask does not provide replacement composer text")
    func settledAskDoesNotReplaceRestoredMessageDraft() {
        let displayedText = ComposerPolicy.composerTextForActiveAskQuestion(
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
        let displayedText = ComposerPolicy.composerTextForActiveAskQuestion(
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
        let transition = try #require(ComposerPolicy.askComposerSendTransition(
            request: request,
            currentPage: 0,
            draftAnswers: [:],
            text: submittedText
        ))

        #expect(transition.shouldSubmit)
        #expect(transition.nextComposerText.isEmpty)

        let whileVisible = ComposerPolicy.composerTextForActiveAskQuestion(
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

        let afterServerCleared = ComposerPolicy.composerTextForActiveAskQuestion(
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
        #expect(ComposerPolicy.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: ["q1": .custom(submittedText)],
            keepComposerClearedForSubmittedRequestID: submission.submittedRequestID
        )?.isEmpty == true)

        submission.applyRequestIDChange(nil)
        let retainedID = submission.submittedRequestID
        #expect(retainedID == request.id)

        let replacement = ComposerPolicy.composerTextForActiveAskQuestion(
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
        let nextComposerText = ComposerPolicy.composerTextForActiveAskQuestion(
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

        let afterRequestCleared = ComposerPolicy.composerTextForActiveAskQuestion(
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
        let displayedText = ComposerPolicy.composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: "q1",
            draftAnswers: draftAnswers,
            keepComposerClearedForSubmittedRequestID: nil
        )

        #expect(displayedText == "because the larger tables should download")
    }

    @Test("Dictation indicator change posted off the main thread does not trap a live mic button")
    func dictationIndicatorChangeOffMainDoesNotTrapMicButton() async {
        let button = MicButtonChromeView()
        let key = AppPreferenceStore.Appearance.dictationIndicatorStyleKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        await Task.detached {
            AppPreferenceStore.Appearance.setDictationIndicatorStyle(.breathing)
            AppPreferenceStore.Appearance.setDictationIndicatorStyle(.ring)
        }.value
        #expect(button.intrinsicContentSize.width == 44)
    }

    @Test("Apply does not write the host's draft, voice prefix, or keyboard state")
    func applyDoesNotWriteHostValues() throws {
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

    @Test("Thinking levels stay reachable when the popover is shorter than the list")
    func thinkingLevelsScrollInsideAShortPopover() throws {
        let picker = ComposerThinkingPickerController(
            levels: ThinkingLevel.allCases,
            selected: .medium,
            colors: .placeholder,
            onSelect: { _ in },
            onSaveDefault: nil
        )
        picker.loadViewIfNeeded()
        // An iPhone in landscape with the keyboard up leaves the popover about this tall.
        picker.view.frame = CGRect(x: 0, y: 0, width: 220, height: 120)
        picker.view.layoutIfNeeded()

        let scroll = try #require(picker.view.firstDescendant(where: { $0 is UIScrollView }) as? UIScrollView)
        #expect(scroll.contentSize.height > scroll.bounds.height, "The list overflows the short popover")
        let off = try #require(picker.view.firstDescendant(where: {
            $0.accessibilityIdentifier == "session.toolbar.thinking.option.off"
        }))
        #expect(
            !scroll.bounds.intersects(off.convert(off.bounds, to: scroll)),
            "Off starts below the popover's fold"
        )

        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
        picker.view.layoutIfNeeded()
        #expect(
            scroll.bounds.insetBy(dx: 0, dy: -0.5).contains(off.convert(off.bounds, to: scroll)),
            "Scrolling the list must bring Off into the popover"
        )
    }

    @Test("A long Ask scrolls its rows inside the capped slot, rows fit their text, and actions stay in view")
    func longAskScrollsInsideCappedSlotWithActionsInView() throws {
        let host = ComposerBarTestHost()
        host.content.askRequest = Self.longMultiSelectAsk
        let (controller, window) = Self.mountComposer(host)
        defer { window.rootViewController = nil; window.isHidden = true }

        let scroll = try #require(descendant(in: controller.view, identifier: "chat.ask.scroll") as? UIScrollView)
        let card = try #require(scroll.superview)
        #expect(card.bounds.height <= ExtensionNativeSurfaceLayout.expandedMaxHeight + 0.5)
        #expect(card.bounds.height > 120)
        #expect(scroll.isScrollEnabled)
        #expect(scroll.contentSize.height > scroll.bounds.height)

        // Send and Ignore stay inside the visible card, not below the fold.
        for id in ["ask.send", "ask.ignore"] {
            let button = try #require(descendant(in: controller.view, identifier: id))
            let frame = button.convert(button.bounds, to: card)
            #expect(card.bounds.contains(frame), "\(id) is outside the visible card: \(frame) in \(card.bounds)")
            #expect(frame.height >= 44)
        }

        // Every option row is at least as tall as its wrapped text.
        for option in Self.longMultiSelectAsk.questions[0].options {
            let row = try #require(descendant(in: scroll, identifier: "ask.option.\(option.value)"))
            for label in Self.labels(in: row) where !label.isHidden {
                let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                #expect(label.bounds.height >= needed - 0.5, "\(option.value) clips its text")
                #expect(label.convert(label.bounds, to: row).maxY <= row.bounds.height)
            }
        }
    }

    @Test("A long Live Voice status truncates; the mic and End keep their size, and the mic carries the state")
    func longLiveVoiceStatusKeepsCallControls() throws {
        let host = ComposerBarTestHost()
        host.content.alwaysShowActionRow = false
        let failure = "Grok Voice needs an xAI sign-in or API key before a call can start on this server"
        host.content.liveVoiceCall = ComposerLiveVoiceCall(
            isLive: false, isConnecting: false, isMuted: false, isSpeaking: false,
            status: failure, transcript: "", meter: LiveVoiceAudioMeter(),
            onToggleMute: {}, onEnd: {}
        )
        let (controller, window) = Self.mountComposer(host)
        defer { window.rootViewController = nil; window.isHidden = true }

        let diameter = ComposerInputMetrics.controlDiameter
        let mic = try #require(descendant(in: controller.view, identifier: ComposerLiveVoiceCall.muteIdentifier))
        let end = try #require(descendant(in: controller.view, identifier: ComposerLiveVoiceCall.endIdentifier))
        let status = try #require(descendant(in: controller.view, identifier: ComposerLiveVoiceCall.stateIdentifier) as? UILabel)
        #expect(abs(mic.bounds.width - diameter) < 0.5, "mic squeezed to \(mic.bounds.width)")
        #expect(abs(end.bounds.width - diameter) < 0.5, "End squeezed to \(end.bounds.width)")
        #expect(!mic.isHidden && !end.isHidden && !status.isHidden)
        #expect(status.intrinsicContentSize.width > status.bounds.width, "status should truncate at 390 pt")
        #expect(mic.accessibilityValue == failure)

        // The visible status gives way to what the user is saying; the mic still has the state.
        host.content.liveVoiceCall?.isLive = true
        host.content.liveVoiceCall?.status = "Listening"
        host.content.liveVoiceCall?.transcript = "check the server tests"
        controller.apply()
        window.layoutIfNeeded()
        #expect(status.isHidden)
        #expect(mic.accessibilityValue == "Listening")
        host.content.liveVoiceCall?.isMuted = true
        controller.apply()
        #expect(mic.accessibilityValue == "Muted")
    }

    @Test("A short Ask sizes the slot to the card without scrolling")
    func shortAskSizesSlotToCard() throws {
        let host = ComposerBarTestHost()
        host.content.askRequest = Self.shortAsk(id: "short")
        let (controller, window) = Self.mountComposer(host)
        defer { window.rootViewController = nil; window.isHidden = true }

        let scroll = try #require(descendant(in: controller.view, identifier: "chat.ask.scroll") as? UIScrollView)
        #expect(!scroll.isScrollEnabled)
        #expect(scroll.contentSize.height <= scroll.bounds.height + 0.5)
        #expect(scroll.superview!.bounds.height < ExtensionNativeSurfaceLayout.expandedMaxHeight)
    }

    @Test("A new Ask after a scrolled one starts at its top in a slot sized for it")
    func replacingAskResetsScrollAndSlot() throws {
        let host = ComposerBarTestHost()
        host.content.askRequest = Self.longMultiSelectAsk
        let (controller, window) = Self.mountComposer(host)
        defer { window.rootViewController = nil; window.isHidden = true }
        let scroll = try #require(descendant(in: controller.view, identifier: "chat.ask.scroll") as? UIScrollView)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)

        host.content.askRequest = Self.shortAsk(id: "next")
        controller.apply()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let next = try #require(descendant(in: controller.view, identifier: "chat.ask.scroll") as? UIScrollView)
        #expect(next.contentOffset.y == 0)
        #expect(!next.isScrollEnabled)
        let first = try #require(descendant(in: next, identifier: "ask.option.yes"))
        #expect(next.bounds.contains(first.convert(first.bounds, to: next)))
    }

    @Test("A submitted Ask forwards one response and disables its controls until delivery fails")
    func submittedAskDisablesControlsUntilDeliveryFails() throws {
        let host = ComposerBarTestHost()
        host.holdsAskCompletions = true
        host.content.askRequest = Self.longMultiSelectAsk
        let (controller, window) = Self.mountComposer(host)
        defer { window.rootViewController = nil; window.isHidden = true }

        let option = try #require(descendant(in: controller.view, identifier: "ask.option.trackpad") as? UIControl)
        option.sendActions(for: .touchUpInside)
        let send = try #require(descendant(in: controller.view, identifier: "ask.send") as? UIButton)
        send.sendActions(for: .touchUpInside)
        send.sendActions(for: .touchUpInside)
        #expect(host.askDeliveries.count == 1)
        #expect(host.askDeliveries.first??["features"] == .multi(["trackpad"]))
        #expect(!send.isEnabled)
        #expect(!option.isEnabled)
        #expect((descendant(in: controller.view, identifier: "ask.ignore") as? UIButton)?.isEnabled == false)

        // A failed delivery hands the card back for a retry.
        host.heldAskCompletions.removeFirst()(.retryableFailure)
        controller.apply()
        controller.view.layoutIfNeeded()
        #expect(send.isEnabled)
        #expect(option.isEnabled)
        #expect(send.configuration?.title == "Retry")
        send.sendActions(for: .touchUpInside)
        #expect(host.askDeliveries.count == 2)
    }

    @Test("A failed Ask send keeps text typed while it was in flight")
    func failedAskSendKeepsTextTypedInFlight() throws {
        let host = ComposerBarTestHost()
        host.holdsAskCompletions = true
        host.content.askRequest = AskRequest(
            id: "ask-1",
            sessionId: "s",
            questions: [AskQuestion(id: "q1", question: "Why?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let (controller, window) = Self.mountComposer(host)
        defer { window.rootViewController = nil; window.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let input = try #require(descendant(in: controller.view, identifier: "chat.input") as? UITextView)
        input.text = "sent answer"
        controller.textViewDidChange(input)
        let send = try #require(descendant(in: controller.view, identifier: "chat.send") as? UIButton)
        send.sendActions(for: .touchUpInside)
        #expect(host.askDeliveries.count == 1)
        #expect(host.content.text.isEmpty, "Sending clears the submitted answer")

        // The user starts a new draft before the delivery settles.
        input.text = "typed while sending"
        controller.textViewDidChange(input)

        host.heldAskCompletions.removeFirst()(.retryableFailure)
        controller.view.layoutIfNeeded()
        #expect(
            host.content.text == "typed while sending",
            "A failed delivery must not restore the sent answer over newer typing"
        )
        #expect(input.text == "typed while sending")
    }

    @Test("A failed Ask send leaves a type-then-delete edit alone")
    func failedAskSendDoesNotRestoreAfterAnEditAndDelete() throws {
        let host = ComposerBarTestHost()
        host.holdsAskCompletions = true
        host.content.askRequest = AskRequest(
            id: "ask-1",
            sessionId: "s",
            questions: [AskQuestion(id: "q1", question: "Why?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let (controller, window) = Self.mountComposer(host)
        defer { window.rootViewController = nil; window.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let input = try #require(descendant(in: controller.view, identifier: "chat.input") as? UITextView)
        input.text = "sent answer"
        controller.textViewDidChange(input)
        let send = try #require(descendant(in: controller.view, identifier: "chat.send") as? UIButton)
        send.sendActions(for: .touchUpInside)
        #expect(host.askDeliveries.count == 1)

        // The edit is not the text's emptiness: type then delete, so the text
        // revision moves while the field is empty again.
        input.text = "typed then removed"
        controller.textViewDidChange(input)
        input.text = ""
        controller.textViewDidChange(input)
        #expect(host.content.text.isEmpty)

        host.heldAskCompletions.removeFirst()(.retryableFailure)
        controller.view.layoutIfNeeded()
        #expect(host.content.text.isEmpty, "The failure must not restore over an emptied field")
        #expect(input.text.isEmpty)
    }

    private static func mountComposer(_ host: ComposerBarTestHost) -> (ComposerBarController, UIWindow) {
        let controller = ComposerBarController()
        controller.host = host
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.apply()
        _ = controller.sizeThatFits(width: 390)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.apply()
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    private static let longMultiSelectAsk = AskRequest(
        id: "long",
        sessionId: "s",
        questions: [AskQuestion(
            id: "features",
            question: "Which keyboard follow-ups should ship in the next terminal build?",
            options: [
                AskOption(value: "trackpad", label: "Space bar trackpad \u{2192} arrow keys (Recommended)",
                          description: "Long-press the space bar and slide: sends \u{2190}/\u{2192} (and \u{2191}/\u{2193}) to the shell, like moving the cursor in a text field."),
                AskOption(value: "dictation", label: "Keyboard mic dictation into the terminal",
                          description: "The system keyboard's mic types the dictated words straight into the shell (once, no partial results)."),
                AskOption(value: "shortcuts", label: "Hardware keyboard shortcuts",
                          description: "\u{2318}C copy selection, \u{2318}V paste (with the usual confirm), \u{2318}K clear, Option as Meta, \u{2318}. as Esc; shown in the \u{2318} shortcut overlay."),
                AskOption(value: "delete", label: "Faster delete when held long",
                          description: "After a second of holding Delete, deletes a word at a time instead of one character."),
            ],
            multiSelect: true
        )],
        allowCustom: true,
        timeout: nil
    )

    private static func shortAsk(id: String) -> AskRequest {
        AskRequest(
            id: id,
            sessionId: "s",
            questions: [AskQuestion(
                id: "confirm",
                question: "Run it?",
                options: [AskOption(value: "yes", label: "Yes"), AskOption(value: "no", label: "No")],
                multiSelect: false
            )],
            allowCustom: false,
            timeout: nil
        )
    }

    private static func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { subview -> [UILabel] in
            (subview as? UILabel).map { [$0] } ?? labels(in: subview)
        }
    }

    @Test("A draft set outside typing (dictation, restore) shows expand once it reaches the inline budget")
    func programmaticLongDraftShowsExpand() {
        let host = ComposerBarTestHost()
        let controller = ComposerBarController()
        controller.host = host
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        controller.apply()
        #expect(!showsExpand(in: controller.view))

        // One paragraph, no line breaks: it reaches the threshold only by wrapping.
        host.text = String(repeating: "Dictated words keep flowing into the composer. ", count: 8)
        controller.apply()
        #expect(showsExpand(in: controller.view))

        // Sending clears the draft without a keystroke.
        host.text = ""
        controller.apply()
        #expect(!showsExpand(in: controller.view))
        window.rootViewController = nil
        window.isHidden = true
    }

    @Test("A busy bar keeps its idle height while the busy-mode tip is not presented")
    func busyBarReservesNoSpaceForAbsentTip() {
        let host = ComposerBarTestHost()
        host.content.alwaysShowActionRow = false
        // A draft keeps Send as the primary control in both states; an empty
        // busy bar shows the slightly larger Stop instead.
        host.text = "steer"
        let controller = ComposerBarController()
        controller.host = host
        _ = controller.view
        controller.apply()
        let idle = controller.sizeThatFits(width: 390).height

        host.content.isBusy = true
        controller.apply()
        #expect(controller.sizeThatFits(width: 390).height == idle)

        controller.setBusyTipHeight(70)
        #expect(controller.sizeThatFits(width: 390).height == idle + 70)
        controller.setBusyTipHeight(0)
        #expect(controller.sizeThatFits(width: 390).height == idle)

        // A tip still showing when the turn ends must not hold space in the
        // next busy turn before that turn's tip reports a height.
        controller.setBusyTipHeight(70)
        host.content.isBusy = false
        controller.apply()
        host.content.isBusy = true
        controller.apply()
        #expect(controller.sizeThatFits(width: 390).height == idle)
    }

    @Test("Toolbar pills size to their full title as short capsules")
    func toolbarPillsFitTheirTitle() throws {
        let host = ComposerBarTestHost()
        host.content.actionRow = .sessionToolbar(
            modelTitle: "routes",
            modelProvider: nil,
            thinkingLevel: .medium,
            thinkingTint: .systemBlue,
            supportedThinkingLevels: ThinkingLevel.allCases,
            colors: .placeholder,
            onModelTap: {},
            onThinkingSelect: { _ in },
            onSaveThinkingAsDefault: nil
        )
        let controller = ComposerBarController()
        controller.host = host
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.apply()
        controller.view.layoutIfNeeded()

        let model = try #require(descendant(in: controller.view, identifier: "session.toolbar.model"))
        let font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .medium
        )
        let titleWidth = ("routes" as NSString).size(withAttributes: [.font: font]).width
        #expect(model.bounds.width >= titleWidth + 20)
        #expect(model.bounds.height <= 24)
        window.rootViewController = nil
        window.isHidden = true
    }

    @Test("Review quick comments stay visible between the attach and cancel buttons")
    func reviewQuickCommentChipsAreVisible() throws {
        let host = ComposerBarTestHost()
        let templates = QuickCommentTemplate.builtInDefaults
        // Chat shows the session toolbar first; commenting swaps the row in place.
        host.content.actionRow = .sessionToolbar(
            modelTitle: "routes",
            modelProvider: nil,
            thinkingLevel: .medium,
            thinkingTint: .systemBlue,
            supportedThinkingLevels: ThinkingLevel.allCases,
            colors: .placeholder,
            onModelTap: {},
            onThinkingSelect: { _ in },
            onSaveThinkingAsDefault: nil
        )
        let controller = ComposerBarController()
        controller.host = host
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.apply()
        controller.view.layoutIfNeeded()

        host.content.actionRow = ComposerActionRow(
            leading: templates.map { template in
                .reviewChip(
                    id: "chat.reviewComment.\(template.id.uuidString)",
                    title: template.title,
                    systemImage: template.systemImage,
                    onTap: {}
                )
            },
            trailing: [.reviewCancel {}],
            leadingScrolls: true
        )
        controller.apply()
        controller.view.layoutIfNeeded()

        let first = try #require(descendant(
            in: controller.view,
            identifier: "chat.reviewComment.\(templates[0].id.uuidString)"
        ))
        let cancel = try #require(descendant(in: controller.view, identifier: "chat.reviewComment.cancel"))
        let scroll = try #require(first.superview?.superview)
        let chipFrame = first.convert(first.bounds, to: window)
        let visibleFrame = scroll.convert(scroll.bounds, to: window)
        // Auto Layout may pick any solution the constraints allow; on device it
        // once handed the whole row to the spacer. Walk the alternatives.
        let settledWidth = scroll.bounds.width
        for _ in 0..<6 {
            scroll.exerciseAmbiguityInLayout()
            #expect(scroll.bounds.width == settledWidth)
        }
        #expect(chipFrame.width > 40)
        #expect(visibleFrame.contains(chipFrame))
        #expect(chipFrame.maxX <= cancel.convert(cancel.bounds, to: window).minX)
        // Four default chips overflow an iPhone row: they scroll, Cancel keeps its size.
        #expect(cancel.bounds.width >= 32)
        #expect((scroll as? UIScrollView).map { $0.contentSize.width > $0.bounds.width } == true)
        window.rootViewController = nil
        window.isHidden = true
    }

    private func showsExpand(in root: UIView) -> Bool {
        if root.accessibilityIdentifier == "chat.expand", !root.isHidden { return true }
        return root.subviews.contains { showsExpand(in: $0) }
    }

    private func descendant(in root: UIView, identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let match = descendant(in: child, identifier: identifier) { return match }
        }
        return nil
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

}

/// Commenting with dictation from the selection menu, through the chat's own
/// composer owner: the comment row and then the normal bar must stay laid out.
@Suite("Composer action row with dictated comments")
@MainActor
struct ComposerDictatedCommentRowTests {
    @Test("Commenting with dictation keeps the plus and Cancel in the row, and the normal bar recovers after")
    func dictatedCommentKeepsActionRowLaidOut() async throws {
        var content = ComposerBarTestHost().content
        content.alwaysShowActionRow = false
        content.appliesOuterPadding = true
        content.reduceMotion = false
        content.voiceInputManager = VoiceInputManager()
        let toolbar = ComposerActionRow.sessionToolbar(
            modelTitle: "opus-5-5",
            modelProvider: "anthropic",
            thinkingLevel: .high,
            thinkingTint: .systemBlue,
            supportedThinkingLevels: [.off, .high],
            colors: .placeholder,
            onModelTap: {},
            onThinkingSelect: { _ in },
            onSaveThinkingAsDefault: nil
        )
        content.actionRow = toolbar
        let screen = ComposerOwnerTestScreen(content: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }

        // The timeline text the user selected holds first responder.
        let selection = UITextView(frame: CGRect(x: 20, y: 100, width: 360, height: 200))
        selection.text = "Tap the mic so the bar gets stuck with the plus cut off on the left."
        selection.isEditable = false
        screen.view.addSubview(selection)
        screen.composer.setNeedsUpdateProperties()
        try await Task.sleep(for: .milliseconds(400))
        selection.becomeFirstResponder()
        selection.selectedRange = NSRange(location: 4, length: 20)
        try await Task.sleep(for: .milliseconds(300))

        // ChatViewController.handleReviewCommentSelection with startsDictation.
        screen.content.actionRow = ComposerActionRow(
            leading: QuickCommentTemplate.builtInDefaults.map { template in
                .reviewChip(
                    id: "chat.reviewComment.\(template.id.uuidString)",
                    title: template.title,
                    systemImage: template.systemImage,
                    onTap: {}
                )
            },
            trailing: [.reviewCancel {}],
            leadingScrolls: true
        )
        screen.content.placeholderOverride = "Comment…"
        screen.composer.setNeedsUpdateProperties()
        screen.composer.requestFocus()
        screen.composer.requestDictation(owner: .reviewCommentMenu)
        try await Task.sleep(for: .milliseconds(500))

        let attach = try #require(screen.view.firstDescendant { $0.accessibilityIdentifier == "chat.attach" })
        let row = try #require(attach.superview as? UIStackView)
        screen.view.layoutIfNeeded()
        #expect(!row.isHidden)
        let cancel = try #require(screen.view.firstDescendant {
            $0.accessibilityIdentifier == "chat.reviewComment.cancel"
        })
        expectInside(attach, row, "plus while commenting")
        expectInside(cancel, row, "Cancel while commenting")

        // Cancelling the comment returns the session toolbar.
        await screen.composer.stopVoice()
        screen.content.actionRow = toolbar
        screen.content.placeholderOverride = nil
        screen.composer.setNeedsUpdateProperties()
        try await Task.sleep(for: .milliseconds(500))
        screen.view.layoutIfNeeded()
        let thinking = try #require(screen.view.firstDescendant {
            $0.accessibilityIdentifier == "session.toolbar.thinking"
        })
        #expect(!row.isHidden)
        #expect(row.bounds.height >= 30, "the normal bar's row collapsed to \(row.bounds.height) pt")
        expectInside(attach, row, "plus after the comment")
        expectInside(thinking, row, "thinking pill after the comment")
    }

    private func expectInside(_ item: UIView, _ row: UIStackView, _ name: String) {
        let frame = item.convert(item.bounds, to: row)
        let lane = row.bounds.inset(by: UIEdgeInsets(
            top: 0,
            left: row.layoutMargins.left - 0.5,
            bottom: 0,
            right: row.layoutMargins.right - 0.5
        ))
        #expect(frame.width >= 20 && frame.minX >= lane.minX && frame.maxX <= lane.maxX, "\(name) at \(frame) in \(lane)")
    }
}

/// The chat screen's part in commenting: it feeds `ChatComposerOwner` the
/// bar's content the way `ChatViewController` does.
private extension UIView {
    func firstDescendant(where match: (UIView) -> Bool) -> UIView? {
        if match(self) { return self }
        for child in subviews {
            if let hit = child.firstDescendant(where: match) { return hit }
        }
        return nil
    }
}

@MainActor
private final class ComposerBarTestHost: ComposerBarHosting {
    var content = ComposerBarContent.testDefault()
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
    /// Delivered Ask responses; nil answers is Ignore. Completions run at once
    /// unless a test holds them to play delivery itself.
    var askDeliveries: [[String: AskAnswer]?] = []
    var holdsAskCompletions = false
    var heldAskCompletions: [AskResponseSubmission.Completion] = []
    func submitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) {
        askDeliveries.append(answers)
        if holdsAskCompletions { heldAskCompletions.append(completion) } else { completion(.completed) }
    }
    func ignoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {
        askDeliveries.append(nil)
        if holdsAskCompletions { heldAskCompletions.append(completion) } else { completion(.completed) }
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
