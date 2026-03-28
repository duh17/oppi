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
        markdownView.apply(configuration: .init(
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
        markdownView.apply(configuration: .init(
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
