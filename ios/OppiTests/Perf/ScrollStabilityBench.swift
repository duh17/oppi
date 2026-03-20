import Foundation
import Testing
import UIKit
@testable import Oppi

/// Benchmarks for scroll stability anchoring overhead.
///
/// The primary scenario simulates UIKit's self-sizing cascade: repeated
/// contentOffset adjustments with an active detached anchor. Each adjustment
/// triggers AnchoredCollectionView.contentOffset.didSet which queries
/// layoutAttributesForItem and applies correction. In production, the
/// compositional layout fires 100+ such adjustments during streaming as
/// cells report preferred sizes one-per-frame.
///
/// Secondary scenarios verify correctness (drift, stutter, shift) during
/// streaming, expand/collapse, and upward scroll.
///
/// Output format: `METRIC name=number` for autoresearch consumption.
@Suite("ScrollStabilityBench")
struct ScrollStabilityBench {

    // MARK: - Configuration

    private static let cascadeIterations = 200
    private static let medianRuns = 5
    private static let warmupRuns = 2
    private static let streamingRounds = 20

    // MARK: - Primary: Cascade simulation

    @MainActor
    @Test func cascade_overhead() {
        // Setup: real collection view with 60 items at actual heights.
        let harness = makeRealHarness(itemCount: 60, withToolOutput: true)
        let cv = harness.collectionView

        // Scroll to bottom so all cells measure at actual heights.
        scrollThroughAll(cv)
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // Scroll to mid-point and detach.
        let maxOff = maxOffsetY(cv)
        cv.contentOffset.y = maxOff * 0.5
        cv.layoutIfNeeded()
        harness.scrollController.detachFromBottomForUserScroll()

        // Find a visible tool row for expand/collapse anchoring.
        let visibleIPs = cv.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let targetIP = visibleIPs.first { ip in
            ip.item < harness.items.count && harness.items[ip.item].id.hasPrefix("tc-")
        }
        guard let targetIP else {
            Issue.record("No visible tool row for cascade benchmark")
            return
        }

        var timings: [UInt64] = []
        var didSetEntries = 0
        var didSetCorrections = 0

        for run in 0 ..< (Self.warmupRuns + Self.medianRuns) {
            // Use expand/collapse anchor (this path still uses didSet
            // correction — the detached path now relies on layoutSubviews).
            cv.setExpandCollapseAnchor(indexPath: targetIP)
            cv._debugResetCounters()

            let startOffset = cv.contentOffset.y

            // Simulate cascade: UIKit adjusts contentOffset by ~6pt per frame.
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0 ..< Self.cascadeIterations {
                cv.contentOffset.y += 6
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start

            if run >= Self.warmupRuns {
                timings.append(elapsed)
                didSetEntries = cv._debugDidSetEntryCount
                didSetCorrections = cv._debugDidSetCorrectionCount
            }

            // Flush any pending deferred correction before checking drift.
            cv.layoutIfNeeded()

            // Verify anchor restored position.
            let drift = abs(cv.contentOffset.y - startOffset)
            #expect(
                drift < 2.0,
                "Cascade simulation drifted \(drift)pt after \(Self.cascadeIterations) adjustments"
            )

            cv.clearExpandCollapseAnchor()
        }

        timings.sort()
        let medianNs = timings[timings.count / 2]
        let medianUs = Double(medianNs) / 1000.0
        let perCallNs = Double(medianNs) / Double(Self.cascadeIterations)

        print("METRIC anchor_overhead_us=\(Int(medianUs))")
        print("METRIC per_didset_ns=\(Int(perCallNs))")
        print("METRIC didset_entry_count=\(didSetEntries)")
        print("METRIC didset_correction_count=\(didSetCorrections)")
    }

    // MARK: - Correctness: Streaming while detached

