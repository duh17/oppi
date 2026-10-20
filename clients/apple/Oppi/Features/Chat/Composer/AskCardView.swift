import UIKit

// MARK: - Card view

/// What the inline Ask card draws. `AskCardViewController` owns the rules
/// (submission, paging, auto-advance) and hands the view this snapshot.
struct AskCardViewState {
    var request: AskRequest
    var page: Int
    var answers: [String: AskAnswer]
    var isSubmitted: Bool
    var responseFailed: Bool
    var colors: ComposerThemeColors
    var reduceMotion: Bool

    var question: AskQuestion? {
        page < request.questions.count ? request.questions[page] : nil
    }

    var isSingleQuestionSingleSelect: Bool {
        request.questions.count == 1 && !request.questions[0].multiSelect
    }

    var isLastQuestionPage: Bool {
        !isSingleQuestionSingleSelect && page == request.questions.count - 1
    }
}

/// The inline Ask card in the composer's Ask slot.
///
/// ```
/// ╭──────────────────────────────────────╮
/// │ Question text (≤ 6 lines)        ⤢  │ ┐
/// │ [☑ Select multiple]                  │ │ scrolls inside the card
/// │ ┌ option row, height fits text ┐    │ │ when the slot is capped
/// │ └──────────────────────────────┘    │ │
/// │            • ○ ○                     │ ┘ pager, several questions only
/// ├──────────────────────────────────────┤ hairline while rows scroll beneath
/// │ Expires…   Done (2)  Ignore →  Send │ actions stay in reach
/// ╰──────────────────────────────────────╯
/// ```
///
/// The card is opaque so the timeline behind the composer's glass cannot show
/// through, and its frame stays put while its rows scroll, so the scrolling
/// content always meets a clean rounded edge.
@MainActor
final class AskCardView: UIView, UIScrollViewDelegate {
    var onOptionTap: ((AskOption, AskQuestion) -> Void)?
    var onIgnore: (() -> Void)?
    var onSend: (() -> Void)?
    var onDone: (() -> Void)?
    var onExpand: (() -> Void)?
    var onSelectPage: ((Int) -> Void)?
    /// The card's natural height changed; the slot caps it.
    var onHeightChange: (() -> Void)?

