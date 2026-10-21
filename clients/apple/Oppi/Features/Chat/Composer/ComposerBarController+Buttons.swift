import UIKit

/// The send, End call, and mic slots, plus the Live Voice entry points.
extension ComposerBarController {
    func applyPrimaryButton(content: ComposerBarContent, colors: ComposerThemeColors) {
        let canSend = self.canSend
        let inFlight = isSendInFlight
        let kind = ComposerPolicy.primaryActionKind(
            isBusy: content.isBusy,
            canSend: canSend,
            isSending: inFlight,
            hasAskRequest: content.askRequest != nil
        )
        let submitted = isCurrentAskSubmitted
        switch kind {
        case .send:
            let fill: UIColor
            if inFlight {
                fill = content.isBusy ? colors.purple : colors.blue
            } else {
                fill = canSend ? (content.isBusy ? colors.purple : colors.blue) : colors.bgHighlight
            }
            let stroke = (canSend || inFlight) ? fill.withAlphaComponent(0.9) : colors.comment.withAlphaComponent(0.35)
            let foreground: UIColor
            if canSend || inFlight {
                foreground = ComposerColorContrast.foreground(for: fill, fg: colors.fg, bg: colors.bg)
            } else {
                foreground = colors.comment
            }
            primaryButton.apply(
                systemImage: "arrow.up",
                fill: fill,
                stroke: stroke,
                foreground: foreground,
                showsProgress: inFlight
            )
            primaryButton.isEnabled = canSend && !inFlight && !submitted
            primaryButton.accessibilityIdentifier = content.sendAccessibilityIdentifier
            primaryButton.accessibilityLabel = inFlight ? "Sending" : "Send"
        case .ignoreAsk:
            primaryButton.apply(
                systemImage: "xmark",
                fill: colors.bgHighlight,
                stroke: colors.comment.withAlphaComponent(0.35),
                foreground: colors.comment,
                showsProgress: false,
                symbol: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            )
            primaryButton.isEnabled = !submitted
            primaryButton.accessibilityIdentifier = "chat.askIgnore"
            primaryButton.accessibilityLabel = "Ignore request"
            primaryButton.accessibilityHint = "Responds to the current extension request as ignored"
        case .stop:
            let fill = content.isStopping ? colors.orange : colors.red
            let foreground = ComposerColorContrast.foreground(for: fill, fg: colors.fg, bg: colors.bg)
            primaryButton.apply(
                systemImage: "stop.fill",
                fill: fill,
                stroke: fill.withAlphaComponent(0.9),
                foreground: foreground,
                showsProgress: content.isStopping,
                diameter: ComposerInputMetrics.controlDiameter + 2,
                symbol: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            )
            primaryButton.isEnabled = !content.isStopping
            primaryButton.accessibilityIdentifier = "chat.stop"
            primaryButton.accessibilityLabel = content.isStopping ? "Stopping" : "Stop response"
        }
        applyCallButtons(content: content, colors: colors, kind: kind, canSend: canSend, inFlight: inFlight)
    }

    /// During a call End holds the send slot. Send joins it for a typed draft and Ignore for
    /// an Ask card; Stop and the empty Send stay out so End is the one red button.
    private func applyCallButtons(
        content: ComposerBarContent,
        colors: ComposerThemeColors,
        kind: ComposerPrimaryActionKind,
        canSend: Bool,
        inFlight: Bool
    ) {
        guard content.liveVoiceCall != nil else {
            primaryButton.setHiddenIfChanged(false)
            endCallButton.setHiddenIfChanged(true)
            return
        }
        switch kind {
        case .send:
            primaryButton.setHiddenIfChanged(!(canSend || inFlight) || callTranscript != nil)
        case .ignoreAsk:
            primaryButton.setHiddenIfChanged(false)
        case .stop:
            primaryButton.setHiddenIfChanged(true)
        }
        endCallButton.setHiddenIfChanged(false)
        endCallButton.apply(
            systemImage: "phone.down.fill",
            fill: colors.red,
            stroke: colors.red.withAlphaComponent(0.9),
            foreground: ComposerColorContrast.foreground(for: colors.red, fg: colors.fg, bg: colors.bg),
            showsProgress: false,
            symbol: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        )
    }

