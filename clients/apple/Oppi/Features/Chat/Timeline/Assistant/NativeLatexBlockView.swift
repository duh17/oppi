import UIKit

/// Inline LaTeX math renderer for the chat timeline.
///
/// Shows a rendered formula when the code fence is closed, or falls back
/// to a syntax-highlighted code block while the fence is still open during
/// streaming. Parses via `TeXMathParser` and rasterizes via
/// `MathCoreGraphicsRenderer` on a background thread, then displays the
/// resulting image.
///
/// Tap opens `FullScreenCodeViewController` with pinch-to-zoom and full
/// export support. Same pattern as `NativeMermaidBlockView`.
@MainActor
final class NativeLatexBlockView: UIView {

    // MARK: - Subviews

    /// Code block shown while the fence is open (streaming) or on parse failure.
    private let codeBlockView = NativeCodeBlockView()

    /// Rasterized formula image.
    private let formulaImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.isUserInteractionEnabled = true
        iv.layer.cornerRadius = 8
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// Active only while showing the rendered formula. A direct self-height
    /// constraint makes stack/scroll relayout more reliable after async renders.
    private var formulaHeightConstraint: NSLayoutConstraint?

    /// Cap formula height in the timeline to keep cells reasonable.
    private static let maxInlineHeight: CGFloat = 400

    // MARK: - State

    private var currentCode: String?
    private var isShowingFormula = false
    private var renderTask: Task<Void, Never>?
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?

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

        formulaImageView.isHidden = true
        addSubview(formulaImageView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        formulaImageView.addGestureRecognizer(tapGesture)

        let formulaHeight = heightAnchor.constraint(equalToConstant: 200)
        formulaHeight.isActive = false
        formulaHeightConstraint = formulaHeight

        NSLayoutConstraint.activate([
            codeBlockView.topAnchor.constraint(equalTo: topAnchor),
            codeBlockView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeBlockView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeBlockView.bottomAnchor.constraint(equalTo: bottomAnchor),

            formulaImageView.topAnchor.constraint(equalTo: topAnchor),
            formulaImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            formulaImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            formulaImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// Show as a code block (streaming / fence still open).
    func applyAsCode(language: String?, code: String, palette: ThemePalette, isOpen: Bool) {
        renderTask?.cancel()
        renderTask = nil

        codeBlockView.isHidden = false
        formulaImageView.isHidden = true
        formulaHeightConstraint?.isActive = false
        isShowingFormula = false

        codeBlockView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
        currentCode = code
    }

    /// Render synchronously on the current thread. Used by export paths that
    /// snapshot the view immediately after layout.
    func applyAsFormulaSync(code: String, palette: ThemePalette) {
        currentCode = code

        let theme = ThemeRuntimeState.currentRenderTheme()
        let availableWidth = bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? 360)

        guard let result = DocumentRenderPipeline.renderInlineGraphicalImage(
            parser: TeXMathParser(),
            renderer: MathCoreGraphicsRenderer(),
            text: code,
            config: RenderConfiguration(
                fontSize: 13,
                maxWidth: availableWidth,
                theme: theme,
                displayMode: .inline
            )
        ) else {
            showAsCodeFallback(code: code, palette: palette)
            return
        }

        showFormula(image: result.image, naturalSize: result.size, palette: palette)
    }

    /// Render as a formula (fence closed, not streaming).
    func applyAsFormula(code: String, palette: ThemePalette) {
        guard code != currentCode || !isShowingFormula else { return }
        currentCode = code

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }

            let theme = ThemeRuntimeState.currentRenderTheme()
            let availableWidth = self.bounds.width > 0
                ? self.bounds.width
                : (self.window?.windowScene?.screen.bounds.width ?? 360)

            let result: (image: UIImage, size: CGSize)? = await Task.detached(priority: .userInitiated) {
                DocumentRenderPipeline.renderInlineGraphicalImage(
                    parser: TeXMathParser(),
                    renderer: MathCoreGraphicsRenderer(),
                    text: code,
                    config: RenderConfiguration(
                        fontSize: 13,
                        maxWidth: availableWidth,
                        theme: theme,
                        displayMode: .inline
                    )
                )
            }.value

            guard !Task.isCancelled else { return }

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
        sourceContext: ReviewCommentSourceContext?,
        reviewCommentAnnotations: [ReviewCommentInlineAnnotation] = []
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
        codeBlockView.configureReviewCommentSelection(
            router: router,
            sourceContext: sourceContext,
            reviewCommentAnnotations: reviewCommentAnnotations
        )
    }

    /// Apply syntax highlighting to the inner code block (when showing as code).
    func applyHighlightedCode(_ attributed: NSAttributedString) {
        codeBlockView.applyHighlightedCode(attributed)
    }

    // MARK: - Private

    private func showFormula(image: UIImage, naturalSize: CGSize, palette: ThemePalette) {
        let availableWidth = bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? 360)
        let scale = min(1.0, availableWidth / naturalSize.width)
        let displayHeight = min(naturalSize.height * scale, Self.maxInlineHeight)

        formulaHeightConstraint?.constant = displayHeight
        formulaHeightConstraint?.isActive = true
        formulaImageView.backgroundColor = UIColor(palette.bgHighlight)
        formulaImageView.image = image

        codeBlockView.isHidden = true
        formulaImageView.isHidden = false
        isShowingFormula = true

        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
        superview?.layoutIfNeeded()
        invalidateTimelineLayout()
    }

    private func showAsCodeFallback(code: String, palette: ThemePalette) {
        codeBlockView.isHidden = false
        formulaImageView.isHidden = true
        formulaHeightConstraint?.isActive = false
        isShowingFormula = false
        codeBlockView.apply(language: "latex", code: code, palette: palette, isOpen: false)
        invalidateTimelineLayout()
    }

    private func invalidateTimelineLayout() {
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
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
