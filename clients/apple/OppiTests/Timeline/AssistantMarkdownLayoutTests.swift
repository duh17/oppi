import Foundation
import Testing
import UIKit
@testable import Oppi

/// Layout regression tests for AssistantMarkdownContentView self-sizing.
///
/// Ensures dense markdown with interleaved prose and code blocks produces
/// correct cell heights in the collection view. Guards against regressions
/// if the text view implementation changes (e.g., UILabel ↔ UITextView).
@Suite("AssistantMarkdownContentView Layout")
@MainActor
struct AssistantMarkdownLayoutTests {

    @Test func denseMarkdownProducesCorrectCellHeight() throws {
        let markdown = """
        # Heading

        Some prose text here.

        ```text
        Explain this:
        ```

        More prose between code blocks.

        ```swift
        let x = 1
        ```

        Final paragraph.
        """

        let config = AssistantTimelineRowConfiguration(
            text: markdown,
            isStreaming: false,
            canFork: false,
            onFork: nil,
        )
        let cell = AssistantTimelineRowContentView(configuration: config)

        // Mirror the exact SafeSizingCell path — no container, no pre-layout.
        let fitted = cell.systemLayoutSizeFitting(
            CGSize(width: 370, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .defaultLow
        )

        // Heading + 2 prose + 2 code blocks + spacing ≈ 250pt minimum.
        #expect(fitted.height > 200, "Cell height \(fitted.height) too small — prose or code blocks likely collapsed")
    }

    @Test func collectionViewCellsDoNotOverlap() throws {
        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            collectionViewLayout: layout
        )

        let items: [(String, String)] = [
            ("msg-1", "Short first message."),
            ("msg-2", "# Doc\n\nProse.\n\n```text\nTemplate\n```\n\nMore prose.\n\n```swift\nlet x = 1\n```\n\nEnd."),
            ("msg-3", "Short after long."),
        ]

        let reg = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, itemID in
            guard let text = items.first(where: { $0.0 == itemID })?.1 else { return }
            cell.contentConfiguration = AssistantTimelineRowConfiguration(
                text: text, isStreaming: false, canFork: false, onFork: nil
            )
        }

