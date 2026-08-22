import Foundation
import Testing
import UIKit
@testable import Oppi

/// Experiment 0: mixed-document correctness oracle for the full-screen reader.
///
/// Same UIKit shape as `OpenHostMarkdownReportCrashTests`: load a fixture,
/// build `NativeFullScreenMarkdownBody`, layout, and force every item to
/// measure. Hang, crash, overflow, or raw-source fallback is a red result.
@Suite("Full-screen markdown stress corpus")
@MainActor
struct FullScreenMarkdownStressCorpusTests {
    private static let deferredRenderByteThreshold = 200 * 1024
    private static let crashedReportByteCount = 12_487
    private static let mixedItemCountBand = 20...200

    @Test("mixed stress fixture covers the corpus and stays under the deferred-render threshold")
    func mixedStressFixtureCoversCorpusUnderDeferredRenderThreshold() throws {
        let content = try mixedStressFixture()
        #expect(content.utf8.count < Self.deferredRenderByteThreshold)
        #expect(content.utf8.count > 8_000, "fixture must be tall enough that virtualization matters")

        for marker in [
            "# Mixed Markdown Stress Corpus",
            "**bold**",
            "`inline code`",
            "[plain link](https://example.invalid/docs)",
            "synthetic-list-fence",
            "synthetic-ordered-list-fence",
            "https://example.invalid/wrap",
            "synthetic-code-fence",
            "<br/>",
            "sequenceDiagram",
            "```latex",
            "$$",
            "$a^2 + b^2 = c^2$",
            "[[notes/synthetic-corpus.md|corpus note]]",
            "[[/tmp/oppi-markdown-stress.log]]",
            "[[Sources/App.swift#L12-L18|focused code]]",
            "fixtures/synthetic-diagram.png",
            "https://example.invalid/remote-chart.png",
            "<span>inline html</span>",
            "<div>",
            "STRESS_CORPUS_PARCEL_20",
        ] {
            #expect(content.contains(marker), "fixture missing required case: \(marker)")
        }

        let blocks = parseCommonMark(content)
        let segments = FlatSegment.build(
            from: blocks,
            themeID: .dark,
            workspaceID: "ws-markdown-stress",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceDirectory: "docs"
        )
        #expect(!blocks.isEmpty)
        #expect(Self.mixedItemCountBand.contains(segments.count), "segment count \(segments.count) left the oracle band")

        var mermaid = 0
        var latex = 0
        var tables = 0
        var images = 0
        var code = 0
        var breaks = 0
        for segment in segments {
            switch segment {
            case .mermaidDiagram:
                mermaid += 1
            case .latexBlock:
                latex += 1
            case .table:
                tables += 1
            case .image:
                images += 1
            case .codeBlock:
                code += 1
            case .thematicBreak:
                breaks += 1
            case .text:
                break
            }
        }
        #expect(mermaid == 2, "expected flowchart + sequence diagram, got \(mermaid)")
        #expect(latex >= 2, "expected latex fence + display math, got \(latex)")
        #expect(tables == 1)
        #expect(images == 2, "expected relative + remote image segments, got \(images)")
        // Nested list fences are required in the source; CommonMark may keep
        // only the standalone python fence as a top-level code segment.
        #expect(code >= 1, "expected the standalone python fence, got \(code)")
        #expect(breaks >= 10, "expected enough thematic breaks for virtualization, got \(breaks)")
    }

    @Test(
        "document reader lays out the mixed stress fixture without hanging or falling back to raw source",
        .timeLimit(.minutes(1))
    )
    func documentReaderLaysOutMixedStressFixtureWithoutHanging() async throws {
        ToolTimelineRowPresentationHelpers.debugResetNestedLayoutInvalidationCountForTesting()
        let content = try mixedStressFixture()
        let pngData = try #require(Self.tinyPNGData())
        let imageProbe = WorkspaceImageFetchProbe()

        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            workspaceID: "ws-markdown-stress",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/mixed-markdown-stress-corpus.md",
            fetchWorkspaceFile: { workspaceID, path in
                await imageProbe.record(workspaceID: workspaceID, path: path)
                return pngData
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collectionView.layoutIfNeeded()

        // Force every segment to measure. Visible-only layout can hide a
        // hang or overflow that happens while self-sizing later cells.
        let itemCount = collectionView.numberOfItems(inSection: 0)
        for item in 0..<itemCount {
            let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0))
            let frame = try #require(attributes?.frame, "missing layout attributes for item \(item)")
            #expect(frame.width.isFinite && frame.height.isFinite, "item \(item) laid out with a non-finite frame")
            #expect(frame.height > 0, "item \(item) collapsed to zero height")
            #expect(frame.maxX <= collectionView.bounds.width + 24, "item \(item) overflowed the reader width")
        }
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        if collectionView.contentSize.height > collectionView.bounds.height {
            collectionView.contentOffset.y = collectionView.contentSize.height - collectionView.bounds.height
            collectionView.layoutIfNeeded()
        }

