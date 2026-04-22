import UIKit

/// Inline mermaid diagram renderer for the chat timeline.
///
/// Shows a rendered diagram when the code fence is closed, or falls back
/// to a syntax-highlighted code block while the fence is still open during
/// streaming. Parses and rasterizes via `DocumentRenderPipeline` +
/// `MermaidFlowchartRenderer` on a background thread, then displays the
/// resulting image.
///
/// Tap opens `FullScreenCodeViewController` with pinch-to-zoom and full
/// export support (image, PDF, source). No inline zoom — keeps the view
/// simple and avoids UIScrollView gesture conflicts.
@MainActor
final class NativeMermaidBlockView: UIView {

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

    private var currentCode: String?
    private var isShowingDiagram = false
    /// Natural (unscaled) diagram size from the latest successful render.
    /// Used to recompute inline height if the view width changes later.
    private var renderedDiagramNaturalSize: CGSize?
    private var renderTask: Task<Void, Never>?
    private var selectedTextPiRouter: SelectedTextPiActionRouter?
    private var selectedTextSourceContext: SelectedTextSourceContext?

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
        // message-bubble width. Recompute height on later width changes so
        // diagrams don't stay clamped until an unrelated snapshot reconfigure.
        guard isShowingDiagram,
              let naturalSize = renderedDiagramNaturalSize,
              naturalSize.width > 0,
              naturalSize.height > 0,
              bounds.width > 0 else {
            return
        }

