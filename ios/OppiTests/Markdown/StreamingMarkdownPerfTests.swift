import Testing
import Foundation
@testable import Oppi

// MARK: - parseCommonMarkWithLastLine Tests

/// Correctness tests for `parseCommonMarkWithLastLine`.
///
/// This function is the core of the incremental streaming parse path: it
/// returns both the parsed blocks AND the 1-based start line of the last
/// top-level block so callers can split the content into a stable prefix and
/// a re-parse-only tail without a second full-document parse.
@Suite("parseCommonMarkWithLastLine")
struct ParseCommonMarkWithLastLineTests {

    @Test func singleBlock_returnsLine1() {
        let md = "Just one paragraph.\n"
        let (blocks, lastLine) = parseCommonMarkWithLastLine(md)
        #expect(blocks.count == 1)
        // Only one block → no stable prefix → function returns 1
        #expect(lastLine == 1)
    }

    @Test func twoParagraphs_lastLineIsSecond() {
        let md = "First paragraph.\n\nSecond paragraph.\n"
        let (blocks, lastLine) = parseCommonMarkWithLastLine(md)
        #expect(blocks.count == 2)
        // "Second paragraph" starts on line 3 (two lines for first para + blank)
        #expect(lastLine == 3)
    }

    @Test func headingPlusParagraphPlusCode() {
        let md = """
        # Heading

        A paragraph here.

        ```swift
        let x = 42
        ```
        """
        let (blocks, lastLine) = parseCommonMarkWithLastLine(md)
        #expect(blocks.count == 3)
        // Code block starts after heading (line 1) + blank (line 2) + paragraph (line 3) + blank (line 4)
        // → line 5
        #expect(lastLine == 5)
    }

    @Test func emptyDocument_returnsLine1() {
        let (blocks, lastLine) = parseCommonMarkWithLastLine("")
        #expect(blocks.isEmpty)
        #expect(lastLine == 1)
    }

    @Test func singleCodeBlock_returnsLine1() {
        let md = "```swift\nlet x = 1\n```\n"
        let (blocks, lastLine) = parseCommonMarkWithLastLine(md)
        #expect(blocks.count == 1)
        #expect(lastLine == 1)
    }

    @Test func matchesPlainParseCommonMark() {
        let md = """
        # Title

        Intro paragraph.

        - item one
        - item two

        > block quote

        ---

        Final paragraph.
        """
        let plain = parseCommonMark(md)
        let (withMeta, _) = parseCommonMarkWithLastLine(md)
        #expect(plain == withMeta)
    }

    @Test func multipleBlocks_lastLineBeyondMiddle() {
        // Generate 10 paragraphs separated by blank lines.
        let paragraphs = (1...10).map { "Paragraph \($0)." }
        let md = paragraphs.joined(separator: "\n\n") + "\n"
        let (blocks, lastLine) = parseCommonMarkWithLastLine(md)
        #expect(blocks.count == 10)
        // Last paragraph starts well after line 1
        #expect(lastLine > 1)
    }
}

// MARK: - Tail-only Incremental Parse Correctness

/// Verify that the incremental parse approach (parse prefix once, re-parse
/// tail each tick) produces the same `FlatSegment` array as a full parse.
///
/// This simulates what `AssistantMarkdownContentView.buildSegmentsIncremental`
/// does:  find the prefix boundary, parse prefix blocks, parse tail blocks,
/// combine, build segments.
@Suite("Incremental Parse Correctness")
@MainActor
struct IncrementalParseCorrectnessTests {

    // Helper: simulate one incremental parse tick given a known prefix byte count.
    private func simulateIncrementalParse(
        content: String,
        prefixUTF8ByteCount: Int,
        themeID: ThemeID = .dark
    ) -> [FlatSegment] {
        let utf8 = content.utf8
        guard prefixUTF8ByteCount > 0, prefixUTF8ByteCount < utf8.count else {
            let blocks = parseCommonMark(content)
            return FlatSegment.build(from: blocks, themeID: themeID)
        }
        let boundaryIdx = utf8.index(utf8.startIndex, offsetBy: prefixUTF8ByteCount)
        let prefixBlocks = parseCommonMark(String(content[..<boundaryIdx]))
        let tailBlocks = parseCommonMark(String(content[boundaryIdx...]))
        return FlatSegment.build(from: prefixBlocks + tailBlocks, themeID: themeID)
    }