        let ds = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.0))
        ds.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()

        let sorted = collectionView.indexPathsForVisibleItems
            .sorted { $0.item < $1.item }
            .compactMap { collectionView.cellForItem(at: $0) }
            .map(\.frame)

        #expect(sorted.count >= 2)
        for i in 0 ..< sorted.count - 1 {
            let gap = sorted[i + 1].minY - sorted[i].maxY
            #expect(gap >= 0, "Cells \(i) and \(i + 1) overlap by \(-gap)pt")
        }
    }

    /// Regression: markdown images decode asynchronously. Soft layout invalidation
    /// is skipped while detached from bottom, so scroll-away/recycle can leave the
    /// image cut off until another interaction. Size changes must force-invalidate.
    @Test func asyncPNGImageGrowsWhileDetachedFromBottom() async throws {
        let hostSize = CGSize(width: 393, height: 852)
        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = AnchoredCollectionView(
            frame: CGRect(origin: .zero, size: hostSize),
            collectionViewLayout: layout
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
        window.addSubview(collectionView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 320)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 320))
        }
        let imageData = try #require(image.pngData())

        let items: [(String, AssistantTimelineRowConfiguration)] = [
            (
                "msg-image",
                AssistantTimelineRowConfiguration(
                    text: """
                    Detached markdown image regression fixture.

                    ![Tall chart](fixtures/tall.png)

                    Tail prose under the image.
                    """,
                    isStreaming: false,
                    canFork: false,
                    onFork: nil,
                    sessionId: "assistant-png-detached-relayout",
                    workspaceID: "ws-png",
                    serverBaseURL: URL(string: "https://server.example.com")!,
                    fetchWorkspaceFile: { _, _ in
                        try await Task.sleep(for: .milliseconds(80))
                        return imageData
                    }
                )
            ),
            (
                "msg-after",
                AssistantTimelineRowConfiguration(
                    text: "This row must move down after detached image render.",
                    isStreaming: false,
                    canFork: false,
                    onFork: nil,
                    sessionId: "assistant-png-detached-relayout"
                )
            ),
        ]

        let registration = UICollectionView.CellRegistration<SafeSizingCell, String> { cell, _, itemID in
            guard let config = items.first(where: { $0.0 == itemID })?.1 else { return }
            cell.contentConfiguration = config
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: registration, for: ip, item: id)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.0))
        await dataSource.apply(snapshot, animatingDifferences: false)
        window.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        let firstIP = IndexPath(item: 0, section: 0)
        let initialFirstHeight = try #require(
            collectionView.layoutAttributesForItem(at: firstIP)?.frame.height
        )

        collectionView.isDetachedFromBottom = true
        collectionView.captureDetachedAnchor()
        #expect(collectionView.detachedAnchorIsActive)

        let imageRendered = await waitForTimelineCondition(timeoutMs: 1_800) {
            await MainActor.run {
                window.layoutIfNeeded()
                collectionView.layoutIfNeeded()
                guard let firstCell = collectionView.cellForItem(at: firstIP),
                      let imageView = timelineFirstView(ofType: NativeMarkdownImageView.self, in: firstCell.contentView)
                else {
                    return false
                }
                return timelineAllImageViews(in: imageView).contains { $0.image != nil && !$0.isHidden }
            }
        }
        #expect(imageRendered, "Expected delayed markdown PNG to decode while detached")

        let reflowed = await waitForTimelineCondition(timeoutMs: 1_400) {
            await MainActor.run {
                window.layoutIfNeeded()
                collectionView.layoutIfNeeded()
                guard let firstFrame = collectionView.layoutAttributesForItem(at: firstIP)?.frame,
                      let firstCell = collectionView.cellForItem(at: firstIP),
                      let imageView = timelineFirstView(ofType: NativeMarkdownImageView.self, in: firstCell.contentView)
                else {
                    return false
                }
                let expectedImageHeight = ImageViewportSizing.fittedHeight(
                    forWidth: max(1, imageView.bounds.width),
                    heightToWidthRatio: 320.0 / 80.0,
                    surface: .inlineProse,
                    screenHeight: window.windowScene?.screen.bounds.height ?? hostSize.height
                )
                let imageTallEnough = imageView.bounds.height >= expectedImageHeight - 8
                let rowGrew = firstFrame.height > initialFirstHeight + 40
                // The user-visible bug is the image row staying short while detached.
                return imageTallEnough && rowGrew
            }
        }

        #expect(
            reflowed,
            "Detached markdown image stayed cut off after decode; initialRow=\(initialFirstHeight)"
        )
    }

    /// Regression: inline markdown images render asynchronously after the
    /// assistant row is first measured. If the enclosing collection view layout
    /// is not invalidated when the image appears, following rows can overlap it.
    @Test func asyncSVGImageRenderReflowsTimelineWithoutUserTouch() async throws {
        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            collectionViewLayout: layout
        )
        let window = UIWindow(frame: collectionView.frame)
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let items: [(String, AssistantTimelineRowConfiguration)] = [
            (
                "msg-svg",
                AssistantTimelineRowConfiguration(
                    text: """
                    SVG async reflow regression fixture.

                    ![Donkey](fixtures/test.svg)

                    Tail prose under the image.
                    """,
                    isStreaming: false,
                    canFork: false,
                    onFork: nil,
                    sessionId: "assistant-svg-async-relayout",
                    workspaceID: "ws-svg",
                    serverBaseURL: URL(string: "https://server.example.com")!,
                    fetchWorkspaceFile: { _, _ in
                        try await Task.sleep(for: .milliseconds(50))
                        return Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 320 180\"><rect width=\"320\" height=\"180\" fill=\"red\"/></svg>".utf8)
                    }
                )
            ),
            (
                "msg-after",
                AssistantTimelineRowConfiguration(
                    text: "This row must move down after image render.",
                    isStreaming: false,
                    canFork: false,
                    onFork: nil,
                    sessionId: "assistant-svg-async-relayout"
                )
            ),
        ]

        let reg = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, itemID in
            guard let config = items.first(where: { $0.0 == itemID })?.1 else { return }
            cell.contentConfiguration = config
        }

        let ds = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.0))
        await ds.apply(snapshot, animatingDifferences: false)
        window.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        let firstIP = IndexPath(item: 0, section: 0)
        let secondIP = IndexPath(item: 1, section: 0)
        let initialSecondMinY = try #require(collectionView.layoutAttributesForItem(at: secondIP)?.frame.minY)

        let imageRendered = await waitForTimelineCondition(timeoutMs: 10_000) {
            await MainActor.run {
                window.layoutIfNeeded()
                guard let firstCell = collectionView.cellForItem(at: firstIP),
                      let imageView = timelineFirstView(ofType: NativeMarkdownImageView.self, in: firstCell.contentView) else {
                    return false
                }
                return timelineAllViews(in: imageView).contains {
                    String(describing: type(of: $0)).contains("ReviewCommentWKWebView") && !$0.isHidden
                }
            }
        }

        #expect(imageRendered, "SVG fixture did not render in time")

        let layoutReflowedWithoutTouch = await waitForTimelineCondition(timeoutMs: 1_400) {
            await MainActor.run {
                window.layoutIfNeeded()
                guard let firstFrame = collectionView.layoutAttributesForItem(at: firstIP)?.frame,
                      let secondFrame = collectionView.layoutAttributesForItem(at: secondIP)?.frame else {
                    return false
                }

                let rowsSeparated = secondFrame.minY >= firstFrame.maxY - 0.5
                let secondRowMovedDown = secondFrame.minY > initialSecondMinY + 4
                let initialLayoutReservedUsefulSpace = initialSecondMinY >= firstFrame.maxY - 24
                return rowsSeparated && (secondRowMovedDown || initialLayoutReservedUsefulSpace)
            }
        }

        #expect(layoutReflowedWithoutTouch, "Timeline did not keep SVG rows separated after async render")
        window.resignKey()
    }

    /// Regression: mermaid renders asynchronously after the assistant row is
    /// first measured. If the enclosing collection view layout is not
    /// invalidated when the diagram appears, the row keeps its old height until
    /// the next user interaction, and following rows can overlap it.
    @Test func asyncMermaidRenderReflowsTimelineWithoutUserTouch() async throws {
        let wh = makeWindowedTimelineHarness(
            sessionId: "assistant-mermaid-async-relayout",
            useAnchoredCollectionView: true
        )

        let mermaidMessage = """
        Mermaid async reflow regression fixture.

        ```mermaid
        flowchart TD
            A[Capture] --> B[Normalize]
            B --> C[Enrich]
            C --> D[Index]
            D --> E[Retrieve]
            E --> F[Summarize]
            F --> G[Share]
            B --> H[Deduplicate]
            H --> I[Merge]
            I --> J[Score]
            J --> K[Rank]
            K --> L[Answer]
            L --> M[Audit]
            M --> N[Feedback]
        ```

        Tail prose under the diagram.
        """

        wh.applyItems(
            [
                .assistantMessage(id: "msg-mermaid", text: mermaidMessage, timestamp: Date(timeIntervalSince1970: 0)),
                .assistantMessage(id: "msg-after", text: "This row must move down after diagram render.", timestamp: Date(timeIntervalSince1970: 1)),
            ],
            isBusy: false
        )

        let firstIP = IndexPath(item: 0, section: 0)
        let secondIP = IndexPath(item: 1, section: 0)

        let initialSecondMinY = try #require(wh.collectionView.layoutAttributesForItem(at: secondIP)?.frame.minY)

        let diagramRendered = await waitForTimelineCondition(timeoutMs: 1_400) {
            await MainActor.run {
                guard let firstCell = wh.collectionView.cellForItem(at: firstIP),
                      let mermaidView = timelineFirstView(ofType: NativeMermaidBlockView.self, in: firstCell.contentView) else {
                    return false
                }
                return timelineAllImageViews(in: mermaidView).contains { !$0.isHidden && $0.image != nil }
            }
        }

        #expect(diagramRendered, "Mermaid fixture did not render image in time")

        let layoutReflowedWithoutTouch = await waitForTimelineCondition(timeoutMs: 1_400) {
            await MainActor.run {
                guard let firstFrame = wh.collectionView.layoutAttributesForItem(at: firstIP)?.frame,
                      let secondFrame = wh.collectionView.layoutAttributesForItem(at: secondIP)?.frame else {
                    return false
                }

                let rowsSeparated = secondFrame.minY >= firstFrame.maxY - 0.5
                let secondRowMovedDown = secondFrame.minY > initialSecondMinY + 20
                return rowsSeparated && secondRowMovedDown
            }
        }

        let finalFrames = await MainActor.run {
            (
                wh.collectionView.layoutAttributesForItem(at: firstIP)?.frame,
                wh.collectionView.layoutAttributesForItem(at: secondIP)?.frame
            )
        }

        #expect(
            layoutReflowedWithoutTouch,
            "Timeline did not reflow after async mermaid render (initial second.minY=\(initialSecondMinY), final first=\(String(describing: finalFrames.0)), final second=\(String(describing: finalFrames.1)))"
        )
    }

    @Test func streamingTextGrowthInvalidatesTextViewHeight() throws {
        let markdownView = AssistantMarkdownContentView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 350, height: 900))
        markdownView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(markdownView)
        NSLayoutConstraint.activate([
            markdownView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            markdownView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            markdownView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        let phase1 = "Streaming markdown should start with a short line."
        markdownView.apply(configuration: .make(
            content: phase1,
            isStreaming: true,
            themeID: .dark
        ))
        container.layoutIfNeeded()

        let initialTextView = try #require(timelineFirstTextView(in: markdownView))
        let initialFrameHeight = initialTextView.frame.height
        let initialFittedHeight = markdownView.systemLayoutSizeFitting(
            CGSize(width: 350, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        let phase2 = """
        Streaming markdown should start with a short line.

        Then the same text segment keeps growing with enough additional prose to wrap across several lines inside the same UITextView. Without intrinsic-size invalidation after textStorage.append(delta), UIKit keeps the old height and later lines paint over whatever follows.
        """
        markdownView.apply(configuration: .make(
            content: phase2,
            isStreaming: true,
            themeID: .dark
        ))
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let grownTextView = try #require(timelineFirstTextView(in: markdownView))
        let grownFittedHeight = markdownView.systemLayoutSizeFitting(
            CGSize(width: 350, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        #expect(
            grownTextView.frame.height > initialFrameHeight + 20,
            "Streaming text view height should grow after append (before: \(initialFrameHeight), after: \(grownTextView.frame.height))"
        )
        #expect(
            grownFittedHeight > initialFittedHeight + 20,
            "Markdown view fitted height should grow after append (before: \(initialFittedHeight), after: \(grownFittedHeight))"
        )
    }

    @Test func streamingHeadingBelowThematicBreakStaysPinned() throws {
        let markdownView = AssistantMarkdownContentView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 350, height: 1_400))
        markdownView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(markdownView)
        NSLayoutConstraint.activate([
            markdownView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            markdownView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            markdownView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        var content = """
        Intro text.

        ---

        ## What to keep

        These notes start short.
        """
        markdownView.apply(configuration: .make(
            content: content,
            isStreaming: true,
            themeID: .dark
        ))
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let initialTextView = try #require(timelineAllTextViews(in: markdownView).first {
            timelineRenderedText(of: $0).contains("What to keep")
        })
        let initialHeadingY = try #require(visibleTextMinY(of: "What to keep", in: initialTextView))

        let streamedChunks = Array(repeating:
            " More streamed prose arrives underneath the heading and keeps wrapping across many lines so the paragraph grows substantially while the heading itself should remain visually pinned in place above it.",
            count: 12
        )

        for chunk in streamedChunks {
            content += chunk
            markdownView.apply(configuration: .make(
                content: content,
                isStreaming: true,
                themeID: .dark
            ))
            container.setNeedsLayout()
            container.layoutIfNeeded()
        }

        let updatedTextView = try #require(timelineAllTextViews(in: markdownView).first {
            timelineRenderedText(of: $0).contains("What to keep")
        })
        let updatedHeadingY = try #require(visibleTextMinY(of: "What to keep", in: updatedTextView))

        #expect(
            abs(updatedHeadingY - initialHeadingY) < 1,
            "Heading shifted vertically during streaming (before: \(initialHeadingY), after: \(updatedHeadingY))"
        )
        #expect(
            abs(updatedTextView.contentOffset.y + updatedTextView.adjustedContentInset.top) < 0.5,
            "Non-scrollable markdown text view drifted to contentOffset.y=\(updatedTextView.contentOffset.y)"
        )
    }

    @Test func streamingHeadingDoesNotScrollWithinStaleFrameBetweenRelayouts() throws {
        let markdownView = AssistantMarkdownContentView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 350, height: 500))
        markdownView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(markdownView)
        NSLayoutConstraint.activate([
            markdownView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            markdownView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            markdownView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        var content = """
        Intro text.

        ---

        ## What to keep

        These notes start short.
        """
        markdownView.apply(configuration: .make(
            content: content,
            isStreaming: true,
            themeID: .dark
        ))
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: markdownView).first {
            timelineRenderedText(of: $0).contains("What to keep")
        })
        let initialHeadingY = try #require(visibleTextMinY(of: "What to keep", in: textView))
        let initialFrameHeight = textView.frame.height

        for _ in 0..<12 {
            content += " More streamed prose arrives underneath the heading and keeps wrapping across many lines so the paragraph grows substantially while the cell is still using the old measured height."
            markdownView.apply(configuration: .make(
                content: content,
                isStreaming: true,
                themeID: .dark
            ))
            // Intentionally skip layout to mirror streaming ticks between
            // collection-view self-sizing passes.
        }

        let updatedTextView = try #require(timelineAllTextViews(in: markdownView).first {
            timelineRenderedText(of: $0).contains("What to keep")
        })
        let updatedHeadingY = try #require(visibleTextMinY(of: "What to keep", in: updatedTextView))

        #expect(
            updatedTextView.frame.height == initialFrameHeight,
            "Fixture expects the text view frame to remain stale between relayouts"
        )
        #expect(
            abs(updatedHeadingY - initialHeadingY) < 1,
            "Heading shifted inside a stale text view frame (before: \(initialHeadingY), after: \(updatedHeadingY))"
        )
        #expect(
            abs(updatedTextView.contentOffset.y + updatedTextView.adjustedContentInset.top) < 0.5,
            "Non-scrollable markdown text view drifted to contentOffset.y=\(updatedTextView.contentOffset.y) before relayout"
        )
    }

    @Test func streamingStructuralMarkdownRebuildBustsCachedCollectionHeight() async throws {
        let wh = makeWindowedTimelineHarness(
            sessionId: "assistant-streaming-structural-cache",
            useAnchoredCollectionView: true
        )
        let itemID = "assistant-streaming-structural-cache"
        let timestamp = Date(timeIntervalSince1970: 0)
        let initialText = "Overlap repro fixture.\n\nShort intro before the rich markdown arrives."
        let updatedText = """
        Overlap repro fixture.

        This paragraph stays short at first, then the renderer suddenly has to fit multiple rich blocks in one assistant row.

        ```swift
        enum TimelineScrollIntent {
            case none
            case initialBottom(id: String)
            case jumpToBottom(id: String, animated: Bool)
            case navigateTo(id: String)
        }
        ```

        ```swift
        if explicitIntent {
            performExplicitScroll()
        } else if detached {
            preserveViewport()
        } else if isBusy {
            keepTailVisibleWithinComfortBand()
        } else {
            settleToExactBottomIfStillAttached()
        }
        ```

        The key simplification: streaming is not a scroll animation anymore. Streaming is content appearing, scrolling only nudges.
        """

        wh.applyItems(
            [
                .assistantMessage(id: itemID, text: initialText, timestamp: timestamp),
            ],
            isBusy: false,
            streamingID: itemID
        )

        let indexPath = IndexPath(item: 0, section: 0)
        let initialCell = try #require(try configuredTimelineCell(in: wh.collectionView, item: 0) as? SafeSizingCell)
        let initialHeight = initialCell.frame.height
        initialCell.cachedStreamingHeight = initialHeight
        initialCell.lastFullSizeComputeNs = DispatchTime.now().uptimeNanoseconds

        wh.applyItems(
            [
                .assistantMessage(id: itemID, text: updatedText, timestamp: timestamp),
            ],
            isBusy: false,
            streamingID: itemID
        )

        let reflowed = await waitForTimelineCondition(timeoutMs: 500) {
            await MainActor.run {
                wh.collectionView.layoutIfNeeded()
                guard let cell = wh.collectionView.cellForItem(at: indexPath) as? SafeSizingCell,
                      let row = timelineFirstView(ofType: AssistantTimelineRowContentView.self, in: cell.contentView) else {
                    return false
                }

                return cell.frame.height > initialHeight + 120
                    && row.debugMarkdownOverflowPoints < 1
                    && row.debugMarkdownRenderedOverlapPoints < 1
            }
        }

        let finalHeight = await MainActor.run {
            (wh.collectionView.cellForItem(at: indexPath) as? SafeSizingCell)?.frame.height ?? -1
        }

        #expect(
            reflowed,
            "Streaming structural markdown rebuild should invalidate cached assistant height (initial=\(initialHeight), final=\(finalHeight))"
        )
    }

    @Test func streamingOpenCodeBlockGrowthBustsCachedCollectionHeight() async throws {
        let wh = makeWindowedTimelineHarness(
            sessionId: "assistant-streaming-code-cache",
            useAnchoredCollectionView: true
        )
        let itemID = "assistant-streaming-code-cache"
        let timestamp = Date(timeIntervalSince1970: 0)
        let phase1 = """
        Streaming code-block growth fixture.

        ```swift
        let first = 1
        """
        let phase2 = """
        Streaming code-block growth fixture.

        ```swift
        let first = 1
        let second = 2
        let third = 3
        let fourth = 4
        let fifth = 5
        let sixth = 6
        let seventh = 7
        let eighth = 8
        let ninth = 9
        let tenth = 10
        """

        wh.applyItems(
            [
                .assistantMessage(id: itemID, text: phase1, timestamp: timestamp),
            ],
            isBusy: false,
            streamingID: itemID
        )

        let indexPath = IndexPath(item: 0, section: 0)
        let initialCell = try #require(try configuredTimelineCell(in: wh.collectionView, item: 0) as? SafeSizingCell)
        let initialHeight = initialCell.frame.height
        initialCell.cachedStreamingHeight = initialHeight
        initialCell.lastFullSizeComputeNs = DispatchTime.now().uptimeNanoseconds

        wh.applyItems(
            [
                .assistantMessage(id: itemID, text: phase2, timestamp: timestamp),
            ],
            isBusy: false,
            streamingID: itemID
        )

        let reflowed = await waitForTimelineCondition(timeoutMs: 500) {
            await MainActor.run {
                wh.collectionView.layoutIfNeeded()
                guard let cell = wh.collectionView.cellForItem(at: indexPath) as? SafeSizingCell,
                      let row = timelineFirstView(ofType: AssistantTimelineRowContentView.self, in: cell.contentView) else {
                    return false
                }

                return cell.frame.height > initialHeight + 80
                    && row.debugMarkdownOverflowPoints < 1
                    && row.debugMarkdownRenderedOverlapPoints < 1
            }
        }

        let finalHeight = await MainActor.run {
            (wh.collectionView.cellForItem(at: indexPath) as? SafeSizingCell)?.frame.height ?? -1
        }

        #expect(
            reflowed,
            "Streaming code block growth should invalidate cached assistant height (initial=\(initialHeight), final=\(finalHeight))"
        )
    }

    @Test func detachedStreamingAssistantHeadingStaysStableOnScreen() throws {
        let wh = makeWindowedTimelineHarness(
            sessionId: "assistant-md-stability",
            useAnchoredCollectionView: true
        )
        let streamingID = "assistant-stream"
        let timestamp = Date(timeIntervalSince1970: 0)

        var assistantText = """
        Preface paragraph one keeps the assistant row tall enough to scroll while reading.

        Preface paragraph two keeps the assistant row tall enough to scroll while reading.

        Preface paragraph three keeps the assistant row tall enough to scroll while reading.

        Preface paragraph four keeps the assistant row tall enough to scroll while reading.

        ---

        ## What to keep

        These notes start short.
        """

        func render() {
            wh.applyItems(
                [
                    .assistantMessage(id: streamingID, text: assistantText, timestamp: timestamp),
                ],
                isBusy: true,
                streamingID: streamingID
            )
        }

        render()

        let initialMaxOffsetY = max(
            -wh.collectionView.adjustedContentInset.top,
            wh.collectionView.contentSize.height - wh.collectionView.bounds.height + wh.collectionView.adjustedContentInset.bottom
        )
        wh.collectionView.contentOffset.y = initialMaxOffsetY
        wh.collectionView.layoutIfNeeded()

        let initialTextView = try #require(assistantMarkdownTextView(containing: "What to keep", in: wh.collectionView))
        let initialScreenY = try #require(screenY(of: "What to keep", in: initialTextView, relativeTo: wh.window))

        let desiredY: CGFloat = 220
        let delta = initialScreenY - desiredY
        let maxOffsetY = max(
            -wh.collectionView.adjustedContentInset.top,
            wh.collectionView.contentSize.height - wh.collectionView.bounds.height + wh.collectionView.adjustedContentInset.bottom
        )
        let targetOffsetY = min(
            max(wh.collectionView.contentOffset.y + delta, -wh.collectionView.adjustedContentInset.top),
            maxOffsetY
        )
        wh.collectionView.contentOffset.y = targetOffsetY
        wh.collectionView.layoutIfNeeded()

        let anchoredCV = try #require(wh.collectionView as? AnchoredCollectionView)
        anchoredCV.isDetachedFromBottom = true
        anchoredCV.captureDetachedAnchor()
        wh.scrollController.updateNearBottom(false)

        let pinnedTextView = try #require(assistantMarkdownTextView(containing: "What to keep", in: wh.collectionView))
        let pinnedScreenY = try #require(screenY(of: "What to keep", in: pinnedTextView, relativeTo: wh.window))

        for _ in 0..<6 {
            assistantText += " More streamed prose arrives underneath the heading and keeps wrapping across many lines so the paragraph grows substantially while the user is detached from bottom and reading this section."
            render()

            let textView = try #require(assistantMarkdownTextView(containing: "What to keep", in: wh.collectionView))
            let currentScreenY = try #require(screenY(of: "What to keep", in: textView, relativeTo: wh.window))
            #expect(
                abs(currentScreenY - pinnedScreenY) < 4,
                "Detached assistant heading drifted on screen (expected ~\(pinnedScreenY), got \(currentScreenY))"
            )
        }
    }

    @Test func baselineSafeTextViewPinsNonScrollableContentOffsetToTop() {
        let textView = BaselineSafeTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 140))
        textView.isScrollEnabled = false
        textView.font = AppFont.messageBody
        textView.text = Array(repeating: "A long wrapped line of text for streaming.", count: 40).joined(separator: " ")

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        textView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.heightAnchor.constraint(equalToConstant: 140),
        ])
        container.layoutIfNeeded()

        textView.contentOffset = CGPoint(x: 0, y: 42)
        textView.setNeedsLayout()
        textView.layoutIfNeeded()

        #expect(
            abs(textView.contentOffset.y + textView.adjustedContentInset.top) < 0.5,
            "BaselineSafeTextView should re-pin non-scrollable content to top, got y=\(textView.contentOffset.y)"
        )
    }

    @Test func veryLongAssistantMessageDoesNotClampBelowMarkdownHeight() {
        // Regression guard for the old 10k-point height cap that clipped tall
        // assistant rows (long review / write-up turns). The fixture only needs to
        // exceed that cap with margin (~26k pt rendered); the previous 1,100-section
        // version (~242k pt) added runtime and TextKit large-content measurement
        // noise without strengthening the guarantee.
        let sections = (1...120).map { index in
            """
            ## Section \(index)

            This is a long assistant paragraph intended to reproduce the tall-markdown bug. It wraps across multiple lines on iPhone-width layouts, includes **bold text**, `inline code`, and enough prose to force the rendered height far beyond ten thousand points.
            """
        }
        let markdown = sections.joined(separator: "\n\n")

        // Derive the row's internal markdown width from the row's own geometry so
        // this cannot silently rot if bubble padding changes.
        let rowWidth: CGFloat = 338
        let contentWidth = rowWidth
            - AssistantTimelineRowContentView.bubbleLeadingPadding
            - AssistantTimelineRowContentView.bubbleTrailingPadding

        let row = AssistantTimelineRowContentView(configuration: .init(
            text: markdown,
            isStreaming: false,
            canFork: false,
            onFork: nil
        ))
        let rowSize = fittedTimelineSize(for: row, width: rowWidth)

        // The standalone markdown must replicate the row's internal markdown
        // exactly — same width AND the avatar exclusion path (leadingHang) — or the
        // two measurements diverge (~6.5pt/section) and the comparison is meaningless.
        let markdownView = AssistantMarkdownContentView()
        markdownView.apply(configuration: .make(
            content: markdown,
            isStreaming: false,
            themeID: .dark
        ))
        markdownView.leadingHangClearance = AssistantTimelineRowContentView.avatarContentClearance
        markdownView.leadingHangHeight = AssistantTimelineRowContentView.avatarHangHeight
        let markdownSize = fittedTimelineSize(for: markdownView, width: contentWidth)

        #expect(markdownSize.height > 10_000, "Fixture must exceed the old 10k height cap, got \(markdownSize.height)")
        #expect(
            rowSize.height >= markdownSize.height + 8,
            "Assistant row height \(rowSize.height) clipped markdown content needing \(markdownSize.height)pt"
        )
    }

    /// Regression: UICollectionViewCell defaults to clipsToBounds=false.
    /// When the compositional layout uses estimated(100) heights and self-
    /// sizing hasn't resolved yet (e.g., during streaming when layoutIfNeeded
    /// is skipped), cell content overflows beyond the cell frame. Adjacent
    /// cells render their overflow on top of each other, producing the
    /// "scrambled text" visual artifact.
    ///
    /// Fix: SafeSizingCell must clip its contentView so overflow is hidden
    /// even when cells are briefly at estimated heights.
    @Test func timelineCellsClipContentBounds() throws {
        // Use the real production controller + data source so the test
        // exercises the actual SafeSizingCell (which is private to the
        // DataSource file). We set up the coordinator through the public
        // makeUIView → configureDataSource path.
        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            collectionViewLayout: layout
        )

        let controller = ChatTimelineCollectionHost.Controller()
        controller.configureDataSource(collectionView: collectionView)

        let items: [ChatItem] = [
            .assistantMessage(id: "a1", text: "Test content.", timestamp: Date()),
        ]

        let (orderedIDs, itemByID) = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast(items)
        controller.currentIDs = orderedIDs
        controller.currentItemByID = itemByID

        TimelineSnapshotApplier.applySnapshot(
            dataSource: controller.dataSource,
            nextIDs: orderedIDs,
            previousIDs: [],
            nextItemByID: itemByID,
            previousItemByID: [:],
            hiddenCount: 0,
            previousHiddenCount: 0,
            streamingAssistantID: nil,
            previousStreamingAssistantID: nil
        )
        collectionView.layoutIfNeeded()

        guard let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) else {
            Issue.record("No cell at index 0")
            return
        }

        // The cell's contentView must clip so that when cells are at
        // estimated heights (pre-self-sizing), content doesn't overflow
        // into adjacent cells.
        #expect(cell.contentView.clipsToBounds == true,
                "Cell contentView.clipsToBounds must be true to prevent overflow during estimated-height layout")
    }
}

