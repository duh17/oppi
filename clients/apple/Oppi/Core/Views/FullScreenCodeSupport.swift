import SwiftUI
import UIKit

/// Shared chrome convention for all fullscreen viewer controllers.
///
/// Fullscreen viewers use immersive presentation: content extends
/// behind the navigation bar, and bar items render as floating
/// Liquid Glass pills (the iOS 26 default when no custom
/// `UINavigationBarAppearance` is set).
///
/// The convention:
/// 1. Do NOT set a custom `UINavigationBarAppearance` on the content VC.
/// 2. Pin the body view's top to `view.topAnchor` (not `safeAreaLayoutGuide`).
/// 3. Do NOT set a `titleView` — only left/right bar button items.
///
/// Scroll views inside body views use `contentInsetAdjustmentBehavior = .automatic`
/// (the default) so content starts below the bar but scrolls behind it.
///
/// To revert to an opaque header:
/// 1. Set a `UINavigationBarAppearance` with `configureWithOpaqueBackground()`
/// 2. Pin content to `safeAreaLayoutGuide.topAnchor`
/// 3. Optionally restore `titleView`
///
/// Both ``FullScreenCodeViewController`` and ``FullScreenImageViewController``
/// follow this pattern.
enum FullScreenViewerChrome {
    // Marker enum — the convention is documented above.
    // Grep for `FullScreenViewerChrome` to find all adopters.
}

enum FullScreenCodeTypography {
    static let codeFont = AppFont.monoMedium

    static func codeFont(for preferences: FullScreenReaderPreferences) -> UIFont {
        scaledFont(codeFont, scale: preferences.textScale)
    }

    static func scaledFont(_ font: UIFont, scale: CGFloat) -> UIFont {
        guard scale != 1 else { return font }
        let pointSize = min(40, max(8, font.pointSize * scale))
        return font.withSize(pointSize)
    }
}

@MainActor
protocol FullScreenReaderConfigurable: AnyObject {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences)
}

func fullScreenAttributedCodeText(
    from attributed: NSAttributedString,
    font: UIFont = FullScreenCodeTypography.codeFont
) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: attributed)
    let fullRange = NSRange(location: 0, length: mutable.length)
    mutable.addAttribute(.font, value: font, range: fullRange)
    return mutable
}

/// UITextView variant that also contributes the review-comment action through
/// UIResponder menu building. Some readonly full-screen text views do not
/// reliably ask their delegate for `editMenuForTextIn` on newer iOS builds,
/// so the delegate path below remains the testable primary path while this
/// responder hook keeps the visible selection menu populated on-device.
final class FullScreenReviewCommentTextView: UITextView {
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    var reviewCommentSourceContext: ReviewCommentSourceContext?

