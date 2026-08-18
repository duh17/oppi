import Testing
import UIKit
@testable import Oppi

@Suite("Markdown table column layout")
struct MarkdownTableColumnLayoutTests {
    @Test func narrowerColumnStaysAtNaturalWidthWhileNeighborClamps() {
        let maxReadable = MarkdownTableColumnLayout.maxReadableColumnWidth
        let widths = MarkdownTableColumnLayout.clampedColumnWidths(
            naturalWidths: [64, 900]
        )

        #expect(widths == [64, maxReadable])
        #expect(64 < maxReadable)
        #expect(900 > maxReadable)
    }

    @Test func needsGridModeOnlyWhenAnyColumnClamps() {
        let maxReadable = MarkdownTableColumnLayout.maxReadableColumnWidth

        #expect(!MarkdownTableColumnLayout.needsGridMode(naturalWidths: [64, 80, 120]))
        #expect(MarkdownTableColumnLayout.needsGridMode(naturalWidths: [64, 900]))
        #expect(
            MarkdownTableColumnLayout.needsGridMode(
                naturalWidths: [10, 20, 30, 40, 900]
            ),
            "Five-column tables still enter grid mode when any column clamps"
        )
        #expect(
            !MarkdownTableColumnLayout.needsGridMode(
                naturalWidths: [10, 20, 30, 40, 50]
            ),
            "Column count alone must not force grid mode"
        )
        #expect(
            !MarkdownTableColumnLayout.needsGridMode(
                naturalWidths: [maxReadable, 64]
            )
        )
        #expect(
            MarkdownTableColumnLayout.needsGridMode(
                naturalWidths: [maxReadable + 0.5, 64]
            )
        )
    }
}

@Suite("Native table wrap-to-fit")
@MainActor
struct NativeTableWrapToFitTests {
    @Test func shortColumnStaysSingleLineAndLongColumnClamps() {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        let longNotes = "Incremental tail parse keeps first paint cheap on long turns."
        tableView.apply(
            headers: [[.text("Feature")], [.text("Notes")]],
            rows: [
                [
                    [.text("Streaming markdown")],
                    [.text(longNotes)],
                ],
                [
                    [.text("Tables")],
                    [.text("Two-column tables wrap the long column at the readable clamp.")],
                ],
            ],
            palette: ThemeRuntimeState.currentPalette()
        )

        container.setNeedsLayout()
        container.layoutIfNeeded()

        let horizontalScroll = timelineAllScrollViews(in: tableView).first { !($0 is UITextView) }
        #expect(horizontalScroll != nil, "Grid tables stay hosted in the horizontal scroller")
        #expect(horizontalScroll?.isHidden == false)

        let shortCells = visibleTableCells(in: tableView).filter { cell in
            let text = timelineRenderedText(of: cell)
            return text == "Feature" || text == "Tables" || text == "Streaming markdown"
        }
        #expect(!shortCells.isEmpty)
        for cell in shortCells {
            #expect(
                cellIsSingleLine(cell),
                "Short cell wrapped unexpectedly: \(timelineRenderedText(of: cell))"
            )
        }

        let longCells = visibleTableCells(in: tableView).filter {
            timelineRenderedText(of: $0).contains(longNotes)
        }
        #expect(!longCells.isEmpty)
        for cell in longCells {
            #expect(!cellIsSingleLine(cell), "Long cell should wrap at the readable clamp")
            #expect(
                abs(cell.bounds.width - MarkdownTableColumnLayout.maxReadableColumnWidth) <= 1,
                "Long column should wrap at maxReadable, got \(cell.bounds.width)"
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
        #expect(
            firstPass.height < 500 && settled.height < 500,
            "Grid table height exploded (first=\(firstPass.height), settled=\(settled.height))"
        )
        #expect(
            settled.height > 80,
            "Grid table collapsed (settled=\(settled.height))"
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

