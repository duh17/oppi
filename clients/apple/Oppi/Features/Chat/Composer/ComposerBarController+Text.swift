import UIKit

/// The draft's text view: its styled content, focus, and measured height.
extension ComposerBarController {
    func applyTextView(content: ComposerBarContent, colors: ComposerThemeColors) {
        // A call's live transcript stands in for the draft until it is sent; the draft
        // comes back when the user stops talking.
        let transcript = callTranscript
        let visible = transcript ?? ComposerShared.visibleComposerText(composerDisplayText)
        let callStatus = content.askRequest == nil && content.placeholderOverride == nil
            ? content.liveVoiceCall?.status
            : nil
        placeholderLabel.text = callStatus ?? content.placeholderOverride ?? ComposerPolicy.composerPlaceholder(
            askRequest: content.askRequest,
            pendingReviewCommentCount: content.pendingReviewCommentCount,
            isBusy: content.isBusy,
            busyStreamingBehavior: content.busyStreamingBehavior
        )
        // A long status (an approval, the agent's progress) stays on the draft's line.
        placeholderLabel.numberOfLines = callStatus == nil ? 0 : 1
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.accessibilityIdentifier = content.liveVoiceCall == nil ? nil : ComposerLiveVoiceCall.stateIdentifier
        placeholderLabel.textColor = colors.comment
        placeholderLabel.isHidden = !visible.isEmpty
        let accent = content.isBusy ? colors.purple : colors.blue
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.tintColor = accent
        textView.accessibilityIdentifier = content.inputAccessibilityIdentifier
        applyComposerInputTraits(to: textView, autocorrectionEnabled: content.autocorrectionEnabled)
        textView.applyStyledText(
            visible,
            font: UIFont.preferredFont(forTextStyle: .body),
            baseColor: colors.fg,
            // The whole transcript is still being heard; it reads like dictation's live words.
            volatileSuffixLength: transcript?.count
                ?? ComposerShared.volatileSuffixLength(
                    manager: content.voiceInputManager,
                    owner: .inlineComposer
                ),
            volatileColor: transcript == nil ? accent : colors.blue,
            volatileBackgroundColor: (transcript == nil ? accent : colors.blue).withAlphaComponent(0.20),
            correctionRanges: transcript == nil
                ? ComposerShared.correctionRanges(
                    manager: content.voiceInputManager,
                    textBeforeRecording: content.textBeforeRecording,
                    owner: .inlineComposer
                )
                : [],
            correctionUnderlineColor: colors.orange,
            scrollCaretToVisible: true
        )
        let allowRestore = ComposerPolicy.allowKeyboardRestoreOnTap(
            voiceState: content.voiceInputManager?.state ?? .idle
        )
        if textView.allowsKeyboardRestoreOnTap != allowRestore {
            textView.setAllowKeyboardRestoreOnTap(allowRestore)
        }
        if textView.isKeyboardSuppressed != content.suppressKeyboard {
            textView.setKeyboardSuppressed(content.suppressKeyboard)
        }
        attemptFocusIfRequested()
        applyTextLayout(proposedWidth: view.bounds.width)
    }

    func attemptFocusIfRequested() {
        guard let host, host.content.focusRequestID != 0 else { return }
        guard textView.window != nil else { return }
        if !textView.isFirstResponder {
            guard textView.becomeFirstResponder() else { return }
        }
        textView.moveCaretToEnd()
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.host, host.content.focusRequestID != 0 else { return }
            guard self.textView.isFirstResponder else { return }
            host.consumeFocusRequest()
        }
    }

    /// One line of body text plus its insets: the draft's resting height.
    var oneLineTextHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight + textVerticalInset * 2)
    }

    /// Measures the draft as laid out at `proposedWidth`, then sizes the text
    /// view and shows the expand control from that one measurement. Typed,
    /// dictated, pasted, and restored text all pass through here, so each
    /// reaches the expand threshold the same way.
    func applyTextLayout(proposedWidth: CGFloat) {
        guard let host else { return }
        let content = host.content
        let maxLines = ComposerPolicy.inlineTextMaxLines(
            hasAskRequest: content.askRequest != nil,
            hasAttachments: !content.pendingAttachments.isEmpty,
            hasRepoPointers: !content.pendingRepoPointers.isEmpty
        )
        let outer: CGFloat = content.appliesOuterPadding ? 32 : 0
        let rowPad: CGFloat = composerHorizontalPadding * 2
        let showsMic = !micButton.isHidden
        let mic: CGFloat = showsMic ? ComposerInputMetrics.controlDiameter + 8 : 0
        let trailingButtons = [primaryButton, endCallButton].filter { !$0.isHidden }.count
        let send = CGFloat(trailingButtons) * (ComposerInputMetrics.controlDiameter + 8)
        let textWidth = proposedWidth - outer - rowPad - mic - send
        // Before the first layout pass the bar has no width; SwiftUI measures
        // it again at a real width.
        guard textWidth > ComposerInputMetrics.controlDiameter else { return }

        // Count lines without the expand gutter so showing the control cannot
        // re-wrap the draft back under the threshold.
        textView.textContainerInset.right = 0
        var growth = ComposerInputMetrics.textViewGrowth(
            for: textView,
            fittingWidth: textWidth,
            minHeight: oneLineTextHeight,
            maxLines: maxLines
        )
        let lineHeight = max(textView.font?.lineHeight ?? 17, 1)
        let lines = (growth.height - textVerticalInset * 2) / lineHeight
        inlineVisualLineCount = max(1, Int(lines + 0.05))
        let showsExpand = ComposerPolicy.shouldShowExpandButton(
            allowsExpansion: content.allowsExpansion,
            visualLineCount: inlineVisualLineCount,
            threshold: expandVisibilityLineThreshold,
            maxLines: maxLines
        )
        overlayExpand.isHidden = !(showsExpand && content.askRequest == nil)
        expandInActionRow.setHiddenIfChanged(!(showsExpand && content.askRequest != nil && lastShowActionRow == true))
        if showsExpand {
            textView.textContainerInset.right = ComposerPolicy.composerTextTrailingPadding(showsExpandButton: true)
            growth = ComposerInputMetrics.textViewGrowth(
                for: textView,
                fittingWidth: textWidth,
                minHeight: oneLineTextHeight,
                maxLines: maxLines
            )
        }
        if textHeightConstraint?.constant != growth.height {
            textHeightConstraint?.constant = growth.height
        }
        textView.isScrollEnabled = growth.isScrollEnabled
    }
}
