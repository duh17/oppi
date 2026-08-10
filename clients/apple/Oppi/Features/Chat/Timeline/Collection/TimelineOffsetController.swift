import UIKit

@MainActor
enum TimelineAnchorEdge: Equatable {
    case top
    case bottom
}

@MainActor
enum TimelineOffsetReason: Equatable {
    case bottomInsetGrowth
    case liveTailVisibility
    case idleBottomSettle
    case expandCollapse(edge: TimelineAnchorEdge)
    case programmaticTopAlign
    case navigationViewportRestore
    case detachedFallback
    case imagePreviewReturn
}

@MainActor
enum TimelineOffsetController {
    @discardableResult
    static func apply(
        targetOffsetY proposedOffsetY: CGFloat,
        reason: TimelineOffsetReason,
        collectionView: UICollectionView,
        scrollController: ChatScrollController?
    ) -> Bool {
        guard canApply(
            reason: reason,
            collectionView: collectionView,
            scrollController: scrollController
        ) else {
            return false
        }

        let targetOffsetY = clampedOffsetY(proposedOffsetY, in: collectionView)
        guard targetOffsetY.isFinite,
              abs(collectionView.contentOffset.y - targetOffsetY) > 0.5 else {
            return false
        }

        if let anchoredCV = collectionView as? AnchoredCollectionView {
            anchoredCV.applyOffsetCorrection(targetOffsetY)
        } else {
            collectionView.contentOffset.y = targetOffsetY
        }
        return true
    }

    static func clampedOffsetY(
        _ proposedOffsetY: CGFloat,
        in collectionView: UICollectionView
    ) -> CGFloat {
        let insets = collectionView.adjustedContentInset
        let minOffsetY = -insets.top
        let maxOffsetY = max(
            minOffsetY,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
        return min(max(proposedOffsetY, minOffsetY), maxOffsetY)
    }

    private static func canApply(
        reason: TimelineOffsetReason,
        collectionView: UICollectionView,
        scrollController: ChatScrollController?
    ) -> Bool {
        switch reason {
        case .bottomInsetGrowth, .liveTailVisibility, .idleBottomSettle:
            guard scrollController?.isCurrentlyNearBottom ?? true else { return false }
            guard !isUserInteracting(with: collectionView) else { return false }
            if #available(iOS 17.4, *), collectionView.isScrollAnimating {
                return false
            }
            return true

        case .expandCollapse, .programmaticTopAlign, .navigationViewportRestore:
            guard !isUserInteracting(with: collectionView) else { return false }
            return true

        case .detachedFallback:
            guard !(scrollController?.isCurrentlyNearBottom ?? true) else { return false }
            guard !isUserInteracting(with: collectionView) else { return false }
            return true

        case .imagePreviewReturn:
            // The image dismissal transition has completed before this reason is
            // issued. Refuse real touch interaction, but supersede any stale
            // programmatic scroll animation left by timeline re-entry.
            guard !isUserInteracting(with: collectionView) else { return false }
            return true
        }
    }

    private static func isUserInteracting(with collectionView: UICollectionView) -> Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }
}
