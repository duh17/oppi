import UIKit

@MainActor
enum TimelineScrollCoordinator {
    /// One-shot reading anchor captured before a modal image preview covers chat.
    /// Stable item identity makes restoration resilient to row remeasurement and
    /// timeline growth while the preview is open.
    @MainActor
    final class ImagePreviewViewportRestoration {
        private weak var collectionView: UICollectionView?
        private weak var controller: ChatTimelineCollectionHost.Controller?
        private weak var scrollController: ChatScrollController?
        private let sessionId: String
        private let itemID: String?
        private let viewportRelativeY: CGFloat?
        private let wasAttachedToTail: Bool
        private var didRestore = false

        fileprivate init(
            collectionView: UICollectionView,
            controller: ChatTimelineCollectionHost.Controller,
            scrollController: ChatScrollController,
            sessionId: String,
            itemID: String?,
            viewportRelativeY: CGFloat?,
            wasAttachedToTail: Bool
        ) {
            self.collectionView = collectionView
            self.controller = controller
            self.scrollController = scrollController
            self.sessionId = sessionId
            self.itemID = itemID
            self.viewportRelativeY = viewportRelativeY
            self.wasAttachedToTail = wasAttachedToTail
        }

        func restore() {
            guard !didRestore else { return }
            didRestore = true

            guard let collectionView,
                  let controller,
                  let scrollController,
                  controller.collectionView === collectionView,
                  controller.sessionId == sessionId,
                  collectionView.window != nil else {
                return
            }

            collectionView.layoutIfNeeded()

            if wasAttachedToTail {
                if let tailID = controller.currentIDs.last {
                    _ = TimelineScrollCoordinator.performScroll(
                        ChatTimelineScrollCommand(
                            id: tailID,
                            anchor: .bottom,
                            animated: false,
                            nonce: 0
                        ),
                        in: collectionView,
                        currentIDs: controller.currentIDs,
                        sessionId: sessionId
                    ) { [weak self, weak collectionView, weak controller, weak scrollController] in
                        guard let self, let collectionView, let controller, let scrollController else { return }
                        self.restoreAttachedTail(
                            collectionView: collectionView,
                            controller: controller,
                            scrollController: scrollController,
                            deferredPasses: 0
                        )
                    }
                }
                restoreAttachedTail(
                    collectionView: collectionView,
                    controller: controller,
                    scrollController: scrollController,
                    deferredPasses: 2
                )
                return
            }

            guard let itemID,
                  let viewportRelativeY,
                  let itemIndex = controller.currentIDs.firstIndex(of: itemID),
                  let attributes = collectionView.layoutAttributesForItem(
                    at: IndexPath(item: itemIndex, section: 0)
                  ) else {
                return
            }

            // Re-entry can temporarily mark the timeline attached. Restore the
            // captured user intent before the sole outer-offset writer runs.
            scrollController.detachFromBottomForUserScroll()
            _ = TimelineOffsetController.apply(
                targetOffsetY: attributes.frame.minY - viewportRelativeY,
                reason: .imagePreviewReturn,
                collectionView: collectionView,
                scrollController: scrollController
            )

            if let anchoredCollectionView = collectionView as? AnchoredCollectionView {
                anchoredCollectionView.isDetachedFromBottom = true
                anchoredCollectionView.captureDetachedAnchor()
            }
            controller.updateScrollState(collectionView)
            scrollController.detachFromBottomForUserScroll()
        }

        private func restoreAttachedTail(
            collectionView: UICollectionView,
            controller: ChatTimelineCollectionHost.Controller,
            scrollController: ChatScrollController,
            deferredPasses: Int
        ) {
            guard controller.collectionView === collectionView,
                  controller.sessionId == sessionId,
                  collectionView.window != nil else {
                return
            }

            collectionView.layoutIfNeeded()
            scrollController.updateNearBottom(true)
            let insets = collectionView.adjustedContentInset
            _ = TimelineOffsetController.apply(
                targetOffsetY: max(
                    -insets.top,
                    collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
                ),
                reason: .imagePreviewReturn,
                collectionView: collectionView,
                scrollController: scrollController
            )
            controller.updateScrollState(collectionView)

            guard deferredPasses > 0 else { return }
            DispatchQueue.main.async { [weak self, weak collectionView, weak controller, weak scrollController] in
                guard let self, let collectionView, let controller, let scrollController else { return }
                self.restoreAttachedTail(
                    collectionView: collectionView,
                    controller: controller,
                    scrollController: scrollController,
                    deferredPasses: deferredPasses - 1
                )
            }
        }
    }

    static func captureImagePreviewViewport(
        from presenter: UIViewController
    ) -> ImagePreviewViewportRestoration? {
        guard let window = presenter.view.window,
              let collectionView = visibleTimelineCollectionView(in: presenter.view)
                ?? visibleTimelineCollectionView(in: window),
              let controller = collectionView.delegate as? ChatTimelineCollectionHost.Controller,
              let scrollController = controller.scrollController else {
            return nil
        }

        collectionView.layoutIfNeeded()
        let wasAttachedToTail = scrollController.isCurrentlyNearBottom
        let anchor = wasAttachedToTail
            ? nil
            : firstStableVisibleAnchor(in: collectionView, currentIDs: controller.currentIDs)

        return ImagePreviewViewportRestoration(
            collectionView: collectionView,
            controller: controller,
            scrollController: scrollController,
            sessionId: controller.sessionId,
            itemID: anchor?.itemID,
            viewportRelativeY: anchor?.viewportRelativeY,
            wasAttachedToTail: wasAttachedToTail
        )
    }

