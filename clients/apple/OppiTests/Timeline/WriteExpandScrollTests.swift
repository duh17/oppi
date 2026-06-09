import Foundation
import Testing
import UIKit
@testable import Oppi

/// Tests for the scroll-lock bug when expanding a `write` tool output.
///
/// Bug: expanding a write tool row (which renders syntax-highlighted code in
/// an inner `expandedScrollView`) locks the outer collection view's scroll
/// position. The user cannot scroll up or down — position keeps resetting.
///
/// Root cause hypothesis: the inner `expandedScrollView`'s vertical pan gesture
/// captures the outer collection view's scroll gesture, or the height change
/// from the expanded viewport triggers a layout pass that resets contentOffset
/// through the AnchoredCollectionView's restore logic.
@Suite("Write tool expand scroll behavior")
struct WriteExpandScrollTests {

    // MARK: - Helpers

    /// Build a timeline with enough content to scroll, including several write tool rows.
    @MainActor
    private static func makeWriteToolTimeline(
        count: Int = 20,
        toolArgsStore: ToolArgsStore,
        toolOutputStore: ToolOutputStore
    ) -> [ChatItem] {
        var items: [ChatItem] = []
        for i in 0..<count {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Response paragraph \(i). ", count: 12),
                timestamp: Date()
            ))

            let toolId = "tc-write-\(i)"
            let fileContent = String(
                repeating: "func example\(i)() {\n    print(\"line \(i)\")\n}\n\n",
                count: 20
            )
            toolArgsStore.set([
                "path": .string("Sources/File\(i).swift"),
                "content": .string(fileContent),
            ], for: toolId)
            toolOutputStore.append("Successfully wrote Sources/File\(i).swift", to: toolId)