        #expect(Self.mixedItemCountBand.contains(itemCount), "reader item count \(itemCount) left the oracle band")
        #expect(collectionView.contentSize.width.isFinite)
        #expect(collectionView.contentSize.height.isFinite)
        #expect(collectionView.contentSize.height > 844, "reader failed to lay out the mixed document")
        #expect(collectionView.contentSize.height < 100_000, "reader content height exploded")
        #expect(itemCount > collectionView.visibleCells.count, "fixture was not tall enough for virtualization")
        // Content, mermaid images, wiki/table links, and remote-image gating
        // live on the visible-cell tests so this hang check does not force
        // applying every off-screen view before first paint.
        let fetchedPaths = await imageProbe.paths
        #expect(fetchedPaths.allSatisfy { !$0.contains("example.invalid") })
        print("READER_METRIC item_count=\(itemCount)")
        print("READER_METRIC content_height=\(Int(collectionView.contentSize.height.rounded()))")
        #expect(
            ToolTimelineRowPresentationHelpers.debugNestedLayoutInvalidationCountForTesting < 50,
            "apply-time nested layout invalidations exploded"
        )
    }

    @Test("first layout applies only the visible window, not the whole document")
    func firstLayoutAppliesOnlyTheVisibleWindow() throws {
        let content = try mixedStressFixture()
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            workspaceID: "ws-markdown-stress",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/mixed-markdown-stress-corpus.md"
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        body.layoutIfNeeded()
        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collectionView.layoutIfNeeded()
        #expect(body.debugRenderedSegmentCountForTesting > body.debugVisibleCellCountForTesting)
        #expect(body.debugAppliedItemCountForTesting > 0)
        #expect(
            body.debugAppliedItemCountForTesting < body.debugRenderedSegmentCountForTesting,
            "first layout applied the whole document (\(body.debugAppliedItemCountForTesting)/\(body.debugRenderedSegmentCountForTesting))"
        )
        print("READER_METRIC applied_count=\(body.debugAppliedItemCountForTesting)")
        print("READER_METRIC item_count=\(body.debugRenderedSegmentCountForTesting)")
        print("READER_METRIC visible_count=\(body.debugVisibleCellCountForTesting)")
        print("READER_METRIC content_height=\(Int(collectionView.contentSize.height.rounded()))")
    }

    @Test(
        "visible cells show real renderers after scrolling each mixed-corpus segment into view",
        .timeLimit(.minutes(1))
    )
    func visibleCellsShowRealRenderersForEachMixedCorpusSegment() async throws {
        let content = try mixedStressFixture()
        let pngData = try #require(Self.tinyPNGData())
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            workspaceID: "ws-markdown-stress",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/mixed-markdown-stress-corpus.md",
            fetchWorkspaceFile: { _, _ in pngData }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        body.layoutIfNeeded()
        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collectionView.layoutIfNeeded()

        let bareParkedLabels = body.debugParkedHostForTesting.subviews.filter { view in
            view is UILabel && view.superview === body.debugParkedHostForTesting
        }
        #expect(
            bareParkedLabels.isEmpty,
            "off-screen text must stay as real markdown views, not UILabel snapshots"
        )

        let segments = body.debugRenderedSegmentsForTesting
        #expect(Self.mixedItemCountBand.contains(segments.count))

        var seenMermaid = 0
        var seenLatex = 0
        var seenTable = 0
        var seenImage = 0
        var seenCode = 0
        var seenText = 0
        for (item, segment) in segments.enumerated() {
            body.debugScrollItemIntoViewForTesting(item)
            let visible = collectionView.visibleCells
            #expect(!visible.isEmpty, "item \(item) produced no visible cell")
            switch segment {
            case .text(let attributed):
                let needle = String(attributed.characters)
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                let visibleTextViews = visible.flatMap { timelineAllTextViews(in: $0) }
                let joined = visibleTextViews.map { timelineRenderedText(of: $0) }.joined(separator: "\n")
                if !needle.isEmpty {
                    #expect(
                        joined.contains(needle),
                        "visible text cell \(item) is not a real markdown text view for \(needle.prefix(40))"
                    )
                }
                seenText += 1
            case .codeBlock(_, let code):
                #expect(
                    visible.contains { timelineFirstView(ofType: NativeCodeBlockView.self, in: $0) != nil },
                    "code item \(item) not visible as NativeCodeBlockView"
                )
                let codeText = visible.flatMap { timelineAllTextRenderViews(in: $0) }
                    .map { timelineRenderedText(of: $0) }
                    .joined(separator: "\n")
                let marker = code.split(whereSeparator: \.isNewline).map(String.init).first { !$0.isEmpty }
                if let marker {
                    #expect(codeText.contains(marker), "visible code item \(item) missing \(marker)")
                }
                seenCode += 1
            case .table:
                #expect(
                    visible.contains { timelineFirstView(ofType: NativeTableBlockView.self, in: $0) != nil },
                    "table item \(item) not visible as NativeTableBlockView"
                )
                seenTable += 1
            case .image:
                #expect(
                    visible.contains { timelineFirstView(ofType: NativeMarkdownImageView.self, in: $0) != nil },
                    "image item \(item) not visible as NativeMarkdownImageView"
                )
                seenImage += 1
            case .mermaidDiagram:
                let mermaid = visible.compactMap { timelineFirstView(ofType: NativeMermaidBlockView.self, in: $0) }
                #expect(!mermaid.isEmpty, "mermaid item \(item) not visible")
                for view in mermaid {
                    let imageView = timelineAllImageViews(in: view).first { !$0.isHidden }
                    #expect(imageView?.image != nil, "visible mermaid item \(item) has no diagram image")
                }
                seenMermaid += 1
            case .latexBlock:
                let latex = visible.compactMap { timelineFirstView(ofType: NativeLatexBlockView.self, in: $0) }
                #expect(!latex.isEmpty, "latex item \(item) not visible")
                for view in latex {
                    let hasFormula = view.debugIsShowingFormulaForTesting && view.debugFormulaImageForTesting != nil
                    let fallbackText = timelineAllTextRenderViews(in: view)
                        .map { timelineRenderedText(of: $0) }
                        .joined()
                    #expect(
                        hasFormula || !fallbackText.isEmpty,
                        "visible latex item \(item) has neither a formula image nor a code fallback"
                    )
                }
                seenLatex += 1
            case .thematicBreak:
                break
            }
        }
        #expect(seenMermaid == 2)
        #expect(seenLatex >= 2)
        #expect(seenTable == 1)
        #expect(seenImage == 2)
        #expect(seenCode >= 1)
        #expect(seenText >= 1)
    }

    @Test(
        "visible wiki, table, latex, mermaid, and remote image keep interactive contracts",
        .timeLimit(.minutes(1))
    )
    func visibleInteractiveContractsStayOnRealRenderers() async throws {
        let content = try mixedStressFixture()
        let pngData = try #require(Self.tinyPNGData())
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            workspaceID: "ws-markdown-stress",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/mixed-markdown-stress-corpus.md",
            fetchWorkspaceFile: { _, _ in pngData }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        body.layoutIfNeeded()
        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collectionView.layoutIfNeeded()

        let segments = body.debugRenderedSegmentsForTesting
        func scrollToFirst(where match: (FlatSegment) -> Bool) {
            guard let item = segments.firstIndex(where: match) else { return }
            body.debugScrollItemIntoViewForTesting(item)
        }

        scrollToFirst { segment in
            if case .text(let attributed) = segment {
                return String(attributed.characters).contains("corpus note")
            }
            return false
        }
        let wikiViews = collectionView.visibleCells.flatMap { timelineAllTextViews(in: $0) }
        let wikiHasLink = wikiViews.contains { textView in
            let text = textView.attributedText ?? NSAttributedString()
            var found = false
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                guard value != nil else { return }
                found = true
                stop.pointee = true
            }
            return found && timelineRenderedText(of: textView).contains("corpus note")
        }
        #expect(wikiHasLink, "visible wiki line has no tappable .link on corpus note")

        scrollToFirst { segment in
            if case .table = segment { return true }
            return false
        }
        let table = collectionView.visibleCells.compactMap {
            timelineFirstView(ofType: NativeTableBlockView.self, in: $0)
        }.first
        #expect(table != nil)
        let tableText = timelineAllTextRenderViews(in: table ?? UIView())
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")
        #expect(tableText.contains("Alpha specimen") || tableText.contains("example.invalid"))
        let tableHasLink = timelineAllTextViews(in: table ?? UIView()).contains { textView in
            let text = textView.attributedText ?? NSAttributedString()
            var found = false
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                guard value != nil else { return }
                found = true
                stop.pointee = true
            }
            return found
        }
        #expect(tableHasLink, "visible table has no tappable links")

        scrollToFirst { segment in
            if case .latexBlock = segment { return true }
            return false
        }
        let latex = collectionView.visibleCells.compactMap {
            timelineFirstView(ofType: NativeLatexBlockView.self, in: $0)
        }
        #expect(!latex.isEmpty)
        #expect(latex.contains { $0.debugIsShowingFormulaForTesting && $0.debugFormulaImageForTesting != nil
            || $0.accessibilityIdentifier == "latex.formula.open" })

        scrollToFirst { segment in
            if case .mermaidDiagram = segment { return true }
            return false
        }
        let mermaid = collectionView.visibleCells.compactMap {
            timelineFirstView(ofType: NativeMermaidBlockView.self, in: $0)
        }
        #expect(mermaid.contains { $0.debugIsShowingDiagramForTesting })

        scrollToFirst { segment in
            if case .image(_, let url) = segment {
                return url.host?.contains("example.invalid") == true
            }
            return false
        }
        let remotePromptVisible = collectionView.visibleCells.contains { cell in
            timelineAllViews(in: cell).contains { view in
                if let button = view as? UIButton, button.configuration?.title == "Load remote image" {
                    return !button.isHidden
                }
                return false
            }
        }
        #expect(remotePromptVisible, "remote image prompt is not on the visible image cell")
    }

    @Test(
        "document reader lays out the crashed host report without hanging",
        .timeLimit(.minutes(1))
    )
    func documentReaderLaysOutCrashedHostReportWithoutHanging() throws {
        ToolTimelineRowPresentationHelpers.debugResetNestedLayoutInvalidationCountForTesting()
        let url = fixtureURL("2026-08-22-anthropic-s1-report.md")
        let content = try String(contentsOf: url, encoding: .utf8)
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            sourceFilePath: "report.md"
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        body.layoutIfNeeded()
        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collectionView.layoutIfNeeded()
        let itemCount = collectionView.numberOfItems(inSection: 0)
        #expect(itemCount > 0)
        for item in 0..<itemCount {
            let frame = try #require(
                collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame
            )
            #expect(frame.height.isFinite && frame.height > 0)
        }
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        #expect(collectionView.contentSize.height > 844)
        #expect(collectionView.contentSize.height < 100_000)
        body.debugScrollItemIntoViewForTesting(0)
        let visibleText = collectionView.visibleCells
            .flatMap { timelineAllTextViews(in: $0) }
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")
        #expect(visibleText.contains("Anthropic S-1"))
        #expect(!visibleText.contains("# Anthropic S-1"))
        #expect(ToolTimelineRowPresentationHelpers.debugNestedLayoutInvalidationCountForTesting < 50)
    }

    @Test("crashed host report fixture is byte-identical and parses into a finite document")
    func crashedHostReportFixtureParsesIntoFiniteDocument() throws {
        let url = fixtureURL("2026-08-22-anthropic-s1-report.md")
        let data = try Data(contentsOf: url)
        #expect(
            data.count == Self.crashedReportByteCount,
            "fixture must stay byte-identical to the crashed report (\(data.count) bytes)"
        )
        let content = try #require(String(data: data, encoding: .utf8))
        let blocks = parseCommonMark(content)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(!blocks.isEmpty)
        #expect(!segments.isEmpty)
        #expect(segments.count < 400)
    }

    private func mixedStressFixture() throws -> String {
        let url = fixtureURL("mixed-markdown-stress-corpus.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixtureURL(_ fileName: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fileName)")
    }

    private static func tinyPNGData() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.pngData()
    }
}

private actor WorkspaceImageFetchProbe {
    private(set) var records: [(workspaceID: String, path: String)] = []

    var paths: [String] { records.map(\.path) }

    func record(workspaceID: String, path: String) {
        records.append((workspaceID, path))
    }
}