        let matchingCells = visibleTableCells(in: tableView).filter {
            timelineRenderedText(of: $0).contains(detail)
        }
        let detailCell = try #require(matchingCells.first)
        let widthAwareHeight = ceil(
            detailCell.sizeThatFits(
                CGSize(width: detailCell.bounds.width, height: .greatestFiniteMagnitude)
            ).height
        )
        #expect(
            widthAwareHeight > 40,
            "Long table detail should require multiple rendered lines (fit=\(widthAwareHeight))"
        )
        #expect(
            detailCell.bounds.height + 1 >= widthAwareHeight,
            "Wrapped table cell is clipped: rendered=\(detailCell.bounds.height), required=\(widthAwareHeight)"
        )
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

    @Test func relayoutAcrossPhoneWidthsKeepsCellHeightsAndNonOverlappingRows() {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 800))
        container.addSubview(tableView)
        let widthConstraint = tableView.widthAnchor.constraint(equalToConstant: 375)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
            widthConstraint,
        ])

        tableView.apply(
            headers: [[.text("Time")], [.text("Notes")]],
            rows: [
                [
                    [.text("01:46:42")],
                    [.text("A long value that must wrap onto multiple lines instead of overlapping the next row.")],
                ],
                [
                    [.text("02:10:05")],
                    [.text("The following row must stay below the complete first row after width changes.")],
                ],
            ],
            palette: ThemeRuntimeState.currentPalette()
        )

        func assertHealthyLayout(at width: CGFloat) {
            container.frame.size.width = width
            widthConstraint.constant = width
            container.setNeedsLayout()
            container.layoutIfNeeded()

            let cells = visibleTableCells(in: tableView)
            #expect(!cells.isEmpty, "Expected visible table cells at width \(width)")
            for cell in cells {
                let required = ceil(
                    cell.sizeThatFits(
                        CGSize(width: cell.bounds.width, height: .greatestFiniteMagnitude)
                    ).height
                )
                #expect(
                    cell.bounds.height + 1 >= required,
                    "Cell clipped at width \(width): rendered=\(cell.bounds.height), required=\(required), text=\(timelineRenderedText(of: cell))"
                )
            }

            let rows = wrapRows(in: tableView)
            #expect(rows.count >= 2, "Expected header and body rows at width \(width)")
            for index in 0..<(rows.count - 1) {
                let current = rows[index].convert(rows[index].bounds, to: tableView)
                let next = rows[index + 1].convert(rows[index + 1].bounds, to: tableView)
                #expect(
                    current.maxY <= next.minY + 0.5,
                    "Rows overlap at width \(width): \(current) vs \(next)"
                )
            }
        }

        assertHealthyLayout(at: 375)
        assertHealthyLayout(at: 320)
        assertHealthyLayout(at: 375)

        let timeCells = visibleTableCells(in: tableView).filter {
            timelineRenderedText(of: $0).contains("01:46:42")
        }
        let card = tableView.subviews.first { $0.layer.cornerRadius == 8 }
        if let card, let lastRow = wrapRows(in: tableView).last {
            let lastFrame = lastRow.convert(lastRow.bounds, to: card)
            #expect(
                lastFrame.maxY <= card.bounds.maxY + 1,
                "Last row is clipped by the table card: row=\(lastFrame) card=\(card.bounds)"
            )
        }

        #expect(!timeCells.isEmpty, "Time column 01:46:42 must remain fully visible")
        for cell in timeCells {
            #expect(timelineRenderedText(of: cell).contains("01:46:42"))
            #expect(cellIsSingleLine(cell), "Time cell 01:46:42 must stay one line")
        }
    }

    @Test func assistantRowSelfSizingKeepsTimeEvidenceTableUnclipped() {
        let markdown = """
        ## What 01a0140d itself did

        | Time | Evidence |
        | --- | --- |
        | 01:46:42 | JSONL start, cwd ~/.config/dotfiles, host session (not Gondolin) |
        | 01:48:21 | auth.refresh_succeeded |
        | 01:49:48 | iOS background again; last WS activity 01a0140d; keepalive timeout (27s) |
        """
        let row = AssistantTimelineRowContentView(
            configuration: AssistantTimelineRowConfiguration(
                text: markdown,
                isStreaming: false,
                canFork: false,
                onFork: nil
            )
        )
        row.bounds = CGRect(x: 0, y: 0, width: 320, height: 10)
        let fitted = row.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .defaultLow
        )
        row.bounds.size = fitted
        row.setNeedsLayout()
        row.layoutIfNeeded()

        #expect(fitted.height > 160, "Assistant row collapsed the table (height=\(fitted.height))")

        let tables = timelineAllViews(in: row).compactMap { $0 as? NativeTableBlockView }
        #expect(tables.count == 1)
        guard let table = tables.first else { return }
        let rows = wrapRows(in: table)
        #expect(rows.count >= 2, "Expected wrapped Time/Evidence rows")
        if let last = rows.last {
            let lastFrame = last.convert(last.bounds, to: table)
            #expect(
                lastFrame.maxY <= table.bounds.maxY + 1,
                "Last table row clipped inside assistant cell: row=\(lastFrame) table=\(table.bounds) fitted=\(fitted)"
            )
        }
        let visibleTime = visibleTableCells(in: table).filter {
            timelineRenderedText(of: $0).contains("01:46:42")
        }
        #expect(!visibleTime.isEmpty)
        for cell in visibleTime {
            #expect(cellIsSingleLine(cell))
        }
    }
}

@MainActor
private func visibleTableCells(in tableView: NativeTableBlockView) -> [UITextView] {
    timelineAllTextViews(in: tableView).filter { !$0.isHidden && $0.bounds.width > 1 }
}

@MainActor
private func wrapRows(in tableView: NativeTableBlockView) -> [UIView] {
    let stacks = timelineAllViews(in: tableView).compactMap { $0 as? UIStackView }
    guard let wrapStack = stacks.first(where: { stack in
        !stack.isHidden
            && stack.axis == .vertical
            && stack.arrangedSubviews.contains(where: { ($0 as? UIStackView)?.axis == .horizontal })
    }) else {
        return []
    }
    return wrapStack.arrangedSubviews.filter { $0.bounds.height > 2 }
}

@MainActor
private func cellIsSingleLine(_ cell: UITextView) -> Bool {
    // Row stacks use .fill so zebra covers the tallest neighbor. Compare the
    // text's fitted height, not the stretched cell bounds.
    let singleLine = ceil(
        cell.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        ).height
    )
    let atAllocatedWidth = ceil(
        cell.sizeThatFits(
            CGSize(width: max(1, cell.bounds.width), height: .greatestFiniteMagnitude)
        ).height
    )
    return atAllocatedWidth <= singleLine + 1
}
