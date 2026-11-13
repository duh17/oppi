import Testing
import UIKit
@testable import Oppi

/// Regression test: CJK/emoji table columns must align correctly.
///
/// SF Mono is monospaced for ASCII but CJK characters fall back to a
/// different system font (PingFang SC etc.) whose glyph widths are NOT
/// exact multiples of the ASCII advance width. The old character-counting
/// approach (CJK = 2 columns) produced visible misalignment.
///
/// The fix uses NSTextTab stops so the text system places column
/// separators at exact pixel positions. This test verifies the `│`
/// separators appear at the same horizontal offset across all rows.
@Suite("Table Column Alignment")
@MainActor
struct TableColumnAlignmentTests {

    // MARK: - CJK alignment (the original bug)

    @Test func cjkColumnsAlignAcrossRows() throws {
        let headers: [[MarkdownInline]] = [
            [.text("")],
            [.text("我们")],
            [.text("moona3k")],
        ]
        let rows: [[[MarkdownInline]]] = [
            [[.text("编码")], [.text("缓存完成的窗口，只编码尾部")], [.text("每个 chunk 重新跑 encoder")]],
            [[.text("Prefill")], [.text("Delta prefill, 逐元素比较")], [.text("无增量 prefill")]],
            [[.text("Rollback")], [.text("Token 级 rollback")], [.text("字符串拼接 + overlap")]],
        ]

        try assertColumnsAligned(headers: headers, rows: rows)
    }

    // MARK: - Mixed CJK + ASCII in the same column

    @Test func mixedCjkAsciiColumnAligns() throws {
        let headers: [[MarkdownInline]] = [
            [.text("名称")],
            [.text("Value")],
        ]
        let rows: [[[MarkdownInline]]] = [
            [[.text("延迟")], [.text("120ms")]],
            [[.text("Latency")], [.text("95ms")]],
            [[.text("吞吐量")], [.text("1000 req/s")]],
        ]

        try assertColumnsAligned(headers: headers, rows: rows)
    }

    // MARK: - Emoji columns

    @Test func emojiColumnsAlign() throws {
        let headers: [[MarkdownInline]] = [
            [.text("Icon")],
            [.text("Name")],
        ]
        let rows: [[[MarkdownInline]]] = [
            [[.text("🔥")], [.text("Fire")]],
            [[.text("AB")], [.text("Alpha Beta")]],
            [[.text("🎉🎊")], [.text("Party")]],
        ]

        try assertColumnsAligned(headers: headers, rows: rows)
    }

    // MARK: - Pure ASCII (sanity check — should always pass)

    @Test func pureAsciiColumnsAlign() throws {
        let headers: [[MarkdownInline]] = [
            [.text("Name")],
            [.text("Score")],
            [.text("Grade")],
        ]
        let rows: [[[MarkdownInline]]] = [
            [[.text("Alice")], [.text("95")], [.text("A")]],
            [[.text("Bob")], [.text("87")], [.text("B+")]],
            [[.text("Charlie")], [.text("100")], [.text("A+")]],
        ]

        try assertColumnsAligned(headers: headers, rows: rows)
    }