@MainActor
private func visibleTextMinY(of needle: String, in textView: UITextView) -> CGFloat? {
    let fullText = timelineRenderedText(of: textView) as NSString
    let range = fullText.range(of: needle)
    guard range.location != NSNotFound else { return nil }

    textView.layoutManager.ensureLayout(for: textView.textContainer)
    let glyphRange = textView.layoutManager.glyphRange(
        forCharacterRange: range,
        actualCharacterRange: nil
    )
    let rect = textView.layoutManager.boundingRect(
        forGlyphRange: glyphRange,
        in: textView.textContainer
    )

    return rect.minY + textView.textContainerInset.top - textView.contentOffset.y
}

@MainActor
private func screenY(of needle: String, in textView: UITextView, relativeTo view: UIView) -> CGFloat? {
    guard let localY = visibleTextMinY(of: needle, in: textView) else { return nil }
    return textView.convert(CGPoint(x: 0, y: localY), to: view).y
}

@MainActor
private func assistantMarkdownTextView(containing needle: String, in root: UIView) -> UITextView? {
    if let collectionView = root as? UICollectionView {
        for cell in collectionView.visibleCells {
            if let textView = assistantMarkdownTextView(containing: needle, in: cell.contentView) {
                return textView
            }
        }
    }

    if let assistantView = root as? AssistantTimelineRowContentView {
        return timelineAllTextViews(in: assistantView).first {
            timelineRenderedText(of: $0).contains(needle)
        }
    }

    for child in root.subviews {
        if let textView = assistantMarkdownTextView(containing: needle, in: child) {
            return textView
        }
    }

    return nil
}
