import Testing
import UIKit
@testable import Oppi

/// Microbenchmark for syntax highlighting pipeline.
///
/// Measures wall-clock μs for each stage:
/// - SyntaxHighlighter.highlight (raw scanner)
/// - SyntaxHighlighter.highlightLines (batch per-line)
/// - ToolRowTextRenderer.makeCodeAttributedText (full pipeline: gutter + highlight + assembly)
///
/// Outputs METRIC lines for autoresearch.sh to parse.
@Suite("Syntax Highlight Perf Bench")
@MainActor
struct SyntaxHighlightPerfBench {

    // MARK: - Fixtures

    static let source100 = RenderStrategyPerfTests.syntheticSwiftSource(lineCount: 100)
    static let source500 = RenderStrategyPerfTests.syntheticSwiftSource(lineCount: 500)

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

    @Test("Benchmark: highlight 100 lines")
    func highlight100() {
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(Self.source100, language: .swift)
        }
        print("METRIC highlight_100=\(us)")
        #expect(us < 500_000, "highlight 100 lines: \(us)μs")
    }

    @Test("Benchmark: highlight 500 lines")
    func highlight500() {
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(Self.source500, language: .swift)
        }
        print("METRIC highlight_500=\(us)")
        #expect(us < 500_000, "highlight 500 lines: \(us)μs")
    }

    @Test("Benchmark: highlightLines 100 lines")
    func highlightLines100() {
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlightLines(Self.source100, language: .swift)
        }
        print("METRIC highlightLines_100=\(us)")
        #expect(us < 500_000, "highlightLines 100 lines: \(us)μs")
    }

    @Test("Benchmark: highlightLines 500 lines")
    func highlightLines500() {
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlightLines(Self.source500, language: .swift)
        }
        print("METRIC highlightLines_500=\(us)")
        #expect(us < 500_000, "highlightLines 500 lines: \(us)μs")
    }

    @Test("Benchmark: makeCodeAttributedText 100 lines")
    func codeAttr100() {
        let us = Self.measureUs {
            _ = ToolRowTextRenderer.makeCodeAttributedText(
                text: Self.source100, language: .swift, startLine: 1
            )
        }
        print("METRIC codeAttr_100=\(us)")
        #expect(us < 500_000, "makeCodeAttributedText 100 lines: \(us)μs")
    }

    @Test("Benchmark: makeCodeAttributedText 500 lines")
    func codeAttr500() {
        let us = Self.measureUs {
            _ = ToolRowTextRenderer.makeCodeAttributedText(
                text: Self.source500, language: .swift, startLine: 1
            )
        }
        print("METRIC codeAttr_500=\(us)")
        #expect(us < 500_000, "makeCodeAttributedText 500 lines: \(us)μs")
    }

    @Test("Benchmark: highlight JSON 500 lines")
    func highlightJSON500() {
        let json = (0..<500).map { "  \"key\($0)\": \($0)," }.joined(separator: "\n")
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(json, language: .json)
        }
        print("METRIC highlight_json_500=\(us)")
        #expect(us < 500_000, "highlight JSON 500 lines: \(us)μs")
    }

    @Test("Benchmark: highlight Shell 100 lines")
    func highlightShell100() {
        let shell = (0..<100).map { "echo \"line \($0)\" | grep -E 'pattern' >> output.log 2>&1" }
            .joined(separator: "\n")
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(shell, language: .shell)
        }
        print("METRIC highlight_shell_100=\(us)")
        #expect(us < 500_000, "highlight Shell 100 lines: \(us)μs")
    }
}
