import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Session timeline navigation", .serialized)
@MainActor
struct SessionTimelineNavigationTests {
    enum OutlineScenario: CaseIterable {
        case firstUser, assistant, tool, quietTool, pagedFirstUser

        var targetID: String {
            switch self {
            case .firstUser, .pagedFirstUser: "entry-0"
            case .assistant: "entry-19"
            case .tool, .quietTool: "entry-21"
            }
        }
    }

    @Test(arguments: OutlineScenario.allCases)
    func outlineSelectionFromAttachedWindowedTimelineLandsAndHighlights(scenario: OutlineScenario) async throws {
        let targetID = scenario.targetID
        let manager = ChatSessionManager(sessionId: "outline-hosted")
        let reducer = manager.reducer
        let events = (0..<301).map { index in
            TraceEvent(
                id: "entry-\(index)",
                type: index == 21 ? .toolCall : (index.isMultiple(of: 2) ? .user : .assistant),
                timestamp: "2026-09-07T10:00:00Z",
                text: "Message \(index). " + String(repeating: "Timeline navigation context. ", count: 4),
                tool: index == 21 ? "bash" : nil, args: nil, output: nil, toolCallId: nil,
                toolName: nil, isError: nil, thinking: nil
            )
        }
        reducer.loadSession(scenario == .pagedFirstUser ? Array(events.suffix(100)) : events)
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()
        let scrollController = ChatScrollController()
        manager.needsInitialScroll = true
        let timeline = ChatTimelineView(
            sessionId: manager.sessionId, serverId: nil, workspaceId: nil,
            isBusy: false, extensionWorkingState: nil, extensionHiddenThinkingLabel: nil,
            currentModel: nil, connection: connection, scrollController: scrollController,
            sessionManager: manager, audioLifecycleCoordinator: nil,
            quietModeEnabled: scenario == .quietTool,
            onFork: { _ in }, onOpenCurrentFile: { _ in }, onBackSwipe: {}, reviewCommentSelectionRouter: nil,
            topOverlap: 160, bottomOverlap: 0
        )
        let host = UIHostingController(rootView:
            NavigationStack { timeline.navigationTitle("Chat") }
                .environment(reducer)
                .environment(audioPlayer)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let ready = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                host.view.layoutIfNeeded()
                return scrollController.currentTopVisibleItemId != nil && !manager.needsInitialScroll
            }
        }
        #expect(ready)
        let cv = try #require(timelineFirstView(ofType: UICollectionView.self, in: host.view))
        let coordinator = try #require(cv.delegate as? ChatTimelineCollectionHost.Controller)
        #expect(!coordinator.currentIDs.contains(targetID), "Setup must retain the real 80-row render window")
        #expect(scrollController.isCurrentlyNearBottom)

