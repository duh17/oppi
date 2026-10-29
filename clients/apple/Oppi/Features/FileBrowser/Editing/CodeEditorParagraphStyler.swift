import UIKit

/// The one owner of paragraph styles: where the wrapped rows of a line start.
///
/// A continuation row lines up with the text of its own line, never deeper:
/// - Prose and code: the line's own leading indentation, so a flush paragraph
///   wraps flush and an indented line wraps under its own first character.
/// - Markdown list items and quotes: the column where the item's text starts,
///   after the quote markers, the bullet or number, and a task checkbox.
/// - Inside a fenced code block, every line is code, whatever it looks like.
/// A row never starts deeper than half the wrapped width.
///
/// The text storage holds one default style for the whole buffer (tab stops, no
/// hang), set with its fonts and colors (`CodeEditorHighlighter`). This object
/// is the content storage's delegate and gives a paragraph that needs a hang
/// its own style as TextKit builds it for layout, so the style is current for
/// every edit, undo, and Replace All, costs nothing for a paragraph that is not
/// laid out or has no hang, and does not depend on Syntax Highlighting.
@MainActor
final class CodeEditorParagraphStyler: NSObject, @preconcurrency NSTextContentStorageDelegate {
    private weak var textView: CodeEditorTextView?
    private let isMarkdown: Bool
    private var columnWidth: CGFloat
    private var tabWidth: Int
    private var styles: [Int: NSParagraphStyle] = [:]
    private var fences = CodeEditorFenceIndex()
    private var capColumns = Int.max
    /// The lowest cap in effect when any paragraph was built since the last
    /// restyle: a paragraph built during a resize wait is capped by whatever
    /// the width was at that moment, not by the last settled one.
    private var lowestBuiltCap = Int.max
    private var hasWrapWidth = false
    private var capTask: Task<Void, Never>?
    /// Everything TextKit has built through this delegate (kept in step with
    /// edits), and the deepest hang any of it wanted before the cap.
    private var builtRange: NSRange?
    private var deepestHang = 0

    /// Width of the wrapped text area in points; nil when lines do not wrap.
    /// A new width changes the cap on hangs; paragraphs TextKit built that
    /// hang past the smaller of the old and new cap are built again, and
    /// nothing else is touched.
    var wrapWidth: CGFloat? {
        didSet {
            let cap = Self.cap(for: wrapWidth, columnWidth: columnWidth)
            guard cap != capColumns else { return }
            capColumns = cap
            capTask?.cancel()
            guard hasWrapWidth else {
                // The first width arrives before the first layout.
                hasWrapWidth = true
                restyleForCap()
                return
            }
            // A resize drag reports a width per frame: restyle once it settles,
            // and not while marked (IME) text is open.
            capTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                while !Task.isCancelled, self?.textView?.markedTextRange != nil {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard !Task.isCancelled else { return }
                self?.restyleForCap()
            }
        }
    }

    private func restyleForCap() {
        defer { lowestBuiltCap = capColumns }
        guard let builtRange, deepestHang > min(lowestBuiltCap, capColumns) else { return }
        invalidate(builtRange)
    }

