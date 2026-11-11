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

    // MARK: - Fit to the viewport

    /// `words`: each column's longest unbreakable word; prose of short words by default.
    private static func plan(
        _ naturals: [CGFloat],
        words: [CGFloat]? = nil,
        available: CGFloat?,
        scale: CGFloat = 3
    ) -> MarkdownTableColumnLayout.Plan {
        // Clip text is wider than the grid: `  │  ` separators instead of 8pt gaps.
        let clipWidth = naturals.reduce(0, +) + 40 * CGFloat(naturals.count)
        return MarkdownTableColumnLayout.plan(
            naturalWidths: naturals,
            longestWordWidths: words ?? naturals.map { min($0, 40) },
            clipContentWidth: clipWidth,
            availableWidth: available,
            displayScale: scale
        )
    }

    @Test func tableWiderThanViewportFitsWhenEveryColumnCanStayReadable() {
        let naturals: [CGFloat] = [90, 200, 274]
        let plan = Self.plan(naturals, available: 370)

        #expect(plan.presentation == .grid)
        #expect(MarkdownTableColumnLayout.gridContentWidth(columnWidths: plan.columnWidths) <= 370)
        for (fitted, natural) in zip(plan.columnWidths, naturals) {
            #expect(fitted <= natural)
            #expect(fitted >= MarkdownTableColumnLayout.minimumFitColumnWidth - 0.5)
        }
        #expect(plan.columnWidths[2] > plan.columnWidths[0], "The wide column gets the room")
    }

    @Test func shortColumnsKeepTheirNaturalWidthWhenTheTableIsFit() {
        let protected = MarkdownTableColumnLayout.protectedColumnWidth
        let long = MarkdownTableColumnLayout.maxReadableColumnWidth
        let naturals: [CGFloat] = [protected, protected, long, long]
        // Room for every column's floor, not for the long columns' natural width.
        let available = MarkdownTableColumnLayout.gridContentWidth(
            columnWidths: [protected, protected, long / 2, long / 2]
        )
        let plan = Self.plan(naturals, available: available)

        #expect(plan.presentation == .grid)
        #expect(plan.columnWidths[0] == protected)
        #expect(plan.columnWidths[1] == protected)
        #expect(MarkdownTableColumnLayout.gridContentWidth(columnWidths: plan.columnWidths) <= available)
    }

    @Test func tableScrollsWhenColumnsCannotStayReadable() {
        // Six columns of prose need 6 x 8 characters plus gaps: more than 300pt.
        let naturals = [CGFloat](repeating: 274, count: 6)
        let plan = Self.plan(naturals, available: 300)

        #expect(plan == Self.plan(naturals, available: nil), "No fit: the content-only layout, which scrolls")
        #expect(plan.columnWidths == naturals)
    }

    @Test func fittedColumnsNeverBreakTheirLongestWord() {
        let advance = MarkdownTableColumnLayout.characterWidth
        // An identifier column (16 characters, one word) beside a prose column.
        let identifier = ceil(16 * advance)
        let naturals: [CGFloat] = [identifier, 274]
        let fitted = Self.plan(naturals, words: [identifier, 50], available: 300)
        #expect(fitted.presentation == .grid)
        #expect(fitted.columnWidths[0] >= identifier, "The identifier keeps its width: \(fitted.columnWidths)")
        #expect(MarkdownTableColumnLayout.gridContentWidth(columnWidths: fitted.columnWidths) <= 300)

        // Four such columns cannot all keep their words in 300pt: scroll instead.
        let four = [CGFloat](repeating: identifier, count: 4)
        let scrolled = Self.plan(four, words: four, available: 300)
        #expect(scrolled == Self.plan(four, words: four, available: nil))
    }

    @Test func unbreakableRunsEndAtSpacesSlashesHyphensAndOtherScripts() {
        func longest(_ text: String) -> Int {
            TableInlineText.unbreakableRuns(in: text as NSString).map(\.length).max() ?? 0
        }
        #expect(longest("chooses clip or grid") == 7)
        #expect(longest("plan(width:)") == 12)
        #expect(longest("src/views/TableChrome.swift") == 17)
        #expect(longest("well-known") == 5)
        #expect(longest("表格的列宽") == 0)
    }

    /// Cells are proportional, so a word's floor is its drawn width, not its
    /// length: eight W's need far more room than eight i's, and a code span is
    /// measured in the code font it draws in.
    @Test @MainActor func wordFloorsAreMeasuredInTheFontsTheCellsDrawIn() {
        let fonts = TableInlineText.Fonts.current
        func width(_ text: String, _ font: UIFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let wide = TableInlineText.measure([.text("iiiiiiiiii WWWWWWWW")], fonts: fonts, isHeader: false)
        #expect(abs(wide.word - width("WWWWWWWW", fonts.body)) <= 1, "\(wide.word)")
        #expect(wide.word > width("iiiiiiiiii", fonts.body) + 20, "The widest run wins, not the longest")

        let code = TableInlineText.measure([.text("call "), .code("fold(rows:)")], fonts: fonts, isHeader: false)
        #expect(abs(code.word - width("fold(rows:)", fonts.code)) <= 1, "\(code.word)")

        let header = TableInlineText.measure([.text("Owner")], fonts: fonts, isHeader: true)
        #expect(abs(header.natural - width("Owner", fonts.bold)) <= 1, "Headers are measured bold")
    }

    @Test func wrappingColumnsShareTheSpareWidthUpToTheirContent() {
        let cap = MarkdownTableColumnLayout.maxReadableColumnWidth
        let naturals: [CGFloat] = [100, cap + 600, cap + 200]
        let chrome = MarkdownTableColumnLayout.gridContentWidth(columnWidths: [0, 0, 0])
        let cappedWidth = chrome + 100 + 2 * cap

        // 400pt to spare against 800pt wanted: each long column gets its share.
        let shared = Self.plan(naturals, available: cappedWidth + 400, scale: 1)
        #expect(shared.presentation == .grid)
        // Widths round down to the pixel grid, and the cap is not a whole point.
        for (width, expected) in zip(shared.columnWidths, [100, cap + 300, cap + 100]) {
            #expect(width <= expected && width > expected - 1, "\(shared.columnWidths)")
        }

        // More room than wanted: every column at its natural width, no wider.
        let roomy = Self.plan(naturals, available: cappedWidth + 2000, scale: 1)
        #expect(roomy.columnWidths == naturals)

        // The reader grows a table only to its prose column, not the window.
        let reader = MarkdownTableColumnLayout.plan(
            naturalWidths: naturals,
            longestWordWidths: naturals.map { min($0, 40) },
            clipContentWidth: naturals.reduce(0, +) + 120,
            availableWidth: cappedWidth + 2000,
            fillWidth: cappedWidth + 400,
            displayScale: 1
        )
        #expect(reader.columnWidths == shared.columnWidths)
    }

    @Test func clipTableThatFitsStaysClipText() {
        let plan = Self.plan([80, 80], available: 370)
        #expect(plan.presentation == .clip)
        #expect(plan.columnWidths == [80, 80])
    }

    @Test func fittedWidthsNeverOvershootTheViewport() {
        let naturals: [CGFloat] = [120, 90, 274, 150]
        // From where every column's floor fits up to where nothing needs fitting.
        let floors = MarkdownTableColumnLayout.gridContentWidth(columnWidths: [
            MarkdownTableColumnLayout.minimumFitColumnWidth, 90,
            MarkdownTableColumnLayout.minimumFitColumnWidth, MarkdownTableColumnLayout.minimumFitColumnWidth,
        ])
        for available in stride(from: ceil(floors), through: 700, by: 7) {
            let plan = Self.plan(naturals, available: available)
            #expect(
                MarkdownTableColumnLayout.gridContentWidth(columnWidths: plan.columnWidths) <= available,
                "Plan overshoots \(available): \(plan.columnWidths)"
            )
        }
    }

    @Test func hiddenColumnCountCountsColumnsPastTheVisibleEdge() {
        let edges: [CGFloat] = [100, 220, 340, 460]
        #expect(MarkdownTableColumnLayout.hiddenColumnCount(trailingEdges: edges, visibleMaxX: 370) == 1)
        #expect(MarkdownTableColumnLayout.hiddenColumnCount(trailingEdges: edges, visibleMaxX: 300) == 2, "A cut column counts")
        #expect(MarkdownTableColumnLayout.hiddenColumnCount(trailingEdges: edges, visibleMaxX: 460) == 0)
        #expect(MarkdownTableColumnLayout.hiddenColumnCount(trailingEdges: edges, visibleMaxX: 50) == 4)
    }

    @Test func trailingEdgesFollowTheDrawnLayouts() {
        let grid = MarkdownTableColumnLayout.gridTrailingEdges(columnWidths: [50, 60])
        #expect(grid == [58, 126])
        let clip = MarkdownTableColumnLayout.clipTrailingEdges(
            columnWidths: [50, 60],
            leadPad: 16,
            separator: 40,
            buffer: 1
        )
        #expect(clip == [67, 168])
    }
}

