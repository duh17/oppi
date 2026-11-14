import UIKit

/// The Markdown reader's segment column: items stack top to bottom at the
/// heights the reader's ledger gives, `spacing` apart, inside `contentInsets`,
/// each as wide as the collection less the side insets.
///
/// The heights can change in place. While a gesture owns the viewport the
/// reader swaps no layout, but heights settled for items still below the
/// viewport go in here at once (`updateItemHeights`), so those items arrive on
/// screen at their measured height rather than their estimate.
final class MarkdownReaderStackLayout: UICollectionViewLayout {
    static let contentInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

    let spacing: CGFloat
    private(set) var itemHeights: [CGFloat]

    private var cachedAttributes: [UICollectionViewLayoutAttributes] = []
    private var cachedContentSize: CGSize = .zero

    init(spacing: CGFloat, itemHeights: [CGFloat]) {
        self.spacing = spacing
        self.itemHeights = itemHeights
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updateItemHeights(_ heights: [CGFloat]) {
        guard heights != itemHeights else { return }
        itemHeights = heights
        invalidateLayout()
    }

    override func prepare() {
        super.prepare()
        let insets = Self.contentInsets
        let boundsWidth = collectionView?.bounds.width ?? 0
        let width = max(1, boundsWidth - insets.left - insets.right)
        var y = insets.top
        cachedAttributes = itemHeights.enumerated().map { index, height in
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            let itemHeight = max(1, height)
            attributes.frame = CGRect(x: insets.left, y: y, width: width, height: itemHeight)
            y += itemHeight + spacing
            return attributes
        }
        if !itemHeights.isEmpty { y -= spacing }
        cachedContentSize = CGSize(width: boundsWidth, height: y + insets.bottom)
    }

    override var collectionViewContentSize: CGSize { cachedContentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // Frames are sorted by y: find the first item ending below the top of
        // `rect`, then take items until one starts below its bottom.
        var low = 0
        var high = cachedAttributes.count
        while low < high {
            let mid = (low + high) / 2
            if cachedAttributes[mid].frame.maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        for attributes in cachedAttributes[low...] {
            guard attributes.frame.minY <= rect.maxY else { break }
            if attributes.frame.intersects(rect) { result.append(attributes) }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cachedAttributes.indices.contains(indexPath.item) ? cachedAttributes[indexPath.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.width != newBounds.width
    }
}
