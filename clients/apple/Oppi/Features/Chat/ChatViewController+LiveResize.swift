import UIKit

// The chat holds its timeline at its width while a divider beside it moves, and
// lays it out once where the divider pauses or rests. The bar, the composer and
// the footer stay on the safe area and follow every frame: they are cheap. The
// timeline's rows are not: every width drops TextKit layout for each visible
// row, which on a moving frame cost more than the frame.

extension ChatViewController: PaneLiveResizing {
    /// Pins the timeline at its current width. A shrinking chat clips it under
    /// the pane beside; a growing one shows the chat's background past it.
    func paneWillBeginLiveResize() {
        guard let timelineView, timelineHeldWidth == nil, timelineView.bounds.width > 1 else { return }
        let held = timelineView.widthAnchor.constraint(equalToConstant: timelineView.bounds.width)
        timelineTrailing?.isActive = false
        held.isActive = true
        timelineHeldWidth = held
        (timelineView.collectionViewLayout as? ChatTimelineCachedHeightLayout)?.isHeldForLiveResize = true
    }

    /// Back on the safe area: one layout at the new width, at the same reading
    /// position (the tail when the timeline was on it, else the first row read).
    func paneSettleLiveResize(to size: CGSize, final: Bool) {
        guard let timelineView, let held = timelineHeldWidth else { return }
        let anchor = timeline.liveResizeAnchor(in: timelineView)
        held.isActive = false
        timelineHeldWidth = nil
        timelineTrailing?.isActive = true
        (timelineView.collectionViewLayout as? ChatTimelineCachedHeightLayout)?.isHeldForLiveResize = false
        view.layoutIfNeeded()
        timeline.restoreLiveResizeAnchor(anchor, in: timelineView)
    }
}

extension ChatTimelineController {
    /// Where the reader is, for a live resize to keep across its one reflow.
    struct LiveResizeAnchor {
        /// The first row read, and its top edge relative to the viewport; nil
        /// when the timeline follows its tail.
        let row: (itemID: String, screenY: CGFloat)?
    }

    func liveResizeAnchor(in collectionView: UICollectionView) -> LiveResizeAnchor {
        guard !(scrollController?.isCurrentlyNearBottom ?? true) else { return LiveResizeAnchor(row: nil) }
        let readingTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let first = collectionView.indexPathsForVisibleItems
            .compactMap { indexPath -> (Int, CGRect)? in
                guard indexPath.item < currentIDs.count,
                      let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                      frame.maxY > readingTop else { return nil }
                return (indexPath.item, frame)
            }
            .min { $0.1.minY < $1.1.minY }
        guard let (item, frame) = first else { return LiveResizeAnchor(row: nil) }
        return LiveResizeAnchor(row: (currentIDs[item], frame.minY - collectionView.contentOffset.y))
    }

    func restoreLiveResizeAnchor(_ anchor: LiveResizeAnchor, in collectionView: UICollectionView) {
        guard let row = anchor.row else {
            pinAttachedTail(collectionView, toExactBottom: true)
            return
        }
        guard let item = currentIDs.firstIndex(of: row.itemID),
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame else {
            return
        }
        TimelineOffsetController.apply(
            targetOffsetY: frame.minY - row.screenY,
            reason: .viewportPreservation,
            collectionView: collectionView,
            scrollController: scrollController
        )
        if let anchored = collectionView as? AnchoredCollectionView, anchored.isDetachedFromBottom {
            anchored.captureDetachedAnchor()
        }
    }
}
