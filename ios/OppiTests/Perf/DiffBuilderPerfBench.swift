import Testing
import UIKit
@testable import Oppi

/// Microbenchmark for DiffAttributedStringBuilder.build().
///
/// Measures wall-clock μs for building the full attributed string from
/// realistic diff hunks at various sizes. This is the hot path that runs
/// on the main thread in UnifiedDiffTextView.makeUIView().
///
/// Outputs METRIC lines for autoresearch.sh to parse.
@Suite("Diff Builder Perf Bench")
@MainActor
struct DiffBuilderPerfBench {

    // MARK: - Fixtures

    /// Generate realistic diff hunks simulating a modified Swift file.
    ///
    /// Creates hunks with a mix of context, added, and removed lines.
    /// Some removed/added pairs get word-level spans (like real diffs).
    static func syntheticDiffHunks(totalLines: Int) -> [WorkspaceReviewDiffHunk] {
        var lines: [WorkspaceReviewDiffLine] = []
        var oldLine = 1
        var newLine = 1

        for i in 0..<totalLines {
            let mod = i % 10
            switch mod {
            case 0...4:
                // Context line (50%)
                let text = "    let value\(i) = computeSomething(input: \(i), flag: true) // context"
                lines.append(WorkspaceReviewDiffLine(
                    kind: .context, text: text, oldLine: oldLine, newLine: newLine, spans: nil
                ))
                oldLine += 1
                newLine += 1
            case 5, 6:
                // Removed line (20%)
                let text = "    let old\(i) = legacyFunction(\(i)) // removed line"
                let spans: [WorkspaceReviewDiffSpan]? = mod == 5
                    ? [WorkspaceReviewDiffSpan(start: 8, end: 14, kind: .changed)]
                    : nil
                lines.append(WorkspaceReviewDiffLine(
                    kind: .removed, text: text, oldLine: oldLine, newLine: nil, spans: spans
                ))
                oldLine += 1
            case 7, 8:
                // Added line (20%)
                let text = "    let new\(i) = modernFunction(\(i), options: .default) // added line"
                let spans: [WorkspaceReviewDiffSpan]? = mod == 7
                    ? [WorkspaceReviewDiffSpan(start: 8, end: 14, kind: .changed)]
                    : nil
                lines.append(WorkspaceReviewDiffLine(
                    kind: .added, text: text, oldLine: nil, newLine: newLine, spans: spans
                ))
                newLine += 1
            default:
                // Mixed: removed + added pair (10%)
                let removedText = "    guard let item = cache[\"\(i)\"] else { return nil }"
                lines.append(WorkspaceReviewDiffLine(
                    kind: .removed, text: removedText, oldLine: oldLine, newLine: nil,
                    spans: [WorkspaceReviewDiffSpan(start: 20, end: 30, kind: .changed)]
                ))
                oldLine += 1
                let addedText = "    guard let item = store.fetch(key: \"\(i)\") else { return nil }"
                lines.append(WorkspaceReviewDiffLine(
                    kind: .added, text: addedText, oldLine: nil, newLine: newLine,
                    spans: [WorkspaceReviewDiffSpan(start: 20, end: 38, kind: .changed)]
                ))
                newLine += 1
            }
        }

        // Split into hunks of ~40 lines each (realistic hunk sizes)
        let hunkSize = 40
        var hunks: [WorkspaceReviewDiffHunk] = []
        var offset = 0
        while offset < lines.count {
            let end = min(offset + hunkSize, lines.count)
            let slice = Array(lines[offset..<end])
            let oldStart = slice.compactMap(\.oldLine).first ?? 1
            let newStart = slice.compactMap(\.newLine).first ?? 1
            let oldCount = slice.compactMap(\.oldLine).count
            let newCount = slice.compactMap(\.newLine).count
            hunks.append(WorkspaceReviewDiffHunk(
                oldStart: oldStart, oldCount: oldCount,
                newStart: newStart, newCount: newCount,
                lines: slice
            ))
            offset = end
        }
        return hunks
    }

    static let hunks100 = syntheticDiffHunks(totalLines: 100)
    static let hunks300 = syntheticDiffHunks(totalLines: 300)
    static let hunks500 = syntheticDiffHunks(totalLines: 500)

    // MARK: - Timing

    private static func measureUs(iterations: Int = 5, _ block: () -> Void) -> Int {
        // Warmup
        block()

        var best = Int.max
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            let us = Int((end &- start) / 1_000)
            best = min(best, us)
        }
        return best
    }

    // MARK: - Benchmarks

    @Test("Benchmark: DiffBuilder 100 lines")
    func diffBuild100() {
        let us = Self.measureUs {
            _ = DiffAttributedStringBuilder.build(hunks: Self.hunks100, filePath: "Example.swift")
        }
        print("METRIC diffBuild_100=\(us)")
        #expect(us < 500_000, "diffBuild 100 lines: \(us)μs")
    }

    @Test("Benchmark: DiffBuilder 300 lines")
    func diffBuild300() {
        let us = Self.measureUs {
            _ = DiffAttributedStringBuilder.build(hunks: Self.hunks300, filePath: "Example.swift")
        }
        print("METRIC diffBuild_300=\(us)")
        #expect(us < 500_000, "diffBuild 300 lines: \(us)μs")
    }

    @Test("Benchmark: DiffBuilder 500 lines")
    func diffBuild500() {
        let us = Self.measureUs {
            _ = DiffAttributedStringBuilder.build(hunks: Self.hunks500, filePath: "Example.swift")
        }
        print("METRIC diffBuild_500=\(us)")
        #expect(us < 500_000, "diffBuild 500 lines: \(us)μs")
    }

    @Test("Benchmark: DiffBuilder 500 lines (unknown language)")
    func diffBuildPlain500() {
        let us = Self.measureUs {
            _ = DiffAttributedStringBuilder.build(hunks: Self.hunks500, filePath: "README.txt")
        }
        print("METRIC diffBuild_plain_500=\(us)")
        #expect(us < 500_000, "diffBuild plain 500 lines: \(us)μs")
    }

    // MARK: - SyntaxHighlighter benchmarks (secondary metrics)

    static let swiftSource500 = RenderStrategyPerfTests.syntheticSwiftSource(lineCount: 500)

    @Test("Benchmark: SyntaxHighlighter.highlight 500 lines Swift")
    func highlight500() {
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(Self.swiftSource500, language: .swift)
        }
        print("METRIC highlight_500=\(us)")
        #expect(us < 500_000, "highlight 500 lines: \(us)μs")
    }

    @Test("Benchmark: SyntaxHighlighter.scanTokenRanges 500 lines Swift")
    func scanTokens500() {
        let us = Self.measureUs {
            _ = SyntaxHighlighter.scanTokenRanges(Self.swiftSource500, language: .swift)
        }
        print("METRIC scanTokens_500=\(us)")
        #expect(us < 500_000, "scanTokenRanges 500 lines: \(us)μs")
    }
}