    static let cornerRadius: CGFloat = 16
    private static let contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 4, trailing: 12)

    let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let tipHost = FeatureEducationTipHostView(
        tip: FeatureEducationTips.AnswerPromptTip(),
        descriptor: FeatureEducationTips.answerPrompt,
        insets: NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12)
    )
    private let questionRow = UIView()
    private let questionLabel = UILabel()
    private let expandButton = UIButton(type: .system)
    private let selectionPill = AskSelectionModePillView()
    private let commandPreview = AskCommandPreviewView()
    private let optionsStack = UIStackView()
    private let pagerRow = UIView()
    private let pagerDots = UIStackView()
    private let pagerLabel = UILabel()
    private let topEdge = UIView()
    private let footerEdge = UIView()
    private let footer = UIStackView()
    private let statusLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let ignoreButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)

    private var optionRows: [AskOptionChoiceRowView] = []
    private var pageButtons: [UIButton] = []
    private var state: AskCardViewState?
    private var builtRequest: AskRequest?
    private var builtPage: Int?
    private var lastReportedHeight: CGFloat = -1
    private var lastLayoutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        clipsToBounds = true
        buildHierarchy()
        tipHost.onHeightChange = { [weak self] in self?.reportHeightIfNeeded() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (card: Self, _) in
            card.rebuild()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            tipHost.start()
        } else {
            tipHost.stop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Settle the scroll view's content size before deciding whether it scrolls.
        scrollView.layoutIfNeeded()
        updateScrollEdges()
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            reportHeightIfNeeded()
        }
    }

    // MARK: Build

    private func buildHierarchy() {
        scrollView.accessibilityIdentifier = "chat.ask.scroll"
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = false
        scrollView.keyboardDismissMode = .none
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        buildQuestionRow()
        optionsStack.axis = .vertical
        optionsStack.spacing = 8
        buildPager()

        for view in [tipHost, questionRow, selectionPillRow, commandPreview, optionsStack, pagerRow] as [UIView] {
            contentStack.addArrangedSubview(view)
        }
        contentStack.setCustomSpacing(4, after: tipHost)
        contentStack.setCustomSpacing(10, after: questionRow)
        contentStack.setCustomSpacing(10, after: selectionPillRow)
        contentStack.setCustomSpacing(10, after: commandPreview)
        contentStack.setCustomSpacing(2, after: optionsStack)

        buildFooter()
        for edge in [topEdge, footerEdge] {
            edge.translatesAutoresizingMaskIntoConstraints = false
            edge.isUserInteractionEnabled = false
            edge.alpha = 0
            addSubview(edge)
        }

        let insets = Self.contentInsets
        let hairline = 1 / max(traitCollection.displayScale, 1)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: insets.leading),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -insets.trailing),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: insets.top),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -insets.bottom),
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            topEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            topEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            topEdge.topAnchor.constraint(equalTo: topAnchor),
            topEdge.heightAnchor.constraint(equalToConstant: hairline),
            footerEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerEdge.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerEdge.heightAnchor.constraint(equalToConstant: hairline),
        ])
    }

    /// The pill hugs its text at the leading edge.
    private lazy var selectionPillRow: UIView = {
        let row = UIView()
        selectionPill.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(selectionPill)
        NSLayoutConstraint.activate([
            selectionPill.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            selectionPill.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            selectionPill.topAnchor.constraint(equalTo: row.topAnchor),
            selectionPill.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }()

    /// Question text with the expand control in the card's top-trailing
    /// corner. The control's 44 pt square reaches into the card padding so its
    /// glyph centers on the first line of text.
    private func buildQuestionRow() {
        questionLabel.font = AskUIFont.preferred(.subheadline, weight: .medium)
        questionLabel.adjustsFontForContentSizeCategory = true
        questionLabel.numberOfLines = 0
        questionLabel.lineBreakMode = .byTruncatingTail
        questionLabel.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "arrow.up.left.and.arrow.down.right",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        )
        config.contentInsets = .zero
        expandButton.configuration = config
        expandButton.accessibilityLabel = "Expand ask request"
        expandButton.accessibilityHint = "Opens the complete question and details"
        expandButton.accessibilityIdentifier = "ask.expand"
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
        expandButton.translatesAutoresizingMaskIntoConstraints = false

        questionRow.addSubview(questionLabel)
        questionRow.addSubview(expandButton)
        let side = AskCard.quietControlMinimumHitSize
        let hugsLabel = questionRow.bottomAnchor.constraint(equalTo: questionLabel.bottomAnchor)
        hugsLabel.priority = .defaultLow
        NSLayoutConstraint.activate([
            questionLabel.leadingAnchor.constraint(equalTo: questionRow.leadingAnchor),
            questionLabel.topAnchor.constraint(equalTo: questionRow.topAnchor),
            questionLabel.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: 2),
            questionRow.bottomAnchor.constraint(greaterThanOrEqualTo: questionLabel.bottomAnchor),
            questionRow.bottomAnchor.constraint(greaterThanOrEqualTo: expandButton.bottomAnchor),
            hugsLabel,
            expandButton.widthAnchor.constraint(equalToConstant: side),
            expandButton.heightAnchor.constraint(equalToConstant: side),
            expandButton.trailingAnchor.constraint(equalTo: questionRow.trailingAnchor, constant: 12),
            expandButton.topAnchor.constraint(equalTo: questionRow.topAnchor, constant: -12),
        ])
    }

    private func buildPager() {
        pagerDots.axis = .horizontal
        pagerDots.alignment = .center
        pagerDots.spacing = 0
        pagerLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        pagerLabel.adjustsFontForContentSizeCategory = true
        pagerLabel.textAlignment = .center
        for view in [pagerDots, pagerLabel] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pagerRow.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: pagerRow.centerXAnchor),
                view.topAnchor.constraint(equalTo: pagerRow.topAnchor),
                view.bottomAnchor.constraint(equalTo: pagerRow.bottomAnchor),
            ])
        }
        pagerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: AskCard.quietControlMinimumHitSize).isActive = true
    }

    private func buildFooter() {
        footer.axis = .horizontal
        footer.alignment = .center
        footer.spacing = 4
        footer.isLayoutMarginsRelativeArrangement = true
        footer.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 4, trailing: 6)
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        statusLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 2
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        ignoreButton.accessibilityIdentifier = AskCard.ignoreAccessibilityIdentifier
        ignoreButton.addAction(UIAction { [weak self] _ in self?.onIgnore?() }, for: .touchUpInside)
        sendButton.accessibilityIdentifier = "ask.send"
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)

        for button in [doneButton, ignoreButton, sendButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: AskCard.quietControlMinimumHitSize),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: AskCard.quietControlMinimumHitSize),
            ])
        }
        for view in [statusLabel, doneButton, ignoreButton, sendButton] as [UIView] {
            footer.addArrangedSubview(view)
        }
    }

    // MARK: Apply

    func apply(_ next: AskCardViewState) {
        let pageChanged = builtRequest?.id != next.request.id || builtPage != next.page
        let structureChanged = builtRequest != next.request || builtPage != next.page
        let hadPage = builtPage != nil
        state = next
        if structureChanged {
            rebuild()
            if pageChanged {
                scrollView.setContentOffset(.zero, animated: false)
                if hadPage, !next.reduceMotion {
                    UIView.transition(
                        with: contentStack,
                        duration: 0.2,
                        options: [.transitionCrossDissolve, .allowUserInteraction],
                        animations: nil
                    )
                }
            }
        } else {
            update()
        }
    }

    /// Natural height at `width`: the scrolling content plus the footer.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard width > 1 else { return 0 }
        let insets = Self.contentInsets
        let contentWidth = width - insets.leading - insets.trailing
        let content = contentStack.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let footerHeight = footer.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        return ceil(insets.top + content + insets.bottom + footerHeight)
    }

    var lastMeasuredHeight: CGFloat { max(lastReportedHeight, 0) }

    /// Rebuilds rows for a new request or page; everything else updates in place.
    private func rebuild() {
        guard let state else { return }
        builtRequest = state.request
        builtPage = state.page
        optionRows.forEach { $0.removeFromSuperview() }
        optionRows = []
        if let question = state.question {
            for option in question.options {
                let row = AskOptionChoiceRowView(density: .inline)
                row.onTap = { [weak self] in self?.onOptionTap?(option, question) }
                optionsStack.addArrangedSubview(row)
                optionRows.append(row)
            }
        }
        optionsStack.isHidden = optionRows.isEmpty

        pageButtons.forEach { $0.removeFromSuperview() }
        pageButtons = []
        let total = AskCard.pageCount(for: state.request)
        if state.request.questions.count > 1, total <= 4 {
            for index in 0..<total {
                let button = makePageButton(index: index, total: total)
                pagerDots.addArrangedSubview(button)
                pageButtons.append(button)
            }
        }
        update()
    }

    private func makePageButton(index: Int, total: Int) -> UIButton {
        let button = UIButton(type: .custom)
        let dot = UIView()
        dot.isUserInteractionEnabled = false
        dot.layer.cornerRadius = 3.5
        dot.tag = 1
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        let side = AskCard.quietControlMinimumHitSize
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: side),
            button.heightAnchor.constraint(equalToConstant: side),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.accessibilityLabel = "Question \(index + 1) of \(total)"
        button.accessibilityIdentifier = AskCard.pageAccessibilityIdentifier(index)
        button.addAction(UIAction { [weak self] _ in self?.onSelectPage?(index) }, for: .touchUpInside)
        return button
    }

    private func update() {
        guard let state else { return }
        let colors = state.colors
        backgroundColor = colors.bgDark
        layer.borderColor = colors.comment.withAlphaComponent(0.18).cgColor
        topEdge.backgroundColor = colors.comment.withAlphaComponent(0.25)
        footerEdge.backgroundColor = colors.comment.withAlphaComponent(0.25)

        if let question = state.question {
            applyQuestion(question, state: state)
            for (row, option) in zip(optionRows, question.options) {
                row.apply(
                    option: option,
                    isSelected: AskCardShared.isOptionSelected(option, in: question, answers: state.answers),
                    isMultiSelect: question.multiSelect,
                    colors: colors
                )
                row.isEnabled = !state.isSubmitted
            }
        }
        applyPager(state)
        applyFooter(state)
        setNeedsLayout()
        reportHeightIfNeeded()
    }

    private func applyQuestion(_ question: AskQuestion, state: AskCardViewState) {
        let colors = state.colors
        let display = AskCard.inlineQuestionDisplay(for: question.question)
        let summary = display.summary.isEmpty ? "Review this request." : display.summary
        let category = traitCollection.preferredContentSizeCategory
        questionLabel.text = summary
        questionLabel.textColor = colors.fg
        questionLabel.numberOfLines = AskCard.usesInlineQuestionPreview(summary, contentSizeCategory: category)
            ? AskCard.inlineQuestionLineLimit(for: category)
            : 0
        questionLabel.accessibilityLabel = "Question: \(summary)"
        expandButton.configuration?.baseForegroundColor = colors.comment

        selectionPill.apply(question: question, colors: colors)
        selectionPillRow.isHidden = selectionPill.isHidden
        if let command = display.commandPreview {
            commandPreview.apply(command: command, colors: colors)
            commandPreview.isHidden = false
        } else {
            commandPreview.isHidden = true
        }
    }

    private func applyPager(_ state: AskCardViewState) {
        let total = AskCard.pageCount(for: state.request)
        pagerRow.isHidden = state.request.questions.count <= 1
        pagerDots.isHidden = pageButtons.isEmpty
        pagerLabel.isHidden = !pageButtons.isEmpty
        pagerLabel.text = "\(state.page + 1) of \(total)"
        pagerLabel.textColor = state.colors.comment
        for (index, button) in pageButtons.enumerated() {
            let current = index == state.page
            button.viewWithTag(1)?.backgroundColor = current
                ? state.colors.blue
                : state.colors.comment.withAlphaComponent(0.35)
            button.isEnabled = !state.isSubmitted
            button.accessibilityTraits = current ? [.button, .selected] : [.button]
        }
    }

    private func applyFooter(_ state: AskCardViewState) {
        let colors = state.colors
        if state.responseFailed {
            statusLabel.attributedText = nil
            statusLabel.text = "Couldn't confirm response. Try again."
            statusLabel.textColor = colors.orange
        } else if let timeout = timeoutSummary(state.request) {
            let text = NSMutableAttributedString()
            if let timer = UIImage(systemName: "timer")?.withTintColor(colors.comment, renderingMode: .alwaysOriginal) {
                text.append(NSAttributedString(attachment: NSTextAttachment(image: timer)))
                text.append(NSAttributedString(string: " "))
            }
            text.append(NSAttributedString(string: timeout))
            text.addAttributes(
                [.font: statusLabel.font as Any, .foregroundColor: colors.comment],
                range: NSRange(location: 0, length: text.length)
            )
            statusLabel.attributedText = text
        } else {
            statusLabel.attributedText = nil
            statusLabel.text = nil
        }

        let question = state.question
        let selected = question.flatMap { AskCardShared.multiSelectCount(for: $0, answers: state.answers) } ?? 0
        let showsDone = question?.multiSelect == true && selected > 0 && !state.isLastQuestionPage
        doneButton.isHidden = !showsDone
        if showsDone {
            doneButton.configuration = Self.capsuleConfiguration(
                title: "Done (\(selected) selected)",
                foreground: colors.blue,
                fill: colors.blue.withAlphaComponent(0.14)
            )
        }
        doneButton.isEnabled = !state.isSubmitted

        let ignoreTitle = state.isLastQuestionPage ? "Ignore & Send" : "Ignore"
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let title = NSMutableAttributedString(
            string: ignoreTitle,
            attributes: [.font: font, .foregroundColor: colors.comment]
        )
        title.append(NSAttributedString(
            string: " \u{2192}",
            attributes: [.font: font, .foregroundColor: colors.comment.withAlphaComponent(0.6)]
        ))
        var ignoreConfig = UIButton.Configuration.plain()
        ignoreConfig.attributedTitle = AttributedString(title)
        ignoreConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        ignoreButton.configuration = ignoreConfig
        ignoreButton.accessibilityLabel = "\(ignoreTitle) \u{2192}"
        ignoreButton.isEnabled = !state.isSubmitted

        sendButton.isHidden = !state.isLastQuestionPage
        if state.isLastQuestionPage {
            sendButton.configuration = Self.capsuleConfiguration(
                title: state.responseFailed ? "Retry" : "Send",
                foreground: ComposerColorContrast.foreground(for: colors.blue, fg: colors.fg, bg: colors.bg),
                fill: colors.blue
            )
        }
        sendButton.isEnabled = !state.isSubmitted
    }

    /// A 32 pt capsule drawn inside the button's 44 pt touch target.
    private static func capsuleConfiguration(title: String, foreground: UIColor, fill: UIColor) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = foreground
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = AskUIFont.preferred(.footnote, weight: .semibold)
            return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        config.background.backgroundColor = fill
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        config.background.cornerRadius = 16
        return config
    }

    private func timeoutSummary(_ request: AskRequest) -> String? {
        guard let timeout = request.timeout, timeout > 0 else { return nil }
        let seconds = max(1, (timeout + 999) / 1000)
        return "Expires in about \(seconds) seconds"
    }

    // MARK: Height and scroll edges

    private func reportHeightIfNeeded() {
        let height = preferredHeight(for: bounds.width)
        guard height > 0, abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onHeightChange?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollEdges()
    }

    /// Hairlines mark the edges only while rows actually pass under them.
    private func updateScrollEdges() {
        let offset = scrollView.contentOffset.y
        let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
        let scrollable = maxOffset > 0.5
        scrollView.isScrollEnabled = scrollable
        topEdge.alpha = scrollable && offset > 0.5 ? 1 : 0
        footerEdge.alpha = scrollable && offset < maxOffset - 0.5 ? 1 : 0
    }
}

