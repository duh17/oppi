import UIKit

private final class CodeBlockHeaderButton: UIButton {
    private static let minimumHitTarget: CGFloat = 44

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let horizontalInset = min(0, (bounds.width - Self.minimumHitTarget) / 2)
        let verticalInset = min(0, (bounds.height - Self.minimumHitTarget) / 2)
        return bounds.insetBy(dx: horizontalInset, dy: verticalInset).contains(point)
    }
}

/// Code block container with language badge, copy button, and syntax highlighting.
///
/// Renders a code block with language badge, copy button, and
/// optional syntax highlighting. Supports in-place content updates
/// for streaming.
final class NativeCodeBlockView: UIView {
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?

    private let headerStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.alignment = .center
        sv.spacing = 8
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let languageLabel: UILabel = {
        let l = UILabel()
        l.font = AppFont.mono
        l.lineBreakMode = .byTruncatingTail
        l.accessibilityIdentifier = "markdown.codeBlock.language"
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }()

    private let wrapButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: CodeWrapControl.symbolName)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 12, weight: .regular
        )
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = CodeBlockHeaderButton(type: .system)
        button.configuration = config
        button.accessibilityIdentifier = "markdown.codeBlock.wrap"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }()

    private let copyButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "doc.on.doc")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 10, weight: .regular
        )
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = CodeBlockHeaderButton(type: .system)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }()

    private let codeScrollView: HorizontalPanPassthroughScrollView = {
        let sv = HorizontalPanPassthroughScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.alwaysBounceVertical = false
        sv.bounces = false
        sv.isDirectionalLockEnabled = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let codeLabel: BaselineSafeTextView = {
        let tv = BaselineSafeTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.accessibilityIdentifier = "markdown.codeBlock.text"
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.setContentCompressionResistancePriority(.required, for: .horizontal)
        return tv
    }()

    private let headerBackground = UIView()
    private var currentCode: String = ""
    private var highlightedText: NSAttributedString?
    private var currentPalette: ThemePalette?
    private var isLineWrappingEnabled = false
    private var measuredUnwrappedCodeWidth: CGFloat = 0

    /// Horizontal padding around the text view inside `codeScrollView`.
    private static let codeHorizontalPadding: CGFloat = 24

    /// Explicit width constraint for the label. In the default unwrapped mode it
    /// is the measured code width so the scroll view can pan horizontally. In
    /// wrap mode it tracks the visible viewport width so TextKit wraps lines.
    private var codeLabelWidthConstraint: NSLayoutConstraint?

    private lazy var longPressCopyGesture: UILongPressGestureRecognizer = {
        UILongPressGestureRecognizer(target: self, action: #selector(longPressCopy(_:)))
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        accessibilityIdentifier = "markdown.codeBlock"
        layer.cornerRadius = 8
        layer.borderWidth = 1
        clipsToBounds = true

        headerBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBackground)
        addSubview(headerStack)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(languageLabel)
        headerStack.addArrangedSubview(spacer)
        headerStack.addArrangedSubview(wrapButton)
        headerStack.addArrangedSubview(copyButton)

        addSubview(codeScrollView)
        codeScrollView.addSubview(codeLabel)

        wrapButton.addTarget(self, action: #selector(wrapTapped), for: .touchUpInside)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        codeLabel.delegate = self
        codeScrollView.addGestureRecognizer(longPressCopyGesture)
        updateWrapButton()

        let widthConstraint = codeLabel.widthAnchor.constraint(equalToConstant: 0)
        codeLabelWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            headerBackground.topAnchor.constraint(equalTo: topAnchor),
            headerBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBackground.bottomAnchor.constraint(equalTo: headerStack.bottomAnchor),

            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            codeScrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 6),
            codeScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            codeLabel.topAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.topAnchor, constant: 12),
            codeLabel.leadingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            codeLabel.trailingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            codeLabel.bottomAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            codeLabel.heightAnchor.constraint(equalTo: codeScrollView.frameLayoutGuide.heightAnchor, constant: -24),
            widthConstraint,
        ])
    }

    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
        let selectionEnabled = router != nil && sourceContext != nil
        codeLabel.isSelectable = selectionEnabled
        longPressCopyGesture.isEnabled = !selectionEnabled
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isLineWrappingEnabled else { return }

        let width = wrappedCodeWidth()
        if abs((codeLabelWidthConstraint?.constant ?? 0) - width) > 0.5 {
            codeLabelWidthConstraint?.constant = width
            updateTextContainerForCurrentWrapping()
            codeLabel.invalidateIntrinsicContentSize()
        }
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        if isLineWrappingEnabled {
            let hasTargetWidth = targetSize.width.isFinite
                && targetSize.width > Self.codeHorizontalPadding
            let targetWidth = hasTargetWidth ? targetSize.width : nil
            let width = wrappedCodeWidth(availableWidth: targetWidth)
            if abs((codeLabelWidthConstraint?.constant ?? 0) - width) > 0.5 {
                codeLabelWidthConstraint?.constant = width
            }
            updateTextContainerForCurrentWrapping()
            codeLabel.invalidateIntrinsicContentSize()
        }

        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    // periphery:ignore:parameters isOpen
    func apply(language: String?, code: String, palette: ThemePalette, isOpen: Bool) {
        currentPalette = palette
        backgroundColor = UIColor(palette.bgDark)
        headerBackground.backgroundColor = UIColor(palette.bgHighlight)
        layer.borderColor = UIColor(palette.mdCodeBlockBorder).withAlphaComponent(0.5).cgColor

        languageLabel.text = language ?? "code"
        languageLabel.textColor = UIColor(palette.comment)
        copyButton.tintColor = UIColor(palette.fgDim)
        updateWrapButton()

        let font = AppFont.monoMedium

        if code == currentCode, let highlighted = highlightedText {
            codeLabel.attributedText = highlighted
            applyCurrentLineWrapping(resetHorizontalOffset: false)
            return
        }

        currentCode = code
        highlightedText = nil

        codeLabel.font = font
        codeLabel.textColor = UIColor(palette.fg)
        codeLabel.attributedText = nil
        codeLabel.text = code

        updateMeasuredCodeWidth(NSAttributedString(string: code, attributes: [.font: font]))
    }

    func applyHighlightedCode(_ highlighted: NSAttributedString) {
        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let font = AppFont.monoMedium
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)
        codeLabel.attributedText = mutable
        highlightedText = mutable

        updateMeasuredCodeWidth(mutable)
    }

    @objc private func wrapTapped() {
        isLineWrappingEnabled.toggle()
        updateWrapButton()
        applyCurrentLineWrapping(resetHorizontalOffset: true)
        invalidateTimelineLayout()
    }

    @objc private func copyTapped() {
        copyCodeAndShowFeedback()
    }

    @objc private func longPressCopy(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        copyCodeAndShowFeedback()
        showCopiedFlash()
    }

    private func copyCodeAndShowFeedback() {
        UIPasteboard.general.string = currentCode
        AppHaptics.impact(style: .light, intensity: 0.7)

        copyButton.configuration?.image = UIImage(systemName: "checkmark")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            self.copyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        }
    }

    private func updateMeasuredCodeWidth(_ text: NSAttributedString) {
        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = text.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
        measuredUnwrappedCodeWidth = max(1, ceil(boundingRect.width))
        applyCurrentLineWrapping(resetHorizontalOffset: false)
    }

    private func applyCurrentLineWrapping(resetHorizontalOffset: Bool) {
        codeLabel.textContainer.lineBreakMode = isLineWrappingEnabled ? .byCharWrapping : .byClipping
        codeScrollView.isScrollEnabled = !isLineWrappingEnabled
        codeScrollView.alwaysBounceHorizontal = false
        codeScrollView.showsHorizontalScrollIndicator = false
        codeLabelWidthConstraint?.constant = isLineWrappingEnabled ? wrappedCodeWidth() : measuredUnwrappedCodeWidth
        updateTextContainerForCurrentWrapping()

        if resetHorizontalOffset {
            codeScrollView.setContentOffset(.zero, animated: false)
        }

        codeLabel.invalidateIntrinsicContentSize()
        codeScrollView.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private func updateTextContainerForCurrentWrapping() {
        codeLabel.textContainer.widthTracksTextView = isLineWrappingEnabled
        codeLabel.textContainer.size = isLineWrappingEnabled
            ? CGSize(
                width: max(1, codeLabelWidthConstraint?.constant ?? wrappedCodeWidth()),
                height: CGFloat.greatestFiniteMagnitude
            )
            : CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeLabel.layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: codeLabel.textStorage.length),
            actualCharacterRange: nil
        )
        codeLabel.layoutManager.ensureLayout(for: codeLabel.textContainer)
    }

    private func wrappedCodeWidth(availableWidth explicitAvailableWidth: CGFloat? = nil) -> CGFloat {
        let availableWidth = explicitAvailableWidth
            ?? [codeScrollView.bounds.width, bounds.width, superview?.bounds.width ?? 0]
                .first(where: { $0 > Self.codeHorizontalPadding })
            ?? 320
        return max(1, availableWidth - Self.codeHorizontalPadding)
    }

    private func updateWrapButton() {
        let palette = currentPalette ?? ThemeRuntimeState.currentPalette()
        var config = wrapButton.configuration ?? .plain()
        config.title = nil
        config.image = UIImage(systemName: CodeWrapControl.symbolName)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 12, weight: .regular
        )
        config.baseForegroundColor = isLineWrappingEnabled ? UIColor(palette.blue) : UIColor(palette.fgDim)
        config.background.backgroundColor = isLineWrappingEnabled
            ? UIColor(palette.blue).withAlphaComponent(0.14)
            : .clear
        config.background.cornerRadius = 8
        wrapButton.configuration = config
        wrapButton.accessibilityLabel = isLineWrappingEnabled ? "Unwrap code lines" : "Wrap code lines"
        wrapButton.accessibilityValue = isLineWrappingEnabled ? "On" : "Off"
    }

    private func invalidateTimelineLayout() {
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    private func showCopiedFlash() {
        showCopiedOverlay(on: self)
    }
}