            items.append(.toolCall(
                id: toolId,
                tool: "write",
                argsSummary: "write Sources/File\(i).swift",
                outputPreview: "Successfully wrote Sources/File\(i).swift",
                outputByteCount: fileContent.utf8.count,
                isError: false,
                isDone: true
            ))
        }
        return items
    }

    // MARK: - Scroll Position Tests

    @MainActor
    @Test func expandingWriteToolDoesNotLockScrollPosition() {
        // Setup: windowed collection view with write tool rows.
        let wh = makeWindowedTimelineHarness(
            sessionId: "s-write-scroll",
            useAnchoredCollectionView: true
        )
        let items = Self.makeWriteToolTimeline(
            toolArgsStore: wh.toolArgsStore,
            toolOutputStore: wh.toolOutputStore
        )

        wh.applyItems(items, isBusy: false)

        // Scroll to bottom so all cells measure their real heights.
        let maxOffset = max(0, wh.collectionView.contentSize.height - wh.collectionView.bounds.height)
        setTimelineUserScrollOffsetY(wh.collectionView, maxOffset)
        wh.collectionView.layoutIfNeeded()

        // Scroll to mid-point and detach.
        let midY = maxOffset * 0.5
        setTimelineUserScrollOffsetY(wh.collectionView, midY)
        wh.collectionView.layoutIfNeeded()
        wh.scrollController.detachFromBottomForUserScroll()

        // Find a visible write tool row to expand.
        let visibleIPs = wh.collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let writeToolIP = visibleIPs.first { ip in
            let allIDs = items.map(\.id)
            return ip.item < allIDs.count && allIDs[ip.item].hasPrefix("tc-write-")
        }
        guard let targetIP = writeToolIP else {
            Issue.record("No visible write tool row at midpoint")
            return
        }

        // Top-edge anchoring: capture the tapped header before expansion.
        // After expansion, the header should stay in place and the cell should
        // grow downward.
        let topScreenYBefore: CGFloat? = {
            guard let attrs = wh.collectionView.layoutAttributesForItem(at: targetIP) else { return nil }
            return attrs.frame.minY - wh.collectionView.contentOffset.y
        }()

        // Tap to expand the write tool output.
        wh.coordinator.collectionView(wh.collectionView, didSelectItemAt: targetIP)
        wh.collectionView.layoutIfNeeded()

        let offsetAfterExpand = wh.collectionView.contentOffset.y

        // The header should stay at the same screen position.
        if let before = topScreenYBefore,
           let attrs = wh.collectionView.layoutAttributesForItem(at: targetIP) {
            let after = attrs.frame.minY - wh.collectionView.contentOffset.y
            let topDrift = abs(after - before)
            #expect(topDrift < 5.0,
                    "Header drifted \(topDrift)pt after expanding write tool row")
        }

        // Now simulate the user trying to scroll up after the expand.
        // In the bug scenario, the offset resets back to the expanded position.
        let scrollUpAmount: CGFloat = 200
        let targetOffset = offsetAfterExpand - scrollUpAmount
        setTimelineUserScrollOffsetY(wh.collectionView, targetOffset)
        wh.collectionView.layoutIfNeeded()

        let offsetAfterScrollUp = wh.collectionView.contentOffset.y
        let scrollUpDrift = abs(offsetAfterScrollUp - targetOffset)
        #expect(scrollUpDrift < 5.0,
                "scroll position snapped back after scrolling up (\(scrollUpDrift)pt drift, expected < 5pt)")

        // Simulate scrolling down past the expanded row.
        let scrollDownTarget = offsetAfterExpand + scrollUpAmount
        setTimelineUserScrollOffsetY(wh.collectionView, scrollDownTarget)
        wh.collectionView.layoutIfNeeded()

        let offsetAfterScrollDown = wh.collectionView.contentOffset.y
        let scrollDownDrift = abs(offsetAfterScrollDown - scrollDownTarget)
        #expect(scrollDownDrift < 5.0,
                "scroll position snapped back after scrolling down (\(scrollDownDrift)pt drift, expected < 5pt)")
    }

    @MainActor
    @Test func expandedWriteToolInnerScrollViewDoesNotStealVerticalGesture() {
        // The expanded write tool row contains an inner expandedScrollView
        // for horizontal scrolling of wide code lines. Verify that vertical
        // pan gestures are not consumed by this inner scroll view.
        let wh = makeWindowedTimelineHarness(
            sessionId: "s-write-gesture",
            useAnchoredCollectionView: true
        )
        let items = Self.makeWriteToolTimeline(
            count: 10,
            toolArgsStore: wh.toolArgsStore,
            toolOutputStore: wh.toolOutputStore
        )

        wh.applyItems(items, isBusy: false)

        // Scroll to bottom, then back to top area.
        let maxOffset = max(0, wh.collectionView.contentSize.height - wh.collectionView.bounds.height)
        setTimelineUserScrollOffsetY(wh.collectionView, maxOffset)
        wh.collectionView.layoutIfNeeded()
        setTimelineUserScrollOffsetY(wh.collectionView, 100)
        wh.collectionView.layoutIfNeeded()

        // Expand a visible write tool row.
        let targetIP = IndexPath(item: 1, section: 0) // first tool call is item 1
        wh.collectionView.scrollToItem(at: targetIP, at: .centeredVertically, animated: false)
        settleTimelineLayout(wh.collectionView)
        wh.scrollController.detachFromBottomForUserScroll()
        wh.coordinator.collectionView(wh.collectionView, didSelectItemAt: targetIP)
        wh.collectionView.layoutIfNeeded()

        // Get the expanded cell and find the inner scroll view.
        guard let cell = wh.collectionView.cellForItem(at: targetIP) else {
            Issue.record("Cell not visible after expand")
            return
        }

        let innerScrollViews = timelineAllScrollViews(in: cell.contentView)
            .filter { $0 !== wh.collectionView }

        // The expanded content should have at least one inner scroll view.
        #expect(!innerScrollViews.isEmpty, "Expected inner scroll view in expanded write tool row")

        // When expanded code content fits inside the viewport height, the
        // inner scroll view should not scroll vertically (content fits).
        // When it overflows, the vertical scroll competes with the outer
        // collection view's pan gesture. Either:
        //   a) alwaysBounceVertical should be false, OR
        //   b) a gesture dependency (require(toFail:)) should be set up
        //      so the outer collection view wins vertical pans.
        //
        // Failing this means inner scroll views can steal vertical gestures
        // from the outer collection view, causing the "locked scroll" bug.
        for innerSV in innerScrollViews {
            let verticalBounce = innerSV.alwaysBounceVertical
            let canScrollVertically = innerSV.contentSize.height > innerSV.bounds.height

            if canScrollVertically || verticalBounce {
                // This inner scroll view can capture vertical gestures.
                // For the fix to work, either:
                // 1. Vertical scrolling should be disabled (content fits in viewport), or
                // 2. The outer collection view's pan should be wired as a
                //    gesture dependency so it takes priority.
                //
                // Record a diagnostic — the actual scroll behavior test above
                // (`expandingWriteToolDoesNotLockScrollPosition`) is the
                // authoritative check.
                #expect(!verticalBounce,
                        "Inner scroll view has alwaysBounceVertical=true, which can steal vertical gestures from the outer collection view")
            }

            if innerSV.isScrollEnabled {
                #expect(!innerSV.bounces,
                        "Inner scroll view should not bounce vertically in expanded tool rows")

                let verticalOverflow = innerSV.contentSize.height - innerSV.bounds.height
                #expect(
                    verticalOverflow <= 12,
                    "Inner scroll view can still consume vertical drags (overflow=\(verticalOverflow))"
                )
            }
        }
    }

    @MainActor
    @Test func multipleExpandedWriteToolsDoNotCompoundScrollLock() {
        // Expand multiple write tool rows, then verify the user can still
        // scroll freely through the timeline.
        let wh = makeWindowedTimelineHarness(
            sessionId: "s-write-multi",
            useAnchoredCollectionView: true
        )
        let items = Self.makeWriteToolTimeline(
            count: 15,
            toolArgsStore: wh.toolArgsStore,
            toolOutputStore: wh.toolOutputStore
        )

        wh.applyItems(items, isBusy: false)

        // Scroll to bottom to measure all cells.
        let maxOffset = max(0, wh.collectionView.contentSize.height - wh.collectionView.bounds.height)
        setTimelineUserScrollOffsetY(wh.collectionView, maxOffset)
        wh.collectionView.layoutIfNeeded()

        // Scroll back to near-top.
        setTimelineUserScrollOffsetY(wh.collectionView, 0)
        wh.collectionView.layoutIfNeeded()
        wh.scrollController.detachFromBottomForUserScroll()

        // Expand the first 3 visible write tool rows.
        let visibleIPs = wh.collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let writeIPs = visibleIPs.filter { ip in
            let allIDs = items.map(\.id)
            return ip.item < allIDs.count && allIDs[ip.item].hasPrefix("tc-write-")
        }.prefix(3)

        for ip in writeIPs {
            wh.coordinator.collectionView(wh.collectionView, didSelectItemAt: ip)
        }
        wh.collectionView.layoutIfNeeded()

        // Start from an interior offset so the check has room to move down.
        let newMax = max(0, wh.collectionView.contentSize.height - wh.collectionView.bounds.height)
        let startingOffset = min(max(0, newMax * 0.25), max(0, newMax - 400))
        setTimelineUserScrollOffsetY(wh.collectionView, startingOffset)
        wh.collectionView.layoutIfNeeded()
        let offsetAfterExpands = wh.collectionView.contentOffset.y

        // Try scrolling through the content in increments.
        let scrollStep: CGFloat = 100
        var scrollLocked = false

        var currentOffset = offsetAfterExpands
        for _ in 0..<20 {
            let target = min(currentOffset + scrollStep, newMax)
            setTimelineUserScrollOffsetY(wh.collectionView, target)
            wh.collectionView.layoutIfNeeded()

            let actual = wh.collectionView.contentOffset.y
            if abs(actual - target) > 10 {
                scrollLocked = true
                break
            }
            currentOffset = actual
        }

        #expect(!scrollLocked,
                "Scroll position is locked after expanding multiple write tool rows")

        // Verify we actually moved significantly from the starting position.
        let totalScrolled = abs(wh.collectionView.contentOffset.y - offsetAfterExpands)
        #expect(totalScrolled > 200,
                "Failed to scroll at least 200pt after expanding write tools (only moved \(totalScrolled)pt)")
    }

    @MainActor
    @Test func collapsingExpandedTallReadImageKeepsHeaderPositionStable() throws {
        let wh = makeWindowedTimelineHarness(
            sessionId: "s-read-image-collapse",
            useAnchoredCollectionView: true
        )
        let toolID = "tc-read-tall-image"
        let image = Self.makeReadToolImage(size: CGSize(width: 80, height: 320))
        let imageData = try #require(image.pngData())
        let output = "Read image file [image/png]\n\ndata:image/png;base64,\(imageData.base64EncodedString())"
        wh.toolArgsStore.set(["path": .string("/tmp/tall-read-image.png")], for: toolID)
        wh.toolOutputStore.append(output, to: toolID)
        wh.reducer.expandedItemIDs.insert(toolID)

        let items: [ChatItem] = [
            .assistantMessage(id: "before", text: String(repeating: "Before. ", count: 80), timestamp: Date()),
            .toolCall(
                id: toolID,
                tool: "read",
                argsSummary: "read /tmp/tall-read-image.png",
                outputPreview: output,
                outputByteCount: output.utf8.count,
                isError: false,
                isDone: true
            ),
            .assistantMessage(id: "after", text: String(repeating: "After. ", count: 600), timestamp: Date()),
        ]
        wh.applyItems(items, isBusy: false)
        settleTimelineLayout(wh.collectionView, passes: 4)

        let targetIP = IndexPath(item: 1, section: 0)
        wh.collectionView.scrollToItem(at: targetIP, at: .top, animated: false)
        settleTimelineLayout(wh.collectionView, passes: 3)
        wh.scrollController.detachFromBottomForUserScroll()

        guard let attrsBefore = wh.collectionView.layoutAttributesForItem(at: targetIP) else {
            Issue.record("Missing expanded read image layout attributes")
            return
        }
        let topScreenYBefore = attrsBefore.frame.minY - wh.collectionView.contentOffset.y
        let offsetBefore = wh.collectionView.contentOffset.y

        wh.coordinator.collectionView(wh.collectionView, didSelectItemAt: targetIP)
        settleTimelineLayout(wh.collectionView, passes: 4)

        let offsetJump = abs(wh.collectionView.contentOffset.y - offsetBefore)
        #expect(offsetJump < 12, "Collapsing tall image should not yank the timeline offset by \(offsetJump)pt")
        if let attrsAfter = wh.collectionView.layoutAttributesForItem(at: targetIP) {
            let topScreenYAfter = attrsAfter.frame.minY - wh.collectionView.contentOffset.y
            let topDrift = abs(topScreenYAfter - topScreenYBefore)
            #expect(topDrift < 8, "Collapsed row header drifted \(topDrift)pt")
        }
    }

    @MainActor
    @Test func collapsingExpandedWriteToolRestoresNormalScrolling() {
        // Expand a write tool, verify scroll works, collapse it, verify scroll still works.
        let wh = makeWindowedTimelineHarness(
            sessionId: "s-write-collapse",
            useAnchoredCollectionView: true
        )
        let items = Self.makeWriteToolTimeline(
            count: 15,
            toolArgsStore: wh.toolArgsStore,
            toolOutputStore: wh.toolOutputStore
        )

        wh.applyItems(items, isBusy: false)

        let maxOffset = max(0, wh.collectionView.contentSize.height - wh.collectionView.bounds.height)
        setTimelineUserScrollOffsetY(wh.collectionView, maxOffset)
        wh.collectionView.layoutIfNeeded()

        let midY = maxOffset * 0.5
        setTimelineUserScrollOffsetY(wh.collectionView, midY)
        wh.collectionView.layoutIfNeeded()
        wh.scrollController.detachFromBottomForUserScroll()

        // Find and expand a visible write tool.
        let visibleIPs = wh.collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let writeToolIP = visibleIPs.first { ip in
            let allIDs = items.map(\.id)
            return ip.item < allIDs.count && allIDs[ip.item].hasPrefix("tc-write-")
        }
        guard let targetIP = writeToolIP else {
            Issue.record("No visible write tool row")
            return
        }

        // Expand.
        wh.coordinator.collectionView(wh.collectionView, didSelectItemAt: targetIP)
        wh.collectionView.layoutIfNeeded()

        // Collapse.
        wh.coordinator.collectionView(wh.collectionView, didSelectItemAt: targetIP)
        wh.collectionView.layoutIfNeeded()

        let offsetAfterCollapse = wh.collectionView.contentOffset.y

        // Verify scrolling works after collapse.
        let scrollTarget = offsetAfterCollapse - 300
        setTimelineUserScrollOffsetY(wh.collectionView, max(0, scrollTarget))
        wh.collectionView.layoutIfNeeded()

        let drift = abs(wh.collectionView.contentOffset.y - max(0, scrollTarget))
        #expect(drift < 5.0,
                "Scroll position snapped back after collapse+scroll (\(drift)pt drift)")
    }

    private static func makeReadToolImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(
                x: size.width * 0.25,
                y: size.height * 0.08,
                width: size.width * 0.5,
                height: size.height * 0.84
            ))
        }
    }
}
