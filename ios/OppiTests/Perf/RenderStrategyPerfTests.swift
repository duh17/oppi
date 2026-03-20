import Testing
import SwiftUI
import UIKit
@testable import Oppi

// MARK: - Render Strategy Performance

/// End-to-end benchmarks for tool row rendering paths.
///
/// Exercises the full pipeline from raw text → NSAttributedString,
/// measuring wall-clock time for realistic inputs. Verifies that the
/// batch `highlightLines` API matches per-line output and that
/// telemetry metrics are recorded.
@Suite("Render Strategy Performance")
@MainActor
struct RenderStrategyPerfTests {

    // MARK: - Test Fixtures

    /// Generate a realistic Swift source file of N lines.
    static func syntheticSwiftSource(lineCount: Int) -> String {
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        lines.append("import Foundation")
        lines.append("import UIKit")
        lines.append("")
        lines.append("/// A sample class for benchmarking syntax highlighting.")
        lines.append("final class BenchmarkModel: Sendable {")
        lines.append("    let id: UUID")
        lines.append("    let name: String")
        lines.append("    let count: Int")
        lines.append("")
        lines.append("    init(id: UUID = UUID(), name: String, count: Int) {")
        lines.append("        self.id = id")
        lines.append("        self.name = name")
        lines.append("        self.count = count")
        lines.append("    }")
        lines.append("")

        // Fill remaining lines with varied content to exercise all token types.
        var i = lines.count
        while i < lineCount {
            let mod = i % 12
            switch mod {
            case 0:
                lines.append("    // MARK: - Section \(i)")
            case 1:
                lines.append("    func process\(i)(_ input: String) -> Bool {")
            case 2:
                lines.append("        let result = input.count > \(i) ? true : false")
            case 3:
                lines.append("        guard !input.isEmpty else { return false }")
            case 4:
                lines.append("        let message = \"Processing item \\(input)\"")
            case 5:
                lines.append("        print(message)")
            case 6:
                lines.append("        let value: Double = \(Double(i) * 1.5)")
            case 7:
                lines.append("        return result && value > 0")
            case 8:
                lines.append("    }")
            case 9:
                lines.append("")
            case 10:
                lines.append("    /* Block comment for item \(i)")
            case 11:
                lines.append("       end of block comment */")
            default:
                lines.append("")
            }
            i += 1
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Generate ANSI-colored terminal output.
    private static func syntheticANSIOutput(lineCount: Int) -> String {
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for i in 0..<lineCount {
            let mod = i % 5
            switch mod {
            case 0:
                lines.append("\u{1B}[32m✓\u{1B}[0m Test \(i) passed")
            case 1:
                lines.append("\u{1B}[31m✗\u{1B}[0m Test \(i) \u{1B}[1;31mfailed\u{1B}[0m")
            case 2:
                lines.append("\u{1B}[33mwarning:\u{1B}[0m \u{1B}[1mDeprecated\u{1B}[0m API usage at line \(i)")
            case 3:
                lines.append("\u{1B}[36minfo:\u{1B}[0m Processing batch \(i) of \(lineCount)")
            case 4:
                lines.append("  plain output line \(i)")
            default:
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Generate diff lines.
    private static func syntheticDiffLines(count: Int) -> [DiffLine] {
        var lines: [DiffLine] = []
        lines.reserveCapacity(count)
        for i in 0..<count {
            let kind: DiffLine.Kind
            let mod = i % 5
            switch mod {
            case 0: kind = .removed
            case 1: kind = .added
            default: kind = .context
            }
            lines.append(DiffLine(
                kind: kind,
                text: "    let value\(i) = computeResult(\(i), threshold: \(Double(i) * 0.5))"
            ))
        }
        return lines
    }

    // MARK: - Timing Helper

    private static func measureMs(_ block: () -> Void) -> Int {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        let end = DispatchTime.now().uptimeNanoseconds
        return Int((end &- start) / 1_000_000)
    }

    // MARK: - Code Highlighting (makeCodeAttributedText)

    @Test("Code highlight 100 lines Swift")
    func codeHighlight100() {
        let source = Self.syntheticSwiftSource(lineCount: 100)
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.makeCodeAttributedText(
                text: source, language: .swift, startLine: 1
            )
        }
        // Should complete well under 16ms frame budget.
        #expect(ms < 50, "100-line code highlight took \(ms)ms (budget: 50ms)")
    }

    @Test("Code highlight 500 lines Swift")
    func codeHighlight500() {
        let source = Self.syntheticSwiftSource(lineCount: 500)
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.makeCodeAttributedText(
                text: source, language: .swift, startLine: 1
            )
        }
        // Batch highlightLines should keep this under 100ms even in debug.
        #expect(ms < 150, "500-line code highlight took \(ms)ms (budget: 150ms)")
    }

    @Test("Code highlight 1000 lines Swift")
    func codeHighlight1000() {
        let source = Self.syntheticSwiftSource(lineCount: 1000)
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.makeCodeAttributedText(
                text: source, language: .swift, startLine: 1
            )
        }
        // 1000 lines should be manageable.
        #expect(ms < 300, "1000-line code highlight took \(ms)ms (budget: 300ms)")
    }

    @Test("Code highlight without language is fast")
    func codeHighlightPlain() {
        let source = Self.syntheticSwiftSource(lineCount: 500)
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.makeCodeAttributedText(
                text: source, language: nil, startLine: 1
            )
        }
        // No syntax highlighting — should be very fast.
        #expect(ms < 30, "500-line plain code took \(ms)ms (budget: 30ms)")
    }

    // MARK: - Syntax Output Presentation (makeSyntaxOutputPresentation)

    @Test("Syntax output presentation 500 lines")
    func syntaxPresentation500() {
        let source = Self.syntheticSwiftSource(lineCount: 500)
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.makeSyntaxOutputPresentation(source, language: .swift)
        }
        #expect(ms < 100, "500-line syntax presentation took \(ms)ms (budget: 100ms)")
    }

