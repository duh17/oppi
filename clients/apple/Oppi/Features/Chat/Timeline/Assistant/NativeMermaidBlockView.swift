import UIKit

/// Inline mermaid diagram renderer for the chat timeline.
///
/// Shows a rendered diagram when the code fence is closed, or falls back
/// to a syntax-highlighted code block while the fence is still open during
/// streaming. Parses and rasterizes via `DocumentRenderPipeline` +
/// `MermaidRenderer` on a background thread, then displays the
/// resulting image.
///
/// Tap opens `FullScreenCodeViewController` with pinch-to-zoom and full
/// export support (image, PDF, source). No inline zoom — keeps the view
/// simple and avoids UIScrollView gesture conflicts.
@MainActor
final class NativeMermaidBlockView: UIView {
    struct RasterResult: @unchecked Sendable {
        let image: UIImage
        let size: CGSize
    }

    struct Rasterizer: Sendable {
        let renderSync: @Sendable (String, CGFloat, RenderTheme) -> RasterResult?
        let renderAsync: @Sendable (String, CGFloat, RenderTheme) async -> RasterResult?

        static let live = Rasterizer(
            renderSync: { code, availableWidth, theme in
                DocumentRenderPipeline.renderInlineGraphicalImage(
                    parser: MermaidParser(),
                    renderer: MermaidRenderer(),
                    text: code,
                    config: RenderConfiguration(
                        fontSize: 13,
                        maxWidth: availableWidth,
                        theme: theme,
                        displayMode: .inline
                    )
                ).map { RasterResult(image: $0.image, size: $0.size) }
            },
            renderAsync: { code, availableWidth, theme in
                await Task.detached(priority: .userInitiated) {
                    DocumentRenderPipeline.renderInlineGraphicalImage(
                        parser: MermaidParser(),
                        renderer: MermaidRenderer(),
                        text: code,
                        config: RenderConfiguration(
                            fontSize: 13,
                            maxWidth: availableWidth,
                            theme: theme,
                            displayMode: .inline
                        )
                    ).map { RasterResult(image: $0.image, size: $0.size) }
                }.value
            }
        )
    }

    // MARK: - Subviews

    /// Code block shown while the fence is open (streaming) or on parse failure.
    private let codeBlockView = NativeCodeBlockView()

    /// Rasterized diagram image — simple UIImageView, just like NativeMarkdownImageView.
    /// No UIScrollView, no inline zoom. Tap opens fullscreen for zoom/export.
    private let diagramImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.isUserInteractionEnabled = true
        iv.isAccessibilityElement = false
        iv.layer.cornerRadius = 8
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// Active only while showing the rendered diagram. A direct self-height
    /// constraint makes stack/scroll relayout more reliable after async renders.
    private var diagramHeightConstraint: NSLayoutConstraint?

    /// Cap diagram height in the timeline to keep cells reasonable.
    private static let maxInlineHeight: CGFloat = 400

    // MARK: - State

    private struct RasterRequest: Equatable {
        let code: String
        let rasterWidth: CGFloat
        let renderThemeIdentity: String
        let usesExactWidth: Bool
    }

    private let rasterizer: Rasterizer
    private var currentCode: String?
    private var currentPalette: ThemePalette?
    private var isShowingDiagram = false
    var isDisplayingRenderedDiagram: Bool { isShowingDiagram }
    /// Natural (unscaled) diagram size from the latest successful render.
    /// Used to recompute inline height if the view width changes later.
    private var renderedDiagramNaturalSize: CGSize?
    /// `maxWidth` passed to the last finished raster. Layout may later
    /// settle wider than the estimated width used at apply time.
    private var desiredRasterRequest: RasterRequest?
    private var displayedRasterRequest: RasterRequest?
    /// Exact in-flight request so layout cannot start a duplicate render.
    private var inFlightRasterRequest: RasterRequest?
    private var rasterRequestGeneration: UInt = 0
    private var requiresExactRasterWidth = false
    private var renderTask: Task<Void, Never>?
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?

