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
///
/// Inline never shrinks a diagram below `MermaidInlinePresentation`'s
/// legible scale: larger diagrams show a clipped preview with a footer, and
/// the expanded view keeps the same geometry.
@MainActor
final class NativeMermaidBlockView: UIView {
    struct RasterResult: @unchecked Sendable {
        let image: UIImage
        let size: CGSize
        /// Where a clipped preview pins the diagram.
        var previewAnchor = MermaidInlinePresentation.Anchor.center
    }

    struct Rasterizer: Sendable {
        let renderSync: @Sendable (String, CGFloat, RenderTheme) -> RasterResult?
        let renderAsync: @Sendable (String, CGFloat, RenderTheme) async -> RasterResult?

        static let live = Rasterizer(
            renderSync: { code, _, theme in
                DocumentRenderPipeline.renderInlineGraphicalImage(
                    parser: MermaidParser(),
                    renderer: MermaidRenderer(),
                    text: code,
                    config: DocumentRenderPipeline.mermaidConfiguration(theme: theme)
                ).map {
                    RasterResult(
                        image: $0.image,
                        size: $0.size,
                        previewAnchor: MermaidInlinePresentation.anchor(for: code)
                    )
                }
            },
            renderAsync: { code, _, theme in
                #if DEBUG
                await NativeMermaidBlockView.testHooks.beforeAsyncRaster?(code)
                #endif
                return await Task.detached(priority: .userInitiated) {
                    DocumentRenderPipeline.renderInlineGraphicalImage(
                        parser: MermaidParser(),
                        renderer: MermaidRenderer(),
                        text: code,
                        config: DocumentRenderPipeline.mermaidConfiguration(theme: theme)
                    ).map {
                        RasterResult(
                            image: $0.image,
                            size: $0.size,
                            previewAnchor: MermaidInlinePresentation.anchor(for: code)
                        )
                    }
                }.value
            }
        )
    }

    // MARK: - Subviews

    /// Code block shown while the fence is open (streaming) or on parse failure.
    private let codeBlockView = NativeCodeBlockView()

    /// Clips the rasterized diagram to the bubble. No UIScrollView, no inline
    /// zoom. Tap opens fullscreen for zoom/export.
    private let diagramClipView: UIView = {
        let view = UIView()
        view.clipsToBounds = true
        view.isUserInteractionEnabled = true
        view.isAccessibilityElement = false
        view.layer.cornerRadius = 8
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// Natural-geometry raster, framed by `MermaidInlinePresentation`.
    private let diagramImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleToFill
        iv.isAccessibilityElement = false
        return iv
    }()

