import Foundation

/// Where the wrapped rows of a line start, in columns.
///
/// A continuation row lines up with the text of its own line, never deeper:
/// - Prose and code: the line's own leading indentation, so a flush paragraph
///   wraps flush and an indented line wraps under its own first character.
/// - Markdown list items and quotes: the column where the item's text starts,
///   after the quote markers, the bullet or number, and a task checkbox.
///
/// Pure, so the rule is testable without a window.
enum CodeEditorWrapIndent {
    /// Columns for the line `lineStart..<contentsEnd` of `text`. Tabs advance
    /// to the next multiple of `tabWidth`.
    static func columns(in text: NSString, lineStart: Int, contentsEnd: Int, tabWidth: Int, markdown: Bool) -> Int {
        let tabWidth = max(1, tabWidth)
        var index = lineStart
        var column = 0
        skipBlanks(text, &index, contentsEnd, &column, tabWidth)
        let indent = column
        guard markdown else { return indent }

        // Quote markers: `>`, `> >`, `>>`.
        var quoted = false
        while index < contentsEnd, text.character(at: index) == quote {
            quoted = true
            index += 1
            column += 1
            if index < contentsEnd, text.character(at: index) == CodeText.space {
                index += 1
                column += 1
            }
        }
        if quoted { skipBlanks(text, &index, contentsEnd, &column, tabWidth) }
        let textColumn = column
        guard let markerWidth = listMarkerWidth(text, at: index, contentsEnd: contentsEnd) else { return textColumn }
        index += markerWidth
        column += markerWidth
        let markerEnd = column
        var gap = column
        skipBlanks(text, &index, contentsEnd, &gap, tabWidth)
        // Four spaces or fewer after the marker belong to it; more is an
        // indented code block inside the item, which starts one space in.
        let spaces = gap - markerEnd
        guard spaces > 0 else { return textColumn }
        column = markerEnd + (spaces > 4 ? 1 : spaces)
        if let box = taskBoxWidth(text, at: index, contentsEnd: contentsEnd) { column += box }
        return column
    }

    private static let quote: unichar = 0x3E

    private static func skipBlanks(_ text: NSString, _ index: inout Int, _ end: Int, _ column: inout Int, _ tabWidth: Int) {
        while index < end {
            let unit = text.character(at: index)
            if unit == CodeText.space {
                column += 1
            } else if unit == CodeText.tab {
                column += tabWidth - column % tabWidth
            } else {
                return
            }
            index += 1
        }
    }

    /// Width of a bullet (`-`, `*`, `+`) or number (`1.`, `10)`) at `index`.
    private static func listMarkerWidth(_ text: NSString, at index: Int, contentsEnd: Int) -> Int? {
        guard index < contentsEnd else { return nil }
        let first = text.character(at: index)
        if first == 0x2D || first == 0x2A || first == 0x2B { return 1 }
        var digits = 0
        while index + digits < contentsEnd, digits < 10, (0x30...0x39).contains(text.character(at: index + digits)) {
            digits += 1
        }
        guard (1...9).contains(digits), index + digits < contentsEnd else { return nil }
        let delimiter = text.character(at: index + digits)
        return delimiter == 0x2E || delimiter == 0x29 ? digits + 1 : nil
    }

    /// Width of `[ ] `, `[x] `, or `[X] ` at `index`.
    private static func taskBoxWidth(_ text: NSString, at index: Int, contentsEnd: Int) -> Int? {
        guard index + 3 < contentsEnd, text.character(at: index) == 0x5B, text.character(at: index + 2) == 0x5D,
              text.character(at: index + 3) == CodeText.space else { return nil }
        switch text.character(at: index + 1) {
        case CodeText.space, 0x78, 0x58: return 4
        default: return nil
        }
    }
}
