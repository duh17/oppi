import UIKit

/// Rules for the expanded Ask sheet.
@MainActor
enum AskCardExpanded {
    static let confirmationDismissTitle = "Close Details"

    /// An extension confirm request (one single-choice question with confirm
    /// and cancel values) gets pinned Confirm / Cancel / Close Details buttons
    /// instead of option rows.
    static func usesPinnedConfirmationActions(_ request: AskRequest) -> Bool {
        guard request.responseEncoding == .extensionConfirm,
              request.questions.count == 1,
              let question = request.questions.first,
              !question.multiSelect else { return false }
        let values = Set(question.options.map(\.value))
        return values.contains(ExtensionUIRequest.confirmValue)
            && values.contains(ExtensionUIRequest.cancelValue)
    }

    /// Keep the custom field in the footer chrome. Confirmation sheets already
    /// own that space for Confirm/Cancel.
    static func pinsCustomAnswerInBottomChrome(_ request: AskRequest) -> Bool {
        request.allowCustom && !usesPinnedConfirmationActions(request)
    }

    static func sheetDetentForCustomAnswerFocus(
        request: AskRequest,
        isCustomAnswerFocused: Bool
    ) -> UISheetPresentationController.Detent.Identifier? {
        guard isCustomAnswerFocused, pinsCustomAnswerInBottomChrome(request) else {
            return nil
        }
        return .large
    }

    static func dictationPrefix(for base: String) -> String {
        ComposerShared.dictationPrefix(for: base)
    }

    static func combinedDictationText(base: String, prefix: String, transcript: String) -> String {
        guard !transcript.isEmpty else { return base }
        return prefix + transcript
    }
}

/// Expanded sheet for an Ask request: the full question as Markdown, option
/// rows, and an optional typed answer pinned above the keyboard. Several
/// questions page with Back / Next. The inline card and this sheet share the
/// page and draft answers both ways, so collapsing keeps both.
///
/// ```
/// ┌──────────────────────────────────────┐
/// │ ‹ Back    Question 1 of 3         ⤡ │
/// ├──────────────────────────────────────┤
/// │ Full question (Markdown)             │ scrolls
/// │ [☑ Select multiple]                  │
/// │ option rows                          │
/// ├──────────────────────────────────────┤
/// │ Or type your answer                  │ custom answers only
/// │ [🎤 Type your answer…              ] │
/// │ Ignore ›                      Send   │
/// └──────────────────────────────────────┘
/// ```
@MainActor
final class AskCardExpandedViewController: UIViewController, RouterModalContainer, UITextViewDelegate {
    var onDismissed: (() -> Void)?
    var onPageChange: ((Int) -> Void)?
    var onAnswersChange: (([String: AskAnswer]) -> Void)?
    var onSubmit: (([String: AskAnswer]) -> Void)?
    var onIgnoreAll: (() -> Void)?
    var voiceInputManager: VoiceInputManager?

    private var request: AskRequest?
    private var currentPage = 0
    private var answers: [String: AskAnswer] = [:]
    private var colors = ComposerThemeColors.placeholder
    private var reduceMotion = false
    private var customTexts: [String: String] = [:]
    private var focusedQuestionId: String?
    private var suppressKeyboard = false
    private var keyboardLanguage: String?
    private var focusRequestID = 0
    /// Question currently receiving dictated custom text, its text before
    /// dictation, and the prefix (base plus separator) transcripts follow.
    private var dictationQuestionId: String?
    private var dictationBaseText = ""
    private var dictationPrefixText = ""
    private var builtRequest: AskRequest?
    private var builtPage: Int?
    private var optionRows: [AskOptionChoiceRowView] = []

    private let header = UIView()
    private let backButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let collapseButton = UIButton(type: .system)
    private let divider = UIView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let markdownView = AssistantMarkdownContentView()
    private let selectionPillRow = UIView()
    private let selectionPill = AskSelectionModePillView()
    private let optionsStack = UIStackView()
    private let multiSelectDone = UIButton(type: .system)