        // Invoke the actual ChatView onSelect/load/scrollTargetID path while
        // an outline sheet covers the mounted, windowed SwiftUI timeline.
        // No pre-expansion, manual detach, scroll command, or highlight injection.
        var didLoadTarget = false
        let outline = SessionOutlineView(
            items: reducer.items, sessionId: manager.sessionId, workspaceId: nil,
            onSelect: { selectedID in
                ChatView.selectOutlineTimelineEntry(
                    selectedID, items: reducer.items, scrollController: scrollController
                ) {
                    didLoadTarget = true
                    await Task.yield()
                    #expect(reducer.prependTracePage(Array(events.prefix(201))))
                }
            }
        )
        let sheet = UIHostingController(rootView: outline.environment(reducer.toolArgsStore))
        sheet.modalPresentationStyle = .pageSheet
        host.present(sheet, animated: false)
        #expect(host.presentedViewController === sheet)
        outline.onSelect(targetID)
        if scenario != .pagedFirstUser {
            #expect(scrollController.scrollTargetID == targetID)
        }
        host.dismiss(animated: false)
        let landedAndHighlighted = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                host.view.layoutIfNeeded()
                cv.layoutIfNeeded()
                guard host.presentedViewController == nil,
                      let index = coordinator.currentIDs.firstIndex(of: targetID),
                      let cell = cv.cellForItem(at: IndexPath(item: index, section: 0)) as? SafeSizingCell,
                      let attributes = cv.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else {
                    return false
                }
                let relativeY = attributes.frame.minY - cv.contentOffset.y
                return abs(relativeY - cv.adjustedContentInset.top) < 8
                    && cell.isShowingNavigationHighlightForTesting
            }
        }
        #expect(landedAndHighlighted, "Expected outline selection to expand, land and highlight; top=\(scrollController.currentTopVisibleItemId ?? "nil"), attached=\(scrollController.isCurrentlyNearBottom), target=\(scrollController.scrollTargetID ?? "nil")")
        #expect(didLoadTarget == (scenario == .pagedFirstUser))
        #expect(!scrollController.isCurrentlyNearBottom, "Outline navigation must release tail-follow intent")
        // A later timeline publication must not erase a successful jump.
        let newTailID = reducer.appendUserMessage("A new live message")
        let retainedLanding = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                host.view.layoutIfNeeded()
                cv.layoutIfNeeded()
                guard coordinator.currentIDs.contains(newTailID),
                      let index = coordinator.currentIDs.firstIndex(of: targetID),
                      let attrs = cv.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { return false }
                return abs(attrs.frame.minY - cv.contentOffset.y - cv.adjustedContentInset.top) < 8
            }
        }
        let targetIndex = coordinator.currentIDs.firstIndex(of: targetID)
        let targetY = targetIndex.flatMap { cv.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame.minY }
        #expect(retainedLanding, "New publication must preserve the outline landing; count=\(coordinator.currentIDs.count), first=\(coordinator.currentIDs.first ?? "nil"), targetY=\(targetY ?? -999), offset=\(cv.contentOffset.y), inset=\(cv.adjustedContentInset.top), top=\(scrollController.currentTopVisibleItemId ?? "nil"), attached=\(scrollController.isCurrentlyNearBottom)")
    }

    @Test func detachedNavigationExpandsHistoryAndLandsOnSelectedAssistantMessage() async throws {
        let result = await navigateFromDetachedTail(to: "msg-20")
        #expect(
            result.reachedTarget,
            "Expected timeline navigation to land on msg-20; top=\(result.topVisible), visible=\(result.visibleIDs)"
        )
        #expect(result.didHighlightTarget, "Expected assistant target row to flash after navigation")
        #expect(result.highlightOverlayFrontmost, "Expected assistant highlight overlay to render above row content")
    }

    @Test func detachedNavigationExpandsHistoryAndLandsOnFirstTimelineRow() async throws {
        let result = await navigateFromDetachedTail(to: "msg-0", topOverlap: 160)
        #expect(
            result.reachedTarget,
            "Expected timeline navigation to land on msg-0; top=\(result.topVisible), visible=\(result.visibleIDs)"
        )
        #expect(
            result.landedBelowTopChrome,
            "Expected first row to sit below top chrome, not under the navigation bar"
        )
        #expect(result.didHighlightTarget, "Expected first-row target to flash after navigation")
    }

    @Test func scrollingToTopKeepsFirstCommitRowBelowChrome() async throws {
        let harness = makeWindowedTimelineHarness(
            sessionId: "session-commit-first-row",
            useAnchoredCollectionView: true
        )
        defer {
            harness.window.isHidden = true
            harness.window.rootViewController = nil
        }

        let commitText = """
        Is this fix even a real fix?

        Selected commit:
        - SHA: 0486bc75
        - Message: keep first chat row below nav
        """
        var items: [ChatItem] = [
            .userMessage(
                id: "msg-0",
                text: commitText,
                images: [],
                timestamp: Date(timeIntervalSince1970: 0)
            )
        ]
        items.append(contentsOf: (1..<10).map { index in
            .assistantMessage(
                id: "msg-\(index)",
                text: Array(
                    repeating: "Follow-up line \(index) with enough text to need scrolling.",
                    count: 6
                ).joined(separator: "\n"),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        })

        applyTimelineItems(
            items,
            hiddenCount: 0,
            nonce: nil,
            topOverlap: 160,
            to: harness
        )

        let collectionView = harness.collectionView
        let minOffsetY = -collectionView.adjustedContentInset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: minOffsetY), animated: false)
        settleTimelineLayout(collectionView, passes: 3)

        #expect(
            abs(collectionView.contentOffset.y - minOffsetY) < 0.5,
            "Pull-to-top must reach min offset when the first row has a commit chip"
        )

        let cell = try #require(timelineCell(for: "msg-0", in: harness))
        let pill = try #require(
            firstSubview(withAccessibilityIdentifier: "chat.user.path-pill.0486bc75", in: cell)
        )
        let pillInContent = cell.convert(pill.frame, to: collectionView)
        let pillInBoundsMinY = pillInContent.minY - collectionView.contentOffset.y
        #expect(
            pillInBoundsMinY >= collectionView.adjustedContentInset.top - 0.5,
            "Commit chip must not sit under the nav when pulled to the top"
        )
        #expect(pill is UIControl)
    }

    @Test func streamingNoOpApplyStillHonorsOutlineScrollCommand() async throws {
        let harness = makeWindowedTimelineHarness(
            sessionId: "session-outline-streaming-noop",
            useAnchoredCollectionView: true
        )
        let items = makeMixedTimelineItems(count: 12)
        applyTimelineItems(
            items,
            hiddenCount: 0,
            nonce: 1,
            streamingAssistantID: "msg-10",
            to: harness
        )
        harness.scrollController.detachFromBottomForUserScroll()
        if let anchoredCV = harness.collectionView as? AnchoredCollectionView {
            anchoredCV.isDetachedFromBottom = true
        }

        applyTimelineItems(
            items,
            hiddenCount: 0,
            nonce: 2,
            scrollTargetID: "msg-0",
            streamingAssistantID: "msg-10",
            topOverlap: 160,
            to: harness
        )

        let landed = await waitForTimelineCondition(timeoutMs: 500) {
            await MainActor.run {
                settleTimelineLayout(harness.collectionView, passes: 3)
                return firstItemIsBelowTopChrome("msg-0", in: harness)
            }
        }
        #expect(landed, "Expected outline jump to survive a structurally unchanged streaming apply")
    }

    @Test(arguments: [false, true])
    func outlineCommandOnlySuppressesTailReconciliationWhilePending(isPending: Bool) {
        let harness = makeTimelineHarness(sessionId: "outline-return-to-tail")
        let cv = TimelineScrollMetricsCollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 500)
        )
        cv.layoutIfNeeded()
        cv.testContentSize = CGSize(width: 390, height: 2_000)
        cv.testAdjustedContentInset = .zero
        harness.scrollController.detachFromBottomForUserScroll()
        cv.contentOffset.y = 1_500
        harness.coordinator.updateScrollState(cv)
        #expect(harness.scrollController.isCurrentlyNearBottom)

        // Isolate the post-apply policy from UIKit's own offset preservation.
        // The rendered tail grows after the user has reattached at the bottom.
        cv.testContentSize.height += 24
        let configuration = makeTimelineConfiguration(
            scrollCommand: ChatTimelineScrollCommand(id: "tool-1", anchor: .top, animated: false, nonce: 42),
            sessionId: harness.sessionId,
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.reconcileScrollAfterTimelineApply(
            didScroll: isPending,
            hadPendingScrollCommand: isPending,
            configuration: configuration,
            collectionView: cv,
            itemCount: 1,
            structuralAppend: true
        )
        #expect(cv.contentOffset.y == (isPending ? 1_500 : 1_524))
    }

    @Test func detachedNavigationExpandsHistoryAndLandsOnSelectedToolRow() async throws {
        let result = await navigateFromDetachedTail(to: "tool-21")
        #expect(
            result.reachedTarget,
            "Expected timeline navigation to land on tool-21; top=\(result.topVisible), visible=\(result.visibleIDs)"
        )
        #expect(result.didHighlightTarget, "Expected tool target row to flash after navigation")
        #expect(result.highlightOverlayFrontmost, "Expected tool highlight overlay to render above row content")
    }

    @Test func navigationReentryRestoresStableItemAtExactRelativeViewportPosition() async throws {
        let harness = makeWindowedTimelineHarness(
            sessionId: "session-document-reentry",
            useAnchoredCollectionView: true
        )
        let originalItems = makeMixedTimelineItems(count: 50)
        applyTimelineItems(originalItems, hiddenCount: 0, nonce: nil, to: harness)

        let anchorID = "msg-20"
        let anchorIndex = try #require(harness.coordinator.currentIDs.firstIndex(of: anchorID))
        let anchorPath = IndexPath(item: anchorIndex, section: 0)
        settleTimelineLayout(harness.collectionView, passes: 3)
        let anchorAttrs = try #require(
            harness.collectionView.layoutAttributesForItem(at: anchorPath)
        )
        harness.scrollController.detachFromBottomForUserScroll()
        if let anchoredCV = harness.collectionView as? AnchoredCollectionView {
            anchoredCV.isDetachedFromBottom = true
        }
        setTimelineUserScrollOffsetY(
            harness.collectionView,
            anchorAttrs.frame.minY - harness.collectionView.adjustedContentInset.top + 37
        )
        harness.coordinator.updateScrollState(
            harness.collectionView,
            preserveDetachedState: true
        )

        let before = try #require(
            harness.collectionView.layoutAttributesForItem(
                at: IndexPath(item: anchorIndex, section: 0)
            )
        ).frame.minY - harness.collectionView.contentOffset.y
        #expect(
            abs(before + 37) < 8,
            "setup should place \(anchorID) near -37pt, got relativeY=\(before) offset=\(harness.collectionView.contentOffset.y) minY=\(anchorAttrs.frame.minY)"
        )
        harness.scrollController.suspendForNavigation()

        let changedItems: [ChatItem] = [
            .assistantMessage(id: "new-prefix", text: "New context while reading the document", timestamp: Date()),
        ] + originalItems + [
            .assistantMessage(id: "new-tail", text: "New live-tail context", timestamp: Date()),
        ]
        harness.scrollController.needsInitialScroll = true
        let changedIDs = changedItems.map(\.id)
        let placement = try #require(harness.scrollController.initialPlacement(
            availableFullTimelineItemIDs: changedIDs,
            bottomItemID: "new-tail"
        ))
        guard case .viewport(let restoration) = placement else {
            Issue.record("Expected detached viewport restoration, got \(placement)")
            return
        }

        let command = ChatTimelineScrollCommand(
            id: restoration.itemID,
            anchor: .viewport(relativeY: restoration.relativeY),
            animated: false,
            nonce: 7
        )
        let config = makeTimelineConfiguration(
            items: changedItems,
            isBusy: false,
            scrollCommand: command,
            sessionId: harness.sessionId,
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            toolSegmentStore: harness.toolSegmentStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let restored = await waitForTimelineCondition(timeoutMs: 500) {
            await MainActor.run {
                settleTimelineLayout(harness.collectionView, passes: 3)
                guard let index = harness.coordinator.currentIDs.firstIndex(of: anchorID),
                      let attributes = harness.collectionView.layoutAttributesForItem(
                          at: IndexPath(item: index, section: 0)
                      ) else {
                    return false
                }
                let after = attributes.frame.minY - harness.collectionView.contentOffset.y
                return abs(after - before) < 2
            }
        }

        #expect(restored, "Expected \(anchorID) to return to relativeY=\(before)")
    }

    @Test func viewportCorrectionDoesNotReattachDuringEstimatedLayout() {
        let harness = makeWindowedTimelineHarness(
            sessionId: "session-document-estimated-layout",
            useAnchoredCollectionView: true
        )
        applyTimelineItems(
            makeMixedTimelineItems(count: 2),
            hiddenCount: 0,
            nonce: nil,
            to: harness
        )
        harness.scrollController.detachFromBottomForUserScroll()

        harness.coordinator.updateScrollState(
            harness.collectionView,
            preserveDetachedState: true
        )

        #expect(!harness.scrollController.isCurrentlyNearBottom)

        // The same geometry would normally enter near-bottom hysteresis; only
        // navigation restoration suppresses that transient reattachment.
        harness.coordinator.updateScrollState(harness.collectionView)
        #expect(harness.scrollController.isCurrentlyNearBottom)
    }

    @Test func windowedReentryUsesAbsoluteFullTimelineOrdinalForFallback() throws {
        let harness = makeWindowedTimelineHarness(
            sessionId: "session-windowed-document-reentry",
            useAnchoredCollectionView: true
        )
        let allItems = makeMixedTimelineItems(count: 240)
        let visibleItems = Array(allItems.suffix(80))
        applyTimelineItems(
            visibleItems,
            hiddenCount: allItems.count - visibleItems.count,
            nonce: nil,
            to: harness
        )

        // `currentIDs` is the rendered suffix, but viewport restoration must
        // retain the absolute ordinal from the complete timeline.
        harness.scrollController.updateTimelineItemOrder(allItems.map(\.id))
        let anchorID = "msg-180"
        let anchorIndex = try #require(harness.coordinator.currentIDs.firstIndex(of: anchorID))
        harness.collectionView.scrollToItem(
            at: IndexPath(item: anchorIndex, section: 0),
            at: .top,
            animated: false
        )
        settleTimelineLayout(harness.collectionView, passes: 3)
        setTimelineUserScrollOffsetY(
            harness.collectionView,
            harness.collectionView.contentOffset.y + 37
        )
        harness.scrollController.detachFromBottomForUserScroll()
        // Pin the known anchor explicitly: the collection is windowed, while
        // the controller's saved ordinal comes from the full timeline order.
        harness.scrollController.updateViewportAnchor(itemID: anchorID, relativeY: -37)
        harness.scrollController.suspendForNavigation()

        let availableFullTimelineItemIDs = (0..<240).map { "replacement-\($0)" }
        let placement = try #require(harness.scrollController.initialPlacement(
            availableFullTimelineItemIDs: availableFullTimelineItemIDs,
            bottomItemID: "replacement-239"
        ))
        guard case .viewport(let restoration) = placement else {
            Issue.record("Expected detached viewport restoration, got \(placement)")
            return
        }

        #expect(restoration.itemID == "replacement-180")
        #expect(restoration.relativeY == -37)
    }
}

