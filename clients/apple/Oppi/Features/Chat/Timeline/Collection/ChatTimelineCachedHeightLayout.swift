import UIKit

// MARK: - Cached-height list layout

/// Single-column timeline layout that stores measured row heights by item id
/// and width so estimated-size invalidation cannot remeasure settled rows.
///
/// Visual metrics match the previous compositional section: 16pt side insets,
/// 8pt section insets, 8pt inter-item spacing, 100pt first-pass estimate.
/// `invalidateLayout()` keeps those cached heights; only a session switch or
/// a font change drops them. A width change keeps the heights of the width
/// before as a second generation (`CachedHeights`), so a resize back to it (a
/// divider toggled, a second rotation) measures no row. Dynamic Type preferred-size updates replace
/// cache entries without a first-pass collapse to the estimate. Preferred-size
/// updates dirty the changed row through the tail so origins below can shift
/// without asking TextKit to size rows above.
@MainActor
final class ChatTimelineCachedHeightLayout: UICollectionViewLayout {
    static let estimatedHeight: CGFloat = 100
    static let interItemSpacing: CGFloat = 8
    static let sectionInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    nonisolated private static let heightMatchTolerance: CGFloat = 1

    /// Horizontal span rows occupy: the timeline's width inside the section
    /// insets, and nothing else. The chat pins the timeline to its safe-area
    /// guide, so a side rail or the iPad trailing column already sits outside
    /// it. The column never reads safe-area insets or the frame's position:
    /// opening the trailing column narrows the timeline inside one layout pass,
    /// and UIKit lays it out once with its new bounds but its old center, while
    /// its own `safeAreaInsets` still held the overlap of its old full-width
    /// frame (520 pt on a 512 pt timeline). Rows measured in the column either
    /// left were the wrong width, and with no column left at all UIKit trapped
    /// in a self-sizing loop. Bounds are set first, so the width is right in
    /// every pass.
    static func rowColumn(boundsWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let section = sectionInsets
        return (section.leading, max(boundsWidth - section.leading - section.trailing, 0))
    }

    private struct CachedHeight {
        var width: CGFloat
        var height: CGFloat
    }

    /// A row's height at the width it was last measured at, and at the width
    /// before that: two generations, so a width that comes back finds its
    /// heights.
    private struct CachedHeights {
        var latest: CachedHeight
        var previous: CachedHeight?

        func height(atWidth width: CGFloat) -> CGFloat? {
            if abs(latest.width - width) <= 0.5 { return latest.height }
            if let previous, abs(previous.width - width) <= 0.5 { return previous.height }
            return nil
        }

        /// A guess at `width` with no height measured there: the latest
        /// height scaled by the width ratio, as wrapped text grows when its
        /// column narrows. Closer than the flat estimate, so the content size
        /// barely jumps when the row is measured.
        func scaledEstimate(atWidth width: CGFloat) -> CGFloat {
            (latest.height * latest.width / max(width, 1)).rounded()
        }

        /// A measurement at `width`. Another height at the latest width means
        /// the content changed, so the other width's height is stale too.
        mutating func record(_ height: CGFloat, atWidth width: CGFloat) {
            if abs(latest.width - width) <= 0.5 {
                if abs(latest.height - height) > ChatTimelineCachedHeightLayout.heightMatchTolerance { previous = nil }
                latest.height = height
            } else if let previous, abs(previous.width - width) <= 0.5 {
                self.previous = latest
                latest = CachedHeight(width: width, height: height)
                if abs(previous.height - height) > ChatTimelineCachedHeightLayout.heightMatchTolerance { self.previous = nil }
            } else {
                previous = latest
                latest = CachedHeight(width: width, height: height)
            }
        }
    }

