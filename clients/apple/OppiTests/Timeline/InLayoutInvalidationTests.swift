import Testing
import UIKit
@testable import Oppi

/// Build 49 SIGABRT: NativeMarkdownImageView consumed a prepared raster during
/// cell configuration inside `AnchoredCollectionView.layoutSubviews`, then
/// `forceInvalidateEnclosingCollectionViewLayout` called `invalidateLayout`
/// on a collection view that was already laying out.
@Suite("Collection layout invalidation during layout")
@MainActor
struct InLayoutInvalidationTests {
    @Test func forceInvalidateDuringLayoutDoesNotCallInvalidateLayoutUntilLayoutEnds() async {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 390, height: 50)
        layout.minimumLineSpacing = 0
        let collectionView = AnchoredCollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 400),
            collectionViewLayout: layout
        )
        let dataSource = SingleCellDataSource()
        collectionView.register(
            UICollectionViewCell.self,
            forCellWithReuseIdentifier: SingleCellDataSource.reuseID
        )
        collectionView.dataSource = dataSource

        let source = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let host = UIViewController()
        host.view.addSubview(collectionView)
        collectionView.addSubview(source)

        let window = UIWindow(frame: collectionView.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        collectionView.reloadData()
        host.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        let baseline = ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
            collectionView
        )
        var invalidationsDuringLayout = -1
        var probedDuringLayout = false

        collectionView.didCaptureAnchorForTesting = { [weak collectionView, weak source] in
            guard let collectionView, let source else { return }
            collectionView.didCaptureAnchorForTesting = nil
            probedDuringLayout = true
            let before = ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            )
            ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
                startingAt: source
            )
            invalidationsDuringLayout =
                ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                    collectionView
                ) - before
        }

        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()

        #expect(probedDuringLayout, "layoutSubviews never reached the in-layout probe")
        #expect(
            invalidationsDuringLayout == 0,
            "force-invalidate must not call invalidateLayout while the collection view is laying out"
        )

        await drainMainQueue()
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            ) == baseline + 1,
            "the skipped in-layout invalidate must run after layout ends so image height can still settle"
        )
    }

    @Test func forceInvalidateOutsideLayoutStillInvalidatesImmediately() {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 390, height: 50)
        let collectionView = AnchoredCollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 400),
            collectionViewLayout: layout
        )
        let source = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        collectionView.addSubview(source)
        collectionView.layoutIfNeeded()
        #expect(!collectionView.isPerformingLayout)

        let baseline = ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
            collectionView
        )
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
            startingAt: source
        )
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            ) == baseline + 1,
            "force-invalidate must remain synchronous when the collection view is not laying out"
        )
    }

    /// Build 51 escaped the layoutSubviews guard: markdown image height can
    /// publish from the diffable provider while UIKit provisions a cell.
    @Test func markdownImageHeightPublicationDefersAcrossCellProvisioning() async throws {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 390, height: 100)
        layout.minimumLineSpacing = 0
        let collectionView = AnchoredCollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 400),
            collectionViewLayout: layout
        )

        var shouldPublishImageHeight = false
        var synchronousInvalidationCount = -1
        var didClearStreamingHeightCache = false
        var publishedWhilePerformingLayout = true
        weak var recycledImageView: NativeMarkdownImageView?
        let registration = UICollectionView.CellRegistration<SafeSizingCell, String> { cell, _, _ in
            guard shouldPublishImageHeight else { return }

            let imageView = NativeMarkdownImageView()
            cell.contentView.addSubview(imageView)
            cell.cachedStreamingHeight = 999
            let before = ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            )

            publishedWhilePerformingLayout = collectionView.isPerformingLayout
            // Placeholder height is 160pt; both values must differ so two
            // publications actually run and can coalesce.
            imageView.debugSetDisplayHeightForTesting(180)
            imageView.debugSetDisplayHeightForTesting(140)

            synchronousInvalidationCount =
                ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                    collectionView
                ) - before
            didClearStreamingHeightCache = cell.cachedStreamingHeight == nil
            recycledImageView = imageView
            imageView.removeFromSuperview()
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, itemID in
            collectionView.dequeueConfiguredReusableCell(
                using: registration,
                for: indexPath,
                item: itemID
            )
        }

        let host = UIViewController()
        host.view.addSubview(collectionView)
        let window = UIWindow(frame: collectionView.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let itemIDs = (0..<30).map { "item-\($0)" }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(itemIDs)
        await dataSource.apply(snapshot, animatingDifferences: false)
        host.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(
            at: IndexPath(item: 10, section: 0),
            at: .top,
            animated: false
        )
        collectionView.layoutIfNeeded()
        collectionView.isDetachedFromBottom = true
        collectionView.captureDetachedAnchor()
        #expect(collectionView.detachedAnchorIsActive)

        let offsetBefore = collectionView.contentOffset.y
        let baseline = ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
            collectionView
        )
        let visibleItemID = try #require(
            collectionView.indexPathsForVisibleItems
                .sorted(by: { $0.item < $1.item })
                .compactMap { dataSource.itemIdentifier(for: $0) }
                .first
        )

        shouldPublishImageHeight = true
        snapshot.reconfigureItems([visibleItemID])
        await dataSource.apply(snapshot, animatingDifferences: false)

        #expect(
            !publishedWhilePerformingLayout,
            "Build 51 publishes during cell provisioning, after isPerformingLayout is already false"
        )
        #expect(synchronousInvalidationCount == 0)
        #expect(didClearStreamingHeightCache)
        #expect(recycledImageView == nil, "The queued invalidation retained a recycled image view")

        await drainMainQueue()
        await drainMainQueue()
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            ) == baseline + 1,
            "Two image height publications must coalesce into one eventual remeasurement"
        )
        #expect(abs(collectionView.contentOffset.y - offsetBefore) < 1)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class SingleCellDataSource: NSObject, UICollectionViewDataSource {
    static let reuseID = "during-layout-cell"

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        1
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseID, for: indexPath)
    }
}
