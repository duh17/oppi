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
            themeID: .dark
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
                text: text, isStreaming: false, canFork: false, onFork: nil, themeID: .dark
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
}
