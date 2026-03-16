import UIKit

/// Collection view subclass that stabilises scroll through self-sizing cells
/// by anchoring the first visible item's screen position across layout passes.
///
/// `UICollectionViewCompositionalLayout` with `.estimated()` heights can shift
/// `contentOffset` when cells change size during `layoutSubviews`. This
/// subclass captures the first visible item's screen-relative Y before layout
/// and restores it after, eliminating the visible jitter.
///
/// For expand/collapse and detached-user scenarios, also intercepts
/// `contentOffset` changes via `didSet` to counteract UIKit's self-sizing
/// cascade, which adjusts contentOffset AFTER `layoutSubviews()` returns.
@MainActor
final class AnchoredCollectionView: UICollectionView {

    // Reusable state — no per-frame allocation.
    private var savedAnchorIP: IndexPath?
    private var savedAnchorScreenY: CGFloat = 0
    private var isApplyingAnchorCorrection = false

    /// The "known good" contentOffset.y after the latest layoutSubviews
    /// anchor restoration or explicit anchor capture. The contentOffset
    /// didSet restores this value instead of querying `layoutAttributesForItem`
    /// — the layout engine query is expensive (~78μs) and triggers recursive
    /// layout. Since the didSet only fires for post-layout cascade
    /// adjustments (where cell frames haven't changed), restoring the saved
    /// offset is equivalent to a full layout-based correction.
    private var expandCollapseSavedOffsetY: CGFloat = 0
    private var detachedSavedOffsetY: CGFloat = 0

    /// When non-nil, the next layoutSubviews will restore contentOffset.y
    /// to this value. Set by the contentOffset.didSet to batch multiple
    /// cascade adjustments into a single layout correction. This avoids
    /// the ~55μs UIView.bounds setter cost on every didSet entry.
    private var pendingCorrectionOffsetY: CGFloat?

    /// Set by the timeline controller before each snapshot apply so layout
    /// passes preserve the first visible item's screen position for users
    /// who scrolled away from the bottom. Without this, cell height changes
    /// (e.g. a collapsed image preview appearing in a tool row) shift the
    /// viewport because neither user-interaction anchoring nor the
    /// `scrollViewDidScroll` fallback covers the passive detached case.
    var isDetachedFromBottom = false

    // MARK: - Expand/collapse anchoring

    /// When set, this index path is used as the anchor instead of the first
    /// visible item. Persists until explicitly cleared via
    /// `clearExpandCollapseAnchor()`. The caller is responsible for
    /// scheduling cleanup after all layout passes have settled.
    private(set) var expandCollapseAnchorIP: IndexPath?

    /// The screen-relative Y of the anchored item at the time the anchor
    /// was set. Used by `contentOffset.didSet` to force-restore position
    /// when UIKit adjusts contentOffset outside of `layoutSubviews()`.
    private var expandCollapseAnchorScreenY: CGFloat = 0

    /// Pin a specific item's screen position across expand/collapse layout
    /// passes. Captures the item's current screen-relative Y and
    /// force-restores it on every subsequent contentOffset change until
    /// `clearExpandCollapseAnchor()` is called.
    func setExpandCollapseAnchor(indexPath: IndexPath) {
        expandCollapseAnchorIP = indexPath
        expandCollapseSavedOffsetY = contentOffset.y
        if let attrs = layoutAttributesForItem(at: indexPath) {
            expandCollapseAnchorScreenY = attrs.frame.origin.y - contentOffset.y
        }
    }

    /// Clear the expand/collapse anchor after layout passes have settled.
    func clearExpandCollapseAnchor() {
        expandCollapseAnchorIP = nil
    }

    // MARK: - Detached anchor

    /// Anchors the first visible item during snapshot applies when the user
    /// is scrolled away from the bottom. Counteracts the self-sizing cascade
    /// from `UICollectionViewCompositionalLayout` which adjusts contentOffset
    /// outside `layoutSubviews()` as cells report their preferred sizes.
    private var detachedAnchorIP: IndexPath?
    private var detachedAnchorScreenY: CGFloat = 0

    /// Capture the detached anchor for subsequent contentOffset corrections.
    /// Called before snapshot apply when the user is scrolled away from bottom.
    func captureDetachedAnchor() {
        guard let firstIP = indexPathsForVisibleItems.min(by: { $0.item < $1.item }),
              let attrs = layoutAttributesForItem(at: firstIP) else {
            detachedAnchorIP = nil
            return
        }
        detachedAnchorIP = firstIP
        detachedAnchorScreenY = attrs.frame.origin.y - contentOffset.y
        detachedSavedOffsetY = contentOffset.y
    }

    /// Clear the detached anchor after layout has settled.
    func clearDetachedAnchor() {
        detachedAnchorIP = nil
    }

    // MARK: - contentOffset interception

