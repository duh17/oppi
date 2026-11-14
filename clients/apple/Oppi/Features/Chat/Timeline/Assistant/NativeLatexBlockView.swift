import UIKit

/// Display math in chat and the Markdown reader.
///
/// Shows a rendered formula when the code fence is closed, or falls back
/// to a syntax-highlighted code block while the fence is still open during
/// streaming. Parses via `TeXMathParser` and rasterizes via
/// `MathCoreGraphicsRenderer` on a background thread, then displays the
/// resulting image. The formula sits on the page's own background, with
/// room above and below it like a display in a typeset document.
///
/// Tap opens `FullScreenCodeViewController` with two-axis scrolling and
/// full export support.
@MainActor
final class NativeLatexBlockView: UIView, UIScrollViewDelegate {

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
    /// Pins the code block to this view's edges while it is in the view.
    private var codeBlockConstraints: [NSLayoutConstraint] = []

    /// Cap formula height in the timeline to keep cells reasonable.
    private static let maxInlineHeight: CGFloat = 400

    /// Display math is set like inline math, at the size whose x-height
    /// matches the message body's (Dynamic Type and Message Text Size), a
    /// tenth larger so a block reads as a display; TeX's display style then
    /// sets its fractions and big operators full size. `textScale` is the
    /// full-screen reader's text size.
    static func displayFormulaFontSize(textScale: CGFloat = 1) -> CGFloat {
        MathFont.shared.fontSize(matchingXHeightOf: AppFont.messageBody as CTFont) * 1.1 * textScale
    }

    private var displayFormulaFontSize: CGFloat {
        Self.displayFormulaFontSize(textScale: textScale)
    }

    /// The formula's natural height plus room above and below, as a typeset
    /// display has: half an em of its size on top of the stack spacing
    /// between blocks. The timeline shows at most `maxInlineHeight` of it.
    static func canvasHeight(forNaturalHeight height: CGFloat, fontSize: CGFloat) -> CGFloat {
        max(height + (fontSize * 0.5).rounded() * 2, 44)
    }

    // MARK: - State

    private struct RenderIdentity: Equatable {
        let code: String
        let fontSize: CGFloat
        let availableWidth: CGFloat
    }

    /// The full-screen reader's text scale; chat leaves it at 1.
    private var textScale: CGFloat = 1

    private var currentCode: String?
    private var currentRenderIdentity: RenderIdentity?
    private var isShowingFormula = false
    private var renderTask: Task<Void, Never>?
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?