    /// The rule under the header spans the table: it ended short of the right
    /// edge when its dash width was rounded up before counting the dashes.
    @Test(arguments: [
        ["Area", "Owner"],
        ["Run", "Images", "Avg KB", "Total MB", "p50 ms", "p95 ms"],
    ])
    func headerRuleSpansTheTable(headerTexts: [String]) throws {
        let text = try timelineClipTableText(
            headers: headerTexts.map { [.text($0)] },
            rows: [headerTexts.map { [.text("\($0) value")] }],
            palette: ThemePalettes.dark
        )
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        var lineWidths: [CGFloat] = []
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, used, _, _, _ in
            lineWidths.append(used.width)
        }
        try #require(lineWidths.count >= 3, "header, rule, and a row")
        // The table's width: its last tab stop plus the trailing pad.
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let lastStop = try #require(style.tabStops.last).location
        let pad = ("  " as NSString).size(withAttributes: [.font: AppFont.messageBody]).width
        let tableWidth = lastStop + ceil(pad)
        #expect(abs(lineWidths[1] - tableWidth) <= 1, "rule \(lineWidths[1]) vs table \(tableWidth)")
    }

    // MARK: - Numbers align on their trailing edge

    @Test(arguments: [
        ("0.35 ms", MarkdownTableColumnAlignment.CellKind.number), ("1,702 ms", .number), ("99.95%", .number),
        ("$7.76", .number), ("−3", .number), ("4x", .number), ("182 MB", .number), ("12", .number),
        ("4.1 KB", .number), ("12%", .number), ("about 2.0 ms", .number), ("~3 s", .number),
        ("—", .empty), ("n/a", .empty), ("", .empty),
        ("about half", .text), ("2026-09-14", .text), ("iOS 27.1", .text), ("3f9c2a1", .text),
        ("Tue 09:00", .text), ("2 of 5", .text),
    ])
    func cellsReadAsNumbersOnlyWhenTheyAreNumbers(text: String, kind: MarkdownTableColumnAlignment.CellKind) {
        #expect(MarkdownTableColumnAlignment.kind(of: text) == kind)
    }

    /// A column is numeric while every filled cell is a number; one word in it
    /// makes it text, and a streamed row that is replaced takes its word along.
    @Test func aColumnOfNumbersStaysNumericAsRowsStream() {
        func row(_ cells: String...) -> [[MarkdownInline]] { cells.map { [.text($0)] } }
        var detector = MarkdownTableColumnAlignment.Detector()
        let rows = [row("6 KB message", "0.03 ms", "—"), row("67 KB report", "0.35 ms", "—")]
        detector.replaceRows(keeping: 0, with: rows, columnCount: 3)
        #expect(detector.alignments == [.leading, .trailing, .leading], "A column of dashes has no number to align")

        detector.replaceRows(keeping: 2, with: rows + [row("273 KB session", "pending", "2.0 ms")], columnCount: 3)
        #expect(detector.alignments == [.leading, .leading, .trailing])

        // The device report's table: every timing, hedged or not, under dashes.
        detector.replaceRows(keeping: 2, with: rows + [row("273 KB session", "1.1 ms", "about 2.0 ms")], columnCount: 3)
        #expect(detector.alignments == [.leading, .trailing, .trailing])
    }

    /// In the tab-stop text a numeric column's values, and its header, end at
    /// the column's right edge; a text column's start at its left edge.
    @Test func numericColumnsEndOnTheirRightEdgeInClipText() throws {
        let headers: [[MarkdownInline]] = [[.text("Input")], [.text("Median")]]
        let rows: [[[MarkdownInline]]] = [
            [[.text("6 KB message")], [.text("0.03 ms")]],
            [[.text("273 KB session")], [.text("1,702.4 ms")]],
        ]
        let text = try timelineClipTableText(headers: headers, rows: rows, palette: ThemePalettes.dark)
        let frames = try cellFrames(in: text)
        let numbers = (0 ... 2).compactMap { frames[TableSelectionText.CellPosition(row: $0, column: 1)] }
        let labels = (0 ... 2).compactMap { frames[TableSelectionText.CellPosition(row: $0, column: 0)] }
        try #require(numbers.count == 3 && labels.count == 3)
        for frame in numbers.dropFirst() {
            #expect(abs(frame.maxX - numbers[0].maxX) <= 1, "Right edges \(numbers.map(\.maxX))")
        }
        #expect(numbers[1].minX > numbers[2].minX + 5, "The shorter value starts further right")
        for frame in labels.dropFirst() {
            #expect(abs(frame.minX - labels[0].minX) <= 1, "Left edges \(labels.map(\.minX))")
        }
    }

    /// The source's delimiter row outranks detection: `:---` keeps numbers at
    /// the leading edge, `---:` and `:---:` place text; columns it leaves alone
    /// are detected.
    @Test func delimiterRowAlignmentWinsAndDetectionFillsTheRest() {
        #expect(MarkdownTableColumnAlignment.resolve(
            explicit: [.left, .right, .center, nil],
            detected: [.trailing, .leading, .leading, .trailing]
        ) == [.leading, .trailing, .center, .trailing])
        #expect(MarkdownTableColumnAlignment.resolve(explicit: [], detected: [.leading, .trailing]) == [.leading, .trailing])
    }

    /// A centered column's cells center on the column's middle in the tab-stop text.
    @Test func centeredColumnsCenterInClipText() throws {
        let headers: [[MarkdownInline]] = [[.text("Name")], [.text("Status")]]
        let rows: [[[MarkdownInline]]] = [
            [[.text("build")], [.text("ok")]],
            [[.text("tests")], [.text("passed again")]],
        ]
        let table = NativeTableBlockView()
        table.frame = CGRect(x: 0, y: 0, width: 600, height: 200)
        table.apply(headers: headers, rows: rows, alignments: [nil, .center], palette: ThemePalettes.dark)
        table.layoutIfNeeded()
        let text = try #require(table.debugClipTextForTesting)
        let frames = try cellFrames(in: text)
        let short = try #require(frames[TableSelectionText.CellPosition(row: 1, column: 1)])
        let long = try #require(frames[TableSelectionText.CellPosition(row: 2, column: 1)])
        #expect(abs(short.midX - long.midX) <= 1, "Centers \(short.midX) and \(long.midX)")
        #expect(table.tableText(.markdown).contains("| --- | :---: |"), "Copy keeps the alignment")
    }

    /// The wrapping grid right-aligns the same columns, header included, and
    /// draws digits tabular so they stack by place value.
    @Test func numericColumnsAlignRightInTheGrid() throws {
        let table = NativeTableBlockView()
        table.surface = .viewer
        table.apply(
            headers: [[.text("Device")], [.text("Cold launch")]],
            rows: [[[.text("iPhone 16 Pro")], [.text("412 ms")]], [[.text("iPhone SE")], [.text("1,702 ms")]]],
            palette: ThemePalettes.dark
        )
        let layout = try #require(table.debugGridViewForTesting.layout)
        func alignment(_ row: Int, _ column: Int) -> NSTextAlignment? {
            (layout.cells[row][column].attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        #expect((0 ... 2).allSatisfy { alignment($0, 1) == .right })
        #expect((0 ... 2).allSatisfy { alignment($0, 0) != .right })
        let font = try #require(layout.cells[1][1].attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let one = ("1" as NSString).size(withAttributes: [.font: font]).width
        let eight = ("8" as NSString).size(withAttributes: [.font: font]).width
        #expect(abs(one - eight) < 0.01, "Tabular digits: 1 is \(one), 8 is \(eight)")
    }

    // MARK: - Helpers

    /// Each cell's laid-out frame in the tab-stop text, by its cell attribute.
    private func cellFrames(in text: NSAttributedString) throws -> [TableSelectionText.CellPosition: CGRect] {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        var frames: [TableSelectionText.CellPosition: CGRect] = [:]
        text.enumerateAttribute(TableSelectionText.cellAttribute, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let point = (value as? NSValue)?.cgPointValue else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            frames[TableSelectionText.CellPosition(row: Int(point.y), column: Int(point.x))] =
                layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        }
        return frames
    }

    /// Assert that all `│` separators in the rendered table align vertically
    /// within 1pt tolerance (sub-pixel — effectively exact).
    private func assertColumnsAligned(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]],
        file: String = #file,
        line: Int = #line
    ) throws {
        let separatorOffsets = try measureSeparatorOffsets(headers: headers, rows: rows)

        // With tab stops, alignment should be sub-pixel perfect.
        let tolerance: CGFloat = 1.0

        for col in 0..<separatorOffsets[0].count {
            let referenceOffset = separatorOffsets[0][col]
            for row in 1..<separatorOffsets.count {
                let offset = separatorOffsets[row][col]
                let diff = abs(offset - referenceOffset)
                #expect(
                    diff <= tolerance,
                    """
                    Column \(col) separator misaligned: \
                    row 0 = \(referenceOffset), row \(row) = \(offset), \
                    diff = \(diff), tolerance = \(tolerance)
                    """
                )
            }
        }
    }

    /// Build the table attributed text and measure the horizontal offset of
    /// each `│` separator on every data line (header + body rows).
    ///
    /// Uses `NSLayoutManager` for measurement because `boundingRect` alone
    /// doesn't account for tab-stop expansion in the paragraph style.
    private func measureSeparatorOffsets(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]]
    ) throws -> [[CGFloat]] {
        let palette = ThemePalettes.dark
        let attrText = try timelineClipTableText(headers: headers, rows: rows, palette: palette)

        // Use TextKit 1 layout manager for precise glyph-position queries.
        let textStorage = NSTextStorage(attributedString: attrText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let fullString = attrText.string
        let nsString = fullString as NSString

        // Identify data lines (those containing │). Skip the separator line.
        var dataLineRanges: [NSRange] = []
        var searchStart = 0
        while searchStart < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: searchStart, length: 0))
            let lineStr = nsString.substring(with: lineRange)
            if lineStr.contains("│") {
                dataLineRanges.append(lineRange)
            }
            searchStart = NSMaxRange(lineRange)
        }

        try #require(
            dataLineRanges.count == 1 + rows.count,
            "Expected \(1 + rows.count) data lines, got \(dataLineRanges.count)"
        )

        // For each data line, find the glyph X position of each │ character.
        var allOffsets: [[CGFloat]] = []

        for lineRange in dataLineRanges {
            let lineStr = nsString.substring(with: lineRange)
            let nsLine = lineStr as NSString
            var offsets: [CGFloat] = []
            var pos = 0
            while pos < nsLine.length {
                let range = nsLine.range(
                    of: "│",
                    range: NSRange(location: pos, length: nsLine.length - pos)
                )
                guard range.location != NSNotFound else { break }

                // Character index in the full string.
                let charIndex = lineRange.location + range.location
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                let glyphRect = layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyphIndex, length: 1),
                    in: textContainer
                )
                offsets.append(round(glyphRect.origin.x))

                pos = range.location + range.length
            }
            allOffsets.append(offsets)
        }

        // Verify all rows have the same number of separators.
        let sepCount = allOffsets[0].count
        for (i, offsets) in allOffsets.enumerated() {
            try #require(
                offsets.count == sepCount,
                "Row \(i) has \(offsets.count) separators, expected \(sepCount)"
            )
        }

        return allOffsets
    }
}
