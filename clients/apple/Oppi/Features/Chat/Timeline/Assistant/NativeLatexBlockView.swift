import UIKit

/// Inline LaTeX math renderer for the chat timeline.
///
/// Shows a rendered formula when the code fence is closed, or falls back
/// to a syntax-highlighted code block while the fence is still open during
/// streaming. Parses via `TeXMathParser` and rasterizes via
/// `MathCoreGraphicsRenderer` on a background thread, then displays the
/// resulting image.
///
/// Tap opens `FullScreenCodeViewController` with two-axis scrolling and
/// full export support.
@MainActor
final class NativeLatexBlockView: UIView {

    // MARK: - Subviews

    /// Code block shown while the fence is open (streaming) or on parse failure.
    private let codeBlockView = NativeCodeBlockView()

    /// Horizontal-only viewport. Wide formulas retain natural typography and
    /// pan independently while vertical/diagonal drags stay with the timeline.
    private let formulaScrollView: HorizontalPanPassthroughScrollView = {
        let scrollView = HorizontalPanPassthroughScrollView()
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.layer.cornerRadius = 8
        scrollView.clipsToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }()

    private let formulaCanvas = UIView()

    /// Rasterized formula image presented at its natural point size.
    private let formulaImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = false
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private var formulaCanvasHeightConstraint: NSLayoutConstraint?
    private var formulaImageWidthConstraint: NSLayoutConstraint?
    private var formulaImageHeightConstraint: NSLayoutConstraint?

    /// Active only while showing the rendered formula. A direct self-height
    /// constraint makes stack/scroll relayout more reliable after async renders.
    private var formulaHeightConstraint: NSLayoutConstraint?

    /// Cap formula height in the timeline to keep cells reasonable.
    private static let maxInlineHeight: CGFloat = 400

    /// Display math uses Apple's title1 role rather than a caption-sized scalar.
    /// Applying the configured message-body ratio keeps Dynamic Type and the
    /// chat text-size preference aligned with the surrounding typography.
    private var displayFormulaFontSize: CGFloat {
        Self.displayFormulaFontSize(compatibleWith: traitCollection)
    }