#if DEBUG
struct NativeCodeBlockLayoutDiagnostics {
    let wrapsLines: Bool
    let headerTopInset: CGFloat
    let headerHeight: CGFloat
    let codeTopInset: CGFloat
    let headerToCodeGap: CGFloat
}

extension NativeCodeBlockView {
    func layoutDiagnosticsForTesting() -> NativeCodeBlockLayoutDiagnostics {
        layoutIfNeeded()
        let headerFrame = headerStack.convert(headerStack.bounds, to: self)
        let codeFrame = codeScrollView.convert(codeScrollView.bounds, to: self)
        return NativeCodeBlockLayoutDiagnostics(
            wrapsLines: isLineWrappingEnabled,
            headerTopInset: headerFrame.minY,
            headerHeight: headerFrame.height,
            codeTopInset: codeFrame.minY,
            headerToCodeGap: codeFrame.minY - headerFrame.maxY
        )
    }
}
#endif

extension NativeCodeBlockView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}

/// UIKit markdown table.
///
/// Default path keeps monospaced single-line columns with horizontal scroll
/// (pixel-aligned via tab stops). Grid mode is used only when a column's
/// natural width exceeds the readable clamp; short columns stay one line and
/// the table may scroll sideways instead of squeezing to the viewport.
final class NativeTableBlockView: UIView {
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?
    private var resourceReferenceServerID: String?
    private var resourceReferenceWorkspaceID: String?

