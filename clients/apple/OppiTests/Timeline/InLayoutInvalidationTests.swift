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
