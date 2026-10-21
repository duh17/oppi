import UIKit

/// Fills the built bar from the host's content: chrome, pills, and their popovers.
extension ComposerBarController {
    func applyChrome() {
        guard let host else { return }
        let content = host.content
        let colors = content.colors
        let padding = content.appliesOuterPadding ? UIEdgeInsets(top: 0, left: 16, bottom: 8, right: 16) : .zero
        rootStack.isLayoutMarginsRelativeArrangement = true
        rootStack.layoutMargins = padding

        capsule.apply(colors: colors)
        let context = ComposerAutocomplete.context(for: content.text, isBusy: content.isBusy)
        let slash: [SlashCommand]
        if case .slash(let query) = context {
            slash = ComposerAutocomplete.slashSuggestions(query: query, commands: content.slashCommands)
        } else {
            slash = []
        }
        slashPanel.apply(content: slash.isEmpty ? .empty : .slash(slash), colors: colors)
        let showFiles = !content.fileSuggestions.isEmpty && {
            if case .atFile = context { return true }
            return false
        }()
        filePanel.apply(
            content: showFiles ? .files(content.fileSuggestions) : .empty,
            colors: colors
        )

        sendProgressView.apply(text: content.sendProgressText, isSending: content.isSending, colors: colors)
        if let failure = ComposerShared.captureFailure(content.voiceInputManager, owner: .inlineComposer) {
            failureView.apply(message: failure.message, colors: colors)
            failureView.setHiddenIfChanged(false)
        } else {
            failureView.setHiddenIfChanged(true)
        }
        forceStopButton.setHiddenIfChanged(!content.showForceStop)
        forceStopButton.apply(isInFlight: content.isForceStopInFlight, colors: colors)

        attachmentStrip.apply(
            attachments: content.pendingAttachments,
            colors: colors,
            allowsMutation: !content.isSending
        )
        attachmentStripWrapper.setHiddenIfChanged(content.pendingAttachments.isEmpty)
        filePillStrip.apply(pointers: content.pendingRepoPointers, colors: colors)
        filePillStripWrapper.setHiddenIfChanged(content.pendingRepoPointers.isEmpty)

        let showActionRow = ComposerPolicy.shouldShowComposerActionRow(
            alwaysShowActionRow: content.alwaysShowActionRow,
            isBusy: content.isBusy,
            isInputFocused: isInputFocused,
            isKeyboardSuppressed: content.suppressKeyboard,
            hasAttachments: !content.pendingAttachments.isEmpty,
            hasRepoPointers: !content.pendingRepoPointers.isEmpty
        ) && content.showsAccessoryRow
        applyActionRowVisibility(showActionRow, minimumHeight: content.actionRowMinimumHeight, reduceMotion: content.reduceMotion)

        let showsBusy = ComposerPolicy.showsBusyModeSelector(
            isBusy: content.isBusy,
            hasAskRequest: content.askRequest != nil
        )
        busyModeButton.setHiddenIfChanged(!showsBusy || !showActionRow)
        if !showsBusy {
            // A tip shows once; each busy turn starts at zero until its tip
            // reports a height, so a tip left up by the last turn holds no space.
            busyTipNaturalHeight = 0
        }
        let tipHeight: CGFloat = showsBusy ? busyTipNaturalHeight : 0
        busyTipHeightConstraint?.constant = tipHeight
        busyTipContainer.setHiddenIfChanged(tipHeight <= 0)
        busyModeButton.apply(
            title: content.busyStreamingBehavior == .steer ? "Steering" : "Follow-up",
            systemImage: nil,
            colors: colors,
            chevron: true
        )
        busyModeButton.accessibilityValue = content.busyStreamingBehavior == .steer ? "Steering" : "Follow-up"

        let leadingAttach = content.allowsAttachments && content.attachmentButtonPlacement == .leading
        let trailingAttach = content.allowsAttachments && content.attachmentButtonPlacement == .trailing
        attachButton.setHiddenIfChanged(!leadingAttach || !showActionRow)
        trailingAttachButton.setHiddenIfChanged(!trailingAttach || !showActionRow)
        attachButton.isEnabled = !content.isSending
        trailingAttachButton.isEnabled = !content.isSending
        attachButton.apply(title: nil, systemImage: "plus", colors: colors, symbolPointSize: 11)
        trailingAttachButton.apply(title: nil, systemImage: "plus", colors: colors, symbolPointSize: 11)

        overlayExpand.tintColor = colors.comment
        expandInActionRow.tintColor = colors.comment

        let keyHeight = content.keyStripHeight
        keyStripHeightConstraint?.constant = keyHeight
        keyStripContainer.setHiddenIfChanged(keyHeight <= 0 || !showActionRow)
        spacer.setHiddenIfChanged(keyHeight > 0)

        applyActionPills(content.actionRow, colors: colors, showActionRow: showActionRow)
        // Buttons first: the draft's width depends on which of them show.
        applyPrimaryButton(content: content, colors: colors)
        applyMicChrome()
        applyTextView(content: content, colors: colors)
        refreshPresentedPopover(content.actionRow)

        refreshAskCard()
        applyAskViewport()
    }

