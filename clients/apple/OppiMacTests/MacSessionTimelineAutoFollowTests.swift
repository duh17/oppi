import SwiftUI
import Testing
@testable import Oppi

@Suite("Mac session timeline auto-follow")
struct MacSessionTimelineAutoFollowTests {
    @Test func treatsViewportAtTailAsNearBottom() {
        #expect(
            MacSessionTimelineAutoFollow.isNearBottom(
                contentHeight: 1000,
                offsetY: 800,
                viewportHeight: 200
            )
        )
    }

    @Test func treatsDistanceAtThresholdAsNearBottom() {
        #expect(
            MacSessionTimelineAutoFollow.isNearBottom(
                contentHeight: 1000,
                offsetY: 736,
                viewportHeight: 200
            )
        )
    }

    @Test func detachesWhenUserScrollsAboveThreshold() {
        #expect(
            !MacSessionTimelineAutoFollow.isNearBottom(
                contentHeight: 1000,
                offsetY: 700,
                viewportHeight: 200
            )
        )
    }

    @Test func shortContentFitsAndCountsAsNearBottom() {
        #expect(
            MacSessionTimelineAutoFollow.isNearBottom(
                contentHeight: 120,
                offsetY: 0,
                viewportHeight: 400
            )
        )
    }

    @Test func staysAttachedWhenStreamingGrowthMovesTheTail() {
        #expect(
            MacSessionTimelineAutoFollow.isAttachedAfterGeometryChange(
                wasAttached: true,
                isNearBottom: false,
                scrollPhase: .idle
            )
        )
    }

    @Test func detachesWhenUserLeavesTail() {
        #expect(
            !MacSessionTimelineAutoFollow.isAttachedAfterGeometryChange(
                wasAttached: true,
                isNearBottom: false,
                scrollPhase: .interacting
            )
        )
    }

    @Test func doesNotReattachOnGrowthWhileScrolledUp() {
        #expect(
            !MacSessionTimelineAutoFollow.isAttachedAfterGeometryChange(
                wasAttached: false,
                isNearBottom: false,
                scrollPhase: .idle
            )
        )
    }

    @Test func reattachesWhenUserReturnsToTail() {
        #expect(
            MacSessionTimelineAutoFollow.isAttachedAfterGeometryChange(
                wasAttached: false,
                isNearBottom: true,
                scrollPhase: .interacting
            )
        )
    }

    @Test func distinguishesUserAndProgrammaticScrollPhases() {
        #expect(MacSessionTimelineAutoFollow.isUserDriven(.tracking))
        #expect(MacSessionTimelineAutoFollow.isUserDriven(.interacting))
        #expect(MacSessionTimelineAutoFollow.isUserDriven(.decelerating))
        #expect(!MacSessionTimelineAutoFollow.isUserDriven(.idle))
        #expect(!MacSessionTimelineAutoFollow.isUserDriven(.animating))
    }

    @Test func scrollsTheTailAnchorAfterAttachedContentGrowth() {
        #expect(
            MacSessionTimelineAutoFollow.shouldScrollAfterContentGrowth(
                isAttached: true,
                isNearBottom: false,
                contentHeightIncreased: true
            )
        )
        #expect(
            !MacSessionTimelineAutoFollow.shouldScrollAfterContentGrowth(
                isAttached: false,
                isNearBottom: false,
                contentHeightIncreased: true
            )
        )
        #expect(
            !MacSessionTimelineAutoFollow.shouldScrollAfterContentGrowth(
                isAttached: true,
                isNearBottom: true,
                contentHeightIncreased: true
            )
        )
    }

    @Test func scrollsToLatestOnlyWhileAttached() {
        #expect(MacSessionTimelineAutoFollow.shouldScrollToLatestRow(isAttached: true))
        #expect(!MacSessionTimelineAutoFollow.shouldScrollToLatestRow(isAttached: false))
    }

    @Test func honorsReduceMotionForFollowAnimation() {
        #expect(MacSessionTimelineAutoFollow.scrollAnimation(reduceMotion: true) == nil)
        #expect(MacSessionTimelineAutoFollow.scrollAnimation(reduceMotion: false) != nil)
    }
}

@Suite("Mac session timeline composer overlap")
struct MacSessionTimelineOverlapTests {
    @Test func bottomInsetClearsTheComposerHeight() {
        let inset = MacSessionTimelineOverlap.bottomContentInset(composerHeight: 88)
        #expect(inset >= 88)
        #expect(inset > MacSessionTimelineAutoFollow.nearBottomThreshold)
    }

    @Test func defaultComposerOverlapIsAtLeastACapsule() {
        #expect(MacSessionTimelineOverlap.defaultComposerHeight >= 72)
        #expect(
            MacSessionTimelineOverlap.bottomContentInset(
                composerHeight: MacSessionTimelineOverlap.defaultComposerHeight
            ) >= MacSessionTimelineOverlap.defaultComposerHeight
        )
    }

    @Test func negativeMeasuredHeightDoesNotPullContentUnderTheBar() {
        #expect(MacSessionTimelineOverlap.bottomContentInset(composerHeight: -10) >= 0)
    }
}