    /// Timeline bubbles ignore small constraint jitter. Reader calls supply an
    /// explicit canonical width and use only half-point pixel-rounding slop.
    private static let timelineRasterWidthSlop: CGFloat = 8
    private static let exactReaderRasterWidthSlop: CGFloat = 0.5

    #if DEBUG
    private var debugRenderCount = 0
    private var debugApplyAsDiagramCallCount = 0
    private var debugInvalidateTimelineLayoutCount = 0
    #endif

    // MARK: - Init

    override init(frame: CGRect) {
        rasterizer = .live
        super.init(frame: frame)
        setupViews()
    }

    init(rasterizer: Rasterizer) {
        self.rasterizer = rasterizer
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        codeBlockView.translatesAutoresizingMaskIntoConstraints = false
        codeBlockView.prepareForGraphicalPlaceholder()
        addSubview(codeBlockView)

        diagramImageView.isHidden = true
        addSubview(diagramImageView)

        // Tap to open fullscreen — same pattern as NativeMarkdownImageView
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        diagramImageView.addGestureRecognizer(tapGesture)

        let diagramHeight = heightAnchor.constraint(equalToConstant: 200)
        diagramHeight.isActive = false
        diagramHeightConstraint = diagramHeight

        NSLayoutConstraint.activate([
            // Code block fills self
            codeBlockView.topAnchor.constraint(equalTo: topAnchor),
            codeBlockView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeBlockView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeBlockView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Image view fills self while the container height is driven by
            // `diagramHeightConstraint` when the rendered diagram is visible.
            diagramImageView.topAnchor.constraint(equalTo: topAnchor),
            diagramImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diagramImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diagramImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Async renders can complete before Auto Layout settles the final
        // message-bubble width. Keep the current bitmap's height in sync
        // immediately, then redraw if this width is not what we rastered.
        guard isShowingDiagram, bounds.width > 0 else { return }

        if let naturalSize = renderedDiagramNaturalSize,
           naturalSize.width > 0,
           naturalSize.height > 0 {
            updateDiagramHeight(
                naturalSize: naturalSize,
                availableWidth: bounds.width
            )
        }

        if rasterWidthMismatch(bounds.width), let code = currentCode {
            applyAsDiagram(
                code: code,
                palette: currentPalette ?? ThemeRuntimeState.currentPalette(),
                availableWidth: requiresExactRasterWidth ? bounds.width : nil
            )
        }
    }

    // MARK: - Public API

    /// Show as a code block (streaming / fence still open).
    func applyAsCode(language: String?, code: String, palette: ThemePalette, isOpen: Bool) {
        let wasShowingDiagram = isShowingDiagram

        invalidateRasterRequest()

        codeBlockView.isHidden = false
        diagramImageView.isHidden = true
        diagramHeightConstraint?.isActive = false
        isShowingDiagram = false
        renderedDiagramNaturalSize = nil
        requiresExactRasterWidth = false
        currentPalette = palette
        clearDiagramAccessibility()

        codeBlockView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
        currentCode = code

        if wasShowingDiagram {
            invalidateTimelineLayout()
        }
    }

    /// Render synchronously on the current thread. Used by export paths that
    /// snapshot the view immediately after layout — async rendering would
    /// complete after the snapshot, producing blank boxes.
    func applyAsDiagramSync(
        code: String,
        palette: ThemePalette,
        availableWidth explicitWidth: CGFloat? = nil
    ) {
        let usesExactWidth = explicitWidth != nil
        let availableWidth = resolvedAvailableWidth(explicitWidth)
        let theme = palette.renderTheme
        let request = RasterRequest(
            code: code,
            rasterWidth: availableWidth,
            renderThemeIdentity: theme.renderIdentity,
            usesExactWidth: usesExactWidth
        )
        diagramImageView.backgroundColor = UIColor(palette.bgHighlight)
        currentCode = code
        currentPalette = palette
        requiresExactRasterWidth = usesExactWidth
        #if DEBUG
        debugApplyAsDiagramCallCount += 1
        #endif
        guard let generation = beginRasterRequest(request, replacesInFlight: true) else { return }
        #if DEBUG
        debugRenderCount += 1
        #endif

        guard let result = rasterizer.renderSync(code, availableWidth, theme) else {
            guard rasterRequestIsCurrent(request, generation: generation) else { return }
            showAsCodeFallback(code: code, palette: palette)
            return
        }
        guard rasterRequestIsCurrent(request, generation: generation) else { return }

        showDiagram(
            image: result.image,
            naturalSize: result.size,
            palette: palette,
            request: request,
            invalidateHostLayout: false
        )
    }

    /// Render as a diagram (fence closed, not streaming).
    func applyAsDiagram(
        code: String,
        palette: ThemePalette,
        availableWidth explicitWidth: CGFloat? = nil
    ) {
        currentPalette = palette
        let usesExactWidth = explicitWidth != nil
        let availableWidth = resolvedAvailableWidth(explicitWidth)
        let theme = palette.renderTheme
        let request = RasterRequest(
            code: code,
            rasterWidth: availableWidth,
            renderThemeIdentity: theme.renderIdentity,
            usesExactWidth: usesExactWidth
        )
        diagramImageView.backgroundColor = UIColor(palette.bgHighlight)
        currentCode = code
        requiresExactRasterWidth = usesExactWidth
        #if DEBUG
        debugApplyAsDiagramCallCount += 1
        #endif
        guard let generation = beginRasterRequest(request) else { return }
        #if DEBUG
        debugRenderCount += 1
        #endif
        guard reserveDiagramHeightFromLayout(
            code: code,
            availableWidth: availableWidth,
            theme: theme
        ) else {
            showAsCodeFallback(code: code, palette: palette)
            return
        }
        renderTask = Task { [weak self] in
            guard let self else { return }

            let result = await self.rasterizer.renderAsync(code, availableWidth, theme)

            guard !Task.isCancelled,
                  self.rasterRequestIsCurrent(request, generation: generation) else { return }

            guard let result else {
                self.showAsCodeFallback(code: code, palette: palette)
                return
            }

            self.showDiagram(
                image: result.image,
                naturalSize: result.size,
                palette: palette,
                request: request,
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

    /// Apply syntax highlighting to the inner code block (when showing as code).
    func applyHighlightedCode(_ attributed: NSAttributedString) {
        codeBlockView.applyHighlightedCode(attributed)
    }

    // MARK: - Private

    private func resolvedAvailableWidth(_ explicitWidth: CGFloat? = nil) -> CGFloat {
        if let explicitWidth, explicitWidth.isFinite, explicitWidth > 0 {
            return explicitWidth
        }
        return bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? 360)
    }

    private func rasterWidthMismatch(
        _ width: CGFloat,
        usesExactWidth: Bool? = nil
    ) -> Bool {
        let exact = usesExactWidth ?? requiresExactRasterWidth
        let slop = exact
            ? Self.exactReaderRasterWidthSlop
            : Self.timelineRasterWidthSlop
        if let inFlight = inFlightRasterRequest,
           abs(width - inFlight.rasterWidth) <= slop {
            return false
        }
        if let displayed = displayedRasterRequest,
           abs(width - displayed.rasterWidth) <= slop {
            return false
        }
        return true
    }

    private func beginRasterRequest(
        _ request: RasterRequest,
        replacesInFlight: Bool = false
    ) -> UInt? {
        if desiredRasterRequest != request {
            rasterRequestGeneration &+= 1
            renderTask?.cancel()
            renderTask = nil
            inFlightRasterRequest = nil
            desiredRasterRequest = request
        }
        if displayedRasterRequest == request, diagramImageView.image != nil {
            return nil
        }
        if inFlightRasterRequest == request, !replacesInFlight {
            return nil
        }
        if replacesInFlight {
            renderTask?.cancel()
            renderTask = nil
        }
        inFlightRasterRequest = request
        return rasterRequestGeneration
    }

    private func rasterRequestIsCurrent(_ request: RasterRequest, generation: UInt) -> Bool {
        generation == rasterRequestGeneration
            && desiredRasterRequest == request
            && inFlightRasterRequest == request
    }

    private func invalidateRasterRequest() {
        rasterRequestGeneration &+= 1
        renderTask?.cancel()
        renderTask = nil
        desiredRasterRequest = nil
        displayedRasterRequest = nil
        inFlightRasterRequest = nil
    }

    /// Fence-close reservation: activate the layout-cache height before the
    /// async raster arrives so the image swap does not change cell height.
    /// Same natural-raster budget as `renderInlineGraphicalImage`.
    @discardableResult
    private func reserveDiagramHeightFromLayout(
        code: String,
        availableWidth: CGFloat,
        theme: RenderTheme
    ) -> Bool {
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: code,
            config: RenderConfiguration(
                fontSize: 13,
                maxWidth: availableWidth,
                theme: theme,
                displayMode: .inline
            )
        )
        guard layout.size.width > 0, layout.size.height > 0,
              DocumentRenderPipeline.naturalRasterBudget.permits(
                pointSize: layout.size,
                scale: 2
              ) else {
            return false
        }

        renderedDiagramNaturalSize = layout.size
        let width = bounds.width > 0 ? bounds.width : availableWidth
        let heightOrRevealChanged = updateDiagramHeight(
            naturalSize: layout.size,
            availableWidth: width
        )
        diagramHeightConstraint?.isActive = true
        codeBlockView.isHidden = true
        diagramImageView.isHidden = false
        isShowingDiagram = true
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        if heightOrRevealChanged {
            invalidateTimelineLayout()
        }
        return true
    }

    private func showDiagram(
        image: UIImage,
        naturalSize: CGSize,
        palette: ThemePalette,
        request: RasterRequest,
        invalidateHostLayout: Bool
    ) {
        renderedDiagramNaturalSize = naturalSize
        displayedRasterRequest = request
        inFlightRasterRequest = nil
        renderTask = nil

        let availableWidth = bounds.width > 0 ? bounds.width : request.rasterWidth
        // Decide from the pre-swap state. An inactive 200pt default is not a
        // displayed height, so first reveal still counts as a change.
        let heightOrRevealChanged = updateDiagramHeight(
            naturalSize: naturalSize,
            availableWidth: availableWidth
        )

        // Activate and swap before any force-invalidation so a collection
        // self-size pass measures the diagram, not the code placeholder.
        diagramHeightConstraint?.isActive = true
        diagramImageView.backgroundColor = UIColor(palette.bgHighlight)
        diagramImageView.image = image

        codeBlockView.isHidden = true
        diagramImageView.isHidden = false
        isShowingDiagram = true
        configureDiagramAccessibility()

        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        if invalidateHostLayout && heightOrRevealChanged {
            invalidateTimelineLayout()
        }
    }

    @discardableResult
    private func updateDiagramHeight(
        naturalSize: CGSize,
        availableWidth: CGFloat
    ) -> Bool {
        guard availableWidth > 0, naturalSize.width > 0, naturalSize.height > 0 else {
            return false
        }

        let scale = min(1.0, availableWidth / naturalSize.width)
        let displayHeight = min(naturalSize.height * scale, Self.maxInlineHeight)
        let clampedHeight = max(1, displayHeight)
        let constraintIsActive = diagramHeightConstraint?.isActive == true
        let heightUnchanged = abs((diagramHeightConstraint?.constant ?? 0) - clampedHeight) <= 0.5
        // An inactive 200pt default is not a displayed height. First reveal
        // and inactive constraints are height changes even when the constant
        // already matches. Suppress only when the diagram is already on screen
        // and the active height is unchanged.
        guard !isShowingDiagram || !constraintIsActive || !heightUnchanged else {
            return false
        }
        diagramHeightConstraint?.constant = clampedHeight
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        return true
    }

    private func showAsCodeFallback(code: String, palette: ThemePalette) {
        let wasShowingDiagram = isShowingDiagram

        codeBlockView.isHidden = false
        diagramImageView.isHidden = true
        diagramHeightConstraint?.isActive = false
        isShowingDiagram = false
        renderedDiagramNaturalSize = nil
        displayedRasterRequest = nil
        inFlightRasterRequest = nil
        renderTask = nil
        clearDiagramAccessibility()
        codeBlockView.apply(language: "mermaid", code: code, palette: palette, isOpen: false)

        if wasShowingDiagram {
            invalidateTimelineLayout()
        }
    }

    private func configureDiagramAccessibility() {
        isAccessibilityElement = true
        accessibilityIdentifier = "mermaid.diagram.open"
        accessibilityLabel = String(localized: "Mermaid diagram")
        accessibilityHint = String(localized: "Opens diagram full screen")
        accessibilityTraits = [.image, .button]
        // The rendered diagram is one control; its backing UIImageView must
        // not become a second VoiceOver stop.
        accessibilityElementsHidden = true
    }

    private func clearDiagramAccessibility() {
        isAccessibilityElement = false
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityHint = nil
        accessibilityTraits = []
        accessibilityElementsHidden = false
    }

    private func invalidateTimelineLayout() {
        // Diagram rasterization commonly completes after the first SwiftUI
        // sizeThatFits / collection-view self-sizing pass. Soft invalidation
        // is skipped while detached from bottom and no-ops with no collection
        // view. Force-invalidate so both surfaces adopt the rendered height.
        #if DEBUG
        debugInvalidateTimelineLayoutCount += 1
        #endif
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    override func accessibilityActivate() -> Bool {
        openDiagramPreview()
    }

    @objc private func handleTap() {
        _ = openDiagramPreview()
    }

    @discardableResult
    private func openDiagramPreview() -> Bool {
        guard let code = currentCode, isShowingDiagram else { return false }

        let content = FullScreenCodeContent.mermaid(content: code, filePath: nil)
        if let presenter = ToolTimelineRowPresentationHelpers.nearestViewController(from: self),
           !isInsideFullScreenCodeViewer(presenter) {
            ToolTimelineRowPresentationHelpers.presentFullScreenContent(
                content,
                from: self,
                reviewCommentSelectionRouter: reviewCommentSelectionRouter,
                reviewCommentSessionId: reviewCommentSourceContext?.sessionId,
                reviewCommentSourceLabel: reviewCommentSourceContext?.sourceLabel
            )
            return true
        }

        // The global presenter intentionally permits one focused visual above
        // a full-screen Markdown reader while still preventing deeper stacks.
        FullScreenCodeViewController.present(
            content: content,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSessionId: reviewCommentSourceContext?.sessionId,
            reviewCommentSourceLabel: reviewCommentSourceContext?.sourceLabel
        )
        return true
    }

    private func isInsideFullScreenCodeViewer(_ presenter: UIViewController) -> Bool {
        var current: UIViewController? = presenter
        while let node = current {
            if node is FullScreenCodeViewController { return true }
            current = node.parent
        }
        return false
    }
}

#if DEBUG
extension NativeMermaidBlockView {
    var debugIsShowingDiagramForTesting: Bool { isShowingDiagram }
    var debugRasterWidthForTesting: CGFloat? { displayedRasterRequest?.rasterWidth }
    var debugRenderCountForTesting: Int { debugRenderCount }
    var debugApplyAsDiagramCallCountForTesting: Int { debugApplyAsDiagramCallCount }
    var debugInvalidateTimelineLayoutCountForTesting: Int { debugInvalidateTimelineLayoutCount }
    var debugRenderedImageForTesting: UIImage? { diagramImageView.image }
    var debugDiagramHeightConstantForTesting: CGFloat? { diagramHeightConstraint?.constant }
    var debugDiagramHeightConstraintIsActiveForTesting: Bool {
        diagramHeightConstraint?.isActive == true
    }
}
#endif
