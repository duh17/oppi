import UIKit

@MainActor
enum TimelineScrollCoordinator {
    /// Reading anchor captured before a modal image preview covers chat.
    /// Stable item identity and current-window lookup make restoration resilient
    /// to row remeasurement and timeline remounting while the preview is open.
    @MainActor
    final class ImagePreviewViewportRestoration {
        private weak var window: UIWindow?
        private weak var collectionView: UICollectionView?
        private weak var controller: ChatTimelineCollectionHost.Controller?
        private weak var scrollController: ChatScrollController?
        private let sessionId: String
        private let snapshot: TimelineViewportSnapshot?
        private let wasAttachedToTail: Bool
        private let preservationToken: UInt
        private var isFinishing = false
        private var isFinished = false

        fileprivate init(
            window: UIWindow,
            collectionView: UICollectionView,
            controller: ChatTimelineCollectionHost.Controller,
            scrollController: ChatScrollController,
            sessionId: String,
            snapshot: TimelineViewportSnapshot?,
            wasAttachedToTail: Bool,
            preservationToken: UInt
        ) {
            self.window = window
            self.collectionView = collectionView
            self.controller = controller
            self.scrollController = scrollController
            self.sessionId = sessionId
            self.snapshot = snapshot
            self.wasAttachedToTail = wasAttachedToTail
            self.preservationToken = preservationToken
        }

        func restore() {
            guard !isFinished,
                  let resolved = resolveCurrentTimeline() else { return }
            let (collectionView, controller, scrollController) = resolved
            guard scrollController.ownsImagePreviewViewportPreservation(
                preservationToken
            ) else {
                return
            }
            guard !TimelineScrollCoordinator.isUserInteracting(
                with: collectionView,
                scrollController: scrollController
            ) else {
                return
            }

            collectionView.layoutIfNeeded()

            if wasAttachedToTail {
                // Use the offset controller directly. `scrollToItem` can commit
                // its own delayed offset after a dismissal-time touch begins,
                // bypassing the queued-pass interaction guards below.
                restoreAttachedTail(
                    collectionView: collectionView,
                    controller: controller,
                    scrollController: scrollController,
                    deferredPasses: 2
                )
                return
            }

            guard let snapshot,
                  let fullOrderRestoration = TimelineViewportRestorationResolver.resolve(
                    snapshot,
                    availableFullTimelineItemIDs: controller.currentFullTimelineItemIDs
                  ),
                  let restoration = TimelineViewportRestorationResolver.resolveRenderedWindow(
                    fullOrderRestoration,
                    availableFullTimelineItemIDs: controller.currentFullTimelineItemIDs,
                    renderedTimelineItemIDs: controller.currentIDs,
                    renderedIDForFullTimelineItemID: { controller.renderedID(forFullTimelineItemID: $0) }
                  ),
                  let itemIndex = controller.currentIDs.firstIndex(of: restoration.itemID),
                  let attributes = collectionView.layoutAttributesForItem(
                    at: IndexPath(item: itemIndex, section: 0)
                  ) else {
                return
            }

            let anchoredCollectionView = collectionView as? AnchoredCollectionView
            anchoredCollectionView?.isDetachedFromBottom = false
            anchoredCollectionView?.clearDetachedAnchor()
            _ = TimelineOffsetController.apply(
                targetOffsetY: attributes.frame.minY - restoration.relativeY,
                reason: .viewportPreservation,
                collectionView: collectionView,
                scrollController: scrollController
            )
            collectionView.layoutIfNeeded()

            anchoredCollectionView?.isDetachedFromBottom = true
            anchoredCollectionView?.captureDetachedAnchor()
            controller.updateScrollState(collectionView, preserveDetachedState: true)
        }

        func finish() {
            guard !isFinished, !isFinishing else { return }
            isFinishing = true

            guard wasAttachedToTail,
                  let resolved = resolveCurrentTimeline() else {
                restore()
                completeFinish()
                return
            }
            let (collectionView, controller, scrollController) = resolved
            guard scrollController.ownsImagePreviewViewportPreservation(
                preservationToken
            ) else {
                completeFinish()
                return
            }

            restoreAttachedTail(
                collectionView: collectionView,
                controller: controller,
                scrollController: scrollController,
                deferredPasses: 2,
                completion: { [weak self] in self?.completeFinish() }
            )
        }

        func cancel() {
            guard !isFinished else { return }
            isFinishing = false
            isFinished = true
            scrollController?.endImagePreviewViewportPreservation(preservationToken)
        }