private struct NavigationResult {
    let reachedTarget: Bool
    let didHighlightTarget: Bool
    let highlightOverlayFrontmost: Bool
    let landedBelowTopChrome: Bool
    let topVisible: String
    let visibleIDs: [String]
}

@MainActor
private func navigateFromDetachedTail(
    to targetID: String,
    topOverlap: CGFloat = 0
) async -> NavigationResult {
    let harness = makeWindowedTimelineHarness(
        sessionId: "session-outline-navigation-\(targetID)",
        useAnchoredCollectionView: true
    )
    let allItems = makeMixedTimelineItems(count: 120)
    let visibleTail = Array(allItems.suffix(40))

    applyTimelineItems(
        visibleTail,
        hiddenCount: allItems.count - visibleTail.count,
        nonce: nil,
        topOverlap: topOverlap,
        to: harness
    )

    harness.collectionView.scrollToItem(at: IndexPath(item: 15, section: 0), at: .top, animated: false)
    settleTimelineLayout(harness.collectionView, passes: 2)
    harness.coordinator.updateScrollState(harness.collectionView)
    harness.scrollController.detachFromBottomForUserScroll()

    harness.scrollController.requestNavigationHighlight(for: targetID)
    applyTimelineItems(
        allItems,
        hiddenCount: 0,
        nonce: 2,
        scrollTargetID: targetID,
        topOverlap: topOverlap,
        to: harness
    )

    let reachedTarget = await waitForTimelineCondition(timeoutMs: 500) {
        await MainActor.run {
            settleTimelineLayout(harness.collectionView, passes: 3)
            harness.coordinator.updateScrollState(harness.collectionView)
            return harness.scrollController.currentTopVisibleItemId == targetID
        }
    }

    let didHighlightTarget = await waitForTimelineCondition(timeoutMs: 400) {
        await MainActor.run {
            guard let highlightedCell = timelineCell(for: targetID, in: harness) else { return false }
            return highlightedCell.isShowingNavigationHighlightForTesting
        }
    }

    let highlightOverlayFrontmost = await MainActor.run {
        timelineCell(for: targetID, in: harness)?.isNavigationHighlightOverlayFrontmostForTesting ?? false
    }

    let landedBelowTopChrome = await MainActor.run {
        firstItemIsBelowTopChrome(targetID, in: harness)
    }

    return NavigationResult(
        reachedTarget: reachedTarget,
        didHighlightTarget: didHighlightTarget,
        highlightOverlayFrontmost: highlightOverlayFrontmost,
        landedBelowTopChrome: landedBelowTopChrome,
        topVisible: harness.scrollController.currentTopVisibleItemId ?? "nil",
        visibleIDs: visibleTimelineIDs(in: harness)
    )
}

