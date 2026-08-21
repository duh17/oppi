import UIKit

@MainActor
enum ToolTimelineRowPresentationHelpers {
#if DEBUG
    // periphery:ignore - test seam for distinguishing content updates from
    // outer timeline geometry invalidations.
    static var enclosingLayoutInvalidationHookForTesting: (() -> Void)?
    // periphery:ignore - test seam for SwiftUI-hosted markdown remeasure.
    static var swiftUIMarkdownRootInvalidationHookForTesting: ((AssistantMarkdownContentView) -> Void)?
#endif

    @MainActor
    private final class DetachedLayoutViewportAnchor {
        private weak var collectionView: UICollectionView?
        private weak var controller: ChatTimelineCollectionHost.Controller?
        private let itemID: String?
        private let indexPath: IndexPath
        private let relativeY: CGFloat

        init(
            collectionView: UICollectionView,
            controller: ChatTimelineCollectionHost.Controller?,
            itemID: String?,
            indexPath: IndexPath,
            relativeY: CGFloat
        ) {
            self.collectionView = collectionView
            self.controller = controller
            self.itemID = itemID
            self.indexPath = indexPath
            self.relativeY = relativeY
        }

        func restore() {
            guard let collectionView,
                  !ToolTimelineRowPresentationHelpers.isUserInteracting(with: collectionView) else {
                return
            }

            let resolvedIndexPath: IndexPath
            if let controller,
               let itemID,
               let index = controller.currentIDs.firstIndex(of: itemID) {
                resolvedIndexPath = IndexPath(item: index, section: 0)
            } else {
                resolvedIndexPath = indexPath
            }

            guard let attributes = collectionView.layoutAttributesForItem(at: resolvedIndexPath) else {
                return
            }
            _ = TimelineOffsetController.apply(
                targetOffsetY: attributes.frame.minY - relativeY,
                reason: .viewportPreservation,
                collectionView: collectionView,
                scrollController: controller?.scrollController
            )

            if let anchoredCollectionView = collectionView as? AnchoredCollectionView {
                anchoredCollectionView.isDetachedFromBottom = true
                anchoredCollectionView.captureDetachedAnchor()
            }
            controller?.updateScrollState(collectionView, preserveDetachedState: true)
        }
    }

    @MainActor
    private final class AttachedLayoutTail {
        private weak var collectionView: UICollectionView?
        private weak var controller: ChatTimelineCollectionHost.Controller?

        init(
            collectionView: UICollectionView,
            controller: ChatTimelineCollectionHost.Controller?
        ) {
            self.collectionView = collectionView
            self.controller = controller
        }

