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

    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard let action = reviewCommentMenuAction() else { return }
        let menu = UIMenu(title: "", options: .displayInline, children: [action])
        builder.insertSibling(menu, beforeMenu: .standardEdit)
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
