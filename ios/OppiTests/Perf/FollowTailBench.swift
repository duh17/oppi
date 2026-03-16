import Foundation
import Testing
import UIKit
@testable import Oppi

/// Benchmark for follow-tail latency during streaming tool output.
///
/// Measures the time spent in `ToolTimelineRowContentView.apply()` ->
/// `flushPendingFollowTail()` -> `followTail()` -> `layoutIfNeeded()` during
/// streaming code output. This path triggers synchronous TextKit2 layout
/// which dominates main-thread hangs during tool streaming (723ms hang,
/// 49% in followTail per spin dump analysis).
///
/// Output format: `METRIC name=number` for autoresearch consumption.
@Suite("FollowTailBench")
struct FollowTailBench {

    private static let medianRuns = 5
    private static let warmupRuns = 2
    private static let streamingChunks = 15
    private static let linesPerChunk = 40

    // MARK: - Primary: follow-tail apply latency during streaming

    @MainActor
    @Test func follow_tail_streaming_latency() {
        let lpc = Self.linesPerChunk
        let sc = Self.streamingChunks

        let view = makeWindowedToolView(
            text: "import Foundation\n",
            language: .swift
        )

        let codeLines = (0 ..< lpc * sc).map { i in
            "    let value\(i) = computeResult(input: \(i), factor: \(i * 3 + 7))"
        }

        // Warmup.
        for w in 0 ..< Self.warmupRuns {
            let text = codeLines[0 ..< lpc * (w + 1)].joined(separator: "\n")
            applyStreaming(view, text: text, language: .swift)
        }

        // Measured runs.
        var applyTimesUs: [Int] = []

        for _ in 0 ..< Self.medianRuns {
            let baseText = codeLines[0 ..< lpc].joined(separator: "\n")
            applyStreaming(view, text: baseText, language: .swift)

            var chunkTimes: [Int] = []

            for chunk in 1 ..< sc {
                let endLine = lpc * (chunk + 1)
                let text = codeLines[0 ..< min(endLine, codeLines.count)].joined(separator: "\n")

                let start = ContinuousClock.now
                applyStreaming(view, text: text, language: .swift)
                let elapsed = ContinuousClock.now - start
                let us = Int(elapsed.components.attoseconds / 1_000_000_000_000)
                    + Int(elapsed.components.seconds) * 1_000_000
                chunkTimes.append(us)
            }

            chunkTimes.sort()
            let p90Index = Int(Double(chunkTimes.count) * 0.9)
            applyTimesUs.append(chunkTimes[min(p90Index, chunkTimes.count - 1)])
        }

        applyTimesUs.sort()
        let medianApplyUs = applyTimesUs[applyTimesUs.count / 2]
        print("METRIC follow_tail_streaming_p90_us=\(medianApplyUs)")
        print("METRIC streaming_chunks=\(Self.streamingChunks)")
    }

    // MARK: - Secondary: Single append to large content

    @MainActor
    @Test func follow_tail_large_append() {
        let largeCode = (0 ..< 500).map { i in
            "    func process\(i)(data: [Int]) -> Result<String, Error> { .success(\"ok-\(i)\") }"
        }.joined(separator: "\n")

        let view = makeWindowedToolView(text: largeCode, language: .swift)

        // Warmup.
        applyStreaming(view, text: largeCode + "\n    let warmup = true", language: .swift)

        // Measured: append one line to 500-line content.
        var times: [Int] = []
        for i in 0 ..< Self.medianRuns {
            applyStreaming(view, text: largeCode, language: .swift)

            let extended = largeCode + "\n    let extra\(i) = true"
            let start = ContinuousClock.now
            applyStreaming(view, text: extended, language: .swift)
            let elapsed = ContinuousClock.now - start
            let us = Int(elapsed.components.attoseconds / 1_000_000_000_000)
                + Int(elapsed.components.seconds) * 1_000_000
            times.append(us)
        }

        times.sort()
        let median = times[times.count / 2]
        print("METRIC follow_tail_large_append_us=\(median)")
    }

    // MARK: - Helpers

    @MainActor
    private func makeWindowedToolView(
        text: String,
        language: SyntaxLanguage?
    ) -> ToolTimelineRowContentView {
        let expandedContent: ToolPresentationBuilder.ToolExpandedContent
        if let language {
            expandedContent = .code(
                text: text, language: language, startLine: 1, filePath: "Test.swift"
            )
        } else {
            expandedContent = .text(text: text, language: nil)
        }

        let config = makeTimelineToolConfiguration(
            title: "write Test.swift",
            expandedContent: expandedContent,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            view.topAnchor.constraint(equalTo: window.topAnchor),
        ])
        window.makeKeyAndVisible()
        forceLayout(view)

        return view
    }

    @MainActor
    private func applyStreaming(
        _ view: ToolTimelineRowContentView,
        text: String,
        language: SyntaxLanguage?
    ) {
        let expandedContent: ToolPresentationBuilder.ToolExpandedContent
        if let language {
            expandedContent = .code(
                text: text, language: language, startLine: 1, filePath: "Test.swift"
            )
        } else {
            expandedContent = .text(text: text, language: nil)
        }

        view.configuration = makeTimelineToolConfiguration(
            title: "write Test.swift",
            expandedContent: expandedContent,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
        forceLayout(view)
    }

    @MainActor
    private func forceLayout(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
}