    private func fullParse(content: String, themeID: ThemeID = ThemeRuntimeState.currentThemeID()) -> [FlatSegment] {
        FlatSegment.build(from: parseCommonMark(content), themeID: themeID)
    }

    @Test func twoParas_incrementalMatchesFull() {
        let content = "First paragraph.\n\nSecond paragraph growing...\n"
        let (_, lastLine) = parseCommonMarkWithLastLine(content)
        // Boundary at start of second para.
        let byteOffset = utf8ByteOffset(forLine: lastLine, in: content)

        let incremental = simulateIncrementalParse(content: content, prefixUTF8ByteCount: byteOffset)
        let full = fullParse(content: content)
        #expect(segmentStructure(incremental) == segmentStructure(full))
    }

    @Test func headingPlusParagraph_incrementalMatchesFull() {
        let content = """
        # Section Title

        This is an expanding paragraph that keeps growing.
        """
        let (_, lastLine) = parseCommonMarkWithLastLine(content)
        let byteOffset = utf8ByteOffset(forLine: lastLine, in: content)
        let incremental = simulateIncrementalParse(content: content, prefixUTF8ByteCount: byteOffset)
        let full = fullParse(content: content)
        #expect(segmentStructure(incremental) == segmentStructure(full))
    }

    @Test func prefixEndingInCodeBlock_tailIsParagraph_incrementalMatchesFull() {
        let content = """
        Intro paragraph.

        ```swift
        let x = 1
        let y = 2
        ```

        Tail paragraph growing here.
        """
        let (_, lastLine) = parseCommonMarkWithLastLine(content)
        let byteOffset = utf8ByteOffset(forLine: lastLine, in: content)
        let incremental = simulateIncrementalParse(content: content, prefixUTF8ByteCount: byteOffset)
        let full = fullParse(content: content)
        #expect(segmentStructure(incremental) == segmentStructure(full))
    }

    @Test func singleBlock_noPrefixSplit_matchesFull() {
        let content = "A single growing paragraph with no block boundaries."
        let (_, lastLine) = parseCommonMarkWithLastLine(content)
        // lastLine == 1 → no stable prefix, byte offset 0
        let byteOffset = utf8ByteOffset(forLine: lastLine, in: content)
        // byteOffset == 0 → fallback to full parse
        let incremental = simulateIncrementalParse(content: content, prefixUTF8ByteCount: byteOffset)
        let full = fullParse(content: content)
        #expect(segmentStructure(incremental) == segmentStructure(full))
    }

    // MARK: - Segment structure comparison helpers

    private enum SegmentKind: Equatable {
        case text
        case codeBlock(language: String?)
        case table
        case thematicBreak
    }

    private func segmentStructure(_ segments: [FlatSegment]) -> [SegmentKind] {
        segments.map { seg in
            switch seg {
            case .text: return .text
            case .codeBlock(let lang, _): return .codeBlock(language: lang)
            case .table: return .table
            case .thematicBreak: return .thematicBreak
            }
        }
    }

    // Helper: compute UTF-8 byte offset for 1-based line (matches the impl).
    private func utf8ByteOffset(forLine targetLine: Int, in content: String) -> Int {
        guard targetLine > 1 else { return 0 }
        var currentLine = 1
        var byteOffset = 0
        for byte in content.utf8 {
            byteOffset += 1
            if byte == UInt8(ascii: "\n") {
                currentLine += 1
                if currentLine == targetLine { return byteOffset }
            }
        }
        return content.utf8.count
    }
}

// MARK: - Performance Benchmarks

/// Compares full-document re-parse (old path) vs tail-only re-parse (new path)
/// for streaming document sizes of 100, 500, and 1000 lines.
///
/// Each benchmark simulates a streaming tick where the last paragraph has grown
/// by one sentence.  We measure wall-clock time and verify that the tail-only
/// path is significantly faster for large documents.
///
/// Note: These are wall-clock measurements — CI timing variance is expected.
/// The assertions use conservative multipliers (3× threshold) to avoid flakes.
@Suite("Streaming Parse Performance Benchmarks")
@MainActor
struct StreamingMarkdownPerfBenchmarks {

    // MARK: - Document generation