    @MainActor
    @Test func streaming_correctness() {
        let harness = makeRealHarness(itemCount: 40)
        let cv = harness.collectionView

        scrollThroughAll(cv)
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        let maxOff = maxOffsetY(cv)
        cv.contentOffset.y = maxOff * 0.4
        cv.layoutIfNeeded()
        harness.scrollController.detachFromBottomForUserScroll()

        let anchorOffset = cv.contentOffset.y
        var maxDrift: CGFloat = 0
        var totalApplyNanos: UInt64 = 0

        for round in 1 ... Self.streamingRounds {
            let lastIdx = harness.items.count - 1
            harness.items[lastIdx] = .assistantMessage(
                id: "stream-1",
                text: String(repeating: "Streaming round \(round) content. ", count: round * 5),
                timestamp: Date()
            )

            if round.isMultiple(of: 4) {
                harness.items.append(.toolCall(
                    id: "tc-new-\(round)", tool: "bash",
                    argsSummary: "cmd \(round)",
                    outputPreview: "result \(round)",
                    outputByteCount: 64,
                    isError: false, isDone: true
                ))
                let streamMsg = harness.items.remove(at: lastIdx)
                harness.items.append(streamMsg)
            }

            let applyStart = DispatchTime.now().uptimeNanoseconds
            harness.applyItems(streamingID: "stream-1", isBusy: true)
            cv.layoutIfNeeded()
            totalApplyNanos += DispatchTime.now().uptimeNanoseconds &- applyStart

            let drift = abs(cv.contentOffset.y - anchorOffset)
            maxDrift = max(maxDrift, drift)
        }

        let applyUs = Int(Double(totalApplyNanos) / 1000.0)

        print("METRIC streaming_apply_us=\(applyUs)")
        print("METRIC streaming_max_drift_pt=\(Int(maxDrift * 100))")

        #expect(
            maxDrift < 2.0,
            "Viewport drifted \(maxDrift)pt during streaming while detached"
        )
    }

    // MARK: - Correctness: Expand/collapse while detached

    @MainActor
    @Test func expand_collapse_correctness() {
        let toggleRounds = 6
        let harness = makeRealHarness(itemCount: 30, withToolOutput: true)
        let cv = harness.collectionView

        scrollThroughAll(cv)
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        let maxOff = maxOffsetY(cv)
        cv.contentOffset.y = maxOff * 0.5
        cv.layoutIfNeeded()
        harness.scrollController.detachFromBottomForUserScroll()

        let visibleIPs = cv.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let targetIP = visibleIPs.first { ip in
            ip.item < harness.items.count && harness.items[ip.item].id.hasPrefix("tc-")
        }
        guard let targetIP else {
            Issue.record("No visible tool row at midpoint")
            return
        }

        var maxShift: CGFloat = 0

        for round in 1 ... toggleRounds {
            let attrsBefore = cv.layoutAttributesForItem(at: targetIP)
            let screenYBefore = (attrsBefore?.frame.origin.y ?? 0) - cv.contentOffset.y

            harness.coordinator.collectionView(cv, didSelectItemAt: targetIP)
            // Drain for cascade settlement.
            for _ in 0 ..< 5 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.017))
            }

            let attrsAfter = cv.layoutAttributesForItem(at: targetIP)
            let screenYAfter = (attrsAfter?.frame.origin.y ?? 0) - cv.contentOffset.y
            let shift = abs(screenYAfter - screenYBefore)
            maxShift = max(maxShift, shift)

            #expect(shift < 2.0, "Shift \(shift)pt on toggle round \(round)")
        }

        print("METRIC expand_collapse_max_shift_pt=\(Int(maxShift * 100))")
    }

    // MARK: - Correctness: Upward scroll stutter

    @MainActor
    @Test func upward_scroll_stutter() {
        let harness = makeRealHarness(itemCount: 40)
        let cv = harness.collectionView

        scrollToBottom(cv)
        cv.layoutIfNeeded()
        harness.scrollController.detachFromBottomForUserScroll()

        let scrollStep: CGFloat = 60
        var maxStutter: CGFloat = 0
        var stutterSteps = 0

        for _ in 1 ... 30 {
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

        print("METRIC upward_stutter_max_pt=\(Int(maxStutter * 100))")
        print("METRIC upward_stutter_count=\(stutterSteps)")

        #expect(maxStutter < 4.0, "Stutter \(maxStutter)pt during upward scroll")
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
