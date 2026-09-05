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
    case viewportPreservation
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

        case .viewportPreservation:
            // Modal and async-media viewport restorations are immediate ambient
            // corrections. Never apply them through real touch interaction.
            guard !isUserInteracting(with: collectionView) else { return false }
            return true
        }
    }

    private static func isUserInteracting(with collectionView: UICollectionView) -> Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }
}
