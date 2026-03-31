import UIKit

@MainActor
enum ToolTimelineRowPresentationHelpers {
    static func animateInPlaceReveal(_ view: UIView, shouldAnimate: Bool) {
        guard shouldAnimate else {
            resetRevealAppearance(view)
            return
        }

        view.layer.removeAnimation(forKey: "tool.reveal")
        // Keep reveal almost imperceptible: tiny in-place opacity settle only.
        view.alpha = 0.97

        UIView.animate(
            withDuration: ToolRowExpansionAnimation.contentRevealDuration,
            delay: ToolRowExpansionAnimation.contentRevealDelay,
            options: [.allowUserInteraction, .curveLinear, .beginFromCurrentState]
        ) {
            // Pure in-place fade (no transform/translation), so panels feel
            // like they open within the row rather than slide in.
            view.alpha = 1
        }
    }

    static func resetRevealAppearance(_ view: UIView) {
        view.layer.removeAnimation(forKey: "tool.reveal")
        view.alpha = 1
    }

    static func presentFullScreenContent(
        _ content: FullScreenCodeContent,
        from sourceView: UIView,
        selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
        selectedTextSessionId: String? = nil,
        selectedTextSourceLabel: String? = nil
    ) {
        guard let presenter = nearestViewController(from: sourceView) else {
            return
        }
        guard !isWithinFullScreenModalContext(presenter) else {
            return
        }

        let controller = FullScreenCodeViewController(
            content: content,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSessionId: selectedTextSessionId,
            selectedTextSourceLabel: selectedTextSourceLabel
        )
        // .pageSheet keeps the presenting VC in the window hierarchy (unlike
        // .fullScreen which removes it, triggering SwiftUI onDisappear).
        // On iPhone, .pageSheet at .large() detent is visually full-screen
        // and gives free interactive swipe-to-dismiss.
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        controller.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
        presenter.present(controller, animated: true)
    }

    static func presentFullScreenImage(_ image: UIImage, from sourceView: UIView) {
        guard let presenter = nearestViewController(from: sourceView) else { return }
        guard !isWithinFullScreenModalContext(presenter) else { return }

        let controller = FullScreenImageViewController.makeSlideDownController(image: image)
        presenter.present(controller, animated: true)
    }

    static func nearestViewController(from sourceView: UIView) -> UIViewController? {
        var responder: UIResponder? = sourceView
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    private static func isWithinFullScreenModalContext(_ presenter: UIViewController) -> Bool {
        var current: UIViewController? = presenter
        while let node = current {
            if node is FullScreenCodeViewController
                || node is FullScreenImageViewController {
                return true
            }
            current = node.parent
        }

        var ancestor: UIViewController? = presenter.presentingViewController
        while let node = ancestor {
            if node is FullScreenCodeViewController
                || node is FullScreenImageViewController {
                return true
            }
            ancestor = node.presentingViewController
        }

        if let presented = presenter.presentedViewController {
            if presented is FullScreenCodeViewController
                || presented is FullScreenImageViewController {
                return true
            }
            if let nav = presented as? UINavigationController,
               nav.viewControllers.contains(where: {
                   $0 is FullScreenCodeViewController
                       || $0 is FullScreenImageViewController
                       || $0 is FullScreenImageViewController
               }) {
                return true
            }
        }

        return false
    }

    /// Walk up the view hierarchy to find the enclosing UICollectionView and
    /// invalidate its layout so self-sizing cells get re-measured.
    ///
    /// Multiple calls targeting the same collection view within a single
    /// runloop tick are coalesced into one `invalidateLayout + layoutIfNeeded`
    /// pass.  This avoids redundant full-layout cascades when several async
    /// blocks (e.g. from `installExpandedEmbeddedView` and the end-of-`apply`
    /// expanding-transition path) land in the same dispatch drain.
    static func invalidateEnclosingCollectionViewLayout(startingAt sourceView: UIView) {
        var view: UIView? = sourceView.superview
        while let current = view {
            guard let collectionView = current as? UICollectionView else {
                view = current.superview
                continue
            }

            if isUserInteracting(with: collectionView) {
                scheduleInvalidationWhenInteractionEnds(for: collectionView)
                return
            }

            scheduleCoalescedInvalidation(for: collectionView)
            return
        }
    }

    // MARK: - Coalesced invalidation

    /// Collection views that already have a coalesced invalidation pending.
    /// Cleared after the async block fires.
    private static var pendingCoalescedInvalidations: Set<ObjectIdentifier> = []

    private static func scheduleCoalescedInvalidation(for collectionView: UICollectionView) {
        let identifier = ObjectIdentifier(collectionView)
        guard pendingCoalescedInvalidations.insert(identifier).inserted else {
            // Already scheduled — this call will be covered by the pending pass.
            return
        }
        DispatchQueue.main.async { [weak collectionView] in
            pendingCoalescedInvalidations.remove(identifier)
            guard let collectionView else { return }
            invalidateCollectionViewLayout(collectionView)
        }
    }

    // MARK: - Interaction-deferred invalidation

    private static var pendingInteractionInvalidations: Set<ObjectIdentifier> = []

    private static func scheduleInvalidationWhenInteractionEnds(for collectionView: UICollectionView) {
        let identifier = ObjectIdentifier(collectionView)
        guard pendingInteractionInvalidations.insert(identifier).inserted else {
            return
        }
        recheckInteractionAndInvalidateWhenIdle(
            collectionView: collectionView,
            identifier: identifier,
            retriesRemaining: 180
        )
    }

    private static func recheckInteractionAndInvalidateWhenIdle(
        collectionView: UICollectionView,
        identifier: ObjectIdentifier,
        retriesRemaining: Int
    ) {
        guard retriesRemaining > 0 else {
            pendingInteractionInvalidations.remove(identifier)
            return
        }

        guard isUserInteracting(with: collectionView) else {
            pendingInteractionInvalidations.remove(identifier)
            invalidateCollectionViewLayout(collectionView)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak collectionView] in
            guard let collectionView else {
                pendingInteractionInvalidations.remove(identifier)
                return
            }
            recheckInteractionAndInvalidateWhenIdle(
                collectionView: collectionView,
                identifier: identifier,
                retriesRemaining: retriesRemaining - 1
            )
        }
    }