    private var cachedHeightByItemID: [String: CachedHeights] = [:]
    /// When the reflow that follows a width change is over. Until then a row
    /// with a height at this width, from this reflow or the width before
    /// last, takes it (`unmeasuredHeight`). UIKit asks a cell for its size
    /// more than once in a reflow (each resized row moves the origins below
    /// and is asked again), and a rotation asks a few run-loop turns after the
    /// pass that changed the width. A data change ends it at once, so changed
    /// rows measure; a row that changes its own size within the window (no
    /// snapshot) keeps its height until it is asked again.
    private var reflowEndsAt: CFTimeInterval = 0
    private static let reflowWindow: CFTimeInterval = 0.5
    private var isReflowingWidth: Bool { CACurrentMediaTime() < reflowEndsAt }
    private var liveTailItemIDs: Set<String> = []
    private var attributesByIndex: [UICollectionViewLayoutAttributes] = []
    private var contentSize: CGSize = .zero
    private var lastLayoutWidth: CGFloat = 0

    func setLiveTailItemIDs(_ itemIDs: Set<String>) {
        liveTailItemIDs = itemIDs
    }

    func removeAllCachedHeights() {
        cachedHeightByItemID.removeAll(keepingCapacity: true)
    }

    func removeCachedHeights(for itemIDs: Set<String>) {
        guard !itemIDs.isEmpty else { return }
        for itemID in itemIDs {
            cachedHeightByItemID.removeValue(forKey: itemID)
        }
    }

