import Observation
import SwiftUI
import UIKit

extension ReviewCommentSurfaceKind {
    var reviewCommentReferenceSource: ReviewCommentReferenceSource {
        switch self {
        case .fullScreenDiff:
            return .gitDiff
        case .fullScreenCode, .fullScreenSource, .fullScreenMarkdown:
            return .file
        case .toolCommand, .toolOutput, .toolExpandedText, .fullScreenTerminal:
            return .toolOutput
        case .assistantProse, .userMessage, .assistantCodeBlock, .assistantTable, .thinking, .fullScreenThinking:
            return .timelineText
        }
    }
}

extension ReviewCommentSourceContext {
    var reviewCommentReferenceSource: ReviewCommentReferenceSource {
        surface.reviewCommentReferenceSource
    }
}

// MARK: - Inline Draft Composer

@MainActor
enum ReviewCommentInlineDraftPresenter {
    private static weak var activeView: ReviewCommentInlineDraftView?

    static func present(
        textView: UITextView,
        selectedRange: NSRange,
        request: ReviewCommentSelectionRequest,
        router: ReviewCommentSelectionRouter
    ) {
        let anchorRect = selectionRect(in: textView, range: selectedRange)
            ?? CGRect(x: textView.bounds.midX, y: textView.bounds.midY, width: 1, height: 1)
        clearSelection(in: textView, range: selectedRange)
        present(
            sourceView: textView,
            anchorRect: anchorRect,
            request: request,
            router: router
        )
    }

    static func present(
        sourceView: UIView,
        anchorRect: CGRect? = nil,
        request: ReviewCommentSelectionRequest,
        router: ReviewCommentSelectionRouter
    ) {
        guard router.supportsInlineCommentComposer,
              let hostView = hostView(for: sourceView) else {
            router.dispatch(request, presentingViewController: nearestViewController(from: sourceView))
            return
        }

        activeView?.dismiss(animated: false)

        let rect = anchorRect ?? CGRect(
            x: sourceView.bounds.midX,
            y: min(sourceView.bounds.midY, sourceView.bounds.minY + 180),
            width: 1,
            height: 1
        )
        let composer = ReviewCommentInlineDraftView(
            request: request,
            router: router,
            quickComments: router.inlineQuickComments,
            sourceView: sourceView,
            anchorRect: rect
        )
        activeView = composer
        composer.present(in: hostView)
    }

    private static func hostView(for sourceView: UIView) -> UIView? {
        if let controller = nearestViewController(from: sourceView) {
            return controller.view
        }
        return sourceView.window
    }

    private static func nearestViewController(from responder: UIResponder) -> UIViewController? {
        var current: UIResponder? = responder
        while let node = current {
            if let controller = node as? UIViewController {
                return controller
            }
            current = node.next
        }
        return nil
    }

    private static func clearSelection(in textView: UITextView, range: NSRange) {
        let collapseLocation = max(0, min(range.location, textView.textStorage.length))
        textView.selectedRange = NSRange(location: collapseLocation, length: 0)
        textView.resignFirstResponder()
    }

    private static func selectionRect(in textView: UITextView, range: NSRange) -> CGRect? {
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textView.textStorage.length else {
            return nil
        }

        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return nil }

        var lineRect: CGRect?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, stop in
            lineRect = usedRect
            stop.pointee = true
        }

        guard var rect = lineRect else { return nil }
        rect.origin.x += textView.textContainerInset.left
        rect.origin.y += textView.textContainerInset.top
        rect = rect.offsetBy(dx: -textView.contentOffset.x, dy: -textView.contentOffset.y)
        return rect.integral
    }
}

final class ReviewCommentInlineDraftView: UIView, UITextViewDelegate {
    private weak var hostView: UIView?
    private weak var sourceView: UIView?
    private let request: ReviewCommentSelectionRequest
    private let router: ReviewCommentSelectionRouter
    private let quickComments: [QuickCommentTemplate]
    private let anchorRect: CGRect
    private var keyboardFrameInHost: CGRect?
    private var isObservingKeyboard = false
    private var isSaving = false

