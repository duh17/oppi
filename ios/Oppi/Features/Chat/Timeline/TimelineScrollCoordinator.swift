import UIKit

@MainActor
enum TimelineScrollCoordinator {
    static func performScroll(
        _ command: ChatTimelineScrollCommand,
        in collectionView: UICollectionView,
        currentIDs: [String],
        afterNonAnimatedScroll: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let index = currentIDs.firstIndex(of: command.id) else { return false }
        let indexPath = IndexPath(item: index, section: 0)

        let position: UICollectionView.ScrollPosition
        switch command.anchor {
        case .top:
            position = .top
        case .bottom:
            position = .bottom
        }

        ChatTimelinePerf.recordScrollCommand(anchor: command.anchor, animated: command.animated)

        if command.animated {
            collectionView.scrollToItem(at: indexPath, at: position, animated: true)
        } else {
            collectionView.scrollToItem(at: indexPath, at: position, animated: false)
        }

        if !command.animated {
            DispatchQueue.main.async {
                afterNonAnimatedScroll()
            }
        }

        return true
    }

    static func updateDetachedStreamingHintVisibility(
        scrollController: ChatScrollController?,
        streamingAssistantID: String?,
        distanceFromBottom: CGFloat,
        jumpToBottomMinDistance: CGFloat
    ) {
        guard let scrollController else { return }

        let isDetached = !scrollController.isCurrentlyNearBottom
        let isFarFromBottom = isDetached && distanceFromBottom > jumpToBottomMinDistance

        let showsStreamingState = streamingAssistantID != nil && isDetached

        scrollController.setDetachedStreamingHintVisible(showsStreamingState && isFarFromBottom)
        scrollController.setJumpToBottomHintVisible(isFarFromBottom)
    }

    static func updateScrollState(
        collectionView: UICollectionView,
        scrollController: ChatScrollController?,
        currentIDs: [String],
        nearBottomEnterThreshold: CGFloat,
        nearBottomExitThreshold: CGFloat
    ) -> CGFloat? {
        guard let scrollController else { return nil }

        let insets = collectionView.adjustedContentInset
        scrollController.updateContentOffsetY(collectionView.contentOffset.y + insets.top)

        let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
        guard visibleHeight > 0 else { return nil }

        let bottomY = collectionView.contentOffset.y + insets.top + visibleHeight
        let contentHeight = collectionView.contentSize.height
        let distanceFromBottom = max(0, contentHeight - bottomY)
        let nearBottomThreshold = scrollController.isCurrentlyNearBottom
            ? nearBottomExitThreshold
            : nearBottomEnterThreshold
        scrollController.updateNearBottom(distanceFromBottom <= nearBottomThreshold)

        let firstVisible = collectionView.indexPathsForVisibleItems
            .min { lhs, rhs in lhs.item < rhs.item }

        guard let firstVisible else {
            scrollController.updateTopVisibleItemId(nil)
            return distanceFromBottom
        }

        guard firstVisible.item < currentIDs.count else {
            scrollController.updateTopVisibleItemId(nil)
            return distanceFromBottom
        }

        let id = currentIDs[firstVisible.item]
        if id == ChatTimelineCollectionHost.loadMoreID || id == ChatTimelineCollectionHost.workingIndicatorID {
            scrollController.updateTopVisibleItemId(nil)
        } else {
            scrollController.updateTopVisibleItemId(id)
        }

        return distanceFromBottom
    }
}