    /// Set while a divider beside the chat moves (`PaneLiveResizing`): the
    /// timeline keeps its width, but extends under the pane beside it, so its
    /// safe area changes every frame. UIKit answers each change with a plain
    /// invalidation and a self-sizing pass over the visible cells, which would
    /// lay the rows out on every frame though nothing they show moved. Held,
    /// plain invalidations wait for the release, and rows take the heights
    /// they already have.
    var isHeldForLiveResize = false {
        didSet {
            guard !isHeldForLiveResize, oldValue, hasDeferredInvalidation else { return }
            hasDeferredInvalidation = false
            invalidateLayout()
        }
    }
    private var hasDeferredInvalidation = false
    /// The next `prepare` follows a data change (`ChatTimelinePerf.contentRebuildCount`).
    private var rebuildIsForDataChange = false
    /// An invalidation reached this layout since its last rebuild. A held
    /// timeline's collection view still calls `prepare` on its own (its
    /// safe area moves under the pane, and it re-asks its cells for their
    /// sizes) after every invalidation here waited; with none landed and the
    /// width unchanged, the frames it has are the frames it would build.
    private var hasLandedInvalidation = true

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        // Only geometry-free invalidations wait: a snapshot apply (data source
        // counts), a resized row (items), or a scroll adjustment still lands now.
        if isHeldForLiveResize, !context.invalidateEverything, !context.invalidateDataSourceCounts,
           context.invalidatedItemIndexPaths?.isEmpty ?? true,
           context.contentOffsetAdjustment == .zero, context.contentSizeAdjustment == .zero {
            hasDeferredInvalidation = true
            return
        }
        if context.invalidateDataSourceCounts {
            rebuildIsForDataChange = true
            reflowEndsAt = 0
        }
        hasLandedInvalidation = true
        super.invalidateLayout(with: context)
    }

    /// The height a cell at `indexPath` may take without measuring: the one its
    /// row has at `width`, while held or in the reflow after a width change. A
    /// live tail row is still being written, so it always measures.
    func unmeasuredHeight(at indexPath: IndexPath, width: CGFloat) -> CGFloat? {
        guard indexPath.section == 0, let itemID = itemIdentifier(at: indexPath.item),
              !liveTailItemIDs.contains(itemID) else { return nil }
        guard isReflowingWidth || isHeldForLiveResize else { return nil }
        return cachedHeightByItemID[itemID]?.height(atWidth: width)
    }

    #if DEBUG
        func cachedHeightForTesting(itemID: String) -> CGFloat? {
            cachedHeightByItemID[itemID]?.latest.height
        }
    #endif

    override var collectionViewContentSize: CGSize { contentSize }

    override func prepare() {
        super.prepare()
        if isHeldForLiveResize, !hasLandedInvalidation,
           let collectionView, abs(collectionView.bounds.width - lastLayoutWidth) <= 0.5 {
            return
        }
        hasLandedInvalidation = false
        ChatTimelinePerf.recordLayoutRebuild(forDataChange: rebuildIsForDataChange)
        rebuildIsForDataChange = false
        rebuildAttributes()
    }

    override func layoutAttributesForElements(
        in rect: CGRect
    ) -> [UICollectionViewLayoutAttributes]? {
        attributesByIndex.compactMap { attributes in
            guard attributes.frame.intersects(rect) else { return nil }
            return copyAttributes(attributes)
        }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0,
              indexPath.item >= 0,
              indexPath.item < attributesByIndex.count else {
            return nil
        }
        return copyAttributes(attributesByIndex[indexPath.item])
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        abs(newBounds.width - lastLayoutWidth) > 0.5
    }

    override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        guard preferredAttributes.representedElementCategory == .cell else { return false }
        let preferredHeight = preferredAttributes.size.height
        guard preferredHeight.isFinite, preferredHeight > 0 else { return false }

        let index = originalAttributes.indexPath.item
        let width = originalAttributes.size.width
        let resolved = resolvedHeight(
            at: index,
            width: width,
            preferredHeight: preferredHeight,
            store: false
        )
        // Compare against the cache, not the estimate still sitting in
        // `originalAttributes`. Re-invalidating 100 → 250 after the cache
        // already stores 250 loops layout forever.
        if let itemID = itemIdentifier(at: index),
           let cached = cachedHeightByItemID[itemID]?.height(atWidth: width),
           abs(resolved - cached) <= Self.heightMatchTolerance {
            return false
        }
        if abs(resolved - originalAttributes.size.height) <= Self.heightMatchTolerance {
            _ = resolvedHeight(
                at: index,
                width: width,
                preferredHeight: preferredHeight,
                store: true
            )
            return false
        }
        return true
    }

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes
        )
        let index = originalAttributes.indexPath.item
        let resolved = resolvedHeight(
            at: index,
            width: originalAttributes.size.width,
            preferredHeight: preferredAttributes.size.height,
            store: true
        )
        let delta = resolved - originalAttributes.size.height
        if delta.isFinite {
            context.contentSizeAdjustment = CGSize(width: 0, height: delta)
        }
        if let collectionView, delta.isFinite, abs(delta) > Self.heightMatchTolerance {
            let firstVisibleItem = collectionView.indexPathsForVisibleItems
                .min { $0.item < $1.item }?.item
            // Rows at or above the first visible item change content above
            // the viewport. Shift offset so the reading position stays.
            let followsReadingPosition = firstVisibleItem.map {
                originalAttributes.indexPath.item <= $0
            } ?? false
            if followsReadingPosition {
                context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
            } else if delta > 0, shouldFollowAttachedLiveTail(in: collectionView, growth: delta) {
                // Attached live tail: the growing thinking/assistant/tool row
                // is below the first visible item, so reading-position follow
                // does not run. Keep the working indicator from falling into
                // the composer during in-place height growth. Never follow
                // shrinks (upward busy jitter), detached readers, or a
                // default-attached view that is not actually on the tail.
                context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
            }
        }

        let itemCount = collectionView?.numberOfItems(inSection: 0) ?? 0
        guard itemCount > index else {
            context.invalidateItems(at: [originalAttributes.indexPath])
            return context
        }
        // Origins below the changed row shift. Heights of those rows stay
        // cached so this does not re-run TextKit on settled content.
        let tail = (index..<itemCount).map { IndexPath(item: $0, section: 0) }
        context.invalidateItems(at: tail)
        return context
    }

    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForItem(at: itemIndexPath)
    }

    override func finalLayoutAttributesForDisappearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForItem(at: itemIndexPath)
    }

    private func rebuildAttributes() {
        guard let collectionView else {
            attributesByIndex = []
            contentSize = .zero
            return
        }

        let width = collectionView.bounds.width
        let widthChanged = abs(width - lastLayoutWidth) > 0.5
        if widthChanged, lastLayoutWidth > 1 {
            reflowEndsAt = CACurrentMediaTime() + Self.reflowWindow
        }
        lastLayoutWidth = width

        let column = Self.rowColumn(boundsWidth: width)
        // No column, no rows: a height measured at no width is never cached
        // (`resolvedHeight`), so a row laid out there re-measures every pass
        // and UIKit traps in a self-sizing loop.
        guard width > 1, column.width > 1 else {
            attributesByIndex = []
            contentSize = .zero
            return
        }

        let sectionCount = collectionView.numberOfSections
        let itemCount = sectionCount > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        let insets = Self.sectionInsets
        let itemWidth = column.width
        var y = insets.top
        var nextAttributes: [UICollectionViewLayoutAttributes] = []
        nextAttributes.reserveCapacity(itemCount)
        var liveIDs: Set<String> = []
        liveIDs.reserveCapacity(itemCount)

        for index in 0..<itemCount {
            let indexPath = IndexPath(item: index, section: 0)
            let itemID = itemIdentifier(at: index)
            if let itemID {
                liveIDs.insert(itemID)
            }
            let height: CGFloat
            if let itemID, let cached = cachedHeightByItemID[itemID] {
                if let measured = cached.height(atWidth: itemWidth) {
                    height = measured
                } else {
                    height = cached.scaledEstimate(atWidth: itemWidth)
                }
            } else {
                height = Self.estimatedHeight
            }
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = CGRect(x: column.x, y: y, width: itemWidth, height: height)
            nextAttributes.append(attributes)
            y += height
            if index < itemCount - 1 {
                y += Self.interItemSpacing
            }
        }
        y += insets.bottom
        attributesByIndex = nextAttributes
        contentSize = CGSize(width: width, height: max(y, 0))

        if itemCount > 0, cachedHeightByItemID.count > liveIDs.count {
            cachedHeightByItemID = cachedHeightByItemID.filter { liveIDs.contains($0.key) }
        }
    }

    private func shouldFollowAttachedLiveTail(
        in collectionView: UICollectionView,
        growth: CGFloat
    ) -> Bool {
        if let anchored = collectionView as? AnchoredCollectionView,
           anchored.isDetachedFromBottom {
            return false
        }
        // `isDetachedFromBottom` defaults to false and is also cleared around
        // restore/expand layout. Only chase growth when the offset is already
        // on the live tail, using either pre- or post-adjustment contentSize.
        return isOffsetNearLiveTail(in: collectionView, growth: growth)
    }

    private func isOffsetNearLiveTail(
        in collectionView: UICollectionView,
        growth: CGFloat
    ) -> Bool {
        let insets = collectionView.adjustedContentInset
        let minOffsetY = -insets.top
        let rawMaxY = collectionView.contentSize.height
            - collectionView.bounds.height
            + insets.bottom
        let maxOffsetY = max(minOffsetY, rawMaxY)
        let maxOffsetBeforeGrowth = max(minOffsetY, rawMaxY - growth)
        let offsetY = collectionView.contentOffset.y
        let threshold: CGFloat = 32
        return abs(offsetY - maxOffsetY) <= threshold
            || abs(offsetY - maxOffsetBeforeGrowth) <= threshold
    }

    private func resolvedHeight(
        at index: Int,
        width: CGFloat,
        preferredHeight: CGFloat,
        store: Bool
    ) -> CGFloat {
        var height = preferredHeight
        let itemID = itemIdentifier(at: index)
        if let itemID,
           liveTailItemIDs.contains(itemID),
           let cached = cachedHeightByItemID[itemID]?.height(atWidth: width) {
            height = max(cached, preferredHeight)
        }
        if store, let itemID, width > 1, height.isFinite, height > 0 {
            if cachedHeightByItemID[itemID] == nil {
                cachedHeightByItemID[itemID] = CachedHeights(latest: CachedHeight(width: width, height: height))
            } else {
                cachedHeightByItemID[itemID]?.record(height, atWidth: width)
            }
        }
        return height
    }

    private func itemIdentifier(at index: Int) -> String? {
        guard let collectionView,
              let dataSource = collectionView.dataSource as? UICollectionViewDiffableDataSource<Int, String> else {
            return nil
        }
        return dataSource.itemIdentifier(for: IndexPath(item: index, section: 0))
    }

    private func copyAttributes(
        _ attributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes? {
        attributes.copy() as? UICollectionViewLayoutAttributes
    }
}
