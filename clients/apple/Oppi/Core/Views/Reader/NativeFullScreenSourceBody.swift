import UIKit

final class NativeFullScreenSourceBody: UIView, UITextViewDelegate {
    private let textView = FullScreenReviewCommentTextView()
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private let palette: ThemePalette
    private let lineAnchor: SourceLineAnchor?
    private let lineAnchorResolution: SourceLineAnchorResolution?
    private var readerPreferences: FullScreenReaderPreferences
    private var isStreaming: Bool
    private var lineAnchorFocusTask: Task<Void, Never>?
    private var lineAnchorFocusPending = false

    private lazy var tailFollowCoordinator = TailFollowScrollCoordinator(
        scrollView: textView,
        shouldAutoFollowTail: isStreaming,
        performLayout: { [weak self] in
            self?.layoutIfNeeded()
        }
    )

    init(
        content: String,
        isStreaming: Bool,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.source.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        lineAnchor: SourceLineAnchor? = nil,
        focusLineAnchor: Bool = true
    ) {
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.palette = palette
        self.lineAnchor = lineAnchor
        self.lineAnchorResolution = lineAnchor?.resolution(fileContent: content)
        self.readerPreferences = readerPreferences
        self.isStreaming = isStreaming
        self.lineAnchorFocusPending = lineAnchor != nil && focusLineAnchor
        super.init(frame: .zero)

        backgroundColor = palette.ui.bgDark

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = codeFont
        textView.textColor = palette.ui.fg
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        textView.delegate = self
        textView.text = content
        textView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
        if let lineAnchorResolution {
            textView.accessibilityLabel = "Source text"
            textView.accessibilityValue = lineAnchorResolution.accessibilityLabel
        }
        applyWrapMode()
        addSubview(textView)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        lineAnchorFocusTask?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyWrapMode()
        updateLineAnchorHighlight()
        scheduleLineAnchorFocusIfNeeded()
        tailFollowCoordinator.onLayoutPass()
    }

    private var codeFont: UIFont {
        FullScreenCodeTypography.codeFont(for: readerPreferences)
    }

    func update(content: String, isStreaming: Bool) {
        let textDidChange = textView.text != content
        let streamingDidChange = self.isStreaming != isStreaming

        guard textDidChange || streamingDidChange else {
            tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
            return
        }

        self.isStreaming = isStreaming
        textView.text = content
        if !isStreaming {
            tailFollowCoordinator.shouldAutoFollowTail = false
        }
        tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleWillBeginDragging()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // TextKit rects are expressed in the text view's content coordinates.
        // Recompute the overlay here so a user scroll moves the enclosure with
        // the source instead of leaving it at the pre-scroll position. This
        // only repaints geometry; focus and content offset remain untouched.
        updateLineAnchorHighlight()
        tailFollowCoordinator.handleDidScroll(
            isUserDriven: scrollView.isDragging || scrollView.isDecelerating,
            isStreaming: isStreaming
        )
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        tailFollowCoordinator.handleDidEndDragging(
            willDecelerate: decelerate,
            isStreaming: isStreaming
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleDidEndDecelerating(isStreaming: isStreaming)
    }

    private func updateLineAnchorHighlight() {
        guard let existingRange = lineAnchorResolution?.existingRange else {
            textView.setLineAnchorHighlight(
                rects: [],
                fillColor: UIColor.systemBlue.withAlphaComponent(0.08),
                strokeColor: UIColor.systemBlue.withAlphaComponent(0.75)
            )
            return
        }

        let layout = FullScreenLineAnchorLayout.layout(
            for: textView,
            sourceLineRange: existingRange,
            startLine: 1
        )
        textView.setLineAnchorHighlight(
            rects: layout.visibleRects,
            firstRect: layout.firstVisibleRect,
            fillColor: palette.ui.blue.withAlphaComponent(0.08),
            strokeColor: palette.ui.blue.withAlphaComponent(0.75)
        )
    }

    private func scheduleLineAnchorFocusIfNeeded() {
        guard lineAnchorFocusPending, lineAnchorFocusTask == nil else { return }
        lineAnchorFocusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.lineAnchorFocusTask = nil
            guard self.textView.bounds.height > 0 else {
                self.lineAnchorFocusPending = true
                return
            }
            self.lineAnchorFocusPending = false
            self.scrollLineAnchorIntoUpperThird()
        }
    }

    private func scrollLineAnchorIntoUpperThird() {
        guard lineAnchorResolution != nil, textView.bounds.height > 0 else { return }
        textView.layoutIfNeeded()

        let targetY: CGFloat
        if let existingRange = lineAnchorResolution?.existingRange,
           let firstRect = FullScreenLineAnchorLayout.layout(
               for: textView,
               sourceLineRange: existingRange,
               startLine: 1
           ).firstContentRect {
            targetY = firstRect.minY - textView.bounds.height / 3
        } else {
            targetY = textView.contentSize.height
        }

        let minimumY = -textView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            textView.contentSize.height
                - textView.bounds.height
                + textView.adjustedContentInset.bottom
        )
        let clampedY = min(max(targetY, minimumY), maximumY)
        guard clampedY.isFinite else { return }
        textView.setContentOffset(
            CGPoint(x: textView.contentOffset.x, y: clampedY),
            animated: false
        )
        updateLineAnchorHighlight()
        UIAccessibility.post(notification: .layoutChanged, argument: textView)
    }

    private func applyTextSize() {
        textView.font = codeFont
    }

    private func applyWrapMode() {
        let wraps = readerPreferences.wrapsText
        textView.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        textView.textContainer.widthTracksTextView = wraps
        textView.textContainer.size = wraps
            ? CGSize(width: max(1, textView.bounds.width), height: CGFloat.greatestFiniteMagnitude)
            : CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.alwaysBounceHorizontal = !wraps
        textView.showsHorizontalScrollIndicator = !wraps
        if wraps {
            textView.contentOffset.x = -textView.adjustedContentInset.left
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? FullScreenReviewCommentTextView)?.reviewCommentSelectionDidChange()
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenReviewCommentMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}

extension NativeFullScreenSourceBody: ReaderBody {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        readerPreferences = preferences
        applyTextSize()
        applyWrapMode()
        textView.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}

#if DEBUG
extension NativeFullScreenSourceBody {
    var debugLineAnchorExistingRangeForTesting: ClosedRange<Int>? {
        lineAnchorResolution?.existingRange
    }

    var debugLineAnchorHighlightRectCountForTesting: Int {
        textView.debugLineAnchorHighlightRectCountForTesting
    }

    var debugLineAnchorFirstHighlightRectForTesting: CGRect? {
        textView.debugLineAnchorFirstHighlightRectForTesting
    }

    var debugLineAnchorHighlightEnclosureRectForTesting: CGRect? {
        textView.debugLineAnchorHighlightEnclosureRectForTesting
    }

    var debugLineAnchorVisibleHighlightGeometryForTesting: Bool {
        textView.debugLineAnchorHighlightHasVisibleGeometryForTesting
    }

    var debugLineAnchorVisibleHighlightAlignedWithTargetForTesting: Bool {
        textView.debugLineAnchorHighlightContainsFirstTargetForTesting
    }

    var debugLineAnchorScrollOffsetForTesting: CGPoint {
        textView.contentOffset
    }
}
#endif
