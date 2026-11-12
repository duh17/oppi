import UIKit

// MARK: - UIScrollViewDelegate

extension ChatTimelineController {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollController?.setUserInteracting(true)
        lastObservedContentOffsetY = scrollView.contentOffset.y
        earlierRowsRequestMark = nil

        guard let collectionView = scrollView as? UICollectionView else { return }
        // A real drag owns follow state immediately. Sample the live geometry
        // before the first movement callback so an already-detached reader is
        // not pulled back to the tail by an active turn while browsing. This
        // mirrors Pi fullscreen's explicit `followingEnd` state: user scrolling
        // away clears follow until they reach the live edge again.
        updateLastDistanceFromBottom(collectionView)
        if lastDistanceFromBottom > nearBottomExitThreshold {
            // Explicit user ownership must override the temporary follow lock
            // installed by send/jump-to-bottom. Passive layout updates still
            // cannot detach that lock.
            scrollController?.detachFromBottomForUserScroll()
            updateScrollState(collectionView, preserveDetachedState: true)
            (collectionView as? AnchoredCollectionView)?.isDetachedFromBottom = true
            (collectionView as? AnchoredCollectionView)?.captureDetachedAnchor()
        } else {
            updateScrollState(collectionView)
        }
        updateDetachedStreamingHintVisibility()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scrollController?.setUserInteracting(false)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollController?.setUserInteracting(false)
    }

    /// A status-bar tap is a programmatic scroll, so the drag path never sees
    /// it. It is still an explicit ask for the top; keep going past it.
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        earlierRowsRequestMark = nil
        requestEarlierRowsIfNearTop(scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let collectionView = scrollView as? UICollectionView else { return }

        defer {
            lastObservedContentHeight = scrollView.contentSize.height
            // Every scroll path, including early returns for upward drags,
            // must republish unobstructed audio-strip IDs. Cells under the
            // composer overlay stay in visibleCells.
            publishVisibleAudioStripItemIDs(in: collectionView)
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

        if isUserDriven, deltaY < -0.5 {
            // User is scrolling up: detach and skip position-based
            // re-evaluation so updateScrollState cannot immediately
            // re-attach within the same callback.
            scrollController?.detachFromBottomForUserScroll()
            lastObservedContentOffsetY = scrollView.contentOffset.y
            // Detaching must still sample the live viewport. Returning
            // without this left navigation restoration holding the last
            // tail-attached anchor from before the user's drag.
            updateScrollState(collectionView, preserveDetachedState: true)
            if let anchoredCV = collectionView as? AnchoredCollectionView {
                anchoredCV.isDetachedFromBottom = true
                anchoredCV.captureDetachedAnchor()
            }
            updateDetachedStreamingHintVisibility()
            requestEarlierRowsIfNearTop(scrollView)
            return
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

/// Local reveals shrink the hidden count; a loaded older page grows the
/// timeline. Either one means the last request landed.
struct EarlierRowsRequestMark: Equatable {
    let hiddenCount: Int
    let timelineItemCount: Int
}

// MARK: - Scroll State Helpers

extension ChatTimelineController {
    /// Infinite scroll toward older rows: once an upward user scroll is within
    /// one viewport of the top, reveal the next batch before the reader reaches
    /// the edge. The detached identity anchor keeps the reader's row in place
    /// while rows are inserted above it.
    func requestEarlierRowsIfNearTop(_ scrollView: UIScrollView) {
        guard currentIDs.first == Self.loadMoreID,
              onShowEarlier != nil else {
            return
        }
        // Not the first row ID: a folded work pill keeps its ID while the
        // window grows through its turn.
        let mark = EarlierRowsRequestMark(
            hiddenCount: previousHiddenCount,
            timelineItemCount: currentFullTimelineItemIDs.count
        )
        guard mark != earlierRowsRequestMark else { return }
        let insets = scrollView.adjustedContentInset
        let viewportHeight = scrollView.bounds.height - insets.top - insets.bottom
        let distanceFromTop = scrollView.contentOffset.y + insets.top
        guard viewportHeight > 0, distanceFromTop < viewportHeight else { return }

        earlierRowsRequestMark = mark
        // Never mutate the snapshot inside the scroll callback; the reveal
        // re-enters layout and contentOffset.
        DispatchQueue.main.async { [weak self] in
            self?.onShowEarlier?()
        }
    }

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

    func updateScrollState(
        _ collectionView: UICollectionView,
        preserveDetachedState: Bool = false
    ) {
        if let distanceFromBottom = TimelineScrollCoordinator.updateScrollState(
            collectionView: collectionView,
            scrollController: scrollController,
            currentIDs: currentIDs,
            nearBottomEnterThreshold: nearBottomEnterThreshold,
            nearBottomExitThreshold: nearBottomExitThreshold,
            preserveDetachedState: preserveDetachedState,
            fullTimelineIDForRenderedID: { [weak self] id in
                self?.fullTimelineItemID(forRenderedID: id)
            }
        ) {
            lastDistanceFromBottom = distanceFromBottom
        }

        // Logical attach is the pin off-switch. Jump, send, and a finger
        // return to the tail must not leave a stale identity restore armed.
        if !preserveDetachedState,
           scrollController?.isCurrentlyNearBottom == true,
           let anchoredCV = collectionView as? AnchoredCollectionView {
            anchoredCV.isDetachedFromBottom = false
            anchoredCV.clearDetachedAnchor()
        }

        if let targetID = scrollController?.pendingNavigationHighlightItemID {
            _ = applyPendingNavigationHighlightIfVisible(for: targetID, in: collectionView)
        }
    }
}

// MARK: - Off-screen settle

/// What a timeline that skipped its forced layout off screen owes its return.
struct OffscreenTimelineSettle {
    /// An attached update skipped its tail pin.
    var pinsAttachedTail = false
    /// One of those updates appended a row or was idle, so the pin is the
    /// exact bottom rather than only keeping the live tail visible.
    var settlesAttachedBottom = false
    /// The detached reader's position from before the first skipped pass.
    var readerPosition: AnchoredCollectionView.DetachedReaderPosition?
    /// A work-line replacement needs the restore again once its frame settles.
    var replaysReaderPosition = false
}

extension ChatTimelineController {
    /// A forced layout pass out of the window only makes geometry nobody sees
    /// current, and the CPU it burns stalls the screen that is showing. The
    /// pass is deferred only where `AnchoredCollectionView.didMoveToWindow`
    /// will settle it.
    func defersLayoutOffscreen(_ collectionView: UICollectionView) -> Bool {
        collectionView.window == nil && collectionView is AnchoredCollectionView
    }

    func oweOffscreenSettle(_ update: (inout OffscreenTimelineSettle) -> Void) {
        var owed = offscreenSettle ?? OffscreenTimelineSettle()
        update(&owed)
        offscreenSettle = owed
    }

    /// Runs, once, the layout this timeline skipped while out of the window.
    /// `AnchoredCollectionView` calls it as it enters a window, before the
    /// next frame, so the reader sees the rows and position a timeline that
    /// stayed on screen would show: the live tail pinned, or the reader's row
    /// at the screen Y it had.
    func settleOffscreenUpdates(in collectionView: UICollectionView) {
        guard collectionView.window != nil, let owed = offscreenSettle else { return }
        offscreenSettle = nil

        let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: currentIDs.count, sessionId: sessionId)
        collectionView.layoutIfNeeded()
        if let readerPosition = owed.readerPosition,
           let anchoredCollectionView = collectionView as? AnchoredCollectionView {
            anchoredCollectionView.restoreDetachedReaderPosition(readerPosition)
            if owed.replaysReaderPosition {
                replayDetachedReaderPosition(readerPosition, in: anchoredCollectionView)
            }
        }
        ChatTimelinePerf.endLayoutPass(layoutToken)

        if owed.pinsAttachedTail, canReconcileAmbientScroll(collectionView) {
            pinAttachedTail(collectionView, toExactBottom: owed.settlesAttachedBottom)
        }
        if !isTimelineBusy, scrollController?.isCurrentlyNearBottom ?? true {
            updateScrollState(collectionView)
        }
        updateDetachedStreamingHintVisibility()
        // A settle that moves nothing fires no scroll callback to do this.
        publishVisibleAudioStripItemIDs(in: collectionView)
    }

    /// A replaced work line's final frame exists only after the first pass;
    /// restore the reader's Y once more on the next turn.
    func replayDetachedReaderPosition(
        _ readerPosition: AnchoredCollectionView.DetachedReaderPosition,
        in anchoredCollectionView: AnchoredCollectionView
    ) {
        DispatchQueue.main.async { [weak anchoredCollectionView] in
            // A finger that landed since the apply owns the
            // viewport; replaying the old Y would snap it back.
            guard let anchoredCollectionView,
                  !anchoredCollectionView.isTracking,
                  !anchoredCollectionView.isDragging,
                  !anchoredCollectionView.isDecelerating else {
                return
            }
            anchoredCollectionView.layoutIfNeeded()
            anchoredCollectionView.restoreDetachedReaderPosition(readerPosition)
        }
    }
}
