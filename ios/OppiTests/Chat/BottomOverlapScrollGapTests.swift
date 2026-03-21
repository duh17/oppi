import Foundation
import Testing
import UIKit
@testable import Oppi

/// Regression tests for the gap between the last message and the input bar
/// when returning to a chat.
///
/// Bug shape:
/// - `footerHeight` starts at 0 (unmeasured).
/// - Initial scroll-to-bottom fires with `contentInset.bottom = 0`.
/// - Footer overlay is measured → `contentInset.bottom` increases to the
///   real footer height.
/// - No re-scroll fires → the last item sits at the wrong position
///   relative to the footer, leaving a visible gap.
@Suite("Bottom overlap scroll gap")
@MainActor
struct BottomOverlapScrollGapTests {

    /// Simulated footer height (input bar + session toolbar).
    private static let footerHeight: CGFloat = 120

    // MARK: - Core regression: initial scroll with zero overlap, then footer measured

    @Test func scrollToBottomWithZeroOverlapThenFooterMeasuredLeavesGap() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-gap",
            useAnchoredCollectionView: true
        )
        let items = assistantItems(count: 30)

        // Simulate: initial scroll fires with footerHeight=0 (not measured yet).
        let scrollCmd = ChatTimelineScrollCommand(
            id: items.last!.id,
            anchor: .bottom,
            animated: false,
            nonce: 1
        )
        windowed.scrollController.updateNearBottom(true)

        let configZero = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            scrollCommand: scrollCmd,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            bottomOverlap: 0
        )
        windowed.coordinator.apply(configuration: configZero, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        // Capture position after scroll-to-bottom with no overlap.
        let offsetAfterScroll = windowed.collectionView.contentOffset.y

        // Simulate: footer gets measured, overlap changes to footerHeight.
        // No new scroll command fires (the race condition).
        let configMeasured = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            bottomOverlap: Self.footerHeight
        )
        windowed.coordinator.apply(configuration: configMeasured, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        let offsetAfterInsetChange = windowed.collectionView.contentOffset.y

        // After the inset change, the content offset should have been
        // adjusted to keep the last item at the visible bottom. If the
        // offset didn't change (or didn't change enough), the last item
        // is pushed behind the footer — creating a gap when the user
        // scrolls to what they think is "the bottom".
        let cv = windowed.collectionView
        let insets = cv.adjustedContentInset
        let visibleHeight = cv.bounds.height - insets.top - insets.bottom
        let maxOffset = max(-insets.top, cv.contentSize.height - visibleHeight)
        let distFromBottom = maxOffset - cv.contentOffset.y

        // If attached to bottom, distFromBottom should be ~0.
        // If the bug exists, distFromBottom will be roughly footerHeight.
        let detail = "distFromBottom=\(distFromBottom), offsetAfterScroll=\(offsetAfterScroll), offsetAfterInsetChange=\(offsetAfterInsetChange), maxOffset=\(maxOffset), contentH=\(cv.contentSize.height), visibleH=\(visibleHeight), insets=\(insets)"
        #expect(
            distFromBottom < 20,
            Comment(rawValue: "Expected content at bottom after inset change. \(detail)")
        )
    }

    // MARK: - Control: correct overlap from start has no gap

    @Test func scrollToBottomWithCorrectOverlapFromStartHasNoGap() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-no-gap",
            useAnchoredCollectionView: true
        )
        let items = assistantItems(count: 30)

        let scrollCmd = ChatTimelineScrollCommand(
            id: items.last!.id,
            anchor: .bottom,
            animated: false,
            nonce: 1
        )
        windowed.scrollController.updateNearBottom(true)

        let config = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            scrollCommand: scrollCmd,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            bottomOverlap: Self.footerHeight
        )
        windowed.coordinator.apply(configuration: config, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        let cv = windowed.collectionView
        let insets = cv.adjustedContentInset
        let visibleHeight = cv.bounds.height - insets.top - insets.bottom
        let maxOffset = max(-insets.top, cv.contentSize.height - visibleHeight)
        let distFromBottom = maxOffset - cv.contentOffset.y

        #expect(
            distFromBottom < 20,
            Comment(rawValue: "Expected no gap with correct overlap. distFromBottom=\(distFromBottom)")
        )
    }

    // MARK: - Footer grows while attached

    @Test func footerHeightGrowthWhileAttachedStaysAtBottom() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-grow",
            useAnchoredCollectionView: true
        )
        let items = assistantItems(count: 30)

        // Start with a small footer.
        let smallFooter: CGFloat = 60
        let scrollCmd = ChatTimelineScrollCommand(
            id: items.last!.id,
            anchor: .bottom,
            animated: false,
            nonce: 1
        )
        windowed.scrollController.updateNearBottom(true)

        let configSmall = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            scrollCommand: scrollCmd,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            bottomOverlap: smallFooter
        )
        windowed.coordinator.apply(configuration: configSmall, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        // Footer grows (message queue appears, etc.). No new scroll command.
        let bigFooter: CGFloat = 180
        let configBig = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            bottomOverlap: bigFooter
        )
        windowed.coordinator.apply(configuration: configBig, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        let cv = windowed.collectionView
        let insets = cv.adjustedContentInset
        let visibleHeight = cv.bounds.height - insets.top - insets.bottom
        let maxOffset = max(-insets.top, cv.contentSize.height - visibleHeight)
        let distFromBottom = maxOffset - cv.contentOffset.y

        #expect(
            distFromBottom < 20,
            Comment(rawValue: "Expected no gap when footer grows while attached. distFromBottom=\(distFromBottom)")
        )
    }

    // MARK: - Top + bottom overlap: passive pinning formula

    /// Regression: the passive bottom-pinning formula in scrollViewDidScroll
    /// used `contentSize - visibleHeight` which expands to
    /// `contentSize - bounds + insets.top + insets.bottom`. The correct max
    /// offset is `contentSize - bounds + insets.bottom`. The old formula
    /// overshoots by `insets.top`, pushing the last item above the footer
    /// by the header height (~60pt in the real app).
    ///
    /// This test exercises the passive pinning path by:
    /// 1. Scrolling to bottom with header + footer insets
    /// 2. Adding items so contentSize grows
    /// 3. Verifying the offset doesn't overshoot the correct max
    @Test func contentGrowthWithTopOverlapDoesNotOvershoot() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-top-overlap",
            useAnchoredCollectionView: true
        )

        let headerHeight: CGFloat = 60
        let footerHeight: CGFloat = 120

        // Start with fewer items so we can grow later.
        let initialItems = assistantItems(count: 20)

        let scrollCmd = ChatTimelineScrollCommand(
            id: initialItems.last!.id,
            anchor: .bottom,
            animated: false,
            nonce: 1
        )
        windowed.scrollController.updateNearBottom(true)

        let config1 = makeTimelineConfiguration(
            items: initialItems,
            isBusy: false,
            scrollCommand: scrollCmd,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            topOverlap: headerHeight,
            bottomOverlap: footerHeight
        )
        windowed.coordinator.apply(configuration: config1, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        // Verify at bottom after initial scroll.
        let cv = windowed.collectionView
        let insets1 = cv.adjustedContentInset
        let maxOffset1 = cv.contentSize.height - cv.bounds.height + insets1.bottom
        #expect(
            abs(cv.contentOffset.y - maxOffset1) < 10,
            "Pre-condition: expected at bottom after initial scroll"
        )

        // Add more items (simulating new content arriving while attached).
        let grownItems = assistantItems(count: 30)
        let config2 = makeTimelineConfiguration(
            items: grownItems,
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            topOverlap: headerHeight,
            bottomOverlap: footerHeight
        )
        windowed.coordinator.apply(configuration: config2, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        let insets2 = cv.adjustedContentInset
        let correctMaxOffset = cv.contentSize.height - cv.bounds.height + insets2.bottom
        let overshoot = cv.contentOffset.y - correctMaxOffset
        let detail = "offset=\(cv.contentOffset.y), correctMax=\(correctMaxOffset), " +
            "overshoot=\(overshoot), topInset=\(insets2.top), " +
            "contentH=\(cv.contentSize.height)"
        #expect(
            overshoot < 10,
            Comment(rawValue: "Passive pinning overshoots by \(overshoot)pt (topInset=\(insets2.top)). \(detail)")
        )
    }

    /// The zero-to-real footer transition must also work when a header
    /// overlap is present. Without the fix, the top inset throws off the
    /// max-offset computation in the compensation path.
    @Test func zeroToRealFooterWithTopOverlapStaysAtBottom() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-top-footer-race",
            useAnchoredCollectionView: true
        )

        let headerHeight: CGFloat = 60
        let items = assistantItems(count: 30)

        let scrollCmd = ChatTimelineScrollCommand(
            id: items.last!.id,
            anchor: .bottom,
            animated: false,
            nonce: 1
        )
        windowed.scrollController.updateNearBottom(true)

        // Phase 1: footer not measured yet (overlap = 0), header present.
        let configZero = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            scrollCommand: scrollCmd,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            topOverlap: headerHeight,
            bottomOverlap: 0
        )
        windowed.coordinator.apply(configuration: configZero, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        // Phase 2: footer measured, overlap grows.
        let configMeasured = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            topOverlap: headerHeight,
            bottomOverlap: Self.footerHeight
        )
        windowed.coordinator.apply(configuration: configMeasured, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        let cv = windowed.collectionView
        let insets = cv.adjustedContentInset
        // Correct max offset: contentSize - bounds + adjustedContentInset.bottom
        // (NOT contentSize - visibleHeight, which includes insets.top)
        let maxOffset = max(
            -insets.top,
            cv.contentSize.height - cv.bounds.height + insets.bottom
        )
        let distFromBottom = maxOffset - cv.contentOffset.y

        let detail = "distFromBottom=\(distFromBottom), topInset=\(insets.top), " +
            "bottomInset=\(insets.bottom), contentH=\(cv.contentSize.height)"
        #expect(
            distFromBottom < 20,
            Comment(rawValue: "Expected at bottom after footer measured with header present. \(detail)")
        )
    }

    /// Verify the last cell's frame is close to the visible bottom edge
    /// (the top of the footer). This is the most direct assertion of the
    /// user's expectation: "last item sits right above the input bar."
    @Test func lastCellBottomNearVisibleBottomOnReentry() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-cell-gap",
            useAnchoredCollectionView: true
        )

        let headerHeight: CGFloat = 60
        let items = assistantItems(count: 30)

        let scrollCmd = ChatTimelineScrollCommand(
            id: items.last!.id,
            anchor: .bottom,
            animated: false,
            nonce: 1
        )
        windowed.scrollController.updateNearBottom(true)

        let config = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            scrollCommand: scrollCmd,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            topOverlap: headerHeight,
            bottomOverlap: Self.footerHeight
        )
        windowed.coordinator.apply(configuration: config, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)

        let cv = windowed.collectionView
        let insets = cv.adjustedContentInset
        let lastIndex = cv.numberOfItems(inSection: 0) - 1
        let lastIP = IndexPath(item: lastIndex, section: 0)
        let lastAttrs = try #require(cv.layoutAttributesForItem(at: lastIP))
        let lastCellBottom = lastAttrs.frame.maxY

        // The visible content bottom: where the footer starts.
        let visibleBottom = cv.contentOffset.y + cv.bounds.height - insets.bottom

        // Gap should be roughly the section bottom padding (8pt).
        // Any gap > 30pt indicates a positioning bug.
        let gap = visibleBottom - lastCellBottom
        let detail = "gap=\(gap), lastCellMaxY=\(lastCellBottom), " +
            "visibleBottom=\(visibleBottom), offset=\(cv.contentOffset.y), " +
            "topInset=\(insets.top), bottomInset=\(insets.bottom)"
        #expect(
            gap >= 0 && gap < 30,
            Comment(rawValue: "Expected last item near footer. \(detail)")
        )
    }

    // MARK: - Helpers

    private func assistantItems(count: Int) -> [ChatItem] {
        (0..<count).map { i in
            .assistantMessage(
                id: "msg-\(i)",
                text: """
                Message \(i)

                This is a longer message body that ensures the timeline is tall
                enough to require scrolling. Multiple lines help exercise the
                compositional layout's estimated to actual height resolution.
                """,
                timestamp: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }
    }
}
