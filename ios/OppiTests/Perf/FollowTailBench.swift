import Foundation
import Testing
import UIKit
@testable import Oppi

/// Benchmark for follow-tail latency during streaming tool output.
///
/// Measures the time spent in `flushPendingFollowTail()` → `followTail()`
/// during streaming reconfiguration. This path triggers synchronous TextKit2
/// layout (`layoutIfNeeded`), which dominates main-thread hangs during
/// tool streaming (723ms hang, 49% in followTail per spin dump).
///
/// Output format: `METRIC name=number` for autoresearch consumption.
@Suite("FollowTailBench")
struct FollowTailBench {

    private static let medianRuns = 5
    private static let warmupRuns = 2
    private static let streamingChunks = 15
    /// Lines of code per chunk — simulates a tool writing a file.
    private static let linesPerChunk = 40

    // MARK: - Primary: Follow-tail latency during streaming

    @MainActor
    @Test func follow_tail_streaming_latency() {
        let harness = makeFollowTailHarness()
        let cv = harness.collectionView

        // Warm up: apply initial items so cells are laid out.
        harness.applyItems(streamingID: "stream-1", isBusy: true)
        cv.layoutIfNeeded()

        // Scroll to bottom (attached).
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // Generate code content to stream.
        let codeLines = (0 ..< Self.linesPerChunk * Self.streamingChunks).map { i in
            "    let value\(i) = computeResult(input: \(i), factor: \(i * 3 + 7))"
        }

        // Warmup runs.
        for w in 0 ..< Self.warmupRuns {
            let text = codeLines[0 ..< Self.linesPerChunk * (w + 1)].joined(separator: "\n")
            harness.updateStreamingToolOutput(text)
            harness.applyItems(streamingID: "stream-1", isBusy: true)
            cv.layoutIfNeeded()
        }

        // Measured runs: simulate streaming chunks.
        var applyTimesUs: [Int] = []

        for run in 0 ..< Self.medianRuns {
            // Reset to a small initial state.
            let baseText = codeLines[0 ..< Self.linesPerChunk].joined(separator: "\n")
            harness.updateStreamingToolOutput(baseText)
            harness.applyItems(streamingID: "stream-1", isBusy: true)
            cv.layoutIfNeeded()

            var chunkTimes: [Int] = []

            for chunk in 1 ..< Self.streamingChunks {
                let endLine = Self.linesPerChunk * (chunk + 1)
                let text = codeLines[0 ..< min(endLine, codeLines.count)].joined(separator: "\n")
                harness.updateStreamingToolOutput(text)

                let start = ContinuousClock.now
                harness.applyItems(streamingID: "stream-1", isBusy: true)
                cv.layoutIfNeeded()
                let elapsed = ContinuousClock.now - start
                let us = Int(elapsed.components.attoseconds / 1_000_000_000_000)
                    + Int(elapsed.components.seconds) * 1_000_000
                chunkTimes.append(us)
            }

            // Use p90 of chunk times for this run.
            chunkTimes.sort()
            let p90Index = Int(Double(chunkTimes.count) * 0.9)
            applyTimesUs.append(chunkTimes[min(p90Index, chunkTimes.count - 1)])
        }

        applyTimesUs.sort()
        let medianApplyUs = applyTimesUs[applyTimesUs.count / 2]

        print("METRIC follow_tail_streaming_p90_us=\(medianApplyUs)")

        // Also measure total apply count for sanity.
        print("METRIC streaming_chunks=\(Self.streamingChunks)")
    }

    // MARK: - Secondary: Per-chunk breakdown with large content

    @MainActor
    @Test func follow_tail_large_content() {
        let harness = makeFollowTailHarness()
        let cv = harness.collectionView

        harness.applyItems(streamingID: "stream-1", isBusy: true)
        cv.layoutIfNeeded()
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // Build a large code block (500 lines).
        let largeCode = (0 ..< 500).map { i in
            "    func process\(i)(data: [Int]) -> Result<String, Error> { .success(\"ok-\(i)\") }"
        }.joined(separator: "\n")

        harness.updateStreamingToolOutput(largeCode)

        // Warmup.
        harness.applyItems(streamingID: "stream-1", isBusy: true)
        cv.layoutIfNeeded()

        // Append one more line and measure the reconfigure cost.
        var singleAppendTimes: [Int] = []
        for i in 0 ..< Self.medianRuns {
            let extended = largeCode + "\n    let extra\(i) = true"
            harness.updateStreamingToolOutput(extended)

            let start = ContinuousClock.now
            harness.applyItems(streamingID: "stream-1", isBusy: true)
            cv.layoutIfNeeded()
            let elapsed = ContinuousClock.now - start
            let us = Int(elapsed.components.attoseconds / 1_000_000_000_000)
                + Int(elapsed.components.seconds) * 1_000_000
            singleAppendTimes.append(us)
        }

        singleAppendTimes.sort()
        let medianLargeUs = singleAppendTimes[singleAppendTimes.count / 2]
        print("METRIC follow_tail_large_append_us=\(medianLargeUs)")
    }

    // MARK: - Harness

    @MainActor
    private final class FollowTailHarness {
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
                sessionId: "bench-follow-tail",
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

        func updateStreamingToolOutput(_ text: String) {
            toolOutputStore.set(text, for: "streaming-tool-1")
        }
    }

    @MainActor
    private func makeFollowTailHarness() -> FollowTailHarness {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            fatalError("Missing UIWindowScene for FollowTailBench")
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

        let harness = FollowTailHarness(
            window: window,
            collectionView: collectionView,
            coordinator: coordinator,
            items: []
        )

        // Build initial timeline: a few done tools + one streaming tool.
        var items: [ChatItem] = []

        // Some done message/tool pairs.
        for i in 0 ..< 5 {
            items.append(.assistantMessage(
                id: "a-\(i)",
                text: "Working on step \(i)...",
                timestamp: Date()
            ))
            harness.toolArgsStore.set(
                ["command": .string("echo step-\(i)")],
                for: "tc-\(i)"
            )
            harness.toolOutputStore.append(
                String(repeating: "output \(i)\n", count: 4),
                to: "tc-\(i)"
            )
            items.append(.toolCall(
                id: "tc-\(i)", tool: "bash",
                argsSummary: "echo step-\(i)",
                outputPreview: "output \(i)",
                outputByteCount: 64,
                isError: false, isDone: true
            ))
        }

        // Streaming assistant message.
        items.append(.assistantMessage(
            id: "stream-1", text: "Writing code...", timestamp: Date()
        ))

        // Streaming tool call (not done) — this is the cell that triggers followTail.
        harness.toolArgsStore.set(
            ["path": .string("Sources/App/Generated.swift")],
            for: "streaming-tool-1"
        )
        harness.toolOutputStore.set(
            "// Initial content\n",
            for: "streaming-tool-1"
        )
        items.append(.toolCall(
            id: "streaming-tool-1", tool: "write",
            argsSummary: "Sources/App/Generated.swift",
            outputPreview: nil,
            outputByteCount: 20,
            isError: false, isDone: false
        ))

        harness.items = items
        return harness
    }

    // MARK: - Helpers

    @MainActor
    private func scrollToBottom(_ cv: UICollectionView) {
        let maxY = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
        cv.contentOffset.y = maxY
    }
}