    private static func visibleTimelineCollectionView(in root: UIView) -> UICollectionView? {
        if let collectionView = root as? UICollectionView,
           collectionView.accessibilityIdentifier == "chat.timeline",
           collectionView.window != nil,
           !collectionView.isHidden,
           collectionView.alpha > 0.01 {
            return collectionView
        }

        for child in root.subviews.reversed() {
            if let collectionView = visibleTimelineCollectionView(in: child) {
                return collectionView
            }
        }
        return nil
    }

    private static func firstStableVisibleAnchor(
        in collectionView: UICollectionView,
        currentIDs: [String]
    ) -> (itemID: String, viewportRelativeY: CGFloat)? {
        let sortedVisible = collectionView.indexPathsForVisibleItems.sorted { lhs, rhs in
            let lhsY = collectionView.layoutAttributesForItem(at: lhs)?.frame.minY
                ?? .greatestFiniteMagnitude
            let rhsY = collectionView.layoutAttributesForItem(at: rhs)?.frame.minY
                ?? .greatestFiniteMagnitude
            return lhsY < rhsY
        }

        for indexPath in sortedVisible where indexPath.item < currentIDs.count {
            let itemID = currentIDs[indexPath.item]
            guard itemID != ChatTimelineCollectionHost.loadMoreID,
                  itemID != ChatTimelineCollectionHost.workingIndicatorID,
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                continue
            }
            return (
                itemID,
                attributes.frame.minY - collectionView.contentOffset.y
            )
        }
        return nil
    }

    static func performScroll(
        _ command: ChatTimelineScrollCommand,
        in collectionView: UICollectionView,
        currentIDs: [String],
        sessionId: String? = nil,
        afterNonAnimatedScroll: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let index = currentIDs.firstIndex(of: command.id) else { return false }
        let indexPath = IndexPath(item: index, section: 0)

        let position: UICollectionView.ScrollPosition
        switch command.anchor {
        case .top, .viewport:
            position = .top
        case .bottom:
            position = .bottom
        }

        ChatTimelinePerf.recordScrollCommand(anchor: command.anchor, animated: command.animated, sessionId: sessionId)

        if command.animated {
            collectionView.scrollToItem(at: indexPath, at: position, animated: true)
        } else {
            collectionView.scrollToItem(at: indexPath, at: position, animated: false)
        }

        if !command.animated {
            DispatchQueue.main.async {
                afterNonAnimatedScroll()
                DispatchQueue.main.async {
                    afterNonAnimatedScroll()
                }
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
        nearBottomExitThreshold: CGFloat,
        preserveDetachedState: Bool = false
    ) -> CGFloat? {
        guard let scrollController else { return nil }

        let insets = collectionView.adjustedContentInset
        scrollController.updateContentOffsetY(collectionView.contentOffset.y + insets.top)

        let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
        guard visibleHeight > 0 else { return nil }

        let bottomY = collectionView.contentOffset.y + insets.top + visibleHeight
        let contentHeight = collectionView.contentSize.height
        let distanceFromBottom = max(0, contentHeight - bottomY)
        if !preserveDetachedState {
            let nearBottomThreshold = scrollController.isCurrentlyNearBottom
                ? nearBottomExitThreshold
                : nearBottomEnterThreshold
            scrollController.updateNearBottom(distanceFromBottom <= nearBottomThreshold)
        }

        let visibleRect = CGRect(
            x: collectionView.contentOffset.x,
            y: collectionView.contentOffset.y,
            width: collectionView.bounds.width,
            height: collectionView.bounds.height
        )
        let firstVisible = collectionView.indexPathsForVisibleItems
            .compactMap { indexPath -> (indexPath: IndexPath, attributes: UICollectionViewLayoutAttributes)? in
                guard indexPath.item < currentIDs.count else { return nil }
                let id = currentIDs[indexPath.item]
                guard id != ChatTimelineCollectionHost.loadMoreID,
                      id != ChatTimelineCollectionHost.workingIndicatorID,
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                      attributes.frame.intersects(visibleRect) else {
                    return nil
                }
                return (indexPath, attributes)
            }
            .min { lhs, rhs in lhs.attributes.frame.minY < rhs.attributes.frame.minY }

        guard let firstVisible else {
            scrollController.updateViewportAnchor(itemID: nil, relativeY: nil)
            return distanceFromBottom
        }

        let id = currentIDs[firstVisible.indexPath.item]
        let relativeY = firstVisible.attributes.frame.minY - collectionView.contentOffset.y
        scrollController.updateViewportAnchor(itemID: id, relativeY: relativeY)

        return distanceFromBottom
    }
}