    /// Shown only for clipped previews: says the diagram continues.
    private let previewFooterLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        // The footer band is a fixed 28pt so the reserved cell height
        // matches the raster; cap growth to what fits in it.
        label.maximumContentSizeCategory = .extraExtraLarge
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.textAlignment = .center
        label.text = String(localized: "Partial preview · Tap to expand")
        label.isAccessibilityElement = false
        label.isHidden = true
        return label
    }()

    /// Active only while showing the rendered diagram. A direct self-height
    /// constraint makes stack/scroll relayout more reliable after async renders.
    private var diagramHeightConstraint: NSLayoutConstraint?
    private var previewAnchor = MermaidInlinePresentation.Anchor.center
    private var isShowingPartialPreview = false

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
    /// Ordering seams for tests that must control when the live async raster
    /// runs and observe when it lands. Both receive the diagram source so a test
    /// can act on its own fixture only; other views rendering concurrently are
    /// not held or reported.
    struct TestHooks: Sendable {
        /// Awaited before the live async rasterizer starts.
        var beforeAsyncRaster: (@Sendable (String) async -> Void)?
        /// Called on the main actor after a rendered diagram has been installed.
        var didShowDiagram: (@Sendable @MainActor (String) -> Void)?
    }

    nonisolated private static let testHooksLock = NSLock()
    nonisolated(unsafe) private static var installedTestHooks = TestHooks()
    nonisolated static var testHooks: TestHooks {
        get { testHooksLock.withLock { installedTestHooks } }
        set { testHooksLock.withLock { installedTestHooks = newValue } }
    }
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

        diagramClipView.isHidden = true
        diagramClipView.addSubview(diagramImageView)
        diagramClipView.addSubview(previewFooterLabel)
        addSubview(diagramClipView)

        // Tap to open fullscreen — same pattern as NativeMarkdownImageView
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        diagramClipView.addGestureRecognizer(tapGesture)

        let diagramHeight = heightAnchor.constraint(equalToConstant: 200)
        diagramHeight.isActive = false
        diagramHeightConstraint = diagramHeight

        NSLayoutConstraint.activate([
            // Code block fills self
            codeBlockView.topAnchor.constraint(equalTo: topAnchor),
            codeBlockView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeBlockView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeBlockView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Clip view fills self while the container height is driven by
            // `diagramHeightConstraint` when the rendered diagram is visible.
            diagramClipView.topAnchor.constraint(equalTo: topAnchor),
            diagramClipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diagramClipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diagramClipView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func layoutDiagramContent() {
        guard let naturalSize = renderedDiagramNaturalSize, bounds.width > 0 else { return }
        let presentation = MermaidInlinePresentation(
            naturalSize: naturalSize,
            availableWidth: bounds.width,
            anchor: previewAnchor
        )
        diagramImageView.frame = presentation.imageFrame
        previewFooterLabel.isHidden = !presentation.isPartial
        previewFooterLabel.frame = CGRect(
            x: 0,
            y: presentation.height - MermaidInlinePresentation.footerHeight,
            width: bounds.width,
            height: MermaidInlinePresentation.footerHeight
        )
        if presentation.isPartial != isShowingPartialPreview {
            isShowingPartialPreview = presentation.isPartial
            if isShowingDiagram { configureDiagramAccessibility() }
        }
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
        layoutDiagramContent()

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
        diagramClipView.isHidden = true
        diagramHeightConstraint?.isActive = false
        isShowingDiagram = false
        renderedDiagramNaturalSize = nil
        requiresExactRasterWidth = false
        currentPalette = palette
        // A reused cell must not frame the next diagram's reservation with
        // the previous image and anchor before its own raster arrives.
        diagramImageView.image = nil
        previewAnchor = .center
        isShowingPartialPreview = false
        previewFooterLabel.isHidden = true
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
        applyDiagramChrome(palette)
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
            result,
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
        applyDiagramChrome(palette)
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
                result,
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
            config: DocumentRenderPipeline.mermaidConfiguration(theme: theme)
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
        diagramClipView.isHidden = false
        isShowingDiagram = true
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        if heightOrRevealChanged {
            invalidateTimelineLayout()
        }
        return true
    }

    private func applyDiagramChrome(_ palette: ThemePalette) {
        diagramClipView.backgroundColor = UIColor(palette.bgHighlight)
        previewFooterLabel.backgroundColor = UIColor(palette.bgHighlight)
        previewFooterLabel.textColor = UIColor(palette.comment)
    }

    private func showDiagram(
        _ result: RasterResult,
        palette: ThemePalette,
        request: RasterRequest,
        invalidateHostLayout: Bool
    ) {
        let naturalSize = result.size
        renderedDiagramNaturalSize = naturalSize
        previewAnchor = result.previewAnchor
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
        applyDiagramChrome(palette)
        diagramImageView.image = result.image

        codeBlockView.isHidden = true
        diagramClipView.isHidden = false
        isShowingDiagram = true
        layoutDiagramContent()
        configureDiagramAccessibility()

        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        if invalidateHostLayout && heightOrRevealChanged {
            invalidateTimelineLayout()
        }
        #if DEBUG
        if let code = currentCode {
            Self.testHooks.didShowDiagram?(code)
        }
        #endif
    }

    @discardableResult
    private func updateDiagramHeight(
        naturalSize: CGSize,
        availableWidth: CGFloat
    ) -> Bool {
        guard availableWidth > 0, naturalSize.width > 0, naturalSize.height > 0 else {
            return false
        }

        // Height does not depend on alignment, so the fence-close reservation
        // matches the final raster before the preview anchor is known.
        let clampedHeight = MermaidInlinePresentation(
            naturalSize: naturalSize,
            availableWidth: availableWidth,
            anchor: .center
        ).height
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
        diagramClipView.isHidden = true
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
        accessibilityLabel = isShowingPartialPreview
            ? String(localized: "Mermaid diagram, partial preview")
            : String(localized: "Mermaid diagram")
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
        ToolTimelineRowPresentationHelpers.presentFullScreenContent(
            content,
            from: self,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSessionId: reviewCommentSourceContext?.sessionId,
            reviewCommentSourceLabel: reviewCommentSourceContext?.sourceLabel,
            reviewCommentFilePath: reviewCommentSourceContext?.filePath,
            reviewCommentTimelineItemId: reviewCommentSourceContext?.timelineItemId
        )
        return true
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
    var debugIsShowingPartialPreviewForTesting: Bool { !previewFooterLabel.isHidden }
    var debugDiagramImageFrameForTesting: CGRect { diagramImageView.frame }
}
#endif

/// How a natural-size diagram sits in an inline bubble.
///
/// The whole diagram shows when it fits at `minPreviewScale` or larger.
/// Otherwise inline shows a clipped preview at a legible scale with a
/// footer; expanding uses the same geometry with Fit/Readable controls.
struct MermaidInlinePresentation: Equatable {
    static let maxHeight: CGFloat = 400
    /// 14pt labels stay about 12pt; smaller is unreadable on a phone.
    static let minPreviewScale: CGFloat = 0.85
    static let footerHeight: CGFloat = 28

    let height: CGFloat
    let imageFrame: CGRect
    let isPartial: Bool

    /// Where a clipped preview pins the diagram: the side its flow starts.
    struct Anchor: Equatable, Sendable {
        enum Horizontal: Sendable { case leading, center, trailing }
        var horizontal: Horizontal = .center
        var fromBottom = false

        static let center = Anchor()
    }

    init(naturalSize: CGSize, availableWidth: CGFloat, anchor: Anchor) {
        let width = max(availableWidth, 1)
        let natural = CGSize(width: max(naturalSize.width, 1), height: max(naturalSize.height, 1))
        let widthFit = min(1, width / natural.width)
        let fullFit = min(widthFit, Self.maxHeight / natural.height)
        if fullFit >= Self.minPreviewScale {
            let size = CGSize(width: natural.width * fullFit, height: natural.height * fullFit)
            height = max(1, size.height)
            imageFrame = CGRect(origin: CGPoint(x: (width - size.width) / 2, y: 0), size: size)
            isPartial = false
            return
        }
        let scale = max(Self.minPreviewScale, widthFit)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        height = min(size.height + Self.footerHeight, Self.maxHeight)
        var x = (width - size.width) / 2
        if size.width > width {
            switch anchor.horizontal {
            case .leading: x = 0
            case .trailing: x = width - size.width
            case .center: break
            }
        }
        let visibleHeight = height - Self.footerHeight
        let y = anchor.fromBottom && size.height > visibleHeight ? visibleHeight - size.height : 0
        imageFrame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        isPartial = true
    }

    /// Top-down trees, mind maps, and pies grow from the center top. Flows
    /// start where their sources are: LR charts, sequences, and timelines at
    /// the leading edge, RL at the trailing edge, BT at the bottom.
    nonisolated static func anchor(for source: String) -> Anchor {
        func flow(_ direction: FlowDirection) -> Anchor {
            switch direction {
            case .LR: return Anchor(horizontal: .leading)
            case .RL: return Anchor(horizontal: .trailing)
            case .BT: return Anchor(fromBottom: true)
            case .TB, .TD: return .center
            }
        }
        switch MermaidParser().parse(source) {
        case .flowchart(let diagram):
            return flow(diagram.direction)
        case .state(let diagram):
            return flow(diagram.direction)
        case .mindmap, .pie, .quadrantChart, .unsupported:
            return .center
        case .sequence, .gantt, .timeline, .classDiagram, .erDiagram, .xyChart,
             .gitGraph, .sankey, .kanban, .journey:
            return Anchor(horizontal: .leading)
        }
    }
}
