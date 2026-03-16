import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
private func makeScrollTestWindow(
    frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844)
) -> UIWindow {
    guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first else {
        fatalError("Missing UIWindowScene for ScrollStabilityTests")
    }

    let window = UIWindow(windowScene: scene)
    window.frame = frame
    return window
}

@Suite("Scroll stability")
struct ScrollStabilityTests {
    // MARK: - Scroll Stability

    @MainActor
    @Test func contentOffsetStaysStableWhenNewItemsAppendedWhileScrolledUp() {
        // Reproduce: user is scrolled up; tool calls transition from running
        // to done (height changes), new items are inserted. Viewport must stay.
        let window = makeScrollTestWindow()
        let collectionView = UICollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()

        // Many items with varying heights: tall assistant messages and short
        // tool calls. This creates large gaps between estimated (44pt) and
        // actual cell heights, which stresses the layout's offset adjustment.
        var items: [ChatItem] = []
        for i in 0..<25 {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Long line \(i) with content. ", count: (i % 3 == 0) ? 40 : 8),
                timestamp: Date()
            ))
            // Tool calls at the end are still "running" (isDone: false).
            let isDone = i < 20
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "cmd \(i)",
                outputPreview: isDone ? "ok \(i)" : "",
                outputByteCount: isDone ? 16 : 0,
                isError: false, isDone: isDone
            ))
        }
        // Streaming assistant at the tail.
        items.append(.assistantMessage(id: "stream-1", text: "Thinking...", timestamp: Date()))

        func applyItems(_ currentItems: [ChatItem], streamingID: String? = nil, isBusy: Bool = true) {
            let config = makeTimelineConfiguration(
                items: currentItems,
                isBusy: isBusy,
                streamingAssistantID: streamingID,
                sessionId: "s1",
                reducer: reducer,
                toolOutputStore: ToolOutputStore(),
                toolArgsStore: ToolArgsStore(),
                connection: connection,
                scrollController: scrollController,
                audioPlayer: audioPlayer
            )
            coordinator.apply(configuration: config, to: collectionView)
            collectionView.layoutIfNeeded()
        }

        // Initial render, scroll to bottom so all cells measure.
        applyItems(items, streamingID: "stream-1")
        let fullHeight = collectionView.contentSize.height
        let viewHeight = collectionView.bounds.height
        collectionView.contentOffset.y = max(0, fullHeight - viewHeight)
        collectionView.layoutIfNeeded()

        // Scroll up to ~40% mark and detach.
        let midY = (fullHeight - viewHeight) * 0.4
        collectionView.contentOffset.y = midY
        collectionView.layoutIfNeeded()
        scrollController.detachFromBottomForUserScroll()

        let anchorY = collectionView.contentOffset.y

        // Transition running tool calls to done (they grow taller).
        for i in 20..<25 {
            guard let idx = items.firstIndex(where: { $0.id == "tc-\(i)" }) else {
                Issue.record("Missing expected tool call tc-\(i) in test setup")
                continue
            }
            items[idx] = .toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "cmd \(i)",
                outputPreview: "completed output line \(i)",
                outputByteCount: 64,
                isError: false, isDone: true
            )
        }
        applyItems(items, streamingID: "stream-1")

        let driftAfterTransition = abs(collectionView.contentOffset.y - anchorY)
        #expect(driftAfterTransition < 2.0,
                "contentOffset drifted \(driftAfterTransition)pt after tool transitions")

        // Insert new tool calls at the bottom.
        items.append(.toolCall(id: "tc-new-1", tool: "Read", argsSummary: "file.swift",
                               outputPreview: "contents", outputByteCount: 200,
                               isError: false, isDone: true))
        items.append(.toolCall(id: "tc-new-2", tool: "Write", argsSummary: "output.txt",
                               outputPreview: "written", outputByteCount: 100,
                               isError: false, isDone: true))
        items.append(.assistantMessage(id: "a-final",
                                       text: String(repeating: "Final paragraph. ", count: 20),
                                       timestamp: Date()))
        applyItems(items, streamingID: nil)

        let driftAfterInsert = abs(collectionView.contentOffset.y - anchorY)
        #expect(driftAfterInsert < 2.0,
                "contentOffset drifted \(driftAfterInsert)pt after inserting new items")

        #expect(!scrollController.isCurrentlyNearBottom,
                "user should still be detached")
    }

    @MainActor
    @Test func contentOffsetStableAcrossMultipleStreamingUpdatesWhileScrolledUp() {
        // Simulate rapid streaming: user is scrolled to a mid-point (not top),
        // streaming text grows and new tool calls are appended. The viewport
        // must stay pinned. This exercises the estimated-size layout path
        // where items above AND below the viewport have been estimated.
        let window = makeScrollTestWindow()
        let collectionView = UICollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()

        // Items with wildly varying heights to stress the estimated-size layout.
        var items: [ChatItem] = []
        for i in 0..<20 {
            // Alternate between short tool calls and long assistant messages
            // so actual cell heights differ greatly from the 44pt estimate.
            items.append(.toolCall(id: "tc-\(i)", tool: "bash",
                                   argsSummary: "cmd \(i)", outputPreview: "ok",
                                   outputByteCount: 8, isError: false, isDone: true))
            let lineCount = (i % 5 == 0) ? 30 : 5
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Line \(i) text. ", count: lineCount),
                timestamp: Date()
            ))
        }
        // Streaming assistant at the end.
        let streamingID = "stream-1"
        items.append(.assistantMessage(id: streamingID, text: "Starting...",
                                       timestamp: Date()))

        func applyItems(_ currentItems: [ChatItem], streamingID: String?) {
            let config = makeTimelineConfiguration(
                items: currentItems,
                isBusy: true,
                streamingAssistantID: streamingID,
                sessionId: "s1",
                reducer: reducer,
                toolOutputStore: ToolOutputStore(),
                toolArgsStore: ToolArgsStore(),
                connection: connection,
                scrollController: scrollController,
                audioPlayer: audioPlayer
            )
            coordinator.apply(configuration: config, to: collectionView)
            collectionView.layoutIfNeeded()
        }

        // Initial apply — scroll to bottom first so all cells get measured.
        applyItems(items, streamingID: streamingID)
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = maxOffset
        collectionView.layoutIfNeeded()

        // Now scroll to mid-point and detach.
        let midOffset = maxOffset * 0.4
        collectionView.contentOffset.y = midOffset
        collectionView.layoutIfNeeded()
        scrollController.detachFromBottomForUserScroll()

        let anchorOffset = collectionView.contentOffset.y

        // 10 rounds of streaming text growth + reconfigure.
        for round in 1...10 {
            let lastIndex = items.count - 1
            items[lastIndex] = .assistantMessage(
                id: streamingID,
                text: String(repeating: "Streaming round \(round). ", count: round * 20),
                timestamp: Date()
            )
            applyItems(items, streamingID: streamingID)

            let drift = abs(collectionView.contentOffset.y - anchorOffset)
            #expect(drift < 2.0,
                    "contentOffset drifted \(drift)pt on streaming round \(round)")
        }

        // New tool calls appear (streaming ends, multiple items inserted).
        for j in 0..<3 {
            items.append(.toolCall(id: "tc-new-\(j)", tool: "Read",
                                   argsSummary: "path: file\(j).swift",
                                   outputPreview: String(repeating: "content ", count: 20),
                                   outputByteCount: 512, isError: false, isDone: true))
        }
        items.append(.assistantMessage(id: "a-final",
                                       text: String(repeating: "Final result. ", count: 30),
                                       timestamp: Date()))
        applyItems(items, streamingID: nil)

        let finalDrift = abs(collectionView.contentOffset.y - anchorOffset)
        #expect(finalDrift < 2.0,
                "contentOffset jumped \(finalDrift)pt after inserting tool calls")

        #expect(!scrollController.isCurrentlyNearBottom,
                "user should still be detached after streaming updates")
    }

    // MARK: - Upward Scroll Stability

    @MainActor
    @Test func anchorItemStaysStableDuringUpwardScrollThroughUnmeasuredCells() {
        // Reproduce upward-scroll stutter: cells above the viewport have only
        // estimated heights.  When they first appear, preferredLayoutAttributesFitting
        // reports the real (larger) height, the layout invalidates, and contentOffset
        // is adjusted.  If the adjustment is wrong the visible "anchor" item
        // shifts → visible stutter.
        //
        // The test scrolls from the bottom upward in small increments,
        // performing layoutIfNeeded at each step (simulating frames).
        // After every step it checks that the *first visible item's screen-
        // relative position* hasn't jumped by more than a small tolerance.
        let window = makeScrollTestWindow()
        let collectionView = AnchoredCollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()
        collectionView.layoutIfNeeded()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()

        // Build 40 items with very different heights so estimated→actual
        // deltas are large.  Even-indexed items are short tool calls (~50pt),
        // odd-indexed are long assistant messages (200–600pt).
        var items: [ChatItem] = []
        for i in 0..<40 {
            if i.isMultiple(of: 2) {
                items.append(.toolCall(
                    id: "tc-\(i)", tool: "bash",
                    argsSummary: "cmd \(i)",
                    outputPreview: "ok",
                    outputByteCount: 8,
                    isError: false, isDone: true
                ))
            } else {
                let wordCount = 10 + (i % 5) * 30   // 10…130 words
                items.append(.assistantMessage(
                    id: "a-\(i)",
                    text: String(repeating: "Word\(i) ", count: wordCount),
                    timestamp: Date()
                ))
            }
        }

        let config = makeTimelineConfiguration(
            items: items,
            sessionId: "s-upward",
            reducer: reducer,
            toolOutputStore: ToolOutputStore(),
            toolArgsStore: ToolArgsStore(),
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        coordinator.apply(configuration: config, to: collectionView)
        collectionView.layoutIfNeeded()

        // Scroll to absolute bottom so cells near the bottom are measured;
        // cells near the top are still at estimated heights.
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = maxOffset
        collectionView.layoutIfNeeded()

        scrollController.detachFromBottomForUserScroll()

        // Simulate upward scroll in 60pt increments (≈ one short cell).
        // After each step, measure the anchor item's screen position.
        let scrollStep: CGFloat = 60
        var maxJump: CGFloat = 0
        var jumpDetails: [(step: Int, jump: CGFloat)] = []

        for step in 1...30 {
            // Record anchor: first visible item's frame relative to viewport.
            guard let anchorIP = collectionView.indexPathsForVisibleItems.min(by: { $0.item < $1.item }),
                  let anchorAttrs = collectionView.layoutAttributesForItem(at: anchorIP) else {
                continue
            }
            let anchorScreenY = anchorAttrs.frame.origin.y - collectionView.contentOffset.y

            // Scroll up by one step.
            let actualStep = min(scrollStep, collectionView.contentOffset.y)
            collectionView.contentOffset.y -= actualStep
            collectionView.layoutIfNeeded()

            // The anchor item should move down on screen by exactly `actualStep`
            // (viewport moved up → item's screen position increases).
            // Any EXTRA shift is stutter from layout re-estimation.
            let expectedScreenY = anchorScreenY + actualStep
            if let newAttrs = collectionView.layoutAttributesForItem(at: anchorIP) {
                let newScreenY = newAttrs.frame.origin.y - collectionView.contentOffset.y
                let stutter = abs(newScreenY - expectedScreenY)
                if stutter > maxJump {
                    maxJump = stutter
                }
                if stutter > 2 {
                    jumpDetails.append((step: step, jump: stutter))
                }
            }
        }

        // Tolerance: 2pt per step.  Any larger stutter is visible jitter.
        let detail = jumpDetails.map { "step \($0.step): \($0.jump)pt" }.joined(separator: ", ")
        #expect(maxJump <= 2.0,
                "anchor item stuttered \(maxJump)pt during upward scroll [\(detail)]")
    }

    // MARK: - Tool Row Expansion Scroll Stability

    @MainActor
    @Test func toolRowExpansionViaTapPreservesContentOffsetWhenScrolledUp() {
        // Bug: user scrolls up, taps a visible tool row to expand. The row
        // grows taller via animateToolRowExpansion (direct cell configuration
        // + invalidateLayout). Without offset compensation the viewport jumps.
        //
        // Key: the target cell must be visible (cellForItem != nil) so we hit
        // the direct-configuration path, NOT the reconfigureItems fallback.
        let window = makeScrollTestWindow()
        let collectionView = UICollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()
        let toolOutputStore = ToolOutputStore()
        let toolArgsStore = ToolArgsStore()

        var items: [ChatItem] = []
        for i in 0..<30 {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Response line \(i). ", count: 15),
                timestamp: Date()
            ))
            toolArgsStore.set(["command": .string("echo test-\(i)")], for: "tc-\(i)")
            toolOutputStore.append(
                String(repeating: "output line for tool \(i)\n", count: 10),
                to: "tc-\(i)"
            )
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "echo test-\(i)",
                outputPreview: "output for tool \(i)",
                outputByteCount: 256,
                isError: false, isDone: true
            ))
        }

        let config = makeTimelineConfiguration(
            items: items,
            sessionId: "s-expand",
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        coordinator.apply(configuration: config, to: collectionView)
        collectionView.layoutIfNeeded()

        // Scroll to bottom so all cells measure.
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = maxOffset
        collectionView.layoutIfNeeded()

        // Scroll to a mid-point where tool rows are visible.
        let midY = maxOffset * 0.5
        collectionView.contentOffset.y = midY
        collectionView.layoutIfNeeded()
        scrollController.detachFromBottomForUserScroll()

        // Find a visible tool row to expand.
        let visibleIPs = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let visibleToolIP = visibleIPs.first { ip in
            ip.item < items.count && items[ip.item].id.hasPrefix("tc-")
        }
        guard let targetIP = visibleToolIP else {
            Issue.record("No visible tool row at midpoint — test setup error")
            return
        }

        let offsetBefore = collectionView.contentOffset.y

        // Tap to expand via real didSelectItemAt → animateToolRowExpansion.
        coordinator.collectionView(collectionView, didSelectItemAt: targetIP)

        let offsetAfter = collectionView.contentOffset.y
        let drift = abs(offsetAfter - offsetBefore)

        #expect(drift < 2.0,
                "contentOffset drifted \(drift)pt after tap-expanding tool row at index \(targetIP.item)")
    }

    @MainActor
    @Test func toolRowExpansionViaTapDoesNotDetachNearBottomState() {
        // Bug: user is near bottom, taps a visible tool row to expand.
        // animateToolRowExpansion invalidates layout, scrollViewDidScroll fires
        // with negative deltaY, detachFromBottomForUserScroll() breaks follow.
        let window = makeScrollTestWindow()
        let collectionView = UICollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()
        let toolOutputStore = ToolOutputStore()
        let toolArgsStore = ToolArgsStore()

        var items: [ChatItem] = []
        for i in 0..<15 {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Line \(i) content. ", count: 10),
                timestamp: Date()
            ))
            toolArgsStore.set(["command": .string("cmd-\(i)")], for: "tc-\(i)")
            toolOutputStore.append("result \(i)\nmore output", to: "tc-\(i)")
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "cmd-\(i)",
                outputPreview: "result \(i)",
                outputByteCount: 64,
                isError: false, isDone: true
            ))
        }

        let config = makeTimelineConfiguration(
            items: items,
            sessionId: "s-nearbot",
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        coordinator.apply(configuration: config, to: collectionView)
        collectionView.layoutIfNeeded()

        // Scroll to bottom — attach.
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = maxOffset
        collectionView.layoutIfNeeded()
        scrollController.updateNearBottom(true)
        scrollController.requestScrollToBottom()

        #expect(scrollController.isCurrentlyNearBottom, "precondition: should be near bottom")

        // Find a visible tool row near the bottom.
        let visibleIPs = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let visibleToolIP = visibleIPs.last { ip in
            ip.item < items.count && items[ip.item].id.hasPrefix("tc-")
        }
        guard let targetIP = visibleToolIP else {
            Issue.record("No visible tool row near bottom — test setup error")
            return
        }

        coordinator.collectionView(collectionView, didSelectItemAt: targetIP)

        #expect(scrollController.isCurrentlyNearBottom,
                "expanding a visible tool row via tap should not detach from bottom")
    }

    @MainActor
    @Test func toolRowCollapseViaTapPreservesContentOffsetWhenScrolledUp() {
        // Mirror of the expansion test: collapse a visible expanded tool row
        // via tap. The row shrinks through animateToolRowExpansion. Without
        // offset compensation the viewport content jumps.
        let window = makeScrollTestWindow()
        let collectionView = UICollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()
        let toolOutputStore = ToolOutputStore()
        let toolArgsStore = ToolArgsStore()

        var items: [ChatItem] = []
        for i in 0..<30 {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Response \(i). ", count: 15),
                timestamp: Date()
            ))
            toolArgsStore.set(["command": .string("echo \(i)")], for: "tc-\(i)")
            toolOutputStore.append(
                String(repeating: "output \(i) line\n", count: 10),
                to: "tc-\(i)"
            )
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "echo \(i)",
                outputPreview: "output \(i)",
                outputByteCount: 200,
                isError: false, isDone: true
            ))
        }

        // Pre-expand several tool rows so we have an expanded one visible at
        // a mid-scroll position.
        for i in stride(from: 5, to: 20, by: 3) {
            reducer.expandedItemIDs.insert("tc-\(i)")
        }

        let config = makeTimelineConfiguration(
            items: items,
            sessionId: "s-collapse",
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        coordinator.apply(configuration: config, to: collectionView)
        collectionView.layoutIfNeeded()

        // Scroll to bottom then to mid.
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = maxOffset
        collectionView.layoutIfNeeded()

        let midY = maxOffset * 0.5
        collectionView.contentOffset.y = midY
        collectionView.layoutIfNeeded()
        scrollController.detachFromBottomForUserScroll()

        // Find a visible expanded tool row.
        let visibleIPs = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let expandedToolIP = visibleIPs.first { ip in
            ip.item < items.count
                && items[ip.item].id.hasPrefix("tc-")
                && reducer.expandedItemIDs.contains(items[ip.item].id)
        }
        guard let targetIP = expandedToolIP else {
            Issue.record("No visible expanded tool row at midpoint — test setup error")
            return
        }

        let offsetBefore = collectionView.contentOffset.y

        // Tap to collapse via real path.
        coordinator.collectionView(collectionView, didSelectItemAt: targetIP)

        let offsetAfter = collectionView.contentOffset.y
        let drift = abs(offsetAfter - offsetBefore)

        #expect(drift < 2.0,
                "contentOffset drifted \(drift)pt after tap-collapsing tool row at index \(targetIP.item)")
    }

    // MARK: - Expand/Collapse Anchor Stability

    /// Drain the main run loop so any `DispatchQueue.main.async` blocks
    /// (e.g. `invalidateEnclosingCollectionViewLayout`, anchor cleanup)
    /// execute within the test. Without this, async layout passes never
    /// fire and the test only validates synchronous state.
    @MainActor
    private func drainRunLoop(seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    @Test func debugAsyncLayoutPassDrift() {
        // Debug test: trace contentOffset changes during async layout passes
        // to find EXACTLY what causes drift after expand/collapse.
        let window = makeScrollTestWindow()
        let collectionView = AnchoredCollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()
        let toolOutputStore = ToolOutputStore()
        let toolArgsStore = ToolArgsStore()

        var items: [ChatItem] = []
        for i in 0..<20 {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Message \(i) text. ", count: 12),
                timestamp: Date()
            ))
            toolArgsStore.set(["command": .string("echo \(i)")], for: "tc-\(i)")
            toolOutputStore.append(
                String(repeating: "output \(i)\n", count: 8),
                to: "tc-\(i)"
            )
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "echo \(i)",
                outputPreview: "output \(i)",
                outputByteCount: 128,
                isError: false, isDone: true
            ))
        }

        let config = makeTimelineConfiguration(
            items: items,
            sessionId: "s-debug",
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        coordinator.apply(configuration: config, to: collectionView)
        collectionView.layoutIfNeeded()

        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = maxOffset
        collectionView.layoutIfNeeded()

        let midY = maxOffset * 0.5
        collectionView.contentOffset.y = midY
        collectionView.layoutIfNeeded()
        scrollController.detachFromBottomForUserScroll()

        let visibleIPs = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let targetIP = visibleIPs.first { ip in
            ip.item < items.count && items[ip.item].id.hasPrefix("tc-")
        }!

        let attrsBefore = collectionView.layoutAttributesForItem(at: targetIP)!
        let screenYBefore = attrsBefore.frame.origin.y - collectionView.contentOffset.y

        print("=== BEFORE EXPAND ===")
        print("contentOffset.y = \(collectionView.contentOffset.y)")
        print("contentSize.height = \(collectionView.contentSize.height)")
        print("target screenY = \(screenYBefore)")
        print("isDetachedFromBottom = \(collectionView.isDetachedFromBottom)")
        print("expandCollapseAnchorIP = \(String(describing: collectionView.expandCollapseAnchorIP))")

        coordinator.collectionView(collectionView, didSelectItemAt: targetIP)

        let attrsSync = collectionView.layoutAttributesForItem(at: targetIP)!
        let screenYSync = attrsSync.frame.origin.y - collectionView.contentOffset.y
        print("\n=== AFTER SYNC ===")
        print("contentOffset.y = \(collectionView.contentOffset.y)")
        print("contentSize.height = \(collectionView.contentSize.height)")
        print("target screenY = \(screenYSync)")
        print("sync shift = \(screenYSync - screenYBefore)")
        print("expandCollapseAnchorIP = \(String(describing: collectionView.expandCollapseAnchorIP))")

        // Drain one tick at a time
        for tick in 1...5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
            let attrsAfter = collectionView.layoutAttributesForItem(at: targetIP)!
            let screenYAfter = attrsAfter.frame.origin.y - collectionView.contentOffset.y
            print("\n=== TICK \(tick) ===")
            print("contentOffset.y = \(collectionView.contentOffset.y)")
            print("contentSize.height = \(collectionView.contentSize.height)")
            print("target screenY = \(screenYAfter)")
            print("total shift = \(screenYAfter - screenYBefore)")
            print("expandCollapseAnchorIP = \(String(describing: collectionView.expandCollapseAnchorIP))")
        }

        #expect(true) // Just logging
    }

    @MainActor
    @Test func repeatedExpandCollapseKeepsTappedRowScreenPosition() {
        // Bug: repeatedly tapping a tool row to expand/collapse causes the
        // collapsed bar to shift on screen. The tapped row's screen-relative
        // Y position must stay fixed across each toggle.
        //
        // This test drains the run loop after each toggle to catch drift from
        // deferred layout passes (invalidateEnclosingCollectionViewLayout).
        let window = makeScrollTestWindow()
        let collectionView = AnchoredCollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()
        let toolOutputStore = ToolOutputStore()
        let toolArgsStore = ToolArgsStore()

        var items: [ChatItem] = []
        for i in 0..<20 {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Message \(i) text. ", count: 12),
                timestamp: Date()
            ))
            toolArgsStore.set(["command": .string("echo \(i)")], for: "tc-\(i)")
            toolOutputStore.append(
                String(repeating: "output \(i)\n", count: 8),
                to: "tc-\(i)"
            )
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "echo \(i)",
                outputPreview: "output \(i)",
                outputByteCount: 128,
                isError: false, isDone: true
            ))
        }

        let config = makeTimelineConfiguration(
            items: items,
            sessionId: "s-repeat",
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        coordinator.apply(configuration: config, to: collectionView)
        collectionView.layoutIfNeeded()

        // Scroll to bottom so cells measure, then scroll to mid.
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = maxOffset
        collectionView.layoutIfNeeded()

        let midY = maxOffset * 0.5
        collectionView.contentOffset.y = midY
        collectionView.layoutIfNeeded()
        scrollController.detachFromBottomForUserScroll()

        // Find a visible tool row.
        let visibleIPs = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let targetIP = visibleIPs.first { ip in
            ip.item < items.count && items[ip.item].id.hasPrefix("tc-")
        }
        guard let targetIP else {
            Issue.record("No visible tool row at midpoint")
            return
        }

        // Toggle expand/collapse 6 times and check screen position AFTER
        // async layout passes settle (not just after the synchronous path).
        for round in 1...6 {
            guard let attrsBefore = collectionView.layoutAttributesForItem(at: targetIP) else {
                Issue.record("Missing layout attributes before toggle round \(round)")
                continue
            }
            let screenYBefore = attrsBefore.frame.origin.y - collectionView.contentOffset.y

            coordinator.collectionView(collectionView, didSelectItemAt: targetIP)

            // Drain the run loop to let deferred layout passes fire.
            drainRunLoop()

            guard let attrsAfter = collectionView.layoutAttributesForItem(at: targetIP) else {
                Issue.record("Missing layout attributes after toggle round \(round)")
                continue
            }
            let screenYAfter = attrsAfter.frame.origin.y - collectionView.contentOffset.y
            let shift = abs(screenYAfter - screenYBefore)

            #expect(shift < 2.0,
                    "Tool row shifted \(shift)pt on screen during toggle round \(round)")
        }
    }

    @MainActor
    @Test func expandCollapseAnchoringWorksWhenNearBottom() {
        // The original bug: user is near the bottom (isDetachedFromBottom is
        // false), taps to expand a tool row. Without the expand/collapse
        // anchor, AnchoredCollectionView skips anchoring entirely, and the
        // compositional layout shifts contentOffset.
        //
        // To match real usage, the test scrolls through ALL content first so
        // every cell is measured at its actual size (not 44pt estimate).
        // Otherwise the expand-triggered layoutIfNeeded re-estimates off-screen
        // cells, collapsing contentSize and making the anchor position
        // unreachable (clamped to maxOffsetY).
        let window = makeScrollTestWindow()
        let collectionView = AnchoredCollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()
        let toolOutputStore = ToolOutputStore()
        let toolArgsStore = ToolArgsStore()

        var items: [ChatItem] = []
        for i in 0..<15 {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Line \(i) content. ", count: 10),
                timestamp: Date()
            ))
            toolArgsStore.set(["command": .string("cmd \(i)")], for: "tc-\(i)")
            toolOutputStore.append(
                String(repeating: "result \(i)\n", count: 6),
                to: "tc-\(i)"
            )
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "cmd \(i)",
                outputPreview: "result \(i)",
                outputByteCount: 96,
                isError: false, isDone: true
            ))
        }

        let config = makeTimelineConfiguration(
            items: items,
            sessionId: "s-bottom",
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        coordinator.apply(configuration: config, to: collectionView)
        collectionView.layoutIfNeeded()

        // Scroll through all content so every cell is measured at its actual
        // height, matching real-world behavior where the user scrolls through
        // the conversation. Without this, off-screen cells have 44pt estimated
        // heights that collapse during the expand layout pass.
        let scrollStep: CGFloat = collectionView.bounds.height * 0.8
        var offset: CGFloat = 0
        while offset < collectionView.contentSize.height {
            collectionView.contentOffset.y = offset
            collectionView.layoutIfNeeded()
            offset += scrollStep
        }

        // Scroll to bottom — stay attached.
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = maxOffset
        collectionView.layoutIfNeeded()
        scrollController.updateNearBottom(true)

        #expect(scrollController.isCurrentlyNearBottom, "precondition: should be near bottom")
        #expect(!collectionView.isDetachedFromBottom,
                "precondition: collection view should not be detached")

        // Find a visible tool row.
        let visibleIPs = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let targetIP = visibleIPs.first { ip in
            ip.item < items.count && items[ip.item].id.hasPrefix("tc-")
        }
        guard let targetIP else {
            Issue.record("No visible tool row near bottom")
            return
        }

        guard let attrsBefore = collectionView.layoutAttributesForItem(at: targetIP) else {
            Issue.record("Missing layout attributes for target tool row")
            return
        }
        let screenYBefore = attrsBefore.frame.origin.y - collectionView.contentOffset.y

        // Expand — this is the scenario that was broken.
        coordinator.collectionView(collectionView, didSelectItemAt: targetIP)

        // Drain the run loop to let deferred layout passes fire.
        drainRunLoop()

        guard let attrsAfter = collectionView.layoutAttributesForItem(at: targetIP) else {
            Issue.record("Missing layout attributes after expand")
            return
        }
        let screenYAfter = attrsAfter.frame.origin.y - collectionView.contentOffset.y
        let shift = abs(screenYAfter - screenYBefore)

        #expect(shift < 2.0,
                "Tool row header shifted \(shift)pt when expanding near bottom")
    }

    // MARK: - Detached Scroll Stability with New Items

    @MainActor
    @Test func detachedScrollStaysStableWhenNewToolCallsArrive() {
        // Bug 2: user scrolls up (detaches), new tool calls arrive from
        // the agent. The viewport should not shift — the user should stay
        // at the same scroll position.
        let window = makeScrollTestWindow()
        let collectionView = AnchoredCollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        let reducer = TimelineReducer()
        let scrollController = ChatScrollController()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()
        let toolOutputStore = ToolOutputStore()
        let toolArgsStore = ToolArgsStore()

        var items: [ChatItem] = []
        for i in 0..<20 {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Message \(i). ", count: 10),
                timestamp: Date()
            ))
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "cmd \(i)",
                outputPreview: "result \(i)",
                outputByteCount: 64,
                isError: false, isDone: true
            ))
        }
        // Streaming assistant at the end.
        items.append(.assistantMessage(
            id: "stream-1",
            text: "Working...",
            timestamp: Date()
        ))

        func applyItems(
            _ currentItems: [ChatItem],
            streamingID: String? = nil,
            isBusy: Bool = true
        ) {
            let config = makeTimelineConfiguration(
                items: currentItems,
                isBusy: isBusy,
                streamingAssistantID: streamingID,
                sessionId: "s-detach",
                reducer: reducer,
                toolOutputStore: toolOutputStore,
                toolArgsStore: toolArgsStore,
                connection: connection,
                scrollController: scrollController,
                audioPlayer: audioPlayer
            )
            coordinator.apply(configuration: config, to: collectionView)
            collectionView.layoutIfNeeded()
        }

        applyItems(items, streamingID: "stream-1")

        // Scroll through all content so cells are measured.
        let scrollStep: CGFloat = collectionView.bounds.height * 0.8
        var scrollY: CGFloat = 0
        while scrollY < collectionView.contentSize.height {
            collectionView.contentOffset.y = scrollY
            collectionView.layoutIfNeeded()
            scrollY += scrollStep
        }

        // Scroll to bottom, then to mid — detach.
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = maxOffset
        collectionView.layoutIfNeeded()

        let midY = maxOffset * 0.5
        collectionView.contentOffset.y = midY
        collectionView.layoutIfNeeded()
        scrollController.detachFromBottomForUserScroll()

        let anchorOffset = collectionView.contentOffset.y

        // New tool calls arrive (simulating agent running tools).
        for j in 0..<5 {
            items.append(.toolCall(
                id: "tc-new-\(j)", tool: "bash",
                argsSummary: "new cmd \(j)",
                outputPreview: "new result \(j)",
                outputByteCount: 64,
                isError: false, isDone: j < 4
            ))
        }
        items.append(.assistantMessage(
            id: "stream-2",
            text: String(repeating: "More output. ", count: 10),
            timestamp: Date()
        ))

        applyItems(items, streamingID: "stream-2")
        drainRunLoop()

        let driftAfterNewTools = abs(collectionView.contentOffset.y - anchorOffset)
        #expect(driftAfterNewTools < 2.0,
                "Detached viewport drifted \(driftAfterNewTools)pt when new tool calls arrived")

        #expect(!scrollController.isCurrentlyNearBottom,
                "User should still be detached after new tool calls")
    }
}
