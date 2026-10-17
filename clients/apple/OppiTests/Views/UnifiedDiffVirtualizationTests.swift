import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Unified diff virtualization")
@MainActor
struct UnifiedDiffVirtualizationTests {
    @Test func largeDiffMountsOnlyViewportChunks() async throws {
        let lineCount = 1_000
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 1,
                oldCount: lineCount,
                newStart: 1,
                newCount: lineCount,
                lines: (1...lineCount).map { line in
                    WorkspaceReviewDiffLine(
                        kind: line.isMultiple(of: 3) ? .added : (line.isMultiple(of: 5) ? .removed : .context),
                        text: "let value\(line) = \(line) // " + String(repeating: "x", count: 180),
                        oldLine: line,
                        newLine: line,
                        spans: line.isMultiple(of: 3)
                            ? [WorkspaceReviewDiffSpan(start: 4, end: 12, kind: .changed)]
                            : nil
                    )
                }
            ),
        ]
        let totalSourceUTF16 = hunks[0].lines.reduce(into: 0) { $0 += $1.text.utf16.count }
        let reader = DiffReaderView()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        reader.frame = host.bounds
        host.addSubview(reader)
        reader.setDiff(hunks: hunks, filePath: "large.txt")
        host.layoutIfNeeded()

        let mountedViewport = await waitForMainActorCondition(timeout: .seconds(10)) {
            host.layoutIfNeeded()
            let mountedUTF16 = timelineAllTextViews(in: host)
                .reduce(into: 0) { $0 += $1.textStorage.length }
            return mountedUTF16 > 0 && mountedUTF16 < totalSourceUTF16 / 4
        }

        #expect(mountedViewport, "A large diff must not mount the whole attributed document")
        let diagnostics = try #require(reader.diagnosticsForTesting())
        #expect(diagnostics.chunkCount > 1)
        #expect(diagnostics.cachedChunkCount <= 14)
        #expect(diagnostics.mountedChunkCount < diagnostics.chunkCount)
        #expect(diagnostics.mountedUTF16Count < diagnostics.totalUTF16Count / 4)
        #expect(diagnostics.indexRanOnMainThread == false)
        #expect(
            diagnostics.contentWidth > diagnostics.boundsWidth,
            "Long clipped diff lines must publish horizontal scroll width"
        )

        let collectionView = try #require(
            timelineAllScrollViews(in: host).compactMap { $0 as? UICollectionView }.first
        )
        collectionView.setContentOffset(
            CGPoint(
                x: collectionView.contentOffset.x,
                y: max(0, collectionView.contentSize.height - collectionView.bounds.height)
            ),
            animated: false
        )
        let renderedTail = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.layoutIfNeeded()
            return timelineAllTextViews(in: host).contains {
                timelineRenderedText(of: $0).contains("value1000")
            }
        }
        #expect(renderedTail)
        let tailDiagnostics = try #require(reader.diagnosticsForTesting())
        #expect(tailDiagnostics.cachedChunkCount <= 14)
        #expect(tailDiagnostics.mountedUTF16Count < tailDiagnostics.totalUTF16Count / 4)
    }

    @Test func wrappingFitsRowsToTheViewportAndTextSizeScalesRows() async throws {
        let longLine = String(repeating: "word ", count: 400)
        let hunks = [WorkspaceReviewDiffHunk(
            oldStart: 1,
            oldCount: 0,
            newStart: 1,
            newCount: 20,
            lines: (1...20).map { line in
                WorkspaceReviewDiffLine(kind: .added, text: "\(line) \(longLine)", oldLine: nil, newLine: line, spans: nil)
            }
        )]
        let reader = DiffReaderView()
        reader.applyReaderPreferencesForTesting(FullScreenReaderPreferences(textScale: 1, wrapsText: false))
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        reader.frame = host.bounds
        host.addSubview(reader)
        reader.setDiff(hunks: hunks, filePath: "notes.txt")

        func settledHeight(_ isSettled: (CGFloat, DiffReaderView.Diagnostics) -> Bool) async -> CGFloat? {
            var settled: CGFloat?
            _ = await waitForMainActorCondition(timeout: .seconds(10)) {
                host.layoutIfNeeded()
                guard let diagnostics = reader.diagnosticsForTesting(),
                      diagnostics.mountedChunkCount > 0,
                      isSettled(reader.contentHeightForTesting, diagnostics) else { return false }
                settled = reader.contentHeightForTesting
                return true
            }
            return settled
        }

        let unwrappedHeight = try #require(await settledHeight { _, diagnostics in
            diagnostics.contentWidth > diagnostics.boundsWidth
        }, "Unwrapped long rows scroll horizontally")

        reader.applyReaderPreferencesForTesting(FullScreenReaderPreferences(textScale: 1, wrapsText: true))
        let wrappedHeight = try #require(await settledHeight { height, diagnostics in
            diagnostics.contentWidth <= diagnostics.boundsWidth && height > unwrappedHeight * 3
        }, "Wrapped rows fit the viewport and grow taller")

        reader.applyReaderPreferencesForTesting(FullScreenReaderPreferences(textScale: 1.3, wrapsText: true))
        _ = try #require(await settledHeight { height, _ in
            height > wrappedHeight * 1.2
        }, "A larger text size makes rows taller")
    }

    @Test func chunkPaintingMatchesWholeDocumentSyntaxNumbersWordsAndGaps() async throws {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 10,
                oldCount: 4,
                newStart: 10,
                newCount: 4,
                lines: [
                    WorkspaceReviewDiffLine(kind: .context, text: "/* comment starts", oldLine: 10, newLine: 10, spans: nil),
                    WorkspaceReviewDiffLine(kind: .removed, text: "let oldValue = 1", oldLine: 11, newLine: nil, spans: [
                        WorkspaceReviewDiffSpan(start: 4, end: 12, kind: .changed),
                    ]),
                    WorkspaceReviewDiffLine(kind: .added, text: "let newValue = 2", oldLine: nil, newLine: 11, spans: [
                        WorkspaceReviewDiffSpan(start: 4, end: 12, kind: .changed),
                    ]),
                    WorkspaceReviewDiffLine(kind: .context, text: "comment ends */", oldLine: 12, newLine: 12, spans: nil),
                ]
            ),
            WorkspaceReviewDiffHunk(
                oldStart: 30,
                oldCount: 1,
                newStart: 30,
                newCount: 1,
                lines: [
                    WorkspaceReviewDiffLine(kind: .context, text: "let tail = true", oldLine: 30, newLine: 30, spans: nil),
                ]
            ),
        ]
        // Chunks always render in painter mode (DiffReaderView tints rows).
        let options = DiffAttributedStringBuilder.Options(
            includeStats: true,
            includeGapSummary: true,
            paintsRowBackgrounds: true
        )
        let built = await Task.detached(priority: .userInitiated) {
            (
                SendableNSAttributedString(DiffAttributedStringBuilder.buildResult(
                    hunks: hunks,
                    filePath: "sample.swift",
                    options: options
                ).attributedText),
                DiffAttributedStringBuilder.buildChunkIndex(
                    hunks: hunks,
                    filePath: "sample.swift",
                    options: options,
                    maxLines: 2,
                    maxUTF8Bytes: 128
                )
            )
        }.value
        let whole = built.0.value
        let index = built.1
        let chunked = NSMutableAttributedString(string: "")
        for chunk in index.chunks {
            chunked.append(DiffAttributedStringBuilder.buildChunk(chunk))
        }

        #expect(index.chunks.count > 1)
        #expect(chunked.string == whole.string)
        #expect(chunked.length == whole.length)
        for location in 0..<whole.length {
            #expect(
                semanticAttributes(at: location, in: chunked)
                    == semanticAttributes(at: location, in: whole),
                "Chunked attributes diverged at UTF-16 offset \(location)"
            )
        }

        let text = chunked.string as NSString
        let changedRange = text.range(of: "newValue")
        #expect(changedRange.location != NSNotFound)
        #expect(chunked.attribute(reviewLineNumberAttributeKey, at: changedRange.location, effectiveRange: nil) as? Int == 11)
        #expect(chunked.attribute(.backgroundColor, at: changedRange.location, effectiveRange: nil) != nil)
        let selectionView = UITextView()
        selectionView.attributedText = chunked
        #expect(ReviewCommentSelectionEditMenuSupport.sourceLineRange(
            in: selectionView,
            range: changedRange,
            sourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenDiff,
                filePath: "sample.swift"
            )
        ) == 11...11)

        let continuedCommentRange = text.range(of: "comment ends")
        #expect(continuedCommentRange.location != NSNotFound)
        #expect(
            chunked.attribute(.foregroundColor, at: continuedCommentRange.location, effectiveRange: nil) as? UIColor
                == SyntaxHighlighter.color(for: .comment)
        )
    }

    private func semanticAttributes(
        at location: Int,
        in attributed: NSAttributedString
    ) -> [String] {
        let attributes = attributed.attributes(at: location, effectiveRange: nil)
        return [
            attributes[reviewLineNumberAttributeKey].map { "line:\($0)" },
            attributes[diffLineKindAttributeKey].map { "kind:\($0)" },
            attributes[diffCodeColumnAttributeKey].map { "code:\($0)" },
            (attributes[.foregroundColor] as? UIColor).map { "fg:\($0.description)" },
            (attributes[.backgroundColor] as? UIColor).map { "bg:\($0.description)" },
            (attributes[.font] as? UIFont).map { "font:\($0.fontName):\($0.pointSize)" },
        ].compactMap { $0 }
    }
}