    #if DEBUG
    static var renderDelayForTesting: Duration?
    private var debugRenderCount = 0
    private var debugInvalidateTimelineLayoutCount = 0
    #endif

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A formula wider than the page fades out at the edge it continues past,
    /// so it reads as scrollable instead of cut off. An alpha mask, so the
    /// fade works on any background.
    private let edgeFade: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        return gradient
    }()

    override func layoutSubviews() {
        super.layoutSubviews()
        updateEdgeFade()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateEdgeFade()
    }

    private func updateEdgeFade() {
        let scrollView = formulaScrollView
        let width = scrollView.bounds.width
        let overflow = scrollView.contentSize.width - width
        guard isShowingFormula, width > 0, overflow > 1 else {
            scrollView.layer.mask = nil
            return
        }
        let fade = min(32, width / 4) / width
        let opaque = UIColor.black.cgColor
        let clear = UIColor.clear.cgColor
        let offset = scrollView.contentOffset.x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A scroll view's bounds move with its offset; the mask follows them.
        edgeFade.frame = scrollView.bounds
        edgeFade.colors = [offset > 1 ? clear : opaque, opaque, opaque, offset < overflow - 1 ? clear : opaque]
        edgeFade.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        scrollView.layer.mask = edgeFade
        CATransaction.commit()
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        codeBlockView.translatesAutoresizingMaskIntoConstraints = false
        codeBlockView.prepareForGraphicalPlaceholder()
        addSubview(codeBlockView)

        formulaScrollView.isHidden = true
        formulaScrollView.delegate = self
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

        codeBlockConstraints = [
            codeBlockView.topAnchor.constraint(equalTo: topAnchor),
            codeBlockView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeBlockView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeBlockView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(codeBlockConstraints + [
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
        currentRenderIdentity = nil

        setShowsCodeBlock(true)
        formulaScrollView.isHidden = true
        formulaHeightConstraint?.isActive = false
        isShowingFormula = false
        configureFormulaAccessibility(code: nil)

        codeBlockView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
        currentCode = code
    }

    var isDisplayingRenderedFormula: Bool { isShowingFormula }

    /// Render synchronously on the current thread. Used by export paths that
    /// snapshot the view immediately after layout.
    func applyAsFormulaSync(
        code: String,
        palette: ThemePalette,
        availableWidth explicitWidth: CGFloat? = nil,
        textScale: CGFloat = 1
    ) {
        self.textScale = textScale
        let availableWidth = resolvedAvailableWidth(explicitWidth)
        let identity = RenderIdentity(
            code: code,
            fontSize: displayFormulaFontSize,
            availableWidth: availableWidth
        )
        // Re-entrant collection-view measurement reuses this cell. Rendering
        // again would rasterize a new image and force another layout pass.
        // A pending reservation has no image yet — do not treat it as done.
        if identity == currentRenderIdentity && isShowingFormula && formulaImageView.image != nil {
            return
        }
        renderTask?.cancel()
        renderTask = nil
        currentCode = code
        currentRenderIdentity = identity

        let theme = ThemeRuntimeState.currentRenderTheme()
        #if DEBUG
        debugRenderCount += 1
        #endif

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

        showFormula(
            image: result.image,
            naturalSize: result.size,
            invalidateHostLayout: false
        )
    }

    /// Render as a formula (fence closed, not streaming).
    func applyAsFormula(
        code: String,
        palette: ThemePalette,
        availableWidth explicitWidth: CGFloat? = nil,
        textScale: CGFloat = 1
    ) {
        self.textScale = textScale
        let availableWidth = resolvedAvailableWidth(explicitWidth)
        let identity = RenderIdentity(
            code: code,
            fontSize: displayFormulaFontSize,
            availableWidth: availableWidth
        )
        guard identity != currentRenderIdentity || !isShowingFormula else { return }
        currentCode = code
        currentRenderIdentity = identity

        renderTask?.cancel()
        #if DEBUG
        debugRenderCount += 1
        #endif
        guard reserveFormulaHeightFromLayout(code: code, availableWidth: availableWidth) else {
            showAsCodeFallback(code: code, palette: palette)
            return
        }
        renderTask = Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            if let delay = Self.renderDelayForTesting {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            #endif

            let theme = ThemeRuntimeState.currentRenderTheme()
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

            self.showFormula(
                image: result.image,
                naturalSize: result.size,
                invalidateHostLayout: true
            )
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

    // MARK: - Private

    private func resolvedAvailableWidth(_ explicitWidth: CGFloat?) -> CGFloat {
        if let explicitWidth, explicitWidth.isFinite, explicitWidth > 0 {
            return explicitWidth
        }
        return bounds.width > 0
            ? bounds.width
            : ((superview?.bounds.width).flatMap { $0 > 0 ? $0 : nil } ?? 360)
    }

    /// Fence-close reservation: activate the layout-cache height before the
    /// async raster arrives so the image swap does not change cell height.
    /// Same renderability and natural-raster budget as `renderLatexGraphicalImage`.
    @discardableResult
    private func reserveFormulaHeightFromLayout(code: String, availableWidth: CGFloat) -> Bool {
        guard let layout = DocumentRenderPipeline.layoutLatexGraphical(
            text: code,
            config: RenderConfiguration(
                fontSize: displayFormulaFontSize,
                maxWidth: availableWidth,
                theme: ThemeRuntimeState.currentRenderTheme(),
                displayMode: .document
            )
        ), layout.size.width > 0, layout.size.height > 0,
              DocumentRenderPipeline.naturalRasterBudget.permits(
                pointSize: layout.size,
                scale: 2
              ) else {
            return false
        }

        let heightOrRevealChanged = updateFormulaHeight(naturalSize: layout.size)
        formulaHeightConstraint?.isActive = true
        setShowsCodeBlock(false)
        formulaScrollView.isHidden = false
        isShowingFormula = true
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        if heightOrRevealChanged {
            invalidateTimelineLayout()
        }
        return true
    }

    private func showFormula(
        image: UIImage,
        naturalSize: CGSize,
        invalidateHostLayout: Bool
    ) {
        let heightOrRevealChanged = updateFormulaHeight(naturalSize: naturalSize)

        formulaHeightConstraint?.isActive = true
        formulaCanvasHeightConstraint?.constant = Self.canvasHeight(
            forNaturalHeight: naturalSize.height,
            fontSize: displayFormulaFontSize
        )
        formulaImageWidthConstraint?.constant = max(naturalSize.width, 1)
        formulaImageHeightConstraint?.constant = max(naturalSize.height, 1)
        formulaImageView.image = image

        setShowsCodeBlock(false)
        formulaScrollView.isHidden = false
        isShowingFormula = true
        configureFormulaAccessibility(code: currentCode)

        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        // Sync reader apply already runs inside a collection-view layout pass.
        // Nested invalidation there re-enters `cellForItem` and overflows.
        if invalidateHostLayout && heightOrRevealChanged {
            invalidateTimelineLayout()
        }
    }

    @discardableResult
    private func updateFormulaHeight(naturalSize: CGSize) -> Bool {
        let displayHeight = min(
            Self.canvasHeight(forNaturalHeight: naturalSize.height, fontSize: displayFormulaFontSize),
            Self.maxInlineHeight
        )
        let constraintIsActive = formulaHeightConstraint?.isActive == true
        let heightUnchanged = abs((formulaHeightConstraint?.constant ?? 0) - displayHeight) <= 0.5
        guard !isShowingFormula || !constraintIsActive || !heightUnchanged else {
            return false
        }
        formulaHeightConstraint?.constant = displayHeight
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        return true
    }

    /// The code block is in the view only while it shows. Hidden, it would
    /// stay in Auto Layout's engine, and every measure of the row around a
    /// rendered formula would measure its source text again.
    private func setShowsCodeBlock(_ shows: Bool) {
        codeBlockView.isHidden = !shows
        if shows, codeBlockView.superview !== self {
            insertSubview(codeBlockView, at: 0)
            NSLayoutConstraint.activate(codeBlockConstraints)
        } else if !shows, codeBlockView.superview === self {
            codeBlockView.removeFromSuperview()
        }
    }

    private func showAsCodeFallback(code: String, palette: ThemePalette) {
        setShowsCodeBlock(true)
        formulaScrollView.isHidden = true
        formulaHeightConstraint?.isActive = false
        isShowingFormula = false
        configureFormulaAccessibility(code: nil)
        codeBlockView.apply(language: "latex", code: code, palette: palette, isOpen: false)
        invalidateTimelineLayout()
    }

    private func invalidateTimelineLayout() {
        #if DEBUG
        debugInvalidateTimelineLayoutCount += 1
        #endif
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

    override func accessibilityActivate() -> Bool {
        guard isShowingFormula else { return false }
        handleTap()
        return true
    }

    @objc private func handleTap() {
        guard let code = currentCode, isShowingFormula else { return }

        let content = FullScreenCodeContent.latex(content: code, filePath: nil)
        ToolTimelineRowPresentationHelpers.presentFullScreenContent(
            content,
            from: self,
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
    var debugRenderWidthForTesting: CGFloat? { currentRenderIdentity?.availableWidth }
    var debugRenderCountForTesting: Int { debugRenderCount }
    var debugFormulaHeightConstantForTesting: CGFloat? { formulaHeightConstraint?.constant }
    var debugFormulaHeightConstraintIsActiveForTesting: Bool {
        formulaHeightConstraint?.isActive == true
    }
    var debugInvalidateTimelineLayoutCountForTesting: Int { debugInvalidateTimelineLayoutCount }
}
#endif
