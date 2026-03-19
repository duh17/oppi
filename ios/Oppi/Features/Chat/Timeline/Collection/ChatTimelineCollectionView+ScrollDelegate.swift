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
                scrollView.contentOffset.y = previousOffset
                isApplyingDetachedProgrammaticCorrection = false
                detachedProgrammaticTargetOffsetY = nil
                lastObservedContentOffsetY = previousOffset
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
                scrollView.contentOffset.y = targetOffsetY
                isApplyingDetachedProgrammaticCorrection = false
                detachedProgrammaticTargetOffsetY = nil
                lastObservedContentOffsetY = targetOffsetY
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
           contentHeightDelta > 0.5 {
            let insets = scrollView.adjustedContentInset
            let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom
            if visibleHeight > 0 {
                // Keep the viewport pinned to the bottom when content grows
                // during non-user-driven layout changes. The previous
                // abs(deltaY) < 2 guard was too restrictive — self-sizing
                // cascades where cells above the viewport resolve estimated
                // -> actual heights shift contentOffset by > 2pt per pass.
                // The old guard missed these corrections, slowly accumulating
                // a gap between the last item and the viewport bottom until
                // the user got false-detached past the 200pt exit threshold.
                //
                // Forward-only: never snap the user upward (away from new
                // content). Content shrinking during estimate resolution is
                // transient and handled by UIKit's natural layout.
                let desiredBottomOffsetY = max(-insets.top, scrollView.contentSize.height - visibleHeight)
                if desiredBottomOffsetY - scrollView.contentOffset.y > 0.5 {
                    scrollView.contentOffset.y = desiredBottomOffsetY
                    lastDistanceFromBottom = 0
                }
            }
        }

        lastObservedContentOffsetY = scrollView.contentOffset.y

        // For user-driven scrolls (scrolling back down toward bottom),
        // always update state so re-attach can happen.
        //
        // For programmatic offset changes (layout invalidation during
        // snapshot apply), only update when already attached. This prevents
        // a detached user from being re-attached by a layout-triggered
        // contentOffset adjustment.
        if isUserDriven || alreadyAttached {
            updateScrollState(collectionView)
        }
        updateDetachedStreamingHintVisibility()
    }
}

// MARK: - Scroll State Helpers

extension ChatTimelineCollectionHost.Controller {
    private func updateLastDistanceFromBottom(_ scrollView: UIScrollView) {
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
    }
}
