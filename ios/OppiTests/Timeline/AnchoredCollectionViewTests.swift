import Testing
import UIKit
@testable import Oppi

@Suite("AnchoredCollectionView")
struct AnchoredCollectionViewTests {
    @MainActor
    @Test func anchorCorrectionPreservesScreenPositionWhenCellYShifts() {
        let harness = makeAnchoredHarness(contentHeight: 1_200)

        harness.layout.itemOriginY = 600
        harness.collectionView.contentOffset.y = 580
        harness.collectionView.layoutIfNeeded()
        harness.collectionView.forceAnchoringForTesting = true

        // Simulate estimated -> actual size change above the viewport.
        harness.collectionView.didCaptureAnchorForTesting = {
            harness.collectionView.didCaptureAnchorForTesting = nil
            harness.layout.itemOriginY = 650
            harness.layout.invalidateLayout()
        }
        harness.collectionView.setNeedsLayout()
        harness.collectionView.layoutIfNeeded()
        harness.collectionView.didCaptureAnchorForTesting = nil

        // Anchor should remain at the same on-screen Y, so offset compensates
        // by the same +50pt delta.
        #expect(abs(harness.collectionView.contentOffset.y - 630) < 0.5)
    }

    @MainActor
    @Test func anchorCorrectionClampsToTopBound() {
        let harness = makeAnchoredHarness(contentHeight: 1_200)

        harness.layout.itemOriginY = 10
        harness.collectionView.contentOffset.y = 0
        harness.collectionView.layoutIfNeeded()
        harness.collectionView.forceAnchoringForTesting = true

        // Large upward frame shift would normally push offset negative.
        harness.collectionView.didCaptureAnchorForTesting = {
            harness.collectionView.didCaptureAnchorForTesting = nil
            harness.layout.itemOriginY = -140
            harness.layout.invalidateLayout()
        }
        harness.collectionView.setNeedsLayout()
        harness.collectionView.layoutIfNeeded()

        let minOffsetY = -harness.collectionView.adjustedContentInset.top
        #expect(abs(harness.collectionView.contentOffset.y - minOffsetY) < 0.5)
    }

    @MainActor
    @Test func anchorCorrectionClampsToBottomBound() {
        let harness = makeAnchoredHarness(contentHeight: 1_000)

        harness.layout.itemOriginY = 550
        harness.collectionView.contentOffset.y = 600
        harness.collectionView.layoutIfNeeded()
        harness.collectionView.forceAnchoringForTesting = true

        // Large downward frame shift would normally push offset past max.
        harness.collectionView.didCaptureAnchorForTesting = {
            harness.collectionView.didCaptureAnchorForTesting = nil
            harness.layout.itemOriginY = 820
            harness.layout.invalidateLayout()
        }
        harness.collectionView.setNeedsLayout()
        harness.collectionView.layoutIfNeeded()

        let minOffsetY = -harness.collectionView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            harness.collectionView.contentSize.height
                - harness.collectionView.bounds.height
                + harness.collectionView.adjustedContentInset.bottom
        )
        #expect(abs(harness.collectionView.contentOffset.y - maxOffsetY) < 0.5)
    }
}

@MainActor
private struct AnchoredHarness {
    let window: UIWindow
    let collectionView: AnchoredCollectionView
    let layout: SingleItemLayout
    let dataSource: SingleItemDataSource
}

@MainActor
private func makeAnchoredHarness(contentHeight: CGFloat) -> AnchoredHarness {
    guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first else {
        fatalError("Missing UIWindowScene for AnchoredCollectionViewTests")
    }

    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
    let layout = SingleItemLayout()
    layout.contentHeight = contentHeight

    let collectionView = AnchoredCollectionView(frame: window.bounds, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: SingleItemDataSource.reuseID)

    let dataSource = SingleItemDataSource()
    collectionView.dataSource = dataSource

    window.addSubview(collectionView)
    window.makeKeyAndVisible()

    collectionView.reloadData()
    collectionView.layoutIfNeeded()

    return AnchoredHarness(
        window: window,
        collectionView: collectionView,
        layout: layout,
        dataSource: dataSource
    )
}

@MainActor
private final class SingleItemDataSource: NSObject, UICollectionViewDataSource {
    static let reuseID = "single-cell"

    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

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

@MainActor
private final class SingleItemLayout: UICollectionViewLayout {
    var itemOriginY: CGFloat = 0
    var itemHeight: CGFloat = 100
    var contentHeight: CGFloat = 1_200

    // `AnchoredCollectionView` captures anchor *before* super.layoutSubviews.
    // Keep a prepared value so tests can model old->new geometry transitions
    // across a single layout pass.
    private var preparedItemOriginY: CGFloat = 0

    override func prepare() {
        super.prepare()
        preparedItemOriginY = itemOriginY
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let attributes = layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) else {
            return []
        }
        return attributes.frame.intersects(rect) ? [attributes] : []
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        let width = collectionView?.bounds.width ?? 0
        attributes.frame = CGRect(x: 0, y: preparedItemOriginY, width: width, height: itemHeight)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        true
    }
}