    static func displayFormulaFontSize(compatibleWith traitCollection: UITraitCollection) -> CGFloat {
        let displayFont = UIFont.preferredFont(
            forTextStyle: .title1,
            compatibleWith: traitCollection
        )
        let defaultTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let defaultBodyFont = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: defaultTraits
        )
        let messageBodyScale = AppFont.messageBody.pointSize / max(defaultBodyFont.pointSize, 1)
        return displayFont.pointSize * messageBodyScale
    }

    // MARK: - State

    private struct RenderIdentity: Equatable {
        let code: String
        let contentSizeCategory: UIContentSizeCategory
    }

    private var currentCode: String?
    private var currentPalette: ThemePalette?
    private var currentRenderIdentity: RenderIdentity?
    private var isShowingFormula = false
    private var renderTask: Task<Void, Never>?
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?

    #if DEBUG
    static var renderDelayForTesting: Duration?
    #endif

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        codeBlockView.translatesAutoresizingMaskIntoConstraints = false
        codeBlockView.prepareForGraphicalPlaceholder()
        addSubview(codeBlockView)

        formulaScrollView.isHidden = true
        addSubview(formulaScrollView)

        formulaCanvas.translatesAutoresizingMaskIntoConstraints = false
        formulaCanvas.semanticContentAttribute = .forceLeftToRight
        formulaImageView.semanticContentAttribute = .forceLeftToRight
        formulaScrollView.semanticContentAttribute = .forceLeftToRight
        formulaScrollView.addSubview(formulaCanvas)
        formulaCanvas.addSubview(formulaImageView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        formulaScrollView.addGestureRecognizer(tapGesture)

        let canvasHeight = formulaCanvas.heightAnchor.constraint(equalToConstant: 44)
        let imageWidth = formulaImageView.widthAnchor.constraint(equalToConstant: 1)
        let imageHeight = formulaImageView.heightAnchor.constraint(equalToConstant: 1)
        formulaCanvasHeightConstraint = canvasHeight
        formulaImageWidthConstraint = imageWidth
        formulaImageHeightConstraint = imageHeight

        let formulaHeight = heightAnchor.constraint(equalToConstant: 200)
        formulaHeight.isActive = false
        formulaHeightConstraint = formulaHeight

        NSLayoutConstraint.activate([
            codeBlockView.topAnchor.constraint(equalTo: topAnchor),
            codeBlockView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeBlockView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeBlockView.bottomAnchor.constraint(equalTo: bottomAnchor),

            formulaScrollView.topAnchor.constraint(equalTo: topAnchor),
            formulaScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            formulaScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            formulaScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            formulaCanvas.leadingAnchor.constraint(equalTo: formulaScrollView.contentLayoutGuide.leadingAnchor),
            formulaCanvas.trailingAnchor.constraint(equalTo: formulaScrollView.contentLayoutGuide.trailingAnchor),
            formulaCanvas.topAnchor.constraint(equalTo: formulaScrollView.contentLayoutGuide.topAnchor),
            formulaCanvas.bottomAnchor.constraint(equalTo: formulaScrollView.contentLayoutGuide.bottomAnchor),
            formulaCanvas.widthAnchor.constraint(greaterThanOrEqualTo: formulaScrollView.frameLayoutGuide.widthAnchor),
            canvasHeight,

            formulaImageView.centerXAnchor.constraint(equalTo: formulaCanvas.centerXAnchor),
            formulaImageView.centerYAnchor.constraint(equalTo: formulaCanvas.centerYAnchor),
            formulaImageView.leadingAnchor.constraint(greaterThanOrEqualTo: formulaCanvas.leadingAnchor),
            formulaImageView.trailingAnchor.constraint(lessThanOrEqualTo: formulaCanvas.trailingAnchor),
            imageWidth,
            imageHeight,
        ])
    }

    // MARK: - Public API

    /// Show as a code block (streaming / fence still open).
    func applyAsCode(language: String?, code: String, palette: ThemePalette, isOpen: Bool) {
        renderTask?.cancel()
        renderTask = nil
        currentPalette = palette
        currentRenderIdentity = nil

        codeBlockView.isHidden = false
        formulaScrollView.isHidden = true
        formulaHeightConstraint?.isActive = false
        isShowingFormula = false
        configureFormulaAccessibility(code: nil)

        codeBlockView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
        currentCode = code
    }

    /// Render synchronously on the current thread. Used by export paths that
    /// snapshot the view immediately after layout.
    func applyAsFormulaSync(code: String, palette: ThemePalette) {
        // Re-entrant collection-view measurement reuses this cell. Rendering
        // again would rasterize a new image and force another layout pass.
        if code == currentCode && isShowingFormula { return }
        renderTask?.cancel()
        renderTask = nil
        currentCode = code
        currentPalette = palette
        currentRenderIdentity = RenderIdentity(
            code: code,
            contentSizeCategory: traitCollection.preferredContentSizeCategory
        )

        let theme = ThemeRuntimeState.currentRenderTheme()
        let availableWidth = bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? 360)

        guard let result = DocumentRenderPipeline.renderLatexGraphicalImage(
            text: code,
            config: RenderConfiguration(
                fontSize: displayFormulaFontSize,
                maxWidth: availableWidth,
                theme: theme,
                displayMode: .document
            )
        ) else {
            showAsCodeFallback(code: code, palette: palette)
            return
        }

        showFormula(image: result.image, naturalSize: result.size, palette: palette)
    }

    /// Render as a formula (fence closed, not streaming).
    func applyAsFormula(code: String, palette: ThemePalette) {
        let identity = RenderIdentity(
            code: code,
            contentSizeCategory: traitCollection.preferredContentSizeCategory
        )
        guard identity != currentRenderIdentity || !isShowingFormula else { return }
        currentCode = code
        currentPalette = palette
        currentRenderIdentity = identity

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            if let delay = Self.renderDelayForTesting {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            #endif

            let theme = ThemeRuntimeState.currentRenderTheme()
            let availableWidth = self.bounds.width > 0
                ? self.bounds.width
                : (self.window?.windowScene?.screen.bounds.width ?? 360)
            let fontSize = self.displayFormulaFontSize

            let result: (image: UIImage, size: CGSize)? = await Task.detached(priority: .userInitiated) {
                DocumentRenderPipeline.renderLatexGraphicalImage(
                    text: code,
                    config: RenderConfiguration(
                        fontSize: fontSize,
                        maxWidth: availableWidth,
                        theme: theme,
                        displayMode: .document
                    )
                )
            }.value

            guard !Task.isCancelled, self.currentRenderIdentity == identity else { return }

            guard let result else {
                self.showAsCodeFallback(code: code, palette: palette)
                return
            }

            self.showFormula(image: result.image, naturalSize: result.size, palette: palette)
        }
    }

    /// Configure review-comment selection forwarding on the inner code block.
    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
        codeBlockView.configureReviewCommentSelection(
            router: router,
            sourceContext: sourceContext
        )
    }

    /// Apply syntax highlighting to the inner code block (when showing as code).
    func applyHighlightedCode(_ attributed: NSAttributedString) {
        codeBlockView.applyHighlightedCode(attributed)
    }

    // MARK: - Private

    private func showFormula(image: UIImage, naturalSize: CGSize, palette: ThemePalette) {
        let canvasHeight = max(naturalSize.height, 44)
        let displayHeight = min(canvasHeight, Self.maxInlineHeight)

        formulaHeightConstraint?.constant = displayHeight
        formulaHeightConstraint?.isActive = true
        formulaCanvasHeightConstraint?.constant = canvasHeight
        formulaImageWidthConstraint?.constant = max(naturalSize.width, 1)
        formulaImageHeightConstraint?.constant = max(naturalSize.height, 1)
        formulaScrollView.backgroundColor = UIColor(palette.bgHighlight)
        formulaCanvas.backgroundColor = UIColor(palette.bgHighlight)
        formulaImageView.image = image

        codeBlockView.isHidden = true
        formulaScrollView.isHidden = false
        isShowingFormula = true
        configureFormulaAccessibility(code: currentCode)

        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        // Sync reader apply already runs inside a collection-view layout pass.
        // Nested `layoutIfNeeded` re-enters `cellForItem` and overflows.
    }

    private func showAsCodeFallback(code: String, palette: ThemePalette) {
        codeBlockView.isHidden = false
        formulaScrollView.isHidden = true
        formulaHeightConstraint?.isActive = false
        isShowingFormula = false
        configureFormulaAccessibility(code: nil)
        codeBlockView.apply(language: "latex", code: code, palette: palette, isOpen: false)
        invalidateTimelineLayout()
    }

    private func invalidateTimelineLayout() {
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    private func configureFormulaAccessibility(code: String?) {
        guard let code else {
            isAccessibilityElement = false
            accessibilityIdentifier = nil
            accessibilityLabel = nil
            accessibilityHint = nil
            accessibilityTraits = []
            return
        }
        isAccessibilityElement = true
        accessibilityIdentifier = "latex.formula.open"
        accessibilityLabel = FlatSegment.formulaAccessibilityLabel(for: code)
        accessibilityHint = String(localized: "Opens formula full screen")
        accessibilityTraits = [.button]
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
                != traitCollection.preferredContentSizeCategory,
              let currentCode,
              let currentPalette,
              isShowingFormula else {
            return
        }
        currentRenderIdentity = nil
        applyAsFormula(code: currentCode, palette: currentPalette)
    }

    override func accessibilityActivate() -> Bool {
        guard isShowingFormula else { return false }
        handleTap()
        return true
    }

    @objc private func handleTap() {
        guard let code = currentCode, isShowingFormula else { return }

        let content = FullScreenCodeContent.latex(content: code, filePath: nil)
        FullScreenCodeViewController.present(
            content: content,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSessionId: reviewCommentSourceContext?.sessionId,
            reviewCommentSourceLabel: reviewCommentSourceContext?.sourceLabel
        )
    }
}

#if DEBUG
extension NativeLatexBlockView {
    var debugIsShowingFormulaForTesting: Bool { isShowingFormula }
    var debugFormulaImageForTesting: UIImage? { formulaImageView.image }
}
#endif
