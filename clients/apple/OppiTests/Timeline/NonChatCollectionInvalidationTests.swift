import Testing
import UIKit
@testable import Oppi

@Suite("Non-chat collection layout invalidation")
@MainActor
struct NonChatCollectionInvalidationTests {
    @Test("forced invalidation preserves a plain collection view viewport")
    func forcedInvalidationPreservesPlainCollectionViewport() {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 393, height: 50)
        layout.minimumLineSpacing = 0
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 800),
            collectionViewLayout: layout
        )
        let dataSource = PlainCollectionDataSource()
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        collectionView.dataSource = dataSource

        let host = UIViewController()
        host.view.addSubview(collectionView)
        let window = UIWindow(frame: collectionView.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        collectionView.reloadData()
        host.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        #expect(collectionView.contentSize.height > collectionView.bounds.height + 1_000)

        let readingOffsetY: CGFloat = 600
        collectionView.contentOffset.y = readingOffsetY
        let source = UIView(frame: CGRect(x: 0, y: readingOffsetY + 100, width: 40, height: 40))
        collectionView.addSubview(source)

        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
            startingAt: source
        )

        #expect(
            abs(collectionView.contentOffset.y - readingOffsetY) < 1,
            "a non-chat collection view was misclassified as bottom-attached"
        )
    }

    @Test("timeline Mermaid keeps its small width-jitter tolerance")
    func timelineMermaidDoesNotRerasterForFourPointJitter() {
        let view = NativeMermaidBlockView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        view.applyAsDiagramSync(
            code: "graph TD\n  A[Start] --> B[Done]",
            palette: ThemeID.dark.palette
        )
        view.layoutIfNeeded()
        let rendersBeforeJitter = view.debugRenderCountForTesting
        #expect(rendersBeforeJitter >= 1)

        view.frame.size.width = 364
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(
            view.debugRenderCountForTesting == rendersBeforeJitter,
            "ordinary timeline width jitter must not inherit reader exact-width rerastering"
        )
    }

    @Test(
        "static Mermaid uses canonical width without a display-time reflow",
        .timeLimit(.minutes(1))
    )
    func staticMermaidWidthSettlementPreservesReaderViewport() async throws {
        let gallery = try String(
            contentsOf: fixtureURL("mermaid-rendering-gallery.md"),
            encoding: .utf8
        )
        let content = try staticReaderFixture(usingMermaidFrom: gallery)

        for width: CGFloat in [375, 393, 430] {
            try await assertStaticMermaidSettlementPreservesViewport(
                content: content,
                width: width
            )
        }
    }

    private func assertStaticMermaidSettlementPreservesViewport(
        content: String,
        width: CGFloat
    ) async throws {
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            ToolTimelineRowPresentationHelpers.forcedEnclosingLayoutInvalidationHookForTesting = nil
            window.isHidden = true
        }

        body.layoutIfNeeded()
        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collectionView.layoutIfNeeded()
        await drainMainQueue()
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let mermaidItem = try #require(body.debugRenderedSegmentsForTesting.firstIndex { segment in
            if case .mermaidDiagram = segment { return true }
            return false
        })
        let mermaidFrame = try #require(
            collectionView.collectionViewLayout.layoutAttributesForItem(
                at: IndexPath(item: mermaidItem, section: 0)
            )?.frame
        )
        let minimumY = -collectionView.adjustedContentInset.top
        let bottomY = max(
            minimumY,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.contentOffset.y = bottomY
        collectionView.layoutIfNeeded()

        var forcedInvalidationCount = 0
        ToolTimelineRowPresentationHelpers.forcedEnclosingLayoutInvalidationHookForTesting = { target in
            guard target === collectionView else { return }
            forcedInvalidationCount += 1
        }

        let readingOffsetY = min(
            bottomY - 120,
            max(minimumY, mermaidFrame.minY - 100)
        )
        #expect(bottomY - readingOffsetY > 100)
        collectionView.contentOffset.y = readingOffsetY
        collectionView.layoutIfNeeded()
        let mermaidView = try #require(
            timelineFirstView(ofType: NativeMermaidBlockView.self, in: collectionView)
        )

        await drainMainQueue()
        body.debugLayoutVisibleMarkdownCellsForTesting()
        #expect(
            abs((mermaidView.debugRasterWidthForTesting ?? 0) - (width - 24)) < 0.5,
            "width \(width) did not use the canonical reader width"
        )
        #expect(mermaidView.debugRenderCountForTesting == 1)
        #expect(
            forcedInvalidationCount == 0,
            "canonical Mermaid display must not trigger a second forced reflow"
        )
        #expect(
            abs(collectionView.contentOffset.y - readingOffsetY) < 1,
            "width \(width) Mermaid settlement jumped the static reader viewport"
        )
    }

    private func staticReaderFixture(usingMermaidFrom gallery: String) throws -> String {
        let opening = "```mermaid\n"
        let openingRange = try #require(gallery.range(of: opening))
        let codeStart = openingRange.upperBound
        let closingRange = try #require(gallery.range(of: "\n```", range: codeStart..<gallery.endIndex))
        let code = gallery[codeStart..<closingRange.lowerBound]
        let before = (0..<50).map {
            "Reader paragraph \($0) above the real gallery diagram, long enough to wrap on a phone."
        }.joined(separator: "\n\n")
        let after = (0..<50).map {
            "Reader paragraph \($0) below the real gallery diagram, long enough to wrap on a phone."
        }.joined(separator: "\n\n")
        return "# Static gallery width fixture\n\n\(before)\n\n```mermaid\n\(code)\n```\n\n\(after)"
    }

    private func fixtureURL(_ fileName: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fileName)")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

private final class PlainCollectionDataSource: NSObject, UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        100
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
    }
}