        func restore() {
            guard let collectionView,
                  !ToolTimelineRowPresentationHelpers.isUserInteracting(
                    with: collectionView,
                    scrollController: controller?.scrollController
                  ) else {
                return
            }

            let insets = collectionView.adjustedContentInset
            let targetOffsetY = max(
                -insets.top,
                collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
            )
            let didApply = TimelineOffsetController.apply(
                targetOffsetY: targetOffsetY,
                reason: .idleBottomSettle,
                collectionView: collectionView,
                scrollController: controller?.scrollController
            )
            guard didApply || abs(collectionView.contentOffset.y - targetOffsetY) <= 0.5 else {
                return
            }

            controller?.scrollController?.updateNearBottom(true)
            controller?.updateScrollState(collectionView)
        }
    }

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
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil,
        reviewCommentSessionId: String? = nil,
        reviewCommentSourceLabel: String? = nil
    ) {
        guard let presenter = nearestViewController(from: sourceView) else {
            return
        }
        guard !isWithinFullScreenModalContext(presenter) else {
            return
        }

        let controller = FullScreenCodeViewController(
            content: content,
            reviewCommentSelectionContext: reviewCommentSelectionContext
                ?? ReviewCommentSelectionContext(
                    router: reviewCommentSelectionRouter,
                    sessionId: reviewCommentSessionId,
                    sourceLabel: reviewCommentSourceLabel
                )
        )
        FullScreenViewerPresentationPolicy.configureLargePresentation(
            controller,
            traitCollection: sourceView.traitCollection
        )
        controller.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
        presenter.present(controller, animated: true)
    }

    static func presentFullScreenImage(_ image: UIImage, from sourceView: UIView) {
        guard let presenter = nearestViewController(from: sourceView) else { return }
        guard !isWithinFullScreenModalContext(presenter) else { return }

        let controller = FullScreenImageViewController.makeSlideDownController(
            image: image,
            prefersFullScreenOverlay: FullScreenViewerPresentationPolicy.prefersFullScreenOverlay(
                for: sourceView.traitCollection
            )
        )
        ImagePreviewPresentationCoordinator.present(controller, from: presenter)
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

    /// Clear any streaming self-sizing cache on the enclosing timeline cell.
    ///
    /// Assistant rows throttle `preferredLayoutAttributesFitting` during
    /// streaming by reusing the last measured height for a short window. When a
    /// markdown update suddenly adds a tall block (code fence, table, image,
    /// mermaid, etc.), that cached compact height must be busted before the
    /// next sizing pass or UIKit can keep the stale height long enough to clip
    /// the new content.
    static func invalidateEnclosingStreamingHeightCache(startingAt sourceView: UIView) {
        var view: UIView? = sourceView
        while let current = view {
            if let cell = current as? SafeSizingCell {
                cell.invalidateStreamingHeightCache()
                cell.setNeedsLayout()
                cell.contentView.setNeedsLayout()
                return
            }
            view = current.superview
        }
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
#if DEBUG
        Self.enclosingLayoutInvalidationHookForTesting?()
#endif
        invalidateEnclosingStreamingHeightCache(startingAt: sourceView)

        let target = enclosingLayoutTarget(startingAt: sourceView)
        if let collectionView = target.collectionView {
            if isUserInteracting(with: collectionView) {
                scheduleInvalidationWhenInteractionEnds(for: collectionView)
                return
            }

            scheduleCoalescedInvalidation(for: collectionView)
            return
        }

        invalidateSwiftUIHostedMarkdownIfNeeded(target.markdownRoot)
    }

    /// Force a self-sizing pass for controls that synchronously change their
    /// own height while the user is detached from the bottom. Detached anchors
    /// still preserve the viewport during `layoutSubviews`; this only bypasses
    /// the helper's normal skip for passive snapshot-driven updates.
    static func forceInvalidateEnclosingCollectionViewLayout(startingAt sourceView: UIView) {
        invalidateEnclosingStreamingHeightCache(startingAt: sourceView)

        let target = enclosingLayoutTarget(startingAt: sourceView)
        if let collectionView = target.collectionView {
            if isUserInteracting(with: collectionView) {
                scheduleForcedInvalidationWhenInteractionEnds(for: collectionView)
                return
            }

            invalidateCollectionViewLayout(
                collectionView,
                allowDetachedAnchorInvalidation: true,
                preservingViewportAround: sourceView
            )
            return
        }

        invalidateSwiftUIHostedMarkdownIfNeeded(target.markdownRoot)
    }

    /// Walk toward the window, remembering the outermost markdown root.
    /// Collection-view hosts keep the existing self-sizing path; SwiftUI
    /// representables have no `UICollectionView`, so the walk would otherwise
    /// no-op after async mermaid/LaTeX/image growth and freeze `sizeThatFits`.
    private static func enclosingLayoutTarget(
        startingAt sourceView: UIView
    ) -> (collectionView: UICollectionView?, markdownRoot: AssistantMarkdownContentView?) {
        var view: UIView? = sourceView.superview
        var markdownRoot: AssistantMarkdownContentView?
        while let current = view {
            if let markdown = current as? AssistantMarkdownContentView {
                markdownRoot = markdown
            }
            if let collectionView = current as? UICollectionView {
                return (collectionView, markdownRoot)
            }
            view = current.superview
        }
        return (nil, markdownRoot)
    }

    private static func invalidateSwiftUIHostedMarkdownIfNeeded(
        _ markdownRoot: AssistantMarkdownContentView?
    ) {
        guard let markdownRoot else { return }
#if DEBUG
        swiftUIMarkdownRootInvalidationHookForTesting?(markdownRoot)
#endif
        markdownRoot.invalidateIntrinsicContentSize()
        markdownRoot.setNeedsLayout()
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
    private static var pendingForcedInteractionInvalidations: Set<ObjectIdentifier> = []

#if DEBUG
    // periphery:ignore - deterministic pending-policy coverage in ToolExpandedSurfaceHostTests
    static func forcedInteractionInvalidationIsPendingForTesting(
        _ collectionView: UICollectionView
    ) -> Bool {
        pendingForcedInteractionInvalidations.contains(ObjectIdentifier(collectionView))
    }
#endif

    private static func scheduleInvalidationWhenInteractionEnds(for collectionView: UICollectionView) {
        let identifier = ObjectIdentifier(collectionView)
        guard pendingInteractionInvalidations.insert(identifier).inserted else {
            return
        }
        recheckOrdinaryInteractionAndInvalidateWhenIdle(
            collectionView: collectionView,
            identifier: identifier,
            retriesRemaining: 180
        )
    }

    private static func recheckOrdinaryInteractionAndInvalidateWhenIdle(
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
            recheckOrdinaryInteractionAndInvalidateWhenIdle(
                collectionView: collectionView,
                identifier: identifier,
                retriesRemaining: retriesRemaining - 1
            )
        }
    }

    private static func scheduleForcedInvalidationWhenInteractionEnds(
        for collectionView: UICollectionView
    ) {
        let identifier = ObjectIdentifier(collectionView)
        guard pendingForcedInteractionInvalidations.insert(identifier).inserted else {
            return
        }
        recheckForcedInteractionAndInvalidateWhenIdle(
            collectionView: collectionView,
            identifier: identifier,
            delayMilliseconds: 16
        )
    }

    private static func recheckForcedInteractionAndInvalidateWhenIdle(
        collectionView: UICollectionView,
        identifier: ObjectIdentifier,
        delayMilliseconds: Int
    ) {
        guard isUserInteracting(with: collectionView) else {
            pendingForcedInteractionInvalidations.remove(identifier)
            invalidateCollectionViewLayout(
                collectionView,
                allowDetachedAnchorInvalidation: true,
                preserveCurrentViewport: true
            )
            return
        }

        // Forced media settlement remains pending for the full interaction,
        // but backs off to four checks per second so a long hold or
        // deceleration does not create hot unbounded main-queue work.
        let nextDelayMilliseconds = min(250, delayMilliseconds * 2)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(delayMilliseconds)
        ) { [weak collectionView] in
            guard let collectionView else {
                pendingForcedInteractionInvalidations.remove(identifier)
                return
            }
            recheckForcedInteractionAndInvalidateWhenIdle(
                collectionView: collectionView,
                identifier: identifier,
                delayMilliseconds: nextDelayMilliseconds
            )
        }
    }

    private static func isUserInteracting(
        with collectionView: UICollectionView,
        scrollController: ChatScrollController? = nil
    ) -> Bool {
        let resolvedScrollController = scrollController
            ?? (collectionView.delegate as? ChatTimelineCollectionHost.Controller)?.scrollController
        return resolvedScrollController?.isUserInteracting == true
            || collectionView.isTracking
            || collectionView.isDragging
            || collectionView.isDecelerating
    }

    private static func invalidateCollectionViewLayout(
        _ collectionView: UICollectionView,
        allowDetachedAnchorInvalidation: Bool = false,
        preservingViewportAround sourceView: UIView? = nil,
        preserveCurrentViewport: Bool = false
    ) {
        // Passive snapshot updates skip full invalidation while an anchor is
        // active because the snapshot path already measured the changed cell.
        // A full layout invalidation clears cached off-screen heights and can
        // produce visible drift while UICollectionView re-measures cells.
        // Explicit local controls, such as code wrapping, can opt into a
        // detached-anchor invalidation because AnchoredCollectionView preserves
        // the viewport during layoutSubviews.
        if let anchoredCV = collectionView as? AnchoredCollectionView {
            if anchoredCV.expandCollapseAnchorIP != nil {
                return
            }
            if !allowDetachedAnchorInvalidation,
               anchoredCV.isDetachedFromBottom && anchoredCV.detachedAnchorIsActive {
                return
            }
        }

        let shouldPreserveViewport = preserveCurrentViewport || sourceView != nil
        let viewportAnchor = shouldPreserveViewport
            ? captureDetachedLayoutViewportAnchor(in: collectionView, excluding: sourceView)
            : nil
        let attachedTail = shouldPreserveViewport
            ? captureAttachedLayoutTail(in: collectionView)
            : nil
        UIView.performWithoutAnimation {
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if let viewportAnchor {
                viewportAnchor.restore()
            } else {
                attachedTail?.restore()
            }
        }
    }

    private static func captureAttachedLayoutTail(
        in collectionView: UICollectionView
    ) -> AttachedLayoutTail? {
        guard collectionView.window != nil else { return nil }
        let controller = collectionView.delegate as? ChatTimelineCollectionHost.Controller
        let isAttached = controller?.scrollController?.isCurrentlyNearBottom
            ?? !((collectionView as? AnchoredCollectionView)?.isDetachedFromBottom ?? false)
        guard isAttached,
              !isUserInteracting(
                with: collectionView,
                scrollController: controller?.scrollController
              ) else {
            return nil
        }
        return AttachedLayoutTail(collectionView: collectionView, controller: controller)
    }

    private static func captureDetachedLayoutViewportAnchor(
        in collectionView: UICollectionView,
        excluding sourceView: UIView?
    ) -> DetachedLayoutViewportAnchor? {
        let controller = collectionView.delegate as? ChatTimelineCollectionHost.Controller
        let isDetached: Bool
        if let scrollController = controller?.scrollController {
            isDetached = !scrollController.isCurrentlyNearBottom
        } else {
            isDetached = (collectionView as? AnchoredCollectionView)?.isDetachedFromBottom ?? false
        }
        guard isDetached,
              !isUserInteracting(
                with: collectionView,
                scrollController: controller?.scrollController
              ) else {
            return nil
        }

        var sourceAncestor: UIView? = sourceView
        var sourceCell: UICollectionViewCell?
        while let current = sourceAncestor, current !== collectionView {
            if let cell = current as? UICollectionViewCell {
                sourceCell = cell
                break
            }
            sourceAncestor = current.superview
        }
        let sourceIndexPath = sourceCell.flatMap { collectionView.indexPath(for: $0) }
        let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        let candidates = collectionView.indexPathsForVisibleItems.compactMap {
            indexPath -> (IndexPath, UICollectionViewLayoutAttributes)? in
            guard indexPath != sourceIndexPath,
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                  attributes.frame.intersects(visibleRect) else {
                return nil
            }
            return (indexPath, attributes)
        }.sorted { $0.1.frame.minY < $1.1.frame.minY }

        let selected: (IndexPath, UICollectionViewLayoutAttributes)?
        if let sourceIndexPath {
            selected = candidates.first { $0.0.item > sourceIndexPath.item }
                ?? candidates.last { $0.0.item < sourceIndexPath.item }
        } else {
            selected = candidates.first
        }
        guard let selected else { return nil }

        let itemID = controller.flatMap { controller in
            selected.0.item < controller.currentIDs.count
                ? controller.currentIDs[selected.0.item]
                : nil
        }
        return DetachedLayoutViewportAnchor(
            collectionView: collectionView,
            controller: controller,
            itemID: itemID,
            indexPath: selected.0,
            relativeY: selected.1.frame.minY - collectionView.contentOffset.y
        )
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
        if normalized == "image" {
            return UIImage(systemName: "photo.fill")
        }
        if normalized == "audio" {
            return UIImage(systemName: "waveform")
        }
        if normalized == "video" {
            return UIImage(systemName: "video.fill")
        }

        return UIImage(systemName: genericLanguageBadgeSymbolName)
    }
}