        private func completeFinish() {
            guard !isFinished else { return }
            isFinishing = false
            isFinished = true
            scrollController?.endImagePreviewViewportPreservation(preservationToken)
        }

        private func resolveCurrentTimeline() -> (
            UICollectionView,
            ChatTimelineCollectionHost.Controller,
            ChatScrollController
        )? {
            if let collectionView,
               let controller,
               let scrollController,
               controller.collectionView === collectionView,
               controller.sessionId == sessionId,
               collectionView.window != nil {
                return (collectionView, controller, scrollController)
            }

            guard let window,
                  let collectionView = TimelineScrollCoordinator.visibleTimelineCollectionView(in: window),
                  let controller = collectionView.delegate as? ChatTimelineCollectionHost.Controller,
                  let scrollController = controller.scrollController,
                  controller.sessionId == sessionId else {
                return nil
            }
            self.collectionView = collectionView
            self.controller = controller
            self.scrollController = scrollController
            return (collectionView, controller, scrollController)
        }

        private func restoreAttachedTail(
            collectionView: UICollectionView,
            controller: ChatTimelineCollectionHost.Controller,
            scrollController: ChatScrollController,
            deferredPasses: Int,
            completion: (@MainActor () -> Void)? = nil
        ) {
            guard scrollController.ownsImagePreviewViewportPreservation(
                preservationToken
            ),
                  controller.collectionView === collectionView,
                  controller.sessionId == sessionId,
                  collectionView.window != nil,
                  !TimelineScrollCoordinator.isUserInteracting(
                    with: collectionView,
                    scrollController: scrollController
                  ) else {
                completion?()
                return
            }

            collectionView.layoutIfNeeded()
            let insets = collectionView.adjustedContentInset
            let targetOffsetY = max(
                -insets.top,
                collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
            )
            let didApply = TimelineOffsetController.apply(
                targetOffsetY: targetOffsetY,
                reason: .viewportPreservation,
                collectionView: collectionView,
                scrollController: scrollController
            )
            guard scrollController.ownsImagePreviewViewportPreservation(
                preservationToken
            ),
                  !TimelineScrollCoordinator.isUserInteracting(
                    with: collectionView,
                    scrollController: scrollController
                  ),
                  didApply || abs(collectionView.contentOffset.y - targetOffsetY) <= 0.5 else {
                completion?()
                return
            }
            scrollController.updateNearBottom(true)
            controller.updateScrollState(collectionView)

            guard deferredPasses > 0 else {
                completion?()
                return
            }
            DispatchQueue.main.async { [weak self, weak collectionView, weak controller, weak scrollController] in
                guard let self, let collectionView, let controller, let scrollController else {
                    completion?()
                    return
                }
                self.restoreAttachedTail(
                    collectionView: collectionView,
                    controller: controller,
                    scrollController: scrollController,
                    deferredPasses: deferredPasses - 1,
                    completion: completion
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
        controller.updateScrollState(collectionView, preserveDetachedState: true)
        let wasAttachedToTail = scrollController.isCurrentlyNearBottom
        let preservation = scrollController.beginImagePreviewViewportPreservation(
            wasAttachedToTail: wasAttachedToTail
        )

        return ImagePreviewViewportRestoration(
            window: window,
            collectionView: collectionView,
            controller: controller,
            scrollController: scrollController,
            sessionId: controller.sessionId,
            snapshot: preservation.snapshot,
            wasAttachedToTail: wasAttachedToTail,
            preservationToken: preservation.token
        )
    }

    private static func isUserInteracting(
        with collectionView: UICollectionView,
        scrollController: ChatScrollController?
    ) -> Bool {
        scrollController?.isUserInteracting == true
            || collectionView.isTracking
            || collectionView.isDragging
            || collectionView.isDecelerating
    }

    fileprivate static func visibleTimelineCollectionView(in root: UIView) -> UICollectionView? {
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
        preserveDetachedState: Bool = false,
        fullTimelineIDForRenderedID: ((String) -> String?)? = nil
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

        let renderedID = currentIDs[firstVisible.indexPath.item]
        let relativeY = firstVisible.attributes.frame.minY - collectionView.contentOffset.y
        let fullTimelineID = fullTimelineIDForRenderedID?(renderedID) ?? renderedID
        scrollController.updateViewportAnchor(itemID: fullTimelineID, relativeY: relativeY)

        return distanceFromBottom
    }
}