    private let bottomChrome = UIView()
    private let bottomDivider = UIView()
    private let customWrap = UIView()
    private let customHint = UILabel()
    private let customField = UIView()
    private let customPlaceholder = UILabel()
    private let customTextView = PastableUITextView()
    private var customTextHeight: NSLayoutConstraint?
    private let micButton = MicButtonChromeView()
    private let footerStack = UIStackView()
    private let ignoreButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let pinnedStack = UIStackView()
    private let closeDetailsButton = UIButton(type: .system)
    private let cancelConfirmButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)
    /// Pushes Cancel and Confirm trailing in the one-row layout; not in the
    /// stacked layout.
    private let pinnedSpacer = UIView()
    nonisolated(unsafe) private var inputModeObserver: NSObjectProtocol?

    deinit {
        if let inputModeObserver {
            NotificationCenter.default.removeObserver(inputModeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHierarchy()
        inputModeObserver = NotificationCenter.default.addObserver(
            forName: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateKeyboardLanguage() }
        }
        loadCustomTextsFromAnswers()
        applyChrome()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        suppressKeyboard = false
        cancelDictationIfNeeded()
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPinnedActions()
    }

    /// Voice state is `@Observable`; reading it here re-runs this on every
    /// state, spectrum, and transcript change.
    override func updateProperties() {
        super.updateProperties()
        guard let manager = voiceInputManager else { return }
        _ = manager.state
        _ = manager.voiceSpectrum
        _ = manager.transcriptPresentationRevision
        if let questionId = dictationQuestionId,
           ComposerShared.ownsVoiceInput(manager, owner: .askCard) {
            applyDictationTranscript(manager.currentTranscript, for: questionId)
        }
        applyMic()
    }

    func apply(
        request: AskRequest,
        currentPage: Int,
        answers: [String: AskAnswer],
        colors: ComposerThemeColors,
        reduceMotion: Bool
    ) {
        self.request = request
        self.currentPage = AskCard.clampedPage(currentPage, for: request)
        self.answers = answers
        self.colors = colors
        self.reduceMotion = reduceMotion
        if isViewLoaded {
            applyChrome()
        }
    }

    // MARK: - Build

    private func buildHierarchy() {
        for view in [header, divider, scrollView, bottomChrome] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }

        var backConfig = UIButton.Configuration.plain()
        backConfig.title = "Back"
        backConfig.image = UIImage(systemName: "chevron.left")
        backConfig.imagePadding = 4
        backConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 8)
        backButton.configuration = backConfig
        backButton.addAction(UIAction { [weak self] _ in self?.navigateBack() }, for: .touchUpInside)

        titleLabel.font = AskUIFont.preferred(.subheadline, weight: .medium)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        var collapseConfig = UIButton.Configuration.plain()
        collapseConfig.image = UIImage(systemName: "arrow.down.right.and.arrow.up.left")
        collapseConfig.contentInsets = .zero
        collapseButton.configuration = collapseConfig
        collapseButton.accessibilityLabel = "Collapse"
        collapseButton.accessibilityIdentifier = "ask.expanded.collapse"
        collapseButton.addAction(UIAction { [weak self] _ in self?.collapse() }, for: .touchUpInside)

        for view in [backButton, titleLabel, collapseButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        let side = AskCard.quietControlMinimumHitSize
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            backButton.heightAnchor.constraint(equalToConstant: side),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            collapseButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            collapseButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: side),
            collapseButton.heightAnchor.constraint(equalToConstant: side),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: collapseButton.leadingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 56),
        ])

        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.accessibilityIdentifier = "ask.approval.scroll"
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        // The markdown view sizes itself (intrinsic height at its width).
        markdownView.backgroundColor = .clear
        markdownView.setContentCompressionResistancePriority(.required, for: .vertical)
        selectionPill.translatesAutoresizingMaskIntoConstraints = false
        selectionPillRow.addSubview(selectionPill)
        NSLayoutConstraint.activate([
            selectionPill.leadingAnchor.constraint(equalTo: selectionPillRow.leadingAnchor),
            selectionPill.trailingAnchor.constraint(lessThanOrEqualTo: selectionPillRow.trailingAnchor),
            selectionPill.topAnchor.constraint(equalTo: selectionPillRow.topAnchor),
            selectionPill.bottomAnchor.constraint(equalTo: selectionPillRow.bottomAnchor),
        ])
        optionsStack.axis = .vertical
        optionsStack.spacing = 10
        multiSelectDone.addAction(UIAction { [weak self] _ in self?.confirmMultiSelect() }, for: .touchUpInside)
        let doneRow = UIView()
        multiSelectDone.translatesAutoresizingMaskIntoConstraints = false
        doneRow.addSubview(multiSelectDone)
        NSLayoutConstraint.activate([
            multiSelectDone.centerXAnchor.constraint(equalTo: doneRow.centerXAnchor),
            multiSelectDone.topAnchor.constraint(equalTo: doneRow.topAnchor),
            multiSelectDone.bottomAnchor.constraint(equalTo: doneRow.bottomAnchor),
            multiSelectDone.heightAnchor.constraint(equalToConstant: side),
        ])
        for view in [markdownView, selectionPillRow, optionsStack, doneRow] as [UIView] {
            contentStack.addArrangedSubview(view)
        }

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        buildBottomChrome()

        let hairline = 1 / max(traitCollection.displayScale, 1)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: hairline),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomChrome.topAnchor),
            bottomChrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomChrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The custom answer stays above the keyboard, so a long option list
            // cannot scroll it out of reach.
            bottomChrome.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func buildBottomChrome() {
        for view in [bottomDivider, customWrap, footerStack, pinnedStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bottomChrome.addSubview(view)
        }

        customHint.font = AskUIFont.preferred(.subheadline, weight: .medium)
        customHint.adjustsFontForContentSizeCategory = true
        customHint.text = "Or type your answer"
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        customPlaceholder.font = bodyFont
        customPlaceholder.text = "Type your answer..."
        customPlaceholder.isUserInteractionEnabled = false
        customTextView.delegate = self
        customTextView.backgroundColor = .clear
        customTextView.font = bodyFont
        customTextView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        customTextView.textContainer.lineFragmentPadding = 0
        customTextView.isScrollEnabled = true
        customTextView.accessibilityIdentifier = "ask.input"
        customTextView.installKeyboardRestoreGesture()
        customTextView.setAllowKeyboardRestoreOnTap(true)
        customTextView.onCommandEnter = { [weak self] in
            Task { await self?.commitCustomFromKeyboard() }
        }
        customTextView.onKeyboardRestoreRequest = { [weak self] in
            self?.handleKeyboardRestoreRequest()
        }
        applyComposerInputTraits(to: customTextView, autocorrectionEnabled: true)
        let customHeight = customTextView.heightAnchor.constraint(equalToConstant: 36)
        customHeight.isActive = true
        customTextHeight = customHeight
        micButton.addAction(UIAction { [weak self] _ in
            Task { await self?.handleDictationTap() }
        }, for: .touchUpInside)
        micButton.accessibilityIdentifier = "ask.voiceInput"
        // The mic draws at 32 pt and takes touches across a 44 pt band; the
        // field's padding has room for the band, the row passes it through.
        micButton.minimumHitSide = AskCard.quietControlMinimumHitSize

        let inputRow = AskAnswerInputRow(arrangedSubviews: [micButton, customTextView])
        inputRow.axis = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 8
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        customPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        customTextView.addSubview(customPlaceholder)
        customField.addSubview(inputRow)
        customField.layer.cornerRadius = 12
        customField.layer.cornerCurve = .continuous
        customField.layer.borderWidth = 1
        NSLayoutConstraint.activate([
            customPlaceholder.leadingAnchor.constraint(equalTo: customTextView.leadingAnchor),
            customPlaceholder.topAnchor.constraint(equalTo: customTextView.topAnchor, constant: 4),
            micButton.widthAnchor.constraint(equalToConstant: 32),
            micButton.heightAnchor.constraint(equalToConstant: 32),
            inputRow.leadingAnchor.constraint(equalTo: customField.leadingAnchor, constant: 12),
            inputRow.trailingAnchor.constraint(equalTo: customField.trailingAnchor, constant: -12),
            inputRow.topAnchor.constraint(equalTo: customField.topAnchor, constant: 7),
            inputRow.bottomAnchor.constraint(equalTo: customField.bottomAnchor, constant: -7),
            customField.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
        let customStack = UIStackView(arrangedSubviews: [customHint, customField])
        customStack.axis = .vertical
        customStack.spacing = 8
        customStack.translatesAutoresizingMaskIntoConstraints = false
        customWrap.addSubview(customStack)
        NSLayoutConstraint.activate([
            customStack.leadingAnchor.constraint(equalTo: customWrap.leadingAnchor, constant: 20),
            customStack.trailingAnchor.constraint(equalTo: customWrap.trailingAnchor, constant: -20),
            customStack.topAnchor.constraint(equalTo: customWrap.topAnchor, constant: 12),
            customStack.bottomAnchor.constraint(equalTo: customWrap.bottomAnchor, constant: -4),
        ])

        ignoreButton.addAction(UIAction { [weak self] _ in self?.handleIgnore() }, for: .touchUpInside)
        nextButton.addAction(UIAction { [weak self] _ in self?.navigateForward() }, for: .touchUpInside)
        sendButton.addAction(UIAction { [weak self] _ in
            Task { await self?.sendCurrent() }
        }, for: .touchUpInside)
        let footerSpacer = UIView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerStack.axis = .horizontal
        footerStack.alignment = .center
        for view in [ignoreButton, footerSpacer, nextButton, sendButton] as [UIView] {
            footerStack.addArrangedSubview(view)
        }

        closeDetailsButton.accessibilityHint = "Closes details without responding"
        closeDetailsButton.accessibilityIdentifier = "ask.confirmation.closeDetails"
        closeDetailsButton.addAction(UIAction { [weak self] _ in self?.collapse() }, for: .touchUpInside)
        cancelConfirmButton.accessibilityIdentifier = "ask.confirmation.cancel"
        cancelConfirmButton.addAction(UIAction { [weak self] _ in
            self?.submitPinnedConfirmation(value: ExtensionUIRequest.cancelValue)
        }, for: .touchUpInside)
        confirmButton.accessibilityIdentifier = "ask.confirmation.confirm"
        confirmButton.addAction(UIAction { [weak self] _ in
            self?.submitPinnedConfirmation(value: ExtensionUIRequest.confirmValue)
        }, for: .touchUpInside)
        pinnedSpacer.isUserInteractionEnabled = false
        pinnedSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pinnedStack.axis = .horizontal
        pinnedStack.alignment = .center
        pinnedStack.spacing = 10
        for view in [closeDetailsButton, pinnedSpacer, cancelConfirmButton, confirmButton] as [UIView] {
            pinnedStack.addArrangedSubview(view)
        }

        let hairline = 1 / max(traitCollection.displayScale, 1)
        let side = AskCard.quietControlMinimumHitSize
        NSLayoutConstraint.activate([
            bottomDivider.leadingAnchor.constraint(equalTo: bottomChrome.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: bottomChrome.trailingAnchor),
            bottomDivider.topAnchor.constraint(equalTo: bottomChrome.topAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: hairline),
            customWrap.leadingAnchor.constraint(equalTo: bottomChrome.leadingAnchor),
            customWrap.trailingAnchor.constraint(equalTo: bottomChrome.trailingAnchor),
            customWrap.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor),
            footerStack.leadingAnchor.constraint(equalTo: bottomChrome.leadingAnchor, constant: 20),
            footerStack.trailingAnchor.constraint(equalTo: bottomChrome.trailingAnchor, constant: -20),
            footerStack.topAnchor.constraint(equalTo: customWrap.bottomAnchor, constant: 6),
            footerStack.bottomAnchor.constraint(equalTo: bottomChrome.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            pinnedStack.leadingAnchor.constraint(equalTo: bottomChrome.leadingAnchor, constant: 20),
            pinnedStack.trailingAnchor.constraint(equalTo: bottomChrome.trailingAnchor, constant: -20),
            pinnedStack.topAnchor.constraint(equalTo: customWrap.bottomAnchor, constant: 10),
            pinnedStack.bottomAnchor.constraint(equalTo: bottomChrome.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            ignoreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: side),
            nextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: side),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: side),
            closeDetailsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: side),
            cancelConfirmButton.heightAnchor.constraint(greaterThanOrEqualToConstant: side),
            confirmButton.heightAnchor.constraint(greaterThanOrEqualToConstant: side),
        ])
    }

    // MARK: - Derived state

    private var isSingleQuestionSingleSelect: Bool {
        guard let request else { return true }
        return request.questions.count == 1 && !request.questions[0].multiSelect
    }

    private var totalPages: Int {
        request.map(AskCard.pageCount(for:)) ?? 1
    }

    private var currentQuestion: AskQuestion? {
        guard let request, currentPage < request.questions.count else { return nil }
        return request.questions[currentPage]
    }

    private var isLastQuestionPage: Bool {
        guard let request else { return false }
        return !isSingleQuestionSingleSelect && currentPage == request.questions.count - 1
    }

    private var usesPinnedConfirmationActions: Bool {
        request.map(AskCardExpanded.usesPinnedConfirmationActions) ?? false
    }

    private var hasCustomTextForCurrentQuestion: Bool {
        guard let question = currentQuestion else { return false }
        return !(customTexts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Apply

    private func applyChrome() {
        guard let request else { return }
        view.backgroundColor = colors.bg
        bottomChrome.backgroundColor = colors.bg
        divider.backgroundColor = colors.comment.withAlphaComponent(0.15)
        bottomDivider.backgroundColor = colors.comment.withAlphaComponent(0.15)
        collapseButton.configuration?.baseForegroundColor = colors.comment
        titleLabel.textColor = colors.comment
        titleLabel.text = isSingleQuestionSingleSelect
            ? nil
            : "Question \(currentPage + 1) of \(request.questions.count)"
        titleLabel.isHidden = isSingleQuestionSingleSelect
        backButton.isHidden = isSingleQuestionSingleSelect || currentPage == 0
        backButton.configuration?.baseForegroundColor = colors.blue

        guard let question = currentQuestion else { return }
        // The markdown view skips an unchanged configuration, so this only
        // re-renders for a new question or a theme change (new palette).
        markdownView.apply(configuration: .make(
            content: question.question,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: true
        ))
        let pageChanged = builtRequest?.id != request.id || builtPage != currentPage
        if builtRequest != request || builtPage != currentPage {
            rebuildPage(question)
            if pageChanged, builtPage != nil {
                scrollView.setContentOffset(.zero, animated: false)
            }
            builtRequest = request
            builtPage = currentPage
        }
        selectionPill.apply(question: question, colors: colors)
        selectionPillRow.isHidden = selectionPill.isHidden
        for (row, option) in zip(optionRows, question.options) {
            row.apply(
                option: option,
                isSelected: AskCardShared.isOptionSelected(option, in: question, answers: answers),
                isMultiSelect: question.multiSelect,
                colors: colors
            )
        }

        let count = AskCardShared.multiSelectCount(for: question, answers: answers) ?? 0
        let showsDone = question.multiSelect && count > 0 && !isLastQuestionPage
        multiSelectDone.superview?.isHidden = !showsDone
        if showsDone {
            var config = UIButton.Configuration.plain()
            config.title = "Done (\(count) selected)"
            config.baseForegroundColor = colors.blue
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = AskUIFont.preferred(.subheadline, weight: .semibold)
                return outgoing
            }
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18)
            config.background.backgroundColor = colors.blue.withAlphaComponent(0.14)
            config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
            config.background.cornerRadius = 18
            multiSelectDone.configuration = config
        }

        applyCustomField(question: question)
        applyFooterActions()
        applyMic()
    }

    /// New request or page: option rows rebuild once; selection changes
    /// afterwards update rows in place.
    private func rebuildPage(_ question: AskQuestion) {
        optionRows.forEach { $0.removeFromSuperview() }
        optionRows = []
        if !usesPinnedConfirmationActions {
            for option in question.options {
                let row = AskOptionChoiceRowView(density: .expanded)
                row.onTap = { [weak self] in self?.selectOption(option, question: question) }
                optionsStack.addArrangedSubview(row)
                optionRows.append(row)
            }
        }
        optionsStack.isHidden = optionRows.isEmpty
        if builtPage != nil, !reduceMotion {
            UIView.transition(
                with: contentStack,
                duration: 0.22,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: nil
            )
        }
    }

    private func applyCustomField(question: AskQuestion) {
        let show = request.map(AskCardExpanded.pinsCustomAnswerInBottomChrome) ?? false
        customWrap.isHidden = !show
        customHint.textColor = colors.comment
        customHint.isHidden = focusedQuestionId == question.id
        customPlaceholder.textColor = colors.comment
        customField.backgroundColor = colors.bgHighlight
        customField.layer.borderColor = colors.comment.withAlphaComponent(0.12).cgColor
        let text = customTexts[question.id] ?? ""
        customTextView.applyStyledText(
            text,
            font: UIFont.preferredFont(forTextStyle: .body),
            baseColor: colors.fg,
            volatileSuffixLength: dictationQuestionId == question.id
                ? ComposerShared.volatileSuffixLength(manager: voiceInputManager, owner: .askCard)
                : 0,
            volatileColor: colors.blue,
            volatileBackgroundColor: colors.blue.withAlphaComponent(0.20),
            correctionRanges: correctionRangesForDisplay(questionId: question.id),
            correctionUnderlineColor: colors.orange
        )
        customPlaceholder.isHidden = !text.isEmpty
        customTextView.tintColor = colors.blue
        if customTextView.isKeyboardSuppressed != suppressKeyboard {
            customTextView.setKeyboardSuppressed(suppressKeyboard)
        }
        let growth = ComposerInputMetrics.textViewGrowth(
            for: customTextView,
            fittingWidth: max(customTextView.bounds.width, 200),
            minHeight: 36,
            maxLines: 5
        )
        customTextHeight?.constant = growth.height
        customTextView.isScrollEnabled = growth.isScrollEnabled
    }

    private func applyFooterActions() {
        let onBlue = ComposerColorContrast.foreground(for: colors.blue, fg: colors.fg, bg: colors.bg)
        if usesPinnedConfirmationActions {
            footerStack.isHidden = true
            pinnedStack.isHidden = false
            var closeConfig = UIButton.Configuration.plain()
            closeConfig.title = AskCardExpanded.confirmationDismissTitle
            closeConfig.baseForegroundColor = colors.comment
            closeDetailsButton.configuration = closeConfig
            cancelConfirmButton.configuration = Self.filledConfiguration(
                title: "Cancel", foreground: colors.fg, fill: colors.bgHighlight, weight: .medium
            )
            confirmButton.configuration = Self.filledConfiguration(
                title: "Confirm", foreground: onBlue, fill: colors.blue, weight: .semibold
            )
            layoutPinnedActions()
            return
        }
        footerStack.isHidden = false
        pinnedStack.isHidden = true

        var ignoreConfig = UIButton.Configuration.plain()
        ignoreConfig.title = isLastQuestionPage ? "Ignore & Send" : "Ignore"
        ignoreConfig.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1)
        )
        ignoreConfig.imagePlacement = .trailing
        ignoreConfig.imagePadding = 4
        ignoreConfig.baseForegroundColor = colors.comment
        ignoreConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8)
        ignoreButton.configuration = ignoreConfig

        let showsSend: Bool
        if isSingleQuestionSingleSelect {
            showsSend = hasCustomTextForCurrentQuestion
        } else {
            showsSend = isLastQuestionPage
        }
        nextButton.isHidden = isSingleQuestionSingleSelect || isLastQuestionPage
        sendButton.isHidden = !showsSend
        sendButton.configuration = Self.filledConfiguration(
            title: "Send", foreground: onBlue, fill: colors.blue, weight: .semibold
        )

        var nextConfig = UIButton.Configuration.plain()
        nextConfig.title = "Next"
        nextConfig.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .medium)
        )
        nextConfig.imagePlacement = .trailing
        nextConfig.imagePadding = 4
        nextConfig.baseForegroundColor = colors.blue
        nextButton.configuration = nextConfig
    }

    private static func filledConfiguration(
        title: String,
        foreground: UIColor,
        fill: UIColor,
        weight: UIFont.Weight
    ) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = foreground
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = AskUIFont.preferred(.body, weight: weight)
            return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
        config.background.backgroundColor = fill
        config.background.cornerRadius = 12
        return config
    }

    /// Confirm / Cancel / Close Details sit in one row when they fit and
    /// stack, Confirm first, when they do not.
    private func layoutPinnedActions() {
        guard usesPinnedConfirmationActions, !pinnedStack.isHidden else { return }
        let width = view.bounds.width
        guard width > 1 else { return }
        let needed = closeDetailsButton.intrinsicContentSize.width
            + cancelConfirmButton.intrinsicContentSize.width
            + confirmButton.intrinsicContentSize.width
            + 52
        let vertical = needed > width - 40
        guard vertical != (pinnedStack.axis == .vertical) else { return }
        let ordered: [UIView] = vertical
            ? [confirmButton, cancelConfirmButton, closeDetailsButton]
            : [closeDetailsButton, pinnedSpacer, cancelConfirmButton, confirmButton]
        pinnedStack.arrangedSubviews.forEach { pinnedStack.removeArrangedSubview($0) }
        // removeArrangedSubview keeps the view as a subview; drop the spacer
        // outright so the stacked layout has nothing but its buttons.
        pinnedSpacer.removeFromSuperview()
        ordered.forEach { pinnedStack.addArrangedSubview($0) }
        pinnedStack.axis = vertical ? .vertical : .horizontal
        pinnedStack.alignment = vertical ? .fill : .center
        pinnedStack.spacing = vertical ? 8 : 10
    }

    private func applyMic() {
        guard let manager = voiceInputManager else {
            micButton.isHidden = true
            return
        }
        let owns = dictationQuestionId != nil && dictationQuestionId == currentQuestion?.id
        let presentation = owns
            ? ComposerShared.micButtonPresentation(for: manager, owner: .askCard)
            : ComposerShared.blockedMicButtonPresentation(for: manager)
        micButton.apply(presentation: presentation, accentColor: colors.blue, diameter: 32)
        micButton.isEnabled = presentation.isEnabled
        micButton.accessibilityLabel = presentation.accessibilityLabel
        micButton.accessibilityValue = presentation.accessibilityValue
        micButton.isHidden = false
    }

    // MARK: - Actions

    private func selectOption(_ option: AskOption, question: AskQuestion) {
        cancelDictationIfNeeded(for: question.id)
        suppressKeyboard = false
        focusedQuestionId = nil
        customTexts[question.id] = ""
        var singleSelected = false
        AskCardShared.handleOptionTap(option, question: question, answers: &answers) {
            singleSelected = true
        }
        onAnswersChange?(answers)
        if singleSelected, isSingleQuestionSingleSelect {
            dismissAndSubmit()
            return
        }
        applyChrome()
    }

    private func confirmMultiSelect() {
        AppHaptics.impact(style: .light)
        if !isLastQuestionPage {
            navigateForward()
        }
    }

    private func handleIgnore() {
        AppHaptics.impact(style: .soft)
        if let question = currentQuestion {
            cancelDictationIfNeeded(for: question.id)
            suppressKeyboard = false
            focusedQuestionId = nil
            answers[question.id] = nil
            customTexts[question.id] = ""
            onAnswersChange?(answers)
        }
        if isSingleQuestionSingleSelect {
            suppressKeyboard = false
            Router.finish(self)
            onIgnoreAll?()
        } else if isLastQuestionPage {
            Task { await sendCurrent() }
        } else {
            navigateForward()
        }
    }

    private func navigateForward() {
        Task {
            await finalizeDictationIfNeeded()
            suppressKeyboard = false
            focusedQuestionId = nil
            commitCustomTextIfNeeded()
            guard currentPage < totalPages - 1 else { return }
            setPage(currentPage + 1)
        }
    }

    private func navigateBack() {
        Task {
            await finalizeDictationIfNeeded()
            suppressKeyboard = false
            focusedQuestionId = nil
            guard currentPage > 0 else { return }
            setPage(currentPage - 1)
        }
    }

    private func setPage(_ page: Int) {
        currentPage = page
        onPageChange?(page)
        applyChrome()
    }

    private func collapse() {
        Task {
            await finalizeDictationIfNeeded()
            commitCustomTextIfNeeded()
            suppressKeyboard = false
            focusedQuestionId = nil
            Router.finish(self)
        }
    }

    private func sendCurrent() async {
        await finalizeDictationIfNeeded()
        commitCustomTextIfNeeded()
        suppressKeyboard = false
        dismissAndSubmit()
    }

    private func dismissAndSubmit() {
        Router.finish(self)
        onSubmit?(answers)
    }

    private func submitPinnedConfirmation(value: String) {
        guard let question = currentQuestion else { return }
        answers[question.id] = .single(value)
        onAnswersChange?(answers)
        suppressKeyboard = false
        focusedQuestionId = nil
        dismissAndSubmit()
    }

    // MARK: - Custom text

    private func commitCustomText(for question: AskQuestion) {
        let text = (customTexts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answers[question.id] = .custom(text)
        onAnswersChange?(answers)
    }

    private func commitCustomTextIfNeeded() {
        if let question = currentQuestion {
            commitCustomText(for: question)
        }
    }

    private func commitCustomFromKeyboard() async {
        await finalizeDictationIfNeeded()
        guard let question = currentQuestion else { return }
        commitCustomText(for: question)
        focusedQuestionId = nil
        if isSingleQuestionSingleSelect {
            suppressKeyboard = false
            dismissAndSubmit()
        }
    }

    private func loadCustomTextsFromAnswers() {
        for (key, answer) in answers {
            if case .custom(let text) = answer {
                customTexts[key] = text
            }
        }
    }

    // MARK: - Dictation

    private func handleDictationTap() async {
        guard let question = currentQuestion, let manager = voiceInputManager else { return }
        guard ComposerShared.canControlVoiceInput(manager, owner: .askCard) else { return }
        switch ComposerShared.micTapAction(for: manager.state) {
        case .stop, .cancelPreparing:
            guard dictationQuestionId == question.id else { return }
            await finalizeDictationIfNeeded()
        case .start:
            await startDictation(for: question, manager: manager)
        case .ignore:
            break
        }
        applyChrome()
    }

    private func startDictation(for question: AskQuestion, manager: VoiceInputManager) async {
        let base = customTexts[question.id] ?? ""
        dictationQuestionId = question.id
        dictationBaseText = base
        revealCustomAnswerChrome(for: question.id)
        do {
            try await ComposerShared.startVoiceInput(
                manager: manager,
                keyboardLanguage: keyboardLanguage,
                owner: .askCard,
                baseText: base,
                getText: { [weak self] in self?.customTexts[question.id] ?? "" },
                setText: { [weak self] value in self?.customTexts[question.id] = value },
                getTextBeforeRecording: { [weak self] in self?.dictationPrefixText },
                setTextBeforeRecording: { [weak self] value in self?.dictationPrefixText = value ?? "" },
                getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
                setSuppressKeyboard: { [weak self] value in self?.suppressKeyboard = value },
                getFocusRequestID: { [weak self] in self?.focusRequestID ?? 0 },
                setFocusRequestID: { [weak self] value in
                    self?.focusRequestID = value
                    self?.customTextView.becomeFirstResponder()
                }
            )
        } catch {
            clearDictationState()
        }
    }

    private func applyDictationTranscript(_ transcript: String, for questionId: String) {
        guard dictationQuestionId == questionId else { return }
        let combined = AskCardExpanded.combinedDictationText(
            base: dictationBaseText,
            prefix: dictationPrefixText,
            transcript: transcript
        )
        guard combined != customTexts[questionId] else { return }
        customTexts[questionId] = combined
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            answers[questionId] = .custom(trimmed)
            onAnswersChange?(answers)
        }
        if let question = currentQuestion {
            applyCustomField(question: question)
            applyFooterActions()
        }
    }

    private func finalizeDictationIfNeeded() async {
        guard let manager = voiceInputManager, let questionId = dictationQuestionId else { return }
        guard ComposerShared.ownsVoiceInput(manager, owner: .askCard) else { return }
        defer { clearDictationState() }
        if manager.isRecording {
            await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
                manager: manager,
                owner: .askCard,
                getText: { [weak self] in self?.customTexts[questionId] ?? "" },
                setText: { [weak self] value in self?.customTexts[questionId] = value },
                getTextBeforeRecording: { [weak self] in self?.dictationPrefixText },
                setTextBeforeRecording: { [weak self] value in self?.dictationPrefixText = value ?? "" },
                getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
                setSuppressKeyboard: { [weak self] value in self?.suppressKeyboard = value }
            )
        } else if manager.isPreparing {
            await ComposerShared.cancelOwnedVoiceInput(
                manager: manager,
                owner: .askCard,
                setTextBeforeRecording: { [weak self] value in self?.dictationPrefixText = value ?? "" },
                setSuppressKeyboard: { [weak self] value in self?.suppressKeyboard = value }
            )
        }
    }

    private func cancelDictationIfNeeded(for questionId: String? = nil) {
        guard let manager = voiceInputManager, let activeQuestionId = dictationQuestionId else { return }
        if let questionId, activeQuestionId != questionId { return }
        clearDictationState()
        Task {
            await ComposerShared.cancelOwnedVoiceInput(
                manager: manager,
                owner: .askCard,
                setTextBeforeRecording: { [weak self] value in self?.dictationPrefixText = value ?? "" },
                setSuppressKeyboard: { _ in }
            )
        }
    }

    private func clearDictationState() {
        dictationQuestionId = nil
        dictationBaseText = ""
        dictationPrefixText = ""
    }

    /// Focusing or dictating a custom answer lifts the sheet to its large
    /// detent so the field and keyboard both fit.
    private func revealCustomAnswerChrome(for questionId: String) {
        focusedQuestionId = questionId
        if let request, AskCardExpanded.sheetDetentForCustomAnswerFocus(
            request: request,
            isCustomAnswerFocused: true
        ) != nil {
            Router.selectSheetDetent(.large, of: self)
        }
        applyChrome()
    }

    private func handleKeyboardRestoreRequest() {
        suppressKeyboard = false
        guard dictationQuestionId != nil else { return }
        Task { await finalizeDictationIfNeeded() }
    }

    private func correctionRangesForDisplay(questionId: String) -> [NSRange] {
        guard dictationQuestionId == questionId,
              let manager = voiceInputManager,
              ComposerShared.ownsVoiceInput(manager, owner: .askCard) else { return [] }
        let offset = (dictationPrefixText as NSString).length
        return manager.currentTranscriptCorrectionRanges.map { range in
            NSRange(location: range.location + offset, length: range.length)
        }
    }

    private func updateKeyboardLanguage() {
        guard !customTextView.isKeyboardSuppressed, customTextView.isFirstResponder else { return }
        let language = customTextView.textInputMode?.primaryLanguage
        keyboardLanguage = language
        guard let manager = voiceInputManager,
              AppPreferences.Keyboard.normalize(language) != nil else { return }
        Task {
            await manager.prewarm(keyboardLanguage: language, source: "ask_card_keyboard_change")
        }
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        guard let question = currentQuestion else { return }
        let newValue = textView.text ?? ""
        customTexts[question.id] = newValue
        customPlaceholder.isHidden = !newValue.isEmpty
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            answers[question.id] = .custom(trimmed)
            onAnswersChange?(answers)
        }
        applyCustomField(question: question)
        applyFooterActions()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let question = currentQuestion else { return }
        revealCustomAnswerChrome(for: question.id)
        updateKeyboardLanguage()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard focusedQuestionId == currentQuestion?.id else { return }
        focusedQuestionId = nil
        applyChrome()
    }
}

/// Answer row that does not clip its children's touch bands (the mic's band
/// reaches past the row's height) to its own bounds.
private final class AskAnswerInputRow: UIStackView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || arrangedSubviews.contains { view in
            !view.isHidden && view.point(inside: convert(point, to: view), with: event)
        }
    }
}
