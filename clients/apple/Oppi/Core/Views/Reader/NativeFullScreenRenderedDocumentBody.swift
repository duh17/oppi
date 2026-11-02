import UIKit

/// Fullscreen body for single-canvas rendered document types. Org documents use
/// ``NativeFullScreenMarkdownBody`` so their multi-block content is virtualized.
final class NativeFullScreenRenderedDocumentBody: UIView, UIScrollViewDelegate {

    enum DocumentContent {
        case latex(String)
        case mermaid(String)
    }

    private struct LatexView {
        let view: UIView
        let isGraphical: Bool
    }

    private let scrollView = UIScrollView()
    private var readerPreferences: FullScreenReaderPreferences
    private let themeID: ThemeID
    private var latexText: String?
    private var latexContentView: UIView?
    private var latexZoomContentView: UIView?
    private var installedLatexDoubleTap = false
    private(set) var mermaidPicker: ZoomableGraphicalView?
    private var mermaidSource: (text: String, theme: RenderTheme)?
    /// Layout width the current diagram was built for; nil before the first.
    private var mermaidLayoutWidth: CGFloat?
    /// Lays the diagram out again once a width change settles.
    private let mermaidResizeSettle = MermaidWidthSettle()
    /// The current layout outlived the turn that built it, so it has been on
    /// screen; width changes in that turn are still the first layout.
    private var mermaidLayoutHasBeenOnScreen = false
    #if DEBUG
    private(set) var debugMermaidLayoutCountForTesting = 0
    #endif
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?

    init(
        content: DocumentContent,
        themeID: ThemeID? = nil,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.renderedDocument.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?
    ) {
        self.readerPreferences = readerPreferences
        self.themeID = themeID ?? ThemeRuntimeState.currentThemeID()
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        super.init(frame: .zero)
        backgroundColor = palette.ui.bgDark

        switch content {
        case .mermaid(let text):
            // ZoomableGraphicalView has its own scroll + zoom — embed directly.
            // The diagram is laid out once this body has a width
            // (`layoutMermaidForCurrentWidth`).
            mermaidSource = (text, palette.renderTheme)
            let zoomable = ZoomableGraphicalView(size: CGSize(width: 1, height: 1), draw: { _, _ in })
            mermaidPicker = zoomable
            zoomable.translatesAutoresizingMaskIntoConstraints = false
            addSubview(zoomable)
            NSLayoutConstraint.activate([
                zoomable.leadingAnchor.constraint(equalTo: leadingAnchor),
                zoomable.trailingAnchor.constraint(equalTo: trailingAnchor),
                zoomable.topAnchor.constraint(equalTo: topAnchor),
                zoomable.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

        case .latex(let text):
            // LaTeX uses the outer scroll view.
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.alwaysBounceVertical = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.backgroundColor = palette.ui.bgDark
            scrollView.accessibilityIdentifier = "fullscreen-latex.scroll"
            scrollView.accessibilityLabel = "Full-screen formula"
            scrollView.alwaysBounceHorizontal = true
            addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            latexText = text
            installLatexContent(text: text)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Lays the formulas out at the current text size, replacing any earlier
    /// layout. A replacement starts at the top at fit zoom, as a new body would.
    private func installLatexContent(text: String) {
        if let previous = latexContentView {
            scrollView.zoomScale = scrollView.minimumZoomScale
            previous.removeFromSuperview()
            latexZoomContentView = nil
        }
        let latex = makeLatexView(text: text)
        let contentView = latex.view
        latexContentView = contentView
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 14),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -14),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
        ])

        // LaTeX keeps its natural width. The content guide grows beyond
        // the viewport when needed, creating real two-axis overflow.
        contentView.widthAnchor.constraint(
            greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -28
        ).isActive = true

        if latex.isGraphical {
            latexZoomContentView = contentView
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 4
            scrollView.bouncesZoom = true
            scrollView.delegate = self
            if !installedLatexDoubleTap {
                installedLatexDoubleTap = true
                DoubleTapZoom.install(
                    on: scrollView,
                    target: self,
                    action: #selector(handleLatexDoubleTap(_:))
                )
            }
            updateLatexAccessibilityValue()
        }
        scrollView.contentOffset = CGPoint(
            x: -scrollView.adjustedContentInset.left,
            y: -scrollView.adjustedContentInset.top
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutMermaidForCurrentWidth()
    }

    /// Full screen fits the diagram to this body's own width (a full window,
    /// a reader column, or a split-view pane) and lays it out again when that
    /// width changes. No height cap: full screen scrolls and zooms instead.
    ///
    /// Until a layout has been on screen, every width lays out at once. After
    /// that, width changes (rotation, split view, Stage Manager) keep the
    /// current diagram until the width settles, then lay out once; a width
    /// that maps to the same layout width changes nothing, so the reader's
    /// zoom stays.
    private func layoutMermaidForCurrentWidth(settled: Bool = false) {
        guard let source = mermaidSource, let zoomable = mermaidPicker, bounds.width > 0 else { return }
        let config = DocumentRenderPipeline.mermaidConfiguration(theme: source.theme, availableWidth: bounds.width)
        guard config.maxWidth != mermaidLayoutWidth else {
            mermaidResizeSettle.cancel()
            return
        }
        if mermaidLayoutHasBeenOnScreen, !settled {
            mermaidResizeSettle.schedule { [weak self] in self?.layoutMermaidForCurrentWidth(settled: true) }
            return
        }
        mermaidResizeSettle.cancel()
        mermaidLayoutWidth = config.maxWidth
        mermaidLayoutHasBeenOnScreen = false
        DispatchQueue.main.async { [weak self, width = config.maxWidth] in
            guard let self, self.mermaidLayoutWidth == width else { return }
            self.mermaidLayoutHasBeenOnScreen = true
        }
        #if DEBUG
        debugMermaidLayoutCountForTesting += 1
        #endif
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(), renderer: MermaidRenderer(), text: source.text, config: config
        )
        zoomable.update(size: layout.size, draw: layout.draw)
        zoomable.configureSemanticPick(map: layout.semanticMap) { [weak self] target in
            self?.presentSemanticComment(for: target)
        }
        // Pick availability is known only now; let the host refresh its controls.
        zoomable.onPickStateChange?(zoomable.isPickingObjects, zoomable.hasSelection)
    }