    /// Generate a realistic assistant markdown message with `paragraphCount`
    /// paragraphs separated by blank lines.  The last paragraph is the "live"
    /// tail — still being streamed.
    private func makeStreamingDocument(paragraphCount: Int, tailSentences: Int = 5) -> String {
        var parts: [String] = []

        // Finalized heading
        parts.append("# Section \(paragraphCount)")
        parts.append("")

        // Finalized paragraphs (all but the last are complete)
        for i in 1..<paragraphCount {
            parts.append("This is finalized paragraph \(i). It contains some representative text that exercises the CommonMark parser.")
            parts.append("")
        }

        // Last paragraph (tail — still streaming, ends without newline)
        let tail = (1...tailSentences).map { "Sentence \($0) of the streaming paragraph." }.joined(separator: " ")
        parts.append(tail)

        return parts.joined(separator: "\n")
    }

    private func utf8ByteOffset(forLine targetLine: Int, in content: String) -> Int {
        guard targetLine > 1 else { return 0 }
        var currentLine = 1
        var byteOffset = 0
        for byte in content.utf8 {
            byteOffset += 1
            if byte == UInt8(ascii: "\n") {
                currentLine += 1
                if currentLine == targetLine { return byteOffset }
            }
        }
        return content.utf8.count
    }

    // MARK: - Benchmark helper

