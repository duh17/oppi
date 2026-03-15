import UIKit

/// Collection view subclass that stabilises scroll through self-sizing cells
/// by anchoring the first visible item's screen position across layout passes.
///
/// `UICollectionViewCompositionalLayout` with `.estimated()` heights can shift
/// `contentOffset` when cells change size during `layoutSubviews`. This
/// subclass captures the first visible item's screen-relative Y before layout
/// and restores it after, eliminating the visible jitter.
@MainActor
final class AnchoredCollectionView: UICollectionView {

    // Reusable state — no per-frame allocation.
    private var savedAnchorIP: IndexPath?
    private var savedAnchorScreenY: CGFloat = 0
    private var isApplyingAnchorCorrection = false

    /// Set by the timeline controller before each snapshot apply so layout
    /// passes preserve the first visible item's screen position for users
    /// who scrolled away from the bottom. Without this, cell height changes
    /// (e.g. a collapsed image preview appearing in a tool row) shift the
    /// viewport because neither user-interaction anchoring nor the
    /// `scrollViewDidScroll` fallback covers the passive detached case.
    var isDetachedFromBottom = false

    #if DEBUG
        /// Tests cannot drive UIKit drag/deceleration flags directly, so this
        /// override allows deterministic anchoring coverage in unit tests.
        var forceAnchoringForTesting = false

        /// Optional hook to mutate layout state after anchor capture but before
        /// UIKit performs the layout pass. Used to simulate estimated→actual
        /// geometry changes in unit tests.
        var didCaptureAnchorForTesting: (() -> Void)?
    #endif

    override func layoutSubviews() {
        if isApplyingAnchorCorrection {
            super.layoutSubviews()
            return
        }

        captureAnchor()

        #if DEBUG
            didCaptureAnchorForTesting?()
        #endif

        super.layoutSubviews()
        restoreAnchor()
    }

    // MARK: - Private

    private var shouldAnchorDuringThisPass: Bool {
        #if DEBUG
            if forceAnchoringForTesting {
                return true
            }
        #endif

        // Always anchor during user-driven scroll (drag/decelerate).
        if isTracking || isDragging || isDecelerating {
            return true
        }

        // Anchor for detached users on passive layout passes. When a cell
        // changes height (e.g. image preview appears) the compositional
        // layout shifts contentOffset. Without anchoring, the viewport
        // jumps to an unrelated position. Safe for auto-scroll because
        // programmatic scrolls (scrollToItem) set contentOffset before the
        // layout pass — the anchor captures the post-scroll position and
        // restores it (no-op).
        return isDetachedFromBottom
    }

    private func captureAnchor() {
        savedAnchorIP = nil

        guard shouldAnchorDuringThisPass else { return }

        guard let firstIP = indexPathsForVisibleItems.min(by: { $0.item < $1.item }),
              let attrs = layoutAttributesForItem(at: firstIP) else { return }

        savedAnchorIP = firstIP
        savedAnchorScreenY = attrs.frame.origin.y - contentOffset.y
    }

    private func restoreAnchor() {
        guard let anchorIP = savedAnchorIP,
              let newAttrs = layoutAttributesForItem(at: anchorIP) else {
            savedAnchorIP = nil
            return
        }

        let newScreenY = newAttrs.frame.origin.y - contentOffset.y
        let delta = newScreenY - savedAnchorScreenY

        savedAnchorIP = nil

        guard delta.isFinite, abs(delta) > 0.5 else { return }

        // Never push beyond legal scroll bounds — keep UIKit bounce behavior
        // deterministic near top/bottom while still preserving anchor position
        // as much as possible.
        let minOffsetY = -adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )

        let targetOffsetY = contentOffset.y + delta
        let clampedOffsetY = min(max(targetOffsetY, minOffsetY), maxOffsetY)
        guard abs(clampedOffsetY - contentOffset.y) > 0.5 else { return }

        isApplyingAnchorCorrection = true
        contentOffset.y = clampedOffsetY
        isApplyingAnchorCorrection = false
    }
}