    private static func isUserInteracting(with collectionView: UICollectionView) -> Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }

    private static func invalidateCollectionViewLayout(_ collectionView: UICollectionView) {
        // When an expand/collapse anchor is active, skip the full
        // invalidateLayout(). The snapshot reconfigure + layoutIfNeeded
        // already measured the cell at its correct size. A full
        // invalidateLayout() clears ALL cached cell heights, reverting
        // off-screen cells to .estimated(44pt). This triggers a self-sizing
        // cascade where UIKit re-measures cells one per frame, adjusting
        // contentOffset by ~6pt each time — creating visible drift that
        // the AnchoredCollectionView cannot fully intercept because UIKit
        // applies some offset changes AFTER layoutSubviews() returns.
        // Skip full invalidateLayout() when an anchor is active. The
        // snapshot reconfigure + layoutIfNeeded already measured cells at
        // their correct sizes. A full invalidateLayout() clears ALL cached
        // cell heights, reverting off-screen cells to .estimated(100pt)
        // defaults. This triggers a self-sizing cascade where UIKit
        // re-measures cells one per frame, adjusting contentOffset by
        // ~6pt each time — creating visible drift.
        if let anchoredCV = collectionView as? AnchoredCollectionView,
           anchoredCV.expandCollapseAnchorIP != nil
            || (anchoredCV.isDetachedFromBottom && anchoredCV.detachedAnchorIsActive) {
            return
        }

        UIView.performWithoutAnimation {
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
    }
}

// MARK: - UI Helpers

@MainActor
enum ToolTimelineRowUIHelpers {
    private static let autoFollowBottomThreshold: CGFloat = 18
    private static let genericLanguageBadgeSymbolName = "chevron.left.forwardslash.chevron.right"

    static func clampScrollOffsetIfNeeded(_ scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        let viewportWidth = max(0, scrollView.bounds.width - inset.left - inset.right)
        let viewportHeight = max(0, scrollView.bounds.height - inset.top - inset.bottom)

        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, scrollView.contentSize.width - viewportWidth + inset.right)
        let maxY = max(minY, scrollView.contentSize.height - viewportHeight + inset.bottom)

        var clamped = scrollView.contentOffset
        clamped.x = min(max(clamped.x, minX), maxX)
        clamped.y = min(max(clamped.y, minY), maxY)

        guard abs(clamped.x - scrollView.contentOffset.x) > 0.5
                || abs(clamped.y - scrollView.contentOffset.y) > 0.5 else {
            return
        }