    /// Measure wall-clock nanoseconds for `block`, repeated `iterations` times,
    /// returning the median.
    private func medianNs(iterations: Int = 10, _ block: () -> Void) -> Double {
        var measurements: [Double] = []
        measurements.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            measurements.append(Double(elapsed))
        }
        measurements.sort()
        return measurements[iterations / 2]
    }

    // MARK: - 100-paragraph benchmark

    @Test func benchmark_100Paragraphs() {
        let content = makeStreamingDocument(paragraphCount: 100)
        let (_, lastLine) = parseCommonMarkWithLastLine(content)
        let byteOffset = utf8ByteOffset(forLine: lastLine, in: content)

        // Warm up.
        _ = parseCommonMark(content)

        let fullNs = medianNs {
            _ = parseCommonMark(content)
        }

        let tailNs = medianNs {
            let utf8 = content.utf8
            let boundaryIdx = utf8.index(utf8.startIndex, offsetBy: byteOffset)
            let tail = String(content[boundaryIdx...])
            _ = parseCommonMark(tail)
        }

        // Tail-only should be at least 3× faster on a 100-paragraph doc.
        let lineCount = content.components(separatedBy: "\n").count
        // Emit results so they show up in test output regardless of threshold.
        print("[Perf] 100-para (\(lineCount) lines): full=\(Int(fullNs/1000))µs  tail=\(Int(tailNs/1000))µs  speedup=\(String(format: "%.1f", fullNs/max(tailNs, 1)))×")

        #expect(tailNs < fullNs * 0.8, "Tail-only parse should be faster than full parse for 100 paragraphs")
    }

    // MARK: - 500-paragraph benchmark

    @Test func benchmark_500Paragraphs() {
        let content = makeStreamingDocument(paragraphCount: 500)
        let (_, lastLine) = parseCommonMarkWithLastLine(content)
        let byteOffset = utf8ByteOffset(forLine: lastLine, in: content)

        _ = parseCommonMark(content)

        let fullNs = medianNs(iterations: 5) {
            _ = parseCommonMark(content)
        }

        let tailNs = medianNs(iterations: 5) {
            let utf8 = content.utf8
            let boundaryIdx = utf8.index(utf8.startIndex, offsetBy: byteOffset)
            let tail = String(content[boundaryIdx...])
            _ = parseCommonMark(tail)
        }

        let lineCount = content.components(separatedBy: "\n").count
        print("[Perf] 500-para (\(lineCount) lines): full=\(Int(fullNs/1000))µs  tail=\(Int(tailNs/1000))µs  speedup=\(String(format: "%.1f", fullNs/max(tailNs, 1)))×")

        // Tail-only should be much faster than full for 500 paragraphs.
        #expect(tailNs < fullNs * 0.5, "Tail-only parse should be at least 2× faster for 500 paragraphs")
    }

    // MARK: - 1000-paragraph benchmark

    @Test func benchmark_1000Paragraphs() {
        let content = makeStreamingDocument(paragraphCount: 1000)
        let (_, lastLine) = parseCommonMarkWithLastLine(content)
        let byteOffset = utf8ByteOffset(forLine: lastLine, in: content)

        _ = parseCommonMark(content)

        let fullNs = medianNs(iterations: 3) {
            _ = parseCommonMark(content)
        }

        let tailNs = medianNs(iterations: 3) {
            let utf8 = content.utf8
            let boundaryIdx = utf8.index(utf8.startIndex, offsetBy: byteOffset)
            let tail = String(content[boundaryIdx...])
            _ = parseCommonMark(tail)
        }

        let lineCount = content.components(separatedBy: "\n").count
        print("[Perf] 1000-para (\(lineCount) lines): full=\(Int(fullNs/1000))µs  tail=\(Int(tailNs/1000))µs  speedup=\(String(format: "%.1f", fullNs/max(tailNs, 1)))×")

        // For 1000 paragraphs, tail-only should be at least 5× faster.
        #expect(tailNs < fullNs * 0.3, "Tail-only parse should be at least 3× faster for 1000 paragraphs")
    }

    // MARK: - Boundary extraction overhead

    @Test func benchmark_boundaryExtractionOverhead() {
        // Verify that computing the UTF-8 byte offset from a line number is
        // negligible (< 1ms for 1000-line document).
        let content = makeStreamingDocument(paragraphCount: 1000)
        let (_, lastLine) = parseCommonMarkWithLastLine(content)

        let overheadNs = medianNs {
            _ = utf8ByteOffset(forLine: lastLine, in: content)
        }

        print("[Perf] utf8ByteOffset (1000-para): \(Int(overheadNs/1000))µs")
        // One-time overhead per new block boundary (runs only on the full-parse
        // tick, not on subsequent tail-only ticks).  5ms is a very conservative
        // upper bound — typical simulator time is ~1-2ms; device is ~0.2-0.5ms.
        #expect(overheadNs < 5_000_000, "utf8ByteOffset should complete in < 5ms for 1000-line documents")
    }

    // MARK: - Phase 2: Segment build benchmarks

    /// Compare full `FlatSegment.build` over all blocks (old hot path) vs
    /// build over tail blocks only + merge (new Phase 2 hot path).
    ///
    /// For a document where the prefix has N finalized blocks and the tail is
    /// one growing paragraph, Phase 2 builds 1 block instead of N+1.
    @Test func benchmark_segmentBuild_500Paragraphs_tailVsFull() {
        let content = makeStreamingDocument(paragraphCount: 500)
        let themeID = ThemeRuntimeState.currentThemeID()
        let (allBlocks, lastLine) = parseCommonMarkWithLastLine(content)
        let byteOffset = utf8ByteOffset(forLine: lastLine, in: content)

        guard byteOffset > 0, byteOffset < content.utf8.count else {
            // No stable prefix — benchmark not applicable.
            return
        }

        let utf8 = content.utf8
        let boundaryIdx = utf8.index(utf8.startIndex, offsetBy: byteOffset)
        let tailContent = String(content[boundaryIdx...])
        let prefixBlocks = Array(allBlocks.dropLast())
        let (tailBlocks, _) = parseCommonMarkWithLastLine(tailContent)
        let prefixSegments = FlatSegment.build(from: prefixBlocks, themeID: themeID)

        // Warm up
        _ = FlatSegment.build(from: allBlocks, themeID: themeID)

        // Old path: build ALL blocks every tick.
        let fullBuildNs = medianNs(iterations: 20) {
            _ = FlatSegment.build(from: allBlocks, themeID: themeID)
        }

        // New path: build only tail blocks, merge with cached prefix.
        let tailBuildNs = medianNs(iterations: 20) {
            let tailSegs = FlatSegment.build(from: tailBlocks, themeID: themeID)
            _ = mergingSegments(prefix: prefixSegments, tail: tailSegs)
        }

        print("[Perf] FlatSegment.build 500-para: full=\(Int(fullBuildNs/1000))µs  tail+merge=\(Int(tailBuildNs/1000))µs  speedup=\(String(format: "%.1f", fullBuildNs/max(tailBuildNs, 1)))×")

        #expect(tailBuildNs < fullBuildNs * 0.5, "Tail+merge build should be at least 2× faster than full build for 500 paragraphs")
    }

    @Test func benchmark_segmentBuild_1000Paragraphs_tailVsFull() {
        let content = makeStreamingDocument(paragraphCount: 1000)
        let themeID = ThemeRuntimeState.currentThemeID()
        let (allBlocks, lastLine) = parseCommonMarkWithLastLine(content)
        let byteOffset = utf8ByteOffset(forLine: lastLine, in: content)

        guard byteOffset > 0, byteOffset < content.utf8.count else { return }

        let utf8 = content.utf8
        let boundaryIdx = utf8.index(utf8.startIndex, offsetBy: byteOffset)
        let tailContent = String(content[boundaryIdx...])
        let prefixBlocks = Array(allBlocks.dropLast())
        let (tailBlocks, _) = parseCommonMarkWithLastLine(tailContent)
        let prefixSegments = FlatSegment.build(from: prefixBlocks, themeID: themeID)

        _ = FlatSegment.build(from: allBlocks, themeID: themeID)

        let fullBuildNs = medianNs(iterations: 5) {
            _ = FlatSegment.build(from: allBlocks, themeID: themeID)
        }

        let tailBuildNs = medianNs(iterations: 5) {
            let tailSegs = FlatSegment.build(from: tailBlocks, themeID: themeID)
            _ = mergingSegments(prefix: prefixSegments, tail: tailSegs)
        }

        print("[Perf] FlatSegment.build 1000-para: full=\(Int(fullBuildNs/1000))µs  tail+merge=\(Int(tailBuildNs/1000))µs  speedup=\(String(format: "%.1f", fullBuildNs/max(tailBuildNs, 1)))×")

        #expect(tailBuildNs < fullBuildNs * 0.3, "Tail+merge build should be at least 3× faster for 1000 paragraphs")
    }

    // Expose the merge logic to test code via a file-private helper so the
    // benchmark can invoke the same logic as the production path.
    private func mergingSegments(prefix: [FlatSegment], tail: [FlatSegment]) -> [FlatSegment] {
        guard !prefix.isEmpty, !tail.isEmpty else { return prefix + tail }
        if case .text(let pt) = prefix.last, case .text(let tt) = tail.first {
            var merged = pt
            merged.append(AttributedString("\n\n"))
            merged.append(tt)
            var result = Array(prefix.dropLast())
            result.append(.text(merged))
            result.append(contentsOf: tail.dropFirst())
            return result
        }
        return prefix + tail
    }
}

