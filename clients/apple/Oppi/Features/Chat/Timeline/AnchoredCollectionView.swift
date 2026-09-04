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

    /// `applyOffsetCorrection` owns the viewport until the next identity
    /// capture. Follow-up layout passes re-apply this Y so self-sizing
    /// cannot walk the offset back toward the pre-scroll position.
    private var frozenOffsetY: CGFloat?

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
    ///
    /// `expandCollapseAnchorItemID` is the stable identity for that row.
    /// A structural snapshot can shift index paths before deferred
    /// remeasurement, so layout and remeasure resolve through the ID.
    /// If that captured ID disappears, the pin expires instead of falling
    /// back to a stale index path.
    private(set) var expandCollapseAnchorIP: IndexPath?
    private(set) var expandCollapseAnchorItemID: String?

    /// Each `setExpandCollapseAnchor` starts a generation. Deferred cleanup
    /// compares this token so generation N cannot clear generation N+1.
    private(set) var expandCollapseAnchorGeneration: UInt64 = 0

    /// The screen-relative Y of the anchored item at the time the anchor
    /// was set. Used by `contentOffset.didSet` to force-restore position
    /// when UIKit adjusts contentOffset outside of `layoutSubviews()`.
    private var expandCollapseAnchorScreenY: CGFloat = 0

    /// Pin a specific item's screen position across expand/collapse layout
    /// passes. Uses top-edge (origin.y) for the deferred anchor because
    /// origin.y is stable across self-sizing cascade passes (only height
    /// changes during re-estimation, not origin).
    @discardableResult
    func setExpandCollapseAnchor(indexPath: IndexPath) -> UInt64 {
        expandCollapseAnchorGeneration &+= 1
        expandCollapseAnchorIP = indexPath
        expandCollapseAnchorItemID = stableItemID(at: indexPath)
        expandCollapseSavedOffsetY = contentOffset.y
        if let attrs = layoutAttributesForItem(at: indexPath) {
            expandCollapseAnchorScreenY = attrs.frame.origin.y - contentOffset.y
        }
        return expandCollapseAnchorGeneration
    }

    /// Clear the expand/collapse anchor after layout passes have settled.
    /// User-scroll and identity-removal paths call this unconditionally.
    func clearExpandCollapseAnchor() {
        expandCollapseAnchorIP = nil
        expandCollapseAnchorItemID = nil
        pendingCorrectionOffsetY = nil
    }

    /// Deferred expand/collapse hops must only clear their own generation.
    /// Returns whether this generation was still current and the pin was dropped.
    @discardableResult
    func clearExpandCollapseAnchor(generation: UInt64) -> Bool {
        guard expandCollapseAnchorGeneration == generation,
              expandCollapseAnchorIP != nil || expandCollapseAnchorItemID != nil else {
            return false
        }
        clearExpandCollapseAnchor()
        return true
    }

    /// A captured stable ID that has left the timeline must not retarget the
    /// row that now occupies the stale index path.
    func expireExpandCollapseAnchorIfIdentityMissing() {
        guard let expandCollapseAnchorItemID else { return }
        if timelineItemIDs().contains(expandCollapseAnchorItemID) { return }
        clearExpandCollapseAnchor()
    }

    /// Apply an absolute contentOffset.y correction while suppressing the
    /// didSet interceptor and any internal layout passes that UIKit
    /// triggers when setting contentOffset on a UICollectionView.
    func applyOffsetCorrection(_ targetOffsetY: CGFloat, freezeUntilCapture: Bool = false) {
        // An explicit offset owns the viewport. Drop any deferred cascade
        // restore so the next layoutSubviews cannot replay the old Y.
        pendingCorrectionOffsetY = nil
        frozenOffsetY = freezeUntilCapture ? targetOffsetY : nil
        isApplyingAnchorCorrection = true
        contentOffset.y = targetOffsetY
        isApplyingAnchorCorrection = false
    }

    // MARK: - Detached anchor

    /// Anchors a stable timeline item during snapshot applies when the user
    /// is scrolled away from the bottom. Counteracts the self-sizing cascade
    /// from `UICollectionViewCompositionalLayout` which adjusts contentOffset
    /// outside `layoutSubviews()` as cells report their preferred sizes.
    ///
    /// Identity matters more than the raw first-visible index path: a windowed
    /// suffix can insert/drop rows above the reader, so the same index path
    /// may point at a different item on the next apply.
    private var detachedAnchorIP: IndexPath?
    private var detachedAnchorItemID: String?
    private var detachedAnchorScreenY: CGFloat = 0

    /// Whether a detached anchor is currently captured.
    var detachedAnchorIsActive: Bool { detachedAnchorIP != nil || detachedAnchorItemID != nil }

    /// Capture the detached anchor for subsequent contentOffset corrections.
    /// Called before snapshot apply when the user is scrolled away from bottom.
    func captureDetachedAnchor() {
        frozenOffsetY = nil
        // Isolated test fixtures host this view without a timeline
        // controller. Keep the first-visible index-path pin so their
        // self-sizing cascade coverage still works.
        if timelineItemIDs().isEmpty {
            guard let firstIP = indexPathsForVisibleItems.min(by: { $0.item < $1.item }),
                  let attrs = layoutAttributesForItem(at: firstIP) else {
                detachedAnchorIP = nil
                detachedAnchorItemID = nil
                return
            }
            detachedAnchorIP = firstIP
            detachedAnchorItemID = nil
            detachedAnchorScreenY = attrs.frame.origin.y - contentOffset.y
            detachedSavedOffsetY = contentOffset.y
            return
        }

        let visibleRect = CGRect(origin: contentOffset, size: bounds.size)
        let candidate = indexPathsForVisibleItems
            .compactMap { indexPath -> (indexPath: IndexPath, attributes: UICollectionViewLayoutAttributes, itemID: String)? in
                guard let attributes = layoutAttributesForItem(at: indexPath),
                      attributes.frame.intersects(visibleRect),
                      let itemID = stableItemID(at: indexPath) else {
                    return nil
                }
                return (indexPath, attributes, itemID)
            }
            .min { $0.attributes.frame.minY < $1.attributes.frame.minY }

        guard let candidate else {
            detachedAnchorIP = nil
            detachedAnchorItemID = nil
            return
        }
        detachedAnchorIP = candidate.indexPath
        detachedAnchorItemID = candidate.itemID
        detachedAnchorScreenY = candidate.attributes.frame.origin.y - contentOffset.y
        detachedSavedOffsetY = contentOffset.y
    }

    /// Transfer a captured derived-row identity before a snapshot replaces
    /// it. The saved screen Y stays unchanged, so the replacement row takes
    /// over the detached viewport anchor without becoming timeline state.
    func remapDetachedAnchorItemID(using replacements: [String: String]) {
        guard let detachedAnchorItemID,
              let replacementID = replacements[detachedAnchorItemID] else {
            return
        }
        self.detachedAnchorItemID = replacementID
    }

    /// Compositional layout can expose the replacement's final frame only
    /// after the snapshot's first layout pass. Reapply the captured screen Y
    /// once that geometry exists so a page prepend cannot leave one-frame or
    /// settled drift behind.
    func restoreRemappedDetachedAnchorPosition() {
        guard isDetachedFromBottom,
              let indexPath = currentDetachedAnchorIndexPath(),
              let attributes = layoutAttributesForItem(at: indexPath) else {
            return
        }

        let minOffsetY = -adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )
        let targetOffsetY = min(
            max(attributes.frame.minY - detachedAnchorScreenY, minOffsetY),
            maxOffsetY
        )
        guard targetOffsetY.isFinite,
              abs(targetOffsetY - contentOffset.y) > 0.5 else {
            return
        }
        applyOffsetCorrection(targetOffsetY)
        detachedSavedOffsetY = contentOffset.y
    }

    // periphery:ignore - used by TimelineLifecycleBench via @testable import
    /// Clear the detached anchor after layout has settled.
    func clearDetachedAnchor() {
        detachedAnchorIP = nil
        detachedAnchorItemID = nil
        frozenOffsetY = nil
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
            // Fast guards — avoid all work when no correction needed.
            guard !isApplyingAnchorCorrection else { return }
            guard pendingCorrectionOffsetY == nil else { return }

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
            expireExpandCollapseAnchorIfIdentityMissing()
            if expandCollapseAnchorIP != nil {
                let delta = contentOffset.y - expandCollapseSavedOffsetY
                guard delta.isFinite, abs(delta) > 0.5 else { return }
                #if DEBUG
                    _debugDidSetCorrectionCount += 1
                #endif
                pendingCorrectionOffsetY = expandCollapseSavedOffsetY
                setNeedsLayout()
                return
            }

            // Detached anchor: preserve position during self-sizing
            // cascade when new items arrive below the viewport.
            // UIKit's display-link-driven cell sizing adjusts contentOffset
            // by ~6pt per frame — these per-frame adjustments are NOT caught
            // by layoutSubviews alone because they happen AFTER the layout
            // pass returns. The deferred correction batches them into a
            // single layoutSubviews correction.
            //
            // Skip during user-driven scroll — the gesture is intentional
            // and layoutSubviews anchoring handles it via captureAnchor/
            // restoreAnchor. Without this guard the didSet fights the
            // user's finger and locks scrolling in place.
            //
            // When an item identity is captured, do not replay the raw
            // pre-apply offset. A suffix-window shift changes content above
            // the reader; layoutSubviews must restore that item's screen Y.
            if isDetachedFromBottom, detachedAnchorIsActive,
               frozenOffsetY == nil,
               !isUserOrProgrammaticScrollOwned {
                let delta = contentOffset.y - detachedSavedOffsetY
                guard delta.isFinite, abs(delta) > 0.5 else { return }
                if detachedAnchorItemID != nil {
                    #if DEBUG
                        _debugDidSetCorrectionCount += 1
                    #endif
                    setNeedsLayout()
                    return
                }
                #if DEBUG
                    _debugDidSetCorrectionCount += 1
                #endif
                pendingCorrectionOffsetY = detachedSavedOffsetY
                setNeedsLayout()
            }
        }
    }

    #if DEBUG
        /// Tests cannot drive UIKit drag/deceleration flags directly, so this
        /// override allows deterministic anchoring coverage in unit tests.
        var forceAnchoringForTesting = false

        /// Tests cannot start a real pan recognizer, so these flags let a
        /// harness drive the same `isTracking` / `isDragging` / `isDecelerating`
        /// paths the scroll delegate uses for user-owned follow detach.
        var testIsTracking = false
        var testIsDragging = false
        var testIsDecelerating = false

        override var isTracking: Bool {
            testIsTracking || super.isTracking
        }

        override var isDragging: Bool {
            testIsDragging || super.isDragging
        }

        override var isDecelerating: Bool {
            testIsDecelerating || super.isDecelerating
        }

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

        expireExpandCollapseAnchorIfIdentityMissing()

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
        if isDetachedFromBottom, detachedAnchorIsActive {
            if let identityIP = currentDetachedAnchorIndexPath() {
                detachedAnchorIP = identityIP
                if isUserOrProgrammaticScrollOwned,
                   let attrs = layoutAttributesForItem(at: identityIP) {
                    // User-owned movement must refresh the sticky Y. Otherwise
                    // the next passive apply snaps back to the pre-drag screen.
                    detachedAnchorScreenY = attrs.frame.origin.y - contentOffset.y
                }
            } else if detachedAnchorItemID != nil {
                detachedAnchorItemID = nil
                detachedAnchorIP = nil
            }
            detachedSavedOffsetY = contentOffset.y
        }

        if expandCollapseAnchorIP == nil,
           let frozenOffsetY,
           abs(contentOffset.y - frozenOffsetY) > 0.5 {
            isApplyingAnchorCorrection = true
            contentOffset.y = frozenOffsetY
            isApplyingAnchorCorrection = false
        }

        #if DEBUG
            _debugLayoutAnchorCount += 1
            _debugLayoutAnchorNanos += (_captureEnd &- _captureStart)
                + (DispatchTime.now().uptimeNanoseconds &- _restoreStart)
        #endif
    }

    // MARK: - Private

    private func timelineItemIDs() -> [String] {
        (delegate as? ChatTimelineCollectionHost.Controller)?.currentIDs ?? []
    }

    private func stableItemID(at indexPath: IndexPath) -> String? {
        let itemIDs = timelineItemIDs()
        guard indexPath.item >= 0, indexPath.item < itemIDs.count else { return nil }
        let itemID = itemIDs[indexPath.item]
        if itemID == ChatTimelineCollectionHost.loadMoreID
            || itemID == ChatTimelineCollectionHost.workingIndicatorID {
            return nil
        }
        return itemID
    }

    private var isUserOrProgrammaticScrollOwned: Bool {
        // Only real gestures. `isScrollAnimating` is also true during some
        // snapshot/layout passes, which would disable the detached identity
        // pin and let tool appends shove the reader again.
        isTracking || isDragging || isDecelerating
    }

    private func currentExpandCollapseAnchorIndexPath() -> IndexPath? {
        if let expandCollapseAnchorItemID {
            guard let index = timelineItemIDs().firstIndex(of: expandCollapseAnchorItemID) else {
                return nil
            }
            return IndexPath(item: index, section: 0)
        }
        return expandCollapseAnchorIP
    }

    private func currentDetachedAnchorIndexPath() -> IndexPath? {
        if let detachedAnchorItemID {
            let controller = delegate as? ChatTimelineCollectionHost.Controller
            guard let renderedID = controller?.renderedID(forFullTimelineItemID: detachedAnchorItemID),
                  let index = timelineItemIDs().firstIndex(of: renderedID) else {
                return nil
            }
            // Once a derived Quiet row is replaced, continue anchoring its
            // current presentation identity rather than retaining a one-apply
            // bridge to the prior synthetic ID.
            if renderedID != detachedAnchorItemID {
                self.detachedAnchorItemID = renderedID
            }
            return IndexPath(item: index, section: 0)
        }
        return detachedAnchorIP
    }

    private var shouldAnchorDuringThisPass: Bool {
        // Always anchor when an expand/collapse is in flight.
        if expandCollapseAnchorIP != nil || expandCollapseAnchorItemID != nil {
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
        // Skip while an explicit offset correction is in charge; a later
        // captureDetachedAnchor() re-enables the pin for snapshot applies.
        return isDetachedFromBottom && frozenOffsetY == nil
    }

    private func captureAnchor() {
        savedAnchorIP = nil

        guard shouldAnchorDuringThisPass else { return }

        // Prefer the expand/collapse anchor when active — it pins the exact
        // item the user tapped, preventing the header bar from shifting.
        // When detached, prefer the captured item identity so a suffix-window
        // shift cannot retarget the first-visible index path mid-apply.
        let anchorIP: IndexPath?
        if let identityIP = currentExpandCollapseAnchorIndexPath() {
            expandCollapseAnchorIP = identityIP
            anchorIP = identityIP
        } else if isDetachedFromBottom, let identityIP = currentDetachedAnchorIndexPath() {
            anchorIP = identityIP
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

        // Sticky identity Y is only for passive/ambient layout. During a
        // user-owned drag it would fight the finger and lock the viewport.
        let identityIP = currentDetachedAnchorIndexPath()
        let targetScreenY = (!isUserOrProgrammaticScrollOwned
            && isDetachedFromBottom
            && detachedAnchorItemID != nil
            && savedAnchorIP == identityIP)
            ? detachedAnchorScreenY
            : savedAnchorScreenY
        let newScreenY = newAttrs.frame.origin.y - contentOffset.y
        let delta = newScreenY - targetScreenY

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