    /// Inner card that wraps the scroll view. Carries the background, border,
    /// and corner radius so it shrink-wraps to content width while the outer
    /// view (sized by SwiftUI) can be full-width and transparent.
    private let cardView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 8
        v.layer.borderWidth = 1
        v.clipsToBounds = true
        return v
    }()

    private let scrollView: HorizontalPanPassthroughScrollView = {
        let sv = HorizontalPanPassthroughScrollView()
        sv.showsHorizontalScrollIndicator = true
        sv.alwaysBounceVertical = false
        sv.bounces = false
        sv.isDirectionalLockEnabled = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let tableLabel: BaselineSafeTextView = {
        let tv = BaselineSafeTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = false
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.setContentCompressionResistancePriority(.required, for: .horizontal)
        return tv
    }()

    /// Multi-line grid used when any column clamps to `maxReadable`.
    /// Lives inside `scrollView` so a wide grid can pan horizontally.
    private let wrapStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    /// Explicit width constraint for the label, updated in `apply()` to the
    /// measured content width so UIScrollView knows the content is wider than
    /// the frame and enables horizontal scrolling.
    private var tableLabelWidthConstraint: NSLayoutConstraint?

    /// Card width constraint — shrinks to content or expands to parent width,
    /// whichever is smaller.
    private var cardWidthConstraint: NSLayoutConstraint?

    /// Explicit grid width (sum of clamped columns + gaps). This is the
    /// scroller content width; rows are not pinned to the card trailing edge.
    private var wrapStackWidthConstraint: NSLayoutConstraint?
    private var tableLabelContentConstraints: [NSLayoutConstraint] = []
    private var wrapStackContentConstraints: [NSLayoutConstraint] = []

    /// Stored for long-press copy — rebuilt as markdown table text.
    private var currentHeaders: [[MarkdownInline]] = []
    private var currentRows: [[[MarkdownInline]]] = []
    private var currentPalette: ThemePalette?
    /// Whether any cell contains a link (enables text view selectability for taps).
    private var hasLinks = false
    private var isWrapMode = false
    /// Identity of the last rendered table content/mode so streaming ticks can
    /// skip full wrap-grid reconstruction when nothing meaningful changed.
    private var renderedContentSignature: String = ""
    private var lastContentIdentity: String = ""

    private lazy var longPressCopyGesture: UILongPressGestureRecognizer = {
        UILongPressGestureRecognizer(target: self, action: #selector(longPressCopy(_:)))
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "markdown.table"
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        backgroundColor = .clear

        addSubview(cardView)
        cardView.addSubview(scrollView)
        scrollView.addSubview(tableLabel)
        scrollView.addSubview(wrapStack)

        tableLabel.delegate = self
        cardView.addGestureRecognizer(longPressCopyGesture)

        let labelWidthConstraint = tableLabel.widthAnchor.constraint(equalToConstant: 0)
        tableLabelWidthConstraint = labelWidthConstraint

        let cardWidth = cardView.widthAnchor.constraint(equalTo: widthAnchor)
        cardWidthConstraint = cardWidth

        let wrapWidth = wrapStack.widthAnchor.constraint(equalToConstant: 0)
        wrapStackWidthConstraint = wrapWidth

        tableLabelContentConstraints = [
            tableLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            tableLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            tableLabel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            tableLabel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            tableLabel.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            labelWidthConstraint,
        ]

        wrapStackContentConstraints = [
            wrapStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 6
            ),
            wrapStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: MarkdownTableColumnLayout.horizontalContentInset
            ),
            wrapStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -MarkdownTableColumnLayout.horizontalContentInset
            ),
            wrapStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -6
            ),
            wrapStack.heightAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.heightAnchor,
                constant: -12
            ),
            wrapWidth,
        ]

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardWidth,

            scrollView.topAnchor.constraint(equalTo: cardView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ])
        NSLayoutConstraint.activate(tableLabelContentConstraints)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        scrollView.flashScrollIndicators()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateCardWidth()
    }

    /// UIScrollView has no useful intrinsic height. Measure the active table
    /// body so chat self-sizing cannot clip the last wrapped row.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredTableHeight())
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let width = targetSize.width.isFinite && targetSize.width > 0
            ? targetSize.width
            : max(1, bounds.width)
        return CGSize(width: width, height: measuredTableHeight())
    }

    private func measuredTableHeight() -> CGFloat {
        if isWrapMode {
            let columnWidth = max(1, wrapStackWidthConstraint?.constant ?? 0)
            let stackSize = wrapStack.systemLayoutSizeFitting(
                CGSize(width: columnWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            return max(1, ceil(stackSize.height + 12))
        }

        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if let text = tableLabel.attributedText, text.length > 0 {
            let bounds = text.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
            return max(1, ceil(bounds.height + tableLabel.textContainerInset.top + tableLabel.textContainerInset.bottom))
        }
        return max(1, tableLabel.intrinsicContentSize.height)
    }

    /// Card width is min(contentWidth, bounds.width) in both clip and grid mode.
    private func updateCardWidth() {
        guard let constraint = cardWidthConstraint else { return }
        let parentWidth = bounds.width
        let contentWidth = currentContentWidth()

        if contentWidth > 0, parentWidth > 0, contentWidth < parentWidth {
            if constraint.firstAnchor === cardView.widthAnchor,
               constraint.secondAnchor === widthAnchor {
                constraint.isActive = false
                let absolute = cardView.widthAnchor.constraint(equalToConstant: contentWidth)
                cardWidthConstraint = absolute
                absolute.isActive = true
            } else {
                constraint.constant = contentWidth
            }
        } else {
            setCardWidthRelativeToParent(constraint)
        }
    }

    private func currentContentWidth() -> CGFloat {
        if isWrapMode {
            let columns = wrapStackWidthConstraint?.constant ?? 0
            return columns + MarkdownTableColumnLayout.horizontalContentInset * 2
        }
        return tableLabelWidthConstraint?.constant ?? 0
    }

    private func setCardWidthRelativeToParent(_ constraint: NSLayoutConstraint) {
        if constraint.firstAnchor === cardView.widthAnchor,
           constraint.secondAnchor === widthAnchor {
            return
        }
        constraint.isActive = false
        let relative = cardView.widthAnchor.constraint(equalTo: widthAnchor)
        cardWidthConstraint = relative
        relative.isActive = true
    }

    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
        let selectionEnabled = router != nil && sourceContext != nil
        tableLabel.isSelectable = selectionEnabled
        applySelectionStateToWrapCells(selectionEnabled: selectionEnabled || hasLinks)
        longPressCopyGesture.isEnabled = !selectionEnabled
    }

    func configureResourceReferenceScope(serverID: String?, workspaceID: String?) {
        resourceReferenceServerID = serverID
        resourceReferenceWorkspaceID = workspaceID
    }

    func apply(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], palette: ThemePalette) {
        let contentIdentity = Self.contentIdentity(headers: headers, rows: rows)
        let contentChanged = contentIdentity != lastContentIdentity
        lastContentIdentity = contentIdentity

        currentHeaders = headers
        currentRows = rows
        currentPalette = palette

        // Detect links in any cell for selectability.
        hasLinks = Self.containsLink(headers) || rows.contains { Self.containsLink($0) }

        cardView.backgroundColor = UIColor(palette.bgDark)
        cardView.layer.borderColor = UIColor(palette.mdCodeBlockBorder).withAlphaComponent(0.5).cgColor

        let metrics = Self.measureNaturalColumns(headers: headers, rows: rows)

        // Only snap horizontal offset when the table body actually changed.
        if contentChanged {
            scrollView.contentOffset = .zero
        }

        // Mode is content-only and chosen once per apply. Layout width never
        // rebuilds the table or flips clip vs grid.
        let previousMode = isWrapMode
        if MarkdownTableColumnLayout.needsGridMode(naturalWidths: metrics.columnWidths) {
            let widths = MarkdownTableColumnLayout.clampedColumnWidths(
                naturalWidths: metrics.columnWidths
            )
            renderWrapMode(columnWidths: widths, palette: palette, force: contentChanged)
        } else {
            renderClipMode(palette: palette, force: contentChanged)
        }

        if previousMode != isWrapMode {
            notifyHeightMayHaveChanged()
        }
        updateCardWidth()
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func notifyHeightMayHaveChanged() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        ToolTimelineRowPresentationHelpers.invalidateEnclosingStreamingHeightCache(startingAt: self)
    }

    private func renderClipMode(palette: ThemePalette, force: Bool) {
        let signature = "clip|" + lastContentIdentity
        let modeChanged = isWrapMode
        if !force, !modeChanged, renderedContentSignature == signature {
            return
        }

        isWrapMode = false
        tableLabel.isHidden = false
        wrapStack.isHidden = true
        NSLayoutConstraint.deactivate(wrapStackContentConstraints)
        NSLayoutConstraint.activate(tableLabelContentConstraints)
        if modeChanged {
            clearWrapStack()
        }

        if hasLinks || (reviewCommentSelectionRouter != nil && reviewCommentSourceContext != nil) {
            tableLabel.isSelectable = true
        } else {
            tableLabel.isSelectable = false
        }

        let attrText = Self.makeTableAttributedText(
            headers: currentHeaders,
            rows: currentRows,
            palette: palette
        )
        tableLabel.attributedText = attrText
        tableLabel.linkTextAttributes = [
            .foregroundColor: UIColor(palette.blue),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = attrText.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
        tableLabelWidthConstraint?.constant = ceil(boundingRect.width)
        renderedContentSignature = signature
        if modeChanged || force {
            notifyHeightMayHaveChanged()
        }
    }

    private func renderWrapMode(columnWidths: [CGFloat], palette: ThemePalette, force: Bool) {
        let signature = "wrap|" + lastContentIdentity
        let modeChanged = !isWrapMode
        if !force, !modeChanged, renderedContentSignature == signature {
            return
        }

        isWrapMode = true
        tableLabel.isHidden = true
        wrapStack.isHidden = false
        NSLayoutConstraint.deactivate(tableLabelContentConstraints)
        let spacing = MarkdownTableColumnLayout.columnSpacing * CGFloat(max(0, columnWidths.count - 1))
        wrapStackWidthConstraint?.constant = columnWidths.reduce(0, +) + spacing
        NSLayoutConstraint.activate(wrapStackContentConstraints)
        tableLabel.attributedText = nil
        tableLabelWidthConstraint?.constant = 0
        clearWrapStack()

        let selectionEnabled = hasLinks
            || (reviewCommentSelectionRouter != nil && reviewCommentSourceContext != nil)

        let headerRow = makeWrapRow(
            cells: paddedCells(currentHeaders, count: columnWidths.count),
            columnWidths: columnWidths,
            palette: palette,
            isHeader: true,
            selectionEnabled: selectionEnabled,
            zebra: false
        )
        wrapStack.addArrangedSubview(headerRow)

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.25)
        let scale = max(traitCollection.displayScale, 1)
        separator.heightAnchor.constraint(equalToConstant: 1 / scale).isActive = true
        wrapStack.addArrangedSubview(separator)

        for (rowIndex, row) in currentRows.enumerated() {
            let body = makeWrapRow(
                cells: paddedCells(row, count: columnWidths.count),
                columnWidths: columnWidths,
                palette: palette,
                isHeader: false,
                selectionEnabled: selectionEnabled,
                zebra: rowIndex % 2 == 1
            )
            wrapStack.addArrangedSubview(body)
        }

        renderedContentSignature = signature
        notifyHeightMayHaveChanged()
    }

    private func clearWrapStack() {
        for view in wrapStack.arrangedSubviews {
            wrapStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func paddedCells(_ cells: [[MarkdownInline]], count: Int) -> [[MarkdownInline]] {
        var result = cells
        if result.count < count {
            result.append(contentsOf: Array(repeating: [.text("")], count: count - result.count))
        } else if result.count > count {
            result = Array(result.prefix(count))
        }
        return result
    }

    private func makeWrapRow(
        cells: [[MarkdownInline]],
        columnWidths: [CGFloat],
        palette: ThemePalette,
        isHeader: Bool,
        selectionEnabled: Bool,
        zebra: Bool
    ) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fill
        row.spacing = MarkdownTableColumnLayout.columnSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        if isHeader {
            row.backgroundColor = UIColor(palette.bgHighlight)
        } else if zebra {
            row.backgroundColor = UIColor(palette.bgHighlight).withAlphaComponent(0.45)
        } else {
            row.backgroundColor = .clear
        }

        for (index, cell) in cells.enumerated() {
            let width = index < columnWidths.count ? columnWidths[index] : 1
            let cellView = makeWrapCell(
                inlines: cell,
                width: width,
                palette: palette,
                isHeader: isHeader,
                selectionEnabled: selectionEnabled
            )
            row.addArrangedSubview(cellView)
        }
        return row
    }

    private func makeWrapCell(
        inlines: [MarkdownInline],
        width: CGFloat,
        palette: ThemePalette,
        isHeader: Bool,
        selectionEnabled: Bool
    ) -> UIView {
        let textView = BaselineSafeTextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = selectionEnabled
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(palette.blue),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        let font = isHeader ? AppFont.monoMediumBold : AppFont.monoMedium
        let color = isHeader ? UIColor(palette.cyan) : UIColor(palette.fg)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2

        let result = NSMutableAttributedString()
        Self.appendTableCellInlines(
            inlines,
            to: result,
            font: font,
            defaultColor: color,
            linkColor: UIColor(palette.blue),
            paragraph: paragraph
        )
        if result.length == 0 {
            result.append(NSAttributedString(string: " ", attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
        }
        textView.attributedText = result

        let resolvedWidth = max(1, width)
        // Required width + non-scrolling UITextView yields a live intrinsic height.
        // Pin the text container width now so self-sizing works before first layout.
        textView.textContainer.size = CGSize(
            width: resolvedWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.widthAnchor.constraint(equalToConstant: resolvedWidth).isActive = true
        return textView
    }

    private func applySelectionStateToWrapCells(selectionEnabled: Bool) {
        for row in wrapStack.arrangedSubviews {
            guard let stack = row as? UIStackView else { continue }
            for cell in stack.arrangedSubviews {
                (cell as? UITextView)?.isSelectable = selectionEnabled
            }
        }
    }

    private static func containsLink(_ cells: [[MarkdownInline]]) -> Bool {
        cells.contains { containsLink($0) }
    }

    private static func containsLink(_ inlines: [MarkdownInline]) -> Bool {
        inlines.contains { inline in
            switch inline {
            case .link:
                return true
            case .emphasis(let children),
                 .strong(let children),
                 .strikethrough(let children):
                return containsLink(children)
            case .text, .code, .image, .softBreak, .hardBreak, .html:
                return false
            }
        }
    }

    /// Measure the actual rendered width of a string in the given font.
    /// Correctly handles CJK, emoji, and mixed-script text via real metrics.
    private static func measuredTextWidth(_ string: String, font: UIFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func contentIdentity(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]]
    ) -> String {
        func inlineKey(_ inline: MarkdownInline) -> String {
            switch inline {
            case .text(let value):
                return "text:\(value.count):\(value)"
            case .emphasis(let children):
                return "emphasis:[\(children.map(inlineKey).joined(separator: ","))]"
            case .strong(let children):
                return "strong:[\(children.map(inlineKey).joined(separator: ","))]"
            case .code(let value):
                return "code:\(value.count):\(value)"
            case .link(let children, let destination):
                return "link:\(destination ?? ""):[\(children.map(inlineKey).joined(separator: ","))]"
            case .image(let alt, let source):
                return "image:\(alt):\(source ?? "")"
            case .softBreak:
                return "softBreak"
            case .hardBreak:
                return "hardBreak"
            case .html(let value):
                return "html:\(value.count):\(value)"
            case .strikethrough(let children):
                return "strikethrough:[\(children.map(inlineKey).joined(separator: ","))]"
            }
        }

        func cellKey(_ cell: [MarkdownInline]) -> String {
            cell.map(inlineKey).joined(separator: ",")
        }

        let headerKey = headers.map(cellKey).joined(separator: "|")
        let rowKey = rows.map { row in
            row.map(cellKey).joined(separator: "|")
        }.joined(separator: "/")
        return headerKey + "#" + rowKey
    }

    /// Natural single-line column metrics used to choose clip vs grid.
    static func measureNaturalColumns(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]]
    ) -> (columnWidths: [CGFloat], totalWidth: CGFloat) {
        let colCount = max(headers.count, rows.first?.count ?? 0)
        guard colCount > 0 else { return ([], 0) }

        let cellFont = AppFont.monoMedium
        let headerFont = AppFont.monoMediumBold
        var colWidths = [CGFloat](repeating: 0, count: colCount)

        for (index, header) in headers.enumerated() where index < colCount {
            colWidths[index] = max(
                colWidths[index],
                measuredTextWidth(plainText(from: header), font: headerFont)
            )
        }
        for row in rows {
            for (index, cell) in row.enumerated() where index < colCount {
                colWidths[index] = max(
                    colWidths[index],
                    measuredTextWidth(plainText(from: cell), font: cellFont)
                )
            }
        }

        // Match clip-mode padding: lead + trail + separators between columns.
        let leadPadWidth = measuredTextWidth("  ", font: cellFont)
        let sepWidth = measuredTextWidth("  │  ", font: cellFont)
        let trailPadWidth = leadPadWidth
        let buffer: CGFloat = 1
        let content = colWidths.reduce(0, +) + buffer * CGFloat(colCount)
        let separators = sepWidth * CGFloat(max(0, colCount - 1))
        let total = leadPadWidth + content + separators + trailPadWidth
        return (colWidths, ceil(total))
    }

    // internal for testing — called from TableColumnAlignmentTests
    static func makeTableAttributedText(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]],
        palette: ThemePalette
    ) -> NSAttributedString {
        let colCount = max(headers.count, rows.first?.count ?? 0)
        guard colCount > 0 else { return NSAttributedString() }

        let cellFont = AppFont.monoMedium
        let headerFont = AppFont.monoMediumBold

        // Compute column widths in points from actual rendered text.
        // SF Mono is monospaced for ASCII but CJK/emoji fall back to
        // system fonts whose advance widths don't divide evenly into
        // the ASCII space width. Measuring avoids misalignment.
        var colWidths = [CGFloat](repeating: 0, count: colCount)
        for (index, header) in headers.enumerated() where index < colCount {
            let w = measuredTextWidth(plainText(from: header), font: headerFont)
            colWidths[index] = max(colWidths[index], w)
        }
        for row in rows {
            for (index, cell) in row.enumerated() where index < colCount {
                let w = measuredTextWidth(plainText(from: cell), font: cellFont)
                colWidths[index] = max(colWidths[index], w)
            }
        }

        // Build tab stops for pixel-perfect column alignment.
        // Each column gets one tab stop at its right edge. After rendering
        // cell content, a \t character advances the cursor to the exact
        // tab-stop position — no space-padding rounding errors.
        let leadPadWidth = measuredTextWidth("  ", font: cellFont)
        let sepWidth = measuredTextWidth("  │  ", font: cellFont)
        let trailPadWidth = leadPadWidth  // "  " trailing
        // +1 buffer: when content exactly fills the column the cursor sits
        // ON the tab stop; a \t would then skip to the *next* stop.
        let buffer: CGFloat = 1

        var tabStops: [NSTextTab] = []
        var pos = leadPadWidth
        for i in 0..<colCount {
            pos += colWidths[i] + buffer
            tabStops.append(NSTextTab(textAlignment: .left, location: pos))
            if i < colCount - 1 { pos += sepWidth }
        }

        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 5
        paragraph.tabStops = tabStops

        let headerColor = UIColor(palette.cyan)
        let cellColor = UIColor(palette.fg)
        let linkColor = UIColor(palette.blue)
        let dimColor = UIColor(palette.comment).withAlphaComponent(0.4)
        let headerBgColor = UIColor(palette.bgHighlight)
        let altRowBgColor = UIColor(palette.bgHighlight).withAlphaComponent(0.45)

        // --- Header row ---
        let headerStart = result.length
        for (index, header) in headers.enumerated() {
            let text = plainText(from: header)
            // Leading pad for first column; tab-to-separator for subsequent.
            if index == 0 {
                result.append(NSAttributedString(string: "  ", attributes: [
                    .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
                ]))
            }
            result.append(NSAttributedString(string: text, attributes: [
                .font: headerFont, .foregroundColor: headerColor, .paragraphStyle: paragraph,
            ]))
            if index < colCount - 1 {
                result.append(NSAttributedString(string: "\t  │  ", attributes: [
                    .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
                ]))
            }
        }
        // Trailing pad via tab stop.
        result.append(NSAttributedString(string: "\t  ", attributes: [
            .font: cellFont, .paragraphStyle: paragraph,
        ]))
        let headerEnd = result.length
        result.addAttribute(
            .backgroundColor,
            value: headerBgColor,
            range: NSRange(location: headerStart, length: headerEnd - headerStart)
        )

        // --- Separator line ---
        let dashWidth = measuredTextWidth("─", font: cellFont)
        let totalPtWidth = (tabStops.last?.location ?? 0) + trailPadWidth
        let separatorCharCount = max(1, Int(ceil(totalPtWidth / dashWidth)))
        let separatorLine = String(repeating: "─", count: separatorCharCount)
        // Separator uses its own paragraph style without tab stops so the
        // dash characters don't get eaten by tab expansion.
        let sepParagraph = NSMutableParagraphStyle()
        sepParagraph.lineBreakMode = .byClipping
        sepParagraph.lineSpacing = 5
        result.append(NSAttributedString(string: "\n"))
        result.append(NSAttributedString(string: separatorLine, attributes: [
            .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: sepParagraph,
        ]))

        // --- Body rows ---
        for (rowIndex, row) in rows.enumerated() {
            result.append(NSAttributedString(string: "\n"))
            let rowStart = result.length

            for index in 0..<colCount {
                let inlines: [MarkdownInline] = index < row.count ? row[index] : [.text("")]
                if index == 0 {
                    result.append(NSAttributedString(string: "  ", attributes: [
                        .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
                    ]))
                }
                appendTableCellInlines(
                    inlines,
                    to: result,
                    font: cellFont,
                    defaultColor: cellColor,
                    linkColor: linkColor,
                    paragraph: paragraph
                )
                if index < colCount - 1 {
                    result.append(NSAttributedString(string: "\t  │  ", attributes: [
                        .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
                    ]))
                }
            }
            // Trailing pad via tab stop.
            result.append(NSAttributedString(string: "\t  ", attributes: [
                .font: cellFont, .paragraphStyle: paragraph,
            ]))

            if rowIndex % 2 == 1 {
                let rowEnd = result.length
                result.addAttribute(
                    .backgroundColor,
                    value: altRowBgColor,
                    range: NSRange(location: rowStart, length: rowEnd - rowStart)
                )
            }
        }

        return result
    }

    /// Append inline content to the result, rendering links with `.link` attribute.
    private static func appendTableCellInlines(
        _ inlines: [MarkdownInline],
        to result: NSMutableAttributedString,
        font: UIFont,
        defaultColor: UIColor,
        linkColor: UIColor,
        paragraph: NSParagraphStyle
    ) {
        // Fast path: single plain text (most common table cell).
        if inlines.count == 1, case .text(let s) = inlines[0] {
            result.append(NSAttributedString(string: s, attributes: [
                .font: font,
                .foregroundColor: defaultColor,
                .paragraphStyle: paragraph,
            ]))
            return
        }
        for inline in inlines {
            appendTableInline(
                inline, to: result, font: font,
                defaultColor: defaultColor, linkColor: linkColor,
                paragraph: paragraph
            )
        }
    }

    private static func appendTableInline(
        _ inline: MarkdownInline,
        to result: NSMutableAttributedString,
        font: UIFont,
        defaultColor: UIColor,
        linkColor: UIColor,
        paragraph: NSParagraphStyle
    ) {
        switch inline {
        case .text(let s):
            result.append(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: defaultColor, .paragraphStyle: paragraph,
            ]))
        case .link(let children, let destination):
            let text = plainText(from: children)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .paragraphStyle: paragraph,
            ]
            if let dest = destination, let url = URL(string: dest), url.scheme != nil {
                attrs[.link] = url
            }
            result.append(NSAttributedString(string: text, attributes: attrs))
        case .code(let s):
            result.append(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: defaultColor, .paragraphStyle: paragraph,
            ]))
        case .emphasis(let children), .strong(let children), .strikethrough(let children):
            for child in children {
                appendTableInline(
                    child, to: result, font: font,
                    defaultColor: defaultColor, linkColor: linkColor,
                    paragraph: paragraph
                )
            }
        case .softBreak, .hardBreak:
            result.append(NSAttributedString(string: " ", attributes: [
                .font: font, .paragraphStyle: paragraph,
            ]))
        case .html(let raw):
            result.append(NSAttributedString(string: raw, attributes: [
                .font: font, .foregroundColor: defaultColor, .paragraphStyle: paragraph,
            ]))
        case .image(let alt, _):
            if !alt.isEmpty {
                result.append(NSAttributedString(string: "[\(alt)]", attributes: [
                    .font: font, .foregroundColor: defaultColor, .paragraphStyle: paragraph,
                ]))
            }
        }
    }

    @objc private func longPressCopy(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        UIPasteboard.general.string = markdownTableText()

        AppHaptics.impact(style: .light, intensity: 0.7)

        showCopiedFlash()
    }

    private func markdownTableText() -> String {
        var lines: [String] = []

        let headerLine = "| " + currentHeaders.map { markdownText(from: $0) }.joined(separator: " | ") + " |"
        lines.append(headerLine)

        let separatorLine = "| " + currentHeaders.map { _ in "---" }.joined(separator: " | ") + " |"
        lines.append(separatorLine)

        for row in currentRows {
            let rowLine = "| " + row.map { markdownText(from: $0) }.joined(separator: " | ") + " |"
            lines.append(rowLine)
        }

        return lines.joined(separator: "\n")
    }

    /// Reconstruct markdown source text from inlines (preserves link syntax).
    private func markdownText(from inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s): return s
            case .link(let children, let dest):
                let text = plainText(from: children)
                if let dest { return "[\(text)](\(dest))" }
                return text
            case .emphasis(let children): return "*\(markdownText(from: children))*"
            case .strong(let children): return "**\(markdownText(from: children))**"
            case .code(let s): return "`\(s)`"
            case .strikethrough(let children): return "~~\(markdownText(from: children))~~"
            case .softBreak: return " "
            case .hardBreak: return "\n"
            case .html(let s): return s
            case .image(let alt, let src):
                if let src { return "![\(alt)](\(src))" }
                return alt
            }
        }.joined()
    }

    private func showCopiedFlash() {
        showCopiedOverlay(on: cardView)
    }
}

