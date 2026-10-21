import UIKit

/// Builds the bar: the view tree, the text view, the action row, and the controls' wiring.
extension ComposerBarController {
    func buildHierarchy() {
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        capsuleStack.axis = .vertical
        capsuleStack.spacing = 0
        capsuleStack.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(capsuleStack)
        NSLayoutConstraint.activate([
            capsuleStack.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor),
            capsuleStack.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor),
            capsuleStack.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            capsuleStack.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
        ])

        let askHeight = askContainer.heightAnchor.constraint(equalToConstant: 0)
        askHeightConstraint = askHeight
        askHeight.isActive = true
        askContainer.isHidden = true
        askContainer.clipsToBounds = true

        textRow.axis = .horizontal
        textRow.alignment = .bottom
        textRow.spacing = 8
        textRow.isLayoutMarginsRelativeArrangement = true
        textRow.layoutMargins = UIEdgeInsets(
            top: 10,
            left: composerHorizontalPadding,
            bottom: 10,
            right: composerHorizontalPadding
        )

        let textContainer = UIView()
        placeholderLabel.numberOfLines = 0
        placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textContainer.addSubview(placeholderLabel)
        textContainer.addSubview(textView)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textContainer.topAnchor, constant: textVerticalInset),
            textView.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            textView.topAnchor.constraint(equalTo: textContainer.topAnchor),
            textView.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
        ])
        let textHeight = textView.heightAnchor.constraint(equalToConstant: oneLineTextHeight)
        textHeightConstraint = textHeight
        textHeight.isActive = true
        textContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // A one-line call status truncates; it must not squeeze the mic or End.
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)

        textRow.addArrangedSubview(micButton)
        textRow.addArrangedSubview(textContainer)
        textRow.addArrangedSubview(primaryButton)
        textRow.addArrangedSubview(endCallButton)
        micButton.setContentHuggingPriority(.required, for: .horizontal)
        primaryButton.setContentHuggingPriority(.required, for: .horizontal)
        endCallButton.setContentHuggingPriority(.required, for: .horizontal)
        endCallButton.isHidden = true

        let tipHeight = busyTipContainer.heightAnchor.constraint(equalToConstant: 0)
        busyTipHeightConstraint = tipHeight
        tipHeight.isActive = true
        busyTipContainer.isHidden = true
        busyTipContainer.clipsToBounds = true

        actionRowStack.axis = .horizontal
        actionRowStack.alignment = .center
        actionRowStack.spacing = 6
        actionRowStack.isLayoutMarginsRelativeArrangement = true
        actionRowStack.layoutMargins = UIEdgeInsets(
            top: 8,
            left: composerHorizontalPadding,
            bottom: 7,
            right: composerHorizontalPadding
        )
        let minHeight = actionRowStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        minHeight.priority = .defaultHigh
        actionRowMinHeight = minHeight
        minHeight.isActive = true

        leadingStack.axis = .horizontal
        leadingStack.alignment = .center
        leadingStack.spacing = 6
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingScroll.showsHorizontalScrollIndicator = false
        leadingScroll.alwaysBounceHorizontal = false
        leadingScroll.addSubview(leadingStack)
        NSLayoutConstraint.activate([
            leadingStack.leadingAnchor.constraint(equalTo: leadingScroll.contentLayoutGuide.leadingAnchor),
            leadingStack.trailingAnchor.constraint(equalTo: leadingScroll.contentLayoutGuide.trailingAnchor),
            leadingStack.topAnchor.constraint(equalTo: leadingScroll.contentLayoutGuide.topAnchor),
            leadingStack.bottomAnchor.constraint(equalTo: leadingScroll.contentLayoutGuide.bottomAnchor),
            leadingStack.heightAnchor.constraint(equalTo: leadingScroll.frameLayoutGuide.heightAnchor),
        ])
        // A scroll view has no intrinsic width, so beside the spacer its width is
        // ambiguous and Auto Layout may collapse it to zero, hiding every pill.
        // Prefer the pills' width; below the trailing stack's compression
        // resistance so a crowded row scrolls instead of squeezing Cancel.
        let leadingFitsContent = leadingScroll.frameLayoutGuide.widthAnchor.constraint(
            equalTo: leadingScroll.contentLayoutGuide.widthAnchor
        )
        leadingFitsContent.priority = UILayoutPriority(UILayoutPriority.defaultLow.rawValue - 1)
        leadingFitsContent.isActive = true
        trailingStack.axis = .horizontal
        trailingStack.alignment = .center
        trailingStack.spacing = 6
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        leadingScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyStripContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyStripContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keyHeight = keyStripContainer.heightAnchor.constraint(
            equalToConstant: ComposerInputMetrics.controlDiameter
        )
        keyStripHeightConstraint = keyHeight
        keyHeight.isActive = true
        keyStripContainer.isHidden = true

        actionRowStack.addArrangedSubview(attachButton)
        actionRowStack.addArrangedSubview(expandInActionRow)
        actionRowStack.addArrangedSubview(busyModeButton)
        actionRowStack.addArrangedSubview(keyStripContainer)
        actionRowStack.addArrangedSubview(leadingScroll)
        actionRowStack.addArrangedSubview(spacer)
        actionRowStack.addArrangedSubview(trailingStack)
        actionRowStack.addArrangedSubview(trailingAttachButton)
        attachButton.setContentHuggingPriority(.required, for: .horizontal)
        attachButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingAttachButton.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        embedStrip(attachmentStrip, in: attachmentStripWrapper, top: 8, bottom: 4)
        embedStrip(filePillStrip, in: filePillStripWrapper, top: 8, bottom: 4)

        capsuleStack.addArrangedSubview(askContainer)
        capsuleStack.addArrangedSubview(attachmentStripWrapper)
        capsuleStack.addArrangedSubview(filePillStripWrapper)
        capsuleStack.addArrangedSubview(textRow)
        capsuleStack.addArrangedSubview(busyTipContainer)
        capsuleStack.addArrangedSubview(actionRowStack)

        overlayExpand.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(overlayExpand)
        NSLayoutConstraint.activate([
            overlayExpand.topAnchor.constraint(equalTo: capsule.contentView.topAnchor, constant: 6),
            overlayExpand.trailingAnchor.constraint(
                equalTo: capsule.contentView.trailingAnchor,
                constant: -composerHorizontalPadding
            ),
            overlayExpand.widthAnchor.constraint(equalToConstant: ComposerInputMetrics.controlDiameter),
            overlayExpand.heightAnchor.constraint(equalToConstant: ComposerInputMetrics.controlDiameter),
        ])

        let capsuleMin = capsule.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        capsuleMin.priority = .defaultHigh
        capsuleMin.isActive = true

        for arranged in [forceStopButton, slashPanel, filePanel, sendProgressView, capsule] {
            rootStack.addArrangedSubview(arranged)
        }
        let minWidth = view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320)
        minWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            minWidth,
        ])

        slashPanel.onSelectSlash = { [weak self] command in
            self?.host?.insertSlashCommand(command)
            self?.applyChrome()
        }
        filePanel.onSelectFile = { [weak self] suggestion in
            self?.host?.insertFileSuggestion(suggestion)
            self?.applyChrome()
        }
        attachmentStrip.onAnnotate = { [weak self] attachment in
            self?.canvasBackgroundImage = ComposerShared.image(forPendingAttachment: attachment)
            self?.canvasReplacingAttachmentID = attachment.id
            self?.presentCanvas()
        }
        attachmentStrip.onRemove = { [weak self] id in
            self?.host?.removeAttachment(id: id)
            self?.applyChrome()
        }
        filePillStrip.onRemove = { [weak self] id in
            self?.host?.removeRepoPointer(id: id)
            self?.applyChrome()
        }
        failureView.onRetry = { [weak self] in
            self?.handleMicTap()
        }
    }

    private func embedStrip(_ view: UIView, in wrapper: UIView, top: CGFloat, bottom: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: composerHorizontalPadding),
            view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -composerHorizontalPadding),
            view.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -bottom),
        ])
    }

    func installTextView() {
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.clipsToBounds = true
        textView.textContainerInset = UIEdgeInsets(
            top: textVerticalInset,
            left: 0,
            bottom: textVerticalInset,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.isAccessibilityElement = true
        _ = textView.layoutManager
        textView.installKeyboardRestoreGesture()
        textView.onPasteImages = { [weak self] images in
            self?.host?.handlePastedImages(images)
        }
        textView.onCommandEnter = { [weak self] in self?.handleSend() }
        textView.onAlternateEnter = { [weak self] in self?.handleAlternateSend() }
        textView.onKeyboardRestoreRequest = { [weak self] in
            self?.host?.restoreKeyboardFromSuppression()
            self?.applyChrome()
        }
    }

    func installActions() {
        micButton.addAction(UIAction { [weak self] _ in self?.handleMicTap() }, for: .touchUpInside)
        micButton.menuProvider = { [weak self] in self?.voiceEntryMenu() }
        primaryButton.addAction(UIAction { [weak self] _ in self?.handlePrimaryAction() }, for: .touchUpInside)
        endCallButton.addAction(UIAction { [weak self] _ in
            self?.host?.content.liveVoiceCall?.onEnd()
        }, for: .touchUpInside)
        forceStopButton.addAction(UIAction { [weak self] _ in self?.host?.performForceStop() }, for: .touchUpInside)
        expandInActionRow.addAction(UIAction { [weak self] _ in self?.host?.performExpand() }, for: .touchUpInside)
        overlayExpand.addAction(UIAction { [weak self] _ in self?.host?.performExpand() }, for: .touchUpInside)
        busyModeButton.addAction(UIAction { [weak self] _ in self?.presentBusyModePicker() }, for: .touchUpInside)
        configureExpand(expandInActionRow)
        configureExpand(overlayExpand)
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.preferredMenuElementOrder = .priority
        attachButton.menu = attachmentMenu()
        trailingAttachButton.showsMenuAsPrimaryAction = true
        trailingAttachButton.preferredMenuElementOrder = .priority
        trailingAttachButton.menu = attachmentMenu()
        attachButton.accessibilityIdentifier = "chat.attach"
        attachButton.accessibilityLabel = "Add attachment"
        trailingAttachButton.accessibilityIdentifier = "chat.attach"
        trailingAttachButton.accessibilityLabel = "Add attachment"
        busyModeButton.accessibilityIdentifier = "chat.busyMode"
        busyModeButton.accessibilityLabel = "Busy send mode"
        primaryButton.accessibilityIdentifier = "chat.send"
        endCallButton.accessibilityIdentifier = ComposerLiveVoiceCall.endIdentifier
        endCallButton.accessibilityLabel = "End call"
        expandInActionRow.accessibilityIdentifier = "chat.expand"
        overlayExpand.accessibilityIdentifier = "chat.expand"
    }

    private func configureExpand(_ button: UIButton) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "arrow.up.left.and.arrow.down.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        config.contentInsets = .zero
        button.configuration = config
        button.accessibilityLabel = "Expand composer"
        button.accessibilityHint = "Opens the full-screen message editor"
    }

    private func embed(_ child: UIViewController?, in container: UIView, stored: inout UIViewController?) {
        if stored === child { return }
        stored?.willMove(toParent: nil)
        stored?.view.removeFromSuperview()
        stored?.removeFromParent()
        stored = child
        guard let child else { return }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.backgroundColor = .clear
        container.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: container.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }
}
