import Testing
import UIKit
@testable import Oppi

@Suite("Markdown table column layout")
struct MarkdownTableColumnLayoutTests {
    @Test func twoColumnTablesWrapWhenNaturalWidthExceedsBudget() {
        let shouldWrap = MarkdownTableColumnLayout.shouldWrap(
            columnCount: 2,
            naturalContentWidth: 420,
            availableWidth: 320
        )
        #expect(shouldWrap)
    }

    @Test func twoColumnTablesWrapWhenOnlyChromeOverflowsAvailableWidth() {
        // Bare text may fit the content budget, but full single-line width with
        // separators/padding still exceeds the card — that must wrap.
        let shouldWrap = MarkdownTableColumnLayout.shouldWrap(
            columnCount: 2,
            naturalContentWidth: 340,
            availableWidth: 320
        )
        #expect(shouldWrap)
    }

    @Test func twoColumnTablesStaySingleLineWhenTheyAlreadyFit() {
        let shouldWrap = MarkdownTableColumnLayout.shouldWrap(
            columnCount: 2,
            naturalContentWidth: 180,
            availableWidth: 320
        )
        #expect(!shouldWrap)
    }

    @Test func wideColumnCountDoesNotEnterWrapMode() {
        let shouldWrap = MarkdownTableColumnLayout.shouldWrap(
            columnCount: 5,
            naturalContentWidth: 900,
            availableWidth: 320
        )
        #expect(!shouldWrap)
    }

    @Test func allocateColumnWidthsPreservesNaturalWhenUnderBudget() {
        let widths = MarkdownTableColumnLayout.allocateColumnWidths(
            naturalWidths: [80, 120],
            availableContentWidth: 260
        )
        #expect(widths == [80, 120])
    }

    @Test func allocateColumnWidthsShrinksProportionallyIntoBudget() {
        let widths = MarkdownTableColumnLayout.allocateColumnWidths(
            naturalWidths: [200, 200],
            availableContentWidth: 200
        )
        #expect(widths.count == 2)
        #expect(widths.reduce(0, +) == 200)
        #expect(widths.allSatisfy { $0 >= MarkdownTableColumnLayout.minimumWrappedColumnWidth || $0 == 100 })
        #expect(abs(widths[0] - widths[1]) <= 1)
    }
}

@Suite("Native table wrap-to-fit")
@MainActor
struct NativeTableWrapToFitTests {
    @Test func moderateTwoColumnTableFitsWithoutHorizontalScroll() {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        tableView.apply(
            headers: [[.text("Feature")], [.text("Notes")]],
            rows: [
                [
                    [.text("Streaming markdown")],
                    [.text("Incremental tail parse keeps first paint cheap on long turns.")],
                ],
                [
                    [.text("Tables")],
                    [.text("Two-column tables should wrap to the bubble instead of forcing sideways scroll.")],
                ],
            ],
            palette: ThemeRuntimeState.currentPalette()
        )

        container.setNeedsLayout()
        container.layoutIfNeeded()

        let horizontalScroll = timelineAllScrollViews(in: tableView).first { !($0 is UITextView) }
        #expect(horizontalScroll?.isHidden == true, "Wrap mode should hide the horizontal scroller")
        if let scroll = horizontalScroll {
            #expect(
                scroll.contentSize.width <= scroll.bounds.width + 0.5
                    || scroll.isHidden,
                "Two-column table should fit without requiring horizontal scroll"
            )
        }
        #expect(tableView.bounds.width <= 320.5)
    }

    @Test func wrappedHeightIsKnownDuringSelfSizingBeforeFirstLayout() {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        tableView.apply(
            headers: [[.text("Practical takeaway")], [.text("Detail")]],
            rows: [
                [
                    [.text("A label that must wrap")],
                    [.text("A long value that must wrap onto multiple lines to fit the phone-width table card.")],
                ],
                [
                    [.text("Another row")],
                    [.text("More detail that must remain below the first row instead of painting over it.")],
                ],
            ],
            palette: ThemeRuntimeState.currentPalette()
        )

        let firstPass = tableView.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        container.setNeedsLayout()
        container.layoutIfNeeded()

        let settled = tableView.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        #expect(
            firstPass.height >= settled.height - 1,
            "Self-sizing measured the wrapped table too short before layout (first=\(firstPass.height), settled=\(settled.height))"
        )
    }

    @Test func wrappedCellsExposeTheirCompleteMultilineHeight() throws {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        let detail = "Long values must wrap inside the table instead of painting over the content below."

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        tableView.apply(
            headers: [[.text("Topic")], [.text("Detail")]],
            rows: [
                [[.text("Why")], [.text(detail)]],
                [[.text("Result")], [.text("The following heading must remain below the complete table card after cell reuse.")]],
            ],
            palette: ThemeRuntimeState.currentPalette()
        )
        container.layoutIfNeeded()

        let matchingCells = timelineAllTextViews(in: tableView).filter {
            !$0.isHidden && timelineRenderedText(of: $0).contains(detail)
        }
        let detailCell = try #require(matchingCells.first)
        detailCell.layoutManager.ensureLayout(for: detailCell.textContainer)
        var lineCount = 0
        detailCell.layoutManager.enumerateLineFragments(
            forGlyphRange: detailCell.layoutManager.glyphRange(for: detailCell.textContainer)
        ) { _, _, _, _, _ in
            lineCount += 1
        }
        print("wrapped detail bounds=\(detailCell.bounds) contentSize=\(detailCell.contentSize) fit=\(detailCell.sizeThatFits(CGSize(width: detailCell.bounds.width, height: .greatestFiniteMagnitude))) textContainer=\(detailCell.textContainer.size) lineCount=\(lineCount)")
        #expect(lineCount >= 2, "Long table detail should wrap across multiple lines, got \(lineCount)")
        #expect(
            detailCell.contentSize.height <= detailCell.bounds.height + 1,
            "Wrapped table cell content is clipped: content=\(detailCell.contentSize.height), bounds=\(detailCell.bounds.height)"
        )
        #expect(detailCell.bounds.height > 40, "Long table detail should occupy multiple lines")
    }

    @Test func manyColumnTableKeepsHorizontalScrollFallback() {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        tableView.apply(
            headers: (0..<5).map { [.text("Col\($0)")] },
            rows: [
                (0..<5).map { [.text(String(repeating: "value\($0)-", count: 4))] },
            ],
            palette: ThemeRuntimeState.currentPalette()
        )

        container.setNeedsLayout()
        container.layoutIfNeeded()

        let horizontalScroll = timelineAllScrollViews(in: tableView).first { !($0 is UITextView) }
        #expect(horizontalScroll != nil)
        #expect(horizontalScroll?.isHidden == false)
        #expect((horizontalScroll?.contentSize.width ?? 0) > (horizontalScroll?.bounds.width ?? 0) + 1)
    }
}