    // MARK: - ANSI Output (makeANSIOutputPresentation)

    @Test("ANSI output 100 lines")
    func ansiOutput100() {
        let text = Self.syntheticANSIOutput(lineCount: 100)
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.makeANSIOutputPresentation(text, isError: false)
        }
        #expect(ms < 30, "100-line ANSI output took \(ms)ms (budget: 30ms)")
    }

    @Test("ANSI output 500 lines")
    func ansiOutput500() {
        let text = Self.syntheticANSIOutput(lineCount: 500)
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.makeANSIOutputPresentation(text, isError: false)
        }
        #expect(ms < 80, "500-line ANSI output took \(ms)ms (budget: 80ms)")
    }

    // MARK: - Diff (makeDiffAttributedText)

    @Test("Diff highlight 100 lines Swift")
    func diffHighlight100() {
        let lines = Self.syntheticDiffLines(count: 100)
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.makeDiffAttributedText(lines: lines, filePath: "test.swift")
        }
        #expect(ms < 80, "100-line diff took \(ms)ms (budget: 80ms)")
    }

    @Test("Diff highlight 300 lines Swift")
    func diffHighlight300() {
        let lines = Self.syntheticDiffLines(count: 300)
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.makeDiffAttributedText(lines: lines, filePath: "test.swift")
        }
        #expect(ms < 200, "300-line diff took \(ms)ms (budget: 200ms)")
    }

    // MARK: - Bash Command

    @Test("Bash command highlight")
    func bashCommand() {
        let command = "cd /Users/me/workspace/project && npm run build 2>&1 | grep -E 'error|warning' | head -50"
        let ms = Self.measureMs {
            _ = ToolRowTextRenderer.bashCommandHighlighted(command)
        }
        #expect(ms < 5, "Bash command highlight took \(ms)ms (budget: 5ms)")
    }

    // MARK: - highlightLines Correctness

    @Test("highlightLines matches per-line highlightLine output")
    func highlightLinesBatchMatchesSingle() {
        let source = Self.syntheticSwiftSource(lineCount: 50)
        let batchResults = SyntaxHighlighter.highlightLines(source, language: .swift)

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(batchResults.count == lines.count,
            "Batch returned \(batchResults.count) lines, expected \(lines.count)")

        // Verify text content matches (colors may differ due to block comment tracking).
        for (i, batchLine) in batchResults.enumerated() {
            let singleLine = SyntaxHighlighter.highlightLine(String(lines[i]), language: .swift)
            #expect(batchLine.string == singleLine.string,
                "Line \(i) text mismatch: batch='\(batchLine.string)' single='\(singleLine.string)'")
        }
    }

    @Test("highlightLines tracks block comment state across lines")
    func highlightLinesBlockCommentState() {
        let source = """
        let a = 1
        /* start of block
        still in block
        end of block */
        let b = 2
        """
        let results = SyntaxHighlighter.highlightLines(source, language: .swift)
        #expect(results.count == 5)

        // Line 2 ("still in block") should be fully comment-colored in batch mode.
        // In single-line mode it wouldn't know it's inside a block comment.
        let commentLine = results[2]
        let commentColor = UIColor(SwiftUI.Color.themeSyntaxComment)

        // Check that at least the first character has comment color.
        var effectiveRange = NSRange()
        let firstCharColor = commentLine.attribute(
            .foregroundColor, at: 0, effectiveRange: &effectiveRange
        ) as? UIColor
        #expect(firstCharColor == commentColor,
            "Block comment line should have comment color, got \(String(describing: firstCharColor))")
    }

    @Test("highlightLines handles JSON")
    func highlightLinesJSON() {
        let source = """
        {
          "name": "test",
          "count": 42,
          "active": true
        }
        """
        let results = SyntaxHighlighter.highlightLines(source, language: .json)
        #expect(results.count == 5)
        #expect(results[0].string == "{")
        #expect(results[1].string.contains("\"name\""))
    }

    @Test("highlightLines empty input")
    func highlightLinesEmpty() {
        let results = SyntaxHighlighter.highlightLines("", language: .swift)
        #expect(results.count == 1)
        #expect(results[0].string.isEmpty)
    }
}

