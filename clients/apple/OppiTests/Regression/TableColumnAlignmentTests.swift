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

    // MARK: - Single column (no separators — should not crash)

    @Test func singleColumnTableRenders() {
        let headers: [[MarkdownInline]] = [[.text("Item")]]
        let rows: [[[MarkdownInline]]] = [
            [[.text("Alpha")]],
            [[.text("日本語")]],
        ]
        let palette = ThemePalettes.dark
        let attrText = NativeTableBlockView.makeTableAttributedText(
            headers: headers, rows: rows, palette: palette
        )
        #expect(!attrText.string.isEmpty)
    }

    /// The rule under the header spans the table: it ended short of the right
    /// edge when its dash width was rounded up before counting the dashes.
    @Test(arguments: [
        ["Area", "Owner"],
        ["Run", "Images", "Avg KB", "Total MB", "p50 ms", "p95 ms"],
    ])
    func headerRuleSpansTheTable(headerTexts: [String]) throws {
        let text = NativeTableBlockView.makeTableAttributedText(
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

    // MARK: - Helpers

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
        let attrText = NativeTableBlockView.makeTableAttributedText(
            headers: headers, rows: rows, palette: palette
        )

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