    private func presentSemanticComment(for target: SemanticTarget) {
        guard let reviewCommentSelectionRouter, let reviewCommentSourceContext else { return }
        let request = ReviewCommentSelectionRequest(
            selectedText: target.label,
            source: reviewCommentSourceContext,
            semanticAnchor: target.semanticAnchor()
        )
        ReviewCommentInlineDraftPresenter.present(
            sourceView: self,
            request: request,
            router: reviewCommentSelectionRouter
        )
    }

    @objc private func handleLatexDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let latexZoomContentView else { return }
        DoubleTapZoom.toggle(
            in: scrollView,
            tapInContent: gesture.location(in: latexZoomContentView),
            fitScale: scrollView.minimumZoomScale
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        latexZoomContentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateLatexAccessibilityValue()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateLatexAccessibilityValue()
    }

    private func updateLatexAccessibilityValue() {
        guard latexZoomContentView != nil else { return }
        let zoomPercent = Int((scrollView.zoomScale * 100).rounded())
        let horizontalOffset = max(
            0,
            scrollView.contentOffset.x + scrollView.adjustedContentInset.left
        )
        scrollView.accessibilityValue = "Zoom \(zoomPercent) percent, horizontal offset \(Int(horizontalOffset.rounded())) points"
    }

    private func makeLatexView(text: String) -> LatexView {
        let config = RenderConfiguration(
            fontSize: UIFont.preferredFont(forTextStyle: .title1).pointSize * readerPreferences.textScale,
            maxWidth: 800,
            theme: themeID.palette.renderTheme,
            displayMode: .document
        )
        let multiLayout = DocumentRenderPipeline.layoutLatexExpressions(text: text, config: config)
        if let source = multiLayout.exactSourceFallback {
            return LatexView(
                view: DocumentRenderPipeline.makeLatexSourceFallbackView(
                    source: source,
                    palette: themeID.palette
                ),
                isGraphical: false
            )
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = multiLayout.spacing
        stack.alignment = .leading
        stack.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(multiLayout.totalSize.width, 1)
        ).isActive = true

        for (expr, source) in zip(multiLayout.expressions, multiLayout.sources) {
            let drawView = GraphicalRendererUIView()
            drawView.configure(
                size: expr.size,
                draw: expr.draw,
                accessibilityLabel: FlatSegment.formulaAccessibilityLabel(for: source)
            )
            drawView.translatesAutoresizingMaskIntoConstraints = false
            drawView.widthAnchor.constraint(equalToConstant: max(expr.size.width, 1)).isActive = true
            drawView.heightAnchor.constraint(equalToConstant: max(expr.size.height, 1)).isActive = true
            stack.addArrangedSubview(drawView)
        }

        return LatexView(view: stack, isGraphical: true)
    }

}

extension NativeFullScreenRenderedDocumentBody: ReaderBody {
    /// LaTeX lays out again at the new text size; a diagram ignores reader
    /// preferences (its content has no Viewing Options).
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        readerPreferences = preferences
        guard let latexText else { return }
        installLatexContent(text: latexText)
    }

    var picker: (any ReaderPicking)? { mermaidPicker }

    var annotateAvailability: ReaderAnnotateAvailability { .ready }

    func renderedSnapshot() async throws -> UIImage {
        layoutIfNeeded()
        let bounds = bounds
        guard bounds.width > 1, bounds.height > 1 else {
            throw PaperMarkupCanvasSession.SnapshotError.notReady
        }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }
}

#if DEBUG
extension NativeFullScreenRenderedDocumentBody {
    func debugToggleLatexZoomForTesting(at pointInContent: CGPoint) {
        guard latexZoomContentView != nil else { return }
        DoubleTapZoom.toggle(
            in: scrollView,
            tapInContent: pointInContent,
            fitScale: scrollView.minimumZoomScale,
            animated: false
        )
    }
}
#endif