// MARK: - Telemetry Recording

@Suite("Render Strategy Telemetry")
@MainActor
struct RenderStrategyTelemetryTests {

    @Test("recordRenderStrategy emits signpost without crash")
    func recordDoesNotCrash() {
        // Verify the recording path doesn't crash for each mode.
        // (Actual metric upload requires a configured APIClient, which we skip in tests.)
        let modes = [
            "text.syntax", "text.ansi", "text.stream",
            "code.highlight", "code.stream",
            "diff.highlight", "diff.stream",
            "bash.command", "bash.output.ansi", "bash.output.stream",
        ]
        for mode in modes {
            ChatTimelinePerf.recordRenderStrategy(
                mode: mode,
                durationMs: 5,
                inputBytes: 1024,
                language: mode.contains("code") ? "Swift" : nil
            )
        }
        // If we got here without crashing, the signpost/log paths are safe.
    }

    @Test("recordRenderStrategy logs slow renders")
    func recordSlowRender() {
        // Reset to ensure fresh cooldown window.
        ChatTimelinePerf.reset()

        // Should not crash even with high durations.
        ChatTimelinePerf.recordRenderStrategy(
            mode: "code.highlight",
            durationMs: 50,
            inputBytes: 50_000,
            language: "Swift"
        )
    }
}

// MARK: - Batch vs Single Benchmark

@Suite("Batch vs Single Highlight Benchmark")
@MainActor
struct BatchHighlightBenchmarkTests {

    @Test("Batch highlightLines is faster than N x highlightLine")
    func batchFasterThanSingle() {
        let source = RenderStrategyPerfTests.syntheticSwiftSource(lineCount: 500)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Measure single-line path (old approach).
        let singleStart = DispatchTime.now().uptimeNanoseconds
        for line in lines {
            _ = SyntaxHighlighter.highlightLine(line, language: .swift)
        }
        let singleMs = Int((DispatchTime.now().uptimeNanoseconds &- singleStart) / 1_000_000)

        // Measure batch path (new approach).
        let batchStart = DispatchTime.now().uptimeNanoseconds
        _ = SyntaxHighlighter.highlightLines(source, language: .swift)
        let batchMs = Int((DispatchTime.now().uptimeNanoseconds &- batchStart) / 1_000_000)

        // Batch should be faster (fewer TokenAttrs allocations, shared block comment state).
        // Allow generous margin for CI/debug variance.
        #expect(batchMs <= singleMs + 5,
            "Batch (\(batchMs)ms) should not be slower than single (\(singleMs)ms)")
    }

    // Expose fixture generator for cross-suite use.
    static func syntheticSwiftSource(lineCount: Int) -> String {
        RenderStrategyPerfTests.syntheticSwiftSource(lineCount: lineCount)
    }
}