extension NativeTableBlockView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case let .link(url) = textItem.content,
              let reference = ResourceReferenceURL.parse(url),
              ResourceReferenceTapScope.matches(
                reference,
                serverID: resourceReferenceServerID,
                workspaceID: resourceReferenceWorkspaceID
              ) else {
            return defaultAction
        }

        return UIAction { _ in
            NotificationCenter.default.post(
                name: .resourceReferenceTapped,
                object: reference
            )
        }
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if let menu = ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        ) {
            return menu
        }

        guard let router = reviewCommentSelectionRouter,
              let sourceContext = reviewCommentSourceContext,
              let fallbackText = fallbackSelectedText(in: textView, range: range) else {
            return nil
        }

        return ReviewCommentSelectionMenuBuilder.editMenu(
            suggestedActions: suggestedActions,
            selectedText: fallbackText,
            sourceContext: sourceContext,
            router: router,
            textView: textView,
            selectedRange: range
        )
    }

    private func fallbackSelectedText(in textView: UITextView, range: NSRange) -> String? {
        guard range.location != NSNotFound else { return nil }

        let fullText = textView.attributedText?.string ?? textView.text ?? ""
        let nsText = fullText as NSString
        guard range.location < nsText.length else { return nil }

        let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = nsText.substring(with: lineRange)
        let normalized = ReviewCommentSelectionTextFormatter.normalizedSelectedText(lineText)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Show a flash overlay + floating "Copied" pill centered on the given view.
@MainActor
private func showCopiedOverlay(on view: UIView) {
    let palette = ThemeRuntimeState.currentPalette()
    let overlay = UIView()
    overlay.backgroundColor = UIColor(palette.fg).withAlphaComponent(0.08)
    overlay.frame = view.bounds
    overlay.layer.cornerRadius = view.layer.cornerRadius
    overlay.isUserInteractionEnabled = false
    view.addSubview(overlay)

    let pill = CopiedPillView()
    pill.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pill)
    NSLayoutConstraint.activate([
        pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        pill.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    pill.alpha = 0
    pill.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

    UIView.animate(withDuration: 0.15) {
        pill.alpha = 1
        pill.transform = .identity
    }

    UIView.animate(withDuration: 0.3, delay: 0.8, options: .curveEaseOut) {
        pill.alpha = 0
        pill.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        overlay.alpha = 0
    } completion: { _ in
        pill.removeFromSuperview()
        overlay.removeFromSuperview()
    }
}

private final class CopiedPillView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let palette = ThemeRuntimeState.currentPalette()

        let icon = UIImageView(image: UIImage(systemName: "checkmark"))
        icon.tintColor = UIColor(palette.fg)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)

        let label = UILabel()
        label.text = "Copied"
        label.font = AppFont.systemFeedback
        label.textColor = UIColor(palette.fg)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Transient pill over code content with no blur behind it, so it
        // takes the near-opaque card role.
        backgroundColor = UIColor(ThemeSurfaceStyle.resolve(.opaqueCard, palette: palette).fill)
        layer.cornerRadius = 16
        isUserInteractionEnabled = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
