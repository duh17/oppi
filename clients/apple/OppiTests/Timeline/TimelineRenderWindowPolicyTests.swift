import CoreGraphics
import Testing
@testable import Oppi

@Suite("Timeline render window policy")
struct TimelineRenderWindowPolicyTests {
    @Test func showEarlierControlRemainsVisibleWhenOnlyServerRowsRemain() {
        #expect(TimelineRenderWindowPolicy.showsShowEarlierControl(hiddenCount: 0, hasOlderServerPage: true))
        #expect(!TimelineRenderWindowPolicy.showsShowEarlierControl(hiddenCount: 0, hasOlderServerPage: false))
    }

    @Test func showEarlierRevealsLocalHiddenRowsBeforeFetchingOlderPage() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 200,
            step: 60,
            hasOlderServerPage: true
        )

        #expect(action == .revealLocal(newWindow: 140))
    }

    @Test func showEarlierFetchesOlderServerPageWhenLocalRowsAreExhausted() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 80,
            step: 60,
            hasOlderServerPage: true
        )

        #expect(action == .fetchOlderPage)
    }

    @Test func showEarlierDoesNothingWhenNoLocalOrServerRowsRemain() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 80,
            step: 60,
            hasOlderServerPage: false
        )

        #expect(action == .none)
    }
}

@Suite("Chat timeline chrome overlap")
struct ChatTimelineChromeOverlapTests {
    @Test func topInsetUsesHeaderBottomNotBarHeight() {
        let timeline = CGRect(x: 0, y: 0, width: 390, height: 844)
        let header = CGRect(x: 16, y: 103, width: 358, height: 48)

        #expect(ChatTimelineChromeOverlap.topInset(timelineFrame: timeline, headerFrame: header) == 151)
        #expect(
            ChatTimelineChromeOverlap.topInset(timelineFrame: timeline, headerFrame: header) != header.height,
            "Bar height alone leaves the first rows under the navigation bar"
        )
    }

    @Test func emptyHeaderStillCoversNavigationGap() {
        let timeline = CGRect(x: 0, y: 0, width: 390, height: 844)
        // Named-space overlay: zero-height bar stretched to timeline width,
        // origin at the safe-area top (below the nav bar).
        let emptyHeaderAtSafeArea = CGRect(x: 0, y: 103, width: 390, height: 0)

        #expect(
            ChatTimelineChromeOverlap.topInset(
                timelineFrame: timeline,
                headerFrame: emptyHeaderAtSafeArea
            ) == 103
        )
    }

    @Test func globalFramesBelowNavCollapseToBarHeight() {
        let timelineLaidOutBelowNav = CGRect(x: 0, y: 103, width: 390, height: 741)
        let header = CGRect(x: 16, y: 103, width: 358, height: 48)
        #expect(
            ChatTimelineChromeOverlap.topInset(
                timelineFrame: timelineLaidOutBelowNav,
                headerFrame: header
            ) == header.height,
            "Global frames whose timeline origin is already below the nav reproduce the original underlap; named-space origin must stay 0"
        )
    }

    @Test func unmeasuredFramesDoNotInventInset() {
        #expect(
            ChatTimelineChromeOverlap.topInset(timelineFrame: .zero, headerFrame: .zero) == 0
        )
    }
}
