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

enum CodeWrapControl {
    static let symbolName = "text.alignleft"
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

private final class FullScreenTextSelectionHighlightOverlayView: UIView {
    var rects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    var fillColor: UIColor = .systemBlue.withAlphaComponent(0.22) {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !rects.isEmpty else { return }
        context.setFillColor(fillColor.cgColor)
        for selectionRect in rects where selectionRect.intersects(rect) {
            let path = UIBezierPath(roundedRect: selectionRect, cornerRadius: 3)
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }
}

/// UITextView variant that carries review-comment routing context.
///
/// The owning `UITextViewDelegate` builds the menu when UIKit asks for it.
/// Some read-only full-screen selections never get that callback, so this view
/// also owns a fallback `UIEditMenuInteraction`; the fallback stands down when
/// the native delegate has already built the menu for the current selection.
final class FullScreenReviewCommentTextView: UITextView {
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    var reviewCommentSourceContext: ReviewCommentSourceContext?

    private let selectionHighlightOverlay = FullScreenTextSelectionHighlightOverlayView()
    private lazy var reviewCommentEditMenuInteraction = UIEditMenuInteraction(delegate: self)
    private var pendingEditMenuPresentation = false
    private var currentEditMenuTargetRect: CGRect?
    private var observedSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var selectionGeneration = 0
    private var nativeTextViewEditMenuGeneration: Int?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addInteraction(reviewCommentEditMenuInteraction)
        installSelectionHighlightOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var selectedRange: NSRange {
        get { super.selectedRange }
        set {
            super.selectedRange = newValue
            noteSelectionRangeDidMaybeChange()
            updateSelectionHighlightOverlay()
            scheduleReviewCommentEditMenuPresentation()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSelectionHighlightOverlay()
    }

    func reviewCommentSelectionDidChange() {
        noteSelectionRangeDidMaybeChange()
        updateSelectionHighlightOverlay()
        scheduleReviewCommentEditMenuPresentation()
    }

    func noteNativeTextViewEditMenuRequest(for range: NSRange) {
        noteSelectionRangeDidMaybeChange()
        guard NSEqualRanges(range, selectedRange) else { return }
        nativeTextViewEditMenuGeneration = selectionGeneration
    }

    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
        scheduleReviewCommentEditMenuPresentation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            reviewCommentEditMenuInteraction.dismissMenu()
        } else {
            scheduleReviewCommentEditMenuPresentation()
        }
    }

    func setAttributedTextPreservingSelection(_ attributedText: NSAttributedString) {
        let selection = selectedRange
        let shouldRestoreSelection = selection.location != NSNotFound
            && selection.length > 0
            && NSMaxRange(selection) <= attributedText.length
        let wasFirstResponder = isFirstResponder

        self.attributedText = attributedText

        if shouldRestoreSelection {
            selectedRange = selection
            if wasFirstResponder {
                becomeFirstResponder()
            }
        }
        updateSelectionHighlightOverlay()
    }

    private func installSelectionHighlightOverlay() {
        selectionHighlightOverlay.isUserInteractionEnabled = false
        selectionHighlightOverlay.backgroundColor = .clear
        selectionHighlightOverlay.isOpaque = false
        addSubview(selectionHighlightOverlay)
    }

    private func updateSelectionHighlightOverlay() {
        bringSubviewToFront(selectionHighlightOverlay)
        selectionHighlightOverlay.frame = bounds
        selectionHighlightOverlay.fillColor = tintColor.withAlphaComponent(0.30)
        selectionHighlightOverlay.rects = selectionHighlightRects(for: selectedRange)
    }

    private func selectionHighlightRects(for range: NSRange) -> [CGRect] {
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textStorage.length else {
            return []
        }

        layoutManager.ensureLayout(for: textContainer)
        let selectedGlyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard selectedGlyphRange.location != NSNotFound, selectedGlyphRange.length > 0 else { return [] }

        var rects: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: selectedGlyphRange) { _, _, _, lineGlyphRange, _ in
            let glyphRange = NSIntersectionRange(selectedGlyphRange, lineGlyphRange)
            guard glyphRange.length > 0 else { return }
            var rect = self.layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textContainer)
            rect.origin.x += self.textContainerInset.left - self.contentOffset.x - 2
            rect.origin.y += self.textContainerInset.top - self.contentOffset.y
            rect.size.width += 4
            rect.size.height = max(rect.height, self.font?.lineHeight ?? rect.height)
            rects.append(rect.integral)
        }
        return rects
    }

    private func noteSelectionRangeDidMaybeChange() {
        let range = selectedRange
        guard !NSEqualRanges(range, observedSelectedRange) else { return }
        observedSelectedRange = range
        selectionGeneration &+= 1
        nativeTextViewEditMenuGeneration = nil
    }

    private func scheduleReviewCommentEditMenuPresentation() {
        guard !pendingEditMenuPresentation else { return }
        pendingEditMenuPresentation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            pendingEditMenuPresentation = false
            presentReviewCommentEditMenuIfNeeded()
        }
    }

    private func presentReviewCommentEditMenuIfNeeded() {
        noteSelectionRangeDidMaybeChange()
        guard nativeTextViewEditMenuGeneration != selectionGeneration else { return }
        guard window != nil,
              reviewCommentSelectionRouter != nil,
              reviewCommentSourceContext != nil,
              ReviewCommentSelectionTextViewSupport.selectedText(in: self, range: selectedRange) != nil else {
            currentEditMenuTargetRect = nil
            reviewCommentEditMenuInteraction.dismissMenu()
            return
        }

        if !isFirstResponder {
            becomeFirstResponder()
        }

        let targetRect = selectionAnchorRect(for: selectedRange)
            ?? CGRect(x: bounds.midX, y: min(bounds.midY, bounds.minY + 180), width: 1, height: 1)
        currentEditMenuTargetRect = targetRect.integral
        reviewCommentEditMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: "review-comment-selection" as NSString,
            sourcePoint: CGPoint(x: targetRect.midX, y: targetRect.minY)
        ))
    }

#if DEBUG
    func shouldPresentFallbackEditMenuForTesting() -> Bool {
        noteSelectionRangeDidMaybeChange()
        return nativeTextViewEditMenuGeneration != selectionGeneration
    }
#endif

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
}

extension FullScreenReviewCommentTextView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let router = reviewCommentSelectionRouter,
              let sourceContext = reviewCommentSourceContext,
              let selectedText = ReviewCommentSelectionTextViewSupport.selectedText(in: self, range: selectedRange) else {
            return nil
        }

        return ReviewCommentSelectionMenuBuilder.editMenu(
            suggestedActions: suggestedActions,
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

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        currentEditMenuTargetRect ?? .null
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
    let menu = ReviewCommentSelectionEditMenuSupport.buildMenu(
        textView: textView,
        range: range,
        suggestedActions: suggestedActions,
        router: router,
        sourceContext: sourceContext,
        presentingViewController: nearestViewController(from: textView)
    )
    if menu != nil {
        (textView as? FullScreenReviewCommentTextView)?.noteNativeTextViewEditMenuRequest(for: range)
    }
    return menu
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
