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
@Suite("Diff Builder Perf Bench", .tags(.perf))
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

    // MARK: - Long-line prose rewrite (CHANGELOG-shaped)

    /// One 262-line hunk of long markdown paragraphs: 131 removed then 92 added,
    /// lines up to ~1,900 characters. This is the shape of a changelog trim and
    /// stays on the single-document path (under the chunking thresholds).
    static let proseRewriteHunks: [WorkspaceReviewDiffHunk] = {
        let words = ["Client", "Server", "session", "durable", "opens", "the", "diff", "a",
                     "workspace", "shows", "no", "longer", "review", "file", "changes", "with"]
        func paragraph(_ seed: Int) -> String {
            let wordCount = 40 + (seed * 37) % 260
            let body = (0..<wordCount).map { words[($0 * 7 + seed * 13) % words.count] }
            return "- **Client:** " + body.joined(separator: " ") + "."
        }
        var lines: [WorkspaceReviewDiffLine] = []
        for index in 0..<3 {
            lines.append(.init(kind: .context, text: paragraph(index), oldLine: index + 1, newLine: index + 1, spans: nil))
        }
        for index in 0..<131 {
            lines.append(.init(kind: .removed, text: paragraph(100 + index), oldLine: 4 + index, newLine: nil, spans: nil))
        }
        for index in 0..<92 {
            let text = paragraph(500 + index)
            // Paired edits carry a few word spans; rewritten lines carry none.
            let spans: [WorkspaceReviewDiffSpan]? = index.isMultiple(of: 4)
                ? [.init(start: 14, end: 20, kind: .changed), .init(start: 40, end: 52, kind: .changed)]
                : nil
            lines.append(.init(kind: .added, text: text, oldLine: nil, newLine: 4 + index, spans: spans))
        }
        for index in 0..<36 {
            lines.append(.init(kind: .context, text: paragraph(900 + index), oldLine: 135 + index, newLine: 96 + index, spans: nil))
        }
        return [WorkspaceReviewDiffHunk(oldStart: 1, oldCount: 170, newStart: 1, newCount: 131, lines: lines)]
    }()

    /// What the review reader (`DiffReaderView`) does per chunk and per tile.
    ///
    /// - `diffPrepare_prose_rewrite_chunk`: style + TextKit layout of the first
    ///   chunk (off the main thread in the reader).
    /// - `diffAttach_prose_rewrite_chunk`: main-thread cost to put a prepared
    ///   chunk on screen (text view creation and its layout pass).
    /// - `diffPaint_prose_rewrite_viewport`: CPU background pass for one
    ///   phone-sized tile (row tints are GPU layers; only word highlights remain).
    /// - `diffDraw_prose_rewrite_viewport`: background + glyphs for that tile.
    @Test("Benchmark: prose rewrite reader chunk + one viewport paint")
    func proseRewriteViewportPaint() throws {
        // Same chunking as DiffReaderView (8 KB).
        let index = DiffAttributedStringBuilder.buildChunkIndex(
            hunks: Self.proseRewriteHunks,
            filePath: "CHANGELOG.md",
            options: .init(includeStats: false, includeGapSummary: true, paintsRowBackgrounds: true),
            maxUTF8Bytes: 8 * 1024
        )
        let chunk = try #require(index.chunks.first)
        let unwrapped = FullScreenReaderPreferences(wrapsText: false)
        let prepareUs = Self.measureUs {
            _ = DiffReaderPreparedChunk.prepare(chunk, preferences: unwrapped, wrapWidth: nil)
        }
        let prepareWrappedUs = Self.measureUs {
            _ = DiffReaderPreparedChunk.prepare(
                chunk,
                preferences: FullScreenReaderPreferences(wrapsText: true),
                wrapWidth: 402
            )
        }
        // measureUs runs its block six times; each attach needs a fresh chunk.
        var unattached = (0..<6).map { _ in
            DiffReaderPreparedChunk.prepare(chunk, preferences: unwrapped, wrapWidth: nil)
        }
        let attachUs = Self.measureUs {
            let textView = unattached.removeLast().makeTextView()
            textView.layoutIfNeeded()
        }
        let textView = DiffReaderPreparedChunk.prepare(chunk, preferences: unwrapped, wrapWidth: nil).makeTextView()
        let layoutManager = textView.layoutManager

        // One phone-sized tile, the unit TextKit repaints while scrolling.
        let viewport = CGRect(x: 0, y: 0, width: 402, height: 874)
        let glyphs = layoutManager.glyphRange(forBoundingRect: viewport, in: textView.textContainer)
        let renderer = UIGraphicsImageRenderer(size: viewport.size)
        let paintUs = Self.measureUs {
            _ = renderer.image { _ in
                layoutManager.drawBackground(forGlyphRange: glyphs, at: .zero)
            }
        }
        let drawUs = Self.measureUs {
            _ = renderer.image { _ in
                layoutManager.drawBackground(forGlyphRange: glyphs, at: .zero)
                layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            }
        }
        print("METRIC diffPrepare_prose_rewrite_chunk=\(prepareUs)")
        print("METRIC diffPrepare_prose_rewrite_chunk_wrapped=\(prepareWrappedUs)")
        print("METRIC diffAttach_prose_rewrite_chunk=\(attachUs)")
        print("METRIC diffPaint_prose_rewrite_viewport=\(paintUs)")
        print("METRIC diffDraw_prose_rewrite_viewport=\(drawUs)")
        #expect(paintUs < 500_000, "viewport paint: \(paintUs)μs")
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