    func applyMicChrome() {
        if let call = host?.content.liveVoiceCall, let colors = host?.content.colors {
            applyCallMicChrome(call, colors: colors)
            return
        }
        micButton.setLiveSpectrumSource(nil)
        micButton.accessibilityIdentifier = "chat.voiceInput"
        guard let host, let manager = host.content.voiceInputManager else {
            micButton.setHiddenIfChanged(true)
            return
        }
        micButton.setHiddenIfChanged(false)
        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .inlineComposer)
        let accent = host.content.isBusy ? host.content.colors.purple : host.content.colors.blue
        micButton.apply(
            presentation: presentation,
            accentColor: accent,
            diameter: ComposerInputMetrics.controlDiameter
        )
        micButton.isEnabled = presentation.isEnabled
        micButton.accessibilityLabel = presentation.accessibilityLabel
        micButton.accessibilityValue = presentation.accessibilityValue
        let offersLiveVoice = host.content.onLiveVoiceSelected != nil
        micButton.isContextMenuInteractionEnabled = offersLiveVoice
        // VoiceOver reaches the same owner action as the long-press menu.
        micButton.accessibilityCustomActions = offersLiveVoice
            ? [UIAccessibilityCustomAction(name: "Live Voice") { [weak self] _ in
                self?.handleLiveVoiceChoice()
                return true
            }]
            : nil
    }

    /// The dictation ring or orb, following the user's mic while they have the floor and the
    /// agent's voice, in the agent's color, while its reply plays. A tap mutes.
    private func applyCallMicChrome(_ call: ComposerLiveVoiceCall, colors: ComposerThemeColors) {
        micButton.setHiddenIfChanged(false)
        let hears = call.isLive && !call.isMuted
        let speaking = call.isSpeaking
        let meter = call.meter
        var source: (@MainActor () -> VoiceSpectrumFrame)?
        if hears, !call.isConnecting {
            source = {
                let levels = meter.current
                return speaking ? levels.playback : levels.mic
            }
        }
        micButton.setLiveSpectrumSource(source)
        micButton.apply(
            isRecording: hears && !call.isConnecting,
            isProcessing: false,
            voiceSpectrum: .zero,
            languageLabel: nil,
            accentColor: speaking ? colors.purple : colors.blue,
            engineBadge: .onDevice,
            diameter: ComposerInputMetrics.controlDiameter,
            isPreparing: hears && call.isConnecting,
            isMuted: call.isMuted,
            listeningSymbol: "waveform"
        )
        micButton.isEnabled = call.isLive
        micButton.accessibilityIdentifier = ComposerLiveVoiceCall.muteIdentifier
        micButton.accessibilityLabel = call.isMuted ? "Unmute" : "Mute"
        micButton.accessibilityValue = call.isMuted ? "Muted" : call.status
        micButton.isContextMenuInteractionEnabled = false
        micButton.accessibilityCustomActions = nil
    }

    func voiceEntryMenu() -> UIMenu? {
        guard host?.content.onLiveVoiceSelected != nil else { return nil }
        return ComposerShared.voiceEntryMenu(
            identifierPrefix: "chat",
            onLiveVoice: { [weak self] in self?.handleLiveVoiceChoice() },
            onDictation: { [weak self] in self?.handleMicTap() }
        )
    }

    /// Live Voice owns the microphone, so an in-progress dictation take ends first.
    private func handleLiveVoiceChoice() {
        Task {
            await ComposerShared.stopDictationBeforeLiveVoice(manager: host?.content.voiceInputManager)
            applyChrome()
            host?.content.onLiveVoiceSelected?()
        }
    }

    @objc func themeDidChange() {
        applyChrome()
    }
}
