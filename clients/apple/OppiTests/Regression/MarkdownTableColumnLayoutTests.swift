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
        #expect(
            (horizontalScroll?.contentSize.width ?? 0) > (horizontalScroll?.bounds.width ?? 0) + 1,
            "Clamped grid wider than the bubble must enable horizontal scroll"
        )

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

@Suite("Native table streaming")
@MainActor
struct NativeTableStreamingTests {
    /// A streamed table only rebuilds the rows past the unchanged prefix. At
    /// every tick — a new row, a row still being typed, a column that widens,
    /// a link that makes cells selectable, a rewritten middle row, a dropped
    /// row — it must match a table built from scratch, and rows before the
    /// first change must stay mounted while the columns hold.
    @Test func streamedGridMatchesAFreshTableAndKeepsUnchangedRows() {
        let long = "keeps the open table in the streaming tail and wraps at the clamp"
        var rows: [[[MarkdownInline]]] = (0..<8).map { Self.cells(["row \($0)", "\(long) \($0)"]) }
        rows[5][0] = [.text("a much wider first column cell")]

        var ticks: [[[[MarkdownInline]]]] = []
        for count in 1...rows.count {
            var tick = Array(rows.prefix(count))
            // The last row arrives in two pieces before it is complete.
            tick[count - 1][1] = [.text(String(long.prefix(12)))]
            ticks.append(tick)
            ticks.append(Array(rows.prefix(count)))
        }
        rows.append([[.text("row 8")], [.link(children: [.text("docs")], destination: "https://example.com"), .text(" \(long)")]])
        ticks.append(rows)
        rows[3][1] = [.text("\(long) rewritten")]
        ticks.append(rows)
        ticks.append(Array(rows.dropLast()))

        let headers = Self.cells(["Name", "Notes"])
        let streamed = NativeTableBlockView()
        var previousTick: [[[MarkdownInline]]] = []
        var previousRowViews: [UIView] = []
        var ticksThatKeptRows = 0
        for (index, tick) in ticks.enumerated() {
            let previousColumns = Self.columnWidths(of: streamed)
            streamed.apply(headers: headers, rows: tick, palette: ThemeRuntimeState.currentPalette())

            let fresh = NativeTableBlockView()
            fresh.apply(headers: headers, rows: tick, palette: ThemeRuntimeState.currentPalette())

            #expect(Self.gridSnapshot(of: streamed) == Self.gridSnapshot(of: fresh), "tick \(index)")
            #expect(Self.fittedHeight(of: streamed) == Self.fittedHeight(of: fresh), "tick \(index) height")

            let rowViews = Self.bodyRowViews(of: streamed)
            let unchanged = zip(previousTick, tick).prefix { $0 == $1 }.count
            if !previousColumns.isEmpty, previousColumns == Self.columnWidths(of: streamed), unchanged > 0 {
                ticksThatKeptRows += 1
                for row in 0..<unchanged {
                    #expect(previousRowViews[row] === rowViews[row], "tick \(index) rebuilt unchanged row \(row)")
                }
            }
            previousTick = tick
            previousRowViews = rowViews
        }
        #expect(ticksThatKeptRows >= ticks.count / 2, "Only \(ticksThatKeptRows) of \(ticks.count) ticks kept rows")
    }

    /// The table's own height must hold every wrapped row once the grid is
    /// laid out, tick after tick, at the size of a long streamed answer. A
    /// height that lags the appended rows clips the bottom of the table.
    @Test func mountedStreamingTableNeverClipsItsRows() throws {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 800))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        let headers = Self.cells(["Metric", "Emitter", "Unit", "Tags emitted", "Filter", "Review", "Dash"])
        var rows: [[[MarkdownInline]]] = []
        for index in 0..<64 {
            let tags = index % 3 == 0
                ? "engine, locale, ui_locale, source, provider_id, provider_kind, stt_backend, model"
                : "phase, status"
            rows.append(Self.cells([
                "chat.metric_\(index)_ms",
                "ChatSessionManager.swift:\(100 + index * 7)",
                "ms",
                tags,
                index % 4 == 0 ? "only when the session is streaming and visible" : "none",
                "UX",
                "RP",
            ]))
            tableView.apply(headers: headers, rows: rows, palette: ThemeRuntimeState.currentPalette())
            container.setNeedsLayout()
            container.layoutIfNeeded()
            guard index % 8 == 7 else { continue }

            let card = try #require(tableView.subviews.first { $0.layer.cornerRadius == 8 })
            let lastRow = try #require(Self.bodyRowViews(of: tableView).last)
            let lastFrame = lastRow.convert(lastRow.bounds, to: card)
            #expect(lastFrame.maxY <= card.bounds.maxY + 1, "\(index + 1) rows: last row \(lastFrame) past card \(card.bounds)")
            for case let cell as UITextView in Self.bodyRowViews(of: tableView).flatMap({ ($0 as? UIStackView)?.arrangedSubviews ?? [] }) {
                let needed = cell.sizeThatFits(CGSize(width: cell.bounds.width, height: .greatestFiniteMagnitude)).height
                #expect(cell.bounds.height + 0.5 >= needed, "\(index + 1) rows: cell squeezed to \(cell.bounds.height) of \(needed)")
            }
        }
    }

    private static func fittedHeight(of table: NativeTableBlockView) -> CGFloat {
        table.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private static func cells(_ texts: [String]) -> [[MarkdownInline]] {
        texts.map { [.text($0)] }
    }

    private static func wrapStack(of table: NativeTableBlockView) -> UIStackView? {
        timelineAllViews(in: table).compactMap { $0 as? UIStackView }.first {
            !$0.isHidden && $0.axis == .vertical
        }
    }

    private static func bodyRowViews(of table: NativeTableBlockView) -> [UIView] {
        // Header row and separator lead the grid.
        Array((wrapStack(of: table)?.arrangedSubviews ?? []).dropFirst(2))
    }

    private static func columnWidths(of table: NativeTableBlockView) -> [CGFloat] {
        guard let header = wrapStack(of: table)?.arrangedSubviews.first as? UIStackView else { return [] }
        return header.arrangedSubviews.map { pinnedWidth(of: $0) }
    }

    /// The cell's column width. Laid-out cells also carry UIKit's intrinsic
    /// size constraints, which are subclasses and do not count.
    private static func pinnedWidth(of cell: UIView) -> CGFloat {
        cell.constraints.first {
            type(of: $0) == NSLayoutConstraint.self && $0.firstAttribute == .width
        }?.constant ?? -1
    }

    /// Cell text, width, and selectability, and the stripe color, of every
    /// grid row.
    private static func gridSnapshot(of table: NativeTableBlockView) -> [String] {
        (wrapStack(of: table)?.arrangedSubviews ?? []).map { row in
            guard let row = row as? UIStackView else { return "separator" }
            let cells = row.arrangedSubviews.map { cell in
                let selectable = (cell as? UITextView)?.isSelectable == true ? "sel" : "-"
                return "\(timelineRenderedText(of: cell))@\(pinnedWidth(of: cell)) \(selectable)"
            }
            return cells.joined(separator: " | ") + " bg=\(String(describing: row.backgroundColor))"
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
