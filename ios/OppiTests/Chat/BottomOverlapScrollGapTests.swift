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
