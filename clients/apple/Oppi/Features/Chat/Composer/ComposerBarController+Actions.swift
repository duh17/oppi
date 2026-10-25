import UIKit

/// Derived send state and the primary, send, alternate-send, and mic actions.
extension ComposerBarController {
    var composerDisplayText: String {
        guard let host else { return "" }
        return ComposerShared.currentComposerText(
            storedText: host.content.text,
            textBeforeRecording: host.content.textBeforeRecording,
            manager: host.content.voiceInputManager,
            owner: .inlineComposer
        )
    }

    var canSend: Bool {
        guard let host else { return false }
        if host.content.askRequest != nil {
            return pendingAskSendTransition != nil
        }
        return ComposerPolicy.canSubmitMessage(
            allowsEmptySubmit: host.content.allowsEmptySubmit,
            text: composerDisplayText,
            hasImages: host.content.pendingAttachments.contains { $0.source == .image },
            hasFiles: host.content.pendingAttachments.contains { $0.source != .image }
                || !host.content.pendingRepoPointers.isEmpty,
            hasReviewComments: host.content.pendingReviewCommentCount > 0
        )
    }

    var isSendInFlight: Bool {
        (host?.content.isSending ?? false) || isFinishingVoiceBeforeSend
    }

    /// A call's live transcript while the user is talking; nil when the draft shows.
    var callTranscript: String? {
        guard let transcript = host?.content.liveVoiceCall?.transcript, !transcript.isEmpty else { return nil }
        return transcript
    }

    func handlePrimaryAction() {
        guard let host else { return }
        switch ComposerPolicy.primaryActionKind(
            isBusy: host.content.isBusy,
            canSend: canSend,
            isSending: isSendInFlight,
            hasAskRequest: host.content.askRequest != nil
        ) {
        case .send:
            handleSend()
        case .ignoreAsk:
            guard let askRequest = host.content.askRequest else { return }
            submitAskResponse(request: askRequest, answers: nil)
        case .stop:
            host.performStop()
        }
    }

    func handleSend() {
        // While the user talks the field shows their words, not the draft Send would send.
        guard !isSendInFlight, callTranscript == nil else { return }
        if let manager = host?.content.voiceInputManager,
           ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer),
           manager.isRecording || manager.isPreparing {
            isFinishingVoiceBeforeSend = true
            let wasSuppressed = host?.content.suppressKeyboard ?? false
            let voiceState = manager.state
            Task { @MainActor in
                await self.host?.finishVoiceBeforeSubmit()
                self.host?.setSuppressKeyboard(
                    ComposerPolicy.suppressKeyboardAfterSend(
                        voiceState: voiceState,
                        wasSuppressed: wasSuppressed
                    )
                )
                self.isFinishingVoiceBeforeSend = false
                self.submitCurrentComposerAction()
            }
            return
        }
        submitCurrentComposerAction()
    }

    private func submitCurrentComposerAction() {
        if handleAskComposerSendIfNeeded() {
            return
        }
        if let askRequest = host?.content.askRequest {
            submitAskResponse(request: askRequest, answers: nil)
            return
        }
        if host?.content.isBusy == true {
            FeatureEducationTips.markBusySendModeUsed()
        }
        host?.performSend()
    }

    func handleAlternateSend() {
        guard !isSendInFlight else { return }
        if host?.content.isBusy == true {
            host?.setBusyStreamingBehavior(.followUp)
            FeatureEducationTips.markBusySendModeUsed()
        }
        handleSend()
    }

    func handleMicTap() {
        if let call = host?.content.liveVoiceCall {
            call.onToggleMute()
            return
        }
        if host?.content.voiceInputManager == nil, host?.content.onLiveVoiceSelected != nil {
            handleLiveVoiceChoice()
            return
        }
        Task {
            guard let manager = host?.content.voiceInputManager else { return }
            guard ComposerShared.canControlVoiceInput(manager, owner: .inlineComposer) else { return }
            switch ComposerShared.micTapAction(for: manager.state) {
            case .stop:
                await host?.stopVoice()
            case .cancelPreparing:
                await host?.cancelVoice()
                applyChrome()
            case .start:
                await startVoice(owner: .inlineComposer)
            case .ignore:
                break
            }
        }
    }

    func startVoice(owner: ComposerShared.VoiceInputOwner) async {
        guard let host else { return }
        do {
            try await host.startVoice(
                keyboardLanguage: host.content.keyboardLanguage,
                owner: owner,
                baseText: host.content.text
            )
            applyChrome()
        } catch is CancellationError {
        } catch {
            presentAlert(title: "Couldn't Start Dictation", message: error.localizedDescription)
        }
    }
}