@Suite("Native table wrap-to-fit")
@MainActor
struct NativeTableWrapToFitTests {
    /// A table wider than the phone is fit to it when every column can stay
    /// readable: no sideways scroll, short values on one line, the long column
    /// wrapping into what is left.
    @Test func widerThanPhoneTableFitsWithoutScrollAndKeepsShortValuesOnOneLine() {
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
            (horizontalScroll?.contentSize.width ?? 0) <= (horizontalScroll?.bounds.width ?? 0) + 1,
            "A table whose columns can stay readable must fit the bubble, not scroll"
        )

        let shortCells = visibleTableCells(in: tableView).filter { cell in
            let text = timelineRenderedText(of: cell)
            return text == "Feature" || text == "Tables"
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
            #expect(!cellIsSingleLine(cell), "Long cell should wrap")
            #expect(
                cell.bounds.width < MarkdownTableColumnLayout.maxReadableColumnWidth - 1,
                "Long column should be fit below the readable clamp, got \(cell.bounds.width)"
            )
        }

        #expect(tableView.bounds.width <= 320.5)
    }

    /// On a wide screen (an iPad mini in landscape gives the chat about 1100pt)
    /// a table of prose is as wide as the text around it: its long column takes
    /// the spare width instead of wrapping at the clamp beside an empty half of
    /// the screen, and its short column stays on one line.
    @Test func proseTableFillsAWideViewport() {
        let width: CGFloat = 1100
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        let options = ["Shrink on read", "Drop older images", "Anthropic \u{201C}context editing\u{201D}"]
        let detail = "Keep the newest few images in full and swap older ones for a short note with the file path, so the model can open one again if it needs to."
        tableView.apply(
            headers: [[.text("Option")], [.text("What it does")]],
            rows: options.map { [[.text($0)], [.text(detail)]] },
            palette: ThemeRuntimeState.currentPalette()
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let card = tableView.subviews.first { $0.layer.cornerRadius == 8 }
        #expect(abs((card?.bounds.width ?? 0) - width) <= 1, "The table fills the width: \(card?.bounds.width ?? 0)")
        let scroll = timelineAllScrollViews(in: tableView).first { !($0 is UITextView) }
        #expect((scroll?.contentSize.width ?? .infinity) <= (scroll?.bounds.width ?? 0) + 1, "and does not scroll")
        let cells = visibleTableCells(in: tableView)
        for cell in cells where options.contains(timelineRenderedText(of: cell)) {
            #expect(cellIsSingleLine(cell), "Short cell wrapped: \(timelineRenderedText(of: cell))")
        }
        let detailCell = cells.first { timelineRenderedText(of: $0) == detail }
        #expect(
            (detailCell?.bounds.width ?? 0) > MarkdownTableColumnLayout.maxReadableColumnWidth * 2,
            "The long column takes the spare width: \(detailCell?.bounds.width ?? 0)"
        )
    }

    /// A long column that fits on one line in the spare width stops at its own
    /// width: the table does not stretch past its content.
    @Test func tableGrowsNoWiderThanItsContent() {
        let tableView = NativeTableBlockView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1100, height: 400))
        container.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        let longNotes = "Incremental tail parse keeps first paint cheap on long turns."
        tableView.apply(
            headers: [[.text("Feature")], [.text("Notes")]],
            rows: [[[.text("Streaming markdown")], [.text(longNotes)]]],
            palette: ThemeRuntimeState.currentPalette()
        )
        container.setNeedsLayout()
        container.layoutIfNeeded()

        for cell in visibleTableCells(in: tableView) {
            #expect(cellIsSingleLine(cell), "Nothing wraps with room to spare: \(timelineRenderedText(of: cell))")
        }
        let card = tableView.subviews.first { $0.layer.cornerRadius == 8 }
        #expect((card?.bounds.width ?? 1100) < 700, "A table that fits keeps its own width")
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

            let rows = wrapRowFrames(in: tableView, to: tableView)
            #expect(rows.count >= 2, "Expected header and body rows at width \(width)")
            for index in 0..<(rows.count - 1) {
                let current = rows[index]
                let next = rows[index + 1]
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
        if let card, let lastFrame = wrapRowFrames(in: tableView, to: card).last {
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
        var configuration = AssistantTimelineRowConfiguration(
            text: markdown,
            isStreaming: false,
            canFork: false,
            onFork: nil
        )
        // The width the timeline gives the markdown (`assistantMarkdownWidth`).
        let card = configuration.chromeStyle.assistantBubble
        configuration.markdownWidth = 320 - card.margins.leading - card.margins.trailing
            - card.padding.leading - card.padding.trailing
        let row = AssistantTimelineRowContentView(configuration: configuration)
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
        let rows = wrapRowFrames(in: table, to: table)
        #expect(rows.count >= 2, "Expected wrapped Time/Evidence rows")
        if let lastFrame = rows.last {
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
        var previousRowCells: [NSAttributedString] = []
        var ticksThatKeptRows = 0
        for (index, tick) in ticks.enumerated() {
            let previousColumns = Self.columnWidths(of: streamed)
            streamed.apply(headers: headers, rows: tick, palette: ThemeRuntimeState.currentPalette())

            let fresh = NativeTableBlockView()
            fresh.apply(headers: headers, rows: tick, palette: ThemeRuntimeState.currentPalette())

            // Both are measured at the chat width first: the columns are fit to it.
            let streamedHeight = Self.fittedHeight(of: streamed)
            let freshHeight = Self.fittedHeight(of: fresh)
            #expect(Self.gridSnapshot(of: streamed) == Self.gridSnapshot(of: fresh), "tick \(index)")
            #expect(streamedHeight == freshHeight, "tick \(index) height")

            let rowCells = Self.bodyRowCells(of: streamed)
            let unchanged = zip(previousTick, tick).prefix { $0 == $1 }.count
            if !previousColumns.isEmpty, previousColumns == Self.columnWidths(of: streamed), unchanged > 0 {
                ticksThatKeptRows += 1
                for row in 0..<unchanged {
                    #expect(previousRowCells[row] === rowCells[row], "tick \(index) rebuilt unchanged row \(row)")
                }
            }
            previousTick = tick
            previousRowCells = rowCells
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
            let lastFrame = try #require(wrapRowFrames(in: tableView, to: card).last)
            #expect(lastFrame.maxY <= card.bounds.maxY + 1, "\(index + 1) rows: last row \(lastFrame) past card \(card.bounds)")
            for cell in visibleTableCells(in: tableView) {
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

    /// The first cell of each body row. A row the grid kept is the same object.
    private static func bodyRowCells(of table: NativeTableBlockView) -> [NSAttributedString] {
        guard let layout = visibleGrid(in: table)?.layout else { return [] }
        return layout.cells.dropFirst().map { $0[0] }
    }

    private static func columnWidths(of table: NativeTableBlockView) -> [CGFloat] {
        visibleGrid(in: table)?.layout?.columnWidths ?? []
    }

    /// Cell text, width, and interactivity, and the stripe, of every grid row.
    private static func gridSnapshot(of table: NativeTableBlockView) -> [String] {
        guard let grid = visibleGrid(in: table), let layout = grid.layout else { return [] }
        return layout.cells.enumerated().map { row, cells in
            let selectable = grid.isInteractive ? "sel" : "-"
            let text = cells.enumerated().map { column, cell in
                "\(cell.string)@\(layout.columnWidths[column]) \(selectable)"
            }
            let stripe = row == 0 ? "header" : (row - 1) % 2 == 1 ? "zebra" : "plain"
            return text.joined(separator: " | ") + " bg=\(stripe)"
        }
    }
}

@MainActor
private func visibleGrid(in table: NativeTableBlockView) -> MarkdownTableGridView? {
    guard let grid = timelineFirstView(ofType: MarkdownTableGridView.self, in: table),
          !grid.isHidden, grid.layout != nil else { return nil }
    return grid
}

/// Every cell as the text view a touch would mount over it: the cell's text at
/// its column width, in a frame as tall as its row.
@MainActor
private func visibleTableCells(in tableView: NativeTableBlockView) -> [UITextView] {
    guard let layout = visibleGrid(in: tableView)?.layout else {
        return timelineAllTextViews(in: tableView).filter { !$0.isHidden && $0.bounds.width > 1 }
    }
    var cells: [UITextView] = []
    for row in layout.cells.indices {
        for column in layout.columnWidths.indices {
            let textView = UITextView(frame: layout.cellFrame(row: row, column: column))
            textView.isScrollEnabled = false
            textView.textContainerInset = UIEdgeInsets(
                top: MarkdownTableGridLayout.cellVerticalInset,
                left: 0,
                bottom: MarkdownTableGridLayout.cellVerticalInset,
                right: 0
            )
            textView.textContainer.lineFragmentPadding = 0
            textView.attributedText = layout.cells[row][column]
            cells.append(textView)
        }
    }
    return cells
}

/// Frame of every cell in the table's own coordinates, in either mode.
@MainActor
private func tableCellFrames(in table: NativeTableBlockView) -> [CGRect] {
    guard let grid = visibleGrid(in: table), let layout = grid.layout else {
        return timelineAllTextViews(in: table)
            .filter { !$0.isHidden && $0.bounds.width > 1 }
            .map { $0.convert($0.bounds, to: table) }
    }
    return layout.cells.indices.flatMap { row in
        layout.columnWidths.indices.map { column in
            grid.convert(layout.cellFrame(row: row, column: column), to: table)
        }
    }
}

/// Frame of every grid row (header, then body rows) in `target`'s coordinates.
@MainActor
private func wrapRowFrames(in tableView: NativeTableBlockView, to target: UIView) -> [CGRect] {
    guard let grid = visibleGrid(in: tableView), let layout = grid.layout else { return [] }
    return layout.cells.indices.map { row in
        grid.convert(
            CGRect(x: 0, y: layout.rowOrigins[row], width: layout.contentWidth, height: layout.rowHeights[row]),
            to: target
        )
    }
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

// MARK: - Fit to width and the cues around it

@Suite("Native table fit and chrome")
@MainActor
struct NativeTableFitAndChromeTests {
    @MainActor
    private final class Host {
        let container: UIView
        let table = NativeTableBlockView()
        let widthConstraint: NSLayoutConstraint

        init(width: CGFloat) {
            container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
            table.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(table)
            widthConstraint = table.widthAnchor.constraint(equalToConstant: width)
            NSLayoutConstraint.activate([
                table.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                table.topAnchor.constraint(equalTo: container.topAnchor),
                widthConstraint,
            ])
        }

        /// What a self-sizing cell does at `width`: measure, then lay out.
        @discardableResult
        func layout(at width: CGFloat) -> CGFloat {
            container.frame.size.width = width
            widthConstraint.constant = width
            let fitted = table.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            container.setNeedsLayout()
            container.layoutIfNeeded()
            container.layoutIfNeeded()
            return fitted
        }
    }

    private static func cells(_ rows: [[String]]) -> [[[MarkdownInline]]] {
        rows.map { $0.map { [.text($0)] } }
    }

    // MARK: Regression for ee911a546 (overlapping rows after fitting to the viewport)

    /// `ee911a546` removed fitting columns to the viewport: a squeezed timestamp
    /// column wrapped, and after a width change the table kept the height it had
    /// measured for the old width, so later rows painted over earlier ones. Fit
    /// is back, so this holds it to what that fix promised, across width changes:
    /// short values stay on one line, the reported height holds every cell, and
    /// no two cells in a column overlap.
    @Test func fitToWidthKeepsShortValuesOnOneLineAndRowsApartAcrossWidthChanges() {
        let host = Host(width: 390)
        host.table.apply(
            headers: [[.text("Time")], [.text("Event")], [.text("Detail")]],
            rows: Self.cells([
                ["01:46:42", "auth.refresh_succeeded", "JSONL start, cwd ~/.config/dotfiles, host session (not Gondolin) with a long trailing explanation"],
                ["01:48:21", "ws.keepalive_timeout", "iOS background again; last websocket activity before the keepalive timeout fired after 27s"],
                ["01:49:48", "session.resumed", "Foreground recovery reran after the socket was replaced."],
            ]),
            palette: ThemeRuntimeState.currentPalette()
        )

        for width in [390, 320, 390, 280, 360, 430] as [CGFloat] {
            let fitted = host.layout(at: width)
            let cells = visibleTableCells(in: host.table)
            #expect(!cells.isEmpty, "No cells at width \(width)")

            // 1. The short column never wraps (the timestamps in the old report).
            for cell in cells where timelineRenderedText(of: cell).hasPrefix("01:4") || timelineRenderedText(of: cell) == "Time" {
                #expect(cellIsSingleLine(cell), "Timestamp wrapped at width \(width): \(timelineRenderedText(of: cell))")
            }

            // 2. At a phone's width the table fits: nothing is cut at the right
            // edge and no scroll is needed. Narrower, `auth.refresh_succeeded`
            // cannot stay whole in the room left, so the table scrolls instead
            // of breaking the identifier mid-word.
            let scroll = timelineAllScrollViews(in: host.table).first { !($0 is UITextView) }
            let scrolls = (scroll?.contentSize.width ?? 0) > (scroll?.bounds.width ?? 0) + 1
            if width >= 390 {
                #expect(!scrolls, "Table scrolls at width \(width): content \(scroll?.contentSize.width ?? 0) in \(scroll?.bounds.width ?? 0)")
            } else if width <= 320 {
                #expect(scrolls, "Table fit at width \(width) by breaking an identifier")
            }

            // 3. The measured height holds every cell, and is the height laid out.
            let frames = tableCellFrames(in: host.table)
            #expect(
                (frames.map(\.maxY).max() ?? 0) <= fitted + 0.5,
                "Cells reach past the measured height at width \(width): \(frames.map(\.maxY).max() ?? 0) > \(fitted)"
            )
            #expect(
                abs(host.table.bounds.height - fitted) <= 1,
                "Laid-out height \(host.table.bounds.height) disagrees with the measured \(fitted) at width \(width)"
            )

            // 4. Cells in a column never overlap.
            let columns = Dictionary(grouping: frames) { Int($0.minX.rounded()) }
            for (x, column) in columns {
                let sorted = column.sorted { $0.minY < $1.minY }
                for (above, below) in zip(sorted, sorted.dropFirst()) {
                    #expect(above.maxY <= below.minY + 0.5, "Rows overlap in column x=\(x) at width \(width): \(above) vs \(below)")
                }
            }
        }
    }

    /// The same table measured narrow, then wide, must not keep the narrow height.
    @Test func measuredHeightFollowsTheWidthItIsMeasuredAt() {
        let host = Host(width: 390)
        host.table.apply(
            headers: [[.text("Check")], [.text("Result")]],
            rows: Self.cells([
                ["Build", "Compiled every target and linked the app without a single warning from the compiler or the linker."],
                ["Tests", "Every suite passed on the first run, including the slow integration suites and the UI suites."],
            ]),
            palette: ThemeRuntimeState.currentPalette()
        )
        let narrow = host.layout(at: 300)
        let wide = host.layout(at: 600)
        let narrowAgain = host.layout(at: 300)

        #expect(narrow > wide + 10, "Narrower columns wrap into more lines (narrow \(narrow), wide \(wide))")
        #expect(abs(narrowAgain - narrow) <= 1, "Returning to the narrow width restores its height (\(narrowAgain) vs \(narrow))")
    }

    /// A streamed table is measured at the chat width before it has a frame of its
    /// own. Each later apply must plan for that width, not fall back to the
    /// content-only layout, or every tick would redraw every row.
    @Test func tableMeasuredAtAWidthKeepsItsFitPlanAcrossAppliesBeforeFirstLayout() throws {
        let table = NativeTableBlockView()
        let long = "A long value that has to wrap inside the fitted column to stay on the phone."
        var rows = Self.cells([["Build", long], ["Tests", long]])
        let headers = Self.cells([["Check", "Result"]])[0]
        table.apply(headers: headers, rows: rows, palette: ThemeRuntimeState.currentPalette())
        _ = table.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let grid = try #require(timelineFirstView(ofType: MarkdownTableGridView.self, in: table))
        let fitted = try #require(grid.layout?.columnWidths)
        let firstRow = try #require(grid.layout?.cells[1][0])
        #expect(MarkdownTableColumnLayout.gridContentWidth(columnWidths: fitted) <= 320)

        rows.append(contentsOf: Self.cells([["Lint", long]]))
        table.apply(headers: headers, rows: rows, palette: ThemeRuntimeState.currentPalette())

        #expect(grid.layout?.columnWidths == fitted, "The plan for 320pt survives an apply that has no width")
        #expect(grid.layout?.cells[1][0] === firstRow, "An unchanged row is not rebuilt")
    }

    // MARK: Overflow cue

    private static func wideTable() -> (headers: [[MarkdownInline]], rows: [[[MarkdownInline]]]) {
        (
            (0 ..< 5).map { [.text("Col\($0)")] },
            cells([(0 ..< 5).map { String(repeating: "value\($0)-", count: 4) }])
        )
    }

    private func overlay(in table: NativeTableBlockView) -> TableOverflowOverlayView? {
        timelineAllViews(in: table).compactMap { $0 as? TableOverflowOverlayView }.first
    }

    private func pill(in table: NativeTableBlockView) -> UIButton? {
        timelineAllViews(in: table).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "markdown.table.moreColumns"
        }
    }

    @Test func scrollingTableShowsAHiddenColumnCountThatFollowsTheScroll() throws {
        let host = Host(width: 320)
        let wide = Self.wideTable()
        host.table.apply(headers: wide.headers, rows: wide.rows, palette: ThemeRuntimeState.currentPalette())
        host.layout(at: 320)

        let scroll = try #require(timelineAllScrollViews(in: host.table).first { !($0 is UITextView) })
        let overlay = try #require(overlay(in: host.table))
        let pill = try #require(pill(in: host.table))
        #expect(scroll.contentSize.width > scroll.bounds.width + 1, "Fixture must overflow")
        #expect(overlay.isCueVisible)
        let atStart = try #require(pill.accessibilityLabel)
        #expect(atStart.hasSuffix("more columns"), "Got \(atStart)")

        // Scrolling updates the count without a layout pass.
        scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width
        #expect(!overlay.isCueVisible, "Nothing is hidden at the right end")

        // Just short of the end, only the last column is cut: singular.
        scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width - 24
        #expect(overlay.isCueVisible)
        #expect(pill.accessibilityLabel == "1 more column")

        scroll.contentOffset.x = 0
        #expect(overlay.isCueVisible)
        #expect(pill.accessibilityLabel == atStart)
    }

    @Test func overflowCueAddsNoLayoutAndIsReachableForVoiceOver() throws {
        let host = Host(width: 320)
        let wide = Self.wideTable()
        host.table.apply(headers: wide.headers, rows: wide.rows, palette: ThemeRuntimeState.currentPalette())
        let heightWithCue = host.layout(at: 320)
        let scroll = try #require(timelineAllScrollViews(in: host.table).first { !($0 is UITextView) })
        let overlay = try #require(overlay(in: host.table))
        let pill = try #require(pill(in: host.table))

        scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width
        #expect(overlay.frame == scroll.frame, "The overlay covers the scroller and takes no space of its own")
        #expect(abs(host.layout(at: 320) - heightWithCue) <= 1, "The cue must not move the table")
        #expect(pill.accessibilityTraits.contains(.button))
        #expect(pill.accessibilityHint?.isEmpty == false)
        #expect(
            overlay.hitTest(CGPoint(x: 2, y: overlay.bounds.midY), with: nil) == nil,
            "Only the pill takes touches; the table underneath keeps scrolling and selecting"
        )
    }

    @Test func tableThatFitsShowsNoCue() throws {
        let host = Host(width: 390)
        host.table.apply(
            headers: [[.text("Name")], [.text("Role")]],
            rows: Self.cells([["Ada", "Engineer"], ["Grace", "Admiral"]]),
            palette: ThemeRuntimeState.currentPalette()
        )
        host.layout(at: 390)
        let overlay = try #require(overlay(in: host.table))
        #expect(!overlay.isCueVisible)
    }

    @Test func narrowingATableUntilItNoLongerFitsTurnsTheCueOn() throws {
        let host = Host(width: 390)
        host.table.apply(
            headers: [[.text("Name")], [.text("Role")], [.text("Team")], [.text("Region")]],
            rows: Self.cells([["Ada Lovelace", "Principal engineer", "Analytical Engines", "London"]]),
            palette: ThemeRuntimeState.currentPalette()
        )
        host.layout(at: 390)
        let overlay = try #require(overlay(in: host.table))
        #expect(!overlay.isCueVisible)

        host.layout(at: 160)
        #expect(overlay.isCueVisible, "At 160pt the columns cannot stay readable, so the table scrolls and says so")
        host.layout(at: 390)
        #expect(!overlay.isCueVisible)
    }

    // MARK: Fold

    @Test func longTableFoldsBehindShowAllRowsAndCopiesEveryRow() throws {
        let rows = (1 ... 30).map { ["item-\($0)", "value \($0)"] }
        let folded = Host(width: 390)
        folded.table.rowFoldLimit = NativeTableBlockView.chatFoldRowLimit
        folded.table.apply(
            headers: [[.text("Item")], [.text("Value")]],
            rows: Self.cells(rows),
            palette: ThemeRuntimeState.currentPalette()
        )
        let foldedHeight = folded.layout(at: 390)

        let button = try #require(timelineAllViews(in: folded.table).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "markdown.table.showAll"
        })
        #expect(button.accessibilityLabel == "Show all 30 rows")
        #expect(!button.isHidden)

        // Twenty rows are drawn, the rest only behind the button.
        let drawn = timelineAllTextViews(in: folded.table).map(timelineRenderedText).joined(separator: "\n")
        #expect(drawn.contains("item-20"))
        #expect(!drawn.contains("item-21"))

        // The footer is part of the measured height: a table of exactly the
        // folded size plus the bar.
        let twenty = Host(width: 390)
        twenty.table.apply(
            headers: [[.text("Item")], [.text("Value")]],
            rows: Self.cells(Array(rows.prefix(20))),
            palette: ThemeRuntimeState.currentPalette()
        )
        let twentyHeight = twenty.layout(at: 390)
        #expect(abs(foldedHeight - (twentyHeight + TableFoldFooterView.height)) <= 1)
        #expect(abs(folded.table.bounds.height - foldedHeight) <= 1)

        // Copy and the viewer take every row.
        let tsv = folded.table.tableText(.tsv)
        #expect(tsv.split(separator: "\n").count == 31)
        #expect(tsv.hasSuffix("item-30\tvalue 30"))
        #expect(folded.table.tableText(.markdown).split(separator: "\n").count == 32)
    }

    private func showAllIsVisible(in table: NativeTableBlockView) -> Bool {
        timelineAllViews(in: table).contains {
            $0.accessibilityIdentifier == "markdown.table.showAll" && !$0.isHidden && $0.superview?.isHidden == false
        }
    }

    @Test func tableAtOrUnderTheLimitDoesNotFoldAndReaderNeverFolds() throws {
        let atLimit = Host(width: 390)
        atLimit.table.rowFoldLimit = NativeTableBlockView.chatFoldRowLimit
        atLimit.table.apply(
            headers: [[.text("Item")]],
            rows: Self.cells((1 ... 20).map { ["row-\($0)"] }),
            palette: ThemeRuntimeState.currentPalette()
        )
        atLimit.layout(at: 390)
        #expect(!showAllIsVisible(in: atLimit.table))

        let reader = Host(width: 390)
        reader.table.rowFoldLimit = nil
        reader.table.apply(
            headers: [[.text("Item")]],
            rows: Self.cells((1 ... 60).map { ["row-\($0)"] }),
            palette: ThemeRuntimeState.currentPalette()
        )
        reader.layout(at: 390)
        #expect(!showAllIsVisible(in: reader.table))
        #expect(timelineAllTextViews(in: reader.table).map(timelineRenderedText).joined().contains("row-60"))
    }

    @Test func foldTracksARowThatStreamsPastTheLimit() throws {
        let host = Host(width: 390)
        host.table.rowFoldLimit = 20
        let palette = ThemeRuntimeState.currentPalette()
        func rows(_ count: Int) -> [[[MarkdownInline]]] { Self.cells((1 ... count).map { ["row-\($0)"] }) }

        host.table.apply(headers: [[.text("Item")]], rows: rows(20), palette: palette)
        host.layout(at: 390)
        let heightAtTwenty = host.table.bounds.height

        host.table.apply(headers: [[.text("Item")]], rows: rows(21), palette: palette)
        host.layout(at: 390)
        let footer = try #require(timelineAllViews(in: host.table).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "markdown.table.showAll"
        })
        #expect(footer.accessibilityLabel == "Show all 21 rows")
        #expect(abs(host.table.bounds.height - (heightAtTwenty + TableFoldFooterView.height)) <= 1)

        host.table.apply(headers: [[.text("Item")]], rows: rows(25), palette: palette)
        host.layout(at: 390)
        #expect(footer.accessibilityLabel == "Show all 25 rows")
        // Copy takes every row, the hidden ones included.
        #expect(host.table.tableText(.tsv).split(separator: "\n").count == 26)
    }
}