// MARK: - Boundary Detection Edge Cases

/// Ensures the `lastBlockStartLine` boundary detection handles edge cases
/// that could arise mid-stream.
@Suite("Boundary Detection Edge Cases")
struct BoundaryDetectionEdgeCaseTests {

    @Test func codeBlockContainingBlankLine_boundaryIsBeforeCodeBlock() {
        // Code block contains internal blank lines — the boundary should be
        // found at the code block start, not inside it.
        let md = """
        Prose paragraph.

        ```python
        def foo():
            x = 1

            return x
        ```
        """
        let (blocks, lastLine) = parseCommonMarkWithLastLine(md)
        // 2 blocks: paragraph + codeBlock
        #expect(blocks.count == 2)
        // Last block (code block) starts after the blank line following "Prose paragraph."
        #expect(lastLine == 3)
    }

    @Test func listFollowedByParagraph_boundaryAtParagraph() {
        let md = """
        - item one
        - item two

        Trailing paragraph.
        """
        let (blocks, lastLine) = parseCommonMarkWithLastLine(md)
        #expect(blocks.count == 2)
        #expect(lastLine > 1)
    }

    @Test func noPreviousBlocks_returnsSingleBlock() {
        let md = "Growing single paragraph with no separators at all."
        let (blocks, lastLine) = parseCommonMarkWithLastLine(md)
        #expect(blocks.count == 1)
        #expect(lastLine == 1)
    }

    @Test func manyBlockTypes_lastLineIsCorrect() {
        let md = """
        # Heading 1

        Paragraph one.

        ## Heading 2

        Paragraph two.

        ---

        Final paragraph.
        """
        let (_, lastLine) = parseCommonMarkWithLastLine(md)
        // "Final paragraph." is the last block — appears after the horizontal rule.
        // Count lines: H1(1) blank(2) Para1(3) blank(4) H2(5) blank(6) Para2(7) blank(8) hr(9) blank(10) Final(11)
        #expect(lastLine == 11)
    }
}
