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
    private let micButton = UIButton(type: .system)
    private let inputTextView = ReviewCommentInlineInputTextView()
    private let quickScrollView = UIScrollView()
    private let quickStack = UIStackView()
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private var textBeforeRecording: String?
    private var suppressKeyboard = false
    private var isObservingVoiceInput = false

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
        isObservingVoiceInput = false
        NotificationCenter.default.removeObserver(self)
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
        isObservingVoiceInput = false
        inputTextView.resignFirstResponder()
        cancelVoiceInputIfOwned()
        if isObservingKeyboard {
            NotificationCenter.default.removeObserver(
                self,
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            isObservingKeyboard = false
        }

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
        inputRow.alignment = .center
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
        inputTextView.layer.cornerRadius = 0
        inputTextView.layer.borderWidth = 0
        inputTextView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        inputTextView.delegate = self
        inputTextView.accessibilityIdentifier = "review-comment.inline-input"
        inputTextView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputTextView.setContentCompressionResistancePriority(.required, for: .vertical)
        inputRow.addArrangedSubview(inputTextView)
        inputTextView.heightAnchor.constraint(equalToConstant: 40).isActive = true

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
            micButton.widthAnchor.constraint(equalToConstant: 40),
            micButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        micButton.tintColor = UIColor(palette.cyan)
        updateMicButton()
    }

    private func updateMicButton() {
        guard let manager = router.voiceInputManager else { return }
        let palette = ThemeRuntimeState.currentPalette()
        let ownsVoiceInput = manager.isActiveRecordingSource(ComposerShared.reviewCommentInlineVoiceInputSource)
        let isRecording = manager.isRecording && ownsVoiceInput
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: isRecording ? "stop.fill" : "mic.fill")
        config.baseForegroundColor = UIColor(isRecording ? palette.bgDark : palette.fg)
        config.baseBackgroundColor = UIColor(isRecording ? palette.red : palette.bgHighlight).withAlphaComponent(isRecording ? 1 : 0.86)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        micButton.configuration = config
        micButton.isEnabled = !isSaving && !manager.isProcessing && (ownsVoiceInput || manager.state == .idle)
        micButton.accessibilityLabel = isRecording ? "Stop dictation" : "Dictate comment"
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
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleVoiceInputChange()
            }
        }
    }

    private func handleVoiceInputChange() {
        guard isObservingVoiceInput else { return }
        applyOwnedDictationTranscript()
        updateMicButton()
        trackVoiceInputChanges()
    }

    private func applyOwnedDictationTranscript() {
        guard let manager = router.voiceInputManager,
              manager.isActiveRecordingSource(ComposerShared.reviewCommentInlineVoiceInputSource),
              let prefix = textBeforeRecording else { return }
        inputTextView.text = prefix + manager.currentTranscript
        inputTextView.refreshPlaceholder()
        updateSaveButton()
    }

    private func cancelVoiceInputIfOwned() {
        guard let manager = router.voiceInputManager,
              manager.isActiveRecordingSource(ComposerShared.reviewCommentInlineVoiceInputSource),
              manager.isRecording || manager.isPreparing else { return }
        textBeforeRecording = nil
        suppressKeyboard = false
        Task { @MainActor in
            await manager.cancelRecording()
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
            saveButton.widthAnchor.constraint(equalToConstant: 40),
            saveButton.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func observeKeyboard() {
        guard !isObservingKeyboard else { return }
        isObservingKeyboard = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardNotification(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func handleKeyboardNotification(_ notification: Notification) {
        guard let hostView,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            keyboardFrameInHost = nil
            updateFrame(animated: true)
            return
        }

        keyboardFrameInHost = hostView.convert(frame, from: nil)
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.22
        let curveValue = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        let options = UIView.AnimationOptions(rawValue: curveValue << 16)
        updateFrame(animated: true, duration: duration, options: options)
    }

    private func updateFrame(
        animated: Bool,
        duration: TimeInterval = 0.18,
        options: UIView.AnimationOptions = [.curveEaseInOut, .allowUserInteraction]
    ) {
        guard let hostView else { return }
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
        bounds.size = CGSize(width: width, height: 1)
        setNeedsLayout()
        layoutIfNeeded()

        let targetSize = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let fittingHeight = stackView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let fallbackHeight: CGFloat = quickComments.isEmpty ? 68 : 108
        let measuredHeight = fittingHeight.isFinite && fittingHeight > 0 ? ceil(fittingHeight) : fallbackHeight
        let preferredHeight = quickComments.isEmpty ? CGFloat(84) : CGFloat(124)
        let compactMaxHeight = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            ? min(safeFrame.height, 180)
            : min(safeFrame.height, preferredHeight)
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
        } else if aboveY >= safeFrame.minY {
            y = aboveY
        } else {
            y = max(safeFrame.minY, bottomLimit - height)
        }
        if !y.isFinite { y = safeFrame.minY }

        let newFrame = CGRect(x: x, y: y, width: width, height: height).integral
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

    private func currentAnchorRect(in hostView: UIView, fallbackFrame: CGRect) -> CGRect {
        guard let sourceView,
              sourceView.window != nil else {
            return CGRect(x: fallbackFrame.midX, y: fallbackFrame.minY + 80, width: 1, height: 1)
        }
        return sourceView.convert(anchorRect, to: hostView)
    }

    private func applyQuickComment(_ template: QuickCommentTemplate) {
        let text = template.quickCommentText
        guard !text.isEmpty else { return }

        let currentText = inputTextView.text ?? ""
        let trimmedBody = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty {
            inputTextView.text = text
        } else if currentText.hasSuffix("\n") {
            inputTextView.text = currentText + text
        } else {
            inputTextView.text = currentText + "\n" + text
        }
        inputTextView.refreshPlaceholder()
        updateSaveButton()
        inputTextView.becomeFirstResponder()
    }

    private func textBinding() -> Binding<String> {
        Binding(
            get: { self.inputTextView.text ?? "" },
            set: { newValue in
                self.inputTextView.text = newValue
                self.inputTextView.refreshPlaceholder()
                self.updateSaveButton()
            }
        )
    }

    private func recordingPrefixBinding() -> Binding<String?> {
        Binding(
            get: { self.textBeforeRecording },
            set: { self.textBeforeRecording = $0 }
        )
    }

    private func suppressKeyboardBinding() -> Binding<Bool> {
        Binding(
            get: { self.suppressKeyboard },
            set: { self.suppressKeyboard = $0 }
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
        let ownsVoiceInput = manager.isActiveRecordingSource(ComposerShared.reviewCommentInlineVoiceInputSource)
        guard ownsVoiceInput || manager.state == .idle else {
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
                    keyboardLanguage: nil,
                    source: ComposerShared.reviewCommentInlineVoiceInputSource,
                    baseText: inputTextView.text ?? "",
                    textBeforeRecording: recordingPrefixBinding(),
                    suppressKeyboard: suppressKeyboardBinding(),
                    focusRequestID: focusRequestBinding()
                )
                inputTextView.resignFirstResponder()
            } catch {
            }
        case .processing, .error:
            break
        }
        updateMicButton()
    }

    private func save() {
        let body = (inputTextView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSaving else { return }

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

private final class ReviewCommentInlineInputTextView: UITextView {
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