    init(textView: CodeEditorTextView, isMarkdown: Bool, columnWidth: CGFloat, tabWidth: Int) {
        self.textView = textView
        self.isMarkdown = isMarkdown
        self.columnWidth = columnWidth
        self.tabWidth = tabWidth
        super.init()
        (textView.textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The font or tab width changed. The caller restyles the buffer next,
    /// which makes TextKit ask for every paragraph again.
    func update(columnWidth: CGFloat, tabWidth: Int) {
        self.columnWidth = columnWidth
        self.tabWidth = tabWidth
        capColumns = Self.cap(for: wrapWidth, columnWidth: columnWidth)
        lowestBuiltCap = Int.max
        styles = [:]
        builtRange = nil
        deepestHang = 0
    }

    private static func cap(for width: CGFloat?, columnWidth: CGFloat) -> Int {
        guard let width, columnWidth > 0 else { return .max }
        return max(2, Int(width / columnWidth) / 2)
    }

    // MARK: - Styling a paragraph

    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let text = storage.mutableString
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: range.location, length: 0))
        let end = min(contentsEnd, NSMaxRange(range))
        var columns = Self.wrapColumns(in: text, lineStart: range.location, contentsEnd: end, tabWidth: tabWidth, markdown: false)
        if isMarkdown {
            // A list or quote item hangs under its text, unless it sits in a fenced code block.
            let item = Self.wrapColumns(in: text, lineStart: range.location, contentsEnd: end, tabWidth: tabWidth, markdown: true)
            if item != columns, !fences.contains(range.location, in: text) { columns = item }
        }
        builtRange = builtRange.map { NSUnionRange($0, range) } ?? range
        deepestHang = max(deepestHang, columns)
        lowestBuiltCap = min(lowestBuiltCap, capColumns)
        columns = min(capColumns, columns)
        // No hang: the buffer-wide default style is already right.
        guard columns > 0 else { return nil }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        paragraph.addAttribute(.paragraphStyle, value: style(columns: columns), range: NSRange(location: 0, length: paragraph.length))
        return NSTextParagraph(attributedString: paragraph)
    }

    private func style(columns: Int) -> NSParagraphStyle {
        if let cached = styles[columns] { return cached }
        let style = Self.paragraphStyle(columns: columns, tabWidth: tabWidth, columnWidth: columnWidth)
        styles[columns] = style
        return style
    }

    /// Tab stops every `tabWidth` columns; wrapped rows start `columns` in.
    /// With 0 columns this is the buffer-wide default.
    nonisolated static func paragraphStyle(columns: Int, tabWidth: Int, columnWidth: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = CGFloat(tabWidth) * columnWidth
        style.tabStops = []
        style.headIndent = CGFloat(columns) * columnWidth
        return style
    }

    // MARK: - Edits

    /// Keeps `builtRange` in step with an edit, and for Markdown lets the fence
    /// index see it: an edit can open or close a fence, which changes how the
    /// lines after it are styled. Paragraphs that asked about fences are built
    /// again; paragraphs nothing asked about are not styled differently.
    @objc private func storageDidProcessEditing(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange
        guard edited.location != NSNotFound else {
            // Unknown range: anything built may be gone or moved.
            builtRange = NSRange(location: 0, length: storage.length)
            if isMarkdown {
                // The edit's range is unknown: forget what was read and rebuild what was asked about.
                let asked = fences.askedThrough
                fences.reset()
                invalidate(NSRange(location: 0, length: min(storage.length, asked + 1)))
            }
            return
        }
        shiftBuiltRange(for: edited, changeInLength: storage.changeInLength, textLength: storage.length)
        guard isMarkdown else { return }
        if let stale = fences.apply(editAt: edited, changeInLength: storage.changeInLength, in: storage.mutableString),
           let built = builtRange {
            // Only paragraphs TextKit built through this delegate have a style to be stale.
            invalidate(NSIntersectionRange(stale, built))
        }
    }

    private func shiftBuiltRange(for edited: NSRange, changeInLength delta: Int, textLength: Int) {
        guard let built = builtRange else { return }
        let oldEditEnd = NSMaxRange(edited) - delta
        let start = built.location >= oldEditEnd ? built.location + delta : min(built.location, edited.location)
        let end = NSMaxRange(built) >= oldEditEnd ? NSMaxRange(built) + delta : max(edited.location, NSMaxRange(edited))
        let clipped = min(end, textLength)
        builtRange = clipped > start ? NSRange(location: start, length: clipped - start) : nil
    }

    /// Makes TextKit build the paragraphs in `range` again.
    ///
    /// Called from `didProcessEditing`, while the edit that triggered it is
    /// still being processed: TextKit folds this attribute range into that edit
    /// and invalidates the paragraphs in one pass. TextKit does not build
    /// paragraphs after an edit again on its own (without this call the
    /// paragraphs below stay as they were), and two real-window tests turn red
    /// when it is removed: `openingAndClosingAFenceRestylesTheLinesBelowAtOnce`
    /// and `openingAFenceAfterAnUnrelatedEditRestylesLinesBuiltFurtherDown`
    /// (no color pass runs there to rescue a stale paragraph).
    private func invalidate(_ range: NSRange) {
        guard range.length > 0, let storage = textView?.textStorage else { return }
        storage.beginEditing()
        storage.edited(.editedAttributes, range: range, changeInLength: 0)
        storage.endEditing()
    }

    // MARK: - The rule

    /// Columns for the line `lineStart..<contentsEnd` of `text`. Tabs advance
    /// to the next multiple of `tabWidth`.
    static func wrapColumns(in text: NSString, lineStart: Int, contentsEnd: Int, tabWidth: Int, markdown: Bool) -> Int {
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