        scrollView.setContentOffset(clamped, animated: false)
    }

    static func resetScrollPosition(_ scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        scrollView.setContentOffset(
            CGPoint(x: -inset.left, y: -inset.top),
            animated: false
        )
    }

    static func scrollToBottom(_ scrollView: UIScrollView, animated: Bool) {
        let inset = scrollView.adjustedContentInset
        let viewportHeight = scrollView.bounds.height - inset.top - inset.bottom
        guard viewportHeight > 0 else { return }

        let bottomY = max(
            -inset.top,
            scrollView.contentSize.height - viewportHeight + inset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: -inset.left, y: bottomY),
            animated: animated
        )
    }

    /// Settle content size and scroll to bottom in one synchronous step.
    ///
    /// Call from `apply()` after setting text — never from `layoutSubviews()`.
    /// UITextView doesn't always propagate intrinsic-size invalidation through
    /// the content layout guide on the same run-loop pass as `.text=`, so we
    /// explicitly invalidate, force layout, then scroll.
    static func followTail(
        in scrollView: UIScrollView,
        contentLabel: UIView
    ) {
        contentLabel.invalidateIntrinsicContentSize()
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        scrollToBottom(scrollView, animated: false)
    }

    /// Pure computation of auto-follow state after a render pass.
    ///
    /// Used by strategies that return `ExpandedRenderOutput` — they call this
    /// to determine the new auto-follow flag without side effects.
    ///
    /// Rules:
    /// - First render while streaming: enable
    /// - Streaming continuation: preserve current state (user scroll respected)
    /// - Cell reuse during streaming (non-continuation rerender): re-enable
    /// - Done: disable
    static func computeAutoFollow(
        isStreaming: Bool,
        shouldRerender: Bool,
        wasExpandedVisible: Bool,
        previousRenderedText: String?,
        currentDisplayText: String,
        currentAutoFollow: Bool
    ) -> Bool {
        let isStreamingContinuation = previousRenderedText.map {
            !$0.isEmpty && currentDisplayText.hasPrefix($0)
        } ?? false

        if isStreaming {
            if !wasExpandedVisible || previousRenderedText == nil {
                return true
            } else if !isStreamingContinuation, shouldRerender {
                return true
            }
            return currentAutoFollow
        } else {
            return false
        }
    }

    static func isNearBottom(_ scrollView: UIScrollView) -> Bool {
        let inset = scrollView.adjustedContentInset
        let viewportHeight = scrollView.bounds.height - inset.top - inset.bottom
        guard viewportHeight > 0 else { return true }

        let bottomY = scrollView.contentOffset.y + inset.top + viewportHeight
        let distance = max(0, scrollView.contentSize.height - bottomY)
        return distance <= autoFollowBottomThreshold
    }

    static func toolSymbolName(for toolNamePrefix: String?) -> String? {
        guard let toolNamePrefix else { return nil }
        return ToolCallFormatting.sfSymbolName(for: toolNamePrefix)
    }

    /// Resolve a language badge string to either an asset catalog image or an SF Symbol.
    ///
    /// Prefers custom language icons from the asset catalog (`lang-*`),
    /// falls back to SF Symbols for languages without a custom icon.
    static func languageBadgeImage(for badge: String?) -> UIImage? {
        guard let badge, !badge.isEmpty else {
            return nil
        }

        let normalized = badge.lowercased()
        if normalized.contains("⚠︎media") || normalized.contains("media") {
            return UIImage(systemName: "exclamationmark.triangle")
        }

        // Check for a custom asset catalog icon first (lang-javascript, lang-python, etc.)
        let assetMap: [String: String] = [
            "javascript": "lang-nodejs",
            "typescript": "lang-typescript",
            "python": "lang-python",
            "ruby": "lang-ruby",
            "go": "lang-go",
            "rust": "lang-rust",
            "swift": "lang-swift",
            "zig": "lang-zig",
            "markdown": "lang-markdown",
        ]
        if let assetName = assetMap[normalized],
           let image = UIImage(named: assetName) {
            return image
        }

        // SF Symbol fallbacks
        if normalized == "swift", let img = UIImage(systemName: "swift") {
            return img
        }
        if normalized == "sql" {
            return UIImage(systemName: "cylinder")
        }

        return UIImage(systemName: genericLanguageBadgeSymbolName)
    }
}