    /// Intercept ALL contentOffset changes. When an expand/collapse or
    /// detached anchor is active, force the anchored item back to its saved
    /// screen position. This catches UIKit's self-sizing cascade adjustments
    /// that happen AFTER `layoutSubviews()` returns — the compositional
    /// layout re-measures cells one per frame and adjusts contentOffset by
    /// ~6pt each time, creating visible drift that `layoutSubviews()`
    /// interception alone cannot prevent.
    override var contentOffset: CGPoint {
        didSet {
            guard !isApplyingAnchorCorrection else { return }

            #if DEBUG
                let _didSetStart = DispatchTime.now().uptimeNanoseconds
                _debugDidSetEntryCount += 1
                defer {
                    _debugDidSetNanos += DispatchTime.now().uptimeNanoseconds &- _didSetStart
                }
            #endif

            // Expand/collapse anchor takes priority.
            // Defers the correction to the next layoutSubviews instead of
            // writing bounds immediately. This batches N cascade adjustments
            // into 1 layout correction, avoiding the ~55μs UIView.bounds
            // setter on every didSet entry.
            if expandCollapseAnchorIP != nil {
                let delta = contentOffset.y - expandCollapseSavedOffsetY
                guard delta.isFinite, abs(delta) > 0.5 else { return }
                #if DEBUG
                    _debugDidSetCorrectionCount += 1
                #endif
                if pendingCorrectionOffsetY == nil {
                    pendingCorrectionOffsetY = expandCollapseSavedOffsetY
                    setNeedsLayout()
                }
                return
            }

            // Detached anchor: preserve position during self-sizing
            // cascade when new items arrive below the viewport.
            if isDetachedFromBottom, detachedAnchorIP != nil {
                let delta = contentOffset.y - detachedSavedOffsetY
                guard delta.isFinite, abs(delta) > 0.5 else { return }
                #if DEBUG
                    _debugDidSetCorrectionCount += 1
                #endif
                if pendingCorrectionOffsetY == nil {
                    pendingCorrectionOffsetY = detachedSavedOffsetY
                    setNeedsLayout()
                }
            }
        }
    }

    #if DEBUG
        /// Tests cannot drive UIKit drag/deceleration flags directly, so this
        /// override allows deterministic anchoring coverage in unit tests.
        var forceAnchoringForTesting = false

        /// Optional hook to mutate layout state after anchor capture but before
        /// UIKit performs the layout pass. Used to simulate estimated→actual
        /// geometry changes in unit tests.
        var didCaptureAnchorForTesting: (() -> Void)?

        // MARK: - Debug instrumentation for autoresearch benchmarks

        /// Count of contentOffset.didSet invocations that entered the
        /// correction path (did not early-return via isApplyingAnchorCorrection).
        var _debugDidSetEntryCount = 0
        /// Count of contentOffset.didSet invocations that actually applied
        /// a correction (delta > 0.5).
        var _debugDidSetCorrectionCount = 0
        /// Accumulated nanoseconds spent in contentOffset.didSet correction path.
        var _debugDidSetNanos: UInt64 = 0

        /// Count of layoutSubviews passes that captured + restored an anchor.
        var _debugLayoutAnchorCount = 0
        /// Accumulated nanoseconds in captureAnchor + restoreAnchor.
        var _debugLayoutAnchorNanos: UInt64 = 0

        func _debugResetCounters() {
            _debugDidSetEntryCount = 0
            _debugDidSetCorrectionCount = 0
            _debugDidSetNanos = 0
            _debugLayoutAnchorCount = 0
            _debugLayoutAnchorNanos = 0
        }
    #endif

    override func layoutSubviews() {
        if isApplyingAnchorCorrection {
            super.layoutSubviews()
            return
        }

        // Apply deferred correction from contentOffset.didSet before
        // the regular anchor cycle. This batches multiple cascade
        // adjustments into a single contentOffset write.
        if let pending = pendingCorrectionOffsetY {
            pendingCorrectionOffsetY = nil
            isApplyingAnchorCorrection = true
            contentOffset.y = pending
            isApplyingAnchorCorrection = false
        }

        #if DEBUG
            let _captureStart = DispatchTime.now().uptimeNanoseconds
        #endif

        captureAnchor()

        #if DEBUG
            let _captureEnd = DispatchTime.now().uptimeNanoseconds
            didCaptureAnchorForTesting?()
        #endif

        super.layoutSubviews()

        #if DEBUG
            let _restoreStart = DispatchTime.now().uptimeNanoseconds
        #endif

        restoreAnchor()

        // Update the saved "known good" offset after layout restoration.
        // This ensures the contentOffset.didSet has the correct target
        // when UIKit applies post-layout cascade adjustments.
        if expandCollapseAnchorIP != nil {
            expandCollapseSavedOffsetY = contentOffset.y
        }
        if isDetachedFromBottom, detachedAnchorIP != nil {
            detachedSavedOffsetY = contentOffset.y
        }

        #if DEBUG
            _debugLayoutAnchorCount += 1
            _debugLayoutAnchorNanos += (_captureEnd &- _captureStart)
                + (DispatchTime.now().uptimeNanoseconds &- _restoreStart)
        #endif
    }

    // MARK: - Private

    private var shouldAnchorDuringThisPass: Bool {
        // Always anchor when an expand/collapse is in flight.
        if expandCollapseAnchorIP != nil {
            return true
        }

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

        // Prefer the expand/collapse anchor when active — it pins the exact
        // item the user tapped, preventing the header bar from shifting.
        let anchorIP: IndexPath?
        if let ecIP = expandCollapseAnchorIP {
            anchorIP = ecIP
        } else {
            anchorIP = indexPathsForVisibleItems.min(by: { $0.item < $1.item })
        }

        guard let anchorIP, let attrs = layoutAttributesForItem(at: anchorIP) else { return }

        savedAnchorIP = anchorIP
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

        let targetOffsetY = min(max(contentOffset.y + delta, minOffsetY), maxOffsetY)
        guard abs(targetOffsetY - contentOffset.y) > 0.5 else { return }

        isApplyingAnchorCorrection = true
        contentOffset.y = targetOffsetY
        isApplyingAnchorCorrection = false
    }
}