    private let stackView = UIStackView()
    private let inputRow = UIStackView()
    private let micButton = MicButtonChromeView()
    private let inputTextView = ReviewCommentInlineInputTextView()
    private let quickScrollView = UIScrollView()
    private let quickStack = UIStackView()
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private var inputTextHeightConstraint: NSLayoutConstraint?
    private var textBeforeRecording: String?
    private var suppressKeyboard = false
    private var isObservingVoiceInput = false
    private var isTornDown = false
    private var lastAppliedDictationText: String?
    private var lastAppliedDictationRevision = -1

    private let inputMinHeight = ComposerInputMetrics.inlineTextMinHeight
    private let controlDiameter = ComposerInputMetrics.controlDiameter

    init(
        request: ReviewCommentSelectionRequest,
        router: ReviewCommentSelectionRouter,
        quickComments: [QuickCommentTemplate],
        sourceView: UIView,
        anchorRect: CGRect
    ) {
        self.request = request
        self.router = router
        self.quickComments = quickComments
        self.sourceView = sourceView
        self.anchorRect = anchorRect
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        teardown(cancelOwnedVoiceInput: true)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            teardown(cancelOwnedVoiceInput: true)
        }
    }

    func present(in hostView: UIView) {
        self.hostView = hostView
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        hostView.addSubview(self)
        updateFrame(animated: false)
        hostView.bringSubviewToFront(self)
        observeKeyboard()
        observeVoiceInput()

        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.alpha = 1
            self.transform = .identity
        }

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.inputTextView.becomeFirstResponder()
        }
    }

    func dismiss(animated: Bool = true) {
        teardown(cancelOwnedVoiceInput: true)

        let removal = {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        }
        let completion: (Bool) -> Void = { _ in
            self.removeFromSuperview()
        }

        if animated {
            UIView.animate(
                withDuration: 0.14,
                delay: 0,
                options: [.curveEaseIn, .allowUserInteraction],
                animations: removal,
                completion: completion
            )
        } else {
            removal()
            completion(true)
        }
    }

    private func teardown(cancelOwnedVoiceInput: Bool) {
        guard !isTornDown else { return }
        isTornDown = true
        isObservingVoiceInput = false
        inputTextView.resignFirstResponder()
        if cancelOwnedVoiceInput {
            cancelVoiceInputIfOwned()
        }
        if isObservingKeyboard {
            removeKeyboardObservers()
            isObservingKeyboard = false
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func setup() {
        accessibilityIdentifier = "review-comment.inline-composer"
        let palette = ThemeRuntimeState.currentPalette()
        backgroundColor = UIColor(palette.bgDark).withAlphaComponent(0.98)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(palette.cyan).withAlphaComponent(0.28).cgColor
        layer.shadowColor = UIColor(palette.bgDark).cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 20
        layer.shadowOffset = CGSize(width: 0, height: 10)

        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 8
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        configureCloseButton(palette: palette)
        configureQuickComments(palette: palette)
        configureInput(palette: palette)
        updateSaveButton()
        updateMicButton()
    }

    private func configureCloseButton(palette: ThemePalette) {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "xmark")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        config.baseForegroundColor = UIColor(palette.fg)
        config.baseBackgroundColor = UIColor(palette.bgHighlight).withAlphaComponent(0.78)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 7, bottom: 7, trailing: 7)
        closeButton.configuration = config
        closeButton.accessibilityIdentifier = "review-comment.inline-dismiss"
        closeButton.accessibilityLabel = "Dismiss comment"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addAction(UIAction { [weak self] _ in
            self?.dismiss()
        }, for: .touchUpInside)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func configureQuickComments(palette: ThemePalette) {
        guard !quickComments.isEmpty else { return }

        quickScrollView.showsHorizontalScrollIndicator = false
        quickScrollView.translatesAutoresizingMaskIntoConstraints = false
        quickStack.axis = .horizontal
        quickStack.alignment = .center
        quickStack.spacing = 8
        quickStack.translatesAutoresizingMaskIntoConstraints = false
        quickScrollView.addSubview(quickStack)

        NSLayoutConstraint.activate([
            quickStack.leadingAnchor.constraint(equalTo: quickScrollView.contentLayoutGuide.leadingAnchor),
            quickStack.trailingAnchor.constraint(equalTo: quickScrollView.contentLayoutGuide.trailingAnchor, constant: -40),
            quickStack.topAnchor.constraint(equalTo: quickScrollView.contentLayoutGuide.topAnchor),
            quickStack.bottomAnchor.constraint(equalTo: quickScrollView.contentLayoutGuide.bottomAnchor),
            quickStack.heightAnchor.constraint(equalTo: quickScrollView.frameLayoutGuide.heightAnchor),
            quickScrollView.heightAnchor.constraint(equalToConstant: 32),
        ])

        for template in quickComments {
            var config = UIButton.Configuration.filled()
            config.title = template.title
            config.image = UIImage(systemName: template.systemImage)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            config.imagePadding = 5
            config.baseForegroundColor = UIColor(palette.fg)
            config.baseBackgroundColor = UIColor(palette.bgHighlight).withAlphaComponent(0.72)
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            let button = UIButton(configuration: config)
            button.addAction(UIAction { [weak self, template] _ in
                self?.applyQuickComment(template)
            }, for: .touchUpInside)
            quickStack.addArrangedSubview(button)
        }

        stackView.addArrangedSubview(quickScrollView)
    }

    private func configureInput(palette: ThemePalette) {
        inputRow.axis = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 8
        inputRow.isLayoutMarginsRelativeArrangement = true
        inputRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        inputRow.backgroundColor = UIColor(palette.bg).withAlphaComponent(0.82)
        inputRow.layer.cornerRadius = 24
        inputRow.layer.cornerCurve = .continuous
        inputRow.layer.borderWidth = 1
        inputRow.layer.borderColor = UIColor(palette.cyan).withAlphaComponent(0.18).cgColor

        if ReleaseFeatures.voiceInputEnabled, router.voiceInputManager != nil {
            configureMicButton(palette: palette)
            inputRow.addArrangedSubview(micButton)
        }

        inputTextView.placeholder = "Comment…"
        inputTextView.font = UIFont.preferredFont(forTextStyle: .body)
        inputTextView.adjustsFontForContentSizeCategory = true
        inputTextView.textColor = UIColor(palette.fg)
        inputTextView.tintColor = UIColor(palette.cyan)
        inputTextView.backgroundColor = .clear
        inputTextView.isScrollEnabled = false
        inputTextView.layer.cornerRadius = 0
        inputTextView.layer.borderWidth = 0
        inputTextView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        inputTextView.textContainer.lineBreakMode = .byWordWrapping
        inputTextView.delegate = self
        inputTextView.accessibilityIdentifier = "review-comment.inline-input"
        inputTextView.onKeyboardRestoreRequest = { [weak self] in
            self?.handleKeyboardRestoreRequest()
        }
        inputTextView.setAllowKeyboardRestoreOnTap(true)
        inputTextView.installKeyboardRestoreGesture()
        inputTextView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputTextView.setContentCompressionResistancePriority(.required, for: .vertical)
        inputRow.addArrangedSubview(inputTextView)
        let heightConstraint = inputTextView.heightAnchor.constraint(equalToConstant: inputMinHeight)
        inputTextHeightConstraint = heightConstraint
        heightConstraint.isActive = true

        configureSaveButton(palette: palette)
        inputRow.addArrangedSubview(saveButton)

        stackView.addArrangedSubview(inputRow)
    }

    private func configureMicButton(palette: ThemePalette) {
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.accessibilityIdentifier = "review-comment.inline-voice"
        micButton.addAction(UIAction { [weak self] _ in
            Task { @MainActor in
                await self?.handleMicTap()
            }
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            micButton.widthAnchor.constraint(equalToConstant: controlDiameter),
            micButton.heightAnchor.constraint(equalToConstant: controlDiameter),
        ])
        updateMicButton()
    }

    private func updateMicButton() {
        guard let manager = router.voiceInputManager else { return }
        let palette = ThemeRuntimeState.currentPalette()
        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .reviewCommentInline)
        micButton.apply(
            presentation: presentation,
            accentColor: UIColor(palette.cyan),
            diameter: controlDiameter
        )
        micButton.isEnabled = !isSaving && presentation.isEnabled
        micButton.accessibilityLabel = presentation.accessibilityLabel
        micButton.accessibilityValue = presentation.accessibilityValue
    }

    private func observeVoiceInput() {
        guard router.voiceInputManager != nil, !isObservingVoiceInput else { return }
        isObservingVoiceInput = true
        trackVoiceInputChanges()
    }

    private func trackVoiceInputChanges() {
        guard isObservingVoiceInput, let manager = router.voiceInputManager else { return }
        withObservationTracking {
            _ = manager.transcriptPresentationRevision
            _ = manager.state
            _ = manager.activeRecordingSource
            _ = manager.audioLevel
            _ = manager.activeLanguageLabel
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleVoiceInputChange()
            }
        }
    }

    private func handleVoiceInputChange() {
        guard isObservingVoiceInput else { return }
        let didChangeTextHeight = applyOwnedDictationTranscript()
        updateMicButton()
        if didChangeTextHeight {
            updateFrame(animated: true)
        }
        trackVoiceInputChanges()
    }

    @discardableResult
    private func applyOwnedDictationTranscript() -> Bool {
        guard let manager = router.voiceInputManager,
              ComposerShared.ownsVoiceInput(manager, owner: .reviewCommentInline),
              let prefix = textBeforeRecording else { return false }
        let nextText = prefix + manager.currentTranscript
        let didChangeText = nextText != inputTextView.text
        let didChangePresentation = nextText != lastAppliedDictationText
            || manager.transcriptPresentationRevision != lastAppliedDictationRevision
        guard didChangeText || didChangePresentation else { return false }
        lastAppliedDictationText = nextText
        lastAppliedDictationRevision = manager.transcriptPresentationRevision
        applyInputTextPresentation(text: nextText)
        updateSaveButton()
        return didChangeText ? updateInputTextHeight(animated: true) : false
    }

    private func applyInputTextPresentation(text: String? = nil) {
        let currentText = text ?? inputTextView.text ?? ""
        inputTextView.applyStyledText(
            currentText,
            font: inputTextView.font ?? UIFont.preferredFont(forTextStyle: .body),
            baseColor: UIColor(ThemeRuntimeState.currentPalette().fg),
            volatileSuffixLength: ComposerShared.volatileSuffixLength(
                manager: router.voiceInputManager,
                owner: .reviewCommentInline
            ),
            volatileColor: UIColor(Color.themeBlue),
            volatileBackgroundColor: composerVolatileTranscriptBackgroundColor(),
            correctionRanges: ComposerShared.correctionRanges(
                manager: router.voiceInputManager,
                textBeforeRecording: textBeforeRecording,
                owner: .reviewCommentInline
            ),
            correctionUnderlineColor: UIColor(Color.themeOrange)
        )
        inputTextView.refreshPlaceholder()
    }

    private func cancelVoiceInputIfOwned() {
        guard let manager = router.voiceInputManager,
              ComposerShared.ownsVoiceInput(manager, owner: .reviewCommentInline),
              manager.isRecording || manager.isPreparing else { return }
        textBeforeRecording = nil
        suppressKeyboard = false
        inputTextView.setKeyboardSuppressed(false)
        Task { @MainActor in
            await ComposerShared.cancelOwnedVoiceInput(
                manager: manager,
                owner: .reviewCommentInline,
                textBeforeRecording: recordingPrefixBinding(),
                suppressKeyboard: suppressKeyboardBinding()
            )
        }
    }

    private func configureSaveButton(palette: ThemePalette) {
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        var saveConfig = UIButton.Configuration.filled()
        saveConfig.image = UIImage(systemName: "arrow.up")
        saveConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        saveConfig.baseForegroundColor = UIColor(palette.bgDark)
        saveConfig.baseBackgroundColor = UIColor(palette.cyan)
        saveConfig.cornerStyle = .capsule
        saveConfig.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        saveButton.configuration = saveConfig
        saveButton.accessibilityIdentifier = "review-comment.inline-save"
        saveButton.accessibilityLabel = "Save comment"
        saveButton.addAction(UIAction { [weak self] _ in
            self?.save()
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            saveButton.widthAnchor.constraint(equalToConstant: controlDiameter),
            saveButton.heightAnchor.constraint(equalToConstant: controlDiameter),
        ])
    }

    private func observeKeyboard() {
        guard !isObservingKeyboard else { return }
        isObservingKeyboard = true
        for name in keyboardNotificationNames {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleKeyboardNotification(_:)),
                name: name,
                object: nil
            )
        }
    }

    private func removeKeyboardObservers() {
        for name in keyboardNotificationNames {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
    }

    private var keyboardNotificationNames: [NSNotification.Name] {
        [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ]
    }

    @objc private func handleKeyboardNotification(_ notification: Notification) {
        guard !suppressKeyboard,
              notification.name != UIResponder.keyboardWillHideNotification else {
            keyboardFrameInHost = nil
            updateFrame(animated: notification.name == UIResponder.keyboardWillHideNotification)
            return
        }

        guard let hostView,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            keyboardFrameInHost = nil
            updateFrame(animated: true)
            return
        }

        let nextFrame = hostView.convert(frame, from: nil)
        if let currentFrame = keyboardFrameInHost,
           currentFrame.intersects(hostView.bounds),
           nextFrame.intersects(hostView.bounds),
           notification.name != UIResponder.keyboardWillHideNotification {
            keyboardFrameInHost = nextFrame.minY < currentFrame.minY ? nextFrame : currentFrame
        } else {
            keyboardFrameInHost = nextFrame
        }
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.22
        let curveValue = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        let options = UIView.AnimationOptions(rawValue: curveValue << 16)
            .union([.allowUserInteraction, .beginFromCurrentState])
        updateFrame(animated: true, duration: duration, options: options)
    }

    func setKeyboardFrameInHostForTesting(_ frame: CGRect?) {
        keyboardFrameInHost = frame
        updateFrame(animated: false)
    }

    private func updateFrame(
        animated: Bool,
        duration: TimeInterval = 0.18,
        options: UIView.AnimationOptions = [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
        guard !isTornDown, let hostView else { return }
        hostView.layoutIfNeeded()
        layoutIfNeeded()

        let safeInsets = hostView.safeAreaInsets
        var safeFrame = hostView.bounds.inset(by: safeInsets)
        safeFrame = safeFrame.insetBy(dx: 12, dy: 12)
        if safeFrame.width <= 0 || safeFrame.height <= 0 {
            safeFrame = hostView.bounds.insetBy(dx: 12, dy: 12)
        }

        let availableWidth = max(240, safeFrame.width)
        let width = min(520, availableWidth)
        let measurementHeight = max(bounds.height, 64)
        bounds.size = CGSize(width: width, height: measurementHeight)
        setNeedsLayout()
        layoutIfNeeded()
        updateInputTextHeight(animated: false)
        layoutIfNeeded()

        let targetSize = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let fittingHeight = stackView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let fallbackHeight: CGFloat = quickComments.isEmpty ? 68 : 108
        let measuredHeight = fittingHeight.isFinite && fittingHeight > 0 ? ceil(fittingHeight) : fallbackHeight
        let compactMaxHeight = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            ? min(safeFrame.height, 260)
            : min(safeFrame.height, quickComments.isEmpty ? 180 : 220)
        let height = min(max(64, measuredHeight), compactMaxHeight)

        let anchor = currentAnchorRect(in: hostView, fallbackFrame: safeFrame)
        var x = min(max(anchor.minX - 18, safeFrame.minX), safeFrame.maxX - width)
        if !x.isFinite { x = safeFrame.minX }

        let keyboardTop = keyboardFrameInHost.map { $0.minY - 10 } ?? safeFrame.maxY
        let bottomLimit = min(safeFrame.maxY, keyboardTop)
        let belowY = anchor.maxY + 8
        let aboveY = anchor.minY - height - 8
        var y: CGFloat
        if belowY + height <= bottomLimit {
            y = belowY
        } else if aboveY >= safeFrame.minY, aboveY + height <= bottomLimit {
            y = aboveY
        } else {
            y = max(safeFrame.minY, bottomLimit - height)
        }
        if !y.isFinite { y = safeFrame.minY }

        let newFrame = CGRect(x: x, y: y, width: width, height: height).integral
        guard !frame.isNearlyEqual(to: newFrame) else { return }

        let changes = {
            self.frame = newFrame
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: duration, delay: 0, options: options, animations: changes)
        } else {
            changes()
        }
    }

    @discardableResult
    private func updateInputTextHeight(animated: Bool) -> Bool {
        guard let inputTextHeightConstraint else { return false }
        let fallbackWidth = max(120, bounds.width - 160)
        let fittingWidth = inputTextView.bounds.width > 0 ? inputTextView.bounds.width : fallbackWidth
        let growth = ComposerInputMetrics.textViewGrowth(
            for: inputTextView,
            fittingWidth: fittingWidth,
            minHeight: inputMinHeight,
            maxLines: traitCollection.preferredContentSizeCategory.isAccessibilityCategory
                ? ComposerInputMetrics.inlineMaxLinesWithAttachments
                : ComposerInputMetrics.inlineMaxLines
        )
        let targetHeight = growth.height
        let shouldScroll = growth.isScrollEnabled

        guard abs(inputTextHeightConstraint.constant - targetHeight) > 0.5
            || inputTextView.isScrollEnabled != shouldScroll else {
            return false
        }

        inputTextHeightConstraint.constant = targetHeight
        inputTextView.isScrollEnabled = shouldScroll

        let changes = {
            self.inputTextView.superview?.layoutIfNeeded()
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
                animations: changes
            )
        } else {
            changes()
        }
        return true
    }

    private func currentAnchorRect(in hostView: UIView, fallbackFrame: CGRect) -> CGRect {
        guard let sourceView,
              sourceView.window != nil else {
            return CGRect(x: fallbackFrame.midX, y: fallbackFrame.minY + 80, width: 1, height: 1)
        }
        return sourceView.convert(anchorRect, to: hostView)
    }

    private func handleKeyboardRestoreRequest() {
        guard suppressKeyboard else { return }
        suppressKeyboard = false
        inputTextView.becomeFirstResponder()
        guard let manager = router.voiceInputManager,
              ComposerShared.ownsVoiceInput(manager, owner: .reviewCommentInline),
              manager.isRecording || manager.isPreparing else { return }
        Task { @MainActor in
            if manager.isRecording {
                await ComposerShared.stopVoiceInput(
                    manager: manager,
                    text: textBinding(),
                    textBeforeRecording: recordingPrefixBinding()
                )
            } else {
                await ComposerShared.cancelVoiceInput(
                    manager: manager,
                    textBeforeRecording: recordingPrefixBinding(),
                    suppressKeyboard: suppressKeyboardBinding()
                )
            }
        }
    }

    private func applyQuickComment(_ template: QuickCommentTemplate) {
        let text = template.quickCommentText
        guard !text.isEmpty else { return }

        let currentText = inputTextView.text ?? ""
        let trimmedBody = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextText: String
        if trimmedBody.isEmpty {
            nextText = text
        } else if currentText.hasSuffix("\n") {
            nextText = currentText + text
        } else {
            nextText = currentText + "\n" + text
        }
        applyInputTextPresentation(text: nextText)
        updateSaveButton()
        lastAppliedDictationText = nil
        lastAppliedDictationRevision = -1
        if updateInputTextHeight(animated: true) {
            updateFrame(animated: true)
        }
        inputTextView.becomeFirstResponder()
    }

    private func textBinding() -> Binding<String> {
        Binding(
            get: { self.inputTextView.text ?? "" },
            set: { newValue in
                self.applyInputTextPresentation(text: newValue)
                self.updateSaveButton()
                self.lastAppliedDictationText = nil
                self.lastAppliedDictationRevision = -1
                if self.updateInputTextHeight(animated: true) {
                    self.updateFrame(animated: true)
                }
            }
        )
    }

    private func recordingPrefixBinding() -> Binding<String?> {
        Binding(
            get: { self.textBeforeRecording },
            set: { prefix in
                self.textBeforeRecording = prefix
                self.lastAppliedDictationText = nil
                self.lastAppliedDictationRevision = -1
            }
        )
    }

    private func suppressKeyboardBinding() -> Binding<Bool> {
        Binding(
            get: { self.suppressKeyboard },
            set: { suppressed in
                self.suppressKeyboard = suppressed
                self.inputTextView.setKeyboardSuppressed(suppressed)
                if suppressed {
                    self.keyboardFrameInHost = nil
                    self.inputTextView.becomeFirstResponder()
                    self.updateFrame(animated: false)
                }
            }
        )
    }

    private func focusRequestBinding() -> Binding<Int> {
        Binding(
            get: { 0 },
            set: { _ in }
        )
    }

    private func handleMicTap() async {
        guard let manager = router.voiceInputManager else { return }
        guard ComposerShared.canControlVoiceInput(manager, owner: .reviewCommentInline) else {
            updateMicButton()
            return
        }
        switch manager.state {
        case .recording:
            await ComposerShared.stopVoiceInput(
                manager: manager,
                text: textBinding(),
                textBeforeRecording: recordingPrefixBinding()
            )
        case .preparingModel:
            await ComposerShared.cancelVoiceInput(
                manager: manager,
                textBeforeRecording: recordingPrefixBinding(),
                suppressKeyboard: suppressKeyboardBinding()
            )
        case .idle:
            do {
                try await ComposerShared.startVoiceInput(
                    manager: manager,
                    keyboardLanguage: inputTextView.textInputMode?.primaryLanguage,
                    owner: .reviewCommentInline,
                    baseText: inputTextView.text ?? "",
                    textBeforeRecording: recordingPrefixBinding(),
                    suppressKeyboard: suppressKeyboardBinding(),
                    focusRequestID: focusRequestBinding()
                )
            } catch {
            }
        case .processing, .error:
            break
        }
        updateMicButton()
    }

    private func save() {
        guard !isSaving else { return }

        if let manager = router.voiceInputManager,
           ComposerShared.ownsVoiceInput(manager, owner: .reviewCommentInline),
           manager.isRecording || manager.isPreparing {
            isSaving = true
            updateSaveButton()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
                    manager: manager,
                    owner: .reviewCommentInline,
                    text: textBinding(),
                    textBeforeRecording: recordingPrefixBinding(),
                    suppressKeyboard: suppressKeyboardBinding()
                )
                suppressKeyboard = false
                inputTextView.setKeyboardSuppressed(false)
                saveCurrentBody()
            }
            return
        }

        saveCurrentBody()
    }

    private func saveCurrentBody() {
        let body = (inputTextView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            isSaving = false
            updateSaveButton()
            return
        }

        isSaving = true
        updateSaveButton()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didSave = await router.saveInlineComment(body: body, request: request)
            if didSave {
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
                dismiss()
            } else {
                isSaving = false
                updateSaveButton()
                inputTextView.becomeFirstResponder()
            }
        }
    }

    private func updateSaveButton() {
        let body = (inputTextView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = !isSaving && !body.isEmpty
        var config = saveButton.configuration ?? .filled()
        config.image = UIImage(systemName: isSaving ? "ellipsis" : "arrow.up")
        saveButton.configuration = config
        inputTextView.isEditable = !isSaving
        closeButton.isEnabled = !isSaving
    }

    func textViewDidChange(_ textView: UITextView) {
        inputTextView.refreshPlaceholder()
        updateSaveButton()
        lastAppliedDictationText = nil
        lastAppliedDictationRevision = -1
        if updateInputTextHeight(animated: true) {
            updateFrame(animated: true)
        }
    }

    private static func locationText(for source: ReviewCommentSourceContext) -> String {
        if let lineRange = source.lineRange {
            if lineRange.lowerBound == lineRange.upperBound {
                return "Comment on line \(lineRange.lowerBound)"
            }
            return "Comment on lines \(lineRange.lowerBound)-\(lineRange.upperBound)"
        }
        if let filePath = source.filePath, !filePath.isEmpty {
            return filePath
        }
        if let sourceLabel = source.sourceLabel, !sourceLabel.isEmpty {
            return sourceLabel
        }

        switch source.surface {
        case .assistantProse: return "Assistant message"
        case .userMessage: return "User message"
        case .assistantCodeBlock: return "Code block"
        case .assistantTable: return "Table"
        case .thinking, .fullScreenThinking: return "Thinking"
        case .toolCommand: return "Tool command"
        case .toolOutput, .toolExpandedText: return "Tool output"
        case .fullScreenCode: return "Code"
        case .fullScreenDiff: return "Diff"
        case .fullScreenSource: return "Source"
        case .fullScreenTerminal: return "Terminal"
        case .fullScreenMarkdown: return "Markdown"
        }
    }
}

private final class ReviewCommentInlineInputTextView: PastableUITextView {
    private let placeholderLabel = UILabel()

    var placeholder: String = "" {
        didSet {
            placeholderLabel.text = placeholder
            refreshPlaceholder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshPlaceholder()
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupPlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupPlaceholder() {
        placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = UIColor(ThemeRuntimeState.currentPalette().comment)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -15),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: UITextView.textDidChangeNotification,
            object: self
        )
    }

    func refreshPlaceholder() {
        let currentText = text ?? ""
        placeholderLabel.isHidden = !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func textDidChange() {
        refreshPlaceholder()
    }
}

private extension CGRect {
    func isNearlyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}