// MARK: - Command preview

private final class AskCommandPreviewView: UIView {
    private let titleLabel = UILabel()
    private let commandLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = AskUIFont.preferred(.caption2, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = "Command"
        commandLabel.font = AskUIFont.monospaced(.footnote, weight: .semibold)
        commandLabel.adjustsFontForContentSizeCategory = true
        commandLabel.numberOfLines = 2
        commandLabel.lineBreakMode = .byTruncatingTail
        let stack = UIStackView(arrangedSubviews: [titleLabel, commandLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        isAccessibilityElement = true
        accessibilityLabel = "Command preview"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(command: String, colors: ComposerThemeColors) {
        commandLabel.text = command
        commandLabel.textColor = colors.fg
        titleLabel.textColor = colors.comment
        backgroundColor = colors.bgHighlight
        layer.borderColor = colors.comment.withAlphaComponent(0.12).cgColor
        accessibilityValue = command
    }
}

// MARK: - Card controller

/// The inline Ask card in `ComposerBarController`'s Ask slot.
///
/// Owns the response rules: single-question single-choice sends on tap, other
/// single-choice taps advance after a short delay that any newer intent
/// cancels, Ignore omits the current answer, and the last page sends. A local
/// submission claim blocks a second response until delivery fails, and the
/// expanded sheet shares the page and draft answers both ways.
@MainActor
final class AskCardViewController: UIViewController {
    var onPageChange: ((Int) -> Void)?
    var onAnswersChange: (([String: AskAnswer]) -> Void)?
    var onSubmit: (([String: AskAnswer], @escaping AskResponseSubmission.Completion) -> Void)?
    var onIgnoreAll: ((@escaping AskResponseSubmission.Completion) -> Void)?
    /// The card's natural height changed (slot margins included).
    var onHeightChange: ((CGFloat) -> Void)?
    var autoAdvanceController: AskInlineAutoAdvanceController?
    var voiceInputManager: VoiceInputManager?

    /// Card inset inside the composer capsule.
    static let margins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12)

    private let card = AskCardView()
    private var request: AskRequest?
    private var currentPage = 0
    private var answers: [String: AskAnswer] = [:]
    private var submittedRequestID: String?
    private var responseFailed = false
    private var colors = ComposerThemeColors.placeholder
    private var reduceMotion = false
    private var presentedAtNs: UInt64 = 0
    private var didRecordResponseMetric = false
    private let submission = AskResponseSubmission()
    private let ownedAutoAdvance = AskInlineAutoAdvanceController()
    private weak var expanded: AskCardExpandedViewController?

    private var pageAdvance: AskInlineAutoAdvanceController {
        autoAdvanceController ?? ownedAutoAdvance
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        let margins = Self.margins
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margins.leading),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margins.trailing),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: margins.top),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margins.bottom),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        card.onOptionTap = { [weak self] option, question in self?.handleOptionTap(option, question: question) }
        card.onIgnore = { [weak self] in self?.handleIgnore() }
        card.onSend = { [weak self] in
            guard let self else { return }
            self.submitAnswers(self.answers, surface: "inline")
        }
        card.onDone = { [weak self] in self?.confirmMultiSelect() }
        card.onExpand = { [weak self] in self?.presentExpanded() }
        card.onSelectPage = { [weak self] page in self?.selectPage(page) }
        card.onHeightChange = { [weak self] in self?.reportHeight() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentedAtNs == 0 {
            presentedAtNs = AskCard.timestampNs()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if expanded == nil {
            pageAdvance.invalidate()
        }
    }

    /// Natural slot height at `width`, margins included.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let margins = Self.margins
        return card.preferredHeight(for: width - margins.leading - margins.trailing)
            + margins.top + margins.bottom
    }

    func apply(
        request: AskRequest,
        currentPage: Int,
        answers: [String: AskAnswer],
        submittedRequestID: String?,
        responseFailed: Bool,
        colors: ComposerThemeColors,
        reduceMotion: Bool
    ) {
        let previous = self.request
        if previous?.id != request.id {
            didRecordResponseMetric = false
            presentedAtNs = AskCard.timestampNs()
        }
        submission.applyRequestIDChange(request.id)
        let clamped = AskCard.clampedPage(currentPage, for: request)
        let pageMoved = previous != nil && clamped != self.currentPage
        self.request = request
        self.currentPage = clamped
        self.answers = answers
        self.submittedRequestID = submittedRequestID
        self.responseFailed = responseFailed
        self.colors = colors
        self.reduceMotion = reduceMotion
        if previous != request {
            // A replaced request (or same-id content update) clamps the page
            // and cancels any pending advance.
            applyRequestIdentity(invalidatePending: true)
            if clamped != currentPage {
                onPageChange?(clamped)
            }
        } else {
            // The composer moves pages too (a typed answer advances); a page
            // change from anywhere cancels a pending advance.
            applyRequestIdentity(invalidatePending: pageMoved)
        }
        if isAskSubmitted {
            pageAdvance.invalidate()
        }
        render()
        expanded?.apply(
            request: request,
            currentPage: clamped,
            answers: answers,
            colors: colors,
            reduceMotion: reduceMotion
        )
    }

    /// The Ask went away: close its expanded sheet and drop pending advances.
    func tearDown() {
        pageAdvance.invalidate()
        if let expanded {
            Router.finish(expanded)
        }
    }

    // MARK: Rules

    private var isAskSubmitted: Bool {
        guard let request else { return false }
        return submittedRequestID == request.id || submission.blocksResponse(to: request.id)
    }

    private var isSingleQuestionSingleSelect: Bool {
        guard let request else { return true }
        return request.questions.count == 1 && !request.questions[0].multiSelect
    }

    private var isLastQuestionPage: Bool {
        guard let request else { return false }
        return !isSingleQuestionSingleSelect && currentPage == request.questions.count - 1
    }

    private var currentQuestion: AskQuestion? {
        guard let request, currentPage < request.questions.count else { return nil }
        return request.questions[currentPage]
    }

    private func render() {
        guard let request else { return }
        card.apply(AskCardViewState(
            request: request,
            page: currentPage,
            answers: answers,
            isSubmitted: isAskSubmitted,
            responseFailed: responseFailed || submission.phase == .failed(request.id),
            colors: colors,
            reduceMotion: reduceMotion
        ))
    }

    private func reportHeight() {
        let width = view.bounds.width
        guard width > 1 else { return }
        onHeightChange?(preferredHeight(for: width))
    }

    private func handleOptionTap(_ option: AskOption, question: AskQuestion) {
        guard let request, !isAskSubmitted else { return }
        var next = answers
        var selectedSingle = false
        AskCardShared.handleOptionTap(option, question: question, answers: &next) {
            selectedSingle = true
        }
        answers = next
        onAnswersChange?(next)
        if selectedSingle {
            if isSingleQuestionSingleSelect {
                pageAdvance.invalidate()
                submitAnswers(next, surface: "inline")
            } else if !isLastQuestionPage {
                applyRequestIdentity(invalidatePending: false)
                pageAdvance.schedule(requestID: request.id, page: currentPage) { [weak self] in
                    self?.advanceToNextPage()
                }
            }
        }
        render()
    }

    private func handleIgnore() {
        guard !isAskSubmitted, let question = currentQuestion else { return }
        AppHaptics.impact(style: .soft)
        pageAdvance.invalidate()
        // Ignored means omitted from the answer map.
        answers[question.id] = nil
        onAnswersChange?(answers)
        if isSingleQuestionSingleSelect {
            ignoreAll(surface: "inline")
        } else if isLastQuestionPage {
            submitAnswers(answers, surface: "inline")
        } else {
            advanceToNextPage()
        }
        render()
    }

    private func confirmMultiSelect() {
        AppHaptics.impact(style: .light)
        pageAdvance.invalidate()
        advanceToNextPage()
    }

    private func selectPage(_ page: Int) {
        pageAdvance.invalidate()
        guard page != currentPage else { return }
        setPage(page)
    }

    private func advanceToNextPage() {
        guard let request, currentPage < AskCard.pageCount(for: request) - 1 else { return }
        setPage(currentPage + 1)
    }

    private func setPage(_ page: Int) {
        guard let request else { return }
        currentPage = page
        onPageChange?(page)
        applyRequestIdentity(invalidatePending: true)
        render()
        UIAccessibility.post(
            notification: .announcement,
            argument: AskCard.pageAnnouncementText(
                page: page,
                questions: request.questions,
                isSingleQuestionSingleSelect: isSingleQuestionSingleSelect
            )
        )
    }

    private func applyRequestIdentity(invalidatePending: Bool) {
        guard let request else { return }
        pageAdvance.noteIdentity(request: request, page: currentPage)
        if invalidatePending {
            pageAdvance.invalidate()
        }
    }

    private func submitAnswers(_ submittedAnswers: [String: AskAnswer], surface: String) {
        guard let request, !isAskSubmitted else { return }
        pageAdvance.invalidate()
        submission.submit(requestID: request.id, deliver: { [weak self] complete in
            guard let self else { return }
            self.recordResponseMetric(
                outcome: submittedAnswers.isEmpty ? "empty" : "answered",
                surface: surface,
                submittedAnswers: submittedAnswers
            )
            self.onSubmit?(submittedAnswers, complete)
            FeatureEducationTips.markPromptAnswered()
        }, completion: { [weak self] _ in
            self?.render()
        })
        render()
    }

    private func ignoreAll(surface: String) {
        guard let request, !isAskSubmitted else { return }
        pageAdvance.invalidate()
        submission.submit(requestID: request.id, deliver: { [weak self] complete in
            guard let self else { return }
            self.recordResponseMetric(outcome: "ignored", surface: surface, submittedAnswers: [:])
            self.onIgnoreAll?(complete)
            FeatureEducationTips.markPromptAnswered()
        }, completion: { [weak self] _ in
            self?.render()
        })
        render()
    }

    // MARK: Expanded sheet

    private func presentExpanded() {
        guard let request, expanded == nil else { return }
        pageAdvance.invalidate()
        AppHaptics.toolbarExpansion()
        let sheet = AskCardExpandedViewController()
        sheet.voiceInputManager = voiceInputManager
        sheet.apply(
            request: request,
            currentPage: currentPage,
            answers: answers,
            colors: colors,
            reduceMotion: reduceMotion
        )
        sheet.onPageChange = { [weak self] page in
            guard let self, page != self.currentPage else { return }
            self.currentPage = page
            self.onPageChange?(page)
            self.applyRequestIdentity(invalidatePending: true)
            self.render()
        }
        sheet.onAnswersChange = { [weak self] answers in
            self?.answers = answers
            self?.onAnswersChange?(answers)
            self?.render()
        }
        sheet.onSubmit = { [weak self] answers in
            self?.answers = answers
            self?.submitAnswers(answers, surface: "expanded")
        }
        sheet.onIgnoreAll = { [weak self] in
            self?.ignoreAll(surface: "expanded")
        }
        expanded = sheet
        Router.present(
            sheet,
            presentation: ModalPresentation.sheet.detents(
                [.medium(), .large()],
                grabber: true,
                selected: .large,
                cornerRadius: 28
            ),
            from: self,
            theme: HostFactory.root(near: self)?.themeStore,
            onDismiss: { [weak self] in
                self?.expanded = nil
            }
        )
    }

    private func recordResponseMetric(
        outcome: String,
        surface: String,
        submittedAnswers: [String: AskAnswer]
    ) {
        guard !didRecordResponseMetric, let request else { return }
        didRecordResponseMetric = true
        let startedNs = presentedAtNs == 0 ? AskCard.timestampNs() : presentedAtNs
        let durationMs = Double((AskCard.timestampNs() &- startedNs) / 1_000_000)
        let tags = AskCard.responseMetricTags(
            request: request,
            answers: submittedAnswers,
            outcome: outcome,
            surface: surface
        )
        let sessionId = request.sessionId
        let workspaceId = request.workspaceId
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .askResponseMs,
                value: durationMs,
                unit: .ms,
                sessionId: sessionId,
                workspaceId: workspaceId,
                tags: tags
            )
        }
    }
}