    private func applyActionRowVisibility(_ showActionRow: Bool, minimumHeight: CGFloat, reduceMotion: Bool) {
        // The row hugs its pills unless the surface asks for a taller row.
        let minHeight = showActionRow ? minimumHeight : 0
        let visibilityChanged = lastShowActionRow.map { $0 != showActionRow } ?? false
        lastShowActionRow = showActionRow
        // The flag flips at once; only the resulting layout animates.
        actionRowStack.setHiddenIfChanged(!showActionRow)
        actionRowMinHeight?.constant = minHeight
        if visibilityChanged, !reduceMotion {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                animations: { self.actionRowStack.layoutIfNeeded() }
            )
        }
    }

    private func applyActionPills(_ row: ComposerActionRow, colors: ComposerThemeColors, showActionRow: Bool) {
        leadingScroll.isScrollEnabled = row.leadingScrolls
        fill(leadingStack, actions: row.leading, colors: colors)
        fill(trailingStack, actions: row.trailing, colors: colors)
        leadingScroll.setHiddenIfChanged(row.leading.isEmpty || !showActionRow)
        trailingStack.setHiddenIfChanged(row.trailing.isEmpty || !showActionRow)
        let keep = Set((row.leading + row.trailing).map(\.id))
        for (id, view) in pillViews where !keep.contains(id) {
            if isPresentedSource(view) { continue }
            view.removeFromSuperview()
            pillViews[id] = nil
        }
    }

    func fill(_ stack: UIStackView, actions: [ComposerAction], colors: ComposerThemeColors) {
        let next = actions.map { pillView(for: $0, colors: colors) }
        for view in stack.arrangedSubviews {
            if next.contains(where: { $0 === view }) { continue }
            if isPresentedSource(view) { continue }
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in next.enumerated() {
            if index < stack.arrangedSubviews.count, stack.arrangedSubviews[index] === view {
                continue
            }
            if view.superview === stack {
                stack.removeArrangedSubview(view)
                stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
            } else if view.superview != nil {
                if isPresentedSource(view) { continue }
                view.removeFromSuperview()
                stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
            } else {
                stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
            }
        }
    }

    private func isPresentedSource(_ view: UIView) -> Bool {
        guard presentedPicker != nil, let presentedActionID else { return false }
        return pillViews[presentedActionID] === view
    }

    private func pillView(for action: ComposerAction, colors: ComposerThemeColors) -> UIView {
        let tint = action.tint ?? colors.fg
        let icon = image(for: action.icon, tint: tint)
        if let existing = pillViews[action.id] {
            configure(existing, action: action, icon: icon, tint: tint, colors: colors)
            return existing
        }
        let view: UIView
        switch action.chrome {
        case .toolbar:
            let button = ComposerToolbarPillButton()
            view = button
        case .chip:
            let button = ComposerActionChipButton()
            view = button
        case .cancel:
            let button = ComposerActionCancelButton()
            view = button
        }
        view.accessibilityIdentifier = action.id
        pillViews[action.id] = view
        configure(view, action: action, icon: icon, tint: tint, colors: colors)
        bindAction(view, id: action.id, kind: action.kind)
        return view
    }

    private func configure(
        _ view: UIView,
        action: ComposerAction,
        icon: UIImage?,
        tint: UIColor,
        colors: ComposerThemeColors
    ) {
        view.accessibilityLabel = action.accessibilityLabel
        view.accessibilityValue = action.accessibilityValue ?? ""
        switch action.chrome {
        case .toolbar:
            let button = view as? ComposerToolbarPillButton
            button?.apply(
                title: action.title,
                icon: icon,
                tint: tint,
                showsChevron: action.showsChevron,
                colors: colors
            )
        case .chip:
            (view as? ComposerActionChipButton)?.apply(
                title: action.title,
                systemImage: symbolName(action.icon),
                colors: colors
            )
        case .cancel:
            (view as? ComposerActionCancelButton)?.apply(colors: colors)
        }
        if let button = view as? UIButton, case .menu(let menu) = action.kind {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        }
    }

    private func bindAction(_ view: UIView, id: String, kind: ComposerAction.Kind) {
        guard let button = view as? UIButton else { return }
        switch kind {
        case .tap, .picker:
            button.showsMenuAsPrimaryAction = false
            button.addAction(UIAction { [weak self] _ in
                self?.performAction(id: id)
            }, for: .touchUpInside)
        case .menu:
            break
        }
    }

    private func performAction(id: String) {
        let actions = (host?.content.actionRow.leading ?? []) + (host?.content.actionRow.trailing ?? [])
        guard let action = actions.first(where: { $0.id == id }) else { return }
        switch action.kind {
        case .tap(let handler):
            handler.run()
        case .picker:
            presentActionPopover(id: id)
        case .menu:
            break
        }
    }

    func image(for icon: ComposerAction.Icon?, tint: UIColor) -> UIImage? {
        switch icon {
        case .image(let image):
            return image
        case .symbol(let name):
            let configuration = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            return UIImage(systemName: name, withConfiguration: configuration)?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
        case .monogram(let text):
            return renderMonogram(text, tint: tint)
        case nil:
            return nil
        }
    }

    private func symbolName(_ icon: ComposerAction.Icon?) -> String? {
        if case .symbol(let name) = icon { return name }
        return nil
    }

    private func renderMonogram(_ text: String, tint: UIColor) -> UIImage {
        let size: CGFloat = 11
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.8, weight: .heavy),
                .foregroundColor: tint,
            ]
            let string = text as NSString
            let textSize = string.size(withAttributes: attributes)
            string.draw(
                at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }
}
