import UIKit

/// Inline mermaid diagram renderer for the chat timeline.
///
/// Shows a rendered diagram when the code fence is closed, or falls back
/// to a syntax-highlighted code block while the fence is still open during
/// streaming. Parses and rasterizes via `DocumentRenderPipeline` +
/// `MermaidFlowchartRenderer` on a background thread, then displays the
/// resulting image in a pinch-to-zoom scroll view.
///
/// Tap opens `FullScreenCodeViewController` with full export support
/// (image, PDF, source).
@MainActor
final class NativeMermaidBlockView: UIView {

    // MARK: - Subviews

    /// Code block shown while the fence is open (streaming) or on parse failure.
    private let codeBlockView = NativeCodeBlockView()

    /// Rendered diagram container with pinch-to-zoom.
    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.minimumZoomScale = 1.0
        sv.maximumZoomScale = 4.0
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.bouncesZoom = true
        sv.bounces = false
        sv.alwaysBounceVertical = false
        sv.clipsToBounds = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    /// Rasterized diagram image view (inside scroll view for zoom).
    private let diagramImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// Height constraint for the scroll container, updated after layout.
    private var scrollHeightConstraint: NSLayoutConstraint?

    /// Width constraint for the image view inside the scroll view.
    private var imageWidthConstraint: NSLayoutConstraint?
    /// Height constraint for the image view inside the scroll view.
    private var imageHeightConstraint: NSLayoutConstraint?

    /// Horizontal centering constraint for the image inside the scroll view.
    private var imageCenterXConstraint: NSLayoutConstraint?

    /// Cap diagram height in the timeline to keep cells reasonable.
    private static let maxInlineHeight: CGFloat = 400

    // MARK: - State

    private var currentCode: String?
    private var isShowingDiagram = false
    private var renderTask: Task<Void, Never>?
    /// Selected-text context forwarded to the inner code block.
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

        scrollView.delegate = self
        scrollView.layer.cornerRadius = 8
        scrollView.isHidden = true
        addSubview(scrollView)

        scrollView.addSubview(diagramImageView)

        let scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 200)
        scrollHeightConstraint = scrollHeight

        let imgWidth = diagramImageView.widthAnchor.constraint(equalToConstant: 1)
        let imgHeight = diagramImageView.heightAnchor.constraint(equalToConstant: 1)
        imageWidthConstraint = imgWidth
        imageHeightConstraint = imgHeight

        // Center horizontally in the scroll view's frame (visible area), not
        // the content guide. This keeps the diagram centered when it's narrower
        // than the container. The constraint is at low priority so it yields
        // to the content guide edges when the content is wider / zoomed in.
        let centerX = diagramImageView.centerXAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.centerXAnchor
        )
        centerX.priority = .defaultHigh
        imageCenterXConstraint = centerX

        // Tap to open fullscreen — use a single-tap that doesn't interfere
        // with the scroll view's pinch gesture.
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGesture.numberOfTapsRequired = 1
        // Don't delay scroll view touches waiting for tap to fail.
        tapGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tapGesture)

        NSLayoutConstraint.activate([
            // Code block fills self
            codeBlockView.topAnchor.constraint(equalTo: topAnchor),
            codeBlockView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeBlockView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeBlockView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Scroll view fills self
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,

            // Image view sized by constraints, pinned to content guide
            diagramImageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            diagramImageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            diagramImageView.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor
            ),
            diagramImageView.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor
            ),
            centerX,
            imgWidth,
            imgHeight,
        ])
    }

    // MARK: - Public API

    /// Show as a code block (streaming / fence still open).
    func applyAsCode(language: String?, code: String, palette: ThemePalette, isOpen: Bool) {
        renderTask?.cancel()
        renderTask = nil

        codeBlockView.isHidden = false
        scrollView.isHidden = true
        isShowingDiagram = false

        codeBlockView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
        currentCode = code
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

            // Parse + layout + rasterize off the main thread.
            // GraphicalLayout contains a non-Sendable draw closure, so we
            // rasterize to a UIImage on the same detached task.
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
        let availableWidth = bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? 360)
        let scale = min(1.0, availableWidth / naturalSize.width)
        let displayHeight = min(naturalSize.height * scale, Self.maxInlineHeight)

        scrollView.backgroundColor = UIColor(palette.bgHighlight)
        scrollHeightConstraint?.constant = displayHeight

        // Size the image view to the scaled content size.
        let scaledWidth = naturalSize.width * scale
        let scaledHeight = naturalSize.height * scale
        imageWidthConstraint?.constant = scaledWidth
        imageHeightConstraint?.constant = scaledHeight

        diagramImageView.image = image

        // Reset zoom on new content.
        scrollView.zoomScale = 1.0

        codeBlockView.isHidden = true
        scrollView.isHidden = false
        isShowingDiagram = true

        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private func showAsCodeFallback(code: String, palette: ThemePalette) {
        codeBlockView.isHidden = false
        scrollView.isHidden = true
        isShowingDiagram = false
        codeBlockView.apply(language: "mermaid", code: code, palette: palette, isOpen: false)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Ignore taps when zoomed in — user is panning, not trying to open fullscreen.
        if scrollView.zoomScale > 1.05 { return }

        guard let code = currentCode, isShowingDiagram else { return }

        let fullScreenContent = FullScreenCodeContent.mermaid(content: code, filePath: nil)
        ToolTimelineRowPresentationHelpers.presentFullScreenContent(
            fullScreenContent,
            from: self,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSessionId: selectedTextSourceContext?.sessionId,
            selectedTextSourceLabel: selectedTextSourceContext?.sourceLabel
        )
    }

    // MARK: - Centering after zoom

    /// Re-center the image view within the scroll view after zoom changes.
    /// Without this, zooming out leaves the image stuck in the top-left corner.
    private func centerImageInScrollView() {
        let scrollSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize

        let horizontalInset = max(0, (scrollSize.width - contentSize.width) / 2)
        let verticalInset = max(0, (scrollSize.height - contentSize.height) / 2)

        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }
}

// MARK: - UIScrollViewDelegate (pinch-to-zoom)

extension NativeMermaidBlockView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        diagramImageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageInScrollView()
    }
}