@MainActor
private func applyTimelineItems(
    _ items: [ChatItem],
    hiddenCount: Int,
    nonce: Int?,
    scrollTargetID: String? = nil,
    streamingAssistantID: String? = nil,
    topOverlap: CGFloat = 0,
    to harness: WindowedTimelineHarness
) {
    let scrollCommand: ChatTimelineScrollCommand? = if let nonce, let scrollTargetID {
        ChatTimelineScrollCommand(
            id: scrollTargetID,
            anchor: .top,
            animated: false,
            nonce: nonce
        )
    } else {
        nil
    }

    let config = makeTimelineConfiguration(
        items: items,
        hiddenCount: hiddenCount,
        isBusy: streamingAssistantID != nil,
        streamingAssistantID: streamingAssistantID,
        scrollCommand: scrollCommand,
        sessionId: harness.sessionId,
        reducer: harness.reducer,
        toolOutputStore: harness.toolOutputStore,
        toolArgsStore: harness.toolArgsStore,
        toolSegmentStore: harness.toolSegmentStore,
        connection: harness.connection,
        scrollController: harness.scrollController,
        audioPlayer: harness.audioPlayer,
        topOverlap: topOverlap
    )
    harness.coordinator.apply(configuration: config, to: harness.collectionView)
    settleTimelineLayout(harness.collectionView, passes: 2)
}