        updateDiagramHeight(naturalSize: naturalSize, availableWidth: bounds.width)
    }

    // MARK: - Public API

    /// Show as a code block (streaming / fence still open).
    func applyAsCode(language: String?, code: String, palette: ThemePalette, isOpen: Bool) {
        let wasShowingDiagram = isShowingDiagram

        renderTask?.cancel()
        renderTask = nil

        codeBlockView.isHidden = false
        diagramImageView.isHidden = true
        diagramHeightConstraint?.isActive = false
        isShowingDiagram = false
        renderedDiagramNaturalSize = nil

        codeBlockView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
        currentCode = code

        if wasShowingDiagram {
            invalidateTimelineLayout()
        }
    }

    /// Render synchronously on the current thread. Used by export paths that
    /// snapshot the view immediately after layout — async rendering would
    /// complete after the snapshot, producing blank boxes.
    func applyAsDiagramSync(code: String, palette: ThemePalette) {
        currentCode = code

        let theme = ThemeRuntimeState.currentRenderTheme()
        let availableWidth = bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? 360)

        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidFlowchartRenderer(),
            text: code,
            config: RenderConfiguration(
                fontSize: 13,
                maxWidth: availableWidth,
                theme: theme,
                displayMode: .inline
            )
        )
        guard layout.size.width > 0, layout.size.height > 0 else {
            showAsCodeFallback(code: code, palette: palette)
            return
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        let renderer = UIGraphicsImageRenderer(size: layout.size, format: format)
        let image = renderer.image { ctx in
            layout.draw(ctx.cgContext, .zero)
        }

        showDiagram(image: image, naturalSize: layout.size, palette: palette)
    }

    /// Render as a diagram (fence closed, not streaming).
    func applyAsDiagram(code: String, palette: ThemePalette) {
        // Skip redundant renders.
        guard code != currentCode || !isShowingDiagram else { return }
        currentCode = code

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }

            let theme = ThemeRuntimeState.currentRenderTheme()
            let availableWidth = self.bounds.width > 0
                ? self.bounds.width
                : (self.window?.windowScene?.screen.bounds.width ?? 360)

            let result: (image: UIImage, size: CGSize)? = await Task.detached(priority: .userInitiated) {
                let layout = DocumentRenderPipeline.layoutGraphical(
                    parser: MermaidParser(),
                    renderer: MermaidFlowchartRenderer(),
                    text: code,
                    config: RenderConfiguration(
                        fontSize: 13,
                        maxWidth: availableWidth,
                        theme: theme,
                        displayMode: .inline
                    )
                )
                guard layout.size.width > 0, layout.size.height > 0 else { return nil }

                let format = UIGraphicsImageRendererFormat()
                format.scale = 2.0
                let renderer = UIGraphicsImageRenderer(size: layout.size, format: format)
                let image = renderer.image { ctx in
                    layout.draw(ctx.cgContext, .zero)
                }
                return (image: image, size: layout.size)
            }.value

            guard !Task.isCancelled else { return }

            guard let result else {
                self.showAsCodeFallback(code: code, palette: palette)
                return
            }

            self.showDiagram(image: result.image, naturalSize: result.size, palette: palette)
        }
    }

    /// Configure selected-text Pi action forwarding on the inner code block.
    func configureSelectedTextPi(
        router: SelectedTextPiActionRouter?,
        sourceContext: SelectedTextSourceContext?
    ) {
        selectedTextPiRouter = router
        selectedTextSourceContext = sourceContext
        codeBlockView.configureSelectedTextPi(router: router, sourceContext: sourceContext)
    }

    /// Apply syntax highlighting to the inner code block (when showing as code).
    func applyHighlightedCode(_ attributed: NSAttributedString) {
        codeBlockView.applyHighlightedCode(attributed)
    }

    // MARK: - Private

    private func showDiagram(image: UIImage, naturalSize: CGSize, palette: ThemePalette) {
        renderedDiagramNaturalSize = naturalSize

        let fallbackWidth = window?.windowScene?.screen.bounds.width ?? 360
        let availableWidth = bounds.width > 0 ? bounds.width : fallbackWidth
        updateDiagramHeight(naturalSize: naturalSize, availableWidth: availableWidth)

        diagramHeightConstraint?.isActive = true
        diagramImageView.backgroundColor = UIColor(palette.bgHighlight)
        diagramImageView.image = image

        codeBlockView.isHidden = true
        diagramImageView.isHidden = false
        isShowingDiagram = true

        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        superview?.layoutIfNeeded()
        invalidateTimelineLayout()
    }

    private func updateDiagramHeight(naturalSize: CGSize, availableWidth: CGFloat) {
        guard availableWidth > 0, naturalSize.width > 0, naturalSize.height > 0 else { return }

        let scale = min(1.0, availableWidth / naturalSize.width)
        let displayHeight = min(naturalSize.height * scale, Self.maxInlineHeight)
        let clampedHeight = max(1, displayHeight)

        if abs((diagramHeightConstraint?.constant ?? 0) - clampedHeight) > 0.5 {
            diagramHeightConstraint?.constant = clampedHeight
            invalidateIntrinsicContentSize()
            superview?.setNeedsLayout()
            invalidateTimelineLayout()
        }
    }

    private func showAsCodeFallback(code: String, palette: ThemePalette) {
        let wasShowingDiagram = isShowingDiagram

        codeBlockView.isHidden = false
        diagramImageView.isHidden = true
        diagramHeightConstraint?.isActive = false
        isShowingDiagram = false
        renderedDiagramNaturalSize = nil
        codeBlockView.apply(language: "mermaid", code: code, palette: palette, isOpen: false)

        if wasShowingDiagram {
            invalidateTimelineLayout()
        }
    }

    private func invalidateTimelineLayout() {
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    @objc private func handleTap() {
        guard let code = currentCode, isShowingDiagram else { return }

        // Use the same static presentation approach as NativeMarkdownImageView.
        // Walking the responder chain from `self` via nearestViewController()
        // can fail silently when the view hierarchy doesn't have a clean
        // UIViewController chain.
        let content = FullScreenCodeContent.mermaid(content: code, filePath: nil)
        FullScreenCodeViewController.present(
            content: content,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSessionId: selectedTextSourceContext?.sessionId,
            selectedTextSourceLabel: selectedTextSourceContext?.sourceLabel
        )
    }
}
