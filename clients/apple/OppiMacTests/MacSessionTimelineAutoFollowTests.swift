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

    @Test func treatsSameWidthHeightGrowthAsDocumentGrowth() {
        #expect(
            MacSessionTimelineAutoFollow.contentHeightIncreasedFromDocumentGrowth(
                previousHeight: 800,
                nextHeight: 960,
                previousViewportWidth: 720,
                nextViewportWidth: 720
            )
        )
    }

    @Test func ignoresHeightGrowthWhenViewportWidthChanges() {
        #expect(
            !MacSessionTimelineAutoFollow.contentHeightIncreasedFromDocumentGrowth(
                previousHeight: 800,
                nextHeight: 960,
                previousViewportWidth: 720,
                nextViewportWidth: 480
            )
        )
    }

    @Test func treatsFirstGeometryFrameAsDocumentGrowth() {
        #expect(
            MacSessionTimelineAutoFollow.contentHeightIncreasedFromDocumentGrowth(
                previousHeight: 0,
                nextHeight: 400,
                previousViewportWidth: 0,
                nextViewportWidth: 720
            )
        )
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

    @Test func remountKeepsADetachedOffsetInsteadOfTheTop() {
        let viewport = MacSessionTimelineViewport(offsetY: 420, anchorID: "row-8")
        #expect(
            MacSessionTimelineAutoFollow.remountScrollTarget(
                isAttached: false,
                viewport: viewport
            ) == .anchor("row-8", offsetY: 420)
        )
        #expect(
            MacSessionTimelineAutoFollow.remountScrollTarget(
                isAttached: false,
                viewport: MacSessionTimelineViewport(offsetY: 420, anchorID: nil)
            ) == .offset(420)
        )
        #expect(
            MacSessionTimelineAutoFollow.remountScrollTarget(
                isAttached: true,
                viewport: viewport
            ) == .latest
        )
        #expect(
            MacSessionTimelineAutoFollow.remountScrollTarget(
                isAttached: false,
                viewport: MacSessionTimelineViewport()
            ) == .top
        )
    }

    @Test func remountFallsBackToOffsetWhenTheAnchorIsMissingOrStale() {
        let viewport = MacSessionTimelineViewport(offsetY: 420, anchorID: "stale-row")
        #expect(
            MacSessionTimelineAutoFollow.remountScrollTarget(
                isAttached: false,
                viewport: viewport,
                availableAnchorIDs: ["row-8", "row-after"]
            ) == .offset(420)
        )
        #expect(
            MacSessionTimelineAutoFollow.remountScrollTarget(
                isAttached: false,
                viewport: MacSessionTimelineViewport(offsetY: 420, anchorID: ""),
                availableAnchorIDs: ["row-8"]
            ) == .offset(420)
        )
        #expect(
            MacSessionTimelineAutoFollow.restoreCommand(for: .offset(420))
                == .contentOffset(420)
        )
    }

    @Test func remountRestoreKeepsIntraRowOffsetInsteadOfTheRowStart() {
        let target = MacSessionTimelineAutoFollow.remountScrollTarget(
            isAttached: false,
            viewport: MacSessionTimelineViewport(offsetY: 420, anchorID: "row-8")
        )
        #expect(target == .anchor("row-8", offsetY: 420))
        #expect(
            MacSessionTimelineAutoFollow.restoreCommand(for: target)
                == .contentOffset(420)
        )
        #expect(
            MacSessionTimelineAutoFollow.restoreCommand(for: target)
                != .rowStart("row-8")
        )
        #expect(
            MacSessionTimelineAutoFollow.restoreCommand(
                for: .anchor("row-8", offsetY: 0)
            ) == .rowStart("row-8")
        )
    }

    @Test func remountRestoreStaysPendingOnShortGeometryThenAppliesSavedOffsetNotLatest() {
        let pending = MacSessionTimelineRemountTarget.offset(420)

        let short = MacSessionTimelineAutoFollow.remountRestoreDecision(
            pending: pending,
            contentHeight: 80,
            offsetY: 0,
            viewportHeight: 400
        )
        #expect(short.pending == pending)
        #expect(!short.applyRestore)
        #expect(short.holdRestore)
        #expect(
            MacSessionTimelineAutoFollow.isNearBottom(
                contentHeight: 80,
                offsetY: 0,
                viewportHeight: 400
            )
        )
        #expect(
            MacSessionTimelineAutoFollow.restoreCommand(for: pending)
                == .contentOffset(420)
        )
        #expect(
            MacSessionTimelineAutoFollow.restoreCommand(for: pending)
                != .latest
        )

        let grown = MacSessionTimelineAutoFollow.remountRestoreDecision(
            pending: short.pending,
            contentHeight: 1000,
            offsetY: 0,
            viewportHeight: 400
        )
        #expect(grown.applyRestore)
        #expect(grown.pending == nil)
        #expect(grown.holdRestore)
        #expect(
            MacSessionTimelineAutoFollow.restoreCommand(for: pending)
                == .contentOffset(420)
        )
        #expect(
            MacSessionTimelineAutoFollow.restoreCommand(for: pending)
                != .latest
        )
    }

    @Test func explicitLatestOrOutlineNavigationCancelsPendingRemountSoLaterGeometryDoesNotReapplyOffset() {
        let pending = MacSessionTimelineRemountTarget.offset(420)

        let short = MacSessionTimelineAutoFollow.remountRestoreDecision(
            pending: pending,
            contentHeight: 80,
            offsetY: 0,
            viewportHeight: 400
        )
        #expect(short.pending == pending)
        #expect(!short.applyRestore)
        #expect(short.holdRestore)

        let afterLatest = MacSessionTimelineAutoFollow.pendingRemountTargetAfterExplicitNavigation(
            short.pending
        )
        let afterOutline = MacSessionTimelineAutoFollow.pendingRemountTargetAfterExplicitNavigation(
            short.pending
        )
        #expect(afterLatest == nil)
        #expect(afterOutline == nil)

        let later = MacSessionTimelineAutoFollow.remountRestoreDecision(
            pending: afterLatest,
            contentHeight: 1000,
            offsetY: 0,
            viewportHeight: 400
        )
        #expect(!later.applyRestore)
        #expect(later.pending == nil)
        #expect(!later.holdRestore)
    }

    @Test func recordingPreservesDetachedAnchorAndFollowsTheTailWhenAttached() {
        #expect(
            MacSessionTimelineAutoFollow.recordedViewport(
                offsetY: 420,
                anchorID: "row-8",
                isAttached: false
            ) == MacSessionTimelineViewport(offsetY: 420, anchorID: "row-8")
        )
        #expect(
            MacSessionTimelineAutoFollow.recordedViewport(
                offsetY: 900,
                anchorID: "row-8",
                isAttached: true
            ) == MacSessionTimelineViewport(
                offsetY: 900,
                anchorID: MacSessionTimelineAutoFollow.latestAnchorID
            )
        )
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