@MainActor
private func firstItemIsBelowTopChrome(_ itemID: String, in harness: WindowedTimelineHarness) -> Bool {
    guard let index = harness.coordinator.currentIDs.firstIndex(of: itemID),
          let attributes = harness.collectionView.layoutAttributesForItem(
            at: IndexPath(item: index, section: 0)
          ) else {
        return false
    }
    let insets = harness.collectionView.adjustedContentInset
    let relativeY = attributes.frame.minY - harness.collectionView.contentOffset.y
    return abs(relativeY - insets.top) < 8
}

private func makeMixedTimelineItems(count: Int) -> [ChatItem] {
    (0..<count).map { index in
        if index.isMultiple(of: 2) {
            let text = Array(repeating: "Message \(index) line with enough text to wrap across the cell.", count: 4)
                .joined(separator: "\n")
            return .assistantMessage(
                id: "msg-\(index)",
                text: text,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let output = Array(repeating: "output \(index)", count: 6).joined(separator: "\n")
        return .toolCall(
            id: "tool-\(index)",
            tool: "bash",
            argsSummary: "printf 'row \(index)'",
            outputPreview: output,
            outputByteCount: output.utf8.count,
            isError: false,
            isDone: true
        )
    }
}

@MainActor
private func visibleTimelineIDs(in harness: WindowedTimelineHarness) -> [String] {
    harness.collectionView.indexPathsForVisibleItems
        .sorted { $0.item < $1.item }
        .compactMap { indexPath in
            guard indexPath.item < harness.coordinator.currentIDs.count else { return nil }
            return harness.coordinator.currentIDs[indexPath.item]
        }
}

@MainActor
private func timelineCell(for itemID: String, in harness: WindowedTimelineHarness) -> SafeSizingCell? {
    guard let index = harness.coordinator.currentIDs.firstIndex(of: itemID) else { return nil }
    return harness.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SafeSizingCell
}

@MainActor
private func firstSubview(withAccessibilityIdentifier identifier: String, in root: UIView) -> UIView? {
    if root.accessibilityIdentifier == identifier {
        return root
    }
    for child in root.subviews {
        if let match = firstSubview(withAccessibilityIdentifier: identifier, in: child) {
            return match
        }
    }
    return nil
}
