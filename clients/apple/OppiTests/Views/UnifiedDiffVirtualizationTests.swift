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
        let index = await Task.detached(priority: .userInitiated) {
            DiffAttributedStringBuilder.buildChunkIndex(
                hunks: hunks,
                filePath: "large.txt",
                options: .init(includeStats: false, includeGapSummary: true)
            )
        }.value
        let chunkView = DiffChunkCollectionView(
            index: index,
            backgroundColor: UIColor(Color.themeBgDark),
            reviewCommentSelectionContext: nil,
            sourceContext: nil
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chunkView.frame = host.bounds
        host.addSubview(chunkView)
        host.layoutIfNeeded()

        let mountedViewport = await waitForMainActorCondition(timeout: .seconds(10)) {
            host.layoutIfNeeded()
            let mountedUTF16 = timelineAllTextViews(in: host)
                .reduce(into: 0) { $0 += $1.textStorage.length }
            return mountedUTF16 > 0 && mountedUTF16 < totalSourceUTF16 / 4
        }

        #expect(mountedViewport, "A large diff must not mount the whole attributed document")
        let diagnostics = try #require(chunkView.virtualizationDiagnosticsForTesting())
        #expect(diagnostics.chunkCount > 1)
        #expect(diagnostics.cachedChunkCount <= 14)
        #expect(diagnostics.mountedChunkCount < diagnostics.chunkCount)
        #expect(diagnostics.mountedUTF16Count < diagnostics.totalUTF16Count / 4)
        #expect(diagnostics.indexRanOnMainThread == false)
        #expect(
            diagnostics.collectionContentWidth > diagnostics.collectionBoundsWidth,
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
        let tailDiagnostics = try #require(chunkView.virtualizationDiagnosticsForTesting())
        #expect(tailDiagnostics.cachedChunkCount <= 14)
        #expect(tailDiagnostics.mountedUTF16Count < tailDiagnostics.totalUTF16Count / 4)

        let wholeDocument = await Task.detached(priority: .userInitiated) {
            SendableNSAttributedString(DiffAttributedStringBuilder.buildResult(
                hunks: hunks,
                filePath: "large.txt",
                options: .init(includeStats: false, includeGapSummary: true)
            ).attributedText)
        }.value.value
        let baselineStorage = NSTextStorage()
        let baselineLayout = NSLayoutManager()
        let baselineContainer = NSTextContainer(size: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        baselineContainer.lineFragmentPadding = 0
        baselineContainer.lineBreakMode = .byClipping
        baselineLayout.addTextContainer(baselineContainer)
        baselineStorage.addLayoutManager(baselineLayout)
        let baselineStarted = CACurrentMediaTime()
        baselineStorage.setAttributedString(wholeDocument)
        baselineLayout.ensureLayout(for: baselineContainer)
        let baselineLayoutInstallMilliseconds = (CACurrentMediaTime() - baselineStarted) * 1_000

        print(
            "DIFF_JIT baseline_utf16=\(wholeDocument.length) baseline_layout_install_ms=\(baselineLayoutInstallMilliseconds) "
                + "chunk_count=\(diagnostics.chunkCount) cached_chunks=\(diagnostics.cachedChunkCount) "
                + "mounted_chunks=\(diagnostics.mountedChunkCount) mounted_utf16=\(diagnostics.mountedUTF16Count) "
                + "collection_content_width=\(diagnostics.collectionContentWidth) "
                + "collection_bounds_width=\(diagnostics.collectionBoundsWidth) "
                + "mean_chunk_layout_install_ms=\(diagnostics.meanLayoutInstallMilliseconds)"
        )
        #expect(diagnostics.meanLayoutInstallMilliseconds > 0)
        #expect(baselineLayoutInstallMilliseconds > diagnostics.meanLayoutInstallMilliseconds)
    }

    @Test func smallDiffKeepsWholeDocumentPathWhileLargeDiffUsesChunks() {
        let small = [WorkspaceReviewDiffHunk(
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 1,
            lines: [WorkspaceReviewDiffLine(
                kind: .context,
                text: "let value = 1",
                oldLine: 1,
                newLine: 1,
                spans: nil
            )]
        )]
        let large = [WorkspaceReviewDiffHunk(
            oldStart: 1,
            oldCount: 601,
            newStart: 1,
            newCount: 601,
            lines: (1...601).map { (line: Int) in
                WorkspaceReviewDiffLine(
                    kind: .context,
                    text: "line \(line)",
                    oldLine: line,
                    newLine: line,
                    spans: nil
                )
            }
        )]

        #expect(!UnifiedDiffView.shouldUseChunkedRendering(for: small))
        #expect(UnifiedDiffView.shouldUseChunkedRendering(for: large))
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
        let options = DiffAttributedStringBuilder.Options(includeStats: true, includeGapSummary: true)
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
