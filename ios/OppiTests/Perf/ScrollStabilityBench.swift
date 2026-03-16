import Foundation
import Testing
import UIKit
@testable import Oppi

/// Benchmarks for scroll stability during streaming.
///
/// Measures the overhead of the AnchoredCollectionView anchoring system
/// and verifies correctness (viewport drift < 2pt) during simulated
/// streaming sessions.
///
/// Output format: `METRIC name=number` for autoresearch consumption.
@Suite("ScrollStabilityBench")
struct ScrollStabilityBench {

    // MARK: - Configuration

    /// Number of streaming append rounds per benchmark iteration.
    private static let streamingRounds = 20

    /// Number of full benchmark iterations (median of these).
    private static let iterations = 3

    // MARK: - Primary: Streaming while detached

    @MainActor
    @Test func streaming_detached() {
        var allAnchorUs: [Double] = []
        var allApplyUs: [Double] = []
        var worstDrift: CGFloat = 0
        var worstDidSetEntries = 0
        var worstDidSetCorrections = 0

        for _ in 0 ..< Self.iterations {
            let result = runStreamingDetachedCycle()
            allAnchorUs.append(result.anchorOverheadUs)
            allApplyUs.append(result.applyUs)
            worstDrift = max(worstDrift, result.maxDrift)
            worstDidSetEntries = max(worstDidSetEntries, result.didSetEntries)
            worstDidSetCorrections = max(worstDidSetCorrections, result.didSetCorrections)
        }

        allAnchorUs.sort()
        allApplyUs.sort()
        let medianAnchorUs = allAnchorUs[allAnchorUs.count / 2]
        let medianApplyUs = allApplyUs[allApplyUs.count / 2]

        print("METRIC anchor_overhead_us=\(Int(medianAnchorUs))")
        print("METRIC apply_total_us=\(Int(medianApplyUs))")
        print("METRIC max_drift_pt=\(Int(worstDrift * 100))")
        print("METRIC didset_entry_count=\(worstDidSetEntries)")
        print("METRIC didset_correction_count=\(worstDidSetCorrections)")
        print("METRIC per_append_anchor_us=\(Int(medianAnchorUs / Double(Self.streamingRounds)))")

        // Correctness gate: if drift exceeds 2pt, the benchmark fails.
        #expect(
            worstDrift < 2.0,
            "Viewport drifted \(worstDrift)pt during \(Self.streamingRounds) streaming appends while detached"
        )
    }

    // MARK: - Secondary: Expand/collapse while detached

    @MainActor
    @Test func expand_collapse_detached() {
        let toggleRounds = 6

        var allToggleUs: [Double] = []
        var worstShift: CGFloat = 0

        for _ in 0 ..< Self.iterations {
            let result = runExpandCollapseCycle(toggles: toggleRounds)
            allToggleUs.append(result.totalUs)
            worstShift = max(worstShift, result.maxShift)
        }

        allToggleUs.sort()
        let medianUs = allToggleUs[allToggleUs.count / 2]

        print("METRIC expand_collapse_us=\(Int(medianUs))")
        print("METRIC expand_collapse_max_shift_pt=\(Int(worstShift * 100))")

        #expect(
            worstShift < 2.0,
            "Tool row shifted \(worstShift)pt during \(toggleRounds) expand/collapse toggles"
        )
    }

    // MARK: - Secondary: Upward scroll stutter

    @MainActor
    @Test func upward_scroll_stutter() {
        let result = runUpwardScrollCycle(steps: 30)

        print("METRIC upward_stutter_max_pt=\(Int(result.maxStutter * 100))")
        print("METRIC upward_stutter_count=\(result.stutterSteps)")

        #expect(
            result.maxStutter < 4.0,
            "Anchor stuttered \(result.maxStutter)pt during upward scroll"
        )
    }

    // MARK: - Scenario Implementations

    private struct StreamingResult {
        let anchorOverheadUs: Double
        let applyUs: Double
        let maxDrift: CGFloat
        let didSetEntries: Int
        let didSetCorrections: Int
    }

    @MainActor
    private func runStreamingDetachedCycle() -> StreamingResult {
        let harness = makeRealHarness(itemCount: 30)
        let cv = harness.collectionView

        // Scroll to bottom so all cells measure at actual heights.
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // Scroll to mid-point and detach.
        let maxOffset = maxOffsetY(cv)
        cv.contentOffset.y = maxOffset * 0.4
        cv.layoutIfNeeded()
        harness.scrollController.detachFromBottomForUserScroll()

        let anchorOffset = cv.contentOffset.y
        var maxDrift: CGFloat = 0
        var totalApplyNanos: UInt64 = 0

        // Reset instrumentation counters.
        cv._debugResetCounters()

        // Stream 20 rounds of content growth.
        for round in 1 ... Self.streamingRounds {
            // Grow the streaming assistant text.
            let lastIdx = harness.items.count - 1
            harness.items[lastIdx] = .assistantMessage(
                id: "stream-1",
                text: String(repeating: "Streaming round \(round) content. ", count: round * 5),
                timestamp: Date()
            )

            // Every 4th round, also append a new tool call at the bottom.
            if round.isMultiple(of: 4) {
                harness.items.append(.toolCall(
                    id: "tc-new-\(round)", tool: "bash",
                    argsSummary: "cmd \(round)",
                    outputPreview: "result \(round)",
                    outputByteCount: 64,
                    isError: false, isDone: true
                ))
                // Re-add streaming message at end.
                let streamMsg = harness.items.remove(at: lastIdx)
                harness.items.append(streamMsg)
            }

            // Timed apply.
            let applyStart = DispatchTime.now().uptimeNanoseconds
            harness.applyItems(streamingID: "stream-1", isBusy: true)
            cv.layoutIfNeeded()
            totalApplyNanos += DispatchTime.now().uptimeNanoseconds &- applyStart

            // Drain run loop: 3 frames to let cascade settle.
            for _ in 0 ..< 3 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.017))
            }
            cv.layoutIfNeeded()

            let drift = abs(cv.contentOffset.y - anchorOffset)
            maxDrift = max(maxDrift, drift)
        }

        let anchorOverheadUs = Double(cv._debugDidSetNanos + cv._debugLayoutAnchorNanos) / 1000.0
        let applyUs = Double(totalApplyNanos) / 1000.0

        return StreamingResult(
            anchorOverheadUs: anchorOverheadUs,
            applyUs: applyUs,
            maxDrift: maxDrift,
            didSetEntries: cv._debugDidSetEntryCount,
            didSetCorrections: cv._debugDidSetCorrectionCount
        )
    }

    private struct ExpandCollapseResult {
        let totalUs: Double
        let maxShift: CGFloat
    }

    @MainActor
    private func runExpandCollapseCycle(toggles: Int) -> ExpandCollapseResult {
        let harness = makeRealHarness(itemCount: 30, withToolOutput: true)
        let cv = harness.collectionView

        // Scroll through all content so cells measure.
        scrollThroughAll(cv)
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // Scroll to mid, detach.
        let maxOff = maxOffsetY(cv)
        cv.contentOffset.y = maxOff * 0.5
        cv.layoutIfNeeded()
        harness.scrollController.detachFromBottomForUserScroll()

        // Find a visible tool row.
        let visibleIPs = cv.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let targetIP = visibleIPs.first { ip in
            ip.item < harness.items.count && harness.items[ip.item].id.hasPrefix("tc-")
        }
        guard let targetIP else {
            return ExpandCollapseResult(totalUs: 0, maxShift: 999)
        }

        var maxShift: CGFloat = 0
        let startNanos = DispatchTime.now().uptimeNanoseconds

        for _ in 1 ... toggles {
            let attrsBefore = cv.layoutAttributesForItem(at: targetIP)
            let screenYBefore = (attrsBefore?.frame.origin.y ?? 0) - cv.contentOffset.y

            harness.coordinator.collectionView(cv, didSelectItemAt: targetIP)
            // Drain for cascade settlement.
            for _ in 0 ..< 5 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.017))
            }

            let attrsAfter = cv.layoutAttributesForItem(at: targetIP)
            let screenYAfter = (attrsAfter?.frame.origin.y ?? 0) - cv.contentOffset.y
            maxShift = max(maxShift, abs(screenYAfter - screenYBefore))
        }

        let totalNanos = DispatchTime.now().uptimeNanoseconds &- startNanos
        // Subtract sleep time: toggles * 5 frames * 17ms
        let sleepNanos = UInt64(toggles * 5) * 17_000_000
        let activeNanos = totalNanos > sleepNanos ? totalNanos - sleepNanos : totalNanos

        return ExpandCollapseResult(
            totalUs: Double(activeNanos) / 1000.0,
            maxShift: maxShift
        )
    }

    private struct UpwardScrollResult {
        let maxStutter: CGFloat
        let stutterSteps: Int
    }

    @MainActor
    private func runUpwardScrollCycle(steps: Int) -> UpwardScrollResult {
        let harness = makeRealHarness(itemCount: 40)
        let cv = harness.collectionView

        // Apply and scroll to bottom.
        scrollToBottom(cv)
        cv.layoutIfNeeded()
        harness.scrollController.detachFromBottomForUserScroll()

        let scrollStep: CGFloat = 60
        var maxStutter: CGFloat = 0
        var stutterSteps = 0

        for _ in 1 ... steps {
            guard let anchorIP = cv.indexPathsForVisibleItems.min(by: { $0.item < $1.item }),
                  let anchorAttrs = cv.layoutAttributesForItem(at: anchorIP)
            else { continue }

            let anchorScreenY = anchorAttrs.frame.origin.y - cv.contentOffset.y
            let actualStep = min(scrollStep, cv.contentOffset.y + cv.adjustedContentInset.top)
            guard actualStep > 0 else { break }

            cv.contentOffset.y -= actualStep
            cv.layoutIfNeeded()

            let expectedScreenY = anchorScreenY + actualStep
            if let newAttrs = cv.layoutAttributesForItem(at: anchorIP) {
                let newScreenY = newAttrs.frame.origin.y - cv.contentOffset.y
                let stutter = abs(newScreenY - expectedScreenY)
                maxStutter = max(maxStutter, stutter)
                if stutter > 2 { stutterSteps += 1 }
            }
        }

        return UpwardScrollResult(maxStutter: maxStutter, stutterSteps: stutterSteps)
    }

    // MARK: - Harness

    @MainActor
    private final class BenchHarness {
        let window: UIWindow
        let collectionView: AnchoredCollectionView
        let coordinator: ChatTimelineCollectionHost.Controller
        let scrollController: ChatScrollController
        let reducer: TimelineReducer
        let toolOutputStore: ToolOutputStore
        let toolArgsStore: ToolArgsStore
        let toolSegmentStore: ToolSegmentStore
        let connection: ServerConnection
        let audioPlayer: AudioPlayerService
        var items: [ChatItem]

        init(
            window: UIWindow,
            collectionView: AnchoredCollectionView,
            coordinator: ChatTimelineCollectionHost.Controller,
            items: [ChatItem]
        ) {
            self.window = window
            self.collectionView = collectionView
            self.coordinator = coordinator
            scrollController = ChatScrollController()
            reducer = TimelineReducer()
            toolOutputStore = ToolOutputStore()
            toolArgsStore = ToolArgsStore()
            toolSegmentStore = ToolSegmentStore()
            connection = ServerConnection()
            audioPlayer = AudioPlayerService()
            self.items = items
        }

        func applyItems(
            streamingID: String? = nil,
            isBusy: Bool = false
        ) {
            let config = makeTimelineConfiguration(
                items: items,
                isBusy: isBusy,
                streamingAssistantID: streamingID,
                sessionId: "bench-scroll",
                reducer: reducer,
                toolOutputStore: toolOutputStore,
                toolArgsStore: toolArgsStore,
                toolSegmentStore: toolSegmentStore,
                connection: connection,
                scrollController: scrollController,
                audioPlayer: audioPlayer
            )
            coordinator.apply(configuration: config, to: collectionView)
        }
    }

    @MainActor
    private func makeRealHarness(
        itemCount: Int,
        withToolOutput: Bool = false
    ) -> BenchHarness {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            fatalError("Missing UIWindowScene for ScrollStabilityBench")
        }

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let collectionView = AnchoredCollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        // Build diverse items with varying heights.
        var items: [ChatItem] = []
        let harness = BenchHarness(
            window: window,
            collectionView: collectionView,
            coordinator: coordinator,
            items: items
        )

        for i in 0 ..< itemCount {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: String(repeating: "Message \(i) content. ", count: (i % 3 == 0) ? 40 : 8),
                timestamp: Date()
            ))
            if withToolOutput {
                harness.toolArgsStore.set(
                    ["command": .string("echo test-\(i)")],
                    for: "tc-\(i)"
                )
                harness.toolOutputStore.append(
                    String(repeating: "output \(i)\n", count: 8),
                    to: "tc-\(i)"
                )
            }
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "cmd \(i)",
                outputPreview: "result \(i)",
                outputByteCount: withToolOutput ? 256 : 64,
                isError: false, isDone: true
            ))
        }
        // Streaming assistant at tail.
        items.append(.assistantMessage(
            id: "stream-1", text: "Working...", timestamp: Date()
        ))

        harness.items = items
        harness.applyItems(streamingID: "stream-1", isBusy: true)
        collectionView.layoutIfNeeded()

        return harness
    }

    // MARK: - Scroll Helpers

    @MainActor
    private func scrollToBottom(_ cv: UICollectionView) {
        cv.contentOffset.y = maxOffsetY(cv)
        cv.layoutIfNeeded()
    }

    @MainActor
    private func scrollThroughAll(_ cv: UICollectionView) {
        let step = cv.bounds.height * 0.8
        var offset: CGFloat = 0
        while offset < cv.contentSize.height {
            cv.contentOffset.y = offset
            cv.layoutIfNeeded()
            offset += step
        }
    }

    @MainActor
    private func maxOffsetY(_ cv: UICollectionView) -> CGFloat {
        let insets = cv.adjustedContentInset
        return max(
            -insets.top,
            cv.contentSize.height - cv.bounds.height + insets.bottom
        )
    }
}