    private weak var reviewCommentSelectionBar: FullScreenReviewCommentSelectionBar?
    private var pendingSelectionBarUpdate = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        reviewCommentSelectionBar?.removeFromSuperview()
    }

    override var selectedRange: NSRange {
        get { super.selectedRange }
        set {
            super.selectedRange = newValue
            scheduleSelectionBarUpdate()
        }
    }

    func reviewCommentSelectionDidChange() {
        scheduleSelectionBarUpdate()
    }

    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
        scheduleSelectionBarUpdate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            dismissReviewCommentSelectionBar()
        } else {
            scheduleSelectionBarUpdate()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleSelectionBarUpdate()
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard let action = reviewCommentMenuAction() else { return }
        let menu = UIMenu(title: "", options: .displayInline, children: [action])
        builder.insertSibling(menu, beforeMenu: .standardEdit)
    }

    private func scheduleSelectionBarUpdate() {
        guard !pendingSelectionBarUpdate else { return }
        pendingSelectionBarUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingSelectionBarUpdate = false
            updateReviewCommentSelectionBar()
        }
    }

    private func updateReviewCommentSelectionBar() {
        guard window != nil,
              let router = reviewCommentSelectionRouter,
              let sourceContext = reviewCommentSourceContext,
              let selectedText = ReviewCommentSelectionTextViewSupport.selectedText(in: self, range: selectedRange),
              let hostView = nearestViewController(from: self)?.view else {
            dismissReviewCommentSelectionBar()
            return
        }

        let range = selectedRange
        let enrichedSourceContext = ReviewCommentSelectionEditMenuSupport.enrichedSourceContext(
            sourceContext,
            textView: self,
            range: range
        )
        let request = ReviewCommentSelectionRequest(
            selectedText: selectedText,
            source: enrichedSourceContext
        )
        let anchorRect = selectionAnchorRect(for: range)
            ?? CGRect(x: bounds.midX, y: min(bounds.midY, bounds.minY + 180), width: 1, height: 1)
        let anchorInHost = convert(anchorRect, to: hostView)

        let bar: FullScreenReviewCommentSelectionBar
        if let existing = reviewCommentSelectionBar {
            bar = existing
        } else {
            let newBar = FullScreenReviewCommentSelectionBar()
            reviewCommentSelectionBar = newBar
            bar = newBar
        }

        if bar.superview !== hostView {
            bar.removeFromSuperview()
            hostView.addSubview(bar)
        }
        bar.onComment = { [weak self, weak router] in
            guard let self, let router else { return }
            self.handleReviewCommentSelectionBarTap(
                router: router,
                request: request,
                selectedRange: range
            )
        }
        bar.isHidden = false
        bar.alpha = 1
        bar.sizeToFit()
        bar.frame = selectionBarFrame(anchor: anchorInHost, hostView: hostView)
        hostView.bringSubviewToFront(bar)
    }

    private func handleReviewCommentSelectionBarTap(
        router: ReviewCommentSelectionRouter,
        request: ReviewCommentSelectionRequest,
        selectedRange: NSRange
    ) {
        dismissReviewCommentSelectionBar()
        if router.supportsInlineCommentComposer,
           request.source.surface.usesInlineCommentWidget {
            ReviewCommentInlineDraftPresenter.present(
                textView: self,
                selectedRange: selectedRange,
                request: request,
                router: router
            )
        } else {
            router.dispatch(request, presentingViewController: nearestViewController(from: self))
            let collapseLocation = max(0, min(selectedRange.location, textStorage.length))
            self.selectedRange = NSRange(location: collapseLocation, length: 0)
            resignFirstResponder()
        }
    }

    private func dismissReviewCommentSelectionBar() {
        reviewCommentSelectionBar?.removeFromSuperview()
        reviewCommentSelectionBar = nil
    }

    private func selectionBarFrame(anchor: CGRect, hostView: UIView) -> CGRect {
        let size = FullScreenReviewCommentSelectionBar.preferredSize
        let safeInsets = hostView.safeAreaInsets
        var safeFrame = hostView.bounds.inset(by: safeInsets).insetBy(dx: 12, dy: 12)
        if safeFrame.width <= 0 || safeFrame.height <= 0 {
            safeFrame = hostView.bounds.insetBy(dx: 12, dy: 12)
        }

        var x = anchor.midX - size.width / 2
        x = min(max(x, safeFrame.minX), safeFrame.maxX - size.width)
        if !x.isFinite { x = safeFrame.minX }

        let aboveY = anchor.minY - size.height - 8
        let belowY = anchor.maxY + 8
        var y = aboveY >= safeFrame.minY ? aboveY : belowY
        y = min(max(y, safeFrame.minY), safeFrame.maxY - size.height)
        if !y.isFinite { y = safeFrame.minY }

        return CGRect(origin: CGPoint(x: x, y: y), size: size).integral
    }

    private func selectionAnchorRect(for range: NSRange) -> CGRect? {
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textStorage.length else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return nil }

        var rect: CGRect?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, stop in
            rect = usedRect
            stop.pointee = true
        }

        guard var anchor = rect else { return nil }
        anchor.origin.x += textContainerInset.left
        anchor.origin.y += textContainerInset.top
        anchor = anchor.offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)
        return anchor.integral
    }

    private func reviewCommentMenuAction() -> UIAction? {
        guard let router = reviewCommentSelectionRouter,
              let sourceContext = reviewCommentSourceContext,
              let selectedText = ReviewCommentSelectionTextViewSupport.selectedText(in: self, range: selectedRange) else {
            return nil
        }

        return ReviewCommentSelectionMenuBuilder.commentAction(
            selectedText: selectedText,
            sourceContext: ReviewCommentSelectionEditMenuSupport.enrichedSourceContext(
                sourceContext,
                textView: self,
                range: selectedRange
            ),
            router: router,
            presentingViewController: nearestViewController(from: self),
            textView: self,
            selectedRange: selectedRange
        )
    }
}

private final class FullScreenReviewCommentSelectionBar: UIButton {
    static let preferredSize = CGSize(width: 148, height: 40)

