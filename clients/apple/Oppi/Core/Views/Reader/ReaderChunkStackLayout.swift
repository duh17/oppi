import UIKit

/// The one virtualized chunk layout of the reader's chunked bodies (terminal
/// output, review diffs): items stack top to bottom at their own sizes, and the
/// content keeps the widest item's unwrapped width instead of clamping it to the
/// viewport the way flow layout does.
final class ReaderChunkStackLayout: UICollectionViewLayout {
    var itemSizes: [CGSize] = []

    private var cachedAttributes: [UICollectionViewLayoutAttributes] = []
    private var cachedContentSize: CGSize = .zero

    override func prepare() {
        super.prepare()
        var y: CGFloat = 0
        var width = collectionView?.bounds.width ?? 0
        cachedAttributes = itemSizes.enumerated().map { index, size in
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height
            width = max(width, size.width)
            return attributes
        }
        cachedContentSize = CGSize(width: width, height: y)
    }

    override var collectionViewContentSize: CGSize { cachedContentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        cachedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cachedAttributes.indices.contains(indexPath.item) ? cachedAttributes[indexPath.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size
    }
}
