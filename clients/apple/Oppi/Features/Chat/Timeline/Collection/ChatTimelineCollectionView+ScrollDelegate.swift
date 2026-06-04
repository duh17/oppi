import UIKit

// MARK: - UIScrollViewDelegate

extension ChatTimelineCollectionHost.Controller {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollController?.setUserInteracting(true)
        lastObservedContentOffsetY = scrollView.contentOffset.y
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scrollController?.setUserInteracting(false)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollController?.setUserInteracting(false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let collectionView = scrollView as? UICollectionView else { return }

        defer {
            lastObservedContentHeight = scrollView.contentSize.height
        }

        let previousContentHeight = lastObservedContentHeight ?? scrollView.contentSize.height
        let contentHeightDelta = scrollView.contentSize.height - previousContentHeight

        // Always track distance for hint visibility, even when
        // updateScrollState is skipped.
        updateLastDistanceFromBottom(scrollView)

        let isUserDriven = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        let alreadyAttached = scrollController?.isCurrentlyNearBottom ?? true
        let previousOffset = lastObservedContentOffsetY ?? scrollView.contentOffset.y
        let deltaY = scrollView.contentOffset.y - previousOffset

        if isApplyingDetachedProgrammaticCorrection {
            lastObservedContentOffsetY = scrollView.contentOffset.y
            return
        }

        if isUserDriven {
            if deltaY < -0.5 {
                // User is scrolling up: detach and skip position-based
                // re-evaluation so updateScrollState cannot immediately
                // re-attach within the same callback.
                scrollController?.detachFromBottomForUserScroll()
                detachedProgrammaticTargetOffsetY = nil
                lastObservedContentOffsetY = scrollView.contentOffset.y
                updateDetachedStreamingHintVisibility()
                return
            }

            detachedProgrammaticTargetOffsetY = nil
        } else if !alreadyAttached,
                  !(collectionView is AnchoredCollectionView) {
            // Detached + programmatic offset changes can trigger UIKit
            // offset jumps while self-sizing settles. For detached users,
            // preserve viewport stability across large passive jumps caused
            // by busy timeline growth (append/reflow), but still allow
            // intentional programmatic navigation jumps.
            if isTimelineBusy,
               abs(contentHeightDelta) > 0.5,
               abs(deltaY) >= detachedProgrammaticCorrectionMaxDelta {
                isApplyingDetachedProgrammaticCorrection = true
                let didApply = TimelineOffsetController.apply(
                    targetOffsetY: previousOffset,
                    reason: .detachedFallback,
                    collectionView: collectionView,
                    scrollController: scrollController
                )
                isApplyingDetachedProgrammaticCorrection = false
                detachedProgrammaticTargetOffsetY = nil
                let correctedOffsetY = didApply ? collectionView.contentOffset.y : previousOffset
                lastObservedContentOffsetY = correctedOffsetY
                updateLastDistanceFromBottom(scrollView)
                updateDetachedStreamingHintVisibility()
                return
            }

            // Keep the large jump target and ignore a single small
            // follow-up snap (estimated -> actual heights).
            if let targetOffsetY = detachedProgrammaticTargetOffsetY,
               abs(deltaY) > 0.5,
               abs(deltaY) < detachedProgrammaticCorrectionMaxDelta {
                isApplyingDetachedProgrammaticCorrection = true
                let didApply = TimelineOffsetController.apply(
                    targetOffsetY: targetOffsetY,
                    reason: .detachedFallback,
                    collectionView: collectionView,
                    scrollController: scrollController
                )
                isApplyingDetachedProgrammaticCorrection = false
                detachedProgrammaticTargetOffsetY = nil
                let correctedOffsetY = didApply ? collectionView.contentOffset.y : targetOffsetY
                lastObservedContentOffsetY = correctedOffsetY
                updateLastDistanceFromBottom(scrollView)
                updateDetachedStreamingHintVisibility()
                return
            }

            if abs(deltaY) >= detachedProgrammaticArmMinDelta {
                detachedProgrammaticTargetOffsetY = scrollView.contentOffset.y
            } else if abs(deltaY) >= detachedProgrammaticCorrectionMaxDelta {
                detachedProgrammaticTargetOffsetY = nil
            }
        } else {
            detachedProgrammaticTargetOffsetY = nil
        }

        if !isUserDriven,
           alreadyAttached,
           !isTimelineBusy,
           abs(contentHeightDelta) > 0.5 {
            let insets = scrollView.adjustedContentInset
            let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom
            if visibleHeight > 0 {
                // Keep the idle viewport pinned to the bottom when content
                // size changes during non-user-driven layout passes. Busy
                // streaming is handled by the collection view's tail governor
                // after apply/layout so this delegate does not fight it.
                //
                // Formula: contentSize - bounds + adjustedContentInset.bottom.
                // NOT contentSize - visibleHeight, which expands to
                // contentSize - bounds + insets.top + insets.bottom and
                // overshoots by insets.top (header + safe area), pushing the
                // last item above the footer.
                let desiredBottomOffsetY = max(
                    -insets.top,
                    scrollView.contentSize.height - scrollView.bounds.height + insets.bottom
                )
                if TimelineOffsetController.apply(
                    targetOffsetY: desiredBottomOffsetY,
                    reason: .idleBottomSettle,
                    collectionView: collectionView,
                    scrollController: scrollController
                ) {
                    lastDistanceFromBottom = 0
                }
            }
        }

        lastObservedContentOffsetY = scrollView.contentOffset.y

        // For user-driven scrolls (scrolling back down toward bottom),
        // always update state so re-attach can happen.
        //
        // For programmatic offset changes (layout invalidation during
        // snapshot apply), only update when already attached and idle. Busy
        // ambient follow keeps the logical attached state stable until the user
        // scrolls or the collection-side tail governor/idle settle runs.
        if isUserDriven || (alreadyAttached && !isTimelineBusy) {
            updateScrollState(collectionView)
        }
        updateDetachedStreamingHintVisibility()
    }
}

// MARK: - Scroll State Helpers

extension ChatTimelineCollectionHost.Controller {
    func updateLastDistanceFromBottom(_ scrollView: UIScrollView) {
        let insets = scrollView.adjustedContentInset
        let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom
        guard visibleHeight > 0 else { return }

        let bottomY = scrollView.contentOffset.y + insets.top + visibleHeight
        lastDistanceFromBottom = max(0, scrollView.contentSize.height - bottomY)
    }

    func updateDetachedStreamingHintVisibility() {
        TimelineScrollCoordinator.updateDetachedStreamingHintVisibility(
            scrollController: scrollController,
            streamingAssistantID: streamingAssistantID,
            distanceFromBottom: lastDistanceFromBottom,
            jumpToBottomMinDistance: jumpToBottomMinDistance
        )
    }

    func updateScrollState(_ collectionView: UICollectionView) {
        if let distanceFromBottom = TimelineScrollCoordinator.updateScrollState(
            collectionView: collectionView,
            scrollController: scrollController,
            currentIDs: currentIDs,
            nearBottomEnterThreshold: nearBottomEnterThreshold,
            nearBottomExitThreshold: nearBottomExitThreshold
        ) {
            lastDistanceFromBottom = distanceFromBottom
        }

        if let targetID = scrollController?.pendingNavigationHighlightItemID {
            _ = applyPendingNavigationHighlightIfVisible(for: targetID, in: collectionView)
        }
    }
}