    var onComment: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        Self.preferredSize
    }

    private func setup() {
        accessibilityIdentifier = "review-comment.selection-bar"
        accessibilityLabel = "Comment on selection"

        var config = UIButton.Configuration.filled()
        config.title = "Comment"
        config.image = UIImage(systemName: "text.bubble")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        config.imagePadding = 6
        config.baseForegroundColor = UIColor(ThemeRuntimeState.currentPalette().bgDark)
        config.baseBackgroundColor = UIColor(ThemeRuntimeState.currentPalette().cyan)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 16, weight: .semibold)
            return outgoing
        }
        configuration = config
        titleLabel?.adjustsFontForContentSizeCategory = false
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byTruncatingTail

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.24
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 8)

        addAction(UIAction { [weak self] _ in
            self?.onComment?()
        }, for: .touchUpInside)
    }
}

@MainActor
func buildFullScreenReviewCommentMenu(
    textView: UITextView,
    range: NSRange,
    suggestedActions: [UIMenuElement],
    router: ReviewCommentSelectionRouter?,
    sourceContext: ReviewCommentSourceContext?
) -> UIMenu? {
    ReviewCommentSelectionEditMenuSupport.buildMenu(
        textView: textView,
        range: range,
        suggestedActions: suggestedActions,
        router: router,
        sourceContext: sourceContext,
        presentingViewController: nearestViewController(from: textView)
    )
}

private func nearestViewController(from responder: UIResponder) -> UIViewController? {
    var current: UIResponder? = responder
    while let node = current {
        if let controller = node as? UIViewController {
            return controller
        }
        current = node.next
    }
    return nil
}

@MainActor
final class TailFollowScrollCoordinator {
    private let scrollView: UIScrollView
    private let nearBottomThreshold: CGFloat
    private let performLayout: () -> Void

    private(set) var isApplyingProgrammaticScroll = false
    var shouldAutoFollowTail: Bool
    private var pendingAutoFollowScroll = false

    init(
        scrollView: UIScrollView,
        shouldAutoFollowTail: Bool,
        nearBottomThreshold: CGFloat = 28,
        performLayout: @escaping () -> Void
    ) {
        self.scrollView = scrollView
        self.shouldAutoFollowTail = shouldAutoFollowTail
        self.nearBottomThreshold = nearBottomThreshold
        self.performLayout = performLayout
    }

    func onLayoutPass() {
        scheduleAutoFollowToBottomIfNeeded()
    }

    func scheduleAutoFollowToBottomIfNeeded() {
        guard shouldAutoFollowTail else { return }
        guard !pendingAutoFollowScroll else { return }
        pendingAutoFollowScroll = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingAutoFollowScroll = false
            self.scrollToBottomIfNeeded()
        }
    }

    func handleWillBeginDragging() {
        if !isNearBottom() {
            shouldAutoFollowTail = false
        }
    }

    func handleDidScroll(isUserDriven: Bool, isStreaming: Bool) {
        guard !isApplyingProgrammaticScroll else { return }
        guard isUserDriven else { return }

        if isNearBottom() {
            shouldAutoFollowTail = isStreaming
        } else {
            shouldAutoFollowTail = false
        }
    }

    func handleDidEndDragging(willDecelerate: Bool, isStreaming: Bool) {
        guard !willDecelerate else { return }
        if isNearBottom() {
            shouldAutoFollowTail = isStreaming
        }
    }

    func handleDidEndDecelerating(isStreaming: Bool) {
        if isNearBottom() {
            shouldAutoFollowTail = isStreaming
        }
    }

    private func scrollToBottomIfNeeded() {
        guard scrollView.bounds.height > 0 else { return }

        performLayout()

        let targetY = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        guard targetY.isFinite else { return }
        guard abs(scrollView.contentOffset.y - targetY) > 0.5 else { return }

        isApplyingProgrammaticScroll = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        CATransaction.commit()
        isApplyingProgrammaticScroll = false
    }

    private func isNearBottom() -> Bool {
        distanceFromBottom() <= nearBottomThreshold
    }

    private func distanceFromBottom() -> CGFloat {
        let viewportHeight = scrollView.bounds.height
            - scrollView.adjustedContentInset.top
            - scrollView.adjustedContentInset.bottom
        guard viewportHeight > 0 else { return .greatestFiniteMagnitude }

        let visibleBottom = scrollView.contentOffset.y
            + scrollView.adjustedContentInset.top
            + viewportHeight

        return scrollView.contentSize.height - visibleBottom
    }
}
