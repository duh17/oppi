import Testing
import UIKit
@testable import Oppi

@Suite("Timeline offset controller policy")
@MainActor
struct TimelineOffsetControllerTests {
    @Test func attachedAmbientCorrectionAppliesAndClampsToLegalRange() {
        let (collectionView, scrollController) = makeOffsetPolicyFixture()
        scrollController.updateNearBottom(true)

        let didApply = TimelineOffsetController.apply(
            targetOffsetY: 10_000,
            reason: .idleBottomSettle,
            collectionView: collectionView,
            scrollController: scrollController
        )

        #expect(didApply)
        #expect(collectionView.contentOffset.y == timelineConformanceMaxOffsetY(collectionView))
    }

    @Test func ambientCorrectionRefusesWhenDetached() {
        let (collectionView, scrollController) = makeOffsetPolicyFixture(startingOffsetY: 120)
        scrollController.detachFromBottomForUserScroll()

        let didApply = TimelineOffsetController.apply(
            targetOffsetY: 360,
            reason: .liveTailVisibility,
            collectionView: collectionView,
            scrollController: scrollController
        )

        #expect(!didApply)
        #expect(collectionView.contentOffset.y == 120)
    }

    @Test func programmaticTopAlignmentCanApplyWhileDetached() {
        let (collectionView, scrollController) = makeOffsetPolicyFixture(startingOffsetY: 120)
        scrollController.detachFromBottomForUserScroll()

        let didApply = TimelineOffsetController.apply(
            targetOffsetY: 420,
            reason: .programmaticTopAlign,
            collectionView: collectionView,
            scrollController: scrollController
        )

        #expect(didApply)
        #expect(collectionView.contentOffset.y == 420)
    }

    @Test func userInteractionBlocksOuterOffsetCorrections() {
        let (collectionView, scrollController) = makeOffsetPolicyFixture(startingOffsetY: 120)
        collectionView.testIsDragging = true
        scrollController.updateNearBottom(true)

        let ambientApplied = TimelineOffsetController.apply(
            targetOffsetY: 360,
            reason: .idleBottomSettle,
            collectionView: collectionView,
            scrollController: scrollController
        )
        let explicitApplied = TimelineOffsetController.apply(
            targetOffsetY: 420,
            reason: .programmaticTopAlign,
            collectionView: collectionView,
            scrollController: scrollController
        )

        #expect(!ambientApplied)
        #expect(!explicitApplied)
        #expect(collectionView.contentOffset.y == 120)
    }

    private func makeOffsetPolicyFixture(
        startingOffsetY: CGFloat = 0
    ) -> (TimelineScrollMetricsCollectionView, ChatScrollController) {
        let collectionView = TimelineScrollMetricsCollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 500)
        )
        collectionView.testContentSize = CGSize(width: 390, height: 2_000)
        collectionView.testAdjustedContentInset = UIEdgeInsets(top: 10, left: 0, bottom: 24, right: 0)
        collectionView.contentOffset.y = startingOffsetY

        let scrollController = ChatScrollController()
        scrollController.updateNearBottom(true)
        return (collectionView, scrollController)
    }
}
